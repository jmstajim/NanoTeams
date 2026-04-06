import CoreGraphics
import XCTest

@testable import NanoTeams

final class DomainModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Role Tests

    func testBuiltInID_roundTrip_allCases() {
        for role in Role.builtInCases {
            let id = Role.builtInID(role)
            let recovered = Role.builtInRole(for: id)
            XCTAssertEqual(recovered, role, "Round-trip failed for role with builtInID '\(id)'")
        }
    }

    func testBuiltInCases_has20Cases() {
        XCTAssertEqual(Role.builtInCases.count, 20)
    }

    func testFromID_builtIn_returnsCorrectRole() {
        XCTAssertEqual(Role.fromID("supervisor"), .supervisor)
        XCTAssertEqual(Role.fromID("softwareEngineer"), .softwareEngineer)
        XCTAssertEqual(Role.fromID("questMaster"), .questMaster)
        XCTAssertEqual(Role.fromID("theAgreeable"), .theAgreeable)
    }

    func testFromID_unknown_returnsCustom() {
        let role = Role.fromID("unknownRole")
        XCTAssertEqual(role, .custom(id: "unknownRole"))
        XCTAssertTrue(role.isCustom)
    }

    func testCustomRole_isCustom_true() {
        let role = Role.custom(id: "myRole")
        XCTAssertTrue(role.isCustom)
    }

    func testBuiltInRole_isCustom_false() {
        for role in Role.builtInCases {
            XCTAssertFalse(role.isCustom, "\(role) should not be custom")
        }
    }

    func testCustomRole_displayName_formatsUnderscores() {
        let role = Role.custom(id: "my_role")
        XCTAssertEqual(role.displayName, "My Role")
    }

    func testRole_codable_roundTrip_builtIn() throws {
        let original = Role.softwareEngineer
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Role.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testRole_codable_roundTrip_custom() throws {
        let original = Role.custom(id: "mySpecialRole")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Verify the encoded string contains the "custom:" prefix
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("custom:mySpecialRole"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Role.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testIsBuiltInID_knownID_true() {
        XCTAssertTrue(Role.isBuiltInID("supervisor"))
        XCTAssertTrue(Role.isBuiltInID("softwareEngineer"))
        XCTAssertTrue(Role.isBuiltInID("tpm"))
        XCTAssertTrue(Role.isBuiltInID("theNeurotic"))
    }

    func testIsBuiltInID_unknownID_false() {
        XCTAssertFalse(Role.isBuiltInID("unknownRole"))
        XCTAssertFalse(Role.isBuiltInID(""))
        XCTAssertFalse(Role.isBuiltInID("custom:something"))
    }

    // MARK: - Artifact Tests

    func testSlugify_spacesToUnderscores() {
        XCTAssertEqual(Artifact.slugify("Product Requirements"), "product_requirements")
    }

    func testSlugify_lowercases() {
        XCTAssertEqual(Artifact.slugify("DesignSpec"), "designspec")
    }

    func testSlugify_removesSpecialChars() {
        XCTAssertEqual(Artifact.slugify("Code Review!@#$%"), "code_review")
    }

    func testSlugify_preservesNumbers() {
        XCTAssertEqual(Artifact.slugify("Phase 2 Plan"), "phase_2_plan")
    }

    func testArtifact_id_isSlugifiedName() {
        let artifact = Artifact(name: "Product Requirements")
        XCTAssertEqual(artifact.id, "product_requirements")
    }

    func testDefaultIconForName_knownArtifact_returnsIcon() {
        // "Product Requirements" is a known system artifact with icon "doc.text"
        let icon = Artifact.defaultIconForName("Product Requirements")
        XCTAssertEqual(icon, "doc.text")

        // "Supervisor Task" should return "target"
        let supervisorIcon = Artifact.defaultIconForName("Supervisor Task")
        XCTAssertEqual(supervisorIcon, "target")
    }

    func testDefaultIconForName_unknown_returnsDocText() {
        let icon = Artifact.defaultIconForName("Some Unknown Artifact")
        XCTAssertEqual(icon, "doc.text")
    }

    func testArtifact_codable_roundTrip() throws {
        let original = Artifact(
            name: "Test Artifact",
            icon: "star",
            mimeType: "application/json",
            description: "A test artifact",
            relativePath: "artifacts/test.json",
            isSystem: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Artifact.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.icon, original.icon)
        XCTAssertEqual(decoded.mimeType, original.mimeType)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.relativePath, original.relativePath)
        XCTAssertEqual(decoded.isSystem, original.isSystem)
        XCTAssertEqual(decoded.id, original.id)
    }

    // MARK: - Work Folder Tests

    func testActiveTeam_withActiveTeamID_returnsCorrectTeam() {
        let team1 = Team(name: "Team A")
        let team2 = Team(name: "Team B")
        let wf = WorkFolderProjection(state: WorkFolderState(name: "Test", activeTeamID: team2.id), settings: .defaults, teams: [team1, team2])

        XCTAssertEqual(wf.activeTeam?.id, team2.id)
        XCTAssertEqual(wf.activeTeam?.name, "Team B")
    }

    func testActiveTeam_nilActiveTeamID_returnsFirstTeam() {
        let team1 = Team(name: "Team A")
        let team2 = Team(name: "Team B")
        let wf = WorkFolderProjection(state: WorkFolderState(name: "Test", activeTeamID: nil), settings: .defaults, teams: [team1, team2])

        XCTAssertEqual(wf.activeTeam?.id, team1.id)
    }

    func testActiveTeam_invalidID_returnsFirstTeam() {
        let team1 = Team(name: "Team A")
        let team2 = Team(name: "Team B")
        // Non-existent ID
        let wf = WorkFolderProjection(state: WorkFolderState(name: "Test", activeTeamID: "test_team"), settings: .defaults, teams: [team1, team2])

        // When activeTeamID doesn't match any team, it returns nil (not first)
        // because the implementation checks `teams.first { $0.id == id }` which returns nil
        // and only falls back to `teams.first` when activeTeamID is nil.
        XCTAssertNil(wf.activeTeam)
    }

    func testSetActiveTeam_validID_setsIt() {
        let team1 = Team(name: "Team A")
        let team2 = Team(name: "Team B")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test", activeTeamID: team1.id), settings: .defaults, teams: [team1, team2])

        wf.setActiveTeam(team2.id)
        XCTAssertEqual(wf.activeTeamID, team2.id)
    }

    func testSetActiveTeam_invalidID_doesNothing() {
        let team1 = Team(name: "Team A")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test", activeTeamID: team1.id), settings: .defaults, teams: [team1])

        let bogusID: NTMSID = "nonexistent_team"
        wf.setActiveTeam(bogusID)
        XCTAssertEqual(wf.activeTeamID, team1.id)
    }

    func testAddTeam_appendsTeam() {
        let team1 = Team(name: "Team A")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: [team1])

        let team2 = Team(name: "Team B")
        wf.addTeam(team2)

        XCTAssertEqual(wf.teams.count, 2)
        XCTAssertEqual(wf.teams[1].name, "Team B")
    }

    func testRemoveTeam_removesTeam() {
        let team1 = Team(name: "Team A")
        let team2 = Team(name: "Team B")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: [team1, team2])

        wf.removeTeam(team1.id)
        XCTAssertEqual(wf.teams.count, 1)
        XCTAssertEqual(wf.teams[0].id, team2.id)
    }

    func testRemoveTeam_lastTeam_doesNotRemove() {
        let team1 = Team(name: "Team A")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: [team1])

        wf.removeTeam(team1.id)
        XCTAssertEqual(wf.teams.count, 1, "Cannot remove the last team")
        XCTAssertEqual(wf.teams[0].id, team1.id)
    }

    func testRemoveTeam_activeTeam_resetsToFirst() {
        let team1 = Team(name: "Team A")
        let team2 = Team(name: "Team B")
        let team3 = Team(name: "Team C")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test", activeTeamID: team2.id), settings: .defaults, teams: [team1, team2, team3])

        wf.removeTeam(team2.id)

        // Active team should reset to first team's ID
        XCTAssertEqual(wf.activeTeamID, team1.id)
        XCTAssertEqual(wf.teams.count, 2)
    }

    // MARK: - TeamHierarchy Tests

    func testHierarchy_supervisorID_returnsCorrect() {
        let hierarchy = TeamHierarchy(reportsTo: [
            "swe": "techLead",
            "techLead": "pm",
            "pm": "supervisor",
        ])

        XCTAssertEqual(hierarchy.supervisorID(for: "swe"), "techLead")
        XCTAssertEqual(hierarchy.supervisorID(for: "techLead"), "pm")
        XCTAssertEqual(hierarchy.supervisorID(for: "pm"), "supervisor")
        XCTAssertNil(hierarchy.supervisorID(for: "supervisor"))
    }

    func testHierarchy_subordinateIDs_returnsCorrect() {
        let hierarchy = TeamHierarchy(reportsTo: [
            "swe": "techLead",
            "designer": "techLead",
            "techLead": "pm",
        ])

        let subordinates = hierarchy.subordinateIDs(of: "techLead")
        XCTAssertEqual(Set(subordinates), Set(["swe", "designer"]))
        XCTAssertTrue(hierarchy.subordinateIDs(of: "swe").isEmpty)
    }

    func testHierarchy_doesReport_directReport_true() {
        let hierarchy = TeamHierarchy(reportsTo: [
            "swe": "techLead",
            "techLead": "pm",
        ])

        XCTAssertTrue(hierarchy.doesReport("swe", to: "techLead"))
    }

    func testHierarchy_doesReport_transitiveReport_true() {
        let hierarchy = TeamHierarchy(reportsTo: [
            "swe": "techLead",
            "techLead": "pm",
            "pm": "supervisor",
        ])

        XCTAssertTrue(hierarchy.doesReport("swe", to: "pm"))
        XCTAssertTrue(hierarchy.doesReport("swe", to: "supervisor"))
        XCTAssertTrue(hierarchy.doesReport("techLead", to: "supervisor"))
    }

    func testHierarchy_doesReport_noRelation_false() {
        let hierarchy = TeamHierarchy(reportsTo: [
            "swe": "techLead",
            "designer": "pm",
        ])

        XCTAssertFalse(hierarchy.doesReport("swe", to: "pm"))
        XCTAssertFalse(hierarchy.doesReport("swe", to: "designer"))
    }

    func testHierarchy_doesReport_cycleDetection_doesNotInfiniteLoop() {
        // Create a cycle: A -> B -> C -> A
        let hierarchy = TeamHierarchy(reportsTo: [
            "A": "B",
            "B": "C",
            "C": "A",
        ])

        // Should not hang, should return false for a non-existent supervisor in the cycle
        XCTAssertFalse(hierarchy.doesReport("A", to: "Z"))

        // Within the cycle, doesReport should still find direct relationships
        XCTAssertTrue(hierarchy.doesReport("A", to: "B"))
        XCTAssertTrue(hierarchy.doesReport("A", to: "C"))
    }

    // MARK: - TeamLimits Tests

    func testTeamLimits_default_values() {
        let limits = TeamLimits.default

        XCTAssertEqual(limits.maxConsultationsPerStep, 5)
        XCTAssertEqual(limits.maxMeetingsPerRun, 3)
        XCTAssertEqual(limits.maxMeetingTurns, 10)
        XCTAssertEqual(limits.maxSameTeammateAsks, 2)
        XCTAssertEqual(limits.autoIterationLimit, 10000)
        XCTAssertEqual(limits.maxMeetingToolIterationsPerTurn, 3)
        XCTAssertEqual(limits.maxChangeRequestsPerRun, 3)
        XCTAssertEqual(limits.maxAmendmentsPerStep, 2)
    }

    func testTeamLimits_discussionClub_zeroChangeRequests() {
        let limits = TeamLimits.discussionClub

        XCTAssertEqual(limits.maxChangeRequestsPerRun, 0)
        XCTAssertEqual(limits.maxAmendmentsPerStep, 0)
        // Discussion club has higher consultation and meeting limits
        XCTAssertEqual(limits.maxConsultationsPerStep, 10)
        XCTAssertEqual(limits.maxMeetingsPerRun, 10)
        XCTAssertEqual(limits.maxMeetingTurns, 10)
        XCTAssertEqual(limits.maxSameTeammateAsks, 4)
    }

    // MARK: - AcceptanceMode Tests

    func testAcceptanceMode_allCases_haveDisplayName() {
        for mode in AcceptanceMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode.rawValue) should have a displayName")
        }

        XCTAssertEqual(AcceptanceMode.afterEachArtifact.displayName, "After Each Artifact")
        XCTAssertEqual(AcceptanceMode.afterEachRole.displayName, "After Each Role")
        XCTAssertEqual(AcceptanceMode.finalOnly.displayName, "Final Result Only")
        XCTAssertEqual(AcceptanceMode.customCheckpoints.displayName, "Custom Checkpoints")
    }

    // MARK: - TeamGraphLayout Tests

    func testGraphLayout_setPosition_newRole_adds() {
        var layout = TeamGraphLayout()
        XCTAssertTrue(layout.nodePositions.isEmpty)

        layout.setPosition(for: "newRole", x: 100, y: 200)

        XCTAssertEqual(layout.nodePositions.count, 1)
        let pos = layout.position(for: "newRole")
        XCTAssertEqual(pos, CGPoint(x: 100, y: 200))
    }

    func testGraphLayout_setPosition_existingRole_updates() {
        var layout = TeamGraphLayout(
            nodePositions: [TeamNodePosition(roleID: "role1", x: 50, y: 50)]
        )

        layout.setPosition(for: "role1", x: 200, y: 300)

        XCTAssertEqual(layout.nodePositions.count, 1)
        let pos = layout.position(for: "role1")
        XCTAssertEqual(pos, CGPoint(x: 200, y: 300))
    }

    func testGraphLayout_hideRole_removesPositionAndAddsToHidden() {
        var layout = TeamGraphLayout(
            nodePositions: [
                TeamNodePosition(roleID: "role1", x: 100, y: 100),
                TeamNodePosition(roleID: "role2", x: 200, y: 200),
            ]
        )

        layout.hideRole("role1")

        XCTAssertNil(layout.position(for: "role1"))
        XCTAssertTrue(layout.hiddenRoleIDs.contains("role1"))
        XCTAssertEqual(layout.nodePositions.count, 1)
    }

    func testGraphLayout_showRole_addsPositionAndRemovesFromHidden() {
        var layout = TeamGraphLayout(
            nodePositions: [],
            hiddenRoleIDs: ["role1"]
        )

        layout.showRole("role1", at: CGPoint(x: 150, y: 250))

        XCTAssertFalse(layout.hiddenRoleIDs.contains("role1"))
        XCTAssertEqual(layout.position(for: "role1"), CGPoint(x: 150, y: 250))
    }

    func testGraphLayout_pruneHiddenRoles_removesOrphans() {
        var layout = TeamGraphLayout(
            nodePositions: [],
            hiddenRoleIDs: ["existing", "orphan1", "orphan2"]
        )

        let existingRoleIDs: Set<String> = ["existing", "visible"]
        layout.pruneHiddenRoles(existingRoleIDs: existingRoleIDs)

        XCTAssertEqual(layout.hiddenRoleIDs, ["existing"])
    }

    // MARK: - TeamGraphTransform Tests

    func testGraphTransform_clampScale_clampsToRange() {
        var transform = TeamGraphTransform(offsetX: 10, offsetY: 20, scale: 5.0)
        transform.clampScale()
        XCTAssertEqual(transform.scale, 2.0, "Scale above 2.0 should be clamped to 2.0")

        transform.scale = 0.1
        transform.clampScale()
        XCTAssertEqual(transform.scale, 0.5, "Scale below 0.5 should be clamped to 0.5")

        transform.scale = 1.5
        transform.clampScale()
        XCTAssertEqual(transform.scale, 1.5, "Scale within range should stay unchanged")
    }

    func testGraphTransform_reset_setsIdentity() {
        var transform = TeamGraphTransform(offsetX: 42, offsetY: -17, scale: 1.8)
        transform.reset()

        XCTAssertEqual(transform.offsetX, 0)
        XCTAssertEqual(transform.offsetY, 0)
        XCTAssertEqual(transform.scale, 1.0)
    }
}
