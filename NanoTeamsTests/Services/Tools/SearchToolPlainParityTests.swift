import XCTest
@testable import NanoTeams

/// Parity tests for the post-refactor `SearchTool.handle` plain path —
/// confirms the envelope shape, key ordering, and behavior match what the
/// LLM saw before `SearchExecutor` was extracted. Any field rename,
/// dropped key, or change in match ordering would shift the LLM's parsing
/// in ways that are hard to detect from a CI run alone.
final class SearchToolPlainParityTests: XCTestCase {

    private let fm = FileManager.default
    private var tempDir: URL!
    private var resolver: SandboxPathResolver!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempDir, internalDir: internalDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        resolver = nil
        try super.tearDownWithError()
    }

    private func makeTool() -> SearchTool {
        SearchTool(
            resolver: resolver,
            fileManager: fm,
            workFolderRoot: tempDir,
            internalDir: tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        )
    }

    private func ctx() -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "tester")
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func parse(_ json: String) throws -> [String: Any] {
        let data = json.data(using: .utf8) ?? Data()
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ParityTests", code: 0)
        }
        return dict
    }

    // MARK: - Envelope shape

    func testPlain_envelopeHasOkDataMetaKeys() throws {
        try write("a.swift", content: "target line\n")
        let result = makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        XCTAssertEqual(env["ok"] as? Bool, true)
        XCTAssertNotNil(env["data"])
        XCTAssertNotNil(env["meta"])
    }

    func testPlain_dataHasQueryMatchesCount() throws {
        try write("a.swift", content: "target\nbeta\n")
        let result = makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertEqual(data?["query"] as? String, "target")
        XCTAssertEqual(data?["count"] as? Int, 1)
        let matches = data?["matches"] as? [[String: Any]]
        XCTAssertEqual(matches?.count, 1)
        XCTAssertEqual(matches?.first?["path"] as? String, "a.swift")
        XCTAssertEqual(matches?.first?["line"] as? Int, 1)
        XCTAssertEqual(matches?.first?["text"] as? String, "target")
    }

    func testPlain_metaHasTruncatedFalseWhenWithinLimits() throws {
        try write("a.swift", content: "target\n")
        let result = makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let meta = env["meta"] as? [String: Any]
        XCTAssertEqual(meta?["truncated"] as? Bool, false)
    }

    func testPlain_metaHasTruncatedTrueAtLimit() throws {
        let lines = (0..<30).map { "target \($0)" }.joined(separator: "\n")
        try write("a.swift", content: lines)
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "max_results": 5]
        )
        let env = try parse(result.outputJSON)
        let meta = env["meta"] as? [String: Any]
        XCTAssertEqual(meta?["truncated"] as? Bool, true)
    }

    // MARK: - Optional skipped fields

    func testPlain_skippedKeys_omittedWhenEmpty() throws {
        try write("a.swift", content: "target\n")
        let result = makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertNil(data?["skipped_files"],
            "skipped_files must be omitted when no files were skipped.")
        XCTAssertNil(data?["skipped_binary_count"],
            "skipped_binary_count must be omitted when zero.")
    }

    func testPlain_skippedBinaryCount_presentWhenBinary() throws {
        try write("a.swift", content: "target\n")
        // Add a binary file to trigger the binary counter.
        try Data([0xFF, 0xFE]).write(to: tempDir.appendingPathComponent("blob.bin"))
        let result = makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertEqual(data?["skipped_binary_count"] as? Int, 1)
    }

    // MARK: - Context fields

    func testPlain_contextFields_omitted_whenZero() throws {
        try write("a.swift", content: "target\n")
        let result = makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let matches = env["data"] as? [String: Any]
        let m = (matches?["matches"] as? [[String: Any]])?.first
        XCTAssertNil(m?["context_before"])
        XCTAssertNil(m?["context_after"])
    }

    func testPlain_contextFields_present_whenRequested() throws {
        try write("a.swift", content: "before\ntarget\nafter\n")
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "context_before": 1, "context_after": 1]
        )
        let env = try parse(result.outputJSON)
        let matches = env["data"] as? [String: Any]
        let m = (matches?["matches"] as? [[String: Any]])?.first
        let before = m?["context_before"] as? [[String: Any]]
        let after = m?["context_after"] as? [[String: Any]]
        XCTAssertEqual(before?.count, 1)
        XCTAssertEqual(after?.count, 1)
        XCTAssertEqual(before?.first?["text"] as? String, "before")
        XCTAssertEqual(after?.first?["text"] as? String, "after")
    }

    // MARK: - Multi-file ordering

    func testPlain_multipleFiles_returnedInDirectoryOrder() throws {
        // Both files match — the walk sorts directory entries, so we get a
        // stable order regardless of FS enumeration quirks.
        try write("aa.swift", content: "target\n")
        try write("bb.swift", content: "target\n")
        try write("cc.swift", content: "target\n")
        let result = makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let matches = (env["data"] as? [String: Any])?["matches"] as? [[String: Any]]
        let paths = matches?.compactMap { $0["path"] as? String }
        XCTAssertEqual(paths, ["aa.swift", "bb.swift", "cc.swift"],
            "Directory walk must remain alphabetically stable.")
    }

    // MARK: - Error behavior

    func testPlain_missingQuery_errorEnvelopeShape() throws {
        let result = makeTool().handle(
            context: ctx(), args: [:]
        )
        XCTAssertTrue(result.isError)
        let env = try parse(result.outputJSON)
        XCTAssertEqual(env["ok"] as? Bool, false)
        let err = env["error"] as? [String: Any]
        XCTAssertNotNil(err)
        XCTAssertNotNil(err?["code"])
        XCTAssertNotNil(err?["message"])
    }
}
