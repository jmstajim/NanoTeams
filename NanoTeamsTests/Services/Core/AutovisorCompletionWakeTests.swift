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
}
