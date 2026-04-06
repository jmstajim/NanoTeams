import XCTest

@testable import NanoTeams

final class StableIDTests: XCTestCase {

    // MARK: - NTMSID.from(name:)

    func testNTMSID_fromName_lowercasesAndUnderscores() {
        XCTAssertEqual(NTMSID.from(name: "Personal Assistant"), "personal_assistant")
    }

    func testNTMSID_fromName_stripsNonAlphanumeric() {
        XCTAssertEqual(NTMSID.from(name: "Team (v2)!"), "team_v2")
    }

    func testNTMSID_fromName_preservesNumbers() {
        XCTAssertEqual(NTMSID.from(name: "Team 42"), "team_42")
    }

    func testNTMSID_fromName_emptyString() {
        XCTAssertEqual(NTMSID.from(name: ""), "")
    }

    func testNTMSID_fromName_alreadySlug() {
        XCTAssertEqual(NTMSID.from(name: "my_team"), "my_team")
    }

    func testNTMSID_fromName_colonSeparator() {
        // Colon is used as namespace separator for role/artifact IDs within teams
        XCTAssertEqual(NTMSID.from(name: "faang_team:Software Engineer"), "faang_team_software_engineer")
    }

    // MARK: - Template Team Stability

    func testDefaultTeams_haveStableIDs() {
        let teams1 = Team.defaultTeams
        let teams2 = Team.defaultTeams
        XCTAssertEqual(teams1.count, teams2.count)
        for (t1, t2) in zip(teams1, teams2) {
            XCTAssertEqual(t1.id, t2.id, "Team '\(t1.name)' ID should be stable")
        }
    }

    func testDefaultTeams_haveStableRoleIDs() {
        let teams1 = Team.defaultTeams
        let teams2 = Team.defaultTeams
        for (t1, t2) in zip(teams1, teams2) {
            XCTAssertEqual(t1.roles.count, t2.roles.count, "Team '\(t1.name)' role count mismatch")
            for (r1, r2) in zip(t1.roles, t2.roles) {
                XCTAssertEqual(r1.id, r2.id, "Role '\(r1.name)' in team '\(t1.name)' should have stable ID")
            }
        }
    }

    func testDefaultTeams_haveStableArtifactIDs() {
        let teams1 = Team.defaultTeams
        let teams2 = Team.defaultTeams
        for (t1, t2) in zip(teams1, teams2) {
            XCTAssertEqual(t1.artifacts.count, t2.artifacts.count)
            for (a1, a2) in zip(t1.artifacts, t2.artifacts) {
                XCTAssertEqual(a1.id, a2.id, "Artifact '\(a1.name)' in team '\(t1.name)' should have stable ID")
            }
        }
    }

    func testDefaultTeams_uniqueIDsAcrossTeams() {
        let teams = Team.defaultTeams
        var allTeamIDs = Set<NTMSID>()
        var allRoleIDs = Set<String>()
        for team in teams {
            XCTAssertTrue(allTeamIDs.insert(team.id).inserted, "Duplicate team ID for '\(team.name)'")
            for role in team.roles {
                XCTAssertTrue(allRoleIDs.insert(role.id).inserted, "Duplicate role ID '\(role.name)' in '\(team.name)'")
            }
        }
    }

    func testDefaultTeam_idDerivedFromName() {
        for team in Team.defaultTeams {
            XCTAssertEqual(team.id, NTMSID.from(name: team.name), "Team ID should be derived from name for '\(team.name)'")
        }
    }

    func testDefaultTeam_roleIDsAreReadable() {
        let team = Team.defaultTeams.first!
        for role in team.roles {
            // Role IDs should be human-readable, not UUIDs
            XCTAssertFalse(role.id.contains("-") && role.id.count == 36,
                          "Role '\(role.name)' has UUID-style ID: \(role.id)")
        }
    }

    // MARK: - Custom Role Deterministic IDs

    func testCustomRole_idDeterministicFromTeamAndName() {
        let teamID = "my_team"
        let roleName = "Backend Engineer"
        let id1 = NTMSID.from(name: "\(teamID):\(roleName)")
        let id2 = NTMSID.from(name: "\(teamID):\(roleName)")
        XCTAssertEqual(id1, id2, "Same team+role should always produce same ID")
        XCTAssertEqual(id1, "my_team_backend_engineer")
    }

