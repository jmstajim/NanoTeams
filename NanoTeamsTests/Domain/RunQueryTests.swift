import XCTest
@testable import NanoTeams

final class RunQueryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStep(
        role: Role = .softwareEngineer,
        teamRoleID: String? = nil,
        status: StepStatus = .done,
        artifacts: [Artifact] = []
    ) -> StepExecution {
        StepExecution(
            id: teamRoleID ?? role.baseID,
            role: role,
            title: "\(role.displayName) step",
            status: status,
            artifacts: artifacts
        )
    }

    private func makeRoleDef(
        id: String,
        name: String,
        required: [String] = [],
        produces: [String] = [],
        systemRoleID: String? = nil
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: required,
                producesArtifacts: produces
            ),
            systemRoleID: systemRoleID
        )
    }

    // MARK: - stepsByRoleBaseID

    func testStepsByRoleBaseID_buildsDict() {
        let step1 = makeStep(role: .productManager, teamRoleID: "pm-id")
        let step2 = makeStep(role: .softwareEngineer, teamRoleID: "swe-id")
        let run = Run(id: 0, steps: [step1, step2])

        let dict = run.stepsByRoleBaseID()

        XCTAssertEqual(dict.count, 2)
        XCTAssertEqual(dict["pm-id"]?.role, .productManager)
        XCTAssertEqual(dict["swe-id"]?.role, .softwareEngineer)
    }

    func testStepsByRoleBaseID_emptySteps() {
        let run = Run(id: 0, steps: [])
        XCTAssertTrue(run.stepsByRoleBaseID().isEmpty)
    }

    func testStepsByRoleBaseID_fallsBackToRoleBaseID() {
        // When teamRoleID is nil, effectiveRoleID uses role.baseID
        let step = makeStep(role: .techLead, teamRoleID: nil)
        let run = Run(id: 0, steps: [step])

        let dict = run.stepsByRoleBaseID()
        XCTAssertNotNil(dict[Role.techLead.baseID])
    }

    // MARK: - producedArtifactsByName

    func testProducedArtifactsByName_collectsArtifacts() {
        let artifact = Artifact(name: "Product Requirements")
        let step = makeStep(role: .productManager, teamRoleID: "pm", artifacts: [artifact])
        let run = Run(id: 0, steps: [step])

        let result = run.producedArtifactsByName()

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["Product Requirements"]?.artifact.name, "Product Requirements")
        XCTAssertEqual(result["Product Requirements"]?.roleID, "pm")
    }

    func testProducedArtifactsByName_latestUpdatedAtWins() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)

        let oldArtifact = Artifact(name: "Report", updatedAt: earlier)
        let newArtifact = Artifact(name: "Report", updatedAt: later)

        let step1 = makeStep(role: .productManager, teamRoleID: "pm", artifacts: [oldArtifact])
        let step2 = makeStep(role: .techLead, teamRoleID: "tl", artifacts: [newArtifact])
        let run = Run(id: 0, steps: [step1, step2])

        let result = run.producedArtifactsByName()

        XCTAssertEqual(result["Report"]?.roleID, "tl")
        XCTAssertEqual(result["Report"]?.artifact.updatedAt, later)
    }

    func testProducedArtifactsByName_emptySteps() {
        let run = Run(id: 0, steps: [])
        XCTAssertTrue(run.producedArtifactsByName().isEmpty)
    }

    func testProducedArtifactsByName_multipleArtifactsFromOneStep() {
        let a1 = Artifact(name: "Plan")
        let a2 = Artifact(name: "Spec")
        let step = makeStep(role: .techLead, teamRoleID: "tl", artifacts: [a1, a2])
        let run = Run(id: 0, steps: [step])

        let result = run.producedArtifactsByName()

        XCTAssertEqual(result.count, 2)
        XCTAssertNotNil(result["Plan"])
        XCTAssertNotNil(result["Spec"])
    }

    // MARK: - finishableAdvisoryRoles

    func testFinishableAdvisoryRoles_workingAdvisory_returned() {
        let defs = [
            makeRoleDef(id: "cr", name: "Code Reviewer", required: ["Plan"], produces: [])
        ]
        let run = Run(
            id: 0,
            steps: [],
            roleStatuses: ["cr": .working]
        )

        let result = run.finishableAdvisoryRoles(definitions: defs)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].roleID, "cr")
        XCTAssertEqual(result[0].roleName, "Code Reviewer")
    }

    func testFinishableAdvisoryRoles_readyAdvisory_returned() {
        let defs = [
            makeRoleDef(id: "cr", name: "Code Reviewer", required: ["Plan"], produces: [])
        ]
        let run = Run(
            id: 0,
            steps: [],
            roleStatuses: ["cr": .ready]
        )

        let result = run.finishableAdvisoryRoles(definitions: defs)
        XCTAssertEqual(result.count, 1)
    }

    func testFinishableAdvisoryRoles_doneAdvisory_notReturned() {
        let defs = [
            makeRoleDef(id: "cr", name: "Code Reviewer", required: ["Plan"], produces: [])
        ]
        let run = Run(
            id: 0,
            steps: [],
            roleStatuses: ["cr": .done]
        )

        let result = run.finishableAdvisoryRoles(definitions: defs)
        XCTAssertTrue(result.isEmpty)
    }

    func testFinishableAdvisoryRoles_producingRole_notReturned() {
        let defs = [
            makeRoleDef(id: "pm", name: "PM", required: ["Goal"], produces: ["Requirements"])
        ]
        let run = Run(
            id: 0,
            steps: [],
            roleStatuses: ["pm": .working]
        )

        let result = run.finishableAdvisoryRoles(definitions: defs)
        XCTAssertTrue(result.isEmpty)
    }

    func testFinishableAdvisoryRoles_sortedByName() {
        let defs = [
            makeRoleDef(id: "z-role", name: "Zeta Reviewer", required: ["X"], produces: []),
            makeRoleDef(id: "a-role", name: "Alpha Reviewer", required: ["X"], produces: []),
        ]
        let run = Run(
            id: 0,
            steps: [],
            roleStatuses: ["z-role": .working, "a-role": .working]
        )

        let result = run.finishableAdvisoryRoles(definitions: defs)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].roleName, "Alpha Reviewer")
        XCTAssertEqual(result[1].roleName, "Zeta Reviewer")
    }

    // MARK: - rolesNeedingAcceptance

    func testRolesNeedingAcceptance_needsAcceptance_returned() {
        let defs = [
            makeRoleDef(id: "pm", name: "PM", produces: ["Requirements"])
        ]
        let run = Run(
            id: 0,
            steps: [],
            roleStatuses: ["pm": .needsAcceptance]
        )

        let result = run.rolesNeedingAcceptance(definitions: defs)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].roleID, "pm")
        XCTAssertEqual(result[0].roleName, "PM")
    }

    func testRolesNeedingAcceptance_working_notReturned() {
        let defs = [
            makeRoleDef(id: "pm", name: "PM", produces: ["Requirements"])
        ]
        let run = Run(
            id: 0,
            steps: [],
            roleStatuses: ["pm": .working]
        )

        let result = run.rolesNeedingAcceptance(definitions: defs)
        XCTAssertTrue(result.isEmpty)
    }

    func testRolesNeedingAcceptance_sortedByName() {
        let defs = [
            makeRoleDef(id: "z-id", name: "Zeta"),
            makeRoleDef(id: "a-id", name: "Alpha"),
        ]
        let run = Run(
            id: 0,
            steps: [],
            roleStatuses: ["z-id": .needsAcceptance, "a-id": .needsAcceptance]
        )

        let result = run.rolesNeedingAcceptance(definitions: defs)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].roleName, "Alpha")
        XCTAssertEqual(result[1].roleName, "Zeta")
    }

    func testRolesNeedingAcceptance_emptyStatuses() {
        let defs = [makeRoleDef(id: "pm", name: "PM")]
        let run = Run(id: 0, steps: [], roleStatuses: [:])

        let result = run.rolesNeedingAcceptance(definitions: defs)
        XCTAssertTrue(result.isEmpty)
    }
}
