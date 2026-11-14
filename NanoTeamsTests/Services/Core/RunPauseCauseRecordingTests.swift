import XCTest
@testable import NanoTeams

/// Every code path that pauses a run records why on the run (`Run.pauseCause`), so the readers
/// that ask "is this the pause the timeout caused" — the event feed, the delegation awaiter and
/// Watchtower — get the same answer after a relaunch as before it.
@MainActor
final class RunPauseCauseRecordingTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func createTaskWithARunningStep(title: String = "Paused task") async throws -> Int {
        let created = await sut.createTask(title: title, supervisorTask: "Brief", makeActive: false)
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        await giveRunningStep(taskID)
        return taskID
    }

    private func giveRunningStep(_ taskID: Int, createdAt: Date = MonotonicClock.shared.now()) async {
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                createdAt: createdAt,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)],
                roleStatuses: ["eng": .working]
            )]
        }
    }

    private func cause(of taskID: Int) -> Run.PauseCause? {
        sut.loadedTask(taskID)?.runs.last?.pauseCause
    }

    // MARK: - pauseRun

    /// RED before 2026-11-07: nothing recorded a cause.
    func testPauseRun_recordsARequestedPause() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createTaskWithARunningStep()

        await sut.pauseRun(taskID: taskID)

        XCTAssertEqual(cause(of: taskID), .requested)
    }

    /// The cause belongs to the task that was asked to pause; a cascade pauses its children on
    /// the parent's behalf, which none of them started — so a child of a timed-out parent did not
    /// time out, and its awaiter must not read that it did.
    func testPauseRun_withATimeoutCause_recordsItOnTheRoot_andARequestedPauseOnItsChildren() async throws {
        await sut.openWorkFolder(tempDir)
        let parentID = try await createTaskWithARunningStep(title: "Parent")
        let created = await sut.createDelegatedTask(
            parentTaskID: parentID,
            parentRoleID: "eng",
            title: "Child",
            supervisorTask: "Sub-brief",
            preferredTeamID: nil,
            depth: 1
        )
        let childID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(childID)
        await giveRunningStep(childID)
        XCTAssertEqual(sut.childTaskIDs(of: parentID), [childID], "premise: the child is the parent's")

        await sut.pauseRun(taskID: parentID, cause: .runTimedOut)

        XCTAssertEqual(cause(of: parentID), .runTimedOut)
        XCTAssertEqual(cause(of: childID), .requested)
    }

    /// A later Pause replaces the cause the timeout recorded: it describes the latest pause.
    func testAPauseAfterTheTimeout_replacesItsCause() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createTaskWithARunningStep()
        await sut.pauseRun(taskID: taskID, cause: .runTimedOut)
        XCTAssertEqual(cause(of: taskID), .runTimedOut)
        await giveRunningStep(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].timedOutAt = MonotonicClock.shared.now()
            task.runs[0].pauseCause = .runTimedOut
        }

        await sut.pauseRun(taskID: taskID)

        let run = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last)
        XCTAssertEqual(run.pauseCause, .requested)
        XCTAssertFalse(run.latestPauseIsItsTimeout, "the person's pause after the timeout is not the timeout's")
    }

    // MARK: - A Pause that stops nothing

    /// A Pause of a run that already stands paused stops nothing — no step is running and
    /// `TeamEngine.pause()` returns at its guard — so the pause that stands keeps its cause.
    ///
    /// RED before 2026-11-07: the cause was written whenever it differed, so pressing Pause on a
    /// timed-out run turned the timeout's pause into the person's — Watchtower dropped "timed out"
    /// and the agent received a second `paused` event saying the person had paused it.
    func testAPauseOfARunThatAlreadyStandsPaused_keepsTheCauseOfThePauseThatStands() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createTaskWithARunningStep()
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].timedOutAt = MonotonicClock.shared.now() }
        await sut.pauseRun(taskID: taskID, cause: .runTimedOut)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.first?.status, .paused, "premise: the timeout's pause stands")

        await sut.pauseRun(taskID: taskID)

        let run = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last)
        XCTAssertEqual(run.pauseCause, .runTimedOut)
        XCTAssertTrue(run.latestPauseIsItsTimeout)
    }

    /// The same with the engine the watchdog leaves behind: paused, still registered — which is
    /// what lets `control_task pause` reach `pauseRun` instead of refusing an already-paused task.
    func testAPauseOfARunWhoseEngineStandsPaused_keepsTheTimeoutsCause() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createTaskWithARunningStep()
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].timedOutAt = MonotonicClock.shared.now() }
        await sut.pauseRun(taskID: taskID, cause: .runTimedOut)
        sut.engineForTask(taskID).transition(to: .paused)
        XCTAssertEqual(sut.taskEngineStates[taskID], .paused, "premise: a paused engine is registered")

        let reportedPaused = await sut.pauseRun(taskID: taskID)

        XCTAssertTrue(reportedPaused, "the task is paused, as before")
        XCTAssertEqual(cause(of: taskID), .runTimedOut)
    }

    /// A pause status recovery made keeps its cause too: the latch it armed on relaunch stands.
    func testAPauseOfARecoveredRun_keepsTheRecoveredCause() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createTaskWithARunningStep()
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].status = .paused
            task.runs[0].pauseCause = .recovered
            task.status = .paused
        }

        await sut.pauseRun(taskID: taskID)

        XCTAssertEqual(cause(of: taskID), .recovered)
    }

    /// A run with no steps and no engine — a task created and never started — records nothing.
    func testAPauseOfAnIdleRun_recordsNothing() async throws {
        await sut.openWorkFolder(tempDir)
        let created = await sut.createTask(title: "Never started", supervisorTask: "Brief", makeActive: false)
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [], roleStatuses: [:])]
        }

        await sut.pauseRun(taskID: taskID)

        XCTAssertNil(cause(of: taskID))
    }

    // MARK: - The run-timeout watchdog

    func testRunTimeoutWatchdog_recordsTheTimeoutAsThePausesCause() async throws {
        await sut.openWorkFolder(tempDir)
        let created = await sut.createTask(title: "Over budget", supervisorTask: "Brief", makeActive: false)
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        let now = Date()
        _ = await sut.mutateTask(taskID: taskID) { $0.runTimeoutSeconds = 60 }
        await giveRunningStep(taskID, createdAt: now.addingTimeInterval(-120))
        sut.engineState[taskID] = .running

        await sut.evaluateRunTimeouts(now: now)

        let run = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last)
        XCTAssertNotNil(run.timedOutAt, "premise: the watchdog fired")
        XCTAssertEqual(run.pauseCause, .runTimedOut)
        XCTAssertTrue(run.latestPauseIsItsTimeout)
    }

    // MARK: - The engine's iteration-limit pause

    func testIterationLimitPause_recordsItsCause() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createTaskWithARunningStep()
        let engine = sut.engineForTask(taskID)

        engine.onIterationLimitPaused?(5)
        for _ in 0..<50 where cause(of: taskID) == nil {
            await Task.yield()
        }

        XCTAssertEqual(cause(of: taskID), .iterationLimit)
    }
}
