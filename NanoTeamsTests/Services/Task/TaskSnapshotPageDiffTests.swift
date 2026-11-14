import XCTest
@testable import NanoTeams

/// N8 (2026-11-12): a page of `task_changes` is diffed file by file and decoded without loss.
final class TaskSnapshotPageDiffTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: TaskSnapshotService!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("TaskSnapshotPageDiffTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = TaskSnapshotService(globalExcludesFile: nil)
    }

    override func tearDown() async throws {
        if let tempDir { try? fileManager.removeItem(at: tempDir) }
        service = nil
        try await super.tearDown()
    }

    private func write(_ data: Data, _ relative: String) throws {
        let url = tempDir.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func changes(page: Int = 1, pageSize: Int = 10, filePath: String? = nil) async throws
        -> TaskSnapshotService.TaskChangesResult {
        try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 1, runID: 1, round: 1,
            page: page, pageSize: pageSize, filePath: filePath)
    }

    // MARK: - Decoding

    func testLosslessText_validUTF8_isUnchanged() {
        let text = "a Ж 🎨 \u{10FFFF}"
        let decoded = TaskSnapshotService.losslessText(Data(text.utf8))
        XCTAssertEqual(decoded.text, text)
        XCTAssertFalse(decoded.hadInvalidBytes)
        XCTAssertEqual(TaskSnapshotService.losslessText(Data()).text, "")
    }

    func testLosslessText_everyInvalidByteIsSpelled_andValidNeighboursSurvive() {
        let cases: [([UInt8], String)] = [
            ([0x63, 0x61, 0x66, 0xE9], "caf<0xE9>"),                       // Latin-1 é
            ([0xC0, 0xAF], "<0xC0><0xAF>"),                                // overlong slash
            ([0xED, 0xA0, 0x80], "<0xED><0xA0><0x80>"),                    // a surrogate
            ([0xF4, 0x90, 0x80, 0x80], "<0xF4><0x90><0x80><0x80>"),        // past U+10FFFF
            ([0x41, 0xE2, 0x82], "A<0xE2><0x82>"),                         // cut at the end
            ([0xD0, 0x96, 0xFF, 0xD0, 0x96], "Ж<0xFF>Ж"),
            ([0xF0, 0x9F, 0x8E, 0xA8, 0x80], "🎨<0x80>"),                   // stray continuation
            ([0xE2, 0x82, 0x41], "<0xE2><0x82>A"),                         // third byte not a continuation
            ([0xF0, 0x9F, 0x8E, 0x41], "<0xF0><0x9F><0x8E>A"),             // fourth byte not one
        ]
        for (bytes, expected) in cases {
            let decoded = TaskSnapshotService.losslessText(Data(bytes))
            XCTAssertEqual(decoded.text, expected, "\(bytes)")
            XCTAssertTrue(decoded.hadInvalidBytes)
            XCTAssertFalse(decoded.text.contains("\u{FFFD}"))
        }
    }

    func testIsBinaryDiff_readsOnlyTheHeader() {
        XCTAssertTrue(TaskSnapshotService.isBinaryDiff(
            "diff --git a/x.png b/x.png\nindex 1..2 100644\nBinary files a/x.png and b/x.png differ\n"))
        XCTAssertFalse(TaskSnapshotService.isBinaryDiff(
            "diff --git a/n.txt b/n.txt\n@@ -1 +1 @@\nBinary files a/fake and b/fake differ\n"),
            "a line of the file's own text that looks like git's verdict is text")
        XCTAssertFalse(TaskSnapshotService.isBinaryDiff(""))
    }

    // MARK: - The page

    func testBinaryAndNonUTF8Fields_onlyOnTheFilesOfThePage() async throws {
        try write(Data([0x00, 0x01]), "a.bin")
        try write(Data("x\n".utf8), "b.txt")
        try write(Data("y\n".utf8), "c.txt")
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, runID: 1, round: 1, phase: .start)
        try write(Data([0x00, 0x02]), "a.bin")
        try write(Data("x2\n".utf8), "b.txt")
        try write(Data([0x7A, 0xE9, 0x0A]), "c.txt")
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, runID: 1, round: 1, phase: .review)

        let first = try await changes(page: 1, pageSize: 2)
        XCTAssertEqual(first.files.map(\.path), ["a.bin", "b.txt", "c.txt"])
        XCTAssertEqual(first.files.map(\.binary), [true, nil, nil])
        XCTAssertEqual(first.files.map(\.encoding), [nil, nil, nil], "c.txt is not on page 1")
        XCTAssertEqual(first.page_diffs.map(\.path), ["a.bin", "b.txt"])
        XCTAssertTrue(first.diff.contains("Binary files"))

        let second = try await changes(page: 2, pageSize: 2)
        XCTAssertEqual(second.files.map(\.encoding), [nil, nil, "not_utf8"])
        XCTAssertTrue(second.diff.contains("+z<0xE9>"), second.diff)
        XCTAssertEqual(second.diff, second.page_diffs.map(\.text).joined())
    }

    func testRenamedFile_isDiffedWithBothPaths() async throws {
        let body = Data((0..<40).map { "line \($0)\n" }.joined().utf8)
        try write(body, "old.txt")
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, runID: 1, round: 1, phase: .start)
        try fileManager.moveItem(
            at: tempDir.appendingPathComponent("old.txt"), to: tempDir.appendingPathComponent("new.txt"))
        let result = try await changes()
        XCTAssertEqual(result.files.map(\.change_type), ["renamed"])
        XCTAssertTrue(result.diff.contains("rename from old.txt"), result.diff)
        XCTAssertTrue(result.diff.contains("rename to new.txt"))

        let filtered = try await changes(filePath: "old.txt")
        XCTAssertEqual(filtered.files.map(\.path), ["new.txt"], "the old name filters too")
    }

    func testEncodedResult_carriesNoPageDiffs() throws {
        let result = TaskSnapshotService.TaskChangesResult(
            folder_id: "f", task_id: 1, round: 1, files: [.init(path: "a", change_type: "added")],
            diff: "d", page: 1, total_pages: 1, has_more: false,
            page_diffs: [.init(path: "a", text: "d", binary: false, notUTF8: false)])
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertNil(json["page_diffs"])
        let file = try XCTUnwrap((json["files"] as? [[String: Any]])?.first)
        XCTAssertNil(file["binary"], "absent, not false")
        XCTAssertNil(file["encoding"])
        let decoded = try JSONDecoder().decode(
            TaskSnapshotService.TaskChangesResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.page_diffs, [])
    }
}
