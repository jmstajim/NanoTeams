import XCTest

@testable import NanoTeams

/// Reproduces the reported bug: the manager parked via `wait_for_events`, and a
/// managed Startup task then either produced its deliverable (→ Review) OR called
/// `ask_supervisor` (→ engine `.needsSupervisorInput`) — and the manager did NOT
/// wake. Both are watchable-task transitions that should supersede a parked
/// manager; this exercises the FULL orchestration path (derived status / engine
/// state → watchable → attention item → supersede) which the existing tests only
/// covered for `.failed`. There is no event-wake throttle: a fresh (not-yet-seen)
/// condition wakes the parked manager immediately; an already-reviewed one is not
/// re-delivered (deliver-once); `.stuck` is excluded from the immediate path.
@MainActor
final class AutovisorCompletionWakeTests: NTMSOrchestratorTestBase {

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

    @discardableResult
    private func parkedManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            $0.settings.autovisorEnabled = true
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

    private func startupTeamID() -> NTMSID {
        sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id ?? "missing"
    }

    /// Startup task whose role produced its deliverable and now awaits acceptance.
    private func makeCompletedStartupTask() async -> Int {
        let taskID = await sut.createTask(title: "Build X", supervisorTask: "do X",
                                          preferredTeamID: startupTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .needsAcceptance])]
        }
        return taskID
    }

    /// Startup task whose role called `ask_supervisor` and parked for input.
    private func makeAskingStartupTask() async -> Int {
        let taskID = await sut.createTask(title: "Build Y", supervisorTask: "do Y",
                                          preferredTeamID: startupTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer",
                                     status: .needsSupervisorInput, needsSupervisorInput: true,
                                     supervisorQuestion: "Which database should I use?")
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[taskID] = .needsSupervisorInput
        return taskID
    }

    /// `repetitionMinIdenticalToolCalls` identical, RECENT tool calls — the loop recipe
    /// `AutovisorStuckEvaluatorTests.testLoop_identicalToolCalls` uses.
    private func loopCalls(now: Date) -> [StepToolCall] {
        let recent = now.addingTimeInterval(-5)
        return (0..<DelegationConstants.repetitionMinIdenticalToolCalls).map {
            StepToolCall(createdAt: recent.addingTimeInterval(Double($0)),
                         name: "task_status", argumentsJSON: #"{"task_id":1}"#, resultJSON: "{}")
        }
    }

    /// A `.running` Startup task whose role is caught in a tool-call loop — the
    /// per-minute poll's `computeStuckTaskIDs` flags it, producing an `onTaskStuck` item.
    private func makeStuckStartupTask(now: Date) async -> Int {
        let taskID = await sut.createTask(title: "Stuck", supervisorTask: "do Z",
                                          preferredTeamID: startupTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer",
                                     status: .running, createdAt: now.addingTimeInterval(-30),
                                     updatedAt: now.addingTimeInterval(-30),
                                     toolCalls: self.loopCalls(now: now))
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[taskID] = .running
        return taskID
    }

    private func runCount(_ taskID: Int) -> Int { sut.loadedTask(taskID)?.runs.count ?? -1 }

    // MARK: - stuck conditions are deliver-once, not re-pass-every-poll (review finding)

    func testStuckCondition_alreadyReviewed_doesNotReWake() async {
        // Deliver-once for stuck (review finding #2): a stuck task is delivered once, then
        // recorded in the freshness baseline (the pass-start seed RECOMPUTES stuck), so it
        // must NOT re-pass the manager every poll tick. (A genuinely fresh stuck condition
        // DOES wake — pinned by `AutovisorOrchestratorTests.testWake_stuckRunningTask_viaPoll_*`.)
        let now = Date()
        let mgrID = await parkedManager()
        let stuckID = await makeStuckStartupTask(now: now)
        sut.autovisorLastPassAttentionKeys = [
            NTMSOrchestrator.AutovisorAttentionKey(taskID: stuckID, trigger: .stuck)
        ]
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents(now: now, includeStuck: true)

        XCTAssertEqual(runCount(mgrID), before,
                       "an already-reviewed stuck condition must not re-pass the manager (deliver-once)")
    }

    // MARK: - status derivation sanity

    func testCompletedTask_derivesToReview() async {
        _ = await parkedManager()
        let startupID = await makeCompletedStartupTask()
        let status = sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == startupID })?.status
        XCTAssertEqual(status, .needsSupervisorAcceptance,
                       "a producing role done + awaiting acceptance must derive to Review in the index")
    }

    // MARK: - the two reported repros

    func testCompletedTask_wakesParkedManager() async {
        let mgrID = await parkedManager()
        await makeCompletedStartupTask()
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "a completed (Review) managed task must wake the parked manager")
        sut.stopEngineForTask(mgrID)
    }

    func testAskSupervisorTask_wakesParkedManager() async {
        let mgrID = await parkedManager()
        await makeAskingStartupTask()
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "a managed task at needsSupervisorInput must wake the parked manager")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: - deliver-once (no throttle)

    func testAlreadyReviewedCondition_isNotReDelivered() async {
        // Deliver-once: a condition present at the manager's last pass start (in the
        // freshness baseline) that it didn't resolve must NOT immediately re-wake it —
        // the periodic recurrence review re-surfaces it instead (no tight re-pass loop).
        let mgrID = await parkedManager()
        let startupID = await makeCompletedStartupTask()
        sut.autovisorLastPassAttentionKeys = [
            NTMSOrchestrator.AutovisorAttentionKey(taskID: startupID, trigger: .completed)
        ]
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before,
                       "an already-reviewed, unresolved condition is not re-delivered (deliver-once)")
    }

    func testFreshWake_recordsPassSnapshot_forConcurrentWakeSerialization() async {
        // Race guard: a fresh-condition wake records the conditions it is reviewing into
        // `autovisorLastPassAttentionKeys` SYNCHRONOUSLY (before the await), so a
        // concurrent observer/poll wake for the SAME conditions sees them as not-fresh
        // and is debounced — neither double-starts a pass (`createNewRun`).
        let mgrID = await parkedManager()
        let startupID = await makeCompletedStartupTask()

        await sut.wakeAutovisorForEvents()

        XCTAssertTrue(
            sut.autovisorLastPassAttentionKeys.contains(
                NTMSOrchestrator.AutovisorAttentionKey(taskID: startupID, trigger: .completed)),
            "the fresh-pass wake must record the reviewed condition as the new freshness baseline")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: - pass-start seed recomputes stuck into the freshness baseline

    func testSeedPassStart_recordsStuckInBaseline_notInjectionSet() async {
        // The seed RECOMPUTES stuck into the deliver-once freshness baseline (so a stuck
        // task is delivered once, not every poll) while the injection-dedup set keeps its
        // `stuck: []` contract (a stuck condition injects once mid-pass).
        let now = Date()
        _ = await parkedManager()
        let stuckID = await makeStuckStartupTask(now: now)

        sut.seedAutovisorNotifiedKeysForPassStart()

        let stuckKey = NTMSOrchestrator.AutovisorAttentionKey(taskID: stuckID, trigger: .stuck)
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(stuckKey),
                      "freshness baseline must include the stuck condition (deliver-once for stuck)")
        XCTAssertFalse(sut.autovisorNotifiedAttentionKeys.contains(stuckKey),
                       "the injection set keeps its stuck:[] contract")
    }

    func testSeedPassStart_onTaskStuckOff_omitsStuck() async {
        let now = Date()
        _ = await parkedManager()
        let stuckID = await makeStuckStartupTask(now: now)
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskStuck = false }

        sut.seedAutovisorNotifiedKeysForPassStart()

        let stuckKey = NTMSOrchestrator.AutovisorAttentionKey(taskID: stuckID, trigger: .stuck)
        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(stuckKey),
                       "onTaskStuck off → the seed must not evaluate or record stuck")
    }

    func testSeedPassStart_recompute_dropsStaleStuckKey_whenNoLongerStuck() async {
        // The seed ASSIGNS (not unions) the baseline, so a task that WAS stuck but isn't
        // anymore is dropped — letting a fresh stuck episode re-wake the manager.
        _ = await parkedManager()
        let taskID = await sut.createTask(title: "Healthy", supervisorTask: "x",
                                          preferredTeamID: startupTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            // A clean, recent running step — no tool-call loop, fresh activity → not stuck.
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer",
                                     status: .running, createdAt: Date(), updatedAt: Date())
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[taskID] = .running
        let stuckKey = NTMSOrchestrator.AutovisorAttentionKey(taskID: taskID, trigger: .stuck)
        sut.autovisorLastPassAttentionKeys = [stuckKey]   // stale (the task is no longer stuck)

        sut.seedAutovisorNotifiedKeysForPassStart()

        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(stuckKey),
                       "a no-longer-stuck task's stale key must be dropped by the recompute")
    }

    // MARK: - engine-less `.failed` wakes the manager (create_team generation failure)

    /// A top-level task with a single step of `status` on `teamID` (default the
    /// Startup team) and NO `taskEngineStates` entry — the exact shape a `create_team`
    /// generation outcome leaves behind: `runTeamGeneration` mutates the step but
    /// creates an engine only on success, so nothing ever writes `taskEngineStates[id]`.
    /// This is the case the immediate event-wake used to miss (it observed only
    /// engine-state changes) and that the `allTaskStatuses` observer now covers by
    /// driving the same wake.
    private func makeEnginelessTask(status: StepStatus, teamID: NTMSID? = nil) async -> Int {
        let taskID = await sut.createTask(title: "Gen", supervisorTask: "build",
                                          preferredTeamID: teamID ?? startupTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "team_generation_X", role: .supervisor,
                                     title: "Generate Team", status: status)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: [:])]
        }
        // Deliberately DO NOT set `sut.engineState[taskID]`: a generation failure
        // starts an engine only on success, so `taskEngineStates` has no entry.
        return taskID
    }

    /// The reported bug's shape: an engine-less `.failed` task.
    private func makeEnginelessFailedTask() async -> Int {
        await makeEnginelessTask(status: .failed)
    }

    func testFailedTask_noEngineEntry_wakesParkedManager() async {
        let mgrID = await parkedManager()
        let failedID = await makeEnginelessFailedTask()

        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == failedID })?.status,
                       .failed, "an engine-less failed step must derive to .failed in the index")
        XCTAssertNil(sut.taskEngineStates[failedID],
                     "precondition: no engine-state entry (a generation failure creates none)")
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "a failed task with no engine entry must wake the parked manager — the create_team-failure case")
        sut.stopEngineForTask(mgrID)
    }

    func testFailedTask_autovisorDisabled_noWake() async {
        let mgrID = await parkedManager()
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = false }
        _ = await makeEnginelessFailedTask()
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before,
                       "with the Autovisor disabled the wake must self-guard to a no-op")
    }

    func testFailedTask_alreadyInBaseline_notReWaked() async {
        let mgrID = await parkedManager()
        let failedID = await makeEnginelessFailedTask()
        sut.autovisorLastPassAttentionKeys = [
            NTMSOrchestrator.AutovisorAttentionKey(taskID: failedID, trigger: .failed)
        ]
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before,
                       "an already-reviewed failed condition is not re-delivered (deliver-once)")
    }

    /// The no-double-wake guarantee the fix relies on: a `create_team` failure now
    /// fires BOTH the `allTaskStatuses` observer AND (for a normal failure) the
    /// engine-state observer, and the ≤60s poll can fire too. The fresh-pass wake
    /// records the `.failed` condition into `autovisorLastPassAttentionKeys`
    /// SYNCHRONOUSLY (before the await), so a concurrent second wake for the same
    /// failure sees it as not-fresh and bails — no second `createNewRun`. Mirrors
    /// `testFreshWake_recordsPassSnapshot_forConcurrentWakeSerialization` for `.failed`.
    func testFailedTask_freshWake_recordsBaselineForSerialization() async {
        let mgrID = await parkedManager()
        let failedID = await makeEnginelessFailedTask()

        await sut.wakeAutovisorForEvents()

        XCTAssertTrue(
            sut.autovisorLastPassAttentionKeys.contains(
                NTMSOrchestrator.AutovisorAttentionKey(taskID: failedID, trigger: .failed)),
            "the fresh-pass wake must record the failed condition as the deliver-once baseline")
        sut.stopEngineForTask(mgrID)
    }

    /// The real `create_team` failure sits on a CHAT-mode placeholder team. The
    /// chat-mode status override touches only a `.done` base, so a `.failed` step
    /// still derives `.failed` and wakes the manager — a chat-mode override must
    /// never swallow a failure.
    func testFailedTask_chatModeTask_derivesFailedAndWakes() async {
        let mgrID = await parkedManager()
        guard let chatID = sut.snapshot?.workFolder.teams
            .first(where: { $0.isChatMode && !$0.isHiddenFromPickers })?.id else {
            XCTFail("a bundled chat-mode team must exist"); return
        }
        let failedID = await makeEnginelessTask(status: .failed, teamID: chatID)

        XCTAssertEqual(sut.loadedTask(failedID)?.isChatMode, true, "precondition: chat-mode task")
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == failedID })?.status,
                       .failed, "a chat-mode failure still derives .failed (override is .done-only)")
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "a chat-mode failed task must still wake the manager")
        sut.stopEngineForTask(mgrID)
    }

    /// The manager may have NO engine entry at all (idle after app restart, or a
    /// pass that fully ended). A fresh `.failed` condition must still wake it — the
    /// `startAutovisorPass` idle path (no parked engine to stop) reaches `startRun`.
    func testFailedTask_idleManagerNoEngineEntry_wakesFreshPass() async {
        let mgrID = await parkedManager()
        sut.engineState[mgrID] = nil   // fully idle — not parked, not running
        _ = await makeEnginelessFailedTask()
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "an idle (no-engine-entry) manager must wake on a fresh failure")
        sut.stopEngineForTask(mgrID)
    }

    /// Safety of the broadened trigger: the new `allTaskStatuses` observer fires on
    /// ANY derived-status change, but the wake only ACTS on real conditions. The
    /// intermediate generating state (a `.running` engine-less step, before the run
    /// succeeds or fails) matches no trigger, so it must NOT wake the manager — only
    /// the terminal `.failed` does. Guards against the observer over-waking.
    func testRunningEnginelessTask_doesNotWake() async {
        let mgrID = await parkedManager()
        let runningID = await makeEnginelessTask(status: .running)
        sut.autovisorSeenTaskIDs.insert(runningID)   // defensive: onTaskCreated can't fire

        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == runningID })?.status,
                       .running, "precondition: a still-generating task derives .running, not .failed")
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before,
                       "a still-generating (.running) task matches no trigger — the status-change observer must not spuriously wake the manager")
    }
}
