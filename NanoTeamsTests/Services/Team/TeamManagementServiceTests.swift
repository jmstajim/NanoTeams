import XCTest
@testable import NanoTeams

final class TeamManagementServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - createTeam

    func testCreateTeam_returnsTeamWithCorrectName() {
        let team = TeamManagementService.createTeam(name: "Alpha Team")

        XCTAssertEqual(team.name, "Alpha Team")
    }

    func testCreateTeam_hasRolesFromDefault() {
        let team = TeamManagementService.createTeam(name: "Default Team")
        let defaultTeam = Team.default

        XCTAssertFalse(team.roles.isEmpty)
        XCTAssertEqual(team.roles.count, defaultTeam.roles.count)
    }

    // MARK: - duplicateTeam

    func testDuplicateTeam_hasNewID() {
        let original = TeamManagementService.createTeam(name: "Original")
        let duplicate = TeamManagementService.duplicateTeam(original)

        XCTAssertNotEqual(original.id, duplicate.id)
    }

    func testDuplicateTeam_defaultNameHasCopySuffix() {
        let original = TeamManagementService.createTeam(name: "My Team")
        let duplicate = TeamManagementService.duplicateTeam(original)

        XCTAssertEqual(duplicate.name, "My Team Copy")
    }

    func testDuplicateTeam_customName_usesIt() {
        let original = TeamManagementService.createTeam(name: "My Team")
        let duplicate = TeamManagementService.duplicateTeam(original, newName: "Renamed Team")

        XCTAssertEqual(duplicate.name, "Renamed Team")
    }

    // MARK: - canDeleteTeam

    func testCanDeleteTeam_singleTeam_returnsFalse() {
        let team = TeamManagementService.createTeam(name: "Only Team")
        let wf = WorkFolderProjection(state: WorkFolderState(name: "TestProject"), settings: .defaults, teams: [team])

        XCTAssertFalse(TeamManagementService.canDeleteTeam(in: wf, teamID: team.id))
    }

    func testCanDeleteTeam_multipleTeams_returnsTrue() {
        let team1 = TeamManagementService.createTeam(name: "Team A")
        let team2 = TeamManagementService.createTeam(name: "Team B")
        let wf = WorkFolderProjection(state: WorkFolderState(name: "TestProject"), settings: .defaults, teams: [team1, team2])

        XCTAssertTrue(TeamManagementService.canDeleteTeam(in: wf, teamID: team1.id))
    }

    func testCanDeleteTeam_nonExistentID_returnsFalse() {
        let team1 = TeamManagementService.createTeam(name: "Team A")
        let team2 = TeamManagementService.createTeam(name: "Team B")
        let wf = WorkFolderProjection(state: WorkFolderState(name: "TestProject"), settings: .defaults, teams: [team1, team2])

        XCTAssertFalse(TeamManagementService.canDeleteTeam(in: wf, teamID: "nonexistent_team"))
    }

    // MARK: - addRole

    func testAddRole_appendsToTeam() {
        var team = Team(name: "Empty Team")
        XCTAssertTrue(team.roles.isEmpty)

        let role = TeamRoleDefinition(
            id: "test_devops",
            name: "DevOps",
            prompt: "DevOps engineer",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        TeamManagementService.addRole(to: &team, role: role)

        XCTAssertEqual(team.roles.count, 1)
        XCTAssertEqual(team.roles.first?.name, "DevOps")
    }

    // MARK: - removeRole

    func testRemoveRole_removesFromTeam() {
        var team = Team(name: "Test Team")
        let role = TeamRoleDefinition(
            id: "test_qa",
            name: "QA",
            prompt: "QA tester",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        TeamManagementService.addRole(to: &team, role: role)
        XCTAssertEqual(team.roles.count, 1)

        TeamManagementService.removeRole(from: &team, roleID: role.id)

        XCTAssertTrue(team.roles.isEmpty)
    }

    // MARK: - role lookup

    func testRole_findsById() {
        var team = Team(name: "Test Team")
        let role = TeamRoleDefinition(
            id: "test_architect",
            name: "Architect",
            prompt: "Software architect",
            toolIDs: [],
            usePlanningPhase: true,
            dependencies: RoleDependencies()
        )
        TeamManagementService.addRole(to: &team, role: role)

        let found = TeamManagementService.role(in: team, roleID: role.id)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Architect")
    }

    func testRole_unknownID_returnsNil() {
        let team = Team(name: "Test Team")

        let found = TeamManagementService.role(in: team, roleID: "nonexistent-id")

        XCTAssertNil(found)
    }

    // MARK: - addArtifact

    func testAddArtifact_appendsToTeam() {
        var team = Team(name: "Test Team")
        XCTAssertTrue(team.artifacts.isEmpty)

        let artifact = TeamArtifact(
            id: "test_api_spec",
            name: "API Spec",
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "API specification"
        )
        TeamManagementService.addArtifact(to: &team, artifact: artifact)

        XCTAssertEqual(team.artifacts.count, 1)
        XCTAssertEqual(team.artifacts.first?.name, "API Spec")
    }

    // MARK: - removeArtifact

    func testRemoveArtifact_removesFromTeam() {
        var team = Team(name: "Test Team")
        let artifact = TeamArtifact(
            id: "test_design_doc",
            name: "Design Doc",
            icon: "paintbrush",
            mimeType: "text/markdown",
            description: "Design document"
        )
        TeamManagementService.addArtifact(to: &team, artifact: artifact)
        XCTAssertEqual(team.artifacts.count, 1)

        TeamManagementService.removeArtifact(from: &team, artifactID: artifact.id)

        XCTAssertTrue(team.artifacts.isEmpty)
    }

    // MARK: - artifact lookup

    func testArtifact_findsByName() {
        var team = Team(name: "Test Team")
        let artifact = TeamArtifact(
            id: "test_release_notes",
            name: "Release Notes",
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "Release notes document"
        )
        TeamManagementService.addArtifact(to: &team, artifact: artifact)

        let found = TeamManagementService.artifact(in: team, name: "Release Notes")

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Release Notes")
    }

    func testArtifact_unknownName_returnsNil() {
        let team = Team(name: "Test Team")

        let found = TeamManagementService.artifact(in: team, name: "Does Not Exist")

        XCTAssertNil(found)
    }

    // MARK: - validate

    func testValidate_emptyRoles_returnsNoRolesError() {
        let team = Team(name: "No Roles Team")

        let errors = TeamManagementService.validate(team)

        XCTAssertTrue(errors.contains(.noRoles))
    }

    func testValidate_emptyName_returnsEmptyNameError() {
        var team = Team(name: "")
        let role = TeamRoleDefinition(
            id: "test_engineer",
            name: "Engineer",
            prompt: "An engineer",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        TeamManagementService.addRole(to: &team, role: role)

        let errors = TeamManagementService.validate(team)

        XCTAssertTrue(errors.contains(.emptyName))
        XCTAssertFalse(errors.contains(.noRoles))
    }

    func testValidate_validTeam_returnsNoErrors() {
        var team = Team(name: "Valid Team")
        let role = TeamRoleDefinition(
            id: "test_pm",
            name: "PM",
            prompt: "Product manager",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        TeamManagementService.addRole(to: &team, role: role)

        let errors = TeamManagementService.validate(team)

        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: - hasDuplicateName

    func testHasDuplicateName_caseInsensitive_returnsTrue() {
        let team = TeamManagementService.createTeam(name: "Alpha Team")

        let result = TeamManagementService.hasDuplicateName("ALPHA TEAM", in: [team])

        XCTAssertTrue(result)
    }

    func testHasDuplicateName_differentName_returnsFalse() {
        let team = TeamManagementService.createTeam(name: "Alpha Team")

        let result = TeamManagementService.hasDuplicateName("Beta Team", in: [team])

        XCTAssertFalse(result)
    }

    func testHasDuplicateName_excludesSelf() {
        let team = TeamManagementService.createTeam(name: "Alpha Team")

        let result = TeamManagementService.hasDuplicateName(
            "Alpha Team",
            in: [team],
            excludingID: team.id
        )

        XCTAssertFalse(result)
    }

    // MARK: - resetGraphLayout

    func testResetGraphLayout_setsDefault() {
        var team = TeamManagementService.createTeam(name: "Graph Team")
        // Modify the layout to something non-default
        team.graphLayout.nodePositions = []
        team.graphLayout.transform = TeamGraphTransform(offsetX: 50, offsetY: 50, scale: 2.0)

        TeamManagementService.resetGraphLayout(&team)

        XCTAssertEqual(team.graphLayout.nodePositions.count, TeamGraphLayout.default.nodePositions.count)
        XCTAssertEqual(team.graphLayout.transform, TeamGraphTransform.identity)
    }

    // MARK: - updateNodePosition

    func testUpdateNodePosition_setsCorrectPosition() {
        var team = Team(name: "Graph Team")
        let role = TeamRoleDefinition(
            id: "test_engineer_graph",
            name: "Engineer",
            prompt: "An engineer",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        TeamManagementService.addRole(to: &team, role: role)

        TeamManagementService.updateNodePosition(&team, roleID: role.id, x: 200, y: 300)

        let position = team.graphLayout.position(for: role.id)
        XCTAssertNotNil(position)
        XCTAssertEqual(position?.x, 200)
        XCTAssertEqual(position?.y, 300)
    }

    // MARK: - updateGraphTransform

    func testUpdateGraphTransform_setsTransform() {
        var team = Team(name: "Transform Team")
        let newTransform = TeamGraphTransform(offsetX: 10, offsetY: 20, scale: 1.5)

        TeamManagementService.updateGraphTransform(&team, transform: newTransform)

        XCTAssertEqual(team.graphLayout.transform.offsetX, 10)
        XCTAssertEqual(team.graphLayout.transform.offsetY, 20)
        XCTAssertEqual(team.graphLayout.transform.scale, 1.5)
    }
}
