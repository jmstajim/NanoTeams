import XCTest

@testable import NanoTeams

// Coverage for the orchestrator's own extension "tail" — the guard arms and
// branch selectors of `+RunControl`, `+StateMutation`, `+Streaming`,
// `+StepExecution`, `+Attachments`, `+WorkFolderManagement` and the core
// `NTMSOrchestrator` snapshot helpers that the existing suites drive only
// incidentally.
//
// Everything here runs against a temp work folder and an inert LLM client, so
// no test reaches the network. Assertions are taken synchronously right after
// the `await` returns, before any spawned engine run loop can advance — the
// same determinism trick `ResumeFailedStepTests` uses.

// MARK: - Shared helpers

/// An orchestrator whose chat client is an inert stub.
///
/// `NTMSOrchestratorTestBase.sut` gets the production `LLMExecutionService`,
/// whose default `clientFactory` is a real `LLMClientRouter` — fine for paths
/// that never start a step, wrong for the resume/restart branches this file
/// drives, which all end in `runStep` → `startStepExecution`. Injecting the
/// service with `RecordingLLMClient` (its `streamChat` finishes immediately)
/// keeps those paths entirely offline.
@MainActor
private func makeOfflineOrchestrator() -> NTMSOrchestrator {
    let repo = NTMSRepository()
    return TestOrchestrator.make(
        repository: repo,
        llmExecutionService: LLMExecutionService(
            repository: repo,
            clientFactory: { RecordingLLMClient() }
        )
    )
}

/// Seeds `taskID`'s latest run with an explicit step/role shape.
@MainActor
private func seedRun(
    _ store: NTMSOrchestrator,
    taskID: Int,
    steps: [StepExecution],
    roleStatuses: [String: RoleExecutionStatus] = [:],
    latchedStatus: TaskStatus? = nil,
    closed: Bool = false
) async {
    await store.mutateTask(taskID: taskID) { task in
        var run = Run(id: 0, steps: steps, roleStatuses: roleStatuses)
        run.updatedAt = MonotonicClock.shared.now()
        task.runs = [run]
        if let latchedStatus { task.status = latchedStatus }
        if closed { task.closedAt = MonotonicClock.shared.now() }
    }
}

@MainActor
private func latestRun(_ store: NTMSOrchestrator, _ taskID: Int) -> Run? {
    store.loadedTask(taskID)?.runs.last
}

@MainActor
private func step(_ store: NTMSOrchestrator, _ taskID: Int, _ stepID: String) -> StepExecution? {
    latestRun(store, taskID)?.steps.first(where: { $0.id == stepID })
}

// MARK: - Run lifecycle: start / pause / resume

