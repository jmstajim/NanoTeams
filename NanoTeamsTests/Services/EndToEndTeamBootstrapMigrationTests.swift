import XCTest

@testable import NanoTeams

/// E2E tests for team bootstrap and migration:
/// new project → default teams created, template structure validation.
@MainActor
final class EndToEndTeamBootstrapMigrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Bootstrap creates all default teams

    func testBootstrap_createsAllDefaultTeams() {
        let templates = TeamTemplateFactory.allTemplates

        // Should have at least FAANG, Startup, QuestParty, DiscussionClub
        XCTAssertGreaterThanOrEqual(templates.count, 4,
                                    "Should have at least 4 built-in templates")

        let templateIDs = Set(templates.compactMap(\.templateID))
        XCTAssertTrue(templateIDs.contains("faang"), "Should have FAANG template")
        XCTAssertTrue(templateIDs.contains("startup"), "Should have Startup template")
        XCTAssertTrue(templateIDs.contains("questParty"), "Should have Quest Party template")
        XCTAssertTrue(templateIDs.contains("discussionClub"), "Should have Discussion Club template")
    }

    // MARK: - Test 2: Each template has a supervisor

    func testBootstrap_eachTemplateHasSupervisor() {
        for team in TeamTemplateFactory.allTemplates {
            let hasSupervisor = team.roles.contains { $0.isSupervisor }
            XCTAssertTrue(hasSupervisor,
                          "Template '\(team.templateID ?? "unknown")' should have a supervisor role")
        }
    }

    // MARK: - Test 3: FAANG team has correct role structure

    func testBootstrap_faangTeam_hasCorrectRoles() {
        let faang = TeamTemplateFactory.faang()

        // FAANG should have key roles
        let hasPM = faang.roles.contains { $0.systemRoleID == "productManager" }
        XCTAssertTrue(hasPM, "FAANG should have Product Manager")

        let hasSWE = faang.roles.contains { $0.systemRoleID == "softwareEngineer" }
        XCTAssertTrue(hasSWE, "FAANG should have Software Engineer")

        let hasTL = faang.roles.contains { $0.systemRoleID == "techLead" }
        XCTAssertTrue(hasTL, "FAANG should have Tech Lead")
    }

    // MARK: - Test 4: Template creation is consistent

    func testBootstrap_templateCreation_consistent() {
        let team1 = TeamTemplateFactory.faang()
        let team2 = TeamTemplateFactory.faang()

        // Same number of roles and artifacts
        XCTAssertEqual(team1.roles.count, team2.roles.count, "Role count should be consistent")
        XCTAssertEqual(team1.artifacts.count, team2.artifacts.count, "Artifact count should be consistent")

        // Same template ID
        XCTAssertEqual(team1.templateID, team2.templateID)

        // Same role names (order may differ due to UUIDs)
        let names1 = Set(team1.roles.map(\.name))
        let names2 = Set(team2.roles.map(\.name))
        XCTAssertEqual(names1, names2, "Role names should be consistent")
    }

    // MARK: - Test 5: Startup team has minimal structure

    func testBootstrap_startupTeam_minimal() {
        let startup = TeamTemplateFactory.startup()

        // Startup should be minimal — Supervisor + SWE
        let nonSupervisorRoles = startup.roles.filter { !$0.isSupervisor }
        XCTAssertGreaterThanOrEqual(nonSupervisorRoles.count, 1,
                                    "Startup should have at least 1 non-supervisor role")

        // Should have SWE
        let hasSWE = startup.roles.contains { $0.systemRoleID == "softwareEngineer" }
        XCTAssertTrue(hasSWE, "Startup should have Software Engineer")
    }

    // MARK: - Test 6: Discussion Club has observer roles

    func testBootstrap_discussionClub_hasObservers() {
        let club = TeamTemplateFactory.discussionClub()

        // Discussion Club should have observer roles (no inputs AND no outputs)
        let observers = club.roles.filter { $0.isObserver }
        XCTAssertGreaterThan(observers.count, 0, "Discussion Club should have observer roles")
    }
}