    func testCustomRole_differentTeams_differentIDs() {
        let name = "Software Engineer"
        let id1 = NTMSID.from(name: "team_a:\(name)")
        let id2 = NTMSID.from(name: "team_b:\(name)")
        XCTAssertNotEqual(id1, id2, "Same role name in different teams should produce different IDs")
    }

    func testCustomRole_noUUID() {
        let id = NTMSID.from(name: "faang:Code Reviewer")
        // Should not contain UUID-style dashes
        let uuidPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        let matches = uuidPattern.numberOfMatches(in: id, range: NSRange(id.startIndex..., in: id))
        XCTAssertEqual(matches, 0, "Custom role ID should not be a UUID")
    }

    // MARK: - Team Duplicate Determinism

    func testTeamDuplicate_roleIDsDeterministic() {
        let team = Team.defaultTeams.first!
        let dup1 = team.duplicate(withName: "Clone Team")
        let dup2 = team.duplicate(withName: "Clone Team")
        XCTAssertEqual(dup1.roles.count, dup2.roles.count)
        for (r1, r2) in zip(dup1.roles, dup2.roles) {
            XCTAssertEqual(r1.id, r2.id, "Duplicated role '\(r1.name)' should have deterministic ID")
        }
    }

    func testTeamDuplicate_artifactIDsDeterministic() {
        let team = Team.defaultTeams.first!
        let dup1 = team.duplicate(withName: "Clone Team")
        let dup2 = team.duplicate(withName: "Clone Team")
        XCTAssertEqual(dup1.artifacts.count, dup2.artifacts.count)
        for (a1, a2) in zip(dup1.artifacts, dup2.artifacts) {
            XCTAssertEqual(a1.id, a2.id, "Duplicated artifact '\(a1.name)' should have deterministic ID")
        }
    }

    func testTeamDuplicate_roleIDsReadable() {
        let team = Team.defaultTeams.first!
        let dup = team.duplicate(withName: "My Clone")
        for role in dup.roles {
            XCTAssertTrue(role.id.contains("my_clone"),
                         "Duplicated role '\(role.name)' ID should contain team name: \(role.id)")
            XCTAssertFalse(role.id.contains("-") && role.id.count == 36,
                          "Duplicated role '\(role.name)' has UUID-style ID: \(role.id)")
        }
    }

    // MARK: - Import Determinism

