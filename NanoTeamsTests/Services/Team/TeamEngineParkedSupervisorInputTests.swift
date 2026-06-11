import XCTest
@testable import NanoTeams

/// Pins the mode-independent engine rule: a step parked at
/// `.needsSupervisorInput` pauses the engine in AUTONOMOUS mode too, not just
/// manual (manual is covered by `TeamEngineTests`). A parked status is only
/// ever written at stop time (`setNeedsSupervisorInput`) or by `resumeRun`'s
/// restore branch — the in-loop auto-answer keeps the step `.running` — so
/// there is no in-flight answer to wait for. Pre-fix, the manual-only gate left
/// autonomous tasks (Autovisor-suppressed questions, StepFlowControl escalation
/// parks, delegated children) busy-burning the iteration limit with the engine
/// stuck `.running`: the Autovisor's needs-supervisor wake trigger (live engine
/// state) never fired, and `answerSupervisorQuestion` couldn't resume the step
/// (`notifyExternalEvent` is a no-op for `.running`).
@MainActor
final class TeamEngineParkedSupervisorInputTests: XCTestCase {

    var sut: TeamEngine!
    var mockStore: MockTeamEngineStore!

    override func setUp() {
        super.setUp()
        mockStore = MockTeamEngineStore()
        sut = TeamEngine(store: mockStore)
    }

    override func tearDown() {
        sut.stop()
        sut = nil
        mockStore = nil
        super.tearDown()
    }

    // MARK: - Helpers (file-private by convention — see TeamEngineTests)

