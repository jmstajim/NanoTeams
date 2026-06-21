import XCTest

@testable import NanoTeams

/// Corner / boundary coverage for the shared resolve-and-extract helper used by
/// `read_file` and `read_lines`. The full handler behavior is still pinned by
/// `ReadFileDocumentTests` / `ReadFileLineLimitTests` / `ReadLinesLineLimitTests`;
/// this file isolates the de-duplicated helper so its edges (missing file,
/// directory, RTFD-as-file, restricted-path throw, binary fallback) are tested
/// once at the source.
final class FileReadSupportTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var resolver: SandboxPathResolver!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("FileReadSupportTests_\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        resolver = nil
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - resolveReadableFile

    func testResolve_existingFile_success() throws {
        try write("a.txt", "hello")
        let result = try FileReadSupport.resolveReadableFile(
            toolName: "read_file", args: [:], path: "a.txt",
            resolver: resolver, fileManager: fm, notFoundNext: nil
        )
        guard case .file(let url) = result else { return XCTFail("Expected file") }
        XCTAssertEqual(url.lastPathComponent, "a.txt")
    }

    func testResolve_missingFile_withHint_includesListFilesHint() throws {
        let result = try FileReadSupport.resolveReadableFile(
            toolName: "read_file", args: [:], path: "nope.txt",
            resolver: resolver, fileManager: fm,
            notFoundNext: NextHint(suggested_cmd: ToolNames.listFiles, suggested_args: ["path": ""], reason: "x")
        )
        guard case .rejected(let err) = result else { return XCTFail("Expected rejection") }
        XCTAssertTrue(err.isError)
        XCTAssertTrue(err.outputJSON.contains("FILE_NOT_FOUND"))
        XCTAssertTrue(err.outputJSON.contains(ToolNames.listFiles), "Caller-supplied not-found hint must be emitted")
    }

    func testResolve_missingFile_noHint_omitsHint() throws {
        let result = try FileReadSupport.resolveReadableFile(
            toolName: "read_lines", args: [:], path: "nope.txt",
            resolver: resolver, fileManager: fm, notFoundNext: nil
        )
        guard case .rejected(let err) = result else { return XCTFail("Expected rejection") }
        XCTAssertTrue(err.outputJSON.contains("FILE_NOT_FOUND"))
        XCTAssertFalse(err.outputJSON.contains(ToolNames.listFiles), "nil hint must not emit a next/list_files hint")
    }

    func testResolve_plainDirectory_failureNotAFile() throws {
        try fm.createDirectory(at: tempDir.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        let result = try FileReadSupport.resolveReadableFile(
            toolName: "read_file", args: [:], path: "subdir",
            resolver: resolver, fileManager: fm, notFoundNext: nil
        )
        guard case .rejected(let err) = result else { return XCTFail("Expected rejection") }
        XCTAssertTrue(err.outputJSON.contains("NOT_A_FILE"))
        XCTAssertTrue(err.outputJSON.contains(ToolNames.listFiles), "Directory rejection always hints list_files")
    }

    /// Load-bearing: an `.rtfd` package is a directory, but must be treated as a
    /// single readable document, not rejected as a directory.
    func testResolve_rtfdBundle_treatedAsFile_success() throws {
        let bundle = tempDir.appendingPathComponent("doc.rtfd", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try #"{\rtf1\ansi inside}"#.write(to: bundle.appendingPathComponent("TXT.rtf"),
                                          atomically: true, encoding: .utf8)
        let result = try FileReadSupport.resolveReadableFile(
            toolName: "read_file", args: [:], path: "doc.rtfd",
            resolver: resolver, fileManager: fm, notFoundNext: nil
        )
        guard case .file(let url) = result else { return XCTFail("RTFD bundle must resolve as a file") }
        XCTAssertEqual(url.lastPathComponent, "doc.rtfd")
    }

    /// A restricted / sandbox-escaping path must propagate the resolver's throw
    /// (so the caller's `ToolErrorHandler` maps it) — not be swallowed into a
    /// `.failure` envelope here.
    func testResolve_parentTraversal_propagatesThrow() {
        XCTAssertThrowsError(
            try FileReadSupport.resolveReadableFile(
                toolName: "read_file", args: [:], path: "../escape.txt",
                resolver: resolver, fileManager: fm, notFoundNext: nil
            )
        )
    }

    // MARK: - extractContent

    func testExtract_utf8TextFile_returnsTextWithUTF8Encoding() throws {
        try write("a.txt", "hello world")
        let url = tempDir.appendingPathComponent("a.txt")
        let outcome = FileReadSupport.extractContent(
            toolName: "read_file", args: [:], path: "a.txt", fileURL: url
        )
        guard case .text(let content, let encoding) = outcome else { return XCTFail("Expected text") }
        XCTAssertEqual(content, "hello world")
        XCTAssertEqual(encoding, "utf-8")
    }

    func testExtract_documentFormat_returnsExtractedTextEncoding() throws {
        let url = tempDir.appendingPathComponent("doc.rtf")
        try #"{\rtf1\ansi RTF body text}"#.write(to: url, atomically: true, encoding: .utf8)
        let outcome = FileReadSupport.extractContent(
            toolName: "read_file", args: [:], path: "doc.rtf", fileURL: url
        )
        guard case .text(let content, let encoding) = outcome else { return XCTFail("Expected text") }
        XCTAssertTrue(content.contains("RTF body text"))
        XCTAssertEqual(encoding, "extracted_text", "Document-format reads report extracted_text encoding")
    }

    func testExtract_binaryFile_returnsCommandFailed() throws {
        // Bytes that are not valid UTF-8 and not a recognized document format.
        let url = tempDir.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x80, 0x81, 0x82]).write(to: url)
        let outcome = FileReadSupport.extractContent(
            toolName: "read_lines", args: [:], path: "blob.bin", fileURL: url
        )
        guard case .failure(let err) = outcome else { return XCTFail("Binary must fail, not return empty text") }
        XCTAssertTrue(err.isError)
        XCTAssertTrue(err.outputJSON.contains("COMMAND_FAILED"))
        XCTAssertTrue(err.outputJSON.contains("not valid UTF-8"))
    }

    func testExtract_emptyFile_returnsEmptyTextNotFailure() throws {
        try write("empty.txt", "")
        let url = tempDir.appendingPathComponent("empty.txt")
        let outcome = FileReadSupport.extractContent(
            toolName: "read_file", args: [:], path: "empty.txt", fileURL: url
        )
        guard case .text(let content, let encoding) = outcome else { return XCTFail("Empty file is valid UTF-8") }
        XCTAssertEqual(content, "")
        XCTAssertEqual(encoding, "utf-8")
    }
}
