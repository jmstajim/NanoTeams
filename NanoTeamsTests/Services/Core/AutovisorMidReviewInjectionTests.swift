import XCTest

@testable import NanoTeams

/// Pins the mid-review event-delivery branch of `wakeAutovisorForEvents`: when the
/// manager is `.running`, a matching activation condition is injected into the LIVE
/// conversation as a queued supervisor message (drained next tool-loop iteration)
/// instead of waiting for the pass to end. Deduped per (task, trigger) via
/// `autovisorNotifiedAttentionKeys`; the fresh-pass wake path keeps its
/// edge-dedup-free level-triggered contract (pinned in `AutovisorOrchestratorTests`).
/// Injection tests force `.running` so no real run is spawned (no LM Studio); the
/// final self-retrigger test spawns (and immediately stops) one real pass.
@MainActor
final class AutovisorMidReviewInjectionTests: NTMSOrchestratorTestBase {

    private var formState: QuickCaptureFormState!

    override func setUp() {
        super.setUp()
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState   // orchestrator holds it weakly
    }

    override func tearDown() {
        formState = nil
        super.tearDown()
    }

    /// Opens the work folder, pins a manager task, turns the feature on (flag only —
    /// `setAutovisorEnabled` would start a real engine), and forces `.running` so
    /// the wake takes the injection branch.
    private func enabledRunningManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            $0.settings.autovisorEnabled = true
        }
        sut.engineState[mgrID] = .running
        return mgrID
    }

    /// Creates a NON-chat (Startup) task whose latest run has a failed step, so the
    /// derived summary status is `.failed` and the `onTaskFailed` trigger matches.
    private func makeFailedStartupTask() async -> Int? {
        guard let startupID = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id else {
            XCTFail("Startup team must be bootstrapped"); return nil
        }
        guard let taskID = await sut.createTask(title: "Build X", supervisorTask: "do X",
                                                preferredTeamID: startupID, makeActive: false) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .failed)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .failed])]
        }
        return taskID
    }

    // MARK: - Injection

    func testMidReview_failedTask_injectsOneNotice() async {
        let mgrID = await enabledRunningManager()
        guard let taskID = await makeFailedStartupTask() else { return }

        await sut.wakeAutovisorForEvents()

        let queued = formState.queuedMessages(for: mgrID)
        XCTAssertEqual(queued.count, 1, "the mid-pass event must inject exactly one notice")
        XCTAssertEqual(queued.first?.targetRoleID, sut.autovisorRole?.id,
                       "the notice targets the manager role so its tool loop drains it")
        XCTAssertEqual(queued.first?.isFromAutomatedSupervisor, true,
                       "automated notice — keeps the Auto-answered badge honest on the backstop path")
        XCTAssertTrue(queued.first?.text.contains("Task #\(taskID)") ?? false)
        XCTAssertTrue(queued.first?.text.contains("failed") ?? false)
        XCTAssertNil(sut.autovisorLastWakeAt,
                     "injection must NOT stamp the wake debounce — the post-pass fresh wake stays available")
    }

    func testMidReview_sameCondition_secondWake_deduped() async {
        let mgrID = await enabledRunningManager()
        guard await makeFailedStartupTask() != nil else { return }

        await sut.wakeAutovisorForEvents()
        await sut.wakeAutovisorForEvents()   // same still-failed task, e.g. next poll tick

        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1,
                       "a persisting condition notifies once per occurrence, not per tick")
    }

    func testMidReview_conditionClears_thenReFires_reNotifies() async {
        let mgrID = await enabledRunningManager()
        guard let taskID = await makeFailedStartupTask() else { return }

        await sut.wakeAutovisorForEvents()
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1)

        // Condition clears (step recovered to .done, task closed → derived .done) —
        // the prune drops its key. A closed task with a still-failed step would
        // keep deriving .failed (`derivedStatusFromActiveRun` checks hasFailed first).
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].status = .done
            task.closedAt = MonotonicClock.shared.now()
        }
        await sut.wakeAutovisorForEvents()
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1, "no notice while nothing matches")

        // Re-fires (reopened, step failed again) → a NEW occurrence must re-notify.
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].status = .failed
            task.closedAt = nil
        }
        await sut.wakeAutovisorForEvents()
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 2,
                       "a condition that cleared and re-fired is a new event")
    }

    func testMidReview_createdTrigger_notifiesOnceAndMarksSeen() async {
        let mgrID = await enabledRunningManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskCreated = true }
        let newID = await sut.createTask(title: "Fresh", supervisorTask: "x", makeActive: false)!

        await sut.wakeAutovisorForEvents()

        let queued = formState.queuedMessages(for: mgrID)
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(queued.first?.text.contains("New task") ?? false)
        XCTAssertTrue(sut.autovisorSeenTaskIDs.contains(newID),
                      "`created` has no clearing state transition — delivery marks it seen")

        await sut.wakeAutovisorForEvents()
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1,
                       "a seen task must not re-notify as created")
    }

    func testMidReview_mixedConditions_secondNoticeListsOnlyNew() async {
        let mgrID = await enabledRunningManager()
        guard let firstID = await makeFailedStartupTask() else { return }
        await sut.wakeAutovisorForEvents()
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1)

        // A SECOND condition arises while the first persists — the incremental
        // notice must contain only the new one, not re-list the notified one.
        guard let secondID = await makeFailedStartupTask() else { return }
        await sut.wakeAutovisorForEvents()

        let queued = formState.queuedMessages(for: mgrID)
        XCTAssertEqual(queued.count, 2)
        XCTAssertTrue(queued.last?.text.contains("Task #\(secondID)") ?? false)
        XCTAssertFalse(queued.last?.text.contains("Task #\(firstID)") ?? true,
                       "an already-notified condition must not be re-listed in the incremental notice")
    }

    func testMidReview_recentWakeStamp_doesNotSuppressInjection() async {
        let mgrID = await enabledRunningManager()
        guard await makeFailedStartupTask() != nil else { return }
        // The realistic timing: the pass start stamped the debounce clock seconds
        // ago. Injection is deliberately debounce-exempt.
        sut.autovisorLastWakeAt = Date()

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1,
                       "the wake debounce gates fresh passes only, never mid-review injection")
    }

    /// Delivery-gated bookkeeping: with no wired form state (headless), the wake
    /// must NOT mark conditions notified/seen — for `created`, seen IS the
    /// level-clear, so marking without delivery would lose the event permanently.
    func testMidReview_unwiredFormState_doesNotMarkDeliveredOrSeen() async {
        _ = await enabledRunningManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskCreated = true }
        let newID = await sut.createTask(title: "Fresh", supervisorTask: "x", makeActive: false)!
        sut.quickCaptureFormState = nil

        await sut.wakeAutovisorForEvents()

        XCTAssertFalse(sut.autovisorSeenTaskIDs.contains(newID),
                       "no delivery → the created level must stay live for the post-pass fresh wake")
        XCTAssertTrue(sut.autovisorNotifiedAttentionKeys.isEmpty,
                      "no delivery → nothing may be marked notified")
    }

    // MARK: - Corner cases

    /// The feature flag is re-checked on every wake — turning the Autovisor off
    /// while a pass is still `.running` must stop injections immediately.
    func testMidReview_featureDisabledMidPass_noInjection() async {
        let mgrID = await enabledRunningManager()
        guard await makeFailedStartupTask() != nil else { return }
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = false }

        await sut.wakeAutovisorForEvents()

        XCTAssertTrue(formState.queuedMessages(for: mgrID).isEmpty,
                      "a disabled Autovisor must not receive event notices")
    }

    /// The manager is excluded from `watchable` — its OWN task failing must never
    /// self-notify (the self-supervision analogue of `performAutovisorAction`'s
    /// self-guard).
    func testMidReview_managerOwnFailure_neverSelfNotifies() async {
        let mgrID = await enabledRunningManager()
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Manager", status: .failed)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .failed])]
        }

        await sut.wakeAutovisorForEvents()

        XCTAssertTrue(formState.queuedMessages(for: mgrID).isEmpty)
        XCTAssertTrue(sut.autovisorNotifiedAttentionKeys.isEmpty,
                      "the manager's own state must not even enter the dedup bookkeeping")
    }

    /// One task matching TWO triggers simultaneously (failed + created) yields ONE
    /// queued message carrying both bullets — never two messages, and both
    /// per-condition keys are recorded.
    func testMidReview_sameTaskTwoTriggers_singleMessageWithBothBullets() async {
        let mgrID = await enabledRunningManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskCreated = true }
        guard let taskID = await makeFailedStartupTask() else { return }  // failed AND unseen

        await sut.wakeAutovisorForEvents()

        let queued = formState.queuedMessages(for: mgrID)
        XCTAssertEqual(queued.count, 1, "simultaneous conditions combine into one notice")
        XCTAssertTrue(queued.first?.text.contains("failed") ?? false)
        XCTAssertTrue(queued.first?.text.contains("New task") ?? false)
        XCTAssertEqual(sut.autovisorNotifiedAttentionKeys,
                       [.init(taskID: taskID, trigger: .failed), .init(taskID: taskID, trigger: .created)])
    }

    /// `onTaskNeedsSupervisor` reads the LIVE engine state (not the derived
    /// summary) — pin the injection path end-to-end for that trigger, including
    /// the actionable tool hint the manager is supposed to follow.
    func testMidReview_needsSupervisorEngineState_injectsAnswerHint() async {
        let mgrID = await enabledRunningManager()
        let qID = await sut.createTask(title: "Q", supervisorTask: "x", makeActive: false)!
        sut.engineState[qID] = .needsSupervisorInput

        await sut.wakeAutovisorForEvents()

        let queued = formState.queuedMessages(for: mgrID)
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(queued.first?.text.contains("Task #\(qID)") ?? false)
        XCTAssertTrue(queued.first?.text.contains("answer_task_question") ?? false)
    }

    /// The seed REPLACES the set wholesale — stale keys from a previous pass (or a
    /// condition that cleared while no wake ran) must not survive into the new pass.
    func testSeedAtPassStart_replacesStaleKeysEntirely() async {
        _ = await enabledRunningManager()
        guard let taskID = await makeFailedStartupTask() else { return }
        sut.autovisorNotifiedAttentionKeys = [.init(taskID: 9999, trigger: .failed)]

        sut.seedAutovisorNotifiedKeysForPassStart()

        XCTAssertEqual(sut.autovisorNotifiedAttentionKeys,
                       [.init(taskID: taskID, trigger: .failed)],
                       "the seed is a full snapshot of currently-matching conditions, not a merge")
    }

    /// A `created` event delivered mid-pass is fully consumed: once the pass ends,
    /// the level is quiet (seen) and the post-pass wake must NOT spawn a redundant
    /// fresh review for the already-delivered event.
    func testCreatedDeliveredMidPass_passEnds_noRedundantFreshWake() async {
        let mgrID = await enabledRunningManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskCreated = true }
        _ = await sut.createTask(title: "Fresh", supervisorTask: "x", makeActive: false)!

        await sut.wakeAutovisorForEvents()
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1, "premise: delivered mid-pass")

        sut.engineState[mgrID] = nil   // pass ended
        await sut.wakeAutovisorForEvents()

        XCTAssertNil(sut.autovisorLastWakeAt,
                     "no fresh pass may fire for an event already delivered into the previous pass")
        XCTAssertNotEqual(sut.taskEngineStates[mgrID], .running, "no manager run should have started")
    }

    // MARK: - Stuck trigger (poll-path injection + prune asymmetry)

    /// Drives a top-level task to `.running` with a silent running step so only
    /// `onTaskStuck` can match (token silence past `stuckHangSeconds` = hang).
    private func makeHungRunningTask() async -> Int? {
        guard let startupID = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id else {
            XCTFail("Startup team must be bootstrapped"); return nil
        }
        guard let taskID = await sut.createTask(title: "Spin", supervisorTask: "x",
                                                preferredTeamID: startupID, makeActive: false) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .running)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[taskID] = .running  // computeStuckTaskIDs only inspects .running engines
        return taskID
    }

    /// Mid-review delivery is the ONLY route for a stuck condition during a pass
    /// (the pass-start seed deliberately uses `stuck: []`), and its dedup key must
    /// survive interleaved observer wakes that don't evaluate stuck
    /// (`includeStuck: false`) — pruning it there would re-inject the same
    /// still-hung condition on every poll tick.
    func testMidReview_stuckNotice_survivesObserverWakesBetweenPollTicks() async {
        let mgrID = await enabledRunningManager()
        guard await makeHungRunningTask() != nil else { return }
        let future = Date().addingTimeInterval(AutovisorConstants.stuckHangSeconds + 120)

        await sut.wakeAutovisorForEvents(now: future, includeStuck: true)   // poll tick
        let queued = formState.queuedMessages(for: mgrID)
        XCTAssertEqual(queued.count, 1, "the poll tick must inject the stuck notice mid-review")
        XCTAssertTrue(queued.first?.text.contains("stuck") ?? false)

        await sut.wakeAutovisorForEvents(now: future)                       // hot observer (no stuck eval)
        await sut.wakeAutovisorForEvents(now: future, includeStuck: true)   // next poll tick

        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1,
                       "an observer wake must not erode the stuck dedup key — same hang, one notice")
    }

    /// The PRUNING half of the stuck exemption: on an EVALUATED tick where the
    /// hang has cleared, the `.stuck` key must drop so a later, distinct hang on
    /// the same task re-notifies. Dropping the `&& !stuckEvaluated` clause (a
    /// tempting "simplification") would pass every other test but fail this one.
    func testMidReview_stuckHangClears_thenRecurs_reNotifies() async {
        let mgrID = await enabledRunningManager()
        guard await makeHungRunningTask() != nil else { return }
        let hung = Date().addingTimeInterval(AutovisorConstants.stuckHangSeconds + 120)

        await sut.wakeAutovisorForEvents(now: hung, includeStuck: true)
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1, "premise: first hang notified")

        // Evaluated tick while the role is healthy (idle time at `Date()` is below
        // the hang threshold) → the key prunes; no new notice.
        await sut.wakeAutovisorForEvents(now: Date(), includeStuck: true)
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1)

        await sut.wakeAutovisorForEvents(now: hung.addingTimeInterval(600), includeStuck: true)
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 2,
                       "a hang that cleared on an evaluated tick and recurred is a new event")
    }

    /// The injection branch's recovery contract: a condition the manager fails to
    /// address mid-pass (its dedup key is recorded AND still matching) must still
    /// get the normal fresh-pass wake once the pass ends — the dedup set never
    /// gates fresh passes. A regression leaking `autovisorNotifiedAttentionKeys`
    /// into the fresh-pass path would silence the condition permanently.
    func testFailedDeliveredMidPass_unaddressed_freshWakeFiresAfterPassEnds() async {
        let mgrID = await enabledRunningManager()
        guard await makeFailedStartupTask() != nil else { return }

        await sut.wakeAutovisorForEvents()
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1, "premise: delivered mid-pass")
        XCTAssertNil(sut.autovisorLastWakeAt)

        sut.engineState[mgrID] = nil   // pass ended; the failure was never addressed
        await sut.wakeAutovisorForEvents()

        XCTAssertNotNil(sut.autovisorLastWakeAt,
                        "an unaddressed still-matching level must re-wake via a fresh pass")
        sut.stopEngineForTask(mgrID)   // tidy the spawned manager run
    }

    // MARK: - Pass-start seeding (self-retrigger guard)

    func testSeedAtPassStart_conditionPresentAtStart_doesNotInject() async {
        let mgrID = await enabledRunningManager()
        guard await makeFailedStartupTask() != nil else { return }

        // The startRun manager hook runs this at every pass start: conditions
        // matching RIGHT NOW are observed by the pass itself via list_tasks.
        sut.seedAutovisorNotifiedKeysForPassStart()
        XCTAssertFalse(sut.autovisorNotifiedAttentionKeys.isEmpty, "premise: the failed task was seeded")

        await sut.wakeAutovisorForEvents()
        XCTAssertTrue(formState.queuedMessages(for: mgrID).isEmpty,
                      "a condition present at pass start must not duplicate into the live chat")
    }

    /// End-to-end self-retrigger scenario: an event wake starts a fresh pass
    /// (`startRun` seeds the dedup set); the manager's own `.running` transition
    /// re-fires the observer → the second wake must NOT inject a duplicate notice
    /// for the very condition the pass was started for.
    func testEventWakePass_doesNotImmediatelySelfInject() async {
        let mgrID = await enabledRunningManager()
        sut.engineState[mgrID] = nil   // manager idle → first wake takes the fresh-pass path
        guard await makeFailedStartupTask() != nil else { return }

        await sut.wakeAutovisorForEvents()           // fresh pass: startRun → seed
        XCTAssertNotNil(sut.autovisorLastWakeAt, "premise: the fresh-pass wake fired")

        // Stop the live engine BEFORE forcing `.running`: a fast-failing real run
        // could overwrite the forced state across the await below, silently
        // rerouting the second wake onto the (debounced) fresh-pass path and
        // letting the test pass even with the seed deleted. The seed already
        // happened in startRun, so the scenario stays faithful.
        sut.stopEngineForTask(mgrID)
        sut.engineState[mgrID] = .running            // the observer re-fires on this transition
        await sut.wakeAutovisorForEvents()

        XCTAssertTrue(formState.queuedMessages(for: mgrID).isEmpty,
                      "the pass-start seed must absorb the condition that triggered the pass")
        sut.stopEngineForTask(mgrID)                 // tidy
    }
}
