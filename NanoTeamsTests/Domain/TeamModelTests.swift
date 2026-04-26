import XCTest

@testable import NanoTeams

final class TeamModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Team Initialization Tests

    func testTeam_CustomInit() {
        let role1 = TeamRoleDefinition(
            id: "test_engineer",
            name: "Engineer",
            prompt: "Engineer prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let artifact1 = TeamArtifact(
            id: "test_requirements",
            name: "Requirements",
            icon: "doc",
            mimeType: "text/markdown",
            description: "Test"
        )

        let team = Team(
            name: "Custom Team",
            roles: [role1],
            artifacts: [artifact1],
            settings: .default,
            graphLayout: .default
        )

        XCTAssertEqual(team.name, "Custom Team")
        XCTAssertEqual(team.roles.count, 1)
        XCTAssertEqual(team.artifacts.count, 1)
    }

    func testTeam_MemberCount() {
        let team = Team(
            name: "Test",
            roles: [
                TeamRoleDefinition(
                    id: "test_role1", name: "Role1", prompt: "", toolIDs: [], usePlanningPhase: false,
                    dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])),
                TeamRoleDefinition(
                    id: "test_role2", name: "Role2", prompt: "", toolIDs: [], usePlanningPhase: false,
                    dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])),
                TeamRoleDefinition(
                    id: "test_role3", name: "Role3", prompt: "", toolIDs: [], usePlanningPhase: false,
                    dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])),
            ],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )

        XCTAssertEqual(team.memberCount, 3)
    }

    // MARK: - isSupervisor Tests

    func testIsSupervisor_SystemSupervisorRole() {
        let role = TeamRoleDefinition(
            id: "test_supervisor",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
        XCTAssertTrue(role.isSupervisor)
    }

    func testIsSupervisor_NonSupervisorRole() {
        let role = TeamRoleDefinition(
            id: "test_software_engineer",
            name: "Software Engineer",
            prompt: "You are an engineer",
            toolIDs: ["read_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(),
            isSystemRole: true,
            systemRoleID: "softwareEngineer"
        )
        XCTAssertFalse(role.isSupervisor)
    }

    func testIsSupervisor_CustomRoleProducingSupervisorTask() {
        let role = TeamRoleDefinition(
            id: "test_custom_supervisor",
            name: "Custom Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [], producesArtifacts: [SystemTemplates.supervisorTaskArtifactName])
        )
        // isSupervisor checks systemRoleID, not artifact names
        XCTAssertFalse(role.isSupervisor)
    }

    func testIsSupervisor_NilSystemRoleID() {
        let role = TeamRoleDefinition(
            id: "test_regular_role",
            name: "Regular Role",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        XCTAssertFalse(role.isSupervisor)
    }

    // MARK: - Role Management Tests

    func testTeam_HasRole() {
        var team = Team(
            name: "Test", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let role = TeamRoleDefinition(
            id: "test-role-id",
            name: "Test Role",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )

        team.addRole(role)

        XCTAssertTrue(team.hasRole("test-role-id"))
        XCTAssertFalse(team.hasRole("nonexistent-id"))
    }

    func testTeam_RoleByID() {
        var team = Team(
            name: "Test", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let role = TeamRoleDefinition(
            id: "test-role-id",
            name: "Test Role",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )

        team.addRole(role)

        let found = team.role(withID: "test-role-id")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Test Role")
    }

    func testTeam_AddRole() {
        var team = Team(
            name: "Test", roles: [], artifacts: [], settings: .default,
            graphLayout: TeamGraphLayout())
        let originalUpdatedAt = team.updatedAt

        Thread.sleep(forTimeInterval: 0.01)

        let role = TeamRoleDefinition(
            id: "test_test_role",
            name: "Test Role",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        team.addRole(role)

        XCTAssertEqual(team.roles.count, 1)
        XCTAssertGreaterThan(team.updatedAt, originalUpdatedAt)
        // Should also add node position
        XCTAssertEqual(team.graphLayout.nodePositions.count, 1)
    }

    func testTeam_RemoveRole() {
        var team = Team(
            name: "Test", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let role = TeamRoleDefinition(
            id: "test-id",
            name: "Test Role",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        team.addRole(role)

        let originalUpdatedAt = team.updatedAt
        Thread.sleep(forTimeInterval: 0.01)

        team.removeRole("test-id")

        XCTAssertEqual(team.roles.count, 0)
        XCTAssertGreaterThan(team.updatedAt, originalUpdatedAt)
    }

    func testTeam_UpdateRole() {
        var team = Team(
            name: "Test", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let role = TeamRoleDefinition(
            id: "test-id",
            name: "Original Name",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        team.addRole(role)

        var updated = role
        updated.name = "Updated Name"
        team.updateRole(updated)

        XCTAssertEqual(team.roles.first?.name, "Updated Name")
    }

    // MARK: - Artifact Management Tests

    func testTeam_ArtifactByName() {
        var team = Team(
            name: "Test", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let artifact = TeamArtifact(
            id: "test_test_artifact",
            name: "Test Artifact",
            icon: "doc",
            mimeType: "text/plain",
            description: ""
        )
        team.addArtifact(artifact)

        let found = team.artifact(withName: "Test Artifact")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Test Artifact")
    }

    func testTeam_AddArtifact() {
        var team = Team(
            name: "Test", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let originalUpdatedAt = team.updatedAt

        Thread.sleep(forTimeInterval: 0.01)

        let artifact = TeamArtifact(
            id: "test_test_artifact_add",
            name: "Test Artifact",
            icon: "doc",
            mimeType: "text/plain",
            description: ""
        )
        team.addArtifact(artifact)

        XCTAssertEqual(team.artifacts.count, 1)
        XCTAssertGreaterThan(team.updatedAt, originalUpdatedAt)
    }

    func testTeam_RemoveArtifact() {
        var team = Team(
            name: "Test", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let artifact = TeamArtifact(
            id: "test-id",
            name: "Test Artifact",
            icon: "doc",
            mimeType: "text/plain",
            description: ""
        )
        team.addArtifact(artifact)

        let originalUpdatedAt = team.updatedAt
        Thread.sleep(forTimeInterval: 0.01)

        team.removeArtifact("test-id")

        XCTAssertEqual(team.artifacts.count, 0)
        XCTAssertGreaterThan(team.updatedAt, originalUpdatedAt)
    }

    func testTeam_UpdateArtifact() {
        var team = Team(
            name: "Test", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let artifact = TeamArtifact(
            id: "test-id",
            name: "Original Name",
            icon: "doc",
            mimeType: "text/plain",
            description: ""
        )
        team.addArtifact(artifact)

        var updated = artifact
        updated.name = "Updated Name"
        team.updateArtifact(updated)

        XCTAssertEqual(team.artifacts.first?.name, "Updated Name")
    }

    // MARK: - Mutation Tests

    func testTeam_Rename() {
        var team = Team(
            name: "Original Name", roles: [], artifacts: [], settings: .default,
            graphLayout: .default)
        let originalUpdatedAt = team.updatedAt

        Thread.sleep(forTimeInterval: 0.01)

        team.rename(to: "New Name")

        XCTAssertEqual(team.name, "New Name")
        XCTAssertGreaterThan(team.updatedAt, originalUpdatedAt)
    }

    // MARK: - Duplicate Tests

    func testTeam_Duplicate_DefaultName() {
        let role = TeamRoleDefinition(
            id: "test_test_role",
            name: "Test Role",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let artifact = TeamArtifact(
            id: "test_test_artifact_dup",
            name: "Test Artifact",
            icon: "doc",
            mimeType: "text/plain",
            description: ""
        )
        let original = Team(
            name: "Original",
            roles: [role],
            artifacts: [artifact],
            settings: .default,
            graphLayout: .default
        )
        let duplicate = original.duplicate()

        XCTAssertEqual(duplicate.name, "Original Copy")
        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.roles.count, 1)
        XCTAssertEqual(duplicate.artifacts.count, 1)
        XCTAssertNotEqual(
            duplicate.roles[0].id, original.roles[0].id, "Role IDs should be regenerated")
        XCTAssertNotEqual(
            duplicate.artifacts[0].id, original.artifacts[0].id,
            "Artifact IDs should be regenerated")
        XCTAssertEqual(duplicate.settings, original.settings)
    }

    func testTeam_Duplicate_CustomName() {
        let original = Team(
            name: "Original", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let duplicate = original.duplicate(withName: "Custom Name")

        XCTAssertEqual(duplicate.name, "Custom Name")
    }

    // MARK: - Codable Tests

    func testTeam_Codable_RoundTrip() throws {
        let role = TeamRoleDefinition(
            id: "test_test_role",
            name: "Test Role",
            prompt: "Test prompt",
            toolIDs: ["read_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let artifact = TeamArtifact(
            id: "test_test_artifact",
            name: "Test Artifact",
            icon: "doc",
            mimeType: "text/markdown",
            description: "Test description"
        )
        let original = Team(
            name: "Test Team",
            roles: [role],
            artifacts: [artifact],
            settings: .default,
            graphLayout: .default
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Team.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.roles.count, 1)
        XCTAssertEqual(decoded.artifacts.count, 1)
        XCTAssertEqual(decoded.roles[0].name, "Test Role")
        XCTAssertEqual(decoded.artifacts[0].name, "Test Artifact")
        XCTAssertEqual(decoded.settings, original.settings)
        XCTAssertEqual(decoded.systemPromptTemplate, original.systemPromptTemplate)
        XCTAssertEqual(decoded.consultationPromptTemplate, original.consultationPromptTemplate)
        XCTAssertEqual(decoded.meetingPromptTemplate, original.meetingPromptTemplate)
    }

    func testTeam_Codable_WithDefaults() throws {
        // JSON without optional fields
        let json = """
            {
                "id": "550e8400-e29b-41d4-a716-446655440000",
                "name": "Test Team",
                "roles": [],
                "artifacts": []
            }
            """.data(using: .utf8)!

        let team = try JSONDecoder().decode(Team.self, from: json)

        XCTAssertEqual(team.name, "Test Team")
        XCTAssertEqual(team.roles.count, 0)
        XCTAssertEqual(team.artifacts.count, 0)
        XCTAssertEqual(team.settings, .default)
        XCTAssertEqual(team.graphLayout, .default)
        // Template fields should default to generic templates
        XCTAssertEqual(team.systemPromptTemplate, SystemTemplates.genericTemplate)
        XCTAssertEqual(team.consultationPromptTemplate, SystemTemplates.genericConsultationTemplate)
        XCTAssertEqual(team.meetingPromptTemplate, SystemTemplates.genericMeetingTemplate)
    }

    // MARK: - Hashable Tests

    func testTeam_Hashable() {
        let team1 = Team(
            name: "Team", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let team2 = Team(
            name: "Team", roles: [], artifacts: [], settings: .default, graphLayout: .default)

        // Different IDs, so not equal
        XCTAssertNotEqual(team1, team2)

        // Same instance
        let team3 = team1
        XCTAssertEqual(team1, team3)
    }

    // NOTE: Team static preset tests (Team.default, Team.startup, etc.) removed.
    // Teams are now created via Team.defaultTeams which will be implemented
    // in Phase 2 with SystemTemplates integration.

    // MARK: - TeamGraphTransform Tests

    func testTeamGraphTransform_Identity() {
        let transform = TeamGraphTransform.identity

        XCTAssertEqual(transform.offsetX, 0)
        XCTAssertEqual(transform.offsetY, 0)
        XCTAssertEqual(transform.scale, 1.0)
    }

    func testTeamGraphTransform_Codable() throws {
        let original = TeamGraphTransform(offsetX: 100, offsetY: 200, scale: 1.5)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeamGraphTransform.self, from: encoded)

        XCTAssertEqual(decoded.offsetX, original.offsetX)
        XCTAssertEqual(decoded.offsetY, original.offsetY)
        XCTAssertEqual(decoded.scale, original.scale)
    }

    // MARK: - Work Folder Teams Integration Tests

    func testProject_TeamsArray() {
        let team1 = Team(name: "Team 1")
        let team2 = Team(name: "Team 2")
        let wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: [team1, team2])

        XCTAssertEqual(wf.teams.count, 2)
    }

    func testProject_ActiveTeam() {
        let team1 = Team(name: "Team 1")
        let team2 = Team(name: "Team 2")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: [team1, team2])

        // Default: first team is active
        XCTAssertEqual(wf.activeTeam?.id, team1.id)

        // Set active team
        wf.setActiveTeam(team2.id)
        XCTAssertEqual(wf.activeTeam?.id, team2.id)
    }

    func testProject_DefaultTeams_UsesBootstrapDefaults() {
        let wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: Team.defaultTeams)
        let names = wf.teams.map(\.name)

        XCTAssertEqual(wf.teams.count, 7)
        XCTAssertEqual(names, ["Coding Assistant", "Personal Assistant", "FAANG Team", "Engineering Team", "Startup", "Quest Party", "Discussion Club"])
    }

    func testDefaultTeams_codingAssistantIsFirst_byTemplateID() {
        // Pin order via templateID so a future rename of the display name doesn't
        // mask an accidental reorder.
        let templateIDs = Team.defaultTeams.map(\.templateID)
        XCTAssertEqual(templateIDs.first, "codingAssistant")
        XCTAssertEqual(templateIDs, ["codingAssistant", "assistant", "faang", "engineering", "startup", "questParty", "discussionClub"])
    }

    func testTemplateMetadata_codingAssistantIsFirstRealTemplate() {
        // The picker's metadata array starts with the synthetic "Empty Team" entry,
        // so the first *real* template must be Coding Assistant.
        let metadata = TeamTemplateFactory.templateMetadata
        XCTAssertEqual(metadata.first?.id, "empty")
        XCTAssertEqual(metadata.dropFirst().first?.id, "codingAssistant")
    }

    func testCodingAssistantTemplate_supervisorModeIsManual() {
        // Pinned explicitly in the factory (not relying on the buildTeam default) so
        // that future changes to TeamSettings or buildTeam defaults can't silently
        // flip Coding Assistant onto autonomous mode — its chat-mode UX depends on
        // ask_supervisor blocking for human input.
        let team = TeamTemplateFactory.codingAssistant()
        XCTAssertEqual(team.settings.supervisorMode, .manual)
    }

    func testProject_AddTeam() {
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: [Team(name: "Original")])
        let newTeam = Team(name: "New Team")

        wf.addTeam(newTeam)

        XCTAssertEqual(wf.teams.count, 2)
        XCTAssertTrue(wf.teams.contains { $0.id == newTeam.id })
    }

    func testProject_RemoveTeam_CannotRemoveLast() {
        let team = Team(name: "Only Team")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: [team])

        wf.removeTeam(team.id)

        // Should still have the team
        XCTAssertEqual(wf.teams.count, 1)
    }

    func testProject_RemoveTeam_Multiple() {
        let team1 = Team(name: "Team 1")
        let team2 = Team(name: "Team 2")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test", activeTeamID: team1.id), settings: .defaults, teams: [team1, team2])

        wf.removeTeam(team1.id)

        XCTAssertEqual(wf.teams.count, 1)
        XCTAssertFalse(wf.teams.contains { $0.id == team1.id })
        // Active team should reset
        XCTAssertEqual(wf.activeTeamID, team2.id)
    }

    func testProject_UpdateTeam() {
        var team = Team(name: "Original")
        var wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: [team])

        team.name = "Updated"
        wf.updateTeam(team)

        XCTAssertEqual(wf.teams.first?.name, "Updated")
    }

    func testProject_TeamByID() {
        let team1 = Team(name: "Team 1")
        let team2 = Team(name: "Team 2")
        let wf = WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: [team1, team2])

        let found = wf.team(withID: team2.id)

        XCTAssertEqual(found?.name, "Team 2")
    }

    // MARK: - TeamSettings Codable Tests

    func testTeamSettings_Codable_RoundTrip() throws {
        var settings = TeamSettings.default
        settings.meetingCoordinatorRoleID = "swe-123"
        settings.supervisorCanBeInvited = true
        settings.defaultAcceptanceMode = .finalOnly
        settings.acceptanceCheckpoints = ["sre", "uxDesigner"]

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TeamSettings.self, from: encoded)

        XCTAssertEqual(decoded.meetingCoordinatorRoleID, "swe-123")
        XCTAssertEqual(decoded.supervisorCanBeInvited, true)
        XCTAssertEqual(decoded.defaultAcceptanceMode, .finalOnly)
        XCTAssertEqual(decoded.acceptanceCheckpoints, ["sre", "uxDesigner"])
    }

    func testTeamSettings_Default() {
        let settings = TeamSettings.default

        XCTAssertNil(settings.meetingCoordinatorRoleID)
        XCTAssertEqual(settings.supervisorCanBeInvited, false)
        XCTAssertEqual(settings.defaultAcceptanceMode, .afterEachRole)
        XCTAssertEqual(settings.acceptanceCheckpoints, [])
        XCTAssertTrue(settings.invitableRoles.isEmpty)
    }

    // MARK: - Bootstrap Team Settings Tests

    func testBootstrapTeam_FAANG_HasSettings() {
        let teams = Team.defaultTeams
        guard let faangTeam = teams.first(where: { $0.name == "FAANG Team" }) else {
            XCTFail("FAANG Team not found in bootstrap defaults")
            return
        }

        // FAANG team should have hierarchy, invitable roles, and coordinator
        XCTAssertFalse(faangTeam.settings.hierarchy.reportsTo.isEmpty)
        XCTAssertFalse(faangTeam.settings.invitableRoles.isEmpty)
        XCTAssertNotNil(faangTeam.settings.meetingCoordinatorRoleID)
        XCTAssertEqual(faangTeam.settings.defaultAcceptanceMode, .finalOnly)
    }

    func testBootstrapTeam_QuestParty_HasSettings() {
        let teams = Team.defaultTeams
        guard let questTeam = teams.first(where: { $0.name == "Quest Party" }) else {
            XCTFail("Quest Party not found in bootstrap defaults")
            return
        }

        XCTAssertEqual(questTeam.roles.count, 6)  // 5 Quest Party roles + Supervisor
        XCTAssertFalse(questTeam.settings.hierarchy.reportsTo.isEmpty)
        XCTAssertNotNil(questTeam.settings.meetingCoordinatorRoleID)
        XCTAssertTrue(questTeam.settings.supervisorCanBeInvited)
        XCTAssertEqual(questTeam.settings.defaultAcceptanceMode, .finalOnly)
        XCTAssertFalse(questTeam.settings.invitableRoles.isEmpty)
    }

    func testBootstrapTeam_Startup_HasSettings() {
        let teams = Team.defaultTeams
        guard let startupTeam = teams.first(where: { $0.name == "Startup" }) else {
            XCTFail("Startup not found in bootstrap defaults")
            return
        }

        XCTAssertEqual(startupTeam.roles.count, 2)  // Supervisor + SWE
        XCTAssertNotNil(startupTeam.settings.meetingCoordinatorRoleID)
        XCTAssertTrue(startupTeam.settings.supervisorCanBeInvited)
        XCTAssertEqual(startupTeam.settings.defaultAcceptanceMode, .finalOnly)
    }

    func testBootstrapTeam_FAANG_HasSoftwareTemplates() {
        let teams = Team.defaultTeams
        guard let faangTeam = teams.first(where: { $0.name == "FAANG Team" }) else {
            XCTFail("FAANG Team not found")
            return
        }

        XCTAssertEqual(faangTeam.systemPromptTemplate, SystemTemplates.softwareTemplate)
        XCTAssertEqual(faangTeam.consultationPromptTemplate, SystemTemplates.softwareConsultationTemplate)
        XCTAssertEqual(faangTeam.meetingPromptTemplate, SystemTemplates.softwareMeetingTemplate)
    }

    func testBootstrapTeam_QuestParty_HasQuestPartyTemplates() {
        let teams = Team.defaultTeams
        guard let questTeam = teams.first(where: { $0.name == "Quest Party" }) else {
            XCTFail("Quest Party not found")
            return
        }

        XCTAssertEqual(questTeam.systemPromptTemplate, SystemTemplates.questPartyTemplate)
        XCTAssertEqual(questTeam.consultationPromptTemplate, SystemTemplates.questPartyConsultationTemplate)
        XCTAssertEqual(questTeam.meetingPromptTemplate, SystemTemplates.questPartyMeetingTemplate)
    }

    func testBootstrapTeam_DiscussionClub_HasDiscussionTemplates() {
        let teams = Team.defaultTeams
        guard let dcTeam = teams.first(where: { $0.name == "Discussion Club" }) else {
            XCTFail("Discussion Club not found")
            return
        }

        XCTAssertEqual(dcTeam.systemPromptTemplate, SystemTemplates.discussionTemplate)
        XCTAssertEqual(dcTeam.consultationPromptTemplate, SystemTemplates.discussionConsultationTemplate)
        XCTAssertEqual(dcTeam.meetingPromptTemplate, SystemTemplates.discussionMeetingTemplate)
    }

    func testBootstrapTeam_DiscussionClub_HasObservers() {
        let teams = Team.defaultTeams
        guard let dcTeam = teams.first(where: { $0.name == "Discussion Club" }) else {
            XCTFail("Discussion Club not found in bootstrap defaults")
            return
        }

        // Discussion Club has 4 observer roles (only Moderator executes)
        // Observers are auto-derived: roles that don't produce artifacts
        let observers = dcTeam.roles.filter(\.isObserver)
        XCTAssertEqual(observers.count, 4)
        XCTAssertEqual(dcTeam.settings.limits.maxMeetingTurns, 10)
        XCTAssertEqual(dcTeam.settings.limits.maxMeetingsPerRun, 10)
    }

    // MARK: - TeamLimits Codable Migration Tests

    func testTeamLimits_Codable_EmptyJSON_UsesDefaults() throws {
        let json = "{}".data(using: .utf8)!

        let limits = try JSONDecoder().decode(TeamLimits.self, from: json)

        XCTAssertEqual(limits.maxConsultationsPerStep, 5)
        XCTAssertEqual(limits.maxMeetingsPerRun, 3)
        XCTAssertEqual(limits.maxMeetingTurns, 10)
        XCTAssertEqual(limits.maxSameTeammateAsks, 2)
        XCTAssertEqual(limits.autoIterationLimit, 10000)
    }

    func testTeamLimits_Codable_PartialJSON_FillsMissingWithDefaults() throws {
        let json = """
            {
                "maxConsultationsPerStep": 10,
                "maxMeetingsPerRun": 5
            }
            """.data(using: .utf8)!

        let limits = try JSONDecoder().decode(TeamLimits.self, from: json)

        // Explicitly set values
        XCTAssertEqual(limits.maxConsultationsPerStep, 10)
        XCTAssertEqual(limits.maxMeetingsPerRun, 5)

        // Default values for missing fields
        XCTAssertEqual(limits.maxMeetingTurns, 10)
        XCTAssertEqual(limits.maxSameTeammateAsks, 2)
        XCTAssertEqual(limits.autoIterationLimit, 10000)
    }

    func testTeamLimits_Codable_PartialJSON_MissingFieldsGetDefaults() throws {
        let json = """
            {
                "maxConsultationsPerStep": 5,
                "maxMeetingsPerRun": 3,
                "maxMeetingTurns": 10
            }
            """.data(using: .utf8)!

        let limits = try JSONDecoder().decode(TeamLimits.self, from: json)

        XCTAssertEqual(limits.maxConsultationsPerStep, 5)
        XCTAssertEqual(limits.maxMeetingsPerRun, 3)
        XCTAssertEqual(limits.maxMeetingTurns, 10)
        XCTAssertEqual(limits.maxSameTeammateAsks, 2)  // Default
        XCTAssertEqual(limits.autoIterationLimit, 10000)  // Default
        XCTAssertEqual(limits.maxMeetingToolIterationsPerTurn, 3)  // Default
    }

    func testTeamLimits_Codable_RoundTrip() throws {
        let limits = TeamLimits(
            maxConsultationsPerStep: 7,
            maxMeetingsPerRun: 4,
            maxMeetingTurns: 15,
            maxSameTeammateAsks: 3,
            autoIterationLimit: 5000
        )

        let encoded = try JSONEncoder().encode(limits)
        let decoded = try JSONDecoder().decode(TeamLimits.self, from: encoded)

        XCTAssertEqual(decoded.maxConsultationsPerStep, 7)
        XCTAssertEqual(decoded.maxMeetingsPerRun, 4)
        XCTAssertEqual(decoded.maxMeetingTurns, 15)
        XCTAssertEqual(decoded.maxSameTeammateAsks, 3)
        XCTAssertEqual(decoded.autoIterationLimit, 5000)
    }

    // MARK: - TeamGraphTransform Codable Migration Tests

    func testTeamGraphTransform_Codable_EmptyJSON_UsesDefaults() throws {
        let json = "{}".data(using: .utf8)!

        let transform = try JSONDecoder().decode(TeamGraphTransform.self, from: json)

        XCTAssertEqual(transform.offsetX, 0)
        XCTAssertEqual(transform.offsetY, 0)
        XCTAssertEqual(transform.scale, 1.0)
    }

    func testTeamGraphTransform_Codable_PartialJSON_FillsMissingWithDefaults() throws {
        let json = """
            {
                "offsetX": 100.5,
                "scale": 1.5
            }
            """.data(using: .utf8)!

        let transform = try JSONDecoder().decode(TeamGraphTransform.self, from: json)

        XCTAssertEqual(transform.offsetX, 100.5)
        XCTAssertEqual(transform.offsetY, 0)  // Default
        XCTAssertEqual(transform.scale, 1.5)
    }

    func testTeamGraphTransform_Reset() {
        var transform = TeamGraphTransform(offsetX: 100, offsetY: 200, scale: 2.0)

        transform.reset()

        XCTAssertEqual(transform.offsetX, 0)
        XCTAssertEqual(transform.offsetY, 0)
        XCTAssertEqual(transform.scale, 1.0)
    }

    func testTeamGraphTransform_ClampScale() {
        var transformTooLow = TeamGraphTransform(offsetX: 0, offsetY: 0, scale: 0.1)
        var transformTooHigh = TeamGraphTransform(offsetX: 0, offsetY: 0, scale: 5.0)
        var transformValid = TeamGraphTransform(offsetX: 0, offsetY: 0, scale: 1.5)

        transformTooLow.clampScale()
        transformTooHigh.clampScale()
        transformValid.clampScale()

        XCTAssertEqual(transformTooLow.scale, 0.5)
        XCTAssertEqual(transformTooHigh.scale, 2.0)
        XCTAssertEqual(transformValid.scale, 1.5)
    }

    // MARK: - TeamGraphLayout Codable Migration Tests

    func testTeamGraphLayout_Codable_EmptyJSON_UsesDefaults() throws {
        let json = "{}".data(using: .utf8)!

        let layout = try JSONDecoder().decode(TeamGraphLayout.self, from: json)

        XCTAssertEqual(layout.nodePositions, TeamGraphLayout.default.nodePositions)
        XCTAssertEqual(layout.transform, .identity)
    }

    func testTeamGraphLayout_Codable_PartialJSON_CustomPositionsDefaultTransform() throws {
        let json = """
            {
                "nodePositions": [
                    { "roleID": "softwareEngineer", "x": 50, "y": 100 }
                ]
            }
            """.data(using: .utf8)!

        let layout = try JSONDecoder().decode(TeamGraphLayout.self, from: json)

        XCTAssertEqual(layout.nodePositions.count, 1)
        XCTAssertEqual(layout.nodePositions.first?.roleID, "softwareEngineer")
        XCTAssertEqual(layout.nodePositions.first?.x, 50)
        XCTAssertEqual(layout.nodePositions.first?.y, 100)
        XCTAssertEqual(layout.transform, .identity)
    }

    func testTeamGraphLayout_Position_ForKnownRole() {
        let layout = TeamGraphLayout.default

        let position = layout.position(for: Role.builtInID(.softwareEngineer))

        XCTAssertNotNil(position)
        XCTAssertEqual(position?.x, 300)
        XCTAssertEqual(position?.y, 520)
    }

    func testTeamGraphLayout_Position_ForUnknownRole() {
        let layout = TeamGraphLayout.default

        let position = layout.position(for: "unknownRole")

        XCTAssertNil(position)
    }

    func testTeamGraphLayout_SetPosition_ExistingRole() {
        var layout = TeamGraphLayout.default

        layout.setPosition(for: Role.builtInID(.softwareEngineer), x: 999, y: 888)

        let position = layout.position(for: Role.builtInID(.softwareEngineer))
        XCTAssertEqual(position?.x, 999)
        XCTAssertEqual(position?.y, 888)
    }

    func testTeamGraphLayout_SetPosition_NewRole() {
        var layout = TeamGraphLayout.default
        let originalCount = layout.nodePositions.count

        layout.setPosition(for: "customRole", x: 500, y: 600)

        XCTAssertEqual(layout.nodePositions.count, originalCount + 1)
        let position = layout.position(for: "customRole")
        XCTAssertEqual(position?.x, 500)
        XCTAssertEqual(position?.y, 600)
    }

    func testTeamGraphLayout_ResetTransform() {
        var layout = TeamGraphLayout(
            nodePositions: [],
            transform: TeamGraphTransform(offsetX: 100, offsetY: 200, scale: 2.0)
        )

        layout.resetTransform()

        XCTAssertEqual(layout.transform, .identity)
    }

    func testTeamGraphLayout_BootstrapTeamHasPositions() {
        // Bootstrap teams generate graph layouts with positions for all roles
        let firstTeam = Team.defaultTeams[0]
        XCTAssertFalse(firstTeam.graphLayout.nodePositions.isEmpty)
        XCTAssertEqual(firstTeam.graphLayout.nodePositions.count, firstTeam.roles.count)
    }

    // MARK: - TeamHierarchy Tests

    func testTeamHierarchy_SupervisorID() {
        let hierarchy = TeamHierarchy(reportsTo: [
            "pm": "supervisor",
            "tl": "pm",
            "swe": "tl",
            "tpm": "tl",
        ])

        XCTAssertEqual(hierarchy.supervisorID(for: "pm"), "supervisor")
        XCTAssertEqual(hierarchy.supervisorID(for: "tl"), "pm")
        XCTAssertEqual(hierarchy.supervisorID(for: "swe"), "tl")
        XCTAssertEqual(hierarchy.supervisorID(for: "tpm"), "tl")
        XCTAssertNil(hierarchy.supervisorID(for: "supervisor"))
    }

    func testTeamHierarchy_SubordinateIDs() {
        let hierarchy = TeamHierarchy(reportsTo: [
            "pm": "supervisor",
            "tl": "pm",
            "swe": "tl",
            "cr": "tl",
            "sre": "tl",
            "tpm": "tl",
        ])

        let tlSubordinates = Set(hierarchy.subordinateIDs(of: "tl"))
        XCTAssertTrue(tlSubordinates.contains("swe"))
        XCTAssertTrue(tlSubordinates.contains("cr"))
        XCTAssertTrue(tlSubordinates.contains("sre"))
        XCTAssertTrue(tlSubordinates.contains("tpm"))
    }

    func testTeamHierarchy_DoesReport_Direct() {
        let hierarchy = TeamHierarchy(reportsTo: [
            "pm": "supervisor",
            "tl": "pm",
            "swe": "tl",
        ])

        XCTAssertTrue(hierarchy.doesReport("swe", to: "tl"))
        XCTAssertFalse(hierarchy.doesReport("tl", to: "swe"))
    }

    func testTeamHierarchy_DoesReport_Indirect() {
        let hierarchy = TeamHierarchy(reportsTo: [
            "pm": "supervisor",
            "tl": "pm",
            "swe": "tl",
        ])

        XCTAssertTrue(hierarchy.doesReport("swe", to: "pm"))
        XCTAssertTrue(hierarchy.doesReport("swe", to: "supervisor"))
    }

    func testTeamHierarchy_DoesReport_CycleDetection() {
        let cyclicHierarchy = TeamHierarchy(reportsTo: [
            "role1": "role2",
            "role2": "role3",
            "role3": "role1",
        ])

        XCTAssertFalse(cyclicHierarchy.doesReport("role1", to: "nonexistent"))
    }

    func testTeamHierarchy_BootstrapTeamHasHierarchy() {
        // First bootstrap team has hierarchy built from actual role IDs
        let firstTeam = Team.defaultTeams[0]
        XCTAssertFalse(firstTeam.settings.hierarchy.reportsTo.isEmpty)
    }

    // MARK: - RoleDependencies via SystemTemplates Tests

    func testSystemTemplateDependencies_Supervisor() {
        let deps = SystemTemplates.roles["supervisor"]!.dependencies
        XCTAssertTrue(deps.requiredArtifacts.isEmpty)
        XCTAssertEqual(deps.producesArtifacts, [SystemTemplates.supervisorTaskArtifactName])
    }

    func testSystemTemplateDependencies_ProductManager() {
        let deps = SystemTemplates.roles["productManager"]!.dependencies
        XCTAssertEqual(deps.requiredArtifacts, [SystemTemplates.supervisorTaskArtifactName])
        XCTAssertEqual(deps.producesArtifacts, ["Product Requirements"])
    }

    func testSystemTemplateDependencies_SoftwareEngineer() {
        let deps = SystemTemplates.roles["softwareEngineer"]!.dependencies
        XCTAssertEqual(deps.requiredArtifacts, ["Implementation Plan", "Design Spec"])
        XCTAssertEqual(deps.producesArtifacts, ["Engineering Notes", "Build Diagnostics"])
    }

    func testSystemTemplateDependencies_CustomRoleNotInTemplates() {
        XCTAssertNil(SystemTemplates.roles["myCustomRole"])
    }

    func testSystemTemplateDependencies_LoreMaster() {
        let deps = SystemTemplates.roles["loreMaster"]!.dependencies
        XCTAssertEqual(deps.requiredArtifacts, [SystemTemplates.supervisorTaskArtifactName])
        XCTAssertEqual(deps.producesArtifacts, ["World Compendium"])
    }

    func testSystemTemplateDependencies_NpcCreator() {
        let deps = SystemTemplates.roles["npcCreator"]!.dependencies
        XCTAssertEqual(deps.requiredArtifacts, ["World Compendium"])
        XCTAssertEqual(deps.producesArtifacts, ["NPC Compendium"])
    }

    func testSystemTemplateDependencies_EncounterArchitect() {
        let deps = SystemTemplates.roles["encounterArchitect"]!.dependencies
        XCTAssertEqual(Set(deps.requiredArtifacts), Set(["World Compendium", "NPC Compendium"]))
        XCTAssertEqual(deps.producesArtifacts, ["Encounter Guide"])
    }

    func testSystemTemplateDependencies_RulesArbiter() {
        let deps = SystemTemplates.roles["rulesArbiter"]!.dependencies
        XCTAssertEqual(deps.requiredArtifacts, ["NPC Compendium", "Encounter Guide"])
        XCTAssertEqual(deps.producesArtifacts, ["Balance Review"])
    }

    func testSystemTemplateDependencies_QuestMaster() {
        let deps = SystemTemplates.roles["questMaster"]!.dependencies
        XCTAssertEqual(
            Set(deps.requiredArtifacts),
            Set(["World Compendium", "NPC Compendium", "Encounter Guide", "Balance Review"])
        )
        XCTAssertEqual(deps.producesArtifacts, [])
    }

    // NOTE: LLM override tests have moved to TeamRoleDefinitionTests.swift
    // LLM overrides are now per-role (inside TeamRoleDefinition), not per-team.

    // MARK: - AcceptanceMode Tests

    func testAcceptanceMode_AllCases() {
        XCTAssertEqual(AcceptanceMode.allCases.count, 4)
        XCTAssertTrue(AcceptanceMode.allCases.contains(.afterEachArtifact))
        XCTAssertTrue(AcceptanceMode.allCases.contains(.afterEachRole))
        XCTAssertTrue(AcceptanceMode.allCases.contains(.finalOnly))
        XCTAssertTrue(AcceptanceMode.allCases.contains(.customCheckpoints))
    }

    func testAcceptanceMode_DisplayName() {
        XCTAssertEqual(AcceptanceMode.afterEachArtifact.displayName, "After Each Artifact")
        XCTAssertEqual(AcceptanceMode.afterEachRole.displayName, "After Each Role")
        XCTAssertEqual(AcceptanceMode.finalOnly.displayName, "Final Result Only")
        XCTAssertEqual(AcceptanceMode.customCheckpoints.displayName, "Custom Checkpoints")
    }

    func testAcceptanceMode_Description() {
        XCTAssertFalse(AcceptanceMode.afterEachArtifact.description.isEmpty)
        XCTAssertFalse(AcceptanceMode.afterEachRole.description.isEmpty)
        XCTAssertFalse(AcceptanceMode.finalOnly.description.isEmpty)
        XCTAssertFalse(AcceptanceMode.customCheckpoints.description.isEmpty)
    }

    // MARK: - Hidden Role Tests

    func testTeamGraphLayout_HideRole() {
        var layout = TeamGraphLayout(
            nodePositions: [
                TeamNodePosition(roleID: "role1", x: 100, y: 100),
                TeamNodePosition(roleID: "role2", x: 200, y: 200),
            ]
        )

        layout.hideRole("role1")

        XCTAssertTrue(layout.hiddenRoleIDs.contains("role1"))
        XCTAssertNil(layout.position(for: "role1"))
        XCTAssertEqual(layout.nodePositions.count, 1)
    }

    func testTeamGraphLayout_ShowRole() {
        var layout = TeamGraphLayout(
            nodePositions: [TeamNodePosition(roleID: "role1", x: 100, y: 100)],
            hiddenRoleIDs: ["role2"]
        )

        layout.showRole("role2", at: CGPoint(x: 300, y: 300))

        XCTAssertFalse(layout.hiddenRoleIDs.contains("role2"))
        XCTAssertNotNil(layout.position(for: "role2"))
        XCTAssertEqual(layout.nodePositions.count, 2)
    }

    func testTeamGraphLayout_PruneHiddenRoles() {
        var layout = TeamGraphLayout(
            nodePositions: [],
            hiddenRoleIDs: ["role1", "role2", "deleted_role"]
        )

        layout.pruneHiddenRoles(existingRoleIDs: ["role1", "role2", "role3"])

        XCTAssertEqual(layout.hiddenRoleIDs, ["role1", "role2"])
    }

    func testTeamGraphLayout_HiddenRoleIDs_Codable_RoundTrip() throws {
        let original = TeamGraphLayout(
            nodePositions: [TeamNodePosition(roleID: "role1", x: 100, y: 100)],
            hiddenRoleIDs: ["role2", "role3"]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeamGraphLayout.self, from: encoded)

        XCTAssertEqual(decoded.hiddenRoleIDs, ["role2", "role3"])
    }

    func testTeamGraphLayout_HiddenRoleIDs_Codable_MissingKey_DefaultsToEmpty() throws {
        let json = """
            {
                "nodePositions": [{ "roleID": "role1", "x": 100, "y": 200 }]
            }
            """.data(using: .utf8)!

        let layout = try JSONDecoder().decode(TeamGraphLayout.self, from: json)

        XCTAssertTrue(layout.hiddenRoleIDs.isEmpty)
    }

    func testTeam_RemoveRole_CleansUpHiddenRoleIDs() {
        let role = TeamRoleDefinition(
            id: "role-to-delete",
            name: "Test",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        var team = Team(
            name: "Test",
            roles: [role],
            artifacts: [],
            settings: .default,
            graphLayout: TeamGraphLayout(hiddenRoleIDs: ["role-to-delete"])
        )

        team.removeRole("role-to-delete")

        XCTAssertFalse(team.graphLayout.hiddenRoleIDs.contains("role-to-delete"))
    }

    func testTeam_Duplicate_RemapsHiddenRoleIDs() {
        let role1 = TeamRoleDefinition(
            id: "test_role1",
            name: "Role1",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let role2 = TeamRoleDefinition(
            id: "test_role2",
            name: "Role2",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let original = Team(
            name: "Original",
            roles: [role1, role2],
            artifacts: [],
            settings: .default,
            graphLayout: TeamGraphLayout(
                nodePositions: [TeamNodePosition(roleID: role1.id, x: 100, y: 100)],
                hiddenRoleIDs: [role2.id]
            )
        )

        let duplicate = original.duplicate()

        XCTAssertEqual(duplicate.graphLayout.hiddenRoleIDs.count, 1)
        XCTAssertTrue(duplicate.graphLayout.hiddenRoleIDs.contains(duplicate.roles[1].id))
        XCTAssertFalse(duplicate.graphLayout.hiddenRoleIDs.contains(role2.id))
    }

    // MARK: - removeRole Settings Cleanup (Round 4 regression)

    func testTeam_RemoveRole_CleansUpSettingsReferences() {
        let roleA = TeamRoleDefinition(
            id: "test_role_a", name: "RoleA", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []))
        let roleB = TeamRoleDefinition(
            id: "test_role_b", name: "RoleB", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []))
        let roleC = TeamRoleDefinition(
            id: "test_role_c", name: "RoleC", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []))

        var team = Team(
            name: "Settings Cleanup Test",
            roles: [roleA, roleB, roleC],
            artifacts: [],
            settings: .default,
            graphLayout: TeamGraphLayout(
                nodePositions: [
                    TeamNodePosition(roleID: roleA.id, x: 0, y: 0),
                    TeamNodePosition(roleID: roleB.id, x: 100, y: 0),
                    TeamNodePosition(roleID: roleC.id, x: 200, y: 0),
                ]
            )
        )

        // Set up settings referencing roleB
        team.settings.hierarchy = TeamHierarchy(reportsTo: [
            roleA.id: roleB.id,
            roleB.id: roleC.id,
        ])
        team.settings.meetingCoordinatorRoleID = roleB.id
        team.settings.invitableRoles = [roleA.id, roleB.id]
        team.settings.acceptanceCheckpoints = [roleB.id]

        // Remove roleB
        team.removeRole(roleB.id)

        // hierarchy must not contain B as key or value
        XCTAssertNil(team.settings.hierarchy.reportsTo[roleB.id],
                     "Removed role should not be a key in hierarchy")
        XCTAssertFalse(team.settings.hierarchy.reportsTo.values.contains(roleB.id),
                       "Removed role should not be a value in hierarchy")
        // A→B was removed because B was deleted
        XCTAssertNil(team.settings.hierarchy.reportsTo[roleA.id],
                     "Subordinate of removed role should have its supervisor cleared")

        XCTAssertNil(team.settings.meetingCoordinatorRoleID,
                     "meetingCoordinatorRoleID should be nil after removing that role")
        XCTAssertFalse(team.settings.invitableRoles.contains(roleB.id),
                       "invitableRoles should not contain removed role")
        XCTAssertFalse(team.settings.acceptanceCheckpoints.contains(roleB.id),
                       "acceptanceCheckpoints should not contain removed role")
        XCTAssertFalse(team.graphLayout.nodePositions.contains(where: { $0.roleID == roleB.id }),
                       "nodePositions should not contain removed role")
    }

    // MARK: - duplicate() Settings Remap (Round 4 regression)

    func testTeam_Duplicate_RemapsSettingsRoleIDs() {
        let roleA = TeamRoleDefinition(
            id: "test_role_a", name: "RoleA", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []))
        let roleB = TeamRoleDefinition(
            id: "test_role_b", name: "RoleB", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []))

        let originalIDs = Set([roleA.id, roleB.id])

        var team = Team(
            name: "Remap Test",
            roles: [roleA, roleB],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
        team.settings.hierarchy = TeamHierarchy(reportsTo: [roleA.id: roleB.id])
        team.settings.meetingCoordinatorRoleID = roleA.id
        team.settings.invitableRoles = [roleA.id, roleB.id]
        team.settings.acceptanceCheckpoints = [roleB.id]

        let dup = team.duplicate()

        // All role IDs in duplicate should be new (not from original)
        let dupRoleIDs = Set(dup.roles.map(\.id))
        XCTAssertTrue(dupRoleIDs.isDisjoint(with: originalIDs),
                      "Duplicate role IDs must be new, not original")

        // hierarchy keys and values should be remapped
        for (sub, sup) in dup.settings.hierarchy.reportsTo {
            XCTAssertTrue(dupRoleIDs.contains(sub), "Hierarchy key should be a new role ID")
            XCTAssertTrue(dupRoleIDs.contains(sup), "Hierarchy value should be a new role ID")
            XCTAssertFalse(originalIDs.contains(sub), "Hierarchy key should not be an original ID")
            XCTAssertFalse(originalIDs.contains(sup), "Hierarchy value should not be an original ID")
        }

        // meetingCoordinatorRoleID should be remapped
        if let coord = dup.settings.meetingCoordinatorRoleID {
            XCTAssertTrue(dupRoleIDs.contains(coord), "Coordinator should be a new role ID")
            XCTAssertFalse(originalIDs.contains(coord), "Coordinator should not be original ID")
        } else {
            XCTFail("meetingCoordinatorRoleID should be set in duplicate")
        }

        // invitableRoles should be remapped
        XCTAssertEqual(dup.settings.invitableRoles.count, 2)
        for id in dup.settings.invitableRoles {
            XCTAssertTrue(dupRoleIDs.contains(id), "invitableRoles should use new IDs")
        }

        // acceptanceCheckpoints should be remapped
        XCTAssertEqual(dup.settings.acceptanceCheckpoints.count, 1)
        for id in dup.settings.acceptanceCheckpoints {
            XCTAssertTrue(dupRoleIDs.contains(id), "acceptanceCheckpoints should use new IDs")
        }

        // Structure preserved: hierarchy should still have exactly 1 entry
        XCTAssertEqual(dup.settings.hierarchy.reportsTo.count, 1)
    }

    // MARK: - findRole(byIdentifier:) (Round 2 regression)

    func testFindRoleByIdentifier_matchesById() {
        let customID = UUID().uuidString
        let role = TeamRoleDefinition(
            id: customID,
            name: "Backend Engineer",
            prompt: "Backend prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let team = Team(
            name: "Test",
            roles: [role],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )

        let found = team.findRole(byIdentifier: customID)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, customID)
    }

    func testFindRoleByIdentifier_matchesBySystemRoleID() {
        let role = TeamRoleDefinition(
            id: UUID().uuidString,
            name: "PM",
            prompt: "PM prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            systemRoleID: "productManager"
        )
        let team = Team(
            name: "Test",
            roles: [role],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )

        let found = team.findRole(byIdentifier: "productManager")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "PM")
    }

    func testFindRoleByIdentifier_matchesByNameCaseInsensitive() {
        let role = TeamRoleDefinition(
            id: UUID().uuidString,
            name: "Tech Lead",
            prompt: "TL prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let team = Team(
            name: "Test",
            roles: [role],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )

        let found = team.findRole(byIdentifier: "tech lead")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Tech Lead")
    }

    func testFindRoleByIdentifier_returnsNilForUnknown() {
        let role = TeamRoleDefinition(
            id: UUID().uuidString,
            name: "Engineer",
            prompt: "Eng prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let team = Team(
            name: "Test",
            roles: [role],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )

        XCTAssertNil(team.findRole(byIdentifier: "nonexistent"))
    }

    // MARK: - rolesProducing / rolesRequiring (Round 3)

    func testRolesProducingAndRequiring() {
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Plan"])
        )
        let swe = TeamRoleDefinition(
            id: "swe", name: "SWE", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Plan"], producesArtifacts: ["Code"])
        )
        let reviewer = TeamRoleDefinition(
            id: "rev", name: "Reviewer", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Code"], producesArtifacts: [])
        )
        let team = Team(name: "T", roles: [pm, swe, reviewer], artifacts: [], settings: .default, graphLayout: .default)

        XCTAssertEqual(team.rolesProducing(artifactName: "Plan").count, 1)
        XCTAssertEqual(team.rolesProducing(artifactName: "Plan").first?.id, "pm")
        XCTAssertEqual(team.rolesRequiring(artifactName: "Plan").count, 1)
        XCTAssertEqual(team.rolesRequiring(artifactName: "Plan").first?.id, "swe")
        XCTAssertTrue(team.rolesProducing(artifactName: "Unknown").isEmpty)
    }

    // MARK: - makeStep (Round 3)

    func testMakeStep_createsStepForValidRoleID() {
        let role = TeamRoleDefinition(
            id: "eng-1", name: "Engineer", prompt: "Build things", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Report"])
        )
        let team = Team(name: "T", roles: [role], artifacts: [], settings: .default, graphLayout: .default)

        let step = team.makeStep(forRoleID: "eng-1")
        XCTAssertNotNil(step)
        XCTAssertEqual(step?.id, "eng-1")
        XCTAssertEqual(step?.expectedArtifacts, ["Report"])
        XCTAssertEqual(step?.status, .pending)
    }

    func testMakeStep_returnsNilForUnknownRoleID() {
        let role = TeamRoleDefinition(
            id: "eng-1", name: "Engineer", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let team = Team(name: "T", roles: [role], artifacts: [], settings: .default, graphLayout: .default)

        XCTAssertNil(team.makeStep(forRoleID: "nonexistent"))
    }

    // MARK: - TeamSettings.remappingRoleIDs Tests

    func testRemappingRoleIDs_emptyMapping_returnsIdentical() {
        let settings = TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: ["child": "parent"]),
            meetingCoordinatorRoleID: "coord",
            invitableRoles: ["role-a", "role-b"],
            acceptanceCheckpoints: ["role-c"]
        )

        let result = settings.remappingRoleIDs([:])

        XCTAssertEqual(result.hierarchy.reportsTo, ["child": "parent"])
        XCTAssertEqual(result.meetingCoordinatorRoleID, "coord")
        XCTAssertEqual(result.invitableRoles, ["role-a", "role-b"])
        XCTAssertEqual(result.acceptanceCheckpoints, ["role-c"])
    }

    func testRemappingRoleIDs_fullMapping_remapsAll() {
        let settings = TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: ["old-child": "old-parent"]),
            meetingCoordinatorRoleID: "old-coord",
            invitableRoles: ["old-a", "old-b"],
            acceptanceCheckpoints: ["old-c"]
        )

        let mapping = [
            "old-child": "new-child",
            "old-parent": "new-parent",
            "old-coord": "new-coord",
            "old-a": "new-a",
            "old-b": "new-b",
            "old-c": "new-c",
        ]

        let result = settings.remappingRoleIDs(mapping)

        XCTAssertEqual(result.hierarchy.reportsTo, ["new-child": "new-parent"])
        XCTAssertEqual(result.meetingCoordinatorRoleID, "new-coord")
        XCTAssertEqual(result.invitableRoles, ["new-a", "new-b"])
        XCTAssertEqual(result.acceptanceCheckpoints, ["new-c"])
    }

    func testRemappingRoleIDs_partialMapping_preservesUnmapped() {
        let settings = TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: ["mapped": "unmapped"]),
            meetingCoordinatorRoleID: "unmapped-coord",
            invitableRoles: ["mapped", "unmapped"],
            acceptanceCheckpoints: ["unmapped"]
        )

        let result = settings.remappingRoleIDs(["mapped": "new-mapped"])

        XCTAssertEqual(result.hierarchy.reportsTo, ["new-mapped": "unmapped"])
        XCTAssertEqual(result.meetingCoordinatorRoleID, "unmapped-coord")
        XCTAssertTrue(result.invitableRoles.contains("new-mapped"))
        XCTAssertTrue(result.invitableRoles.contains("unmapped"))
        XCTAssertEqual(result.acceptanceCheckpoints, ["unmapped"])
    }

    func testRemappingRoleIDs_nilCoordinator_staysNil() {
        let settings = TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: [:]),
            meetingCoordinatorRoleID: nil
        )

        let result = settings.remappingRoleIDs(["any": "other"])

        XCTAssertNil(result.meetingCoordinatorRoleID)
    }

    func testRemappingRoleIDs_hierarchyBothKeysAndValues() {
        // Verify that both children (keys) and parents (values) are remapped
        let settings = TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: [
                "eng": "lead",
                "lead": "supervisor",
            ])
        )

        let mapping = ["eng": "new-eng", "lead": "new-lead", "supervisor": "new-sup"]
        let result = settings.remappingRoleIDs(mapping)

        XCTAssertEqual(result.hierarchy.reportsTo["new-eng"], "new-lead")
        XCTAssertEqual(result.hierarchy.reportsTo["new-lead"], "new-sup")
        XCTAssertEqual(result.hierarchy.reportsTo.count, 2)
    }

    func testRemappingRoleIDs_preservesNonIDFields() {
        let settings = TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: ["a": "b"]),
            meetingCoordinatorRoleID: "a",
            invitableRoles: ["a"],
            supervisorCanBeInvited: true,
            limits: .default,
            defaultAcceptanceMode: .finalOnly,
            acceptanceCheckpoints: ["a"],
            supervisorMode: .autonomous
        )

        let result = settings.remappingRoleIDs(["a": "x", "b": "y"])

        XCTAssertTrue(result.supervisorCanBeInvited)
        XCTAssertEqual(result.defaultAcceptanceMode, .finalOnly)
        XCTAssertEqual(result.supervisorMode, .autonomous)
    }
}
