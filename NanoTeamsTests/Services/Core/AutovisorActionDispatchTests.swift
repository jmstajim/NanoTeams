import XCTest

@testable import NanoTeams

/// `NTMSOrchestrator+AutovisorActions` — the single delegate hook every Autovisor
/// WRITE goes through, plus its `control_task` / `manage_role` verb dispatchers and
/// the three small read/persist delegate hooks beside them.
///
/// Scope split from the neighbouring suites deliberately:
///  - `AutovisorOrchestratorTests` owns the caps, the team-resolution failures and the
///    `restart`-is-destructive guard;
///  - `AutovisorChatRoleAcceptTests` owns the `accept` / `finish_advisory` routing;
///  - `AutovisorReportingErrorTests` owns `reportingError`'s counter mechanism;
///  - `TeamGenerationRetryReportingTests` owns the synthetic `team_generation_*` step.
///
/// What is left — and what this suite covers — is the DISPATCH: that the hook-level
/// guards apply to every action SHAPE (not just `control_task`), that each
/// `ControlVerb` arm performs its operation and reports an HONEST result, that the
/// two `manage_role` verbs nobody drove before (`request_changes`, `correct`) convert
/// a surfaced failure into `.failure` rather than `ok:true`, and the memory / task-load
/// / stream-activity hooks.
///
/// **No engine is ever started and nothing reaches the network.** The verbs that could
/// (`start`, `message_task`'s wake) are driven either through `startingRunTaskIDs` — so
/// `startRun` is a no-op and the honest-failure arm is what gets pinned — or through
/// `makeEngineFreeStartableTask()`, whose contract is documented at the helper.
/// `resume` is deliberately absent: every path through `resumeRun` ends in
/// `engineForTask(...).start()`.
///
/// Every test method is `async` — a sync `@MainActor` test that constructs a
/// `@MainActor` class `abort()`s on CI (CLAUDE.md §Testing Conventions).
@MainActor
final class AutovisorActionDispatchTests: NTMSOrchestratorTestBase {

    /// The orchestrator holds `quickCaptureFormState` weakly, so the test must own the
    /// strong reference for the whole method (`message_task` is unrepresentable without it).
    private var formState: QuickCaptureFormState!

    override func setUp() {
        super.setUp()
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
    }

