import XCTest

@testable import NanoTeams

/// `ArtifactService` is the only reader of persisted artifact payloads, and
/// artifacts are injected into downstream roles' conversations IN FULL — so a
/// silent nil here is a downstream role that simply sees no upstream work.
/// It was at 9.1% line coverage when this suite was written.
///
/// `ArtifactService` and `NTMSPaths` are `nonisolated`, and `NTMSRepository` is
/// a `nonisolated struct`, so this class stays nonisolated and the Xcode 26.3
/// `@MainActor` + sync-test `abort()` trap does not apply.
final class ArtifactServiceIOTests: XCTestCase {

    private var tempDir: URL!
    private var paths: NTMSPaths!
    private var sut: ArtifactService!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-io-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        paths = NTMSPaths(workFolderRoot: tempDir)
        sut = ArtifactService()
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        sut = nil
        paths = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes `bytes` at `<root>/.nanoteams/<relative>` and returns an artifact
    /// pointing at it. `relativePath` is stored relative to `.nanoteams/`, which
    /// is the convention `readContent` resolves against.
    private func makeArtifact(relative: String, bytes: Data) throws -> Artifact {
        let url = paths.nanoteamsDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return Artifact(name: "Design Spec", relativePath: relative)
    }

    private func read(_ artifact: Artifact) -> String? {
        ArtifactService.readContent(artifact: artifact, workFolderRoot: tempDir)
    }

    // MARK: - readContent: the guard arms

    func testReadContent_noPersistedPath_returnsNil() {
        XCTAssertNil(read(Artifact(name: "Design Spec", relativePath: nil)))
    }

    func testReadContent_emptyPersistedPath_returnsNil() {
        XCTAssertNil(read(Artifact(name: "Design Spec", relativePath: "")))
    }

    func testReadContent_pathPointingNowhere_returnsNil() {
        // The catch arm: a recorded path whose file was deleted or never written.
        XCTAssertNil(read(Artifact(name: "Design Spec", relativePath: "tasks/1/runs/0/gone.md")))
    }

