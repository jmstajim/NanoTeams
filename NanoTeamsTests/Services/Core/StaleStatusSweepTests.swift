import XCTest

@testable import NanoTeams

/// Tests for the startup stale-status sweep (`recoverStaleStatusesAcrossIndex`)
/// and its supporting changes:
///
/// - `ensureTaskLoaded` routes through `refreshBackgroundTaskInMemory` (the
///   in-memory tasks index moves in lockstep with the disk index) and returns
///   whether recovery fired + persisted.
/// - `apply(_:)` no longer carries `loadedTasks` across FOLDER switches (task
///   IDs are per-folder sequential ints — collisions are the norm).
/// - `openWorkFolder` sweeps every non-active index entry whose summary says
///   `.running` / `.needsSupervisorInput`, recovers it, and evicts it.
///
/// Bug being fixed: after an app restart, only the ACTIVE task was recovered —
/// every other task that was running at quit time kept its stale "Working"
/// summary in `tasks_index.json`, and the sidebar rendered it verbatim until
/// the user clicked into the task.
@MainActor
final class StaleStatusSweepTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Helpers

    private var paths: NTMSPaths { NTMSPaths(workFolderRoot: tempDir) }
    private var jsonStore: AtomicJSONStore { AtomicJSONStore() }

    private func makeStep(
        id: String = "step",
        role: Role = .supervisor,
        title: String = "Step",
        status: StepStatus
    ) -> StepExecution {
        StepExecution(id: id, role: role, title: title, status: status)
    }

    /// Shapes a task on disk as "quit mid-run": supervisor step done, worker
    /// step in `status`, worker role `.working`.
    private func plantStaleSteps(
        taskID: Int,
        workerStatus: StepStatus = .running,
        isChatMode: Bool = false
    ) async {
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(isChatMode)
            task.status = .running
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [
                self.makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done),
                self.makeStep(id: "worker", role: .softwareEngineer, title: "Work", status: workerStatus),
            ]
            task.runs = [run]
        }
    }

    /// Simulates force-quit + relaunch: fresh orchestrator over the same folder.
    private func restartOrchestrator() {
        sut = TestOrchestrator.make(embeddingClient: embeddingClient)
    }

    private func diskIndexStatus(_ taskID: Int, root: URL? = nil) -> TaskStatus? {
        let p = NTMSPaths(workFolderRoot: root ?? tempDir)
        let index = try? jsonStore.read(TasksIndex.self, from: p.tasksIndexJSON)
        return index?.tasks.first(where: { $0.id == taskID })?.status
    }

    private func memIndexStatus(_ taskID: Int) -> TaskStatus? {
        sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.status
    }

    private func diskIndexWaiting(_ taskID: Int, root: URL? = nil) -> Bool? {
        let p = NTMSPaths(workFolderRoot: root ?? tempDir)
        let index = try? jsonStore.read(TasksIndex.self, from: p.tasksIndexJSON)
        return index?.tasks.first(where: { $0.id == taskID })?.hasPendingSupervisorInput
    }

    private func memIndexWaiting(_ taskID: Int) -> Bool? {
        sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.hasPendingSupervisorInput
    }

    /// Rewrites the on-disk index row for `taskID` to the pre-field legacy shape
    /// (`hasPendingSupervisorInput` key absent). Synthesized `encode(to:)` uses
    /// `encodeIfPresent`, so a nil field round-trips as a genuinely absent key.
    private func stripWaitingFieldFromDiskIndex(_ taskID: Int) throws {
        let path = paths.tasksIndexJSON
        var index = try jsonStore.read(TasksIndex.self, from: path)
        guard let i = index.tasks.firstIndex(where: { $0.id == taskID }) else {
            return XCTFail("index row for task \(taskID) missing")
        }
        index.tasks[i].hasPendingSupervisorInput = nil
        try jsonStore.write(index, to: path)
    }

    private func diskTask(_ taskID: Int, ancestors: [Int] = [], root: URL? = nil) -> NTMSTask? {
        let p = NTMSPaths(workFolderRoot: root ?? tempDir)
        return try? jsonStore.read(NTMSTask.self, from: p.taskJSON(taskID: taskID, ancestors: ancestors))
    }

    // MARK: - A. ensureTaskLoaded → refreshBackgroundTaskInMemory

    func testEnsureTaskLoaded_recoveryFired_refreshesInMemoryIndex() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        sut.evictLoadedTask(a)
        XCTAssertEqual(memIndexStatus(a), .running, "seeding sanity: stale entry planted")

        await sut.ensureTaskLoaded(a)

        XCTAssertEqual(memIndexStatus(a), .paused,
                       "in-memory index must move in lockstep with the disk index recovery persists")
        XCTAssertEqual(diskIndexStatus(a), .paused)
        XCTAssertEqual(sut.loadedTask(a)?.runs.last?.steps.last?.status, .paused)
    }

    func testEnsureTaskLoaded_cleanTask_refreshIsContentNoOp() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        sut.evictLoadedTask(a)
        let entryBefore = sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == a })
        let errorBefore = sut.lastErrorMessage

        await sut.ensureTaskLoaded(a)

        let entryAfter = sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == a })
        XCTAssertEqual(entryBefore, entryAfter, "clean load must not perturb the index entry")
        XCTAssertEqual(sut.lastErrorMessage, errorBefore)
        XCTAssertNotNil(sut.loadedTask(a))
    }

    func testEnsureTaskLoaded_taskMissingFromIndex_appendsSummary() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        sut.evictLoadedTask(a)
        sut.snapshot?.tasksIndex.tasks.removeAll { $0.id == a }
        XCTAssertNil(memIndexStatus(a))

        await sut.ensureTaskLoaded(a)

        XCTAssertNotNil(memIndexStatus(a),
                        "refreshBackgroundTaskInMemory's upsert branch must re-append a missing summary")
    }

    func testEnsureTaskLoaded_alreadyLoaded_shortCircuits() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        XCTAssertNotNil(sut.snapshot?.loadedTasks[a], "A must be in loadedTasks (was active before B)")

        let persisted = await sut.ensureTaskLoaded(a)

        XCTAssertFalse(persisted)
        XCTAssertEqual(sut.loadedTask(a)?.runs.last?.steps.last?.status, .running,
                       "short-circuit must not recover — this is why the sweep needs its loaded-branch")
    }

    func testEnsureTaskLoaded_returnValue_truePersistedRecovery_falseCleanLoad() async {
        await sut.openWorkFolder(tempDir)
        let stale = await sut.createTask(title: "Stale", supervisorTask: "s")!
        await plantStaleSteps(taskID: stale)
        let clean = await sut.createTask(title: "Clean", supervisorTask: "c")!
        _ = await sut.createTask(title: "Active", supervisorTask: "x")!
        sut.evictLoadedTask(stale)
        sut.evictLoadedTask(clean)

        let recoveredStale = await sut.ensureTaskLoaded(stale)
        let recoveredClean = await sut.ensureTaskLoaded(clean)

        XCTAssertTrue(recoveredStale, "recovery fired + persisted → true")
        XCTAssertFalse(recoveredClean, "clean load → false")
    }

    // MARK: - B. Sweep — core paths

    func testRestart_backgroundRunningTask_pausedEverywhere() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(memIndexStatus(a), .paused, "sidebar source of truth must show Paused")
        XCTAssertEqual(diskIndexStatus(a), .paused)
        let summaries = sut.taskSummaries(filter: .all)
        XCTAssertEqual(summaries.first(where: { $0.id == a })?.status, .paused)
        let onDisk = diskTask(a)
        XCTAssertEqual(onDisk?.runs.last?.steps.last?.status, .paused, "task.json steps recovered")
        XCTAssertEqual(onDisk?.runs.last?.roleStatuses["worker"], .idle, "working role reset to idle")
        XCTAssertNil(sut.snapshot?.loadedTasks[a], "swept task must be evicted from memory")
        XCTAssertEqual(sut.taskEngineStates[a], .paused, "engine state seeded so TeamBoard shows Resume")
    }

    func testRestart_backgroundNSITask_pausedAndEvictable() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(false)
            let step = StepExecution(
                id: "worker", role: .softwareEngineer, title: "Work",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Which DB?"
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["worker": .working])]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(memIndexStatus(a), .paused)
        XCTAssertEqual(diskIndexStatus(a), .paused)
        XCTAssertEqual(sut.taskEngineStates[a], .paused,
                       "must seed .paused, NOT .needsSupervisorInput — NSI would block eviction via isTaskEngineActive")
        XCTAssertNil(sut.snapshot?.loadedTasks[a], "NSI task must still be evictable")
        // The fix, in one place: parking rewrote `status`, but the index row must
        // still carry the durable waiting fact — `.paused` alone reads as answered,
        // which is what relit every already-read chat after a restart.
        XCTAssertEqual(memIndexWaiting(a), true,
                       "swept row must stamp hasPendingSupervisorInput — the sidebar keys on it, not on status")
        XCTAssertEqual(diskIndexWaiting(a), true)
    }

    /// The one-time backfill for rows written before `hasPendingSupervisorInput`
    /// existed: a legacy `.paused` row can hide an unanswered question, so the
    /// widened sweep filter must select it once, stamp the field, and converge.
    /// Without this fixture the `!supervisorInputStateIsKnown` clause of the
    /// filter has no test that traverses it (CLAUDE.md #57).
    func testSweep_legacyPausedRow_backfilledInOneOpenPass() async throws {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(true)
            let step = StepExecution(
                id: "assistant", role: .softwareEngineer, title: "Chat",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Here is my reply."
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["assistant": .working])]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        // First restart parks the task; the second sees the legacy-shaped row.
        restartOrchestrator()
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(diskIndexStatus(a), .paused, "precondition: parked by the sweep")
        try stripWaitingFieldFromDiskIndex(a)

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexWaiting(a), true,
                       "legacy .paused row must be backfilled in the first open pass")
        XCTAssertEqual(memIndexWaiting(a), true)
        XCTAssertEqual(diskIndexStatus(a), .paused, "backfill must not disturb the parked status")
        XCTAssertNil(sut.snapshot?.loadedTasks[a], "backfill pass must still evict")
    }

    /// The probe branch of the backfill (task already loaded, recovery a no-op):
    /// disk alone is not convergence — the sidebar reads `snapshot.tasksIndex`, so
    /// the in-memory row must move in the same pass, not on the next launch.
    func testInProcessReopen_legacyRow_probeBranchConvergesMemoryToo() async throws {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(true)
            // Already-parked shape: nothing for recovery to do, so the sweep's
            // probe branch takes its convergence path instead of the mutate path.
            let step = StepExecution(
                id: "assistant", role: .softwareEngineer, title: "Chat",
                status: .paused,
                needsSupervisorInput: true,
                supervisorQuestion: "Reply."
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["assistant": .idle])]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        XCTAssertNotNil(sut.snapshot?.loadedTasks[a], "precondition: A resident (in-process)")
        try stripWaitingFieldFromDiskIndex(a)

        // Same orchestrator, same folder: the index is re-read from disk (legacy
        // row), while A survives in `loadedTasks` — the probe branch's shape.
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexWaiting(a), true)
        XCTAssertEqual(memIndexWaiting(a), true,
                       "the probe-branch backfill must converge the in-memory row in the same pass")
    }

    /// The `.failed` half of the widened filter: a failed run answers "not waiting",
    /// and stamping that false is what stops the row from being re-selected on
    /// every open (the filter is self-terminating, not a standing tax).
    func testSweep_legacyFailedRow_backfilledAsNotWaiting() async throws {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(false)
            task.status = .failed
            let step = StepExecution(
                id: "worker", role: .softwareEngineer, title: "Work", status: .failed)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["worker": .failed])]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        try stripWaitingFieldFromDiskIndex(a)

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexWaiting(a), false,
                       "legacy .failed row must converge to a KNOWN not-waiting, not stay unknown")
        XCTAssertEqual(diskIndexStatus(a), .failed,
                       "recovery must not resurrect a failed task")
    }

    func testInProcessReopen_staleLoadedTask_recoveredEvictedSeeded() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        XCTAssertNotNil(sut.snapshot?.loadedTasks[a], "precondition: A loaded (in-process, not evicted)")

        // Same orchestrator, same folder — `apply` preserves loadedTasks, so
        // the sweep must take its loaded-branch (ensureTaskLoaded short-circuits).
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(memIndexStatus(a), .paused)
        XCTAssertEqual(diskIndexStatus(a), .paused)
        XCTAssertNil(sut.snapshot?.loadedTasks[a], "loaded-branch must still evict after recovery")
        XCTAssertEqual(sut.taskEngineStates[a], .paused,
                       "loaded-branch must seed engine state — stopAllEngines wiped it and switchTask never re-seeds (neither path)")
    }

    func testRestart_activeTask_handledByExistingBlock_notSweep() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.activeTaskID, a)
        XCTAssertEqual(sut.activeTask?.runs.last?.steps.last?.status, .paused,
                       "active task recovered by the pre-existing openWorkFolder block")
        XCTAssertEqual(memIndexStatus(a), .paused)
        XCTAssertNotNil(sut.activeTask, "active task is never evicted")
    }

    // MARK: - C. Corner cases

    func testRestart_chatModeSteadyStateRunning_untouched() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "Chat", supervisorTask: "hi")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0)
            run.steps = [self.makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done)]
            task.runs = [run]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        XCTAssertEqual(diskIndexStatus(a), .running, "chat steady-state derives .running by design")
        let updatedAtBefore = diskTask(a)?.updatedAt

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        let entry = sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == a })
        XCTAssertEqual(entry?.status, .running, "steady-state chat summary must stay .running")
        XCTAssertEqual(entry?.isChatMode, true)
        XCTAssertEqual(diskTask(a)?.updatedAt, updatedAtBefore,
                       "no-op recovery must not churn updatedAt / write task.json")
    }

    func testRestart_chatModeQuitMidStream_recovered() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "Chat", supervisorTask: "hi")!
        await plantStaleSteps(taskID: a, isChatMode: true)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        let entry = sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == a })
        XCTAssertEqual(entry?.status, .paused, "a chat task genuinely quit mid-stream IS recovered")
        XCTAssertEqual(entry?.isChatMode, true, "isChatMode survives so the display override still shows Chat")
    }

    func testRestart_activeTaskDelegationChild_recoveredNotEvicted() async {
        await sut.openWorkFolder(tempDir)
        let parent = await sut.createTask(title: "Parent", supervisorTask: "p")!
        let child = await sut.createDelegatedTask(
            parentTaskID: parent, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "sub", preferredTeamID: nil, depth: 1
        )!
        await plantStaleSteps(taskID: child)

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.activeTaskID, parent)
        XCTAssertEqual(sut.loadedTask(child)?.runs.last?.steps.last?.status, .paused,
                       "descendant load recovers the child")
        XCTAssertNotNil(sut.snapshot?.loadedTasks[child],
                        "child of the ACTIVE task must stay loaded (feed + graph need it)")
        XCTAssertEqual(memIndexStatus(child), .paused,
                       "change 1: descendant load also refreshes the in-memory index entry")
        XCTAssertEqual(diskIndexStatus(child), .paused)
    }

    func testRestart_backgroundParentDelegationChild_recoveredAndEvicted() async {
        await sut.openWorkFolder(tempDir)
        let parent = await sut.createTask(title: "Parent", supervisorTask: "p")!
        let child = await sut.createDelegatedTask(
            parentTaskID: parent, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "sub", preferredTeamID: nil, depth: 1
        )!
        await plantStaleSteps(taskID: child)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexStatus(child), .paused,
                       "child of a BACKGROUND parent recovered via the nested-path ancestors walk")
        XCTAssertEqual(diskTask(child, ancestors: [parent])?.runs.last?.steps.last?.status, .paused)
        XCTAssertNil(sut.snapshot?.loadedTasks[child],
                     "not a descendant of the active task → evicted")
    }

    func testSweep_liveEngine_skipped() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        sut.taskEngines[a] = TeamEngine()

        await sut.recoverStaleStatusesAcrossIndex(folderURL: tempDir)

        XCTAssertEqual(sut.loadedTask(a)?.runs.last?.steps.last?.status, .running,
                       "a task with a live engine must never be touched by the sweep")
        XCTAssertEqual(diskIndexStatus(a), .running)
        sut.taskEngines[a] = nil
    }

    func testSweep_degenerateEntry_noRuns_noCrashNoWrite() async {
        // A created-but-never-started task has NO runs; `NTMSTask`'s stored
        // status defaults to `.running`, so its derived summary is honestly
        // `.running`. The sweep must load it without crashing, find nothing to
        // recover (no runs), skip the convergence write (derived == entry),
        // and evict it.
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "NeverStarted", supervisorTask: "a")!
        _ = await sut.createTask(title: "Active", supervisorTask: "b")!
        XCTAssertEqual(diskIndexStatus(a), .running, "seeding sanity: no-runs task derives .running")
        let updatedAtBefore = diskTask(a)?.updatedAt

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexStatus(a), .running,
                       ".running IS the honest derived status for a no-runs task — no rewrite")
        XCTAssertEqual(diskTask(a)?.updatedAt, updatedAtBefore,
                       "no-op pass must not write task.json")
        XCTAssertNil(sut.snapshot?.loadedTasks[a], "still evicted, no crash")
    }

    func testSweep_missingTaskJSON_continuesToNextTask() async {
        await sut.openWorkFolder(tempDir)
        let broken = await sut.createTask(title: "Broken", supervisorTask: "x")!
        await plantStaleSteps(taskID: broken)
        let healthy = await sut.createTask(title: "Healthy", supervisorTask: "y")!
        await plantStaleSteps(taskID: healthy)
        _ = await sut.createTask(title: "Active", supervisorTask: "z")!
        try! FileManager.default.removeItem(at: paths.taskJSON(taskID: broken))

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexStatus(healthy), .paused,
                       "one unreadable task must not abort the sweep")
        XCTAssertNil(sut.snapshot?.loadedTasks[healthy])
        XCTAssertTrue(sut.lastErrorMessage?.contains("#\(broken)") ?? false,
                      "aggregate banner must name the failed task; got: \(sut.lastErrorMessage ?? "nil")")
    }

    func testSweep_folderURLMismatch_bailsImmediately() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        let otherDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherDir) }

        await sut.recoverStaleStatusesAcrossIndex(folderURL: otherDir)

        XCTAssertEqual(sut.loadedTask(a)?.runs.last?.steps.last?.status, .running,
                       "mismatched folderURL must bail before any write")
        XCTAssertEqual(diskIndexStatus(a), .running)
    }

    func testSweep_noStaleEntries_noOp() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        let errorBefore = sut.lastErrorMessage
        let loadedBefore = sut.snapshot?.loadedTasks.keys.sorted()

        await sut.recoverStaleStatusesAcrossIndex(folderURL: tempDir)

        XCTAssertEqual(sut.lastErrorMessage, errorBefore)
        XCTAssertEqual(sut.snapshot?.loadedTasks.keys.sorted(), loadedBefore,
                       "no stale entries → no loads, no evictions")
        XCTAssertNotEqual(memIndexStatus(a), .paused)
    }

    func testSweep_multipleStale_indexStaysSortedByUpdatedAt() async {
        await sut.openWorkFolder(tempDir)
        for title in ["A1", "A2", "A3"] {
            let id = await sut.createTask(title: title, supervisorTask: title)!
            await plantStaleSteps(taskID: id)
        }
        _ = await sut.createTask(title: "Zzz", supervisorTask: "x")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        let dates = sut.snapshot?.tasksIndex.tasks.map(\.updatedAt) ?? []
        XCTAssertEqual(dates, dates.sorted(by: >),
                       "index must stay sorted by updatedAt desc after multi-task recovery")
        let recovered = sut.snapshot?.tasksIndex.tasks.filter { ["A1", "A2", "A3"].contains($0.title) } ?? []
        XCTAssertEqual(recovered.count, 3)
        for entry in recovered {
            XCTAssertEqual(entry.status, .paused, "\(entry.title) must be recovered")
        }
    }

    func testRestart_NSIQuestionSurvivesSweep_restoredOnResume() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(false)
            let step = StepExecution(
                id: "worker", role: .softwareEngineer, title: "Work",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Which DB?"
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["worker": .working])]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        // Sweep recovered the step to .paused but preserved the question payload.
        let onDisk = diskTask(a)?.runs.last?.steps.first
        XCTAssertEqual(onDisk?.status, .paused)
        XCTAssertEqual(onDisk?.needsSupervisorInput, true, "flag survives recovery")
        XCTAssertEqual(onDisk?.supervisorQuestion, "Which DB?", "question text survives recovery")
    }

    func testFolderSwitch_collidingTaskID_ghostNotWrittenIntoNewFolder() async {
        let folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }

        // Folder B: background task id 0 stale .running + active task id 1.
        await sut.openWorkFolder(folderB)
        let b0 = await sut.createTask(title: "B-Task", supervisorTask: "b0")!
        await plantStaleSteps(taskID: b0)
        _ = await sut.createTask(title: "B-Active", supervisorTask: "b1")!

        // Folder A (tempDir): ghost with the SAME id 0, loaded in memory.
        await sut.openWorkFolder(tempDir)
        let a0 = await sut.createTask(title: "A-Ghost", supervisorTask: "a0")!
        XCTAssertEqual(a0, b0, "seeding sanity: both folders' first task must share an id")
        await plantStaleSteps(taskID: a0)
        _ = await sut.createTask(title: "A-Active", supervisorTask: "a1")!
        XCTAssertNotNil(sut.snapshot?.loadedTasks[a0], "ghost is loaded before the switch")

        // Switch to folder B: apply() must NOT carry folder A's loadedTasks, and
        // the sweep must recover folder B's REAL task 0 from B's disk.
        await sut.openWorkFolder(folderB)

        let b0OnDisk = diskTask(b0, root: folderB)
        XCTAssertEqual(b0OnDisk?.title, "B-Task",
                       "folder B's task.json must never be overwritten by folder A's ghost")
        XCTAssertEqual(b0OnDisk?.runs.last?.steps.last?.status, .paused,
                       "folder B's own task recovered from B's disk")
        XCTAssertEqual(
            sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == b0 })?.title, "B-Task",
            "in-memory index must carry folder B's summary, not the ghost's"
        )
        XCTAssertNil(sut.snapshot?.loadedTasks[a0],
                     "folder A's loadedTasks must not survive the folder switch")
    }

    /// Toggles owner-write on a task's internal directory so `updateTaskOnly`'s
    /// task.json write fails deterministically (0o500 = r-x).
    private func setReadOnly(_ url: URL, _ readOnly: Bool) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: readOnly ? 0o500 : 0o700],
            ofItemAtPath: url.path
        )
    }

    // MARK: - E. Persist-failure paths (review gaps G1/G3 + loaded-branch aggregation)

    func testEnsureTaskLoaded_recoveryPersistFails_returnsFalseAndWarnsDivergence() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        sut.evictLoadedTask(a)
        let dir = paths.internalTaskDir(taskID: a)
        setReadOnly(dir, true)
        defer { setReadOnly(dir, false) }

        let persisted = await sut.ensureTaskLoaded(a)

        XCTAssertFalse(persisted, "recovery fired but persist failed → must return false")
        XCTAssertTrue(sut.lastErrorMessage?.contains("diverge") ?? false,
                      "divergence warning must surface; got: \(sut.lastErrorMessage ?? "nil")")
        XCTAssertEqual(memIndexStatus(a), .paused, "in-memory state IS recovered")
        XCTAssertEqual(diskIndexStatus(a), .running, "disk genuinely diverged")
    }

    func testSweep_persistFailure_aggregatedNotLeakedAsDivergenceBanner() async {
        // ensureTaskLoaded's recovery-persist fails AND the sweep's convergence
        // retry fails too → the task must land in the aggregate banner; the
        // per-task "may diverge" banner must NOT leak past the sweep.
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        sut.evictLoadedTask(a)
        let dir = paths.internalTaskDir(taskID: a)
        setReadOnly(dir, true)
        defer { setReadOnly(dir, false) }

        await sut.recoverStaleStatusesAcrossIndex(folderURL: tempDir)

        let banner = sut.lastErrorMessage ?? ""
        XCTAssertTrue(banner.contains("Could not recover status for 1 task(s): #\(a)"),
                      "failed persist must be aggregated; got: \(banner)")
        XCTAssertFalse(banner.contains("diverge"),
                       "per-task divergence banner must be owned (restored) by the sweep")
    }

    func testSweep_loadedBranchPersistFailure_aggregated() async {
        // The loaded-branch's mutateTask disk write fails → the task must be
        // collected into the aggregate banner (not silently dropped), while the
        // in-memory commit (which mutateTask applies before the detached write)
        // keeps the sidebar honest.
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        XCTAssertNotNil(sut.snapshot?.loadedTasks[a], "precondition: loaded-branch will run")
        let dir = paths.internalTaskDir(taskID: a)
        setReadOnly(dir, true)
        defer { setReadOnly(dir, false) }

        await sut.recoverStaleStatusesAcrossIndex(folderURL: tempDir)

        XCTAssertTrue(sut.lastErrorMessage?.contains("#\(a)") ?? false,
                      "loaded-branch persist failure must reach the aggregate banner; got: \(sut.lastErrorMessage ?? "nil")")
        XCTAssertEqual(memIndexStatus(a), .paused, "in-memory committed before the failed write")
        XCTAssertEqual(diskIndexStatus(a), .running, "disk index stayed stale — divergence is reported, not silent")
    }

    func testSweep_twoFailures_aggregateBannerNamesBoth() async {
        await sut.openWorkFolder(tempDir)
        let broken1 = await sut.createTask(title: "Broken1", supervisorTask: "x")!
        await plantStaleSteps(taskID: broken1)
        let broken2 = await sut.createTask(title: "Broken2", supervisorTask: "y")!
        await plantStaleSteps(taskID: broken2)
        let healthy = await sut.createTask(title: "Healthy", supervisorTask: "z")!
        await plantStaleSteps(taskID: healthy)
        _ = await sut.createTask(title: "Active", supervisorTask: "w")!
        try! FileManager.default.removeItem(at: paths.taskJSON(taskID: broken1))
        try! FileManager.default.removeItem(at: paths.taskJSON(taskID: broken2))

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        let banner = sut.lastErrorMessage ?? ""
        XCTAssertTrue(banner.contains("2 task(s)"), "both failures aggregated; got: \(banner)")
        XCTAssertTrue(banner.contains("#\(broken1)") && banner.contains("#\(broken2)"),
                      "banner must name BOTH failed tasks (not last-writer-wins); got: \(banner)")
        XCTAssertEqual(diskIndexStatus(healthy), .paused, "healthy task still recovered")
    }

    func testApply_sameFolder_neverActiveLoadedTaskSurvivesMutateWorkFolder() async {
        // Pins apply()'s FIRST preservation branch (general loadedTasks carryover
        // for never-active tasks) under the new same-folder gate — delegation
        // children and ensureTaskLoaded-loaded background tasks must survive any
        // mutateWorkFolder-triggered apply, or every subsequent mutateTask on
        // them silently no-ops (CLAUDE.md §7).
        await sut.openWorkFolder(tempDir)
        _ = await sut.createTask(title: "Active", supervisorTask: "a")!
        let c = await sut.createTask(title: "C", supervisorTask: "c", preferredTeamID: nil, makeActive: false)!
        await sut.ensureTaskLoaded(c)
        XCTAssertNotNil(sut.loadedTask(c), "precondition: C loaded, never active")

        await sut.mutateWorkFolder { $0.settings.context = "touched" }

        XCTAssertNotNil(sut.loadedTask(c),
                        "same-folder apply must preserve loadedTasks for never-active tasks")
    }

    // MARK: - F. Review-fix corners (mixed branches, banner ownership, folder lifecycle)

    func testSweep_mixedBranches_partialFailure_aggregateAndRecoveryCoexist() async {
        // One stale task takes the loaded-branch and fails its persist; another
        // takes the else-branch and recovers cleanly — in the SAME pass. The
        // aggregate must name only the broken one, and the per-iteration banner
        // restore must not leak the broken task's failure into the healthy
        // task's iteration (or vice versa).
        await sut.openWorkFolder(tempDir)
        let broken = await sut.createTask(title: "Broken", supervisorTask: "a")!
        await plantStaleSteps(taskID: broken)
        let healthy = await sut.createTask(title: "Healthy", supervisorTask: "c")!
        await plantStaleSteps(taskID: healthy)
        _ = await sut.createTask(title: "Active", supervisorTask: "b")!
        sut.evictLoadedTask(healthy)                       // healthy → else-branch
        XCTAssertNotNil(sut.snapshot?.loadedTasks[broken], "broken → loaded-branch")
        let dir = paths.internalTaskDir(taskID: broken)
        setReadOnly(dir, true)
        defer { setReadOnly(dir, false) }

        await sut.recoverStaleStatusesAcrossIndex(folderURL: tempDir)

        let banner = sut.lastErrorMessage ?? ""
        XCTAssertTrue(banner.contains("1 task(s): #\(broken)"),
                      "only the broken task aggregates; got: \(banner)")
        XCTAssertFalse(banner.contains("#\(healthy)"))
        XCTAssertEqual(diskIndexStatus(healthy), .paused, "healthy task fully recovered on disk")
        XCTAssertEqual(memIndexStatus(broken), .paused, "broken task honest in memory")
        XCTAssertEqual(diskIndexStatus(broken), .running, "broken task diverged on disk — reported, not silent")
    }

    func testSweep_cleanPass_preservesPreexistingBanner() async {
        // The sweep snapshots/restores the banner per iteration and emits an
        // aggregate ONLY on failure — a clean pass must hand back whatever
        // banner another path had set before it ran.
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        sut.evictLoadedTask(a)
        sut.lastErrorMessage = "pre-existing banner from another path"

        await sut.recoverStaleStatusesAcrossIndex(folderURL: tempDir)

        XCTAssertEqual(memIndexStatus(a), .paused, "task recovered")
        XCTAssertEqual(sut.lastErrorMessage, "pre-existing banner from another path",
                       "clean sweep must not consume or clobber an unrelated banner")
    }

    func testRestart_noActiveTask_backgroundStaleStillRecovered() async {
        // Watchtower state: no active task at all (activeTaskID == nil). The
        // pre-existing recovery block has nothing to do; the sweep must still
        // recover every stale background task.
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        await sut.switchTask(to: nil)

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertNil(sut.activeTaskID, "precondition: restart restores the no-selection state")
        XCTAssertEqual(diskIndexStatus(a), .paused)
        XCTAssertEqual(memIndexStatus(a), .paused)
        XCTAssertNil(sut.snapshot?.loadedTasks[a], "evicted")
    }

    func testFolderRoundTrip_staleTaskHealedOnReturn_noGhostsEitherWay() async {
        // A → B → A round-trip: leaving A clears its loadedTasks (apply gating);
        // returning to A finds the in-session stale task on disk and heals it
        // via the else-branch. Nothing from either folder bleeds into the other.
        let folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }

        await sut.openWorkFolder(tempDir)
        let a0 = await sut.createTask(title: "A-Stale", supervisorTask: "a0")!
        await plantStaleSteps(taskID: a0)
        let a1 = await sut.createTask(title: "A-Active", supervisorTask: "a1")!
        XCTAssertNotNil(sut.snapshot?.loadedTasks[a0])

        await sut.openWorkFolder(folderB)
        XCTAssertNil(sut.snapshot?.loadedTasks[a0], "leaving A clears its loadedTasks")

        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.activeTaskID, a1, "A's active selection survives the round-trip")
        XCTAssertEqual(diskIndexStatus(a0), .paused,
                       "on return the sweep heals the stale task from A's own disk (else-branch)")
        XCTAssertEqual(memIndexStatus(a0), .paused)
        XCTAssertNil(sut.snapshot?.loadedTasks[a0], "healed and evicted — no ghost retained")
    }

    func testScheduler_reconcileWithoutOpenFolder_noOpNoCrash() async {
        // Pins the new `guard let folderURL = workFolderURL` entry guard:
        // calling the reconcile pass before any folder is open must be inert.
        await sut.reconcileMissedRecurrences()

        XCTAssertNil(sut.lastErrorMessage)
        XCTAssertNil(sut.snapshot)
    }

    func testRestart_staleRecurringTaskNotDue_recurrenceUntouched() async {
        // Complement to the missed-slot test: a NOT-due recurrence must pass
        // through the sweep + scheduler open sequence with its schedule intact —
        // recovery touches statuses, never recurrence fields.
        let future = Date(timeIntervalSinceNow: 3600)
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        await sut.mutateTask(taskID: a) { task in
            task.recurrence = TaskRecurrence(
                rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: future
            )
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexStatus(a), .paused, "status recovered")
        let onDisk = diskTask(a)
        XCTAssertEqual(onDisk?.runs.count, 1, "not due — nothing fired")
        XCTAssertEqual(onDisk?.recurrence?.isEnabled, true)
        XCTAssertEqual(onDisk?.recurrence?.nextFireAt?.timeIntervalSince1970 ?? 0,
                       future.timeIntervalSince1970, accuracy: 1.0,
                       "schedule must be untouched by recovery (no reschedule, no disable)")
    }

    // MARK: - D. Additional corners

    func testRestart_multipleRuns_historicalStaleStepsAlsoRecovered() async {
        // StatusRecoveryService iterates ALL runs — a stale step left in an
        // older run (e.g. two crashes in a row) must not survive just because
        // only the last run drives the derived summary.
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(false)
            var run0 = Run(id: 0, roleStatuses: ["worker": .working])
            run0.steps = [self.makeStep(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
            var run1 = Run(id: 1, roleStatuses: ["worker": .working])
            run1.steps = [self.makeStep(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run0, run1]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        let onDisk = diskTask(a)
        XCTAssertEqual(onDisk?.runs.count, 2)
        XCTAssertEqual(onDisk?.runs[0].steps.first?.status, .paused, "historical run recovered too")
        XCTAssertEqual(onDisk?.runs[1].steps.first?.status, .paused)
        XCTAssertEqual(diskIndexStatus(a), .paused)
    }

    func testRestart_failedTask_notSwept() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(false)
            var run = Run(id: 0, roleStatuses: ["worker": .failed])
            run.steps = [
                self.makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done),
                self.makeStep(id: "worker", role: .softwareEngineer, title: "Work", status: .failed),
            ]
            task.runs = [run]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        XCTAssertEqual(diskIndexStatus(a), .failed, "seeding sanity")
        let updatedAtBefore = diskTask(a)?.updatedAt

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexStatus(a), .failed, "failed tasks are terminal — sweep must not touch them")
        XCTAssertEqual(diskTask(a)?.updatedAt, updatedAtBefore, "not even loaded-and-rewritten")
        XCTAssertNil(sut.snapshot?.loadedTasks[a])
    }

    func testRestart_closedTaskWithStaleSteps_convergesToDoneNotPaused() async {
        // Crash-mid-close shape: closeTask normally stops the engine, so a
        // closed task with a .running step only exists after a crash between
        // setting closedAt and the steps settling. `derivedStatusFromActiveRun`
        // deliberately refuses to call a live-looking run "Done"
        // (closedAt != nil && !hasRunning guard), so the summary reads .running
        // and the sweep picks it up — recovery pauses the step, after which
        // closedAt dominates and the summary converges to an honest .done
        // (NOT .paused: the sweep must not resurrect a closed task).
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(false)
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [self.makeStep(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run]
            task.closedAt = MonotonicClock.shared.now()
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!
        XCTAssertEqual(diskIndexStatus(a), .running,
                       "seeding sanity: a live-looking step beats closedAt in the derived status")

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexStatus(a), .done,
                       "after recovery closedAt dominates — converged to Done, not resurrected as Paused")
        let onDisk = diskTask(a)
        XCTAssertNotNil(onDisk?.closedAt, "closedAt must survive recovery")
        XCTAssertEqual(onDisk?.runs.last?.steps.first?.status, .paused, "the stale step itself is recovered")
        XCTAssertNil(sut.snapshot?.loadedTasks[a], "evicted")
    }

    func testSweep_secondPassIsNoOp_idempotent() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        await sut.recoverStaleStatusesAcrossIndex(folderURL: tempDir)
        XCTAssertEqual(memIndexStatus(a), .paused, "first pass recovers")
        let updatedAtAfterFirst = diskTask(a)?.updatedAt

        await sut.recoverStaleStatusesAcrossIndex(folderURL: tempDir)

        XCTAssertEqual(diskTask(a)?.updatedAt, updatedAtAfterFirst,
                       "second pass must find nothing stale — no churn")
        XCTAssertNil(sut.snapshot?.loadedTasks[a], "stays evicted")
    }

    func testRestart_disabledAutovisorManager_parkedNSI_recoveredLikeAnyTask() async {
        // The manager parks at .needsSupervisorInput whenever idle. With the
        // feature DISABLED at next launch, ensureAutovisorTask never touches it
        // — the sweep is the only thing standing between the manager and a
        // permanently stale "waiting" summary. It is deliberately NOT
        // special-cased.
        await sut.openWorkFolder(tempDir)
        let mgr = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = mgr }
        await sut.ensureTaskLoaded(mgr)
        await sut.mutateTask(taskID: mgr) { task in
            let step = StepExecution(
                id: "autovisor", role: .softwareEngineer, title: "Autovisor",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Parked — waiting for events."
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["autovisor": .working])]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexStatus(mgr), .paused, "manager recovered like any other task")
        XCTAssertNil(sut.snapshot?.loadedTasks[mgr], "and evicted")
        XCTAssertFalse(sut.taskSummaries(filter: .all).contains(where: { $0.id == mgr }),
                       "manager stays hidden from the sidebar regardless")
    }

    func testRestart_staleRecurringTask_sweepAndReconcileCoexist() async {
        // A recurring task that was running at quit time with a missed slot:
        // the sweep (runs first) recovers the status; reconcileMissedRecurrences
        // (runs right after, inside startAutomationScheduler) advances the slot
        // WITHOUT firing. Both passes load-then-evict the same task — they must
        // compose, not fight.
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await plantStaleSteps(taskID: a)
        await sut.mutateTask(taskID: a) { task in
            task.recurrence = TaskRecurrence(
                rule: .interval(seconds: 3600),
                isEnabled: true,
                nextFireAt: Date(timeIntervalSinceNow: -7200)  // missed while "closed"
            )
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexStatus(a), .paused, "sweep recovered the status")
        let onDisk = diskTask(a)
        XCTAssertEqual(onDisk?.runs.count, 1, "missed slot is skipped, not fired — no new run")
        XCTAssertEqual(onDisk?.recurrence?.isEnabled, true)
        if let next = onDisk?.recurrence?.nextFireAt {
            XCTAssertGreaterThan(next, Date(), "reconcile advanced the slot to the future")
        } else {
            XCTFail("recurrence must still have a future slot")
        }
        XCTAssertNil(sut.snapshot?.loadedTasks[a], "evicted after both passes")
    }

    func testSweep_indexSaysRunningButStepsDone_diskIndexConverges() async {
        await sut.openWorkFolder(tempDir)
        let a = await sut.createTask(title: "A", supervisorTask: "a")!
        await sut.mutateTask(taskID: a) { task in
            task.setStoredChatMode(false)
            var run = Run(id: 0, roleStatuses: ["worker": .done])
            run.steps = [
                self.makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done),
                self.makeStep(id: "worker", role: .softwareEngineer, title: "Work", status: .done),
            ]
            task.runs = [run]
        }
        _ = await sut.createTask(title: "B", supervisorTask: "b")!

        // Crash-window mismatch: hand-patch the DISK index to claim .running.
        var index = try! jsonStore.read(TasksIndex.self, from: paths.tasksIndexJSON)
        let i = index.tasks.firstIndex(where: { $0.id == a })!
        index.tasks[i] = TaskSummary(id: a, title: "A", status: .running)
        try! jsonStore.write(index, to: paths.tasksIndexJSON)

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(diskIndexStatus(a), .needsSupervisorAcceptance,
                       "recovery is a no-op here, so the sweep's convergence write must fix the disk index")
        XCTAssertEqual(memIndexStatus(a), .needsSupervisorAcceptance)
        XCTAssertNil(sut.snapshot?.loadedTasks[a])
    }

    /// End-to-end proof that the destroyed-generation heal reaches a `task.json` already
    /// sitting on disk — i.e. that an existing wedged folder unwedges on the next launch.
    ///
    /// The wedge: `restartRole` reset the synthetic `team_generation_*` step to `.pending`
    /// with no tool calls and left a phantom `roleStatuses` key. That derives `.running`
    /// forever with a dead engine, so the sweep DOES visit it (its filter is
    /// `.running` / `.needsSupervisorInput`) — and before the fix `recoverStaleStatuses`
    /// returned `false`, so it `continue`d and the task stayed wedged across every
    /// relaunch.
    func testSweep_wedgedGenerationStepOnDisk_isHealedAndStopsDerivingRunning() async {
        await sut.openWorkFolder(tempDir)
        let wedged = await sut.createTask(title: "Gen", supervisorTask: "build it")!
        let generationStepID = "\(StepExecution.teamGenerationIDPrefix)WEDGED"
        await sut.mutateTask(taskID: wedged) { task in
            task.setStoredChatMode(false)
            var run = Run(id: 0)
            run.steps = [
                self.makeStep(
                    id: generationStepID, role: .supervisor, title: "Generate Team",
                    status: .pending)
            ]
            run.roleStatuses = ["supervisor": .done, generationStepID: .idle]
            task.runs = [run]
        }
        // A second task keeps `wedged` OUT of the active slot, so it is the sweep — not
        // `openWorkFolder`'s active-task block — that has to reach it.
        _ = await sut.createTask(title: "Other", supervisorTask: "b")!
        XCTAssertEqual(diskIndexStatus(wedged), .running, "precondition: the wedge is on disk")

        restartOrchestrator()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(
            diskTask(wedged)?.runs.last?.steps.first?.status, .paused,
            "the destroyed record is settled, so the task stops claiming to run")
        XCTAssertNil(
            diskTask(wedged)?.runs.last?.roleStatuses[generationStepID],
            "and the phantom role key is gone")
        XCTAssertEqual(diskIndexStatus(wedged), .paused)
        XCTAssertEqual(memIndexStatus(wedged), .paused,
                       "list_tasks reads the in-memory index — it must agree with disk")
    }
}
