import XCTest

@testable import NanoTeams

/// Pins the FORCE contract of `startAutovisorPass(taskID:force:)` — what both
/// "Run now" buttons (TeamBoard TopBar + Settings pill) invoke.
///
/// Before force, Run-now was a silent no-op whenever the manager was `.running`
/// or `.needsAcceptance`: the non-force branch only tears down for
/// `.needsSupervisorInput`, and `startRun` bails on all three. Force supersedes
/// ANY state.
///
/// The suite exists separately from `AutovisorSendMessageTests` (which owns the
/// queued-message contract) and `AutovisorCompletionWakeTests` (which owns wake
/// decisions) because "force supersede" is its own subject.
///
/// Every test method is `async` — a sync `@MainActor` test that constructs a
/// `@MainActor` class `abort()`s on CI (CLAUDE.md §Testing).
@MainActor
final class AutovisorRunNowForceTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var formState: QuickCaptureFormState!

    /// Probe for the drain-ordering pin: the number of runs on the manager task at
    /// the moment the cancelled step's handler ran. A class-level field, not a
    /// local — a `@MainActor` test may not construct/capture locals across the
    /// spawned Task boundary.
    private var runCountAtCancel: Int?

    override func setUp() async throws {
        try await super.setUp()
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState   // orchestrator holds it weakly
    }

    override func tearDown() async throws {
        formState = nil
        runCountAtCancel = nil
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// Opens the folder, pins + enables a manager, and gives its latest run ONE
    /// `.running` step so `pauseRun` has something real to drain. Engine state is
    /// forced to `.running` without a real engine — `pauseRun`'s
    /// `taskEngines[taskID]?.pause()` is an optional chain, so the step-cancellation
    /// loop still runs, which is exactly what the ordering pins need.
    @discardableResult
    private func runningManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            $0.settings.autovisorEnabled = true
        }
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr", status: .running)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[mgrID] = .running
        return mgrID
    }

    private func runCount(_ taskID: Int) -> Int { sut.loadedTask(taskID)?.runs.count ?? -1 }

    /// Status of the step in the FIRST (now-superseded) run.
    private func firstRunStepStatus(_ taskID: Int) -> StepStatus? {
        sut.loadedTask(taskID)?.runs.first?.steps.first?.status
    }

    // MARK: - Force supersedes a live pass

    /// The headline fix: a mid-pass manager (`.running` — the state in which the
    /// TopBar renders `[ pause ]` next to `[ ▷ Run now ]`) must restart.
    /// The old run's step ending `.paused` is what proves the DRAIN ran
    /// (`pauseRun`), not a bare `stopEngineForTask`.
    func testForce_runningManager_tearsDownEngineAndAppendsFreshRun() async {
        let mgrID = await runningManager()
        let before = runCount(mgrID)

        await sut.startAutovisorPass(taskID: mgrID, force: true)

        XCTAssertEqual(runCount(mgrID), before + 1,
                       "force must append a fresh run even while the manager is mid-pass")
        XCTAssertEqual(firstRunStepStatus(mgrID), .paused,
                       "the superseded run's step must be drained to .paused — a bare "
                     + "stopEngineForTask would leave a forever-.running lie")
        sut.stopEngineForTask(mgrID)
    }

    /// THE regression guard. `wakeAutovisorForEvents` calls the same method with the
    /// default `force: false` and depends on a `.running` manager being left alone
    /// (it injects the event into the live conversation instead). If the defaulted
    /// parameter ever leaks force into that path, a pass would be discarded mid-flight
    /// while it is handling the very condition that woke it.
    func testNonForce_runningManager_isNoOp() async {
        let mgrID = await runningManager()
        let before = runCount(mgrID)

        await sut.startAutovisorPass(taskID: mgrID)

        XCTAssertEqual(runCount(mgrID), before, "non-force must not supersede a live pass")
        XCTAssertEqual(firstRunStepStatus(mgrID), .running, "and must not drain its step")
        XCTAssertEqual(sut.taskEngineStates[mgrID], .running, "and must not tear the engine down")
    }

    /// THE hazard pin — why the force path uses `pauseRun` and not just
    /// `stopEngineForTask`.
    ///
    /// `stopEngineForTask`'s bulk `cancelExecutions(forTaskID:)` is fire-and-forget:
    /// it cancels the Task and nils `executionStates[key]` synchronously WITHOUT
    /// awaiting the handler. The cancelled step's `catch is CancellationError` arm
    /// calls `persistWireTranscript`, gated only on `executionStates[key] != nil`
    /// (an EXISTENCE check, no identity check) and writing to `runs.indices.last`.
    /// `startStepExecution` re-populates that exact key, and the manager team is
    /// single-role — so old and new step share ONE `TaskStepKey`. A handler delayed
    /// past the new run's start would therefore write the DEAD pass's transcript
    /// onto the FRESH run.
    ///
    /// `pauseRun` routes through `cancelStepExecution`, which AWAITS the handler
    /// under `LLMConstants.cancelHandlerTimeoutSeconds`. This test fails (probe sees
    /// 2, or nil) if that await is dropped.
    func testForce_liveStepExecution_isDrainedBeforeTheNewRunIsCreated() async {
        let mgrID = await runningManager()
        // Stands in for a live LLM call. `try?` swallows the CancellationError the
        // same way the real `catch is CancellationError` arm does, then records what
        // `runs.last` was at the moment the handler ran.
        sut.llmExecutionService._testInjectRunningTask(
            stepID: "r", taskID: mgrID,
            runningTask: Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.runCountAtCancel = self?.sut?.loadedTask(mgrID)?.runs.count
            }
        )

        await sut.startAutovisorPass(taskID: mgrID, force: true)

        XCTAssertEqual(runCountAtCancel, 1,
                       "the cancelled step's persist arm must run while the OLD run is still "
                     + "runs.last — otherwise its wireTranscript clobbers the fresh run "
                     + "(same TaskStepKey, single-role manager team)")
        XCTAssertEqual(runCount(mgrID), 2, "and the fresh run must still land")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: - Force across every engine state

    /// `.needsAcceptance` and `.running` were silent no-ops pre-fix; the rest already
    /// worked but are pinned so a future guard added to `startRun` can't quietly
    /// re-introduce a dead state for Run-now.
    func testForce_everyEngineState_appendsFreshRun() async {
        let mgrID = await runningManager()
        let states: [TeamEngineState?] = [
            nil, .pending, .paused, .done, .failed,
            .needsAcceptance, .needsSupervisorInput, .running,
        ]

        for state in states {
            sut.engineState[mgrID] = state
            let before = runCount(mgrID)

            await sut.startAutovisorPass(taskID: mgrID, force: true)

            XCTAssertEqual(runCount(mgrID), before + 1,
                           "force must append a run from \(String(describing: state))")
            sut.stopEngineForTask(mgrID)
        }
    }

    // MARK: - What force must NOT destroy

    /// Standing human steering survives the supersede and drains on iteration 1 of
    /// the fresh run — the same contract `fireRecurrence` maintains by deliberately
    /// NOT clearing the manager's queue.
    func testForce_preservesQueuedHumanMessages() async {
        let mgrID = await runningManager()
        XCTAssertTrue(sut.sendMessageToAutovisor("standing guidance", attachments: []),
                      "precondition: the message must queue")
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1, "precondition")
        let before = runCount(mgrID)

        await sut.startAutovisorPass(taskID: mgrID, force: true)

        XCTAssertEqual(runCount(mgrID), before + 1, "the force must still produce a fresh run")
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1,
                       "queued human messages survive the supersede (drained on iteration 1)")
        sut.stopEngineForTask(mgrID)
    }

    /// The in-flight bail must come BEFORE any teardown. A `startRun` already
    /// suspended between its guards and `engine.start()` WILL append the run the
    /// click asked for; killing its engine on its behalf risks leaving the manager
    /// dead if that start then hits one of `startRun`'s silent early-returns.
    func testForce_startAlreadyInFlight_doesNotTearDownOrDoubleCreate() async {
        let mgrID = await runningManager()
        sut.startingRunTaskIDs.insert(mgrID)
        defer { sut.startingRunTaskIDs.remove(mgrID) }
        let before = runCount(mgrID)

        await sut.startAutovisorPass(taskID: mgrID, force: true)

        XCTAssertEqual(runCount(mgrID), before, "the in-flight start owns the new run")
        XCTAssertEqual(sut.taskEngineStates[mgrID], .running,
                       "and the engine must NOT be torn down on its behalf")
        XCTAssertEqual(firstRunStepStatus(mgrID), .running, "nor its step drained")
    }

    // MARK: - Bookkeeping + feedback

    /// Force routes THROUGH `startRun`, so its manager hook (`autovisorLastWakeAt`,
    /// `autovisorCreationsThisReview`, `seedAutovisorNotifiedKeysForPassStart`) is
    /// free. A force path that bypassed `startRun` would silently leave the aborted
    /// pass's per-review creation budget and attention baselines in place.
    func testForce_runsTheManagerPassHook() async {
        let mgrID = await runningManager()
        sut.autovisorCreationsThisReview = 3
        sut.autovisorLastWakeAt = nil

        await sut.startAutovisorPass(taskID: mgrID, force: true)

        XCTAssertEqual(sut.autovisorCreationsThisReview, 0,
                       "the fresh pass gets a full create_managed_task budget")
        XCTAssertNotNil(sut.autovisorLastWakeAt, "the 'last reviewed' diagnostic is restamped")
        sut.stopEngineForTask(mgrID)
    }

    /// The `.running` supersede has no other visible signal — the board reads
    /// "running" before AND after — so it gets a banner.
    func testForce_supersededLivePass_postsInfoBanner() async {
        let mgrID = await runningManager()
        sut.lastInfoMessage = nil

        await sut.startAutovisorPass(taskID: mgrID, force: true)

        XCTAssertTrue(sut.lastInfoMessage?.contains("restarted") == true,
                      "a superseded live pass must say so; got \(sut.lastInfoMessage ?? "nil")")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: - Concurrency

    /// Two "Run now" clicks landing in the same window must produce ONE run.
    ///
    /// The force branch's own claim must be a WRITE, not a read: `pauseRun`
    /// genuinely suspends (`cancelStepExecution` awaits the cancel handler under a
    /// 3s bound), and `TeamEngine.pause()` writes `.paused` on its LAST line — so
    /// for the whole suspension the engine mirror still reads `.running` and the
    /// second click sees exactly the state the first one did. A read-only check
    /// against `startingRunTaskIDs` (which only `startRun` ever inserts into, well
    /// after this point) cannot serialize them: both would tear down and both would
    /// `createNewRun`, and the loser's `stopEngineForTask` would kill the engine the
    /// winner had just started — the double-`createNewRun` the ordering exists to
    /// prevent.
    func testForce_twoConcurrentClicks_produceExactlyOneRun() async {
        let mgrID = await runningManager()
        // Holds click #1 inside `pauseRun` long enough for click #2 to enter, by
        // yielding a few times as it unwinds from cancellation.
        sut.llmExecutionService._testInjectRunningTask(
            stepID: "r", taskID: mgrID,
            runningTask: Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                for _ in 0..<5 { await Task.yield() }
            }
        )
        let before = runCount(mgrID)

        async let first: Void = sut.startAutovisorPass(taskID: mgrID, force: true)
        async let second: Void = sut.startAutovisorPass(taskID: mgrID, force: true)
        _ = await (first, second)

        XCTAssertEqual(runCount(mgrID), before + 1,
                       "two concurrent force clicks must append exactly ONE run — a read-only "
                     + "guard lets both through, and the loser then kills the winner's engine")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: - Feature off

    /// A disabled Autovisor must never start a review pass. `fireRecurrence` has an
    /// explicit zombie guard for exactly this ("the manager's recurrence must never
    /// fire while the feature is off"); `startAutovisorPass` needs the same, because
    /// the manager's board — and its live "Run now" button — remain reachable after
    /// a disable via ⌘3 / the command palette (`detailView`'s `.task` branch renders
    /// `TeamBoardView` with no Autovisor gate, and `setAutovisorEnabled(false)` keeps
    /// `autovisorTaskID`).
    func testForce_autovisorDisabled_doesNotStartAPass() async {
        let mgrID = await runningManager()
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = false }
        sut.lastInfoMessage = nil
        let before = runCount(mgrID)

        await sut.startAutovisorPass(taskID: mgrID, force: true)

        XCTAssertEqual(runCount(mgrID), before,
                       "a disabled Autovisor must not run a zombie review pass")
        XCTAssertNotNil(sut.lastInfoMessage,
                        "and the refusal must say why — a silent no-op is the very defect "
                      + "force was introduced to fix")
    }

    /// The same gate on the default path, so no caller can start a zombie pass.
    func testNonForce_autovisorDisabled_doesNotStartAPass() async {
        let mgrID = await runningManager()
        sut.engineState[mgrID] = .needsSupervisorInput
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = false }
        let before = runCount(mgrID)

        await sut.startAutovisorPass(taskID: mgrID)

        XCTAssertEqual(runCount(mgrID), before, "disabled means disabled on every path")
    }

    /// The negative: nothing was superseded, so nothing is announced. Guards against
    /// a banner on every idle Run-now click (a single coalescing slot — it would
    /// clobber messages the user needs to see).
    func testForce_idleManager_postsNoBanner() async {
        let mgrID = await runningManager()
        sut.engineState[mgrID] = nil
        sut.lastInfoMessage = nil

        await sut.startAutovisorPass(taskID: mgrID, force: true)

        XCTAssertEqual(runCount(mgrID), 2, "precondition: the run still landed")
        XCTAssertNil(sut.lastInfoMessage, "no live pass was superseded, so no banner")
        sut.stopEngineForTask(mgrID)
    }
}
