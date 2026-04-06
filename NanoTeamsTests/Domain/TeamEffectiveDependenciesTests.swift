import XCTest
@testable import NanoTeams

/// Tests that team roles have correct dependency configuration.
/// In the new architecture, dependencies are directly on TeamRoleDefinition - no more 3-tier resolution.
final class TeamRoleDependenciesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - FAANG Team (Default) Dependencies

    func testFAANGTeam_Supervisor_Dependencies() {
        let team = Team.default
        guard let supervisorRole = team.roles.first(where: \.isSupervisor) else {
            XCTFail("Supervisor role not found")
            return
        }

        XCTAssertEqual(supervisorRole.dependencies.requiredArtifacts, ["Release Notes"])
        XCTAssertEqual(supervisorRole.dependencies.producesArtifacts, [SystemTemplates.supervisorTaskArtifactName])
    }

    func testFAANGTeam_ProductManager_Dependencies() {
        let team = Team.default
        guard let pmRole = team.roles.first(where: { $0.systemRoleID == "productManager" }) else {
            XCTFail("Product Manager role not found")
            return
        }

        XCTAssertEqual(pmRole.dependencies.requiredArtifacts, [SystemTemplates.supervisorTaskArtifactName])
        XCTAssertEqual(pmRole.dependencies.producesArtifacts, ["Product Requirements"])
    }

    func testFAANGTeam_SoftwareEngineer_Dependencies() {
        let team = Team.default
        guard let sweRole = team.roles.first(where: { $0.systemRoleID == "softwareEngineer" }) else {
            XCTFail("Software Engineer role not found")
            return
        }

        XCTAssertEqual(sweRole.dependencies.requiredArtifacts, ["Implementation Plan", "Design Spec"])
        XCTAssertEqual(sweRole.dependencies.producesArtifacts, ["Engineering Notes", "Build Diagnostics"])
    }

    func testFAANGTeam_SRE_Dependencies() {
        let team = Team.default
        guard let sreRole = team.roles.first(where: { $0.systemRoleID == "sre" }) else {
            XCTFail("SRE role not found")
            return
        }

        XCTAssertEqual(sreRole.dependencies.requiredArtifacts, ["Engineering Notes"])
        XCTAssertEqual(Set(sreRole.dependencies.producesArtifacts), Set(["Production Readiness", "Production Readiness Summary"]))
    }

    // MARK: - Quest Party Team Dependencies

    func testQuestParty_Supervisor_Dependencies() {
        guard let questTeam = Team.defaultTeams.first(where: { $0.name == "Quest Party" }) else {
            XCTFail("Quest Party team not found in bootstrap defaults")
            return
        }

        guard let supervisorRole = questTeam.roles.first(where: \.isSupervisor) else {
            XCTFail("Supervisor role not found in Quest Party")
            return
        }

        XCTAssertEqual(supervisorRole.dependencies.requiredArtifacts, [])
        XCTAssertEqual(supervisorRole.dependencies.producesArtifacts, [SystemTemplates.supervisorTaskArtifactName])
    }

    func testQuestParty_LoreMaster_Dependencies() {
        guard let questTeam = Team.defaultTeams.first(where: { $0.name == "Quest Party" }) else {
            XCTFail("Quest Party team not found")
            return
        }

        guard let loreRole = questTeam.roles.first(where: { $0.systemRoleID == "loreMaster" }) else {
            XCTFail("Lore Master role not found")
            return
        }

        XCTAssertEqual(loreRole.dependencies.requiredArtifacts, [SystemTemplates.supervisorTaskArtifactName])
        XCTAssertEqual(loreRole.dependencies.producesArtifacts, ["World Compendium"])
    }

    func testQuestParty_QuestMaster_Dependencies() {
        guard let questTeam = Team.defaultTeams.first(where: { $0.name == "Quest Party" }) else {
            XCTFail("Quest Party team not found")
            return
        }

        guard let qmRole = questTeam.roles.first(where: { $0.systemRoleID == "questMaster" }) else {
            XCTFail("Quest Master role not found")
            return
        }

        XCTAssertEqual(
            Set(qmRole.dependencies.requiredArtifacts),
            Set(["World Compendium", "NPC Compendium", "Encounter Guide", "Balance Review"])
        )
        XCTAssertEqual(qmRole.dependencies.producesArtifacts, [])
    }

    // MARK: - Integration with ArtifactDependencyResolver

    func testReadyRoles_UsesRoleDependencies() {
        let team = Team.default
        let supervisorRoleID = team.roles.first(where: \.isSupervisor)!.id
        let pmRoleID = team.roles.first(where: { $0.systemRoleID == "productManager" })!.id

        // With Supervisor Task produced, PM should be ready
        let readyRoles = ArtifactDependencyResolver.findReadyRoles(
            roles: team.roles,
            producedArtifacts: [SystemTemplates.supervisorTaskArtifactName],
            excludeRoleIDs: [supervisorRoleID]
        )

        XCTAssertTrue(readyRoles.contains(pmRoleID))
    }

    func testDownstreamRoles_UsesRoleDependencies() {
        let team = Team.default
        let tlRoleID = team.roles.first(where: { $0.systemRoleID == "techLead" })!.id
        let sweRoleID = team.roles.first(where: { $0.systemRoleID == "softwareEngineer" })!.id

        // TL produces "Implementation Plan", which SWE needs
        let downstream = ArtifactDependencyResolver.getDownstreamRoles(
            of: tlRoleID,
            roles: team.roles
        )

        XCTAssertTrue(downstream.contains(sweRoleID))
    }

    // MARK: - Custom Team with Custom Dependencies

    func testCustomTeam_CustomRoleDependencies() {
        let customRole = TeamRoleDefinition(
            id: "customAnalyst",
            name: "Data Analyst",
            prompt: "Analyze data",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Product Requirements"],
                producesArtifacts: ["Data Analysis"]
            ),
            llmOverride: nil,
            isSystemRole: false,
            systemRoleID: nil,
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now()
        )

        let team = Team(
            id: "test_team_1",
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now(),
            name: "Custom Team",
            roles: [customRole],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )

        guard let role = team.roles.first(where: { $0.id == "customAnalyst" }) else {
            XCTFail("Custom role not found")
            return
        }

        XCTAssertEqual(role.dependencies.requiredArtifacts, ["Product Requirements"])
        XCTAssertEqual(role.dependencies.producesArtifacts, ["Data Analysis"])
    }

    // MARK: - Parallel Execution Test

    func testQuestParty_EncounterArchitect_WaitsForNpcCompendium() {
        guard let questTeam = Team.defaultTeams.first(where: { $0.name == "Quest Party" }) else {
            XCTFail("Quest Party team not found")
            return
        }

        let supervisorRoleID = questTeam.roles.first(where: \.isSupervisor)!.id
        let loreRoleID = questTeam.roles.first(where: { $0.systemRoleID == "loreMaster" })!.id
        let npcRoleID = questTeam.roles.first(where: { $0.systemRoleID == "npcCreator" })!.id
        let encounterRoleID = questTeam.roles.first(where: { $0.systemRoleID == "encounterArchitect" })!.id
        let rulesRoleID = questTeam.roles.first(where: { $0.systemRoleID == "rulesArbiter" })!.id
        let qmRoleID = questTeam.roles.first(where: { $0.systemRoleID == "questMaster" })!.id

        // After Lore Master completes, only NPC Creator is ready.
        // Encounter Architect requires both "World Compendium" AND "NPC Compendium",
        // so it must wait for NPC Creator to finish.
        let readyAfterLore = ArtifactDependencyResolver.findReadyRoles(
            roles: questTeam.roles,
            producedArtifacts: Set([SystemTemplates.supervisorTaskArtifactName, "World Compendium"]),
            excludeRoleIDs: Set([supervisorRoleID, loreRoleID])
        )

        XCTAssertTrue(readyAfterLore.contains(npcRoleID))
        XCTAssertFalse(readyAfterLore.contains(encounterRoleID),
                        "Encounter Architect must wait for NPC Compendium")
        XCTAssertFalse(readyAfterLore.contains(rulesRoleID))
        XCTAssertFalse(readyAfterLore.contains(qmRoleID))

        // After NPC Creator completes, Encounter Architect becomes ready
        let readyAfterNpc = ArtifactDependencyResolver.findReadyRoles(
            roles: questTeam.roles,
            producedArtifacts: Set([SystemTemplates.supervisorTaskArtifactName, "World Compendium", "NPC Compendium"]),
            excludeRoleIDs: Set([supervisorRoleID, loreRoleID, npcRoleID])
        )

        XCTAssertTrue(readyAfterNpc.contains(encounterRoleID),
                       "Encounter Architect ready after NPC Compendium is produced")
        XCTAssertFalse(readyAfterNpc.contains(rulesRoleID))
        XCTAssertFalse(readyAfterNpc.contains(qmRoleID))
    }

    // MARK: - Team Codable Round-Trip

    func testTeam_WithCustomRoleDependencies_CodableRoundTrip() throws {
        let customRole = TeamRoleDefinition(
            id: Role.builtInID(.sre),
            name: "SRE",
            prompt: "Test",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Implementation Plan", "Design Spec"],
                producesArtifacts: ["Test Plan", "Release Notes"]
            ),
            llmOverride: nil,
            isSystemRole: true,
            systemRoleID: Role.builtInID(.sre),
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now()
        )

        let original = Team(
            id: "test_team_2",
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now(),
            name: "Custom Team",
            roles: [customRole],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Team.self, from: encoded)

        XCTAssertEqual(decoded.roles.count, 1)

        guard let sreRole = decoded.roles.first(where: { $0.id == Role.builtInID(.sre) }) else {
            XCTFail("SRE role not found")
            return
        }

        XCTAssertEqual(sreRole.dependencies.requiredArtifacts, ["Implementation Plan", "Design Spec"])
        XCTAssertEqual(sreRole.dependencies.producesArtifacts, ["Test Plan", "Release Notes"])
    }
}
