import XCTest
@testable import NanoTeams

/// Pins three integration concerns the data-structure tests can't reach:
///
/// 1. **C-2: `stopEngineForTask` cascades through the delegation subtree.**
///    The original `stopEngine(for:)` is single-level — used by `closeTask`
///    and `removeTaskRecursively` where children are walked separately. The
///    `LLMStateDelegate`-protocol method `stopEngineForTask`, by contrast,
///    is called from `handleDelegateToTeam` on timeout / cancel / abort,
///    and in those flows depth-2+ chains can have their grandchild engines
///    survive without cascade — leaking LLM calls and orphaning awaiters.
///
/// 2. **C-3: recursive control methods are cycle-safe.** A corrupt
///    `tasks_index.json` (parent==self, or 1↔2 mutual link) would
///    stack-overflow `pauseRun` / `resumeRun` / `removeTaskRecursively` /
///    `stopEngineForTask` without the `visited: Set<Int>` guard. The
///    `TasksIndex.ancestorIDs/descendantIDs` cycle tests cover the
///    data-structure traversal; these cover the orchestrator-level
///    recursion that drives state mutation.
///
/// 3. **C-4: `stopEngine(for:)` wires through to
///    `completionAwaiter.cancelAll(taskID:)`.** Before this, dropping the
///    single line at `NTMSOrchestrator.stopEngine` line ~328 silently
///    re-introduced the original 30-min-hang regression — no test caught
///    the missing wire.
@MainActor
final class RecursiveCycleAndCascadeTests: XCTestCase, @unchecked Sendable {

    // MARK: - Helpers