    override func tearDown() {
        formState = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Opens the temp work folder and pins a freshly-created (non-running) task as the
    /// manager, WITHOUT enabling the feature — so no engine and no LLM are ever started.
    /// Verbatim from `AutovisorOrchestratorTests` / `AutovisorChatRoleAcceptTests`.
    @discardableResult
    private func pinManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = mgrID }
        return mgrID
    }

    /// A plain, loaded, non-manager task. Loading it HERE matters: the action hook's own
    /// `ensureTaskLoaded` would otherwise run `syncEngineStateFromRun` and seed an engine
    /// state under the test's feet, which the `control_task start` guard reads.
    private func makeWorkerTask(title: String = "Worker") async -> Int? {
        guard let id = await sut.createTask(title: title, supervisorTask: "do x", makeActive: false) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(id)
        return id
    }

    /// Replaces the task's runs with a single run carrying `steps`.
    private func injectRun(
        taskID: Int, steps: [StepExecution], statuses: [String: RoleExecutionStatus] = [:]
    ) async {
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: steps, roleStatuses: statuses)]
        }
    }

    private func latestRun(_ taskID: Int) -> Run? { sut.loadedTask(taskID)?.runs.last }
    private func runCount(_ taskID: Int) -> Int { sut.loadedTask(taskID)?.runs.count ?? -1 }
    private var taskCount: Int { sut.snapshot?.tasksIndex.tasks.count ?? -1 }

    private func generatedPlaceholderTeams() -> [Team] {
        (sut.snapshot?.workFolder.teams ?? [])
            .filter { $0.templateID == DelegationConstants.generatedTeamSentinel }
    }

    /// A task `startRun` will genuinely ACT on (it appends a run) that can never start an
    /// engine or reach the network.
    ///
    /// It is pinned to the "Generated Team" placeholder, so `startRun` takes the
    /// team-generation branch and returns BEFORE `engine.start()`. The brief is
    /// deliberately EMPTY: `runTeamGeneration` bails on an empty
    /// `effectiveSupervisorBrief` before it builds any LLM request, so the detached
    /// generation Task is a no-op. Net effect: `runs.count` grows by one, and nothing else.
    private func makeEngineFreeStartableTask() async -> Int? {
        let placeholder = TeamTemplateFactory.generatedTeam()
        await sut.mutateWorkFolder { proj in
            if !proj.teams.contains(where: { $0.templateID == DelegationConstants.generatedTeamSentinel }) {
                proj.teams.append(placeholder)
            }
        }
        guard let genID = generatedPlaceholderTeams().first?.id else {
            XCTFail("the generated placeholder team must be present after seeding"); return nil
        }
        guard let id = await sut.createTask(
            title: "Startable", supervisorTask: "", preferredTeamID: genID, makeActive: false
        ) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(id)
        XCTAssertEqual(runCount(id), 0, "premise: a fresh task has no runs yet")
        return id
    }

    /// One action of every task-targeted SHAPE. The self-guard and the existence guard
    /// live on the hook, above the switch — so they must hold for all five, not just for
    /// `control_task` (the only shape previously driven through them).
    private func taskTargetedActions(for taskID: Int) -> [AutovisorAction] {
        [
            .controlTask(taskID: taskID, verb: .pause),
            .manageRole(taskID: taskID, roleID: "r", verb: .accept),
            .answerTaskQuestion(taskID: taskID, answer: "yes"),
            .messageTask(taskID: taskID, text: "focus on auth", roleID: nil),
            .scheduleTask(taskID: taskID, intervalMinutes: 15),
        ]
    }

    // MARK: - Hook-level guards (self-guard + task existence)

    /// The self-guard sits above the switch, so EVERY task-targeted shape must be refused
    /// on the manager's own task — acting on it would deadlock or self-destruct. Pinning
    /// only `control_task` would leave four shapes free to reach their arm.
    func testSelfGuard_refusesEveryTaskTargetedActionShape() async {
        let mgrID = await pinManager()
        // Load it here: the self-guard returns BEFORE the hook's own `ensureTaskLoaded`,
        // so without this the post-loop assertions would read an unloaded task and pass
        // vacuously.
        await sut.ensureTaskLoaded(mgrID)
        let runsBefore = runCount(mgrID)

        for action in taskTargetedActions(for: mgrID) {
            let r = await sut.performAutovisorAction(action)
            XCTAssertFalse(r.ok, "the manager must never act on its own task: \(action)")
            XCTAssertTrue(r.message.contains("#\(mgrID)"),
                          "the refusal must name the task; got \(r.message)")
        }

        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 0,
                       "a refused message_task must not leave a queued message behind")
        XCTAssertNil(sut.loadedTask(mgrID)?.recurrence,
                     "a refused schedule_task must not have written a recurrence")
        XCTAssertEqual(runCount(mgrID), runsBefore, "and nothing may have started a run")
    }

    /// The counterpart: folder-level actions carry no `targetTaskID`, so the self-guard
    /// must pass them straight through even while a manager is pinned.
    func testSelfGuard_folderLevelActionIsNotRefused() async {
        _ = await pinManager()
        let r = await sut.performAutovisorAction(.setWorkFolderContext(content: "A Swift app."))
        XCTAssertTrue(r.ok, "a folder-level action has no target and must not be self-guarded: \(r.message)")
    }

    /// A task-targeted action against a task that doesn't exist must fail LOUDLY here
    /// rather than no-op'ing silently somewhere downstream — for every shape.
    func testMissingTask_everyShape_failsLoudlyWithoutMutating() async {
        _ = await pinManager()
        let ghostID = 99_999
        let tasksBefore = taskCount

        for action in taskTargetedActions(for: ghostID) {
            let r = await sut.performAutovisorAction(action)
            XCTAssertFalse(r.ok, "an action against a missing task must fail: \(action)")
            XCTAssertTrue(r.message.contains("\(ghostID)"),
                          "the failure must name the bad task id; got \(r.message)")
        }

        XCTAssertEqual(formState.queuedMessages(for: ghostID).count, 0,
                       "no message may be queued for a task that doesn't exist")
        XCTAssertEqual(taskCount, tasksBefore, "and no task may be created or removed")
    }

    // MARK: - answer_task_question

    /// The guard arm: without a step actually parked on `needsSupervisorInput` there is
    /// nothing to answer, and reporting success would tell the manager a blocked task was
    /// unblocked.
    func testAnswerTaskQuestion_noPendingQuestion_failsLoudly() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }

        // (a) no run at all
        let noRun = await sut.performAutovisorAction(.answerTaskQuestion(taskID: id, answer: "yes"))
        XCTAssertFalse(noRun.ok, "a task with no run is not waiting for input")
        XCTAssertTrue(noRun.message.contains("not waiting for supervisor input"), noRun.message)

        // (b) a run whose step is simply running
        await injectRun(
            taskID: id,
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .running)],
            statuses: ["r": .working])
        let notWaiting = await sut.performAutovisorAction(.answerTaskQuestion(taskID: id, answer: "yes"))
        XCTAssertFalse(notWaiting.ok, "a running step is not waiting for input")
        XCTAssertTrue(notWaiting.message.contains("not waiting for supervisor input"), notWaiting.message)
        XCTAssertNil(latestRun(id)?.steps.first?.supervisorAnswer,
                     "a refused answer must not be written to the step")
    }

    /// The delivery arm. `isAutoAnswer: true` is not cosmetic — it drives the feed's
    /// "Auto-answered" badge, which is the only signal separating an LLM-authored answer
    /// from a human one.
    func testAnswerTaskQuestion_deliversTheAnswerAndMarksItAutomated() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        await injectRun(
            taskID: id,
            steps: [StepExecution(
                id: "r", role: .softwareEngineer, title: "Engineer",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Which database should I use?")],
            statuses: ["r": .working])

        let r = await sut.performAutovisorAction(
            .answerTaskQuestion(taskID: id, answer: "Use SQLite."))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("#\(id)"), "the success must name the task; got \(r.message)")
        let step = latestRun(id)?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "Use SQLite.")
        XCTAssertEqual(step?.supervisorAnswerWasAuto, true,
                       "the Autovisor is an LLM — its answer must carry the automated flag")
        XCTAssertEqual(step?.needsSupervisorInput, false,
                       "the pending-question flag must be cleared by the delivery")
    }

    // MARK: - message_task

    /// Without a form state there is nowhere to queue — the action must say so instead of
    /// reporting a message the task will never receive.
    func testMessageTask_withoutFormState_failsLoudly() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        sut.quickCaptureFormState = nil   // the weak ref the queue lives behind

        let r = await sut.performAutovisorAction(
            .messageTask(taskID: id, text: "focus on auth", roleID: nil))

        XCTAssertFalse(r.ok, "no queue → the message cannot be delivered")
        XCTAssertTrue(r.message.contains("#\(id)"), r.message)
        XCTAssertEqual(runCount(id), 0, "and a failed queue must not have woken the task")
    }

    /// `QueuedChatMessage.init?` rejects an empty payload, so an empty `message_task` must
    /// surface as a failure rather than a phantom success.
    func testMessageTask_emptyText_failsLoudly() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }

        let r = await sut.performAutovisorAction(.messageTask(taskID: id, text: "   ", roleID: nil))

        XCTAssertFalse(r.ok, "an empty payload can never enter the queue")
        XCTAssertEqual(formState.queuedMessages(for: id).count, 0)
        XCTAssertEqual(runCount(id), 0, "and it must not wake the task either")
    }

    /// A RUNNING task picks the message up on its next tool-loop iteration, so the wake
    /// branch must be skipped — a fresh run there would discard the pass mid-flight.
    func testMessageTask_runningTask_queuesWithoutStartingARun() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        await injectRun(
            taskID: id,
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .running)],
            statuses: ["r": .working])
        sut.engineState[id] = .running
        let before = runCount(id)

        let r = await sut.performAutovisorAction(
            .messageTask(taskID: id, text: "focus on auth", roleID: "r"))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(runCount(id), before, "a running task must not be superseded by a message")
        let queued = formState.queuedMessages(for: id)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.text, "focus on auth")
        XCTAssertEqual(queued.first?.targetRoleID, "r", "role targeting must survive the hop")
        XCTAssertEqual(queued.first?.isFromAutomatedSupervisor, true,
                       "an Autovisor-authored message must be flagged automated, or a "
                    + "backstop delivery would render it with the human checkmark")
    }

    /// An idle task is woken so it drains the queue on iteration 1 — otherwise a message to
    /// a parked task sits unread forever.
    func testMessageTask_idleTask_queuesAndWakesIt() async {
        _ = await pinManager()
        guard let id = await makeEngineFreeStartableTask() else { return }
        XCTAssertNil(sut.taskEngineStates[id], "premise: nothing is running")

        let r = await sut.performAutovisorAction(
            .messageTask(taskID: id, text: "please continue", roleID: nil))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(formState.queuedMessages(for: id).count, 1)
        XCTAssertEqual(runCount(id), 1, "an idle task must be woken so it drains the queue")
    }

    // MARK: - schedule_task

    func testScheduleTask_positiveInterval_setsAnEnabledIntervalRecurrence() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }

        let r = await sut.performAutovisorAction(.scheduleTask(taskID: id, intervalMinutes: 30))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("30"), "the confirmation must name the interval; got \(r.message)")
        guard let recurrence = sut.loadedTask(id)?.recurrence else {
            return XCTFail("a positive interval must persist a recurrence")
        }
        XCTAssertTrue(recurrence.isEnabled)
        XCTAssertNotNil(recurrence.nextFireAt,
                        "reschedule must have resolved a future slot — an enabled recurrence "
                      + "with no nextFireAt is invisible to the scheduler")
        guard case .interval(let seconds) = recurrence.rule else {
            return XCTFail("expected an interval rule, got \(recurrence.rule)")
        }
        XCTAssertEqual(seconds, 1800, "minutes must be converted to seconds")
    }

    /// `intervalMinutes == 0` is the documented "clear the schedule" spelling.
    func testScheduleTask_zeroInterval_clearsTheRecurrence() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        _ = await sut.performAutovisorAction(.scheduleTask(taskID: id, intervalMinutes: 45))
        XCTAssertNotNil(sut.loadedTask(id)?.recurrence, "premise: a schedule exists")

        let r = await sut.performAutovisorAction(.scheduleTask(taskID: id, intervalMinutes: 0))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.lowercased().contains("cleared"), r.message)
        XCTAssertNil(sut.loadedTask(id)?.recurrence, "zero must clear, not set a degenerate schedule")
    }

    /// Corner: a negative interval takes the same clear branch — it must never become a
    /// negative-seconds rule the scheduler would then have to interpret.
    func testScheduleTask_negativeInterval_alsoClears() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        _ = await sut.performAutovisorAction(.scheduleTask(taskID: id, intervalMinutes: 45))

        let r = await sut.performAutovisorAction(.scheduleTask(taskID: id, intervalMinutes: -5))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertNil(sut.loadedTask(id)?.recurrence, "a negative interval must clear, never persist")
    }

    // MARK: - set_work_folder_context

    func testSetWorkFolderContext_persistsAndReportsSuccess() async {
        _ = await pinManager()

        let r = await sut.performAutovisorAction(
            .setWorkFolderContext(content: "A macOS SwiftUI app with no external packages."))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.context,
                       "A macOS SwiftUI app with no external packages.",
                       "the folder-wide context must actually be written")
    }

    // MARK: - control_task start (the honest-result contract)

    /// `startRun` silently returns when the engine is already active, so `start` must
    /// pre-check and report failure — reporting `ok:true` there tells the manager it
    /// restarted something it did not touch. Covers all three active states.
    func testControlTaskStart_activeEngineStates_reportFailureNotFalseSuccess() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }

        for state in [TeamEngineState.running, .needsAcceptance, .needsSupervisorInput] {
            sut.engineState[id] = state
            let before = runCount(id)

            let r = await sut.performAutovisorAction(.controlTask(taskID: id, verb: .start))

            XCTAssertFalse(r.ok, "start on an already-active engine (\(state)) must fail")
            XCTAssertTrue(r.message.contains("already running"),
                          "the failure must say why; got \(r.message)")
            XCTAssertEqual(runCount(id), before, "and must not append a run")
        }
    }

    /// The complement, which is what makes the assertion above about the GUARD rather than
    /// about `startRun`: from every non-active state the guard lets the call through, and a
    /// `startRun` that then no-ops (here: an in-flight start already owns the run) is still
    /// reported as a FAILURE — never `ok:true` on a no-op.
    func testControlTaskStart_inactiveStates_passTheGuard_andASilentNoOpIsReportedAsFailure() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }

        // `startRun`'s re-entrancy guard: makes it a deterministic no-op with no engine,
        // no run and no error banner — exactly the silent-no-op shape being pinned.
        sut.startingRunTaskIDs.insert(id)
        defer { sut.startingRunTaskIDs.remove(id) }

        let inactive: [TeamEngineState?] = [nil, .pending, .paused, .done, .failed]
        for state in inactive {
            sut.engineState[id] = state
            sut.lastErrorMessage = nil
            let before = runCount(id)

            let r = await sut.performAutovisorAction(.controlTask(taskID: id, verb: .start))

            XCTAssertFalse(r.ok, "a start that appended no run must be reported as failure "
                               + "(state \(String(describing: state)))")
            XCTAssertFalse(r.message.contains("already running"),
                           "state \(String(describing: state)) is not active — the active guard "
                         + "must not fire; got \(r.message)")
            XCTAssertTrue(r.message.contains("could not start"),
                          "the honest no-op message must be used; got \(r.message)")
            XCTAssertEqual(runCount(id), before)
        }
    }

    /// The success arm: a real `startRun` that appends a run reports success.
    func testControlTaskStart_appendsRunAndReportsSuccess() async {
        _ = await pinManager()
        guard let id = await makeEngineFreeStartableTask() else { return }

        let r = await sut.performAutovisorAction(.controlTask(taskID: id, verb: .start))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("Started task #\(id)"), r.message)
        XCTAssertEqual(runCount(id), 1, "a started task must carry the fresh run")
    }

    // MARK: - control_task pause / stop / close / delete / rename / set_timeout

    /// `pause` must actually drain the run's live step — a success message next to a
    /// forever-`.running` step is the lie the honest-results work exists to remove.
    func testControlTaskPause_drainsTheRunningStep() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        await injectRun(
            taskID: id,
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .running)],
            statuses: ["r": .working])
        sut.engineState[id] = .running

        let r = await sut.performAutovisorAction(.controlTask(taskID: id, verb: .pause))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("Paused task #\(id)"), r.message)
        XCTAssertEqual(latestRun(id)?.steps.first?.status, .paused,
                       "the step must be drained, not merely reported paused")
    }

    /// `stop` drops the engine registration, which is also the documented escape hatch that
    /// lifts the paused-restart guard.
    func testControlTaskStop_dropsTheEngineState() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        sut.engineState[id] = .running

        let r = await sut.performAutovisorAction(.controlTask(taskID: id, verb: .stop))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("Stopped task #\(id)"), r.message)
        XCTAssertNil(sut.taskEngineStates[id], "stop must remove the engine registration")
    }

    func testControlTaskClose_stampsClosedAtAndReportsSuccess() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        await injectRun(
            taskID: id,
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)],
            statuses: ["r": .done])
        XCTAssertNil(sut.loadedTask(id)?.closedAt, "premise: open")

        let r = await sut.performAutovisorAction(.controlTask(taskID: id, verb: .close))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("Closed task #\(id)"), r.message)
        XCTAssertNotNil(sut.loadedTask(id)?.closedAt, "close must actually terminate the task")
    }

    /// `delete` is the verb whose false `ok:true` was most expensive — a task still on disk
    /// keeps occupying the manager's "ONE TASK IN FLIGHT" slot and keeps firing its
    /// recurrence. Pin that a successful delete really removed it from the index.
    func testControlTaskDelete_removesTheTaskFromTheIndex() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask(title: "Doomed") else { return }
        let before = taskCount

        let r = await sut.performAutovisorAction(.controlTask(taskID: id, verb: .delete))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("Deleted task #\(id)"), r.message)
        XCTAssertEqual(taskCount, before - 1)
        XCTAssertFalse(sut.snapshot?.tasksIndex.tasks.contains { $0.id == id } ?? true,
                       "a reported deletion must be a real deletion")
    }

    func testControlTaskRename_updatesTheTitleAndNamesItBack() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask(title: "Old Name") else { return }

        let r = await sut.performAutovisorAction(
            .controlTask(taskID: id, verb: .rename(title: "Harden the parser")))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("Harden the parser"),
                      "the confirmation must echo the new title; got \(r.message)")
        XCTAssertEqual(sut.loadedTask(id)?.title, "Harden the parser")
    }

    /// `set_timeout` carries an OPTIONAL seconds value, and the two arms have different
    /// wording — a shared message would make "cleared" indistinguishable from "set".
    func testControlTaskSetTimeout_setsThenClears() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }

        let set = await sut.performAutovisorAction(
            .controlTask(taskID: id, verb: .setTimeout(seconds: 1800)))
        XCTAssertTrue(set.ok, set.message)
        XCTAssertTrue(set.message.contains("Set run timeout"), set.message)
        XCTAssertEqual(sut.loadedTask(id)?.runTimeoutSeconds, 1800)

        let cleared = await sut.performAutovisorAction(
            .controlTask(taskID: id, verb: .setTimeout(seconds: nil)))
        XCTAssertTrue(cleared.ok, cleared.message)
        XCTAssertTrue(cleared.message.contains("Cleared run timeout"), cleared.message)
        XCTAssertNil(sut.loadedTask(id)?.runTimeoutSeconds)
    }

    // MARK: - manage_role request_changes

    func testManageRoleRequestChanges_onCompletedRole_recordsTheRevision() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        await injectRun(
            taskID: id,
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)],
            statuses: ["r": .done])

        let r = await sut.performAutovisorAction(
            .manageRole(taskID: id, roleID: "r", verb: .requestChanges(comment: "add tests")))

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("Requested changes"), r.message)
        XCTAssertEqual(latestRun(id)?.roleStatuses["r"], .revisionRequested)
        XCTAssertEqual(latestRun(id)?.steps.first?.revisionComment, "add tests",
                       "the feedback must be recorded as the artifact-completion gate")
    }

    /// `requestRevision` refuses a role with no completed work and reports it via
    /// `lastErrorMessage`; `reportingError` must convert that into a `.failure` carrying the
    /// specific reason, not a generic success.
    func testManageRoleRequestChanges_onLiveRole_failsWithTheSurfacedReason() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        await injectRun(
            taskID: id,
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .running)],
            statuses: ["r": .working])

        let r = await sut.performAutovisorAction(
            .manageRole(taskID: id, roleID: "r", verb: .requestChanges(comment: "add tests")))

        XCTAssertFalse(r.ok, "a role with nothing completed cannot be revised")
        XCTAssertTrue(r.message.contains("no completed work"),
                      "the specific reason must reach the manager; got \(r.message)")
        XCTAssertEqual(latestRun(id)?.roleStatuses["r"], .working,
                       "a refused request_changes must leave the role untouched")
        XCTAssertNil(latestRun(id)?.steps.first?.revisionComment)
    }

    // MARK: - manage_role correct

    /// `correctRole` hard-requires a paused task, so the verb pre-checks and returns an
    /// ACTIONABLE message. The existing `testCorrect_notPaused_fails` stops at the
    /// role-existence guard (its own comment says so); this drives a real role so the
    /// not-paused guard is what fires.
    func testManageRoleCorrect_realRoleButTaskNotPaused_namesThePrerequisite() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        await injectRun(
            taskID: id,
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .running)],
            statuses: ["r": .working])
        sut.engineState[id] = .running

        let r = await sut.performAutovisorAction(
            .manageRole(taskID: id, roleID: "r", verb: .correct(comment: "prefer SQLite")))

        XCTAssertFalse(r.ok, "correct on a live task must be refused, not silently dropped")
        XCTAssertTrue(r.message.contains("paused"), r.message)
        XCTAssertTrue(r.message.contains("control_task pause"),
                      "the refusal must name the verb that makes it possible; got \(r.message)")
        XCTAssertTrue(latestRun(id)?.steps.first?.messages.isEmpty ?? false,
                      "no correction may have been appended")
    }

    /// The engine is paused but the STEP is not — `correctRole` surfaces its own failure and
    /// returns before touching anything. `reportingError` must relay that as a failure;
    /// pre-fix this whole class read back as `ok:true`.
    func testManageRoleCorrect_pausedEngineButLiveStep_surfacesTheFailure() async {
        _ = await pinManager()
        guard let id = await makeWorkerTask() else { return }
        await injectRun(
            taskID: id,
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .running)],
            statuses: ["r": .working])
        sut.engineState[id] = .paused   // engine paused, step never drained

        let r = await sut.performAutovisorAction(
            .manageRole(taskID: id, roleID: "r", verb: .correct(comment: "prefer SQLite")))

        XCTAssertFalse(r.ok, "a correction that could not be applied must not report success")
        XCTAssertTrue(r.message.contains("no longer paused") || r.message.contains("step is missing"),
                      "the specific reason must reach the manager; got \(r.message)")
        XCTAssertNil(latestRun(id)?.steps.first?.revisionComment,
                     "and nothing may have been written")
    }

    // MARK: - create_managed_task → the lazily-materialized generated placeholder

    /// The `"generated"` sentinel resolves through `ensureGeneratedTeamID`, which creates
    /// the placeholder team on first use and REUSES it afterwards. A second placeholder
    /// would give the folder two teams claiming the same template id.
    ///
    /// Both creations use an EMPTY brief on purpose: `runTeamGeneration` bails on an empty
    /// `effectiveSupervisorBrief` before building any LLM request, so the detached
    /// generation the started run spawns is a no-op (no engine, no network).
    func testCreateManagedTask_generatedSentinel_materializesThePlaceholderExactlyOnce() async {
        _ = await pinManager()
        XCTAssertTrue(sut.snapshot?.workFolder.settings.autovisorAllowTeamGeneration ?? false,
                      "premise: generation is allowed by default")
        XCTAssertEqual(generatedPlaceholderTeams().count, 0, "premise: no placeholder yet")

        let first = await sut.performAutovisorAction(
            .createManagedTask(title: "One", brief: "",
                               teamID: DelegationConstants.generatedTeamSentinel))
        XCTAssertTrue(first.ok, first.message)
        XCTAssertEqual(generatedPlaceholderTeams().count, 1,
                       "the sentinel must lazily materialize the placeholder team")
        guard let genID = generatedPlaceholderTeams().first?.id,
              let firstTaskID = first.createdTaskID else {
            return XCTFail("expected a placeholder team and a created task id")
        }
        XCTAssertEqual(sut.loadedTask(firstTaskID)?.preferredTeamID, genID,
                       "the new task must be pinned to the placeholder, not the active team")

        let second = await sut.performAutovisorAction(
            .createManagedTask(title: "Two", brief: "",
                               teamID: DelegationConstants.generatedTeamSentinel))
        XCTAssertTrue(second.ok, second.message)
        XCTAssertEqual(generatedPlaceholderTeams().count, 1,
                       "a second sentinel must REUSE the placeholder, not append a duplicate")
        guard let secondTaskID = second.createdTaskID else {
            return XCTFail("expected a created task id")
        }
        XCTAssertEqual(sut.loadedTask(secondTaskID)?.preferredTeamID, genID,
                       "and it must resolve to the same team id")
    }

    // MARK: - persistAutovisorMemory

    /// The manager's memory is its only cross-run state, so the write-through must both
    /// land and report that it landed.
    func testPersistAutovisorMemory_writesThroughAndReportsSuccess() async {
        _ = await pinManager()

        let ok = await sut.persistAutovisorMemory("Reviewed 2 tasks; parser milestone blocked.")

        XCTAssertTrue(ok, "a successful settings.json write must report success")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorMemory,
                       "Reviewed 2 tasks; parser milestone blocked.")
    }

    /// A banner left over from BEFORE the write must not be attributed to it — otherwise
    /// the manager would be told it forgot every time anything else had failed earlier.
    func testPersistAutovisorMemory_staleBannerIsNotAttributedToTheWrite() async {
        _ = await pinManager()
        sut.lastErrorMessage = "an earlier, unrelated failure"

        let ok = await sut.persistAutovisorMemory("second memory")

        XCTAssertTrue(ok, "a pre-existing banner is not this write's failure")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorMemory, "second memory")
    }

    // MARK: - autovisorLoadTask

    /// `task_status` inspects background tasks, which are NOT in `loadedTasks` — the hook
    /// exists to hydrate them on demand.
    func testAutovisorLoadTask_hydratesABackgroundTask() async {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "Background", supervisorTask: "x", makeActive: false) else {
            return XCTFail("createTask failed")
        }
        XCTAssertNil(sut.loadedTask(id), "premise: a makeActive:false task is not held in memory")

        let loaded = await sut.autovisorLoadTask(id)

        XCTAssertEqual(loaded?.id, id)
        XCTAssertEqual(loaded?.title, "Background")
    }

    /// A hallucinated task id must come back nil rather than a fabricated blank task.
    func testAutovisorLoadTask_unknownTask_returnsNil() async {
        await sut.openWorkFolder(tempDir)
        let loaded = await sut.autovisorLoadTask(99_999)
        XCTAssertNil(loaded, "an id that isn't on disk must not resolve")
    }

    // MARK: - streamLastActivityAt

    /// Feeds the stuck-detector's hang check. The key is `(taskID, stepID)`, never stepID
    /// alone — `StepExecution.id` IS the role id, so two concurrent tasks on one team share
    /// step ids (CLAUDE.md multi-task invariant #5) and a stepID-only lookup would report a
    /// sibling task's activity as this one's.
    func testStreamLastActivityAt_nilUntilMarked_andKeyedByTaskAndStep() async {
        XCTAssertNil(sut.streamLastActivityAt(stepID: "r", taskID: 7),
                     "no live stream → no activity timestamp")

        sut.streamingPreviewManager.markStreamActivity(stepID: "r", taskID: 7)

        XCTAssertNotNil(sut.streamLastActivityAt(stepID: "r", taskID: 7))
        XCTAssertNil(sut.streamLastActivityAt(stepID: "r", taskID: 8),
                     "same step id on another task must not inherit the timestamp")
        XCTAssertNil(sut.streamLastActivityAt(stepID: "other", taskID: 7),
                     "another step on the same task must not inherit it either")
    }
}
