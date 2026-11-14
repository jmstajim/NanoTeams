import XCTest

@testable import NanoTeams

/// One-shot async gate. `wait()` suspends until `open()` is called; after that it
/// never suspends again.
///
/// Exists so the tests below can ask a question that has no wall-clock answer:
/// "what is true at the moment the chat is told to open, and not yet true?".
/// Checking quickly and hoping would pass against the very ordering being pinned —
/// the launch phase is normally shorter than the suspension the assertion takes.
private final class LaunchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        isOpen = true
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

/// Pins the boundary that makes the chat open immediately after Send.
///
/// `createPreparedTaskAndStart` returns once the task exists and its first run is
/// materialized; the run's LAUNCH — the agent-instruction and role-skill rescans,
/// then the engine — continues behind the already-open chat. Before this split the
/// navigation was posted after the whole chain, so the chat stayed closed for the
/// full prompt warm-up.
///
/// A regression that re-merges the phases makes the create call await the closed
/// gate, so these tests fail by TIMING OUT rather than by assertion. That is
/// deliberate but unreadable on its own, which is why `Ratchet/RunStartOrderingPinTests`
/// pins the same property at the source level and fails fast (CLAUDE.md #60 — a
/// property defended by two mechanisms needs both halves pinned).
@MainActor
final class RunStartOrderingTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var gate: LaunchGate!

    override func setUp() async throws {
        try await super.setUp()
        gate = LaunchGate()
        let gate = gate!
        NTMSOrchestrator._testRunLaunchGate = { await gate.wait() }
    }

    override func tearDown() async throws {
        // Opened BEFORE the seam is cleared and before the orchestrator is torn down:
        // a launch left suspended on a closed gate holds a continuation forever, and
        // `withCheckedContinuation` reports a leaked continuation as a test failure.
        gate?.open()
        NTMSOrchestrator._testRunLaunchGate = nil
        gate = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeRequest(
        title: String = "Ship the thing",
        brief: String = "Add a button",
        attachments: [TaskCreationStagedAttachment] = []
    ) -> TaskCreationRequest {
        TaskCreationRequest(
            title: title,
            rawSupervisorTask: brief,
            preferredTeamID: nil,
            clippedTexts: [],
            stagedAttachments: attachments
        )
    }

    // MARK: - The navigation boundary

    func testCreatePreparedTask_returnsWithRunMaterialized_whileLaunchStillGated() async {
        await sut.openWorkFolder(tempDir)

        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }

        // Everything the board renders against is already true.
        XCTAssertEqual(sut.activeTaskID, taskID)
        XCTAssertEqual(sut.activeTask?.runs.count, 1)
        XCTAssertFalse(
            sut.activeTask?.runs.last?.roleStatuses.isEmpty ?? true,
            "The run must carry its seeded role statuses — the graph reads them raw"
        )
        XCTAssertEqual(
            sut.activeTask?.supervisorTask, "Add a button",
            "The Supervisor's own message is a TASK-level feed item, so the chat has "
                + "something to show before any step exists"
        )

        // And the launch has NOT happened yet.
        XCTAssertNotNil(sut.runStartTask(for: taskID),
                        "The launch must be registered so tests and headless runs can join it")
        XCTAssertNotEqual(sut.taskEngineStates[taskID], .running,
                          "The engine belongs to the launch phase, behind the open chat")
    }

    func testLaunchPhaseCompletes_afterTheGateOpens() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }

        gate.open()
        await sut.runStartTask(for: taskID)?.value

        XCTAssertEqual(sut.taskEngineStates[taskID], .running,
                       "Opening the gate must let the backgrounded launch reach engine.start()")
        XCTAssertNil(sut.runStartTask(for: taskID),
                     "A finished launch must clear its registry entry")
        XCTAssertFalse(sut.engineState.isInitializingRun(taskID),
                       "…and release the run-start claim it held for both phases")
    }

    // MARK: - The inline contract is unchanged

    func testStartRun_stillCompletesBothPhases() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Inline", supervisorTask: "Do it") else {
            XCTFail("Expected the task to be created")
            return
        }
        gate.open()   // an inline start awaits the launch, so the gate must be open

        await sut.startRun(taskID: taskID)

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, 1)
        XCTAssertEqual(sut.taskEngineStates[taskID], .running)
        XCTAssertNil(sut.runStartTask(for: taskID),
                     "An inline start has no background handle — the caller's own await is the join")
        XCTAssertFalse(sut.engineState.isInitializingRun(taskID))
    }

    // MARK: - Concurrency

    func testConcurrentStartRun_whileBackgroundLaunchInFlight_doesNotDoubleStart() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }

        // A Play click / queue-flush wake arriving while the launch is still suspended.
        await sut.startRun(taskID: taskID)

        XCTAssertEqual(sut.activeTask?.runs.count, 1,
                       "The claim spans BOTH phases, so a competing start must be refused")
    }

    func testClaimRunStart_isRefusedWhileABackgroundLaunchHoldsIt() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }

        XCTAssertNil(sut.claimRunStart(taskID: taskID),
                     "A refused claim reports `nil` — there is no generation to own")

        gate.open()
        await sut.runStartTask(for: taskID)?.value

        XCTAssertFalse(sut.engineState.isInitializingRun(taskID))
    }

    // MARK: - Initializing: the fact the four surfaces render

    /// The phase is VISIBLE while it lasts. Before this, the claim was an
    /// `@ObservationIgnored` set on the orchestrator, so the navbar offered `start`, the
    /// Quick Capture panel fell back to the new-task composer and the feed showed
    /// nothing — the user's "it looks like nothing is happening".
    ///
    /// RED: make `claimRunStart` keep its own private set instead of
    /// `engineState.beginRunStart` → this fails while every ordering test above stays
    /// green, because they only ever ask whether the LAUNCH ran.
    func testRunStartIsObservable_atTheNavigationBoundary() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }

        XCTAssertTrue(sut.engineState.isInitializingRun(taskID),
                      "The chat is open and the engine is not running yet — this is exactly "
                          + "the window the four surfaces must report")
        XCTAssertNotEqual(sut.taskEngineStates[taskID], .running,
                          "Anti-vacuum: if the engine were already running the fact above "
                              + "would be trivially uninteresting")
    }

    // MARK: - Pause during initialization

    /// Pause pressed while `Initializing…` is on screen must actually stop the run —
    /// the navbar offers `pause` there, and a button that does nothing is worse than the
    /// `start` it replaced.
    ///
    /// RED: drop `abortRunStart` from `pauseRun` → the launch reaches `engine.start()`
    /// once the gate opens and the engine-state assertion fails.
    func testPauseWhileInitializing_stopsTheRun_andReportsSuccess() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }

        let verdict = await sut.pauseRun(taskID: taskID)

        XCTAssertTrue(verdict,
                      "An aborted start produces no engine, so judging this by the engine "
                          + "mirror alone reports a successful Pause as a failure")
        XCTAssertFalse(sut.engineState.isInitializingRun(taskID),
                       "Every Initializing surface must go dark on this tick, not when the "
                           + "detached scan finally returns")

        gate.open()
        await sut.runStartTask(for: taskID)?.value

        XCTAssertNotEqual(sut.taskEngineStates[taskID], .running,
                          "The aborted launch must refuse at its next re-check — everything "
                              + "past that line WRITES")
    }

    /// The same, on the INLINE path: `startRun` from Play / Autovisor / recurrence
    /// registers nothing in `backgroundRunLaunches`, so there is no `Task` to cancel and
    /// the generation counter is the whole mechanism.
    ///
    /// RED: make `abortRunStart` cancel without bumping the generation → this fails while
    /// the background test above stays green on the cancellation's merit. Two paths, two
    /// tests (CLAUDE.md #51/#60).
    func testPauseWhileInliningTheStart_stopsIt_withNoTaskToCancel() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "t", supervisorTask: "b") else {
            XCTFail("Expected the task to be created")
            return
        }
        await sut.switchTask(to: taskID)

        let inlineStart = Task { @MainActor in await self.sut.startRun(taskID: taskID) }
        // The claim is taken synchronously inside `startRun`, but the Task has to be
        // scheduled first — yield until it is visible rather than guessing a duration.
        while !sut.engineState.isInitializingRun(taskID) { await Task.yield() }

        XCTAssertNil(sut.runStartTask(for: taskID),
                     "Anti-vacuum: an inline start registers no launch, which is what makes "
                         + "this the case cancellation alone cannot defend")

        let verdict = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(verdict)

        gate.open()
        await inlineStart.value

        XCTAssertNotEqual(sut.taskEngineStates[taskID], .running,
                          "The inline launch re-checks the same predicate and must refuse")
    }

    // MARK: - Generations

    /// Abort, then start again while the first launch is still unwinding. Only the new
    /// one may proceed — and the old one's `defer` must not drop the new one's claim.
    ///
    /// RED: drop the generation check from `releaseRunStart` → the stale release clears
    /// the claim and the first assertion fails, with every surface going dark over a run
    /// that is really starting.
    func testAbortThenRestart_theStaleLaunchDoesNotDisturbTheNewClaim() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }
        let stale = sut.runStartTask(for: taskID)

        XCTAssertTrue(sut.abortRunStart(taskID: taskID))
        guard let fresh = sut.claimRunStart(taskID: taskID) else {
            XCTFail("An aborted start must leave the task startable again")
            return
        }

        // The stale launch unwinds now, with the new claim already held.
        gate.open()
        await stale?.value

        XCTAssertTrue(sut.engineState.isInitializingRun(taskID),
                      "The new start's claim survives the old launch's release")

        sut.releaseRunStart(taskID: taskID, claim: fresh)
        XCTAssertFalse(sut.engineState.isInitializingRun(taskID),
                       "Anti-vacuum: the matching release still works, so the guard above "
                           + "is about the GENERATION and not about releases being broken")
    }

    // MARK: - Corner cases

    func testCreateFails_emptyTitleAndBrief_spawnsNoRunStart() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createPreparedTaskAndStart(
            request: makeRequest(title: "   ", brief: "  \n ")
        )

        XCTAssertNil(taskID)
        XCTAssertTrue(sut.backgroundRunLaunches.isEmpty)
        XCTAssertTrue(sut.engineState.initializingRunTaskIDs.isEmpty)
    }

    func testFinalizeAttachmentsFailure_removesTask_andSpawnsNoRunStart() async {
        await sut.openWorkFolder(tempDir)

        // A staged path that was never written: `finalizeAttachments` cannot copy it.
        let ghost = TaskCreationStagedAttachment(
            projectRelativePath: ".nanoteams/staged/\(UUID().uuidString)/ghost.txt",
            isProjectReference: false
        )

        let taskID = await sut.createPreparedTaskAndStart(request: makeRequest(attachments: [ghost]))

        XCTAssertNil(taskID)
        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertTrue(sut.backgroundRunLaunches.isEmpty,
                      "A creation that rolled back must not leave a launch running against a deleted task")
        XCTAssertTrue(sut.engineState.initializingRunTaskIDs.isEmpty)
    }

    /// `stopEngine` alone — the task is NOT removed, so `loadedTask(taskID)` still answers.
    /// Only the cancellation can stop this launch, which is what separates this test from
    /// `testTaskRemovedWhileLaunchIsSuspended_…` above: that one is green on the
    /// loaded-task guard's merit even with the cancel deleted.
    ///
    /// RED: delete `abortRunStart(taskID:)` from `stopEngine(for:)` → the launch resumes past
    /// every guard and `XCTAssertNil(sut.taskEngineStates[taskID])` fails.
    func testStopEngine_cancelsThePendingLaunch() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }

        sut.stopEngine(for: taskID)
        gate.open()
        // `runStartTask(for:)?.value`, NEVER `drainRunStartLaunches()`: the drain cancels
        // before it awaits, so joining through it would supply the very cancellation this
        // test exists to attribute to `stopEngine`. Measured — with the drain here, the
        // mutation "delete the cancel from `stopAllEngines`" (before 2026-10-28) stayed GREEN on the sibling
        // test while its source pin went red (CLAUDE.md #56, reading #3: the fixture never
        // selected the mutated branch). A join that mutates is not a join.
        await sut.runStartTask(for: taskID)?.value

        XCTAssertNotNil(
            sut.loadedTask(taskID),
            "Fixture precondition: the task is still loaded, so the loaded-task guard "
                + "cannot be what stops this launch"
        )
        XCTAssertNil(sut.taskEngineStates[taskID],
                     "A launch must not create an engine after the verb that removed one")
        XCTAssertTrue(sut.backgroundRunLaunches.isEmpty)
        XCTAssertTrue(sut.engineState.initializingRunTaskIDs.isEmpty)
    }

    /// The case that makes cancellation load-bearing rather than tidy.
    ///
    /// `NTMSTask.id` is a sequential `Int` scoped to ONE work folder, so two folders both
    /// have a task 1. A launch suspended in folder A's prompt warm-up, resuming after the
    /// user switched to folder B, finds B's task 1 loaded — `loadedTask(taskID) != nil` is
    /// TRUE and says nothing useful — and would start an engine on a task nobody asked to
    /// run (CLAUDE.md #74: a key that outlives the data it identifies).
    ///
    /// The id collision is asserted, not assumed: without it this test would be green on
    /// the loaded-task guard's merit and would stop describing the defect the moment task
    /// numbering changed (CLAUDE.md #93).
    ///
    /// RED: delete the `abortRunStart` loop from `stopAllEngines()` → the launch starts an
    /// engine on the OTHER folder's task of the same id and the `XCTAssertNil` fails. (Until
    /// 2026-10-28 the verb cancelled background launches with `cancelAllRunStartLaunches()`;
    /// since 2026-10-28 it abandons every start, inline ones included, and the cancel is one of
    /// `abortRunStart`'s acts.)
    func testWorkFolderSwitchWhileLaunchSuspended_doesNotStartAnEngineInTheNewFolder() async {
        let otherDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("other-folder-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherDir) }

        // Folder B gets a task first, through the plain creator so no launch is spawned.
        await sut.openWorkFolder(otherDir)
        guard let otherTaskID = await sut.createTask(title: "Theirs", supervisorTask: "Not this one")
        else {
            XCTFail("Expected the other folder's task to be created")
            return
        }

        // Folder A: the create path leaves its launch suspended on the gate.
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }
        XCTAssertEqual(
            taskID, otherTaskID,
            "Fixture precondition: both folders must number their first task the same, or "
                + "this test stops describing the collision it exists for"
        )

        let launch = sut.runStartTask(for: taskID)
        XCTAssertNotNil(launch, "Fixture precondition: the create registered its launch")

        // The user switches back. `openWorkFolder` runs `stopAllEngines()`.
        await sut.openWorkFolder(otherDir)
        // The boundary abandons the start then and there — all three acts of `abortRunStart`:
        // the claim ends and the launch is cancelled now, not when the scan it is parked in
        // returns (the generation, the refusal itself, is what the assertion below reads).
        XCTAssertFalse(sut.engineState.isInitializingRun(taskID), "the start's claim outlived the boundary")
        XCTAssertEqual(launch?.isCancelled, true, "the boundary did not cancel the launch")
        gate.open()
        // Same reason as in `testStopEngine_cancelsThePendingLaunch`: the drain would
        // cancel the launch itself and this test would pass with the cancel deleted from
        // `stopAllEngines`.
        await sut.runStartTask(for: taskID)?.value

        XCTAssertNotNil(
            sut.loadedTask(taskID),
            "Fixture precondition: the OTHER folder's task of the same id is loaded, so the "
                + "loaded-task guard is satisfied and cannot be what refuses the launch"
        )
        XCTAssertNil(
            sut.taskEngineStates[taskID],
            "A launch belonging to the previous work folder must not start anything in the new one"
        )
    }

    /// `stopEngine` for a task whose start is INLINE — Play, the Autovisor, a recurrence fire,
    /// a delegation child — registers no launch to cancel: the verb abandons the start
    /// (`abortRunStart`), so its launch refuses at its next re-check by its generation, and the
    /// claim ends at once.
    ///
    /// RED until 2026-10-28: `stopEngine` only cancelled a background launch; the inline
    /// start resumed past every re-check and created an engine after the verb that removed one.
    func testStopEngine_abandonsAnInlineStart() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "t", supervisorTask: "b") else {
            XCTFail("Expected the task to be created")
            return
        }
        let inlineStart = Task { @MainActor in await self.sut.startRun(taskID: taskID) }
        while !sut.engineState.isInitializingRun(taskID) { await Task.yield() }
        XCTAssertNil(sut.runStartTask(for: taskID), "Anti-vacuum: an inline start registers no launch")

        sut.stopEngine(for: taskID)
        XCTAssertFalse(sut.engineState.isInitializingRun(taskID), "the start's claim outlived the stop")
        gate.open()
        await inlineStart.value

        XCTAssertNotNil(sut.loadedTask(taskID), "Fixture precondition: the task is still loaded")
        XCTAssertNil(sut.taskEngineStates[taskID],
                     "An inline start must not create an engine after the verb that removed one")
    }

    func testTaskRemovedWhileLaunchIsSuspended_launchIsASafeNoOp() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }

        await sut.removeTask(taskID)
        gate.open()
        await sut.runStartTask(for: taskID)?.value

        XCTAssertNil(sut.taskEngineStates[taskID],
                     "engineForTask is a WRITE — a vanished task must not get a live engine")
        XCTAssertTrue(sut.backgroundRunLaunches.isEmpty)
        XCTAssertTrue(sut.engineState.initializingRunTaskIDs.isEmpty)
    }
    func testAbortRunStart_withNothingInFlight_reportsFalse() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "t", supervisorTask: "b") else {
            XCTFail("Expected the task to be created")
            return
        }

        XCTAssertFalse(sut.abortRunStart(taskID: taskID),
                       "Nothing was started, so nothing was aborted — the verdict Pause "
                           + "reports must not claim otherwise")
    }

    func testAbortRunStart_twice_theSecondReportsFalse() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }

        XCTAssertTrue(sut.abortRunStart(taskID: taskID))
        XCTAssertFalse(sut.abortRunStart(taskID: taskID),
                       "Idempotent, and honest about it: a second Pause aborted nothing")
    }

    /// `runLaunchIsStillWanted` — the `!Task.isCancelled` half alone (D-M11 п.15):
    /// a launch whose own task is cancelled while its folder lifecycle, loaded task, and
    /// `runStartGeneration` are all still intact must not create an engine.
    func testLaunchTaskCancelledWithoutGenerationOrLifecycleChange_doesNotStartAnEngine() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createPreparedTaskAndStart(request: makeRequest()) else {
            XCTFail("Expected the task to be created")
            return
        }
        let launch = sut.runStartTask(for: taskID)
        XCTAssertNotNil(launch, "Premise: background launch is registered")

        sut.cancelRunStartLaunch(taskID: taskID)
        XCTAssertEqual(launch?.isCancelled, true, "Premise: the launch task is cancelled")
        XCTAssertEqual(sut.runStartGeneration[taskID], 1, "Premise: generation was not bumped")
        gate.open()
        await launch?.value

        XCTAssertNotNil(sut.loadedTask(taskID), "Premise: the task is still loaded")
        XCTAssertNil(sut.taskEngineStates[taskID],
                     "A cancelled launch task must not start an engine even when lifecycle and generation still match")
        XCTAssertTrue(sut.taskEngines.isEmpty)
    }

    /// `runLaunchIsStillWanted` — the `isCurrentFolderLifecycle(claim.lifecycle)` half alone (D-M11 п.16):
    /// a launch whose claim's folder lifecycle has ended while the task is loaded, the task is not
    /// cancelled, and `runStartGeneration` matches `claim.generation` must not create an engine.
    func testLaunchWhoseClaimsLifecycleEndedWithoutAGenerationBump_doesNotStartAnEngine() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "t", supervisorTask: "b") else {
            XCTFail("Expected the task to be created")
            return
        }
        await sut.materializeRun(taskID: taskID)
        let endedLifecycle = WorkFolderLifecycle(generation: sut.workFolderOpenGeneration - 1)
        sut.runStartGeneration[taskID] = 1
        let staleClaim = RunStartClaim(generation: 1, lifecycle: endedLifecycle)
        gate.open()

        await sut.launchRun(taskID: taskID, claim: staleClaim)

        XCTAssertNotNil(sut.loadedTask(taskID), "Premise: the task is loaded")
        XCTAssertEqual(sut.runStartGeneration[taskID], staleClaim.generation, "Premise: generation matches")
        XCTAssertNil(sut.taskEngineStates[taskID],
                     "A launch with an ended folder lifecycle must not create an engine even when generation matches")
        XCTAssertTrue(sut.taskEngines.isEmpty)
    }

    /// `runLaunchIsStillWanted` — the `loadedTask(taskID) != nil` half alone (D-M11 п.17):
    /// a launch whose task was evicted from memory without a stop verb (so neither cancellation,
    /// folder lifecycle, nor `runStartGeneration` refuses it) must not reach `engineForTask`.
    func testTaskEvictedWhileLaunchIsSuspended_doesNotStartAnEngine() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "evictable", supervisorTask: "b", makeActive: false),
              let _ = await sut.createTask(title: "active", supervisorTask: "b", makeActive: true)
        else {
            XCTFail("Expected tasks to be created")
            return
        }
        let inlineStart = Task { @MainActor in await self.sut.startRun(taskID: taskID) }
        while !sut.engineState.isInitializingRun(taskID) { await Task.yield() }

        sut.evictLoadedTask(taskID)
        XCTAssertNil(sut.loadedTask(taskID), "Premise: task was evicted without a stop verb")
        XCTAssertEqual(sut.runStartGeneration[taskID], 1, "Premise: generation was not bumped")
        gate.open()
        await inlineStart.value

        XCTAssertNil(sut.taskEngineStates[taskID],
                     "An evicted task must not get a live engine")
        XCTAssertTrue(sut.taskEngines.isEmpty)
    }

    /// `stopAllEngines` — abandons inline starts and bumps `runStartGeneration` (D-M11 п.14 & п.18):
    /// when `stopAllEngines()` runs in the same folder while an inline start (which registers no
    /// `backgroundRunLaunches` entry) is parked on the launch gate, `runStartGeneration` is the
    /// sole condition that refuses the inline start once the gate opens.
    func testStopAllEngines_abandonsAnInlineStartInTheSameFolder() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "inline", supervisorTask: "b") else {
            XCTFail("Expected the task to be created")
            return
        }
        let inlineStart = Task { @MainActor in await self.sut.startRun(taskID: taskID) }
        while !sut.engineState.isInitializingRun(taskID) { await Task.yield() }
        XCTAssertNil(sut.runStartTask(for: taskID), "Premise: inline start has no background launch task")

        sut.stopAllEngines()
        XCTAssertFalse(sut.engineState.isInitializingRun(taskID))
        XCTAssertEqual(sut.runStartGeneration[taskID], 2, "stopAllEngines must bump the start generation")
        gate.open()
        await inlineStart.value

        XCTAssertNotNil(sut.loadedTask(taskID), "Premise: task is still loaded in the same folder")
        XCTAssertNil(sut.taskEngineStates[taskID],
                     "An inline start must be refused by its generation after stopAllEngines()")
        XCTAssertTrue(sut.taskEngines.isEmpty)
    }

}
