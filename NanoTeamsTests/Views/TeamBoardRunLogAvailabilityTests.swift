import XCTest
@testable import NanoTeams

/// Pins for the run-log availability probe and for the WIRING that decides how often it
/// runs.
///
/// The defect: `TeamBoardToolbar` spelled the two answers as
/// `.disabled(store.conversationLogExists(…))` / `.disabled(store.networkLogExists(…))`
/// inside a `Menu`'s `@ViewBuilder`. SwiftUI builds menu content EAGERLY, and
/// `TeamBoardView` reads `store.activeTask` — rewritten on every `mutateTask` — so every
/// LLM token-batch commit, tool result and status change paid, on the MainActor:
/// two whole-index `parentLinks()` allocations and up to four blocking `stat(2)` calls.
///
/// Two properties, two pins (CLAUDE.md #60):
///  - the probe answers BOTH logs from ONE ancestor walk, and
///  - the toolbar no longer probes the filesystem at all.
@MainActor
final class TeamBoardRunLogAvailabilityTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - One walk, not two

    /// RED: give `runLogAvailability` a second `ancestorIDs(of:)` call (e.g. by
    /// restoring `conversationLogExists` + `networkLogExists` as its body) → the count
    /// doubles and this fails. Invisible in the RETURNED value, which is why the probe
    /// lives inside `parentLinks()` rather than beside a caller (CLAUDE.md #62).
    func testRunLogAvailability_buildsTheWholeIndexHopMapExactlyOnce() async throws {
        // A LOADED work folder, not a bare orchestrator. Without a snapshot,
        // `snapshot?.tasksIndex.ancestorIDs(of:)` short-circuits on the optional and the
        // walk never happens — measured: the mutation "walk twice" was GREEN against a
        // bare `TestOrchestrator.make()`, because the fixture never selected the branch
        // (CLAUDE.md #56, reading 3). The `openWorkFolder` below is what makes the count
        // able to move at all, and `testTheWorkProbeIsReachedAtAll` guards that claim.
        await sut.openWorkFolder(tempDir)
        TasksIndexWorkProbe.reset()
        _ = sut.runLogAvailability(taskID: 0, runID: 0)
        let builds = TasksIndexWorkProbe.parentLinksBuilds()

        XCTAssertEqual(
            builds, 1,
            "both log answers must share ONE ancestor walk — `parentLinks()` allocates a "
                + "[Int: Int] plus a Set<Int> over every task the folder has ever held, and "
                + "this ran on every body pass. Built it \(builds) times")
    }

    /// Anti-vacuum twin: without a loaded work folder the probe short-circuits before it
    /// walks anything, so the bound above would pass on a code path that does nothing.
    /// This asserts the probe is reached at all when there IS a folder.
    func testTheWorkProbeIsReachedAtAll() throws {
        let index = TasksIndex(tasks: [
            TaskSummary(id: 0, title: "root", status: .running),
            TaskSummary(id: 1, title: "child", status: .running, parentTaskID: 0)
        ])
        TasksIndexWorkProbe.reset()
        _ = index.ancestorIDs(of: 1)
        XCTAssertEqual(
            TasksIndexWorkProbe.parentLinksBuilds(), 1,
            "the single-argument `ancestorIDs(of:)` builds the hop map — if this is 0 the "
                + "probe is not wired and every bound asserted against it is vacuous")
    }

    // MARK: - The toolbar does no filesystem work (CLAUDE.md #57 — pin the wiring)

    /// RED: put `store.conversationLogExists(` back into the `.disabled(...)` argument →
    /// this fails naming the symbol, and in production the syscalls return to every body
    /// pass. A behavioural test cannot see this: both spellings render the same menu.
    func testTheToolbarDoesNotProbeTheFilesystemFromItsBody() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Views
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
        let path = "NanoTeams/Views/TeamBoard/TeamBoardToolbar.swift"
        let url = repoRoot.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "\(path) not found — the #filePath derivation is broken and every "
                          + "assertion below would pass vacuously")
        // Strip line comments: without this the pin is satisfiable by prose that merely
        // MENTIONS the forbidden call, and defeated by prose that explains it.
        let src = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let c = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<c.lowerBound])
            }
            .joined(separator: "\n")

        // Anti-vacuum FIRST: the menu items this polices must still exist, or a pin that
        // says "no filesystem probe here" is green because the whole feature was deleted.
        XCTAssertTrue(src.contains("runLogAvailability"),
                      "the toolbar no longer reads the memoized availability — if the log "
                          + "menu items were removed, remove this pin; if they were renamed, "
                          + "re-aim it (CLAUDE.md #104)")
        XCTAssertEqual(src.components(separatedBy: ".disabled(!runLogAvailability").count - 1, 2,
                       "expected exactly two log menu items gated on the memoized value")

        for forbidden in ["conversationLogExists", "networkLogExists", "fileExists"] {
            XCTAssertFalse(
                src.contains(forbidden),
                "`\(forbidden)` is back in the toolbar. Menu content is built EAGERLY, so a "
                    + "filesystem probe there runs on every body pass of a view that reads "
                    + "`store.activeTask` — i.e. on every mutateTask, on the MainActor")
        }
    }

    /// The two convenience predicates still answer correctly after being re-pointed at
    /// the shared probe — they are what `NTMSOrchestratorTests` exercises, and a wrong
    /// answer here would disable a menu item over a log that exists.
    func testTheConveniencePredicatesAgreeWithTheSharedProbe() async throws {
        await sut.openWorkFolder(tempDir)
        let pair = sut.runLogAvailability(taskID: 0, runID: 0)
        XCTAssertEqual(sut.conversationLogExists(taskID: 0, runID: 0), pair.conversation)
        XCTAssertEqual(sut.networkLogExists(taskID: 0, runID: 0), pair.network)
    }

    // MARK: - Every arm of the shared probe

    /// The three answers the probe can give, driven through real files. Without this the
    /// legacy-array arm and the no-work-folder arm are code nothing enters — the coverage
    /// ratchet flagged exactly that (`NTMSOrchestrator+RunInfrastructure.swift` 96.8% ->
    /// 96.4% on four new lines).
    func testRunLogAvailability_seesBothLogs_includingThePreJSONLArray() async throws {
        await sut.openWorkFolder(tempDir)
        let paths = NTMSPaths(workFolderRoot: tempDir)

        XCTAssertEqual(sut.runLogAvailability(taskID: 0, runID: 0), RunLogAvailability(),
                       "nothing on disk yet — both answers false")

        let legacy = paths.legacyNetworkLogJSON(taskID: 0, runID: 0)
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacy)
        XCTAssertTrue(
            sut.runLogAvailability(taskID: 0, runID: 0).network,
            "a pre-2026-08-21 run wrote a `network_log.json` ARRAY and nothing converts it; "
                + "the menu item must still offer to reveal it")

        let conversation = paths.conversationLogURL(taskID: 0, runID: 0)
        try FileManager.default.createDirectory(
            at: conversation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# log".utf8).write(to: conversation)
        XCTAssertEqual(sut.runLogAvailability(taskID: 0, runID: 0),
                       RunLogAvailability(conversation: true, network: true))
    }

    /// No work folder → no answer, and specifically not a crash or a true. The view holds
    /// this value as `@State` before its first probe, so the default has to be the safe
    /// direction: a briefly-disabled menu item whose action re-checks the URL anyway.
    func testRunLogAvailability_withNoWorkFolder_isTheEmptyAnswer() {
        let bare = TestOrchestrator.make()
        XCTAssertEqual(bare.runLogAvailability(taskID: 0, runID: 0), RunLogAvailability())
        XCTAssertFalse(RunLogAvailability().conversation)
        XCTAssertFalse(RunLogAvailability().network)
    }

}