@MainActor
final class OrchestratorCoreTailRunControlTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func openAndCreateTask(_ store: NTMSOrchestrator) async -> Int {
        await store.openWorkFolder(tempDir)
        guard let id = await store.createTask(title: "T", supervisorTask: "goal") else {
            XCTFail("task creation must succeed against a fresh temp folder")
            return -1
        }
        return id
    }

    // MARK: startRun re-entry guards

    /// The engine-state guard is what stops Play / ⌘R from stacking a second run
    /// on top of a live one. A fresh task has zero runs, so "still zero" is an
    /// exact read of "the guard fired".
    func testStartRun_whileEngineRunning_createsNoSecondRun() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        store.engineState[id] = .running

        await store.startRun(taskID: id)

        XCTAssertEqual(store.loadedTask(id)?.runs.count, 0,
                       "startRun must bail while the engine is .running — a second createNewRun would orphan the live run")
    }

    func testStartRun_whileAwaitingAcceptance_createsNoSecondRun() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        store.engineState[id] = .needsAcceptance

        await store.startRun(taskID: id)

        XCTAssertEqual(store.loadedTask(id)?.runs.count, 0)
    }

    func testStartRun_whileAwaitingSupervisorInput_createsNoSecondRun() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        store.engineState[id] = .needsSupervisorInput

        await store.startRun(taskID: id)

        XCTAssertEqual(store.loadedTask(id)?.runs.count, 0)
    }

    /// `createNewRun` would wipe the placeholder Supervisor step that team
    /// generation is writing into, and a second `runTeamGeneration` would be
    /// spawned on top of the first.
    func testStartRun_whileTeamGenerationInFlight_createsNoRun() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        XCTAssertTrue(store.beginTeamGeneration(taskID: id), "precondition: slot was free")

        await store.startRun(taskID: id)

        XCTAssertEqual(store.loadedTask(id)?.runs.count, 0,
                       "startRun must bail while a generation reserve is held")
        store.endTeamGeneration(taskID: id)
    }

    /// The re-entrancy set exists because everything after it suspends
    /// (instruction rescan, task load, run creation) before the engine-state
    /// guard above can observe the new run.
    func testStartRun_whileAnotherStartIsInFlight_createsNoRun() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        _ = store.engineState.beginRunStart(id)

        await store.startRun(taskID: id)

        XCTAssertEqual(store.loadedTask(id)?.runs.count, 0,
                       "a concurrent second startRun for the same task must not double-create runs")
        store.engineState.endRunStart(id)
    }

    /// Sanity anchor for the guards above: with nothing blocking, startRun
    /// really does create the run they were suppressing.
    func testStartRun_unblocked_createsExactlyOneRun() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)

        await store.startRun(taskID: id)

        XCTAssertEqual(store.loadedTask(id)?.runs.count, 1,
                       "without a guard firing, startRun must create the run")
        // The engine really starts here; stop it before the temp folder goes
        // away so a lingering run loop can't write into a deleted directory.
        store.stopAllEngines()
    }

    // MARK: pauseRun

    /// Defensive `else` arm: no task in memory, so there is no per-step loop to
    /// run and nothing to preserve. Must not throw or surface a banner.
    func testPauseRun_unknownTask_isSilentNoOp() async {
        let store = makeOfflineOrchestrator()
        await store.openWorkFolder(tempDir)

        await store.pauseRun(taskID: 987_654)

        XCTAssertNil(store.lastErrorMessage,
                     "pausing a task that isn't in memory is a race, not a user-visible error")
    }

    /// A loaded task with no run also takes the defensive branch (`runs.last`
    /// is nil), so it must be equally silent.
    func testPauseRun_loadedTaskWithNoRun_isSilentNoOp() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)

        await store.pauseRun(taskID: id)

        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(store.loadedTask(id)?.runs.count, 0)
    }

    /// `pauseStep` is gated on `.running || .needsSupervisorInput`. A `.pending`
    /// step has nothing in flight; marking it `.paused` would make `resumeRun`
    /// branch 3 treat a never-started role as interrupted work.
    func testPauseRun_pendingStep_staysPending() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "pm", role: .productManager, title: "PM", status: .pending)],
            roleStatuses: ["pm": .idle]
        )

        await store.pauseRun(taskID: id)

        XCTAssertEqual(step(store, id, "pm")?.status, .pending,
                       "a .pending step has no in-flight work to park")
    }

    /// Same gate, terminal side: a finished step must never be re-opened to
    /// `.paused` by a pause of its siblings.
    func testPauseRun_doneStep_staysDone() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [
                StepExecution(id: "pm", role: .productManager, title: "PM",
                              status: .done, completedAt: MonotonicClock.shared.now()),
                StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .running)
            ],
            roleStatuses: ["pm": .done, "swe": .working]
        )

        await store.pauseRun(taskID: id)

        XCTAssertEqual(step(store, id, "pm")?.status, .done,
                       "pause must not resurrect a completed step")
        XCTAssertEqual(step(store, id, "swe")?.status, .paused,
                       "the live sibling still parks")
    }

    /// `pauseRun` cancels the detached generation Task first; its `defer`
    /// releases the reserve and its cancellation check stops `engine.start()`
    /// from firing after the pause.
    func testPauseRun_cancelsInFlightTeamGenerationTask() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        let generation = Task<Void, Never> {
            _ = try? await Task.sleep(for: .seconds(30))
        }
        store.registerTeamGenerationTask(taskID: id, task: generation)

        await store.pauseRun(taskID: id)

        XCTAssertTrue(generation.isCancelled,
                      "pause must cancel the detached generation Task, else engine.start() fires after the pause")
        await generation.value
    }

    // MARK: resumeRun — guards

    /// The `closedAt` guard sits ABOVE the recovery-latch clear, so a closed
    /// task must come back from `resumeRun` completely untouched — including
    /// the latch. Pinning the latch is what makes the ORDER of the two
    /// statements observable.
    func testResumeRun_closedTask_leavesRecoveryLatchArmed() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .paused)],
            roleStatuses: ["swe": .working],
            latchedStatus: .paused,
            closed: true
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(store.loadedTask(id)?.status, .paused,
                       "the closedAt guard must return BEFORE clearRecoveryPauseLatch — a closed task is terminal")
        XCTAssertEqual(step(store, id, "swe")?.status, .paused,
                       "and no restore branch may run")
    }

    /// Mid-delegation short-circuit: the delegating step's handler is still
    /// suspended on its child awaiter, so branches 1 / 1.5 / 3 must all be
    /// skipped — a second `runStep` would stack on the live one.
    func testResumeRun_midDelegation_skipsTheRestartBranches() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [
                StepExecution(id: "agent", role: .softwareEngineer, title: "Agent",
                              status: .running, activeDelegationChildID: 4242),
                StepExecution(id: "pm", role: .productManager, title: "PM",
                              status: .paused,
                              llmConversation: [LLMMessage(role: .assistant, content: "half a plan")])
            ],
            roleStatuses: ["agent": .working, "pm": .working]
        )

        // The premise: a handler is actually suspended on 4242. Re-aimed 2026-08-25 — the
        // predicate moved from the durable marker to `TaskCompletionAwaiter.hasWaiters`, and
        // without a registered awaiter this fixture stops selecting the short-circuit at all.
        // The test would then pass for the wrong reason (branch 3 not restarting `pm` because
        // it never ran), i.e. go VACUOUS rather than red under its own stated mutation.
        let handler = Task { @MainActor in _ = await store.completionAwaiter.register(taskID: 4242) }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: 4242), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        defer { store.completionAwaiter.cancelAll(taskID: 4242); handler.cancel() }
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: 4242),
                      "premise: a delegate_to_team handler is suspended on child #4242")

        await store.resumeRun(taskID: id)

        XCTAssertEqual(step(store, id, "pm")?.status, .paused,
                       "branch 3 must not restart a sibling while another step owns a live delegation")
        XCTAssertEqual(step(store, id, "agent")?.activeDelegationChildID, 4242,
                       "the delegating step is left exactly as it was")
    }

    // MARK: resumeRun — branch 1 (restore Supervisor questions)

    /// A pause that landed on an unanswered `ask_supervisor` must come back as
    /// `.needsSupervisorInput`, not as a restartable `.paused` step — otherwise
    /// branch 3 would re-run the role and re-ask.
    func testResumeRun_pausedUnansweredQuestion_isRestoredToNeedsSupervisorInput() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                                  status: .paused,
                                  needsSupervisorInput: true,
                                  supervisorQuestion: "Which database?")],
            roleStatuses: ["swe": .idle]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(step(store, id, "swe")?.status, .needsSupervisorInput,
                       "an unanswered question must be re-surfaced, not silently restarted")
        XCTAssertEqual(latestRun(store, id)?.roleStatuses["swe"], .working,
                       "and its role is promoted so the run loop keeps the gate open")
    }

    /// Same shape but the role is already `.working`: the second, conditional
    /// `mutateTask` is skipped and the status is unchanged.
    func testResumeRun_pausedUnansweredQuestion_workingRole_staysWorking() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                                  status: .paused,
                                  needsSupervisorInput: true,
                                  supervisorQuestion: "Which database?")],
            roleStatuses: ["swe": .working]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(step(store, id, "swe")?.status, .needsSupervisorInput)
        XCTAssertEqual(latestRun(store, id)?.roleStatuses["swe"], .working)
    }

    // MARK: resumeRun — branch 1.5 (an answer arrived while suspended)

    /// With an answer present, branch 1 must NOT fire (that would re-park an
    /// already-answered step); branch 1.5 restarts it instead.
    func testResumeRun_answeredQuestion_takesRestartBranchNotTheQuestionBranch() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                                  status: .paused,
                                  needsSupervisorInput: true,
                                  supervisorQuestion: "Which database?",
                                  supervisorAnswer: "Postgres")],
            roleStatuses: ["swe": .idle]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(step(store, id, "swe")?.status, .running,
                       "an answered step restarts — re-parking it at .needsSupervisorInput would strand the answer")
        XCTAssertEqual(latestRun(store, id)?.roleStatuses["swe"], .working)
    }

    /// A `.pending` step with an answer is branch 1.5's other input shape
    /// (branches 1 and 3 both filter on `.paused` only).
    func testResumeRun_pendingStepWithAnswer_isRestarted() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                                  status: .pending,
                                  supervisorAnswer: "go ahead")],
            roleStatuses: ["swe": .ready]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(step(store, id, "swe")?.status, .running)
        XCTAssertEqual(latestRun(store, id)?.roleStatuses["swe"], .working)
    }

    /// The live-role guard: `.done` / `.accepted` / `.needsAcceptance` /
    /// `.revisionRequested` have their own flows, so an answer left on a
    /// settled role must not resurrect it.
    func testResumeRun_answerOnSettledRole_isNotRestarted() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                                  status: .paused,
                                  supervisorAnswer: "stale answer")],
            roleStatuses: ["swe": .accepted]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(latestRun(store, id)?.roleStatuses["swe"], .accepted,
                       "an accepted role must not be flipped back to .working by a leftover answer")
        XCTAssertEqual(step(store, id, "swe")?.status, .paused)
    }

    // MARK: resumeRun — branch 3 (interrupted steps)

    /// App-restart recovery: the role was reset to `.idle` but the step carries
    /// history, so it WAS running and must be resumed.
    func testResumeRun_idleRoleWithConversation_isRestarted() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                                  status: .paused,
                                  llmConversation: [LLMMessage(role: .assistant, content: "work in progress")])],
            roleStatuses: ["swe": .idle]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(latestRun(store, id)?.roleStatuses["swe"], .working,
                       "recovery promotes the role before re-running the step")
        XCTAssertEqual(step(store, id, "swe")?.status, .running)
    }

    /// `step.messages` is the other half of the same disjunction.
    func testResumeRun_idleRoleWithStepMessages_isRestarted() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                                  status: .paused,
                                  messages: [StepMessage(role: .assistant, content: "partial")])],
            roleStatuses: ["swe": .idle]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(step(store, id, "swe")?.status, .running)
    }

    /// No history at all → the role never actually started, so resuming must
    /// leave it for the engine's normal dependency scheduling.
    func testResumeRun_idleRoleWithNoHistory_isLeftAlone() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .paused)],
            roleStatuses: ["swe": .idle]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(step(store, id, "swe")?.status, .paused,
                       "an .idle role with no messages and no conversation was never interrupted")
        XCTAssertEqual(latestRun(store, id)?.roleStatuses["swe"], .idle)
    }

    /// The plain pause case: role still `.working`, so the step restarts with
    /// no role mutation at all.
    func testResumeRun_workingRoleWithPausedStep_isRestarted() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .paused)],
            roleStatuses: ["swe": .working]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(step(store, id, "swe")?.status, .running)
    }

    /// A settled role beside a `.paused` step matches neither arm of branch 3.
    func testResumeRun_pausedStepWithDoneRole_isLeftAlone() async {
        let store = makeOfflineOrchestrator()
        let id = await openAndCreateTask(store)
        await seedRun(
            store, taskID: id,
            steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                                  status: .paused,
                                  messages: [StepMessage(role: .assistant, content: "done work")])],
            roleStatuses: ["swe": .done]
        )

        await store.resumeRun(taskID: id)

        XCTAssertEqual(step(store, id, "swe")?.status, .paused)
        XCTAssertEqual(latestRun(store, id)?.roleStatuses["swe"], .done)
    }

    /// `ensureTaskLoaded` fails for an id that is not on disk, so `loadedTask`
    /// stays nil and the `runs.last` guard returns.
    func testResumeRun_unknownTask_isNoOp() async {
        let store = makeOfflineOrchestrator()
        await store.openWorkFolder(tempDir)

        await store.resumeRun(taskID: 424_242)

        XCTAssertNil(store.loadedTask(424_242))
    }
}

