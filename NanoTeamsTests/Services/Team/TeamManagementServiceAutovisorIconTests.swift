import XCTest
@testable import NanoTeams

/// Pins `TeamManagementService.syncAutovisorTeamToTemplate` — the pure helper behind
/// the open-time migration that keeps the hidden Autovisor team's template invariants
/// (Manager role icon + mandatory tools + Auto meeting coordinator) in lock-step with
/// the template (the parts the user never customizes). Extracted from `ensureAutovisorTask`
/// so the matching + idempotency logic is unit-testable without starting the engine.
final class TeamManagementServiceAutovisorIconTests: XCTestCase {

    /// The single source of truth for the Manager role's icon — sourced from the
    /// template so this test never hardcodes the literal and tracks future renames.
    private var templateIcon: String {
        SystemTemplates.roles[AutovisorConstants.managerRoleSystemID]?.icon ?? ""
    }

    private func managerRoleIcon(in team: Team) -> String? {
        team.roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.icon
    }

    /// A Autovisor team whose Manager role still carries the pre-rename icon,
    /// simulating a team persisted by an older build.
    private func staleManagerTeam() -> Team {
        var team = TeamTemplateFactory.autovisor()
        let idx = team.roles.firstIndex { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }
        if let idx { team.roles[idx].icon = "slider.horizontal.3" }
        return team
    }

    func testSync_updatesStaleIconToTemplate() {
        XCTAssertFalse(templateIcon.isEmpty, "fixture precondition: template defines a Manager role icon")
        var teams = [staleManagerTeam()]
        XCTAssertEqual(managerRoleIcon(in: teams[0]), "slider.horizontal.3", "fixture precondition")

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertTrue(changed, "a stale icon must report a change so the diff-based persist fires")
        XCTAssertEqual(managerRoleIcon(in: teams[0]), templateIcon)
    }

    func testSync_isNoopWhenAlreadyMatchesTemplate() {
        // A freshly-built team already carries the template icon.
        var teams = [TeamTemplateFactory.autovisor()]
        let before = managerRoleIcon(in: teams[0])
        XCTAssertEqual(before, templateIcon, "fixture precondition")

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertFalse(changed, "no change → no write (idempotent)")
        XCTAssertEqual(managerRoleIcon(in: teams[0]), before)
    }

    func testFactory_managerToolset_includesAnalyzeImage() {
        let team = TeamTemplateFactory.autovisor()
        let mgr = team.roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }
        XCTAssertTrue(mgr?.toolIDs.contains(ToolNames.analyzeImage) ?? false,
                      "the Autovisor role's default toolset includes analyze_image")
    }

    func testSync_unionEnforcesMissingMandatoryTool() {
        var team = TeamTemplateFactory.autovisor()
        // Simulate a team persisted by an older build missing a mandatory management tool.
        if let idx = team.roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
            team.roles[idx].toolIDs.removeAll { $0 == ToolNames.listTasks }
        }
        var teams = [team]

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertTrue(changed, "a missing mandatory tool must report a change so the persist fires")
        let mgr = teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }
        XCTAssertTrue(mgr?.toolIDs.contains(ToolNames.listTasks) ?? false,
                      "mandatory management tools are union-enforced")
    }

    func testSync_doesNotRevertRemovedOptionalTool() {
        var team = TeamTemplateFactory.autovisor()
        // The user toggled off analyze_image (optional, default-on) — must NOT be re-added.
        if let idx = team.roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
            team.roles[idx].toolIDs.removeAll { $0 == ToolNames.analyzeImage }
        }
        var teams = [team]

        _ = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        let mgr = teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }
        XCTAssertFalse(mgr?.toolIDs.contains(ToolNames.analyzeImage) ?? true,
                       "optional tools the user switched off are preserved (additive sync is mandatory-only)")
    }

    func testFactory_coordinatorIsAuto() {
        let team = TeamTemplateFactory.autovisor()
        XCTAssertNil(team.settings.meetingCoordinatorRoleID,
                     "the Autovisor team defaults to Auto (nil) coordinator")
    }

    func testSync_normalizesNonAutoCoordinatorToNil() {
        var team = TeamTemplateFactory.autovisor()
        // Simulate a team persisted by an older build that pinned the Manager role.
        team.settings.meetingCoordinatorRoleID = team.roles.first {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        }?.id
        XCTAssertNotNil(team.settings.meetingCoordinatorRoleID, "fixture precondition")
        var teams = [team]

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertTrue(changed, "a non-Auto coordinator must report a change so the persist fires")
        XCTAssertNil(teams[0].settings.meetingCoordinatorRoleID, "coordinator normalized to Auto")
    }

    func testSync_isNoopWithoutAutovisorTeam() {
        // Bundled defaults never include the hidden Autovisor team.
        var teams = Team.defaultTeams
        XCTAssertFalse(teams.contains { $0.templateID == AutovisorConstants.teamTemplateID },
                       "fixture precondition: no Autovisor team present")

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertFalse(changed)
    }
}