    private func makeSupervisorRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "supervisor-role",
            name: "Supervisor",
            prompt: "You are the Supervisor.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Final Deliverable"],
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
    }

    private func makeWorkerRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "eng",
            name: "Engineer",
            prompt: "You are Engineer.",
            toolIDs: ["read_file"],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: ["Code"]
            )
        )
    }

    /// Autonomous-mode team with one worker whose step is parked at
    /// `.needsSupervisorInput` — the shape both auto-answer suppression and the
    /// StepFlowControl escalation caps leave behind.
    private func seedAutonomousTeamWithParkedStep() {
        var settings = TeamSettings.default
        settings.supervisorMode = .autonomous
        let team = Team(
            name: "Test Team",
            roles: [makeSupervisorRole(), makeWorkerRole()],
            artifacts: [],
            settings: settings,
            graphLayout: TeamGraphLayout()
        )
        mockStore.activeTeam = team

        let stepID = "eng"  // StepExecution.id IS the roleID (effectiveRoleID == id)
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Engineering",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Reset git history or continue without committing?"
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["eng": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults[stepID] = .needsSupervisorInput
    }

    func testAutonomousTeam_parkedStep_transitionsToNeedsSupervisorInput() async {
        seedAutonomousTeamWithParkedStep()

        let expectation = XCTestExpectation(description: "Engine reaches needsSupervisorInput")
        sut.onStateChanged = { state in
            if state == .needsSupervisorInput {
                expectation.fulfill()
            }
        }
        sut.start()

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsSupervisorInput)
    }

    func testAutonomousTeam_runningStep_staysRunning() async {
        // Control: a `.running` (not parked) step must NOT pause the engine —
        // this is the state the step holds for the whole duration of an
        // autonomous in-loop auto-answer.
        seedAutonomousTeamWithParkedStep()
        mockStore.activeTask?.runs[0].steps[0].status = .running
        mockStore.stepStatusResults["eng"] = .running

        var reachedSupervisorInput = false
        sut.onStateChanged = { state in
            if state == .needsSupervisorInput {
                reachedSupervisorInput = true
            }
        }
        sut.start()

        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(reachedSupervisorInput)
        XCTAssertEqual(sut.state, .running)
    }

    // MARK: - Corners

    func testChatModeAutonomousTeam_parkedStep_transitions() async {
        // Chat-mode (Supervisor requires no artifacts) + autonomous is the
        // Autovisor-manager / Personal Assistant shape. Chat mode skips the
        // acceptance check but must NOT skip the parked-step pause — a chat
        // task whose question is routed to the Autovisor parks the same way.
        var settings = TeamSettings.default
        settings.supervisorMode = .autonomous
        let supervisor = TeamRoleDefinition(
            id: "supervisor-role",
            name: "Supervisor",
            prompt: "You are the Supervisor.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Supervisor Task"]),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
        let advisory = TeamRoleDefinition(
            id: "assistant",
            name: "Assistant",
            prompt: "You are Assistant.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"], producesArtifacts: [])
        )
        let team = Team(
            name: "Chat Team",
            roles: [supervisor, advisory],
            artifacts: [],
            settings: settings,
            graphLayout: TeamGraphLayout()
        )
        XCTAssertTrue(team.isChatMode, "Seeding sanity: empty supervisorRequires must mean chat mode")
        mockStore.activeTeam = team

        let step = StepExecution(
            id: "assistant",
            role: .custom(id: "assistant"),
            title: "Assistant",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Which directory?"
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["assistant": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Chat", supervisorTask: "Talk", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults["assistant"] = .needsSupervisorInput

        let expectation = XCTestExpectation(description: "Chat-mode engine reaches needsSupervisorInput")
        sut.onStateChanged = { state in
            if state == .needsSupervisorInput { expectation.fulfill() }
        }
        sut.start()

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsSupervisorInput)
    }

    func testParkedStep_withFailedRole_failedWins() async {
        // Priority pin: the run loop checks failed roles BEFORE parked steps.
        // A failed sibling must surface as `.failed` even while a question is
        // parked — failing loudly beats waiting on an answer that can't save
        // the run.
        seedAutonomousTeamWithParkedStep()
        mockStore.activeTask?.runs[0].roleStatuses["other"] = .failed

        let expectation = XCTestExpectation(description: "Engine fails")
        sut.onStateChanged = { state in
            if state == .failed { expectation.fulfill() }
        }
        sut.start()

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .failed)
    }

    func testParkedStep_withPendingAcceptance_nonChat_acceptanceWins() async {
        // Priority pin: in non-chat teams the acceptance check runs BEFORE the
        // parked-step check, so a role awaiting acceptance holds the engine in
        // `.needsAcceptance` even while another role's question is parked.
        seedAutonomousTeamWithParkedStep()
        mockStore.activeTask?.runs[0].roleStatuses["other"] = .needsAcceptance

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }
        sut.start()

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsAcceptance)
    }

    func testParkedStep_answeredThenResume_restartsStepAndKeepsRunning() async {
        // The full park → answer → resume corner at engine level: an answered
        // step (`.pending`, role `.working`) must be restarted by
        // `reconcileAfterPause` on resume, and with no parked steps left the
        // engine keeps running. This is the path `answerSupervisorQuestion`
        // relies on after the engine paused at `.needsSupervisorInput`.
        seedAutonomousTeamWithParkedStep()

        let parked = XCTestExpectation(description: "Engine parks")
        sut.onStateChanged = { state in
            if state == .needsSupervisorInput { parked.fulfill() }
        }
        sut.start()
        await fulfillment(of: [parked], timeout: 2.0)

        // Answer lands: StepMessagingService sets status .pending and clears the flag.
        mockStore.activeTask?.runs[0].steps[0].status = .pending
        mockStore.activeTask?.runs[0].steps[0].needsSupervisorInput = false
        mockStore.stepStatusResults["eng"] = .pending

        sut.resume()

        // reconcileAfterPause spawns the restart asynchronously — poll briefly.
        for _ in 0..<20 where mockStore.runStepCalls.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(mockStore.runStepCalls, ["eng"], "Answered step must be re-run on resume")
        XCTAssertEqual(sut.state, .running)
    }

    func testTwoParkedSteps_answerOne_restartsItAndReparksForTheOther() async {
        // Parallel ask_supervisor corner (CLAUDE.md #45 — ready roles run in
        // parallel): with TWO parked questions, answering one must restart that
        // step AND re-park the engine for the remaining question — the answered
        // role must not be starved just because a sibling is still waiting.
        var settings = TeamSettings.default
        settings.supervisorMode = .autonomous
        let team = Team(
            name: "Test Team",
            roles: [makeSupervisorRole(), makeWorkerRole()],
            artifacts: [],
            settings: settings,
            graphLayout: TeamGraphLayout()
        )
        mockStore.activeTeam = team

        let step1 = StepExecution(
            id: "s1", role: .softwareEngineer, title: "One",
            status: .needsSupervisorInput, needsSupervisorInput: true, supervisorQuestion: "Q1"
        )
        let step2 = StepExecution(
            id: "s2", role: .softwareEngineer, title: "Two",
            status: .needsSupervisorInput, needsSupervisorInput: true, supervisorQuestion: "Q2"
        )
        let run = Run(id: 0, steps: [step1, step2], roleStatuses: ["s1": .working, "s2": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults["s1"] = .needsSupervisorInput
        mockStore.stepStatusResults["s2"] = .needsSupervisorInput

        let parked = XCTestExpectation(description: "Engine parks for the two questions")
        sut.onStateChanged = { state in
            if state == .needsSupervisorInput { parked.fulfill() }
        }
        sut.start()
        await fulfillment(of: [parked], timeout: 2.0)

        // Answer s1 only.
        mockStore.activeTask?.runs[0].steps[0].status = .pending
        mockStore.activeTask?.runs[0].steps[0].needsSupervisorInput = false
        mockStore.stepStatusResults["s1"] = .pending

        let reparked = XCTestExpectation(description: "Engine re-parks for the remaining question")
        sut.onStateChanged = { state in
            if state == .needsSupervisorInput { reparked.fulfill() }
        }
        sut.resume()

        await fulfillment(of: [reparked], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsSupervisorInput)
        // The answered step was restarted despite the sibling's open question.
        XCTAssertTrue(mockStore.runStepCalls.contains("s1"), "Answered step must restart")
        XCTAssertFalse(mockStore.runStepCalls.contains("s2"), "Unanswered parked step must NOT restart")
    }
}