// MARK: - Task / snapshot mutation + streaming

@MainActor
final class OrchestratorCoreTailStateMutationTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func openAndCreateTask(title: String = "Original") async -> Int {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: title, supervisorTask: "goal") else {
            XCTFail("task creation must succeed against a fresh temp folder")
            return -1
        }
        return id
    }

    // MARK: mutateTask — the "persisted ≠ mutated" trap (CLAUDE.md §7)

    /// The single most expensive misreading in this codebase: `true` means the
    /// file was written, NOT that the closure changed anything. A closure that
    /// guards its way out still returns `true`.
    func testMutateTask_closureEarlyReturns_stillReportsPersisted() async {
        let id = await openAndCreateTask()

        let persisted = await sut.mutateTask(taskID: id) { task in
            // A fresh task has no run, so this is the shape every real caller
            // writes — and the shape that silently does nothing.
            guard task.runs.indices.last != nil else { return }
            task.title = "should never land"
        }

        XCTAssertTrue(persisted,
                      "mutateTask reports persistence, so a short-circuiting closure still returns true")
        XCTAssertEqual(sut.loadedTask(id)?.title, "Original",
                       "…which is exactly why callers must verify durable state instead of trusting the Bool")
    }

    func testMutateTask_withoutWorkFolder_returnsFalseAndNamesTheCause() async {
        let persisted = await sut.mutateTask(taskID: 1) { $0.title = "x" }

        XCTAssertFalse(persisted)
        XCTAssertTrue(sut.lastErrorMessage?.contains("no work folder") ?? false,
                      "the banner must name the missing work folder, got: \(sut.lastErrorMessage ?? "nil")")
    }

    func testMutateTask_unloadedTask_returnsFalseAndNamesTheCause() async {
        await sut.openWorkFolder(tempDir)

        let persisted = await sut.mutateTask(taskID: 55_555) { $0.title = "x" }

        XCTAssertFalse(persisted)
        XCTAssertTrue(sut.lastErrorMessage?.contains("not loaded") ?? false,
                      "got: \(sut.lastErrorMessage ?? "nil")")
    }

    /// Background branch: `loadedTasks` AND the in-memory tasks index must move
    /// together, or the sidebar shows a stale row for every non-active task
    /// that mutates in the background.
    func testMutateTask_backgroundTask_movesLoadedTasksAndIndexInLockstep() async {
        let first = await openAndCreateTask(title: "First")
        guard let second = await sut.createTask(title: "Second", supervisorTask: "goal") else {
            return XCTFail("second task creation failed")
        }
        XCTAssertEqual(sut.activeTaskID, second, "precondition: the first task is now in the background")

        await sut.mutateTask(taskID: first) { $0.title = "Renamed in background" }

        XCTAssertEqual(sut.loadedTask(first)?.title, "Renamed in background")
        XCTAssertEqual(
            sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == first })?.title,
            "Renamed in background",
            "the tasks-index summary must move in lockstep — the sidebar reads it, not loadedTasks")
    }

    // MARK: mutateTaskInMemory

    /// The whole point of the in-memory variant is that it does NOT hit disk;
    /// pinning that keeps a future "just make it persist" edit honest.
    func testMutateTaskInMemory_updatesMemoryButNotDisk() async throws {
        let id = await openAndCreateTask()
        guard let url = sut.workFolderURL else { return XCTFail("no work folder") }

        sut.mutateTaskInMemory(taskID: id) { $0.title = "in-memory only" }

        XCTAssertEqual(sut.activeTask?.title, "in-memory only")
        let onDisk = try sut.repository.loadTask(at: url, taskID: id)
        XCTAssertEqual(onDisk.title, "Original",
                       "mutateTaskInMemory must never write task.json — that is mutateTask's job")
    }

    func testMutateTaskInMemory_withoutIndexUpdate_leavesSummaryStale() async {
        let id = await openAndCreateTask()

        sut.mutateTaskInMemory(taskID: id, { $0.title = "renamed" }, updateIndex: false)

        XCTAssertEqual(sut.snapshot?.activeTask?.title, "renamed")
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == id })?.title, "Original",
                       "updateIndex: false is the streaming hot path — it deliberately skips the summary rebuild")
    }

    func testMutateTaskInMemory_withIndexUpdate_refreshesSummary() async {
        let id = await openAndCreateTask()

        sut.mutateTaskInMemory(taskID: id, { $0.title = "renamed" }, updateIndex: true)

        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == id })?.title, "renamed")
    }

    func testMutateTaskInMemory_backgroundTask_updatesLoadedTasks() async {
        let first = await openAndCreateTask(title: "First")
        _ = await sut.createTask(title: "Second", supervisorTask: "goal")

        sut.mutateTaskInMemory(taskID: first) { $0.title = "background rename" }

        XCTAssertEqual(sut.snapshot?.loadedTasks[first]?.title, "background rename")
    }

    func testMutateTaskInMemory_unknownTask_isSilentNoOp() async {
        _ = await openAndCreateTask()
        let before = sut.snapshot?.loadedTasks.count

        sut.mutateTaskInMemory(taskID: 909_090) { $0.title = "nope" }

        XCTAssertEqual(sut.snapshot?.loadedTasks.count, before)
        XCTAssertNil(sut.lastErrorMessage)
    }

    // MARK: apply(_:) — loadedTasks preservation

    /// Multi-task invariant #2: switching the active task must park the old one
    /// in `loadedTasks`, or its background engine loses access to it.
    func testApply_sameFolder_parksThePreviousActiveTask() async {
        let first = await openAndCreateTask(title: "First")

        _ = await sut.createTask(title: "Second", supervisorTask: "goal")

        XCTAssertNotNil(sut.loadedTask(first),
                        "the previous active task must survive in loadedTasks for its background engine")
    }

    /// …but ONLY within one folder. Task ids are sequential per folder, so
    /// carrying them across would let a background write persist folder A's
    /// content into folder B's task.json.
    func testApply_folderSwitch_dropsThePreviousFoldersTasks() async throws {
        let first = await openAndCreateTask(title: "First")
        XCTAssertNotNil(sut.loadedTask(first), "precondition")

        let otherDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherDir) }

        await sut.openWorkFolder(otherDir)

        XCTAssertNil(sut.loadedTask(first),
                     "a colliding task id from the previous folder must not resolve after a folder switch")
    }

    // MARK: applyTaskUpdate → syncSelectedRunID

    /// Pinned to the tip: a new run arrives and the feed follows it.
    func testApplyTaskUpdate_selectionPinnedToTip_followsTheNewRun() async {
        let id = await openAndCreateTask()
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0), Run(id: 1)]
        }
        sut.selectedRunID = 1

        await sut.mutateTask(taskID: id) { task in
            task.runs.append(Run(id: 2))
        }

        XCTAssertEqual(sut.selectedRunID, 2,
                       "a selection sitting on the newest run must follow the newest run")
    }

    /// Browsing history: the user pinned an older run, so a new run must not
    /// yank them forward.
    func testApplyTaskUpdate_selectionOnOlderRun_isPreserved() async {
        let id = await openAndCreateTask()
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0), Run(id: 1)]
        }
        sut.selectedRunID = 0

        await sut.mutateTask(taskID: id) { task in
            task.runs.append(Run(id: 2))
        }

        XCTAssertEqual(sut.selectedRunID, 0,
                       "an explicitly-selected historical run must survive a new run appearing")
    }

    /// A selection that no longer names a real run (deleted / rebuilt history)
    /// falls back to the latest run rather than pinning the feed to nothing.
    func testApplyTaskUpdate_staleSelection_fallsBackToLatestRun() async {
        let id = await openAndCreateTask()
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0), Run(id: 1)]
        }
        sut.selectedRunID = 99

        await sut.mutateTask(taskID: id) { $0.title = "touch" }

        XCTAssertEqual(sut.selectedRunID, 1)
    }

    /// No task at all → nothing can be selected.
    func testApplyTaskUpdate_taskWithNoRuns_clearsSelection() async {
        let id = await openAndCreateTask()
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0)]
        }
        sut.selectedRunID = 0

        await sut.mutateTask(taskID: id) { task in
            task.runs = []
        }

        XCTAssertNil(sut.selectedRunID)
    }

    // MARK: streaming

    private func taskWithStep(_ stepID: String = "swe") async -> Int {
        let id = await openAndCreateTask()
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: stepID, role: .softwareEngineer, title: "SWE", status: .running)
            ])]
        }
        return id
    }

    /// `beginStreaming` plants an empty assistant turn so the timeline has a
    /// slot to grow into; everything downstream (commit, discard) keys on it.
    func testBeginStreaming_plantsAnEmptyAssistantTurn() async {
        let id = await taskWithStep()
        let messageID = UUID()

        await sut.beginStreaming(stepID: "swe", taskID: id, messageID: messageID, role: .softwareEngineer)

        let conversation = step(sut, id, "swe")?.llmConversation ?? []
        XCTAssertEqual(conversation.count, 1)
        XCTAssertEqual(conversation.first?.id, messageID)
        XCTAssertEqual(conversation.first?.content, "")
        XCTAssertTrue(sut.streamingPreviewManager.hasPreview(stepID: "swe", taskID: id))
    }

    /// commit clears the preview unconditionally — whitespace-only included.
    /// (The former "returns nil" assertion died with the commit return in wave 33;
    /// the empty-turn suppression is pinned at the two live layers — the
    /// StepMessage guard below and `ActivityFeedBuilder`'s no-orphan-bubble.)
    func testStreamingPreviewCommit_whitespaceOnlyContent_clearsThePreview() async {
        let id = await taskWithStep()
        let messageID = UUID()
        sut.streamingPreviewManager.beginStreaming(
            stepID: "swe", taskID: id, messageID: messageID, role: .softwareEngineer)
        sut.appendStreamingPreview(
            stepID: "swe", taskID: id, messageID: messageID, role: .softwareEngineer, content: "  \n\t ")

        sut.streamingPreviewManager.commit(stepID: "swe", taskID: id)

        XCTAssertFalse(sut.streamingPreviewManager.hasPreview(stepID: "swe", taskID: id),
                       "the preview state is cleared unconditionally")
    }

    /// End-to-end counterpart: a whitespace-only commit leaves NO `StepMessage`
    /// behind (that array feeds `PromptBuilder`, so a blank turn there is real
    /// prompt pollution) while the pre-created LLM turn is still updated.
    func testCommitStreaming_whitespaceOnlyContent_createsNoStepMessage() async {
        let id = await taskWithStep()
        let messageID = UUID()
        await sut.beginStreaming(stepID: "swe", taskID: id, messageID: messageID, role: .softwareEngineer)

        await sut.commitStreaming(stepID: "swe", taskID: id, content: "   ", thinking: nil)

        XCTAssertTrue(step(sut, id, "swe")?.messages.isEmpty ?? false,
                      "a whitespace-only turn must not become a StepMessage")
        XCTAssertEqual(step(sut, id, "swe")?.llmConversation.count, 1,
                       "the planted assistant turn stays (it renders as nothing)")
    }

    func testCommitStreaming_realContent_createsStepMessageAndFillsTheTurn() async {
        let id = await taskWithStep()
        let messageID = UUID()
        await sut.beginStreaming(stepID: "swe", taskID: id, messageID: messageID, role: .softwareEngineer)

        await sut.commitStreaming(stepID: "swe", taskID: id, content: "final answer", thinking: "reasoned")

        XCTAssertEqual(step(sut, id, "swe")?.messages.count, 1)
        XCTAssertEqual(step(sut, id, "swe")?.messages.first?.content, "final answer")
        XCTAssertEqual(step(sut, id, "swe")?.llmConversation.first?.content, "final answer")
        XCTAssertEqual(step(sut, id, "swe")?.llmConversation.first?.thinking, "reasoned")
    }

    /// No `beginStreaming` ran, so there is no planted turn to fill — the
    /// content still has to land somewhere rather than vanish.
    func testCommitStreaming_withoutAPriorPreview_stillRecordsAStepMessage() async {
        let id = await taskWithStep()

        await sut.commitStreaming(stepID: "swe", taskID: id, content: "orphan content", thinking: nil)

        XCTAssertEqual(step(sut, id, "swe")?.messages.count, 1)
        XCTAssertEqual(step(sut, id, "swe")?.messages.first?.content, "orphan content")
        XCTAssertTrue(step(sut, id, "swe")?.llmConversation.isEmpty ?? false,
                      "with no planted turn there is nothing in llmConversation to update")
    }

    /// A looping generation is discarded, never committed: the preview goes and
    /// so does the empty turn `beginStreaming` planted.
    func testDiscardStreaming_removesThePlantedTurnAndThePreview() async {
        let id = await taskWithStep()
        let messageID = UUID()
        await sut.beginStreaming(stepID: "swe", taskID: id, messageID: messageID, role: .softwareEngineer)
        XCTAssertEqual(step(sut, id, "swe")?.llmConversation.count, 1, "precondition")

        await sut.discardStreaming(stepID: "swe", messageID: messageID, taskID: id)

        XCTAssertTrue(step(sut, id, "swe")?.llmConversation.isEmpty ?? false,
                      "the discarded generation must leave no assistant turn behind")
        XCTAssertFalse(sut.streamingPreviewManager.hasPreview(stepID: "swe", taskID: id))
    }

    /// Teardown race: the step already left the latest run. Removal is
    /// best-effort by design, so this must be silent.
    func testDiscardStreaming_stepMissingFromLatestRun_isBestEffortNoOp() async {
        let id = await taskWithStep()

        await sut.discardStreaming(stepID: "not-a-step", messageID: UUID(), taskID: id)

        XCTAssertNil(sut.lastErrorMessage)
        XCTAssertEqual(step(sut, id, "swe")?.llmConversation.count, 0)
    }
}

