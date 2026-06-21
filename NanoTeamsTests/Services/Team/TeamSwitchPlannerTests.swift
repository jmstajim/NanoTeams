import XCTest

@testable import NanoTeams

/// Corner / boundary coverage for the pure team-switch decisions extracted from
/// `NTMSOrchestrator.switchTeam`. Pure value-in/value-out — no orchestrator, snapshot,
/// or engine.
final class TeamSwitchPlannerTests: XCTestCase {

    private func team(templateID: String? = nil) -> Team {
        Team(name: "T", templateID: templateID, roles: [], artifacts: [], settings: .default, graphLayout: .default)
    }

    private func step(roleID: String) -> StepExecution {
        StepExecution(id: roleID, role: .custom(id: roleID), title: "")
    }

    // MARK: - canSwitchTeam

    func testCanSwitch_activeIsAutovisor_blocked() {
        XCTAssertFalse(TeamSwitchPlanner.canSwitchTeam(activeTaskID: 5, autovisorTaskID: 5, target: team()))
    }

    func testCanSwitch_activeIsNotAutovisor_allowed() {
        XCTAssertTrue(TeamSwitchPlanner.canSwitchTeam(activeTaskID: 5, autovisorTaskID: 9, target: team()))
    }

    func testCanSwitch_bothIDsNil_notBlocked() {
        // The unwrap-before-compare invariant: a bare `==` would be true when both are
        // nil and wrongly block every switch on a fresh work folder.
        XCTAssertTrue(TeamSwitchPlanner.canSwitchTeam(activeTaskID: nil, autovisorTaskID: nil, target: team()))
    }

    func testCanSwitch_activeNilManagerPinned_notBlocked() {
        XCTAssertTrue(TeamSwitchPlanner.canSwitchTeam(activeTaskID: nil, autovisorTaskID: 5, target: team()))
    }

    func testCanSwitch_targetIsManagedSingleton_blocked() {
        let autovisorTeam = team(templateID: AutovisorConstants.teamTemplateID)
        XCTAssertFalse(TeamSwitchPlanner.canSwitchTeam(activeTaskID: 5, autovisorTaskID: 9, target: autovisorTeam))
    }

    func testCanSwitch_bothReasons_blocked() {
        let autovisorTeam = team(templateID: AutovisorConstants.teamTemplateID)
        XCTAssertFalse(TeamSwitchPlanner.canSwitchTeam(activeTaskID: 5, autovisorTaskID: 5, target: autovisorTeam))
    }

    // MARK: - filteredSteps

    func testFilteredSteps_fullOverlap_unchanged() {
        let steps = [step(roleID: "a"), step(roleID: "b")]
        let kept = TeamSwitchPlanner.filteredSteps(steps, forTeamRoleIDs: ["a", "b", "c"])
        XCTAssertEqual(kept.map(\.effectiveRoleID), ["a", "b"])
    }

    func testFilteredSteps_noOverlap_allDropped() {
        let steps = [step(roleID: "a"), step(roleID: "b")]
        XCTAssertTrue(TeamSwitchPlanner.filteredSteps(steps, forTeamRoleIDs: ["x", "y"]).isEmpty)
    }

    func testFilteredSteps_emptyTeam_allDropped() {
        let steps = [step(roleID: "a")]
        XCTAssertTrue(TeamSwitchPlanner.filteredSteps(steps, forTeamRoleIDs: []).isEmpty)
    }

    func testFilteredSteps_partialOverlap_keepsOnlyMembers() {
        let steps = [step(roleID: "a"), step(roleID: "b"), step(roleID: "c")]
        let kept = TeamSwitchPlanner.filteredSteps(steps, forTeamRoleIDs: ["a", "c"])
        XCTAssertEqual(kept.map(\.effectiveRoleID), ["a", "c"])
    }

    func testFilteredSteps_emptySteps_returnsEmpty() {
        XCTAssertTrue(TeamSwitchPlanner.filteredSteps([], forTeamRoleIDs: ["a"]).isEmpty)
    }

    func testFilteredSteps_duplicateRoleIDs_keepsBothWhenMember() {
        // Two steps sharing a role id (collision across runs/restarts) both survive if
        // the role is in the new roster — the planner filters, never dedups.
        let steps = [step(roleID: "a"), step(roleID: "a"), step(roleID: "b")]
        let kept = TeamSwitchPlanner.filteredSteps(steps, forTeamRoleIDs: ["a"])
        XCTAssertEqual(kept.map(\.effectiveRoleID), ["a", "a"])
    }
}
