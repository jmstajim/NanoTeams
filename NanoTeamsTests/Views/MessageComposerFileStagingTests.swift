import XCTest

@testable import NanoTeams

/// Corner / boundary coverage for the pure file-staging validation extracted from
/// `MessageComposer.stageURLs`. The `stage` closure is injected, so the directory
/// rejection / dedup / rejection-collection / error-aggregation are exercised without a
/// view. `StagedAttachment`'s init reads file attributes, so attachments are backed by
/// real temp files; equality is by `stagedRelativePath`.
final class MessageComposerFileStagingTests: XCTestCase {

    private var tempDir: URL!
    private var subDir: URL!
    private var fileA: URL!
    private var fileB: URL!
    private var fileC: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        subDir = tempDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        fileA = tempDir.appendingPathComponent("a.txt")
        fileB = tempDir.appendingPathComponent("b.txt")
        fileC = tempDir.appendingPathComponent("c.txt")
        for f in [fileA!, fileB!, fileC!] {
            try Data("x".utf8).write(to: f)
        }
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil; subDir = nil; fileA = nil; fileB = nil; fileC = nil
        try super.tearDownWithError()
    }

    private func att(_ url: URL, path: String) throws -> StagedAttachment {
        try StagedAttachment(url: url, stagedRelativePath: path)
    }

    // MARK: - validateAndStage

    func testDirectoryRejected_withoutConsultingStage() {
        var stageCalled = false
        let result = MessageComposerFileStaging.validateAndStage(
            urls: [subDir], existing: [], stage: { _ in stageCalled = true; return nil })
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertEqual(result.rejected, [subDir.lastPathComponent])
        XCTAssertFalse(stageCalled, "a directory is rejected before stage is consulted")
    }

    func testStageReturnsNil_rejected() {
        let result = MessageComposerFileStaging.validateAndStage(
            urls: [fileA], existing: [], stage: { _ in nil })
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertEqual(result.rejected, [fileA.lastPathComponent])
    }

    func testSuccess_appendsStaged() throws {
        let a = try att(fileA, path: "rel/a")
        let result = MessageComposerFileStaging.validateAndStage(
            urls: [fileA], existing: [], stage: { _ in a })
        XCTAssertEqual(result.staged, [a])
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testDedupAgainstExisting_skipsAlreadyPresent() throws {
        let a = try att(fileA, path: "rel/a")
        let result = MessageComposerFileStaging.validateAndStage(
            urls: [fileA], existing: [a], stage: { _ in a })
        XCTAssertTrue(result.staged.isEmpty, "already in existing ⇒ not re-added")
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testWithinBatchDedup_keepsFirstOnly() throws {
        // Two URLs stage to attachments equal by stagedRelativePath → only the first survives.
        let a = try att(fileA, path: "rel/same")
        let aDup = try att(fileB, path: "rel/same")
        let result = MessageComposerFileStaging.validateAndStage(
            urls: [fileA, fileB], existing: [],
            stage: { url in url == self.fileA ? a : aDup })
        XCTAssertEqual(result.staged.count, 1, "within-batch dedup keeps one")
        XCTAssertEqual(result.staged, [a])
    }

    func testMixedPartition_preservesOrder() throws {
        let a = try att(fileA, path: "rel/a")
        let c = try att(fileC, path: "rel/c")
        // subDir (rejected), fileA → a, fileB → nil (rejected), fileC → c.
        let result = MessageComposerFileStaging.validateAndStage(
            urls: [subDir, fileA, fileB, fileC], existing: [],
            stage: { url in
                if url == self.fileA { return a }
                if url == self.fileC { return c }
                return nil
            })
        XCTAssertEqual(result.staged, [a, c], "staged in input order")
        XCTAssertEqual(result.rejected, [subDir.lastPathComponent, fileB.lastPathComponent])
    }

    func testEmptyInput_returnsEmptyResult() {
        let result = MessageComposerFileStaging.validateAndStage(
            urls: [], existing: [], stage: { _ in nil })
        XCTAssertEqual(result, .init(staged: [], rejected: []))
    }

    // MARK: - aggregateErrorMessage

    func testAggregate_nilExisting_returnsNew() {
        XCTAssertEqual(MessageComposerFileStaging.aggregateErrorMessage(existing: nil, new: "x"), "x")
    }

    func testAggregate_emptyExisting_returnsNew() {
        XCTAssertEqual(MessageComposerFileStaging.aggregateErrorMessage(existing: "", new: "x"), "x")
    }

    func testAggregate_nonEmpty_joinsWithNewline() {
        XCTAssertEqual(MessageComposerFileStaging.aggregateErrorMessage(existing: "a", new: "b"), "a\nb")
    }

    func testAggregate_chains() {
        let once = MessageComposerFileStaging.aggregateErrorMessage(existing: "a", new: "b")
        XCTAssertEqual(MessageComposerFileStaging.aggregateErrorMessage(existing: once, new: "c"), "a\nb\nc")
    }
}
