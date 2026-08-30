import XCTest

@testable import NanoTeams

/// The reported bug: *«Autovisor иногда не просыпается, когда получается вопрос от роли
/// из чата»*.
///
/// A chat role asks, the manager answers, the role asks AGAIN — and the second question
/// did not wake the parked manager. `autovisorLastPassAttentionKeys` is keyed
/// `(taskID, trigger)`, so the key from the FIRST question outlived the question it
/// identified (CLAUDE.md #74) and `hasFreshCondition` read false for every later one. The
/// per-minute poll could not rescue it — it evaluates the same gate — so the question
/// waited for the 10-minute recurrence.
///
/// Two mechanisms retire a spent key, and this suite pins them separately:
/// • the RESOLVER (`answerSupervisorQuestion` → `noteSupervisorQuestionResolved`) —
///   positive evidence at the moment of resolution, no sampling required;
/// • the WAKE's own prune, for the clearing paths that don't route through an answer
///   (`manage_role restart`, `control_task stop`, a superseded run).
///
/// Also pins the second half of the same symptom: the `.needsSupervisor` trigger read the
/// ENGINE MIRROR, which `StatusRecoveryService` demotes to `.paused` at launch while the
/// durable question survives (CLAUDE.md #91).
///
/// Every fixture here runs with `onTaskNeedsSupervisor` as the ONLY enabled trigger unless
/// a test says otherwise — a background step that fails or completes must never be able to
/// carry a wake this suite is attributing to the question.
@MainActor
final class AutovisorReAskWakeTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var formState: QuickCaptureFormState!

    override func setUp() async throws {
        try await super.setUp()
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
    }

    override func tearDown() async throws {
        formState = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A manager parked on `wait_for_events`, with `onTaskNeedsSupervisor` the only
    /// enabled trigger so no sibling condition can carry a wake.
    @discardableResult
    private func parkedManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorActivation = AutovisorActivation(
                onTaskNeedsSupervisor: true, onTaskFailed: false, onTaskCompleted: false,
                onTaskCreated: false, onTaskStuck: false)
        }
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            let step = StepExecution(
                id: "r", role: .softwareEngineer, title: "Mgr",
                status: .needsSupervisorInput, needsSupervisorInput: true,
                supervisorQuestion: AutovisorConstants.idleParkQuestion)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[mgrID] = .needsSupervisorInput
        return mgrID
    }

    private func chatTeamID() -> NTMSID {
        sut.snapshot?.workFolder.teams
            .first(where: { $0.isChatMode && !$0.isHiddenFromPickers })?.id ?? "missing"
    }

    private func startupTeamID() -> NTMSID {
        sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id ?? "missing"
    }

    /// A chat-mode task whose advisory role called `ask_supervisor` and parked.
    private func makeAskingChatTask(question: String = "Which database should I use?") async -> Int {
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "help me",
                                          preferredTeamID: chatTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Assistant",
                                     status: .needsSupervisorInput, needsSupervisorInput: true,
                                     supervisorQuestion: question)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[taskID] = .needsSupervisorInput
        return taskID
    }

    /// The role asks the NEXT question on an existing task.
    private func askAgain(_ taskID: Int, question: String = "And which ORM?") async {
        await sut.mutateTask(taskID: taskID) { task in
            guard let r = task.runs.indices.last, let s = task.runs[r].steps.indices.first else { return }
            task.runs[r].steps[s].status = .needsSupervisorInput
            task.runs[r].steps[s].needsSupervisorInput = true
            task.runs[r].steps[s].supervisorQuestion = question
            task.runs[r].steps[s].supervisorAnswer = nil
        }
        sut.engineState[taskID] = .needsSupervisorInput
    }

    /// A clearing path that is NOT an answer — `manage_role restart` / `control_task stop`
    /// reset the step, so the question goes quiet with no `answerSupervisorQuestion` call.
    private func clearQuestionByRestart(_ taskID: Int) async {
        await sut.mutateTask(taskID: taskID) { task in
            guard let r = task.runs.indices.last, let s = task.runs[r].steps.indices.first else { return }
            task.runs[r].steps[s].status = .running
            task.runs[r].steps[s].needsSupervisorInput = false
            task.runs[r].steps[s].supervisorQuestion = nil
            task.runs[r].steps[s].toolCalls = []
        }
        sut.engineState[taskID] = .running
    }

    /// The restart-recovered shape: `StatusRecoveryService` demotes the parked step's
    /// STATUS to `.paused` and leaves the durable flag + question, and no engine exists.
    private func makeRecoveredParkedTask() async -> Int {
        let taskID = await sut.createTask(title: "Recovered", supervisorTask: "help me",
                                          preferredTeamID: chatTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Assistant",
                                     status: .paused, needsSupervisorInput: true,
                                     supervisorQuestion: "Which database should I use?")
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        // Deliberately NO `sut.engineState[taskID]` — after a relaunch `taskEngines` is empty.
        return taskID
    }

    private func runCount(_ taskID: Int) -> Int { sut.loadedTask(taskID)?.runs.count ?? -1 }

    private func nsKey(_ id: Int) -> NTMSOrchestrator.AutovisorAttentionKey {
        .init(taskID: id, trigger: .needsSupervisor)
    }

    private func indexRow(_ id: Int) -> TaskSummary? {
        sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == id })
    }

    // MARK: - The reported repro

    func testSecondQuestion_afterTheManagerAnsweredTheFirst_wakesTheManagerAgain() async {
        let mgrID = await parkedManager()
        let chatID = await makeAskingChatTask()

        // The manager's pass baselines Q1 — this is the key that used to outlive it.
        sut.seedAutovisorNotifiedKeysForPassStart()
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(nsKey(chatID)),
                      "premise: the manager's pass records Q1 in the deliver-once baseline")

        _ = await sut.answerSupervisorQuestion(stepID: "r", taskID: chatID, answer: "Use Postgres.")
        sut.stopEngineForTask(chatID)   // the resume spawns a run loop this test isn't about

        // Sampled BEFORE the second question, not after: since the engine-state observer
        // schedules its own wake, Q2 may reach the manager through that path instead of the
        // explicit call below. The property under test is "a second question wakes the
        // manager", not "this particular caller does" — measuring across both keeps the pin
        // on the property and independent of which one gets there first.
        let before = runCount(mgrID)
        await askAgain(chatID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "a SECOND question from the same chat role must wake the parked manager — deliver-once is per QUESTION, not per task forever")
        sut.stopEngineForTask(mgrID)
    }

    func testAnsweringAQuestion_retiresTheBaselineKey_withNoWakeInvolved() async {
        // The resolver is the deterministic half: no `wakeAutovisorForEvents` call happens
        // anywhere in this test, so nothing can be sampling the cleared level.
        let mgrID = await parkedManager()
        let chatID = await makeAskingChatTask()
        sut.seedAutovisorNotifiedKeysForPassStart()
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(nsKey(chatID)), "premise")

        _ = await sut.answerSupervisorQuestion(stepID: "r", taskID: chatID, answer: "Use Postgres.")
        sut.stopEngineForTask(chatID)

        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(nsKey(chatID)),
                       "the site that RESOLVES a question must retire its key — positive evidence, not sampling")
        XCTAssertFalse(sut.autovisorLoopParkRedelivered.contains(nsKey(chatID)),
                       "a spent rollback entry for a finished question must not deny the next one its one free re-delivery")
        sut.stopEngineForTask(mgrID)
    }

    func testSecondQuestion_afterANonAnswerClear_wakesTheManagerAgain() async {
        // `manage_role restart` / `control_task stop` clear a question without an answer,
        // so the wake's own prune is what has to learn it.
        let mgrID = await parkedManager()
        let chatID = await makeAskingChatTask()
        sut.autovisorLastPassAttentionKeys = [nsKey(chatID)]

        await clearQuestionByRestart(chatID)
        await sut.wakeAutovisorForEvents()      // samples the cleared level (carries no items)

        await askAgain(chatID)
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "a question that re-arises after a non-answer clear is a NEW condition")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: - Where the prune has to sit

    func testWake_carryingNoItemsAtAll_stillRetiresTheClearedKey() async {
        // The wake that observes a condition CLEAR is usually the one with zero items —
        // pruning below `guard !items.isEmpty` would ship the bug unchanged.
        let mgrID = await parkedManager()
        let chatID = await makeAskingChatTask()
        sut.autovisorLastPassAttentionKeys = [nsKey(chatID)]
        await clearQuestionByRestart(chatID)
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before, "premise: nothing matched, so no pass started")
        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(nsKey(chatID)),
                       "the empty-items wake is exactly the one that must learn the question went quiet")
    }

    func testClearedKey_isRetiredEvenWhenTheMidReviewInjectionBranchReturns() async {
        // Manager `.running` → the wake returns from the injection branch. The prune must
        // already have run.
        let mgrID = await parkedManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskFailed = true }
        let chatID = await makeAskingChatTask()
        await clearQuestionByRestart(chatID)
        let failedID = await makeFailedStartupTask()   // supplies an item so we pass `items.isEmpty`
        sut.autovisorLastPassAttentionKeys = [nsKey(chatID)]
        sut.engineState[mgrID] = .running

        await sut.wakeAutovisorForEvents()

        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(nsKey(chatID)),
                       "the prune must precede the mid-review injection branch's return")
        XCTAssertFalse(formState.queuedMessages(for: mgrID).isEmpty,
                       "premise: this wake really did take the injection branch")
        _ = failedID
    }

    func testClearedKey_isRetiredEvenWhenAPendingHumanAnswerDefersTheWake() async {
        // A parked manager carrying an unprocessed human answer defers the supersede. The
        // prune must already have run there too.
        let mgrID = await parkedManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskFailed = true }
        await sut.mutateTask(taskID: mgrID) { task in
            task.runs[0].steps[0].supervisorAnswer = "keep going"
            task.runs[0].steps[0].supervisorAnswerWasAuto = false
        }
        let chatID = await makeAskingChatTask()
        await clearQuestionByRestart(chatID)
        _ = await makeFailedStartupTask()
        sut.autovisorLastPassAttentionKeys = [nsKey(chatID)]
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before,
                       "premise: the pending human answer deferred the supersede")
        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(nsKey(chatID)),
                       "the prune must precede the pending-human-continuation return")
    }

    // MARK: - The prune touches ONE trigger, deliberately

    private func makeFailedStartupTask() async -> Int {
        let taskID = await sut.createTask(title: "Broken", supervisorTask: "do X",
                                          preferredTeamID: startupTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .failed)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .failed])]
        }
        return taskID
    }

    func testPrune_servesOnlyLevelSampleTriggers_soAResolvedFailureStaysDelivered() async {
        // This prune serves exactly the triggers whose `keyRetirement` is `.levelSample` —
        // the ones whose level ORs in a representation no index write can observe, so only a
        // sample can learn their clear. `.needsSupervisor` is one: `summaryAwaitsSupervisor`
        // reads the engine mirror as well as the row.
        //
        // `.failed` is retired NOWHERE, and that is the assertion below: its remedy is a
        // restart, an ATTEMPT rather than a consumption, so a role that fails again would
        // wake a fresh pass per failure latency until auto-off — one `createNewRun` each.
        //
        // Note what this test does NOT say. Until 2026-08-30 its name and comment claimed the
        // exemption for every trigger but `.needsSupervisor`, argued entirely from `.failed`'s
        // case — and `.completed` sat inside that unexamined "every other" (CLAUDE.md #119).
        // `.completed`'s level is `summary.status` alone, so it is retired on the
        // `upsertTaskSummary` EDGE by `noteDerivedStatusTransition`, not here; a task that
        // left Review and came back with a revised artifact is a condition the manager has
        // never seen. `AutovisorReviewRetirementTests` owns that half.
        let mgrID = await parkedManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskFailed = true }
        let chatID = await makeAskingChatTask()          // a STANDING question keeps the wake quiet
        let failedID = await makeFailedStartupTask()
        let failedKey = NTMSOrchestrator.AutovisorAttentionKey(taskID: failedID, trigger: .failed)
        sut.autovisorLastPassAttentionKeys = [nsKey(chatID), failedKey]

        // The manager restarted the failing role: the `.failed` level goes quiet.
        await sut.mutateTask(taskID: failedID) { task in
            task.runs[0].steps[0].status = .running
            task.runs[0].roleStatuses["r"] = .working
        }
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before, "premise: the standing question is not fresh")
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(failedKey),
                      "a cleared `.failed` key must SURVIVE — pruning it is the restart-loop regression")
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(nsKey(chatID)),
                      "a STANDING question keeps its key — deliver-once still holds while it matches")
    }

    func testPrune_leavesStuckKeysAlone_onBothWakePaths() async {
        // `.stuck` is time-based and evaluated only on the poll path; its keys are managed by
        // the pass-start recompute, never by this prune.
        let mgrID = await parkedManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskStuck = true }
        let chatID = await makeAskingChatTask()
        let stuckKey = NTMSOrchestrator.AutovisorAttentionKey(taskID: 4242, trigger: .stuck)
        // The chat task's own key is baselined too, so neither wake starts a pass — a pass
        // would REASSIGN the baseline via the pass-start reseed and drop the stuck key for
        // a reason that has nothing to do with the prune under test.
        sut.autovisorLastPassAttentionKeys = [stuckKey, nsKey(chatID)]

        await sut.wakeAutovisorForEvents()                        // observer path (no stuck eval)
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(stuckKey),
                      "the observer path must not touch a `.stuck` key")

        await sut.wakeAutovisorForEvents(includeStuck: true)      // poll path
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(stuckKey),
                      "the poll path must not touch a `.stuck` key either — that is the pass-start recompute's job")
        XCTAssertEqual(runCount(mgrID), 1, "premise: neither wake started a pass, so no reseed ran")
    }

    // MARK: - Concurrent wakes still serialize

    func testConcurrentWake_sameStandingQuestion_stillBails() async {
        // The synchronous baseline record is the sole serialization between the observer and
        // the poll caller. The prune must not weaken it: it only ever drops keys the freshness
        // gate does not test.
        let mgrID = await parkedManager()
        _ = await makeAskingChatTask()

        await sut.wakeAutovisorForEvents()
        let afterFirst = runCount(mgrID)
        XCTAssertGreaterThan(afterFirst, 1, "premise: the first wake started a pass")

        // Model the second concurrent caller arriving with the manager's engine guard gone.
        sut.stopEngineForTask(mgrID)
        sut.engineState[mgrID] = nil

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), afterFirst,
                       "a concurrent wake for the SAME standing question must still bail — no second createNewRun")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: - The durable fact, not the engine mirror (CLAUDE.md #91)

    func testRecoveredPausedQuestion_wakesTheParkedManager() async {
        let mgrID = await parkedManager()
        let chatID = await makeRecoveredParkedTask()

        XCTAssertEqual(indexRow(chatID)?.status, .paused,
                       "premise: recovery demotes the derived status to .paused")
        XCTAssertEqual(indexRow(chatID)?.hasPendingSupervisorInput, true,
                       "premise: the durable wait-fact survives recovery")
        XCTAssertNotEqual(sut.taskEngineStates[chatID], .needsSupervisorInput,
                          "premise: the engine mirror cannot carry this wake")
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "a question that survived a relaunch must still wake the manager")
        sut.stopEngineForTask(mgrID)
    }

    func testRecoveredPausedQuestion_isAnswerable_evenWhenNotResident() async {
        // The wake must not be a wake into a dead end: a restart-recovered task is exactly
        // the one that is NOT in `loadedTasks`, and `answer_task_question` matches on the
        // stored flag of a task it has to load first. Residency comes from
        // `performAutovisorAction`'s prologue, not from the arm — pin the behaviour, so a
        // refactor that moves the load out of the prologue is caught here.
        _ = await parkedManager()
        let chatID = await makeRecoveredParkedTask()
        sut.evictLoadedTask(chatID)
        XCTAssertNil(sut.loadedTask(chatID), "premise: the task is not resident")

        let result = await sut.performAutovisorAction(
            .answerTaskQuestion(taskID: chatID, answer: "Use Postgres."))

        XCTAssertTrue(result.ok, "answer_task_question must load the task it was woken for: \(result.message)")
        sut.stopEngineForTask(chatID)
    }

    func testAskCallLandedButParkNotYet_doesNotWakeTheManager() async {
        // `hasActiveSupervisorInput` flips true when the ask CALL is appended, sub-second
        // before the park is written. `answer_task_question` matches the STORED flag, so a
        // wake here buys a pass that cannot answer anything.
        let mgrID = await parkedManager()
        let chatID = await sut.createTask(title: "Chat", supervisorTask: "help me",
                                          preferredTeamID: chatTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(chatID)
        await sut.mutateTask(taskID: chatID) { task in
            let step = StepExecution(
                id: "r", role: .softwareEngineer, title: "Assistant", status: .running,
                toolCalls: [StepToolCall(name: ToolNames.askSupervisor, argumentsJSON: "{}")])
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[chatID] = .running

        XCTAssertEqual(indexRow(chatID)?.hasPendingSupervisorInput, true,
                       "premise: the durable fact is already true from the ask CALL alone")
        XCTAssertEqual(indexRow(chatID)?.status, .running,
                       "premise: the step has not parked yet")
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before,
                       "a still-running step with an unparked ask call is not answerable — no wake")
    }

    func testClosedTaskWithParkedStep_neverWakes() async {
        // The widening must not revive the class where a settled task loops the manager
        // forever: closing is the Supervisor's explicit "done".
        let mgrID = await parkedManager()
        let chatID = await makeRecoveredParkedTask()
        await sut.mutateTask(taskID: chatID) { $0.closedAt = MonotonicClock.shared.now() }

        XCTAssertEqual(indexRow(chatID)?.hasPendingSupervisorInput, false,
                       "premise: a closed task is not waiting, whatever its last run holds")
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before, "a closed task must never wake the manager")
    }
}
