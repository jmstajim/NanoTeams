import XCTest
@testable import NanoTeams

/// Verifies that delegated child tasks are pulled into `loadedTasks` on the
/// three lifecycle entry points the user touches after an app restart:
///
/// - `openWorkFolder` — the cold-start path. Without descendant restore, a
///   parent task whose role previously called `delegate_to_team` shows an
///   empty activity feed and a single-layer graph until the user runs a new
///   delegation.
/// - `switchTask` — when navigating between top-level tasks, descendants of
///   the newly active task were never loaded if no run resurrected them.
/// - `removeTask` — when the active task is deleted, the repository falls
///   back to another task; that fallback's descendants need the same
///   treatment.
///
/// All tests drive the orchestrator's high-level helpers (`openWorkFolder`,
/// `createTask`, `createDelegatedTask`, `switchTask`, `removeTask`) so the
/// regression catches breakage at the call-site level — not just the helper
/// in isolation.
@MainActor
final class NTMSOrchestratorDelegationRestoreTests: XCTestCase {

    private var workFolderRoot: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-delegation-restore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workFolderRoot {
            try? FileManager.default.removeItem(at: workFolderRoot)
        }
        workFolderRoot = nil
        super.tearDown()
    }

    private func makeOrchestrator() -> NTMSOrchestrator {
        NTMSOrchestrator(
            repository: NTMSRepository(),
            searchEmbeddingClient: StubSearchEmbeddingClient()
        )
    }

    // MARK: - Scenario A: cold restart via openWorkFolder

    /// Simulates app restart: persist parent + child via one orchestrator,
    /// drop it, open a fresh orchestrator at the same folder. The child must
    /// be in `loadedTasks` immediately — before the user manually triggers
    /// any further delegation.
    func testOpenWorkFolder_restoresChildOfActiveParent() async {
        let firstStore = makeOrchestrator()
        await firstStore.openWorkFolder(workFolderRoot)
        let parentID = await firstStore.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }
        let childID = await firstStore.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "Sub-brief",
            preferredTeamID: nil, depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }

        // Rebuild — same disk, fresh in-memory state.
        let secondStore = makeOrchestrator()
        await secondStore.openWorkFolder(workFolderRoot)

        XCTAssertEqual(secondStore.activeTaskID, parentID,
                       "Parent should remain the active top-level task post-restart.")
        XCTAssertNotNil(secondStore.loadedTask(childID),
                        "Child task must be hydrated into loadedTasks on openWorkFolder, not lazily.")
        let loadedIDs = Set(secondStore.allLoadedTasksIncludingChildren.map(\.id))
        XCTAssertTrue(loadedIDs.contains(parentID))
        XCTAssertTrue(loadedIDs.contains(childID))
    }

    // MARK: - Scenario B: depth-2 restoration

    /// Three-level chain (parent → child → grandchild) must fully restore.
    /// `descendantIDs` is BFS, so as long as the helper walks every level
    /// the entire subtree lands in `loadedTasks`.
    func testOpenWorkFolder_restoresDepth2DelegationChain() async {
        let firstStore = makeOrchestrator()
        await firstStore.openWorkFolder(workFolderRoot)
        let parentID = await firstStore.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }
        let childID = await firstStore.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }
        let grandchildID = await firstStore.createDelegatedTask(
            parentTaskID: childID, parentRoleID: "engineer",
            title: "Grandchild", supervisorTask: "...",
            preferredTeamID: nil, depth: 2
        )
        guard let grandchildID else { return XCTFail("grandchild creation failed") }

        let secondStore = makeOrchestrator()
        await secondStore.openWorkFolder(workFolderRoot)

        XCTAssertNotNil(secondStore.loadedTask(childID), "Child (depth 1) missing.")
        XCTAssertNotNil(secondStore.loadedTask(grandchildID), "Grandchild (depth 2) missing.")
    }

    // MARK: - Scenario C: idempotency

    /// Calling the helper twice must not duplicate or otherwise corrupt the
    /// loaded-tasks map. `ensureTaskLoaded` short-circuits when the task is
    /// already in memory, but the helper itself shouldn't iterate twice.
    func testEnsureDelegationDescendantsLoaded_isIdempotent() async {
        let store = makeOrchestrator()
        await store.openWorkFolder(workFolderRoot)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }
        let childID = await store.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }

        // First call already happened implicitly in createDelegatedTask
        // (via ensureTaskLoaded). Call the helper once more, then again.
        await store.ensureDelegationDescendantsLoaded(of: parentID)
        await store.ensureDelegationDescendantsLoaded(of: parentID)

        let descendantIDs = store.allLoadedTasksIncludingChildren
            .map(\.id)
            .filter { $0 == childID }
        XCTAssertEqual(descendantIDs.count, 1,
                       "Repeated calls must not duplicate child entries in loadedTasks.")
    }

    /// Defensive: passing nil must be a clean no-op.
    func testEnsureDelegationDescendantsLoaded_nilTaskID_isNoOp() async {
        let store = makeOrchestrator()
        await store.openWorkFolder(workFolderRoot)
        await store.ensureDelegationDescendantsLoaded(of: nil)
        // Reaches here without trapping — the assertion is implicit.
        XCTAssertTrue(true)
    }

    // MARK: - Scenario D: switchTask after restart

    /// Two top-level tasks each with a child. After a fresh open lands the
    /// user on the second task (most-recently-created), switching to the
    /// first must hydrate ITS descendants (which weren't loaded by the open).
    func testSwitchTask_afterRestart_loadsDescendantsOfNewActive() async {
        let firstStore = makeOrchestrator()
        await firstStore.openWorkFolder(workFolderRoot)

        let aID = await firstStore.createTask(title: "A", supervisorTask: "...")
        guard let aID else { return XCTFail("A creation failed") }
        let a1ID = await firstStore.createDelegatedTask(
            parentTaskID: aID, parentRoleID: "coding_agent",
            title: "A1", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )
        guard let a1ID else { return XCTFail("A1 creation failed") }

        let bID = await firstStore.createTask(title: "B", supervisorTask: "...")
        guard let bID else { return XCTFail("B creation failed") }
        // B becomes the active top-level task here (createTask updates activeTaskID).

        let secondStore = makeOrchestrator()
        await secondStore.openWorkFolder(workFolderRoot)
        XCTAssertEqual(secondStore.activeTaskID, bID,
                       "Sanity: post-restart, the most recently created top-level task is active.")
        XCTAssertNil(secondStore.loadedTask(a1ID),
                     "Sanity: A's descendants must NOT be loaded yet — only the active task's are.")

        await secondStore.switchTask(to: aID)
        XCTAssertEqual(secondStore.activeTaskID, aID)
        XCTAssertNotNil(secondStore.loadedTask(a1ID),
                        "After switching to A, its descendant A1 must be hydrated by the switchTask hook.")
    }

    // MARK: - Scenario E: removeTask fallback hydrates new active's descendants

    /// User deletes the active task; the repository auto-selects another
    /// top-level as the new active. That fallback's descendants must be
    /// loaded too — without this, the user lands on a task whose activity
    /// feed silently lacks delegation history.
    ///
    /// Construction note: `pickFallbackActiveTaskID` walks `tasksIndex.tasks`
    /// (sorted by `updatedAt` desc) and picks the first non-`.done`. With Y
    /// created first, then Y1 (child), then X — the natural sort puts Y1
    /// ahead of Y. To ensure the fallback picks the *parent* Y (not the
    /// orphaned child), we touch Y after Y1 so its `updatedAt` is freshest
    /// among the survivors.
    func testRemoveTask_loadsDescendantsOfFallbackActive() async {
        let store = makeOrchestrator()
        await store.openWorkFolder(workFolderRoot)

        let yID = await store.createTask(title: "Y", supervisorTask: "...")
        guard let yID else { return XCTFail("Y creation failed") }
        let y1ID = await store.createDelegatedTask(
            parentTaskID: yID, parentRoleID: "coding_agent",
            title: "Y1", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )
        guard let y1ID else { return XCTFail("Y1 creation failed") }
        // Bump Y so it sorts ahead of Y1 in the index — this guarantees
        // pickFallbackActiveTaskID returns the parent.
        await store.mutateTask(taskID: yID) { task in
            task.title = "Y (touched)"
            task.updatedAt = MonotonicClock.shared.now()
        }

        let xID = await store.createTask(title: "X", supervisorTask: "...")
        guard let xID else { return XCTFail("X creation failed") }
        XCTAssertEqual(store.activeTaskID, xID, "Sanity: X is active after creation.")

        // Evict Y1 so we can prove that removeTask re-hydrates it via the
        // fallback path (otherwise the assertion below could pass simply
        // because Y1 was already in loadedTasks from createDelegatedTask).
        store.evictLoadedTask(y1ID)
        XCTAssertNil(store.loadedTask(y1ID), "Sanity: Y1 evicted before removeTask.")

        await store.removeTask(xID)

        XCTAssertEqual(store.activeTaskID, yID,
                       "Fallback should pick parent Y (newest non-done top-level after X is gone).")
        XCTAssertNotNil(store.loadedTask(y1ID),
                        "removeTask must re-hydrate descendants of the new active task.")
    }

    // MARK: - Scenario G: failure aggregation (I3)

    /// When the on-disk task.json is missing for multiple descendants (e.g. a
    /// partially-corrupted work folder where only the index remains), each
    /// `ensureTaskLoaded` call sets `lastErrorMessage` — pre-fix this clobbered
    /// every prior error, leaving the user with only the LAST failure visible
    /// and an activity feed silently rendering an incomplete tree.
    ///
    /// Post-fix: a single banner names ALL failed descendant IDs and warns the
    /// tree may be incomplete. Helper continues the loop on failure (don't
    /// abort — losing more would be worse than partial restore).
    func testEnsureDelegationDescendantsLoaded_aggregatesMultipleFailures() async {
        let store = makeOrchestrator()
        await store.openWorkFolder(workFolderRoot)

        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }
        let childAID = await store.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent",
            title: "Child A", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )
        guard let childAID else { return XCTFail("Child A creation failed") }
        let childBID = await store.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent",
            title: "Child B", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )
        guard let childBID else { return XCTFail("Child B creation failed") }

        // Corrupt the work folder: delete both child task.json files but
        // leave the index entries pointing at them. Subsequent loadTask calls
        // for either ID will throw `taskNotFound`.
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let childAFile = paths.taskJSON(taskID: childAID, ancestors: [parentID])
        let childBFile = paths.taskJSON(taskID: childBID, ancestors: [parentID])
        try? FileManager.default.removeItem(at: childAFile)
        try? FileManager.default.removeItem(at: childBFile)

        // Evict from in-memory loadedTasks so ensureTaskLoaded actually re-reads disk.
        store.evictLoadedTask(childAID)
        store.evictLoadedTask(childBID)
        store.lastErrorMessage = nil

        await store.ensureDelegationDescendantsLoaded(of: parentID)

        let banner = store.lastErrorMessage ?? ""
        XCTAssertTrue(banner.contains("#\(childAID)"),
                      "Aggregated banner must name the first failed child ID. Got: '\(banner)'")
        XCTAssertTrue(banner.contains("#\(childBID)"),
                      "Aggregated banner must name the second failed child ID — pre-fix only the LAST overwrite was visible. Got: '\(banner)'")
        XCTAssertTrue(banner.lowercased().contains("incomplete"),
                      "Banner must signal the tree is incomplete so the user understands the activity feed isn't authoritative. Got: '\(banner)'")
    }

    /// Successful restore must NOT clobber a pre-existing unrelated error
    /// banner — the helper has nothing to report.
    func testEnsureDelegationDescendantsLoaded_successfulRestore_preservesBanner() async {
        let store = makeOrchestrator()
        await store.openWorkFolder(workFolderRoot)

        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }
        _ = await store.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )

        store.lastErrorMessage = "unrelated prior error"
        await store.ensureDelegationDescendantsLoaded(of: parentID)
        XCTAssertEqual(store.lastErrorMessage, "unrelated prior error",
                       "Helper must not touch lastErrorMessage when every descendant loads successfully.")
    }

    // MARK: - Scenario F: switchTask preserves prior active's descendants

    /// `apply(_:)` intentionally preserves the old active task and its
    /// descendants in `loadedTasks` so background delegation engines stay
    /// addressable. Switching A → B → A must NOT lose A's child along the
    /// way — this is a guard against an over-eager future "evict on switch"
    /// optimization.
    func testSwitchTask_doesNotEvictPriorActiveDescendants() async {
        let store = makeOrchestrator()
        await store.openWorkFolder(workFolderRoot)

        let aID = await store.createTask(title: "A", supervisorTask: "...")
        guard let aID else { return XCTFail("A creation failed") }
        let a1ID = await store.createDelegatedTask(
            parentTaskID: aID, parentRoleID: "coding_agent",
            title: "A1", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )
        guard let a1ID else { return XCTFail("A1 creation failed") }

        let bID = await store.createTask(title: "B", supervisorTask: "...")
        guard let bID else { return XCTFail("B creation failed") }

        await store.switchTask(to: aID)
        XCTAssertNotNil(store.loadedTask(a1ID),
                        "Sanity: A's descendant present after first switchTask.")

        await store.switchTask(to: bID)
        XCTAssertNotNil(store.loadedTask(a1ID),
                        "A's descendant must survive switching away — apply(_:) preserves loadedTasks.")

        await store.switchTask(to: aID)
        XCTAssertNotNil(store.loadedTask(a1ID),
                        "A's descendant must still be present after switching back.")
    }
}