// MARK: - Step execution, attachments, work-folder settings

@MainActor
final class OrchestratorCoreTailWorkFolderTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func openAndCreateTask() async -> Int {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "T", supervisorTask: "goal") else {
            XCTFail("task creation must succeed against a fresh temp folder")
            return -1
        }
        return id
    }

    // MARK: answerSupervisorQuestion

    /// The step was restarted / rebuilt between the composer rendering the
    /// Answer chip and the user submitting. `mutateTask` still returns `true`,
    /// so the applied-flag is the only honest signal.
    func testAnswerSupervisorQuestion_stepNoLongerExists_reportsFailureWithACause() async {
        let id = await openAndCreateTask()
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .running)
            ])]
        }

        let ok = await sut.answerSupervisorQuestion(stepID: "vanished", taskID: id, answer: "hi")

        XCTAssertFalse(ok, "an answer aimed at a step that no longer exists must not report success")
        XCTAssertTrue(sut.lastErrorMessage?.contains("no longer active") ?? false,
                      "got: \(sut.lastErrorMessage ?? "nil")")
    }

    func testAnswerSupervisorQuestion_recordsAnswerAndClearsTheInputFlag() async {
        let id = await openAndCreateTask()
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                              status: .needsSupervisorInput,
                              needsSupervisorInput: true,
                              supervisorQuestion: "Which database?")
            ], roleStatuses: ["swe": .working])]
        }

        let ok = await sut.answerSupervisorQuestion(stepID: "swe", taskID: id, answer: "Postgres")

        XCTAssertTrue(ok)
        let recorded = step(sut, id, "swe")
        XCTAssertEqual(recorded?.supervisorAnswer, "Postgres")
        XCTAssertEqual(recorded?.needsSupervisorInput, false)
        XCTAssertEqual(recorded?.supervisorAnswerWasAuto, false,
                       "a human answer must not be badged Auto-answered")
    }

    /// `isAutoAnswer` is what drives the feed's "Auto-answered" badge; it comes
    /// only from automated paths (delegating parent, the Autovisor).
    func testAnswerSupervisorQuestion_autoAnswer_isMarkedAsAutomated() async {
        let id = await openAndCreateTask()
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "swe", role: .softwareEngineer, title: "SWE",
                              status: .needsSupervisorInput, needsSupervisorInput: true)
            ], roleStatuses: ["swe": .working])]
        }

        let ok = await sut.answerSupervisorQuestion(
            stepID: "swe", taskID: id, answer: "proceed", isAutoAnswer: true)

        XCTAssertTrue(ok)
        XCTAssertEqual(step(sut, id, "swe")?.supervisorAnswerWasAuto, true)
    }

    // MARK: staging attachments

    /// A file already inside the work folder is referenced, never copied — the
    /// LLM can read it in place and the user's file is not duplicated.
    func testStageAttachment_fileInsideWorkFolder_becomesAProjectReference() async throws {
        await sut.openWorkFolder(tempDir)
        let source = tempDir.appendingPathComponent("notes.txt", isDirectory: false)
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        guard let staged = sut.stageAttachment(url: source, draftID: UUID()) else {
            return XCTFail("staging an in-folder file must succeed")
        }

        XCTAssertTrue(staged.isProjectReference)
        XCTAssertEqual(staged.stagedRelativePath, "notes.txt",
                       "a project reference keeps its work-folder-relative path")
    }

    /// The reference points at the user's real file, so removing the
    /// *attachment* must never delete it.
    func testRemoveStagedAttachment_projectReference_leavesTheUsersFileOnDisk() async throws {
        await sut.openWorkFolder(tempDir)
        let source = tempDir.appendingPathComponent("keep-me.txt", isDirectory: false)
        try "precious".write(to: source, atomically: true, encoding: .utf8)
        guard let staged = sut.stageAttachment(url: source, draftID: UUID()) else {
            return XCTFail("staging failed")
        }

        sut.removeStagedAttachment(staged)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "removing a project-reference attachment must not delete the user's real file")
    }

    /// A file from outside the folder is copied into `.nanoteams/staged/`, and
    /// THAT copy is what removal deletes.
    func testStageAttachment_fileOutsideWorkFolder_isCopiedThenRemovable() async throws {
        await sut.openWorkFolder(tempDir)
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let source = outsideDir.appendingPathComponent("outside.txt", isDirectory: false)
        try "external".write(to: source, atomically: true, encoding: .utf8)

        guard let staged = sut.stageAttachment(url: source, draftID: UUID()) else {
            return XCTFail("staging an out-of-folder file must succeed")
        }
        XCTAssertFalse(staged.isProjectReference)
        XCTAssertTrue(staged.stagedRelativePath.hasPrefix(".nanoteams/"),
                      "the copy lives in internal staging, got: \(staged.stagedRelativePath)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))

        sut.removeStagedAttachment(staged)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path),
                       "the staged COPY is ours to delete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the user's original is untouched")
    }

    func testDiscardStagedDraft_removesTheWholeDraftDirectory() async throws {
        await sut.openWorkFolder(tempDir)
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let source = outsideDir.appendingPathComponent("draft.txt", isDirectory: false)
        try "draft".write(to: source, atomically: true, encoding: .utf8)
        let draftID = UUID()
        guard let staged = sut.stageAttachment(url: source, draftID: draftID) else {
            return XCTFail("staging failed")
        }
        let draftDir = staged.url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftDir.path), "precondition")

        sut.discardStagedDraft(draftID: draftID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDir.path),
                       "cancelling a draft must clean up its whole staging directory")
    }

    func testRemoveStagedAttachment_withoutWorkFolder_reportsTheMissingFolder() async throws {
        let url = tempDir.appendingPathComponent("orphan.txt", isDirectory: false)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        let attachment = try StagedAttachment(url: url, stagedRelativePath: "orphan.txt")

        sut.removeStagedAttachment(attachment)

        XCTAssertNotNil(sut.lastErrorMessage)
    }

    // MARK: revealTaskAttachments

    func testRevealTaskAttachments_withoutWorkFolder_reportsTheMissingFolder() async {
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "goal",
                            attachmentPaths: ["a.txt"])

        sut.revealTaskAttachments(task)

        XCTAssertNotNil(sut.lastErrorMessage,
                        "revealing without a folder is a real failure the user should see")
    }

    /// No attachments → nothing to show in Finder. Must return before touching
    /// `NSWorkspace` and must NOT masquerade as an error.
    func testRevealTaskAttachments_taskWithNoAttachments_isSilentNoOp() async {
        await sut.openWorkFolder(tempDir)
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "goal")

        sut.revealTaskAttachments(task)

        XCTAssertNil(sut.lastErrorMessage,
                     "a task with no attachments is not an error state")
    }

    // MARK: createPreparedTaskAndStart

    /// Attachment finalization is the one failure that must roll the whole
    /// creation back — a task whose attachments silently vanished is worse than
    /// no task at all.
    func testCreatePreparedTaskAndStart_finalizationFails_rollsTheTaskBack() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertTrue(sut.snapshot?.tasksIndex.tasks.isEmpty ?? false, "precondition: no tasks yet")

        let request = TaskCreationRequest(
            title: "Doomed",
            rawSupervisorTask: "will not survive",
            preferredTeamID: nil,
            clippedTexts: [],
            stagedAttachments: [
                TaskCreationStagedAttachment(
                    projectRelativePath: ".nanoteams/staged/\(UUID().uuidString)/missing.txt",
                    isProjectReference: false
                )
            ]
        )

        let result = await sut.createPreparedTaskAndStart(request: request)

        XCTAssertNil(result, "creation must fail when its attachments could not be finalized")
        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertTrue(sut.snapshot?.tasksIndex.tasks.isEmpty ?? false,
                      "the half-created task must be removed again, not left orphaned in the index")
    }

    /// Clips are trimmed and empties dropped before they reach the task —
    /// otherwise the prompt grows a `--- Clipped Text ---` section with nothing
    /// under it.
    func testCreatePreparedTaskAndStart_normalizesClippedTexts() async {
        let store = makeOfflineOrchestrator()
        await store.openWorkFolder(tempDir)

        let request = TaskCreationRequest(
            title: "Clips",
            rawSupervisorTask: "do the thing",
            preferredTeamID: nil,
            clippedTexts: ["   ", "\n\t", "  real content  "],
            stagedAttachments: []
        )

        let taskID = await store.createPreparedTaskAndStart(request: request)

        XCTAssertNotNil(taskID)
        XCTAssertEqual(store.activeTask?.clippedTexts.texts, ["real content"],
                       "blank clips must be dropped and survivors trimmed")
        // This path ends in `startRun`, so an engine is live — stop it before
        // the temp folder is torn down.
        store.stopAllEngines()
    }

    // MARK: work-folder settings

    func testSaveToolDefinitions_persistsACustomRecordAndKeepsTheDefaults() async {
        await sut.openWorkFolder(tempDir)
        let defaultCount = sut.toolDefinitions.count
        XCTAssertGreaterThan(defaultCount, 0, "precondition: bootstrap seeded the built-ins")

        let custom = ToolDefinitionRecord(
            id: "orchestrator_core_tail_custom_tool",
            name: "orchestrator_core_tail_custom_tool",
            prompt: "a custom prompt",
            parameters: JSONSchema(type: "object"),
            isBuiltIn: false
        )

        await sut.saveToolDefinitions(sut.toolDefinitions + [custom])

        let saved = sut.toolDefinitions.first(where: { $0.id == custom.id })
        XCTAssertEqual(saved?.prompt, "a custom prompt",
                       "a non-built-in record must survive the merge with its own prompt")
        XCTAssertEqual(sut.toolDefinitions.count, defaultCount + 1,
                       "the built-in definitions must still be merged back in")
    }

    func testSaveToolDefinitions_withoutWorkFolder_isNoOp() async {
        let before = sut.toolDefinitions

        await sut.saveToolDefinitions([
            ToolDefinitionRecord(id: "x", name: "x", prompt: "p",
                                 parameters: JSONSchema(type: "object"), isBuiltIn: false)
        ])

        XCTAssertEqual(sut.toolDefinitions.count, before.count)
        XCTAssertNil(sut.lastErrorMessage)
    }

    func testUpdateContextPrompt_persistsIntoSettings() async {
        await sut.openWorkFolder(tempDir)

        await sut.updateContextPrompt("summarise this repo in one line")

        XCTAssertEqual(sut.workFolder?.settings.contextPrompt, "summarise this repo in one line")
    }

    func testUpdateWorkFolderContext_withoutWorkFolder_isNoOp() async {
        await sut.updateWorkFolderContext("nowhere to write this")

        XCTAssertNil(sut.workFolder,
                     "with no folder open there is nothing to apply the snapshot to")
        XCTAssertNil(sut.lastErrorMessage)
    }

    func testUpdateWorkFolderContext_persistsAndAppliesTheSnapshot() async {
        await sut.openWorkFolder(tempDir)

        await sut.updateWorkFolderContext("a Swift package that does one thing")

        XCTAssertEqual(sut.workFolder?.settings.context, "a Swift package that does one thing")
    }

    func testFetchAvailableSchemes_withoutWorkFolder_returnsEmpty() async {
        let schemes = await sut.fetchAvailableSchemes()

        XCTAssertTrue(schemes.isEmpty)
    }

    func testUpdateSelectedScheme_persistsIntoSettings() async {
        await sut.openWorkFolder(tempDir)

        await sut.updateSelectedScheme("MyScheme")

        XCTAssertEqual(sut.workFolder?.settings.selectedScheme, "MyScheme")
    }

    // MARK: loaded-task views

    /// `allLoadedTasks` is what Watchtower and the sidebar enumerate; a
    /// delegated child is internal to its parent's tool call and must never
    /// surface there.
    func testAllLoadedTasks_excludesDelegatedChildren() async {
        await sut.openWorkFolder(tempDir)
        guard let parent = await sut.createTask(title: "Parent", supervisorTask: "goal") else {
            return XCTFail("parent creation failed")
        }
        guard let child = await sut.createDelegatedTask(
            parentTaskID: parent, parentRoleID: "agent", title: "Child",
            supervisorTask: "sub-goal", preferredTeamID: nil, depth: 1
        ) else {
            return XCTFail("child creation failed")
        }

        let topLevelIDs = Set(sut.allLoadedTasks.map(\.id))
        let allIDs = Set(sut.allLoadedTasksIncludingChildren.map(\.id))

        XCTAssertTrue(topLevelIDs.contains(parent))
        XCTAssertFalse(topLevelIDs.contains(child),
                       "a delegation child is not Supervisor-facing work")
        XCTAssertTrue(allIDs.contains(child),
                      "…but the lifecycle view must still see it")
    }

    func testHasRunningTasks_tracksEngineStates() async {
        let id = await openAndCreateTask()
        XCTAssertFalse(sut.hasRunningTasks)

        sut.engineState[id] = .running
        XCTAssertTrue(sut.hasRunningTasks)

        sut.engineState[id] = .paused
        XCTAssertFalse(sut.hasRunningTasks,
                       "paused is not running — the Play/Pause affordance depends on the distinction")
    }

    func testEvictLoadedTask_dropsOnlyTheBackgroundCopy() async {
        let first = await openAndCreateTask()
        _ = await sut.createTask(title: "Second", supervisorTask: "goal")
        XCTAssertNotNil(sut.loadedTask(first), "precondition: parked in loadedTasks")

        sut.evictLoadedTask(first)

        XCTAssertNil(sut.loadedTask(first))
        XCTAssertNotNil(sut.activeTask, "the active task is unaffected")
    }

    // MARK: Autovisor wake helpers

    /// The watchable set is the single source of truth shared by the wake and
    /// the pass-start seed; it must exclude the manager itself and every
    /// delegated child, or the manager wakes itself in a loop.
    func testAutovisorWatchableTasks_excludesTheManagerAndDelegatedChildren() async {
        await sut.openWorkFolder(tempDir)
        guard let manager = await sut.createTask(title: "Manager", supervisorTask: "manage"),
              let worker = await sut.createTask(title: "Worker", supervisorTask: "work"),
              let child = await sut.createDelegatedTask(
                  parentTaskID: worker, parentRoleID: "agent", title: "Child",
                  supervisorTask: "sub", preferredTeamID: nil, depth: 1)
        else {
            return XCTFail("task creation failed")
        }

        let watchable = Set(sut.autovisorWatchableTasks(excluding: manager).map(\.id))

        XCTAssertEqual(watchable, [worker],
                       "only top-level non-manager tasks are watchable; got \(watchable)")
        XCTAssertFalse(watchable.contains(child))
    }

    /// Setting and clearing the Manager role's model override — the Settings
    /// Model card's only write path. An all-empty override must clear the slot
    /// rather than persist an empty struct.
    func testSetAutovisorLLMOverride_setsThenClearsTheManagerRoleOverride() async {
        await sut.openWorkFolder(tempDir)
        await sut.ensureAutovisorTeam()
        XCTAssertNotNil(sut.autovisorRole, "precondition: the hidden Autovisor team exists")

        await sut.setAutovisorLLMOverride(
            baseURL: "http://127.0.0.1:11434", model: "some-model", provider: .ollama)

        XCTAssertEqual(sut.autovisorRole?.llmOverride?.modelName, "some-model")
        XCTAssertEqual(sut.autovisorRole?.llmOverride?.baseURLString, "http://127.0.0.1:11434")
        XCTAssertEqual(sut.autovisorRole?.llmOverride?.provider, .ollama)

        await sut.setAutovisorLLMOverride(baseURL: "   ", model: "", provider: nil)

        XCTAssertNil(sut.autovisorRole?.llmOverride,
                     "an all-blank override must clear the slot, not persist an empty struct")
    }
}
