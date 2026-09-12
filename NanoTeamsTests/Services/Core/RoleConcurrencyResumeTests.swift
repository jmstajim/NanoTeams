import XCTest

@testable import NanoTeams

/// Resume honours the concurrency cap.
///
/// `resumeRun` re-enters interrupted steps DIRECTLY, before any engine exists to apply
/// `RoleAdmissionControl` — so without a cap of its own the setting fails on its most common
/// path: four roles running, the user picks "One at a time", Pause, Resume, four roles
/// running again, permanently.
@MainActor
final class RoleConcurrencyResumeTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func startupTeamID() -> NTMSID {
        sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id ?? "missing"
    }

    /// Three roles left `.working` beside `.paused` steps — what `pauseRun` leaves behind.
    private func makePausedTask() async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(
            title: "T", supervisorTask: "build", preferredTeamID: startupTeamID(),
            makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await registerRoles(["alpha", "bravo", "charlie"], onTeamOf: taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: ["alpha", "bravo", "charlie"].map {
                    StepExecution(id: $0, role: .custom(id: $0), title: $0, status: .paused)
                },
                roleStatuses: ["alpha": .working, "bravo": .working, "charlie": .working])]
        }
        return taskID
    }

    private func pausedStepCount(_ taskID: Int) -> Int {
        sut.loadedTask(taskID)?.runs.last?.steps.filter { $0.status == .paused }.count ?? -1
    }

    /// Asserted the instant `resumeRun` returns: `runStep` marks the step `.running` before it
    /// spawns anything, and the engine's own loop has not had a suspension point to run in yet.
    func testResumeUnderCapOfOne_restartsExactlyOneStep() async {
        sut.configuration.roleConcurrencyMode = .single
        let taskID = await makePausedTask()

        await sut.resumeRun(taskID: taskID)
        let stillPaused = pausedStepCount(taskID)
        sut.stopAllEngines()

        XCTAssertEqual(stillPaused, 2,
                       "two of the three must be left for the run loop's parked-role pass")
    }

    /// The two remaining steps keep `.working` next to `.paused` — exactly the shape
    /// `TeamEngine.parkedRoleIDs` picks up — so nothing is dropped, only deferred.
    func testResumeUnderCapOfOne_leavesTheOthersInTheShapeTheEngineRestarts() async {
        sut.configuration.roleConcurrencyMode = .single
        let taskID = await makePausedTask()

        await sut.resumeRun(taskID: taskID)
        let run = sut.loadedTask(taskID)?.runs.last
        sut.stopAllEngines()

        for step in run?.steps.filter({ $0.status == .paused }) ?? [] {
            XCTAssertEqual(run?.roleStatuses[step.effectiveRoleID], .working,
                           "\(step.id) must stay parked, not be demoted")
        }
    }

    /// The failed-step revival loop is a second direct-restart site, and it runs BEFORE the
    /// interrupted-step branch — so it spends the allowance first.
    func testResumeUnderCapOfOne_revivesExactlyOneFailedStep() async {
        sut.configuration.roleConcurrencyMode = .single
        let taskID = await makePausedTask()
        await sut.mutateTask(taskID: taskID) { task in
            for index in task.runs[0].steps.indices {
                task.runs[0].steps[index].status = .failed
            }
            for roleID in task.runs[0].roleStatuses.keys {
                task.runs[0].roleStatuses[roleID] = .failed
            }
        }

        await sut.resumeRun(taskID: taskID)
        let run = sut.loadedTask(taskID)?.runs.last
        sut.stopAllEngines()

        XCTAssertEqual(run?.steps.filter { $0.status == .paused }.count, 2,
                       "revived to `.paused` but not started — the run loop picks them up")
        XCTAssertEqual(
            run?.roleStatuses.values.filter { $0 == .working }.count, 3,
            "all three are revived; only the START is rationed")
    }

    /// The third direct-restart site: a step whose Supervisor answer landed while it was
    /// suspended.
    func testResumeUnderCapOfOne_restartsOneAnsweredStep() async {
        sut.configuration.roleConcurrencyMode = .single
        let taskID = await makePausedTask()
        await sut.mutateTask(taskID: taskID) { task in
            for index in task.runs[0].steps.indices {
                task.runs[0].steps[index].supervisorAnswer = "go on"
            }
        }

        await sut.resumeRun(taskID: taskID)
        let stillPaused = pausedStepCount(taskID)
        sut.stopAllEngines()

        XCTAssertEqual(stillPaused, 2)
    }

    func testResumeUnderProviderLimited_restartsEveryStep() async {
        sut.configuration.roleConcurrencyMode = .providerLimited
        let taskID = await makePausedTask()

        await sut.resumeRun(taskID: taskID)
        let stillPaused = pausedStepCount(taskID)
        sut.stopAllEngines()

        XCTAssertEqual(stillPaused, 0, "the shipping default restarts all of them at once")
    }
}
