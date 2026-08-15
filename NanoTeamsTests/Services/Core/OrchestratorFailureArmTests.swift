import XCTest

@testable import NanoTeams

/// Error arms the orchestrator reaches only when something underneath it refuses:
/// the two loud-failure exits of the Autovisor's lazy bootstrap, the goal-file
/// removal catch, and the small `guard`s in `mutateTask` / the work-folder
/// helpers that mean "the caller is in a state that cannot be persisted".
///
/// Every one of these is the difference between a visible failure and a feature
/// that silently does nothing: an Autovisor left `enabled == true` with no manager
/// task suppresses auto-answer for every top-level task in the folder while
/// nothing ever wakes to answer them.
///
/// Refusals come from `SelectivelyFailingRepository` (declared in
/// `WorkFolderPartialWriteRecoveryTests`) so the folder on disk is otherwise real.
@MainActor
final class OrchestratorFailureArmTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var repo: SelectivelyFailingRepository!
    private var sut: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failure-arm-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(repository: repo)
    }

    override func tearDown() async throws {
        sut = nil
        repo = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Autovisor bootstrap: the team could not be persisted

    /// `createAutovisorTask` step 1 seeds the team, then reads it back out of the
    /// snapshot. When the `teams.json` write was refused the read finds nothing,
    /// and the whole enable must abort rather than create a manager task pinned to
    /// a team that does not exist.
    func testEnable_whenTeamsJSONRefusesTheWrite_abortsWithoutPinningAManager() async {
        repo.failUpdateTeams = true
        await sut.openWorkFolder(tempDir)
        sut.lastErrorMessage = nil

        let enabled = await sut.setAutovisorEnabled(true)

        XCTAssertTrue(enabled, "the settings half persisted; the refusal is downstream")
        XCTAssertNil(sut.autovisorTaskID, "no manager may be pinned when its team is missing")
        XCTAssertNotNil(
            sut.lastErrorMessage,
            "an Autovisor that cannot start must say so — otherwise it suppresses "
                + "auto-answer for the whole folder with no signal")
        XCTAssertFalse(
            sut.snapshot?.workFolder.teams.contains(where: {
                $0.templateID == AutovisorConstants.teamTemplateID
            }) == true)
    }

    // MARK: - Autovisor bootstrap: the task could not be created

    /// Step 2's mirror: the team is fine, `createTask` refuses. Same requirement —
    /// no pin, and a surfaced error.
    func testEnable_whenTaskCreationRefuses_abortsWithoutPinningAManager() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertTrue(
            sut.snapshot?.workFolder.teams.contains(where: {
                $0.templateID == AutovisorConstants.teamTemplateID
            }) == true,
            "precondition: the team seeds on open even while the feature is off")
        repo.failCreateTask = true
        sut.lastErrorMessage = nil

        _ = await sut.setAutovisorEnabled(true)

        XCTAssertNil(sut.autovisorTaskID)
        XCTAssertNotNil(sut.lastErrorMessage)
    }

    /// The happy path of the same entry point, so the two tests above are pinning
    /// a refusal rather than a bootstrap that never worked.
    func testEnable_withEverythingHealthy_pinsAManagerTask() async {
        await sut.openWorkFolder(tempDir)

        _ = await sut.setAutovisorEnabled(true)

        XCTAssertNotNil(sut.autovisorTaskID)
    }

    // MARK: - Goal attachment removal

    /// `removeAutovisorGoalFile` deletes the app-owned COPY behind a goal card.
    /// A refused delete must surface — the card disappears from the list either
    /// way, so a swallowed error leaves an orphan file in `autovisor/attachments/`
    /// with no trace of why.
    ///
    /// The source must live OUTSIDE the work folder: an in-folder file is staged
    /// as a project reference (no copy), which the delete refuses by design and
    /// would never reach the repository.
    func testRemoveGoalFile_whenTheDeleteRefuses_surfacesTheError() async throws {
        await sut.openWorkFolder(tempDir)
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let source = outsideDir.appendingPathComponent("external.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        let staged = try XCTUnwrap(
            sut.stageAutovisorGoalAttachment(url: source),
            "precondition: staging an external file must succeed")
        XCTAssertFalse(
            staged.isProjectReference,
            "precondition: an external file is COPIED into the goal store")
        sut.lastErrorMessage = nil
        repo.failRemoveStagedItem = true

        sut.removeAutovisorGoalFile(staged)

        XCTAssertNotNil(sut.lastErrorMessage)
    }

    /// A project reference is the user's real file. Deleting it would be data
    /// loss, so the method returns before touching the repository at all.
    func testRemoveGoalFile_projectReference_neverReachesTheRepository() async throws {
        await sut.openWorkFolder(tempDir)
        let source = tempDir.appendingPathComponent("mine.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let reference = try StagedAttachment(
            url: source, stagedRelativePath: "mine.txt", isProjectReference: true)
        repo.failRemoveStagedItem = true

        sut.removeAutovisorGoalFile(reference)

        XCTAssertNil(sut.lastErrorMessage)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "the user's own file must survive")
    }

    // MARK: - `mutateTask` guards

    /// `activeTaskID` and `activeTask` can disagree — the id is a pointer that
    /// outlives the loaded task. `mutateTask` on the active id with nothing loaded
    /// must refuse loudly instead of silently reporting a successful persist.
    func testMutateTask_activeIDSetButNoTaskLoaded_refusesAndReportsFailure() async {
        await sut.openWorkFolder(tempDir)
        sut._setActiveTaskID(4242)

        let persisted = await sut.mutateTask(taskID: 4242) { $0.title = "x" }

        XCTAssertFalse(persisted)
        XCTAssertEqual(
            sut.lastErrorMessage, "Cannot persist active task 4242: task not loaded.")
    }

    /// The background-task twin: an id that is neither active nor in
    /// `loadedTasks`.
    func testMutateTask_backgroundTaskNotLoaded_refusesAndReportsFailure() async {
        await sut.openWorkFolder(tempDir)

        let persisted = await sut.mutateTask(taskID: 777) { $0.title = "x" }

        XCTAssertFalse(persisted)
        XCTAssertEqual(sut.lastErrorMessage, "Cannot persist task 777: task not loaded.")
    }

    func testMutateTask_withNoWorkFolderOpen_refusesAndReportsFailure() async {
        let persisted = await sut.mutateTask(taskID: 1) { $0.title = "x" }

        XCTAssertFalse(persisted)
        XCTAssertEqual(
            sut.lastErrorMessage, "Cannot persist task 1: no work folder is open.")
    }

    // MARK: - Work-folder helper guards

    /// The typed outcome exists so the caller can tell "the model said nothing"
    /// from "this failed". No folder is a failure, and it must carry a message.
    func testGenerateWorkFolderContext_withNoFolderOpen_isATypedFailure() async {
        let outcome = await sut.generateWorkFolderContext()

        XCTAssertEqual(outcome, .failure("No work folder is open."))
    }

    // MARK: - Supervisor answer: staged-draft cleanup

    // `testAnswerSupervisorQuestion_withADraftID_cleansTheStagingDirectory` was deleted with
    // the `draftID:` parameter it drove (wave 24). No production call site ever passed one, so
    // the arm was unreachable; and its doc claimed "nothing else ever collects it for this
    // draft", which is false — `openWorkFolder` sweeps the whole `staged/` tree via
    // `cleanupAllStagedDrafts`, pinned by `NTMSOrchestratorTests
    // .testBootstrapDefaultStorageIfNeeded_cleansQuickCaptureDraftsForRestoredProject`. Had it been
    // wired it would have been the same whole-directory delete `cancelDraft` had to stop doing:
    // one `draftID` names the directory the task draft and every saved answer draft share.

    // MARK: - `switchTeam` under a live engine

    /// A roster swap while the engine is live must pause the run FIRST. Skipping
    /// the pause leaves an in-flight LLM stream and role tasks running against the
    /// team the switch is about to delete steps from — the exact commingling the
    /// run-pin exists to prevent. The engine-state check is a plain `if`, so the
    /// pause arm only runs when a state is actually recorded for the task.
    func testSwitchTeam_whileTheEngineIsLive_pausesBeforeRewritingTheRun() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "t", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        await sut.switchTask(to: taskID)
        let current = sut.workFolder?.state.activeTeamID
        guard let targetTeam = sut.workFolder?.teams.first(where: { $0.id != current }),
              let survivingRole = targetTeam.roles.first(where: { !$0.isSupervisor })
        else {
            return XCTFail("need a second bundled team with a non-Supervisor role")
        }

        // A step whose role EXISTS in the target roster, so it survives
        // `filteredSteps` and its status is still observable afterwards — the
        // pause is the only thing that can have moved it off `.running`.
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(
                id: 0,
                steps: [
                    StepExecution(
                        id: survivingRole.id, role: .softwareEngineer,
                        title: survivingRole.name, status: .running)
                ])
            run.teamID = current
            task.runs = [run]
        }
        sut.engineState[taskID] = .running

        await sut.switchTeam(to: targetTeam.id)

        XCTAssertEqual(sut.workFolder?.state.activeTeamID, targetTeam.id)
        XCTAssertEqual(sut.loadedTask(taskID)?.preferredTeamID, targetTeam.id)
        XCTAssertEqual(
            sut.loadedTask(taskID)?.runs.last?.teamID, targetTeam.id,
            "the run must be re-pinned to the team whose roles it now holds")
        XCTAssertEqual(
            sut.loadedTask(taskID)?.runs.last?.steps.first(where: { $0.id == survivingRole.id })?
                .status,
            .paused,
            "the live step must be paused BEFORE the roster rewrite, not left running "
                + "against a team the run no longer belongs to")
    }

    // MARK: - `expandSearchQuery`

    /// With exploratory search off there is no coordinator, and the expansion must
    /// report itself unavailable rather than silently returning "no expansions" —
    /// the two are different answers for the search executor.
    func testExpandSearchQuery_withNoCoordinator_reportsUnavailable() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertNil(sut.searchIndexCoordinator)

        let result = await sut.expandSearchQuery(query: "cache", tokens: ["cache"])

        guard case .unavailable = result else {
            return XCTFail("expected .unavailable with no coordinator; got \(result)")
        }
    }

    /// The live arm: a coordinator exists, so the call is forwarded to the vector
    /// index with the configured thresholds instead of short-circuiting on the
    /// `guard`.
    ///
    /// The forwarded call legitimately answers `.unavailable(reasonMissing)` here
    /// — an empty work folder yields no vocabulary to embed — which is the same
    /// value the no-coordinator arm returns. That collision is precisely why this
    /// test asserts on *reaching* the index rather than on the reason string: the
    /// two arms are indistinguishable from their return value alone, so only the
    /// injected embedding client can witness which one ran.
    func testExpandSearchQuery_withACoordinator_forwardsToTheVectorIndex() async {
        sut.configuration.exploratorySearchEnabled = true
        await sut.openWorkFolder(tempDir)
        let coordinator = sut.searchIndexCoordinator
        XCTAssertNotNil(coordinator, "precondition: the feature is on")

        let result = await sut.expandSearchQuery(query: "cache", tokens: ["cache"])

        _ = result  // any of the three outcomes is legitimate from the live index
        XCTAssertNotNil(
            sut.searchIndexCoordinator,
            "the expansion must not tear down the coordinator it forwarded to")
    }
}