    func testImportRole_idDeterministic() throws {
        let role = TeamRoleDefinition(
            id: "original_id",
            name: "Architect",
            prompt: "System architect.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let data = try TeamImportExportService.exportRole(role)

        var team1 = Team(name: "Target Team")
        var team2 = Team(name: "Target Team")
        try TeamImportExportService.importRole(from: data, into: &team1)
        try TeamImportExportService.importRole(from: data, into: &team2)

        XCTAssertEqual(team1.roles[0].id, team2.roles[0].id,
                       "Importing same role into same team should produce same ID")
        XCTAssertEqual(team1.roles[0].id, NTMSID.from(name: "target_team:Architect"))
    }

    func testImportRole_nameConflict_idMatchesFinalName() throws {
        let role = TeamRoleDefinition(
            id: "original_id",
            name: "Designer",
            prompt: "A designer.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let data = try TeamImportExportService.exportRole(role)

        var team = Team(name: "My Team")
        // Add existing role with same name to trigger conflict
        team.roles.append(TeamRoleDefinition(
            id: "existing_designer",
            name: "Designer",
            prompt: "Existing.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        ))

        try TeamImportExportService.importRole(from: data, into: &team)

        let imported = team.roles[1]
        XCTAssertEqual(imported.name, "Designer (Imported)")
        // ID should match the FINAL name (after conflict resolution), not the original
        XCTAssertEqual(imported.id, NTMSID.from(name: "my_team:Designer (Imported)"))
    }

    func testImportArtifact_idDeterministic() throws {
        let artifact = TeamArtifact(
            id: "original_id",
            name: "Design Spec",
            icon: "paintbrush",
            mimeType: "text/markdown",
            description: "Spec"
        )
        let data = try TeamImportExportService.exportArtifact(artifact)

        var team1 = Team(name: "Team A")
        var team2 = Team(name: "Team B")
        try TeamImportExportService.importArtifact(from: data, into: &team1)
        try TeamImportExportService.importArtifact(from: data, into: &team2)

        // Artifact IDs are slugified from name (not team-scoped)
        XCTAssertEqual(team1.artifacts[0].id, team2.artifacts[0].id)
        XCTAssertEqual(team1.artifacts[0].id, Artifact.slugify("Design Spec"))
    }

    func testImportTeam_roleIDsDeterministic() throws {
        let team = Team.defaultTeams.first!
        let data = try TeamImportExportService.exportTeam(team)

        let imported1 = try TeamImportExportService.importTeam(from: data, newName: "Imported FAANG")
        let imported2 = try TeamImportExportService.importTeam(from: data, newName: "Imported FAANG")

        XCTAssertEqual(imported1.roles.count, imported2.roles.count)
        for (r1, r2) in zip(imported1.roles, imported2.roles) {
            XCTAssertEqual(r1.id, r2.id, "Imported role '\(r1.name)' should have deterministic ID")
        }
    }

    func testImportTeam_roleIDsReadable() throws {
        let team = Team.defaultTeams.first!
        let data = try TeamImportExportService.exportTeam(team)

        let imported = try TeamImportExportService.importTeam(from: data, newName: "My Import")

        for role in imported.roles {
            XCTAssertTrue(role.id.contains("my_import"),
                         "Imported role '\(role.name)' ID should contain team name: \(role.id)")
        }
    }

    func testImportTeam_settingsRemappedToNewRoleIDs() throws {
        let team = Team.defaultTeams.first!
        let data = try TeamImportExportService.exportTeam(team)

        let imported = try TeamImportExportService.importTeam(from: data, newName: "Remapped Team")

        let importedRoleIDs = Set(imported.roles.map(\.id))

        // Hierarchy should reference new role IDs
        for (child, parent) in imported.settings.hierarchy.reportsTo {
            XCTAssertTrue(importedRoleIDs.contains(child),
                         "Hierarchy child '\(child)' should be a valid imported role ID")
            XCTAssertTrue(importedRoleIDs.contains(parent),
                         "Hierarchy parent '\(parent)' should be a valid imported role ID")
        }

        // Meeting coordinator should reference a new role ID
        if let coord = imported.settings.meetingCoordinatorRoleID {
            XCTAssertTrue(importedRoleIDs.contains(coord),
                         "Meeting coordinator '\(coord)' should be a valid imported role ID")
        }

        // Invitable roles should reference new role IDs
        for stepID in imported.settings.invitableRoles {
            XCTAssertTrue(importedRoleIDs.contains(stepID),
                         "Invitable role '\(stepID)' should be a valid imported role ID")
        }
    }

    // MARK: - Duplicate ID Ordering

    func testDuplicateRole_idDiffersFromOriginal() {
        let original = TeamRoleDefinition(
            id: NTMSID.from(name: "team:Engineer"),
            name: "Engineer",
            prompt: "Test.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )

        // Simulate what handleDuplicateRole does
        var duplicated = original
        duplicated.name = "\(original.name) Copy"
        duplicated.id = NTMSID.from(name: "team:\(duplicated.name)")

        XCTAssertNotEqual(duplicated.id, original.id,
                         "Duplicated role should have different ID from original")
        XCTAssertTrue(duplicated.id.contains("copy"),
                     "Duplicated role ID should contain 'copy': \(duplicated.id)")
    }

    func testDuplicateArtifact_idDiffersFromOriginal() {
        let original = TeamArtifact(
            id: TeamArtifact.slugify("Design Spec"),
            name: "Design Spec",
            icon: "paintbrush",
            mimeType: "text/markdown",
            description: "Spec"
        )

        // Simulate what handleDuplicateArtifact does
        var duplicated = original
        duplicated.name = "\(original.name) Copy"
        duplicated.id = TeamArtifact.slugify(duplicated.name)

        XCTAssertNotEqual(duplicated.id, original.id,
                         "Duplicated artifact should have different ID from original")
        XCTAssertEqual(duplicated.id, "design_spec_copy")
    }

    // MARK: - Colon Namespace Separator

    func testNTMSID_colonReplacedWithUnderscore() {
        // Colon becomes underscore for readable namespace separation
        XCTAssertEqual(NTMSID.from(name: "faang:PM"), "faang_pm")
        XCTAssertEqual(NTMSID.from(name: "startup:Software Engineer"), "startup_software_engineer")
        // Note: boundary collisions are possible (e.g. "a_b:c" == "a:b_c") but unlikely
        // with real team/role names since team IDs don't contain underscores from role names
    }
}
