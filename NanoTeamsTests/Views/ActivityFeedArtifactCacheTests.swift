import XCTest

@testable import NanoTeams

/// Tests for `ActivityFeedBuilder.loadArtifactContentsForStepSync` — the shared,
/// untruncated artifact-content reader used by BOTH the live feed and the
/// conversation-log render path for message↔artifact dedup. A miss can only ever
/// *add* a bubble (fail-safe), never hide a real message.
final class ActivityFeedArtifactCacheTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeamsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func writeArtifactFile(relativePath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(".nanoteams").appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func step(artifacts: [Artifact]) -> StepExecution {
        StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer Step", artifacts: artifacts)
    }

    func testPresentFile_contentInSet() throws {
        let rel = "tasks/0/runs/0/roles/eng/artifact_notes.md"
        try writeArtifactFile(relativePath: rel, content: "ARTIFACT_BODY")
        let s = step(artifacts: [Artifact(name: "Notes", relativePath: rel)])

        let set = ActivityFeedBuilder.loadArtifactContentsForStepSync(s, workFolderURL: tempDir)
        XCTAssertTrue(set.contains("ARTIFACT_BODY"))
    }

    func testMissingFile_skipped() {
        let s = step(artifacts: [Artifact(name: "Notes", relativePath: "tasks/0/runs/0/roles/eng/does_not_exist.md")])
        let set = ActivityFeedBuilder.loadArtifactContentsForStepSync(s, workFolderURL: tempDir)
        XCTAssertTrue(set.isEmpty)
    }

    func testNilRelativePath_skipped() {
        let s = step(artifacts: [Artifact(name: "Notes", relativePath: nil)])
        let set = ActivityFeedBuilder.loadArtifactContentsForStepSync(s, workFolderURL: tempDir)
        XCTAssertTrue(set.isEmpty)
    }

    // MARK: - (relativePath, updatedAt) memo — 2026-08-21

    /// The memo's contract, stated as a test: bytes are keyed by the MODEL's
    /// (relativePath, updatedAt), so a disk rewrite with no model mutation serves
    /// the memoized content. This is the deliberate trade that stops both callers
    /// (feed rebuild, per-turn conversation-log render) from re-reading every
    /// artifact of every step on every invocation.
    func testMemo_diskRewriteWithoutModelBump_servesMemoizedContent() throws {
        let rel = "tasks/0/runs/0/roles/eng/artifact_memo_a.md"
        try writeArtifactFile(relativePath: rel, content: "V1")
        let artifact = Artifact(name: "Memo", relativePath: rel)
        let s = step(artifacts: [artifact])

        XCTAssertTrue(ActivityFeedBuilder.loadArtifactContentsForStepSync(
            s, workFolderURL: tempDir).contains("V1"))
        try writeArtifactFile(relativePath: rel, content: "V2")
        let again = ActivityFeedBuilder.loadArtifactContentsForStepSync(s, workFolderURL: tempDir)
        XCTAssertTrue(again.contains("V1"), "same (path, updatedAt) must serve the memo")
        XCTAssertFalse(again.contains("V2"))
    }

    /// A revision bumps `updatedAt`, which changes the key — the re-read is the
    /// mutation this pins (RED: key the memo by relativePath alone and this fails).
    func testMemo_updatedAtBump_reReadsFromDisk() throws {
        let rel = "tasks/0/runs/0/roles/eng/artifact_memo_b.md"
        try writeArtifactFile(relativePath: rel, content: "V1")
        var artifact = Artifact(name: "Memo", relativePath: rel)
        let s1 = step(artifacts: [artifact])
        XCTAssertTrue(ActivityFeedBuilder.loadArtifactContentsForStepSync(
            s1, workFolderURL: tempDir).contains("V1"))

        try writeArtifactFile(relativePath: rel, content: "V2")
        artifact.updatedAt = MonotonicClock.shared.now()
        let s2 = step(artifacts: [artifact])
        XCTAssertTrue(ActivityFeedBuilder.loadArtifactContentsForStepSync(
            s2, workFolderURL: tempDir).contains("V2"))
    }

    /// A failed read must stay retryable — the artifact file may simply not have
    /// landed yet, and memoizing the miss would hide it forever.
    func testMemo_failedReadIsNotCached() throws {
        let rel = "tasks/0/runs/0/roles/eng/artifact_memo_c.md"
        let artifact = Artifact(name: "Memo", relativePath: rel)
        let s = step(artifacts: [artifact])
        XCTAssertTrue(ActivityFeedBuilder.loadArtifactContentsForStepSync(
            s, workFolderURL: tempDir).isEmpty)

        try writeArtifactFile(relativePath: rel, content: "LATE")
        XCTAssertTrue(ActivityFeedBuilder.loadArtifactContentsForStepSync(
            s, workFolderURL: tempDir).contains("LATE"))
    }

    func testNilWorkFolder_returnsEmpty() {
        let s = step(artifacts: [Artifact(name: "Notes", relativePath: "tasks/0/x.md")])
        let set = ActivityFeedBuilder.loadArtifactContentsForStepSync(s, workFolderURL: nil)
        XCTAssertTrue(set.isEmpty)
    }

    func testMultipleArtifacts_oneMissing_othersRetained() throws {
        // Fail-safe: a missing artifact is skipped, the readable ones still populate the set
        // (a dedup miss can only ever ADD a bubble, never hide a real message).
        try writeArtifactFile(relativePath: "tasks/0/runs/0/roles/eng/a.md", content: "AAA")
        try writeArtifactFile(relativePath: "tasks/0/runs/0/roles/eng/c.md", content: "CCC")
        let s = step(artifacts: [
            Artifact(name: "A", relativePath: "tasks/0/runs/0/roles/eng/a.md"),
            Artifact(name: "B", relativePath: "tasks/0/runs/0/roles/eng/missing.md"),
            Artifact(name: "C", relativePath: "tasks/0/runs/0/roles/eng/c.md"),
        ])
        let set = ActivityFeedBuilder.loadArtifactContentsForStepSync(s, workFolderURL: tempDir)
        XCTAssertEqual(set, ["AAA", "CCC"])
    }

    func testIdenticalContents_collapseInSet() throws {
        // Two artifacts with byte-identical content collapse to one entry — intended, since the
        // cache is a content-equality dedup aid, not a per-artifact registry.
        try writeArtifactFile(relativePath: "tasks/0/runs/0/roles/eng/a.md", content: "SAME")
        try writeArtifactFile(relativePath: "tasks/0/runs/0/roles/eng/b.md", content: "SAME")
        let s = step(artifacts: [
            Artifact(name: "A", relativePath: "tasks/0/runs/0/roles/eng/a.md"),
            Artifact(name: "B", relativePath: "tasks/0/runs/0/roles/eng/b.md"),
        ])
        let set = ActivityFeedBuilder.loadArtifactContentsForStepSync(s, workFolderURL: tempDir)
        XCTAssertEqual(set, ["SAME"])
    }

    func testEmptyArtifactFile_emptyStringIncluded() throws {
        // A 0-byte artifact reads as "" and is included — harmless because empty messages
        // never reach the feed (the builder filters them before dedup).
        try writeArtifactFile(relativePath: "tasks/0/runs/0/roles/eng/empty.md", content: "")
        let s = step(artifacts: [Artifact(name: "E", relativePath: "tasks/0/runs/0/roles/eng/empty.md")])
        let set = ActivityFeedBuilder.loadArtifactContentsForStepSync(s, workFolderURL: tempDir)
        XCTAssertTrue(set.contains(""))
    }

    func testNoArtifacts_emptySet() {
        let set = ActivityFeedBuilder.loadArtifactContentsForStepSync(step(artifacts: []), workFolderURL: tempDir)
        XCTAssertTrue(set.isEmpty)
    }

    func testNotTruncated_fullContentRetained() throws {
        // Distinguishes the raw String(contentsOf:) read from ArtifactService.readContent
        // (which truncates at 50 KB) — dedup needs the full body to match a message exactly.
        let big = String(repeating: "X", count: 60 * 1024)
        let rel = "tasks/0/runs/0/roles/eng/artifact_big.md"
        try writeArtifactFile(relativePath: rel, content: big)
        let s = step(artifacts: [Artifact(name: "Big", relativePath: rel)])

        let set = ActivityFeedBuilder.loadArtifactContentsForStepSync(s, workFolderURL: tempDir)
        XCTAssertTrue(set.contains(big), "Content must be retained untruncated (no 50 KB cap).")
    }
}
