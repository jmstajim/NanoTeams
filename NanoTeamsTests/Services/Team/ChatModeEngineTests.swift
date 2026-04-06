import XCTest
@testable import NanoTeams

/// Tests for chat mode behavior in TeamEngine (run loop, acceptance suppression, allRolesComplete).
@MainActor
final class ChatModeEngineTests: XCTestCase {

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

    // MARK: - Helpers

    private func makeSupervisorRole(requiredArtifacts: [String] = []) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "supervisor-role",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requiredArtifacts,
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
    }

    private func makeWorkerRole(
        id: String,
        name: String,
        requiredArtifacts: [String] = ["Supervisor Task"],
        producesArtifacts: [String] = []
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "",
            toolIDs: ["read_file"],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requiredArtifacts,
                producesArtifacts: producesArtifacts
            )
        )
    }

    private func makeTeam(roles: [TeamRoleDefinition]) -> Team {
        Team(name: "Test", roles: roles, artifacts: [], settings: .default, graphLayout: TeamGraphLayout())
    }

    // MARK: - allRolesComplete

    func testAllRolesComplete_chatMode_alwaysFalse() {
        let roles = [
            makeSupervisorRole(),
            makeWorkerRole(id: "eng", name: "Engineer"),
        ]
        let statuses: [String: RoleExecutionStatus] = ["eng": .done]

        let result = sut.allRolesComplete(roleStatuses: statuses, roles: roles, isChatMode: true)
        XCTAssertFalse(result, "Chat mode teams should never auto-complete")
    }

    func testAllRolesComplete_nonChatMode_trueWhenAllDone() {
        let roles = [
            makeSupervisorRole(requiredArtifacts: ["Output"]),
            makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Output"]),
        ]
        let statuses: [String: RoleExecutionStatus] = ["eng": .done]

        let result = sut.allRolesComplete(roleStatuses: statuses, roles: roles, isChatMode: false)
        XCTAssertTrue(result)
    }

    func testAllRolesComplete_chatMode_falseEvenWhenAllRolesDone() {
        let roles = [
            makeSupervisorRole(),
            makeWorkerRole(id: "a", name: "A"),
            makeWorkerRole(id: "b", name: "B"),
        ]
        let statuses: [String: RoleExecutionStatus] = ["a": .done, "b": .done]

        let result = sut.allRolesComplete(roleStatuses: statuses, roles: roles, isChatMode: true)
        XCTAssertFalse(result, "Even with all roles done, chat mode prevents auto-completion")
    }

    // MARK: - Engine run loop with chat mode team

    func testChatModeTeam_engineDoesNotTransitionToDone() {
        let supervisorRole = makeSupervisorRole(requiredArtifacts: []) // isChatMode = true
        let workerRole = makeWorkerRole(id: "assistant", name: "Assistant")
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let stepID = "assistant"
        let step = StepExecution(
            id: stepID, role: .custom(id: "assistant"),
            title: "Chat", status: .done
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["assistant": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Chat", supervisorTask: "Help", runs: [run], isChatMode: true)
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults[stepID] = .done

        // Engine should NOT reach .done in chat mode — it should keep looping
        let doneExpectation = XCTestExpectation(description: "Engine should not reach done")
        doneExpectation.isInverted = true // We expect this to NOT be fulfilled
        sut.onStateChanged = { state in
            if state == .done { doneExpectation.fulfill() }
        }

        sut.start()
        wait(for: [doneExpectation], timeout: 1.0)

        XCTAssertNotEqual(sut.state, .done, "Chat mode engine should not reach .done")
    }

    func testChatModeTeam_skipsAcceptanceTransition() {
        let supervisorRole = makeSupervisorRole(requiredArtifacts: [])
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer")
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let stepID = "eng"
        let step = StepExecution(
            id: stepID, role: .softwareEngineer,
            title: "Work", status: .needsApproval
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["eng": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Task", supervisorTask: "Build", runs: [run], isChatMode: true)
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults[stepID] = .needsApproval

        // In chat mode, engine should NOT transition to .needsAcceptance
        let acceptExpectation = XCTestExpectation(description: "Should not reach needsAcceptance")
        acceptExpectation.isInverted = true
        sut.onStateChanged = { state in
            if state == .needsAcceptance { acceptExpectation.fulfill() }
        }

        sut.start()
        wait(for: [acceptExpectation], timeout: 1.0)

        XCTAssertNotEqual(sut.state, .needsAcceptance)
    }

    // MARK: - Non-chat team acceptance works normally

    func testNonChatTeam_acceptanceTransitionWorks() {
        let supervisorRole = makeSupervisorRole(requiredArtifacts: ["Code"])
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team
        mockStore.teamSettings = .default

        let stepID = "eng"
        let step = StepExecution(
            id: stepID, role: .softwareEngineer,
            title: "Eng", status: .done, artifacts: [Artifact(name: "Code")]
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["eng": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Task", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Code"]
        mockStore.stepStatusResults[stepID] = .done

        let expectation = XCTestExpectation(description: "Engine reaches done or needsAcceptance")
        sut.onStateChanged = { state in
            if state == .done || state == .needsAcceptance {
                expectation.fulfill()
            }
        }

        sut.start()
        wait(for: [expectation], timeout: 2.0)

        // Non-chat team should complete normally
        let finalState = sut.state
        XCTAssertTrue(finalState == .done || finalState == .needsAcceptance,
                      "Non-chat team should reach done or needsAcceptance, got \(finalState)")
    }
}
