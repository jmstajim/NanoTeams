import XCTest

@testable import NanoTeams

/// End-to-end regression pin: **a completed run must survive an app restart into a
/// reviewable state.**
///
/// Role status and step status are two encodings of one fact, written by two subsystems
/// in two separate `mutateTask` calls (`finalizeStepCompletion` writes the step; the
/// engine writes the role later, via `waitForStepCompletion`'s 250 ms poll). A quit in
/// between — or a `pauseRun`, which cancels the engine's `roleTasks` and never touches
/// role statuses — persists a TORN pair.
///
/// Pre-fix, the next launch blindly demoted the role `.working` → `.idle`, and
/// `derivedStatusFromActiveRun` took its "roles still working" arm forever: the task read
/// "Working", every review affordance (all of which reduce to `isReadyForFinalAcceptance`)
/// was hidden, and the only offered control was a "resume" that RE-RAN the finished role.
@MainActor
final class CompletedRunRestartRecoveryTests: NTMSOrchestratorTestBase {

    // MARK: - Helpers

    private var jsonStore: AtomicJSONStore { AtomicJSONStore() }

    /// Startup: one producing Software Engineer role, `.finalOnly` acceptance, and the
    /// Supervisor requires its deliverable — so the review gate is the task-level one.
    private func startupTeamID() -> NTMSID {
        sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id ?? "missing"
    }

    /// Shapes a run on disk as "the worker finished, the role status never caught up".
    private func plantRun(
        taskID: Int,
        stepStatus: StepStatus,
        roleStatus: RoleExecutionStatus,
        stepMessages: [StepMessage] = []
    ) async {
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.status = .running
            let step = StepExecution(
                id: "r", role: .softwareEngineer, title: "Engineer",
                status: stepStatus, messages: stepMessages,
                artifacts: stepStatus == .done ? [Artifact(name: "Engineering Notes")] : []
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": roleStatus])]
        }
    }

