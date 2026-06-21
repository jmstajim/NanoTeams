import XCTest
@testable import NanoTeams

/// Branch coverage for the "Switch Team" menu gate. The team-switch menu
/// re-exposes `store.switchTeam(to:)`, whose only prior UI caller (the
/// activity-feed `teamHeaderMenu`) was removed in the navbar redesign — leaving
/// the orchestrator method + `TeamSwitchPlanner` orphaned. This pins the
/// conditions under which the menu re-appears.
final class TeamSwitchMenuGatingTests: XCTestCase {

    private func offer(
        autovisor: Bool = false,
        historical: Bool = false,
        managedSingleton: Bool = false,
        teams: Int = 3
    ) -> Bool {
        TeamBoardView.shouldOfferTeamSwitch(
            isAutovisorBoard: autovisor,
            isHistoricalRun: historical,
            activeTeamIsManagedSingleton: managedSingleton,
            selectableTeamCount: teams
        )
    }

    func testOffered_whenLiveTaskWithMultipleTeams() {
        XCTAssertTrue(offer())
    }

    func testHidden_onAutovisorBoard() {
        XCTAssertFalse(offer(autovisor: true))
    }

    func testHidden_onHistoricalRun() {
        XCTAssertFalse(offer(historical: true))
    }

    func testHidden_forManagedSingletonTeam() {
        XCTAssertFalse(offer(managedSingleton: true))
    }

    func testHidden_whenOnlyOneSelectableTeam() {
        // Switching needs an alternative — a single team is a redundant no-op.
        XCTAssertFalse(offer(teams: 1))
    }

    func testHidden_whenNoSelectableTeams() {
        XCTAssertFalse(offer(teams: 0))
    }

    func testOffered_atExactlyTwoTeams_boundary() {
        XCTAssertTrue(offer(teams: 2))
    }
}
