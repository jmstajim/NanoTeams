import XCTest
@testable import NanoTeams

@MainActor
final class ChangeRequestServiceExtendedTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRole(
        id: String, name: String,
        required: [String] = [], produces: [String] = [],
        systemRoleID: String? = nil
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, prompt: "", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: required, producesArtifacts: produces),
            systemRoleID: systemRoleID
        )
    }

    private func makeSupervisorRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "supervisor", name: "Supervisor", prompt: "", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Supervisor Task"]),
            isSystemRole: true, systemRoleID: "supervisor"
        )
    }

    private func makeTeam(roles: [TeamRoleDefinition]) -> Team {
        Team(name: "T", roles: roles, artifacts: [], settings: .default, graphLayout: .default)
    }

    // MARK: - buildVotingContext

    func testBuildVotingContext_topicContainsRoleNames() {
        let target = makeRole(id: "swe", name: "Software Engineer", produces: ["Code"])
        let result = ChangeRequestService.buildVotingContext(
            requestingRole: .codeReviewer,
            targetRoleDef: target,
            changes: "Refactor the module",
            reasoning: "Too complex"
        )

        XCTAssertTrue(result.topic.contains("Code Reviewer"),
                       "Topic should contain requesting role's display name")
        XCTAssertTrue(result.topic.contains("Software Engineer"),
                       "Topic should contain target role's name")
    }

    func testBuildVotingContext_contextContainsAllFields() {
        let target = makeRole(id: "swe", name: "SWE", produces: ["Code"])
        let result = ChangeRequestService.buildVotingContext(
            requestingRole: .codeReviewer,
            targetRoleDef: target,
            changes: "Fix error handling",
            reasoning: "Missing edge cases"
        )

        XCTAssertTrue(result.context.contains("Requested by:"))
        XCTAssertTrue(result.context.contains("Target:"))
        XCTAssertTrue(result.context.contains("Changes requested:"))
        XCTAssertTrue(result.context.contains("Reasoning:"))
        XCTAssertTrue(result.context.contains("Fix error handling"))
        XCTAssertTrue(result.context.contains("Missing edge cases"))
        XCTAssertTrue(result.context.contains("VOTE: APPROVE"))
        XCTAssertTrue(result.context.contains("VOTE: REJECT"))
    }

    func testBuildVotingContext_specialCharactersPreserved() {
        let target = makeRole(id: "swe", name: "SWE", produces: ["Code"])
        let changes = "Module refactoring 🔧\nNew line"
        let reasoning = "Reason: \"complexity\" > threshold"

        let result = ChangeRequestService.buildVotingContext(
            requestingRole: .codeReviewer,
            targetRoleDef: target,
            changes: changes,
            reasoning: reasoning
        )

        XCTAssertTrue(result.context.contains("refactoring"))
        XCTAssertTrue(result.context.contains("\"complexity\""))
    }

    // MARK: - validateChangeRequest edge cases

    func testValidateChangeRequest_nilTeam_returnsError() {
        let run = Run(id: 0)
        let result = ChangeRequestService.validateChangeRequest(
            targetRoleID: "swe",
            requestingRole: .codeReviewer,
            team: nil,
            teamSettings: .default,
            run: run
        )

        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("not found"))
        XCTAssertNil(result.targetRoleDef)
    }

    func testValidateChangeRequest_targetIsSupervisor_returnsError() {
        let supervisor = makeSupervisorRole()
        let team = makeTeam(roles: [supervisor])
        let run = Run(id: 0)

        let result = ChangeRequestService.validateChangeRequest(
            targetRoleID: "supervisor",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: .default,
            run: run
        )

        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("Supervisor"))
    }

    func testValidateChangeRequest_targetStepNotFound_returnsError() {
        let role = makeRole(id: "swe", name: "SWE", produces: ["Code"])
        let team = makeTeam(roles: [role])
        let run = Run(id: 0, steps: [])  // No steps at all

        let result = ChangeRequestService.validateChangeRequest(
            targetRoleID: "swe",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: .default,
            run: run
        )

        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("no step"))
    }

    func testValidateChangeRequest_exactlyAtLimit_returnsError() {
        let role = makeRole(id: "swe", name: "SWE", produces: ["Code"])
        let team = makeTeam(roles: [role])
        let step = StepExecution(id: "swe", role: .softwareEngineer, title: "Step", status: .done)

        // Create a run with existing change requests at the limit
        var settings = TeamSettings.default
        settings.limits.maxChangeRequestsPerRun = 2

        let cr1 = ChangeRequest(
            requestingRoleID: "cr", targetRoleID: "swe",
            changes: "a", reasoning: "b", status: .approved
        )
        let cr2 = ChangeRequest(
            requestingRoleID: "cr", targetRoleID: "swe",
            changes: "c", reasoning: "d", status: .approved
        )
        let run = Run(id: 0, steps: [step], changeRequests: [cr1, cr2])

        let result = ChangeRequestService.validateChangeRequest(
            targetRoleID: "swe",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: settings,
            run: run
        )

        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("limit"))
    }

    func testValidateChangeRequest_belowLimit_succeeds() {
        let role = makeRole(id: "swe", name: "SWE", produces: ["Code"])
        let team = makeTeam(roles: [role])
        let step = StepExecution(id: "swe", role: .softwareEngineer, title: "Step", status: .done)

        var settings = TeamSettings.default
        settings.limits.maxChangeRequestsPerRun = 3

        let cr = ChangeRequest(
            requestingRoleID: "cr", targetRoleID: "swe",
            changes: "a", reasoning: "b", status: .approved
        )
        let run = Run(id: 0, steps: [step], changeRequests: [cr])

        let result = ChangeRequestService.validateChangeRequest(
            targetRoleID: "swe",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: settings,
            run: run
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.targetRoleDef?.id, "swe")
    }
}
