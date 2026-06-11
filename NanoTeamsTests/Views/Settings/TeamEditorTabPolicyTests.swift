import XCTest
@testable import NanoTeams

/// Pins the pure tab-visibility + strand-reset policy behind `TeamEditorView`.
/// The managed singleton (Autovisor) hides Artifacts; switching to it must not strand
/// the user on a now-hidden tab.
final class TeamEditorTabPolicyTests: XCTestCase {

    func testAvailableTabs_normalTeam_all() {
        XCTAssertEqual(TeamEditorTabPolicy.availableTabs(isManagedSingleton: false), EditorTab.allCases)
    }

    func testAvailableTabs_managedSingleton_hidesArtifacts_keepsRoles() {
        let tabs = TeamEditorTabPolicy.availableTabs(isManagedSingleton: true)
        XCTAssertEqual(tabs, [.team, .prompts, .roles])
        XCTAssertFalse(tabs.contains(.artifacts), "Artifacts hidden for the managed singleton")
        XCTAssertTrue(tabs.contains(.roles), "Roles kept (read-only)")
    }

    func testClamp_keepsSelectedWhenAvailable() {
        XCTAssertEqual(
            TeamEditorTabPolicy.clamp(.roles, available: [.team, .prompts, .roles]),
            .roles
        )
    }

    func testClamp_resetsToFirstWhenHidden() {
        // On Artifacts, then switch to Autovisor (Artifacts hidden) → reset to .team.
        XCTAssertEqual(
            TeamEditorTabPolicy.clamp(.artifacts, available: [.team, .prompts, .roles]),
            .team
        )
    }
}
