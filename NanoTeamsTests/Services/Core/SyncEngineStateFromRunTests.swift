import XCTest

@testable import NanoTeams

/// Tests for `NTMSOrchestrator.syncEngineStateFromRun` — the seeding of
/// `taskEngineStates` after app restart / background-task load.
///
/// Bug being fixed: chat-mode tasks where every created step is `.done`
/// (e.g. only the auto-completed `Supervisor Task` step exists) used to seed
/// `engineState[taskID] = .done`, which hid the composer in the activity feed
/// even though chat-mode tasks must keep accepting input until explicitly
/// closed.
///
/// All scenarios exercise the end-to-end seeding path:
///   1. createTask + mutateTask to shape state on disk
///   2. openWorkFolder again → triggers StatusRecoveryService + syncEngineStateFromRun
///   3. assert `taskEngineStates[taskID]`
@MainActor
final class SyncEngineStateFromRunTests: NTMSOrchestratorTestBase {

    // MARK: - Helpers

    /// Shapes the active task on disk for the next `openWorkFolder` re-read.
    private func setUpTask(
        isChatMode: Bool,
        closedAt: Date? = nil,
        steps: [StepExecution],
        roleStatuses: [String: RoleExecutionStatus] = [:]
    ) async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "Goal")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(isChatMode)
            task.closedAt = closedAt
            var run = Run(id: 0, roleStatuses: roleStatuses)
            run.steps = steps
            task.runs = [run]
        }

        // Re-open to trigger the recovery + sync pipeline we're testing.
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.activeTaskID, taskID, "active task should survive re-open")
        return taskID
    }

    private func makeStep(
        id: String = "step",
        role: Role = .supervisor,
        title: String = "Step",
        status: StepStatus
    ) -> StepExecution {
        StepExecution(id: id, role: role, title: title, status: status)
    }

    // MARK: - Scenario A — chat-mode, only supervisor task step `.done`

    /// **The core regression.** A fresh chat-mode task whose advisory role hasn't
    /// produced a step yet has `runs[].steps == [supervisorTaskStep .done]`. The
    /// run's derived status is `.done`. The fix must seed engine state to `.paused`
    /// (not `.done`) so the composer remains visible.
    func testChatMode_onlySupervisorTaskDone_seedsPausedNotDone() async {
        let taskID = await setUpTask(
            isChatMode: true,
            steps: [makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done)]
        )

        let state = sut.taskEngineStates[taskID]
        XCTAssertEqual(state, .paused,
            "chat-mode + all-done steps + closedAt=nil → engine state must be .paused so composer renders")
    }

    // MARK: - Scenario B — chat-mode, advisory step recovered to `.paused`

    func testChatMode_advisoryPaused_seedsPaused() async {
        let taskID = await setUpTask(
            isChatMode: true,
            steps: [
                makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done),
                makeStep(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .paused),
            ],
            roleStatuses: ["assistant": .idle]
        )

        XCTAssertEqual(sut.taskEngineStates[taskID], .paused)
    }

    // MARK: - Scenario C — chat-mode but explicitly closed

    func testChatMode_closed_seedsDone() async {
        let taskID = await setUpTask(
            isChatMode: true,
            closedAt: MonotonicClock.shared.now(),
            steps: [makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done)]
        )

        XCTAssertEqual(sut.taskEngineStates[taskID], .done,
            "chat-mode + closedAt set → engine state must be .done (closed chats stay closed)")
    }

    // MARK: - Scenario D — non-chat baseline, all done w/o closedAt

    /// Regression baseline: non-chat tasks with all-done steps go to `.done`
    /// engine state (UI shows acceptance flow). Must not be perturbed by the fix.
    func testNonChatMode_allStepsDone_seedsDone() async {
        let taskID = await setUpTask(
            isChatMode: false,
            steps: [
                makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done),
                makeStep(id: "eng", role: .softwareEngineer, title: "Engineer", status: .done),
            ],
            roleStatuses: ["eng": .done]
        )

        XCTAssertEqual(sut.taskEngineStates[taskID], .done)
    }

    // MARK: - Scenario E — non-chat, recovered paused step

    func testNonChatMode_pausedStep_seedsPaused() async {
        let taskID = await setUpTask(
            isChatMode: false,
            steps: [makeStep(id: "eng", role: .softwareEngineer, title: "Engineer", status: .paused)],
            roleStatuses: ["eng": .idle]
        )

        XCTAssertEqual(sut.taskEngineStates[taskID], .paused)
    }

    // MARK: - Scenario F — failed step

    func testFailedStep_seedsFailed() async {
        let taskID = await setUpTask(
            isChatMode: false,
            steps: [makeStep(id: "eng", role: .softwareEngineer, title: "Engineer", status: .failed)]
        )

        XCTAssertEqual(sut.taskEngineStates[taskID], .failed)
    }

    // MARK: - Scenario G — empty runs (no-op)

    func testChatMode_emptyRuns_doesNotSeedEngineState() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "Goal")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = []
        }
        await sut.openWorkFolder(tempDir)

        XCTAssertNil(sut.taskEngineStates[taskID],
            "no runs → no engine state seeded (guard short-circuits)")
    }

    // MARK: - Scenario H — `ensureTaskLoaded` (background task path)

    /// User scenario: chat-mode task A is open. User opens chat-mode task B.
    /// Task A becomes a background loaded task. App quits, reopens, and B is
    /// active — but the user clicks A in the sidebar, triggering
    /// `ensureTaskLoaded(A)`. That second call site MUST seed engine state via
    /// the same chat-mode-aware path; otherwise A's composer disappears as
    /// soon as it loads.
    func testEnsureTaskLoaded_chatModeBackgroundTask_seedsPaused() async {
        await sut.openWorkFolder(tempDir)

        // Task A — chat-mode, only supervisor task done.
        let aID = await sut.createTask(title: "A", supervisorTask: "A")!
        await sut.mutateTask(taskID: aID) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0)
            run.steps = [makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done)]
            task.runs = [run]
        }

        // Task B — becomes active; A is now background.
        let bID = await sut.createTask(title: "B", supervisorTask: "B")!
        XCTAssertEqual(sut.activeTaskID, bID)

        // Evict A from the in-memory loadedTasks map so `ensureTaskLoaded`
        // actually has to load from disk (i.e. exercises the recover+sync path).
        sut.evictLoadedTask(aID)
        XCTAssertNil(sut.snapshot?.loadedTasks[aID])
        XCTAssertNil(sut.taskEngineStates[aID])

        await sut.ensureTaskLoaded(aID)

        XCTAssertEqual(sut.taskEngineStates[aID], .paused,
            "ensureTaskLoaded must use chat-mode-aware seeding so background chat tasks load with composer-visible state")
    }

    // MARK: - Scenario I — mid-conversation crash recovery (`.running` → `.paused`)

    /// Real-world: user is mid-chat with the assistant, the assistant's step is
    /// `.running` when the app crashes / quits. On reopen, `StatusRecoveryService`
    /// transitions the step to `.paused` and syncs engine state. The composer
    /// must remain visible so the user can resume the conversation.
    func testChatMode_runningStepCrashRecovered_seedsPaused() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        // Simulate crash mid-stream: step .running, role .working, task .running.
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.status = .running
            var run = Run(id: 0, roleStatuses: ["assistant": .working])
            run.steps = [
                makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done),
                makeStep(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .running),
            ]
            task.runs = [run]
        }

        // Reopen — recovery + sync pipeline runs.
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.taskEngineStates[taskID], .paused,
            "running chat step → recovery → sync must end at .paused so composer shows + Resume works")

        // Recovery side-effects (defense-in-depth assertions):
        let task = sut.activeTask
        XCTAssertEqual(task?.runs.last?.steps.last?.status, .paused,
            "running step should be recovered to .paused")
        XCTAssertEqual(task?.runs.last?.roleStatuses["assistant"], .idle,
            "working role should be recovered to .idle")
    }

    // MARK: - Scenario J — `.needsSupervisorInput` direct sync branch

    /// Recovery normally converts `.needsSupervisorInput` steps to `.paused`,
    /// so the `.needsSupervisorInput` branch of `syncEngineStateFromRun` is
    /// hard to hit through `openWorkFolder`. This direct-call test pins the
    /// branch behavior so future refactors of the switch can't drop it.
    func testNeedsSupervisorInputStep_directSync_seedsNeedsSupervisorInput() async {
        await sut.openWorkFolder(tempDir)

        var task = NTMSTask(id: 999, title: "T", supervisorTask: "G")
        task.runs = [Run(id: 0, steps: [
            StepExecution(id: "eng", role: .softwareEngineer, title: "Eng", status: .needsSupervisorInput)
        ])]

        sut.syncEngineStateFromRun(taskID: 999, task: task)

        XCTAssertEqual(sut.taskEngineStates[999], .needsSupervisorInput)
    }

    // MARK: - Scenario K — multi-task isolation (chat + non-chat coexist)

    /// User has two tasks: chat with assistant + FAANG task done waiting acceptance.
    /// After restart both must seed independently — chat → `.paused` (composer
    /// shows), non-chat done → `.done` (acceptance flow).
    func testMultiTask_chatAndNonChat_seedIndependentEngineStates() async {
        await sut.openWorkFolder(tempDir)

        let chatID = await sut.createTask(title: "Chat", supervisorTask: "Help")!
        await sut.mutateTask(taskID: chatID) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0)
            run.steps = [makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done)]
            task.runs = [run]
        }

        let nonChatID = await sut.createTask(title: "Build", supervisorTask: "Build")!
        await sut.mutateTask(taskID: nonChatID) { task in
            task.setStoredChatMode(false)
            var run = Run(id: 0, roleStatuses: ["eng": .done])
            run.steps = [
                makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done),
                makeStep(id: "eng", role: .softwareEngineer, title: "Engineer", status: .done),
            ]
            task.runs = [run]
        }

        // Reopen: only the active task's engine state seeds via openWorkFolder;
        // background ones seed when ensureTaskLoaded fires (i.e. when the
        // sidebar selects them or any other consumer pulls them in).
        await sut.openWorkFolder(tempDir)

        // Active = nonChat (last created). Verify seeded as .done.
        XCTAssertEqual(sut.activeTaskID, nonChatID)
        XCTAssertEqual(sut.taskEngineStates[nonChatID], .done,
            "non-chat task with all-done steps + no closedAt → engine state .done (acceptance flow)")

        // Now load the background chat task — it must seed independently, NOT
        // pick up the non-chat task's .done state.
        sut.evictLoadedTask(chatID)
        await sut.ensureTaskLoaded(chatID)

        XCTAssertEqual(sut.taskEngineStates[chatID], .paused,
            "chat task seeds independently to .paused even when sibling non-chat task is .done")
        XCTAssertEqual(sut.taskEngineStates[nonChatID], .done,
            "non-chat task's engine state must not be perturbed by chat task seeding")
    }

    // MARK: - mapDerivedStatusToEngineState (pure switch coverage)

    /// Exhaustively pin the pure mapping. Includes the `.waiting` branch
    /// which is unreachable via `derivedStatusFromActiveRun()` today but is
    /// kept for `TaskStatus` switch exhaustiveness — if a future refactor
    /// of `derivedStatusFromActiveRun` starts surfacing `.waiting`, this
    /// test pins the engine-seeding contract.
    func testMapDerivedStatus_paused_seedsPaused() {
        XCTAssertEqual(NTMSOrchestrator.mapDerivedStatusToEngineState(.paused, hasSteps: true), .paused)
        XCTAssertEqual(NTMSOrchestrator.mapDerivedStatusToEngineState(.paused, hasSteps: false), .paused)
    }

    func testMapDerivedStatus_failed_seedsFailed() {
        XCTAssertEqual(NTMSOrchestrator.mapDerivedStatusToEngineState(.failed, hasSteps: true), .failed)
    }

    func testMapDerivedStatus_needsSupervisorInput_seedsNeedsSupervisorInput() {
        XCTAssertEqual(NTMSOrchestrator.mapDerivedStatusToEngineState(.needsSupervisorInput, hasSteps: true), .needsSupervisorInput)
    }

    func testMapDerivedStatus_done_seedsDone() {
        XCTAssertEqual(NTMSOrchestrator.mapDerivedStatusToEngineState(.done, hasSteps: true), .done)
    }

    func testMapDerivedStatus_needsSupervisorAcceptance_seedsDone() {
        XCTAssertEqual(NTMSOrchestrator.mapDerivedStatusToEngineState(.needsSupervisorAcceptance, hasSteps: true), .done,
            "needsSupervisorAcceptance collapses to .done engine state — UI surfaces acceptance via task data, not engine state")
    }

    func testMapDerivedStatus_runningWithSteps_seedsPaused() {
        XCTAssertEqual(NTMSOrchestrator.mapDerivedStatusToEngineState(.running, hasSteps: true), .paused)
    }

    func testMapDerivedStatus_runningWithoutSteps_returnsNil() {
        XCTAssertNil(NTMSOrchestrator.mapDerivedStatusToEngineState(.running, hasSteps: false),
            "running + no steps → no engine state (don't fabricate one for a half-built run)")
    }

    func testMapDerivedStatus_waiting_seedsPaused() {
        XCTAssertEqual(NTMSOrchestrator.mapDerivedStatusToEngineState(.waiting, hasSteps: true), .paused,
            "waiting branch is dead through current paths, but contract is `.paused` — pinned so a future caller doesn't get phantom .running")
        XCTAssertEqual(NTMSOrchestrator.mapDerivedStatusToEngineState(.waiting, hasSteps: false), .paused)
    }

    /// Belt-and-suspenders: every `TaskStatus` case must produce a defined
    /// mapping (either an engine state or explicit nil for `.running` no-op).
    /// If a new `TaskStatus` case is added without updating the mapping,
    /// the switch will fail to compile — but this test also pins the
    /// expected coverage at the test level.
    func testMapDerivedStatus_allTaskStatusCasesAreCovered() {
        for status in TaskStatus.allCases {
            // hasSteps=true exercises every non-running branch and the
            // running+steps branch. Just verify it doesn't crash and returns
            // a defined result (the value-level assertions live in the
            // per-case tests above).
            _ = NTMSOrchestrator.mapDerivedStatusToEngineState(status, hasSteps: true)
            _ = NTMSOrchestrator.mapDerivedStatusToEngineState(status, hasSteps: false)
        }
        XCTAssertEqual(TaskStatus.allCases.count, 7,
            "TaskStatus has 7 cases — if this assertion breaks, audit `mapDerivedStatusToEngineState` for the new case")
    }

    // MARK: - Scenario M — `.running` derived status with empty `lastRun.steps`

    /// Pin: when `derivedStatusFromActiveRun()` returns `.running` but the last
    /// run has no steps yet (e.g. run created, steps not yet seeded — interrupted
    /// run-creation), seeding silently no-ops. Encodes the intentional contract:
    /// don't fabricate engine state for a run in a half-built shape.
    func testRunningDerivedStatus_emptySteps_doesNotSeedEngineState() async {
        await sut.openWorkFolder(tempDir)

        var task = NTMSTask(id: 555, title: "T", supervisorTask: "G")
        // runs.last has empty steps → derivedStatusFromActiveRun returns .running.
        task.runs = [Run(id: 0)]
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)

        sut.syncEngineStateFromRun(taskID: 555, task: task)

        XCTAssertNil(sut.taskEngineStates[555],
            ".running with empty steps must not seed engine state — caller should reset the run, not be handed a phantom .paused")
    }

    // MARK: - Scenario N — pre-existing engine guard

    /// Pin: if a `TeamEngine` is already registered for the task, seeding is
    /// skipped — protects against re-opening the work folder while an engine
    /// is mid-run (multi-task invariants, CLAUDE.md).
    func testPreExistingEngine_seedingIsSkipped() async {
        await sut.openWorkFolder(tempDir)

        var task = NTMSTask(id: 777, title: "T", supervisorTask: "G")
        task.runs = [Run(id: 0, steps: [makeStep(id: "eng", role: .softwareEngineer, title: "Eng", status: .paused)])]

        // Pre-register an engine; do NOT pre-set engineState — the guard reads
        // `taskEngines`, not `engineState`.
        sut.taskEngines[777] = TeamEngine()

        sut.syncEngineStateFromRun(taskID: 777, task: task)

        XCTAssertNil(sut.taskEngineStates[777],
            "pre-existing engine present → sync must NOT install a parallel engine state")
    }

    // MARK: - Scenario L — sidebar status label after restart

    /// User-visible symptom: sidebar shows the wrong status label for chat
    /// tasks after restart ("Done"/"Review" instead of "Chat"). This pins
    /// the contract that `task.toSummary()` (the sidebar's source of truth)
    /// reports `.running` for chat tasks with all-done steps after the full
    /// open → recover → sync pipeline.
    func testSidebar_chatModeTask_summaryStatusIsRunningAfterRestart() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0)
            run.steps = [makeStep(id: "sup", role: .supervisor, title: "Supervisor Task", status: .done)]
            task.runs = [run]
        }

        await sut.openWorkFolder(tempDir)

        let summary = sut.activeTask?.toSummary()
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.isChatMode == true)
        XCTAssertEqual(summary?.status, .running,
            "chat-mode task summary must be .running (sidebar then renders 'Chat'), not .needsSupervisorAcceptance/.done")

        // Bonus: tasksIndex (the persisted summary store backing the sidebar)
        // must agree — otherwise the sidebar lags behind the in-memory task.
        let indexSummary = sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })
        XCTAssertEqual(indexSummary?.status, .running)
        XCTAssertTrue(indexSummary?.isChatMode == true)
    }
}