    private func makeOrchestrator() -> NTMSOrchestrator {
        TestOrchestrator.make()
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-recursive-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a synthetic `WorkFolderContext` with the supplied task summaries
    /// installed in `tasksIndex.tasks`. Used by cycle tests to inject
    /// corrupted parent links without going through disk I/O — the
    /// orchestrator's `childTaskIDs(of:)` reads from `snapshot?.tasksIndex.tasks`,
    /// which is what the recursion drives off of.
    private func injectCorruptIndex(
        into store: NTMSOrchestrator,
        summaries: [TaskSummary]
    ) {
        let state = WorkFolderState(name: "test")
        let projection = WorkFolderProjection(
            state: state,
            settings: ProjectSettings(),
            teams: []
        )
        let index = TasksIndex(schemaVersion: 1, tasks: summaries, nextTaskID: 999)
        store.snapshot = WorkFolderContext(
            projection: projection,
            tasksIndex: index,
            toolDefinitions: [],
            activeTaskID: nil,
            activeTask: nil
        )
    }

    private func summary(id: Int, parent: Int?) -> TaskSummary {
        TaskSummary(
            id: id,
            title: "T#\(id)",
            status: .waiting,
            isChatMode: false,
            parentTaskID: parent
        )
    }

    /// Race the work against a hard timeout — if the recursion infinite-loops,
    /// the test fails fast instead of hanging the whole suite. Returns `true`
    /// if `work` completed within `seconds`, `false` if the timeout fired.
    /// On cycle-safe code the work returns almost immediately (visited-set
    /// check returns synchronously); the timeout exists purely to bound the
    /// blast radius of a future regression.
    private func withBoundedTimeout(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable @MainActor () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await work()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    // MARK: - C-2: stopEngineForTask cascades through descendants

    /// Pin: `stopEngineForTask(parent)` removes engines for every descendant
    /// task too — depth-2+ chains otherwise leak grandchild engines.
    /// Pre-fix: only the direct task's engine was stopped; grandchild
    /// engines kept making LLM calls until their own awaiter timed out
    /// (30 minutes) or the user closed the work folder.
    func testStopEngineForTask_cascadesAcrossDepthThreeChain() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)

        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }
        let childID = await store.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }
        let grandchildID = await store.createDelegatedTask(
            parentTaskID: childID, parentRoleID: "engineer",
            title: "GC", supervisorTask: "...",
            preferredTeamID: nil, depth: 2
        )
        guard let grandchildID else { return XCTFail("grandchild creation failed") }

        // Force engine creation at every level so `taskEngines` has entries
        // we can verify get removed.
        _ = store.engineForTask(parentID)
        _ = store.engineForTask(childID)
        _ = store.engineForTask(grandchildID)
        XCTAssertNotNil(store.taskEngines[parentID])
        XCTAssertNotNil(store.taskEngines[childID])
        XCTAssertNotNil(store.taskEngines[grandchildID])

        store.stopEngineForTask(parentID)

        XCTAssertNil(store.taskEngines[parentID],
                     "Parent engine must be torn down")
        XCTAssertNil(store.taskEngines[childID],
                     "Child engine must cascade-stop — without this, depth-1 child keeps running after the parent stops")
        XCTAssertNil(store.taskEngines[grandchildID],
                     "Grandchild engine must cascade-stop too — depth-2+ regression: grandchild was orphaned by single-level stop")
    }

    /// Pin: cascading stop also fires `cancelAll` on each descendant's
    /// awaiter — without this a `delegate_to_team` handler suspended on
    /// the grandchild's awaiter would hang past the cascade.
    func testStopEngineForTask_cancelsDescendantAwaiters() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)

        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }
        let childID = await store.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "...",
            preferredTeamID: nil, depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }

        let outcomeBox = OutcomeBox()
        let waiterTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var spins = 0
        while !store.completionAwaiter.hasWaiters(for: childID), spins < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            spins += 1
        }
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: childID),
                      "Test setup invariant: child awaiter must register before stop")

        store.stopEngineForTask(parentID)

        await waiterTask.value
        XCTAssertEqual(outcomeBox.value, .terminal(.failed),
                       "Cascading stop must wake the descendant awaiter — pre-fix, only the direct-target awaiter resumed and depth-2+ awaiters hung until 30-min timeout")
    }

    // MARK: - C-4: stopEngine(for:) → cancelAll wiring is pinned

    /// Pin: `NTMSOrchestrator.stopEngine(for:)` calls
    /// `completionAwaiter.cancelAll(taskID:)`. Reverting that single line
    /// at `NTMSOrchestrator.swift` ~line 328 silently re-introduces the
    /// original 30-min-hang regression that the auto-accept fix was
    /// chasing — `TaskCompletionAwaiterTests` exercise the awaiter
    /// directly, but no orchestrator-level test pins the wire-up.
    func testStopEngine_singleTask_cancelsRegisteredWaiter() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)

        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }
        _ = store.engineForTask(taskID)

        let outcomeBox = OutcomeBox()
        let waiterTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: taskID)
        }
        var spins = 0
        while !store.completionAwaiter.hasWaiters(for: taskID), spins < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            spins += 1
        }
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: taskID))

        store.stopEngine(for: taskID)

        await waiterTask.value
        XCTAssertEqual(outcomeBox.value, .terminal(.failed),
                       "stopEngine MUST call completionAwaiter.cancelAll(taskID:) — without that wire, registered waiters hang until external timeout")
        XCTAssertFalse(store.completionAwaiter.hasWaiters(for: taskID),
                       "cancelAll empties the per-task waiter list")
    }

    // MARK: - C-3: recursive control methods are cycle-safe

    /// Self-cycle: a `TaskSummary` whose `parentTaskID == self.id` makes
    /// `childTaskIDs(of: id)` return `[id]`. Without the visited-set
    /// guard, the recursion would call itself infinitely.
    func testPauseRun_selfCycleInTasksIndex_doesNotInfiniteLoop() async {
        let store = makeOrchestrator()
        injectCorruptIndex(into: store, summaries: [
            summary(id: 1, parent: 1)  // ← self-cycle
        ])

        let completed = await withBoundedTimeout(2.0) {
            await store.pauseRun(taskID: 1)
        }
        XCTAssertTrue(completed,
                      "pauseRun must terminate even on self-cycle — visited-set guard is the only defense against stack overflow on corrupted tasks_index.json")
    }

    /// Mutual cycle: 1↔2 (1 lists 2 as parent, 2 lists 1 as parent).
    /// Without the visited guard, `pauseRun(1)` recurses into 2 which
    /// recurses into 1 which recurses into 2…
    func testResumeRun_mutualCycleInTasksIndex_doesNotInfiniteLoop() async {
        let store = makeOrchestrator()
        injectCorruptIndex(into: store, summaries: [
            summary(id: 1, parent: 2),
            summary(id: 2, parent: 1)
        ])

        let completed = await withBoundedTimeout(2.0) {
            await store.resumeRun(taskID: 1)
        }
        XCTAssertTrue(completed,
                      "resumeRun must terminate even on mutual cycle 1↔2 — same recursion shape as pauseRun")
    }

    func testRemoveTaskRecursively_selfCycleInTasksIndex_doesNotInfiniteLoop() async {
        let store = makeOrchestrator()
        injectCorruptIndex(into: store, summaries: [
            summary(id: 7, parent: 7)
        ])

        let completed = await withBoundedTimeout(2.0) {
            await store.removeTaskRecursively(7)
        }
        XCTAssertTrue(completed,
                      "removeTaskRecursively must terminate on self-cycle — without visited guard, the bottom-up recursion calls itself indefinitely")
    }

    /// New recursive method introduced by the C-2 fix — must inherit the
    /// same cycle protection as its three siblings.
    func testStopEngineForTask_mutualCycleInTasksIndex_doesNotInfiniteLoop() async {
        let store = makeOrchestrator()
        injectCorruptIndex(into: store, summaries: [
            summary(id: 1, parent: 2),
            summary(id: 2, parent: 1)
        ])

        let completed = await withBoundedTimeout(2.0) {
            store.stopEngineForTask(1)
        }
        XCTAssertTrue(completed,
                      "stopEngineForTask was added by the C-2 cascade fix — its recursion needs the same visited-set guard as pauseRun/resumeRun/removeTaskRecursively")
    }

    // MARK: - Helpers

    @MainActor
    private final class OutcomeBox {
        var value: TaskCompletionAwaiter.WaitOutcome?
    }
}