    /// Simulates force-quit + relaunch: a fresh orchestrator over the same folder.
    private func restartOrchestrator() async {
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient
        )
        await sut.openWorkFolder(tempDir)
    }

    private func diskIndexStatus(_ taskID: Int) -> TaskStatus? {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let index = try? jsonStore.read(TasksIndex.self, from: paths.tasksIndexJSON)
        return index?.tasks.first(where: { $0.id == taskID })?.status
    }

    private func memIndexStatus(_ taskID: Int) -> TaskStatus? {
        sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.status
    }

    /// Reads the persisted task — the sweep evicts what it healed, so an in-memory read
    /// would be `nil` for a background task.
    private func diskRoleStatus(_ taskID: Int) -> RoleExecutionStatus? {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let task = try? jsonStore.read(NTMSTask.self, from: paths.taskJSON(taskID: taskID))
        return task?.runs.last?.roleStatuses["r"]
    }

    /// The settled role status discriminates the gate that produced it, which the index
    /// status CANNOT: `derivedStatusFromActiveRun` maps BOTH `.done` (via the
    /// `allRolesComplete` arm) and `.needsAcceptance` (via `onlyAcceptanceOrComplete`) to
    /// `.needsSupervisorAcceptance`. Startup is `.finalOnly` ⇒ `.done`; a `teamSettings:
    /// nil` regression would fall back to `TeamSettings.default` (`.afterEachRole`) ⇒
    /// `.needsAcceptance`. Asserting the ROLE is therefore the only thing that pins the
    /// wiring the `no-default-value` rule exists to protect.
    private func assertResolvedItsOwnTeamGate(_ taskID: Int, line: UInt = #line) {
        XCTAssertEqual(
            diskRoleStatus(taskID), .done,
            "recovery must resolve the gate off the TASK'S OWN team (.finalOnly ⇒ .done); "
            + "a nil teamSettings would settle .needsAcceptance instead",
            line: line
        )
    }

    private func assertReviewable(_ taskID: Int, expectedRoleStatus: RoleExecutionStatus, line: UInt = #line) {
        guard let task = sut.loadedTask(taskID) else {
            return XCTFail("task \(taskID) not loaded after restart", line: line)
        }
        XCTAssertEqual(task.runs.last?.roleStatuses["r"], expectedRoleStatus, line: line)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance,
                       "the board must read Review, not Working", line: line)
        XCTAssertEqual(memIndexStatus(taskID), .needsSupervisorAcceptance,
                       "the sidebar reads the in-memory index", line: line)
        XCTAssertEqual(diskIndexStatus(taskID), .needsSupervisorAcceptance,
                       "the recovered status must be persisted, or the next launch repeats the bug",
                       line: line)
    }

    // MARK: - The restart bug

    /// The quit-inside-the-poll-gap / quit-while-paused shape.
    func testCompletedRunSurvivesRestart_intoReviewableState() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "M4", supervisorTask: "breathing",
                                          preferredTeamID: startupTeamID())!
        await plantRun(taskID: taskID, stepStatus: .done, roleStatus: .working)

        await restartOrchestrator()

        assertReviewable(taskID, expectedRoleStatus: .done)
        assertResolvedItsOwnTeamGate(taskID)
        XCTAssertTrue(sut.loadedTask(taskID)!.isReadyForFinalAcceptance,
                      "every review affordance reduces to this")
        XCTAssertEqual(sut.taskEngineStates[taskID], .done)
        XCTAssertNil(
            TeamBoardRunControl.select(engineState: sut.taskEngineStates[taskID], isHistoricalRun: false),
            "a finished run must not offer a 'resume' that re-runs the finished role"
        )
        XCTAssertNotEqual(sut.loadedTask(taskID)?.status, .paused,
                          "settling a finished pair is not a park — the latch must stay clear")
    }

    /// **The state on the user's disk right now**, written by a pre-fix build. It must
    /// heal on the next launch with no migration and no user action.
    func testAlreadyDemotedRunHealsOnNextLaunch() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "M4", supervisorTask: "breathing",
                                          preferredTeamID: startupTeamID())!
        await plantRun(taskID: taskID, stepStatus: .done, roleStatus: .idle)

        await restartOrchestrator()

        assertReviewable(taskID, expectedRoleStatus: .done)
    }

    /// A completed task the user is NOT looking at is healed by the index-wide sweep,
    /// so the sidebar stops lying too.
    ///
    /// Cold branch: after a restart the background task is not in `loadedTasks`
    /// (`assembleContext` resolves only the active task), so the sweep goes through
    /// `ensureTaskLoaded` — the gate-resolution site in `+RunInfrastructure`.
    func testBackgroundCompletedRun_healedBySweep() async {
        await sut.openWorkFolder(tempDir)
        _ = await sut.createTask(title: "Foreground", supervisorTask: "front")!
        let background = await sut.createTask(title: "M4", supervisorTask: "breathing",
                                              preferredTeamID: startupTeamID(), makeActive: false)!
        await plantRun(taskID: background, stepStatus: .done, roleStatus: .working)

        await restartOrchestrator()

        XCTAssertEqual(memIndexStatus(background), .needsSupervisorAcceptance)
        XCTAssertEqual(diskIndexStatus(background), .needsSupervisorAcceptance)
        assertResolvedItsOwnTeamGate(background)
    }

    /// Warm branch: an in-process re-open of the SAME folder preserves `loadedTasks`, so
    /// the sweep takes its probe path instead — the gate-resolution site in
    /// `+WorkFolderManagement`. Both sites must resolve the task's own team, and neither
    /// is reachable from the other's test.
    func testLoadedBackgroundCompletedRun_sweepProbeResolvesItsOwnTeamGate() async {
        await sut.openWorkFolder(tempDir)
        _ = await sut.createTask(title: "Foreground", supervisorTask: "front")!
        let background = await sut.createTask(title: "M4", supervisorTask: "breathing",
                                              preferredTeamID: startupTeamID(), makeActive: false)!
        await plantRun(taskID: background, stepStatus: .done, roleStatus: .working)
        XCTAssertNotNil(sut.loadedTask(background), "precondition: the probe branch needs it loaded")

        await sut.openWorkFolder(tempDir)   // same instance, same folder → loadedTasks preserved

        XCTAssertEqual(diskIndexStatus(background), .needsSupervisorAcceptance)
        assertResolvedItsOwnTeamGate(background)
    }

    /// Variant 2: the quit landed after `completeStepNeedsAcceptance` (step
    /// `.needsApproval`) but before the role flip. Recovery does not rewrite the step, so
    /// the ROLE has to be what surfaces the acceptance card.
    func testNeedsApprovalStepRestart_yieldsAcceptanceCard() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "M4", supervisorTask: "breathing",
                                          preferredTeamID: startupTeamID())!
        await plantRun(taskID: taskID, stepStatus: .needsApproval, roleStatus: .working)

        await restartOrchestrator()

        let run = sut.loadedTask(taskID)?.runs.last
        XCTAssertEqual(run?.roleStatuses["r"], .needsAcceptance)
        XCTAssertFalse(run?.rolesNeedingAcceptance(definitions: []).isEmpty ?? true,
                       "the activity feed's Accept card must have something to render")
    }

    // MARK: - Non-regression: genuinely interrupted work still parks and resumes

    /// The legitimate demotion must survive: a step that was really mid-flight parks to
    /// `.paused` with an `.idle` role, which is exactly the shape `resumeRun`'s recovery
    /// branch (mirrored by `AutovisorStatus.isResumable`) restarts.
    func testInFlightRunRestart_stillDemotesAndStaysResumable() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "M4", supervisorTask: "breathing",
                                          preferredTeamID: startupTeamID())!
        await plantRun(
            taskID: taskID, stepStatus: .running, roleStatus: .working,
            stepMessages: [StepMessage(role: .assistant, content: "partial work")]
        )

        await restartOrchestrator()

        guard let task = sut.loadedTask(taskID), let run = task.runs.last, let step = run.steps.first else {
            return XCTFail("task not loaded after restart")
        }
        XCTAssertEqual(step.status, .paused)
        XCTAssertEqual(run.roleStatuses["r"], .idle)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
        XCTAssertEqual(task.status, .paused, "a real park DOES arm the latch")
        XCTAssertEqual(sut.taskEngineStates[taskID], .paused)
        XCTAssertEqual(
            TeamBoardRunControl.select(engineState: sut.taskEngineStates[taskID], isHistoricalRun: false),
            .resume,
            "interrupted work must still offer resume"
        )
        XCTAssertTrue(
            AutovisorStatus.isResumable(step: step, roleStatus: run.roleStatuses["r"], taskIsClosed: false),
            "resumeRun's recovery branch (and the Autovisor mirror of it) must still match"
        )
    }

    // MARK: - The recovery pause latch

    /// The latch is durable, so without an explicit clear every LATER run of the task
    /// renders "Paused" at any moment when no step happens to be `.running`.
    func testResumeRunClearsLatch() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "M4", supervisorTask: "breathing",
                                          preferredTeamID: startupTeamID())!
        await plantRun(
            taskID: taskID, stepStatus: .running, roleStatus: .working,
            stepMessages: [StepMessage(role: .assistant, content: "partial")]
        )
        await restartOrchestrator()
        XCTAssertEqual(sut.loadedTask(taskID)?.status, .paused, "precondition: latch armed")

        await sut.resumeRun(taskID: taskID)

        XCTAssertNotEqual(sut.loadedTask(taskID)?.status, .paused)
    }

    func testCreateNewRunClearsLatch() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "M4", supervisorTask: "breathing",
                                          preferredTeamID: startupTeamID())!
        await plantRun(taskID: taskID, stepStatus: .running, roleStatus: .working)
        await restartOrchestrator()
        XCTAssertEqual(sut.loadedTask(taskID)?.status, .paused, "precondition: latch armed")

        await sut.createNewRun(taskID: taskID)

        XCTAssertNotEqual(sut.loadedTask(taskID)?.status, .paused)
    }

    func testRestartRoleClearsLatch() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "M4", supervisorTask: "breathing",
                                          preferredTeamID: startupTeamID())!
        await plantRun(taskID: taskID, stepStatus: .done, roleStatus: .working)
        await restartOrchestrator()
        // Settling does not arm the latch, so arm it explicitly for this pin.
        await sut.mutateTask(taskID: taskID) { $0.status = .paused }

        await sut.restartRole(taskID: taskID, roleID: "r", comment: nil)

        XCTAssertNotEqual(sut.loadedTask(taskID)?.status, .paused)
    }
}