    func testReadContent_pathIsADirectory_returnsNil() throws {
        let dir = paths.nanoteamsDir.appendingPathComponent("tasks/1/runs/0/adir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(read(Artifact(name: "Design Spec", relativePath: "tasks/1/runs/0/adir")))
    }

    // MARK: - readContent: the happy path and the cap boundary

    func testReadContent_smallFile_returnsExactContentWithNoMarker() throws {
        let body = "# Design Spec\n\nTwo lines.\n"
        let artifact = try makeArtifact(relative: "tasks/1/runs/0/a.md", bytes: Data(body.utf8))
        XCTAssertEqual(read(artifact), body)
    }

    func testReadContent_emptyFile_returnsEmptyStringNotNil() throws {
        // "" and nil mean different things to every caller: an artifact that was
        // submitted empty is not the same as one that could not be read.
        let artifact = try makeArtifact(relative: "tasks/1/runs/0/empty.md", bytes: Data())
        XCTAssertEqual(read(artifact), "")
    }

    func testReadContent_exactlyAtTheCap_isNotMarkedTruncated() throws {
        let max = ArtifactConstants.maxContentBytes
        let body = String(repeating: "a", count: max)
        let artifact = try makeArtifact(relative: "tasks/1/runs/0/at.md", bytes: Data(body.utf8))

        let text = try XCTUnwrap(read(artifact))
        XCTAssertEqual(text.utf8.count, max)
        XCTAssertFalse(text.hasSuffix("... (truncated)"),
                       "a file exactly at the cap was not cut, so it must not claim to be")
    }

    func testReadContent_oneByteOverTheCap_isTruncatedAndMarked() throws {
        let max = ArtifactConstants.maxContentBytes
        let body = String(repeating: "a", count: max + 1)
        let artifact = try makeArtifact(relative: "tasks/1/runs/0/over.md", bytes: Data(body.utf8))

        let text = try XCTUnwrap(read(artifact))
        XCTAssertTrue(text.hasSuffix("\n... (truncated)"))
        XCTAssertEqual(text.replacingOccurrences(of: "\n... (truncated)", with: "").utf8.count, max)
    }

    // MARK: - readContent: the cut that lands inside a character

    /// `Data.prefix(maxBytes)` cuts on a BYTE boundary. Before the fix this fed
    /// `String(data:encoding:.utf8)` directly, so an artifact past the cap whose
    /// 51200th byte fell mid-character decoded to `nil` and the ENTIRE document
    /// read as unreadable — no error, no partial content, and most easily on the
    /// non-ASCII text this project routinely produces.
    ///
    /// One leading ASCII byte puts every subsequent 2-byte character out of
    /// phase with the cap, so the cut necessarily splits one.
    func testReadContent_capLandsInsideAMultiByteCharacter_stillReturnsContent() throws {
        let max = ArtifactConstants.maxContentBytes
        XCTAssertEqual(max % 2, 0, "the phase argument below assumes an even cap")

        let body = "a" + String(repeating: "я", count: max / 2)
        let data = Data(body.utf8)
        XCTAssertEqual(data.count, max + 1, "expected exactly one byte past the cap")
        XCTAssertNil(String(data: data.prefix(max), encoding: .utf8),
                     "the naive byte cut must genuinely be invalid UTF-8, or this test proves nothing")

        let artifact = try makeArtifact(relative: "tasks/1/runs/0/cyr.md", bytes: data)
        let text = try XCTUnwrap(
            read(artifact),
            "a cut inside a character must truncate the artifact, not lose it")

        XCTAssertTrue(text.hasSuffix("\n... (truncated)"))
        let head = text.replacingOccurrences(of: "\n... (truncated)", with: "")
        XCTAssertTrue(head.hasPrefix("a"))
        XCTAssertEqual(head.count, max / 2, "one character short of the full body, cut cleanly")
        XCTAssertFalse(head.unicodeScalars.contains { $0 == "\u{FFFD}" },
                       "must not paper over the split with a replacement character")
    }

    /// The backoff is scoped to OUR cut. A file that is under the cap and simply
    /// is not UTF-8 must still be rejected, not salvaged by dropping bytes.
    func testReadContent_smallNonUTF8File_isStillRejected() throws {
        let artifact = try makeArtifact(
            relative: "tasks/1/runs/0/bin.md", bytes: Data([0xFF, 0xFE, 0x00, 0x01, 0xC3, 0x28]))
        XCTAssertNil(read(artifact))
    }

    func testDecodeUTF8SnappingToBoundary_backsOffAtMostThreeBytes() {
        // A 4-byte scalar is the longest sequence, so three is exhaustive.
        let emoji = Data("🎯".utf8)
        XCTAssertEqual(emoji.count, 4)
        for drop in 1...3 {
            XCTAssertEqual(
                ArtifactService.decodeUTF8SnappingToBoundary(emoji.dropLast(drop)), "",
                "a lone partial sequence snaps back to empty, never nil")
        }
        XCTAssertEqual(ArtifactService.decodeUTF8SnappingToBoundary(emoji), "🎯")
        XCTAssertEqual(ArtifactService.decodeUTF8SnappingToBoundary(Data()), "")
        XCTAssertNil(
            ArtifactService.decodeUTF8SnappingToBoundary(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF])),
            "genuinely non-UTF-8 input survives the backoff and is still rejected")
    }

    // MARK: - Build diagnostics

    func testBuildDiagnosticsRelativePath_whenNoFileWasWritten_returnsNil() {
        XCTAssertNil(
            sut.buildDiagnosticsRelativePath(
                taskID: 1, runID: 0, roleID: "engineer", workFolderRoot: tempDir))
    }

    func testPersistEmptyBuildDiagnostics_writesTheCleanBuildSummary() throws {
        let relative = try XCTUnwrap(
            try sut.persistEmptyBuildDiagnostics(
                taskID: 1, runID: 0, roleID: "engineer", workFolderRoot: tempDir))

        let url = paths.nanoteamsDir.appendingPathComponent(relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the returned path must resolve against .nanoteams/, as readContent assumes")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["skipped"] as? Bool, true)
        XCTAssertEqual(json["skipReason"] as? String, "clean_build")
        XCTAssertEqual(json["errorCount"] as? Int, 0)
        XCTAssertEqual(json["warningCount"] as? Int, 0)
        XCTAssertEqual((json["issues"] as? [Any])?.count, 0)
        XCTAssertNotNil(json["createdAt"] as? String)
    }

    /// The two methods are a pair: what one writes, the other must find. Testing
    /// them separately would let their path derivations drift apart silently.
    func testPersistThenLookup_agreeOnThePath() throws {
        let written = try XCTUnwrap(
            try sut.persistEmptyBuildDiagnostics(
                taskID: 7, runID: 2, roleID: "code_reviewer", workFolderRoot: tempDir))
        let found = sut.buildDiagnosticsRelativePath(
            taskID: 7, runID: 2, roleID: "code_reviewer", workFolderRoot: tempDir)
        XCTAssertEqual(found, written)
    }

    func testPersistThenLookup_nestedSubtask_staysUnderItsAncestorChain() throws {
        let ancestors = [3, 5]
        let written = try XCTUnwrap(
            try sut.persistEmptyBuildDiagnostics(
                taskID: 9, runID: 0, roleID: "engineer",
                workFolderRoot: tempDir, ancestors: ancestors))
        XCTAssertTrue(written.contains("subtasks"),
                      "a delegated child's diagnostics must nest, not collide with the root task's")

        let found = sut.buildDiagnosticsRelativePath(
            taskID: 9, runID: 0, roleID: "engineer",
            workFolderRoot: tempDir, ancestors: ancestors)
        XCTAssertEqual(found, written)

        XCTAssertNil(
            sut.buildDiagnosticsRelativePath(
                taskID: 9, runID: 0, roleID: "engineer", workFolderRoot: tempDir),
            "the same ids without the ancestor chain address a different file")
    }

    func testPersistEmptyBuildDiagnostics_isIdempotentAcrossRepeatCalls() throws {
        let first = try sut.persistEmptyBuildDiagnostics(
            taskID: 1, runID: 0, roleID: "engineer", workFolderRoot: tempDir)
        let second = try sut.persistEmptyBuildDiagnostics(
            taskID: 1, runID: 0, roleID: "engineer", workFolderRoot: tempDir)
        XCTAssertEqual(first, second)
    }

    /// Diagnostics live under `.nanoteams/internal/`, which the sandbox hides
    /// from the file tools — so the artifact that references them must not
    /// advertise a readable path.
    func testDiagnosticsArtifact_hasNoLLMReadablePath() throws {
        let relative = try XCTUnwrap(
            try sut.persistEmptyBuildDiagnostics(
                taskID: 1, runID: 0, roleID: "engineer", workFolderRoot: tempDir))
        XCTAssertTrue(relative.hasPrefix("internal/"))
        XCTAssertNil(
            Artifact(name: ArtifactConstants.buildDiagnosticsName, relativePath: relative)
                .llmReadablePath)
    }
}
