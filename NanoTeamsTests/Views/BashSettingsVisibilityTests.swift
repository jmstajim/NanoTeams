import XCTest

@testable import NanoTeams

/// Pins the relevance-gating of `BashSettingsView` sections per execution mode.
/// `Off` hides every policy section (judge, sandbox, rules); they are shown for
/// both `Manual` and `Auto`.
final class BashSettingsVisibilityTests: XCTestCase {

    func testPolicySections_shownForManualAndAuto_hiddenForOff() {
        XCTAssertFalse(BashSettingsVisibility.showsPolicySections(mode: .off))
        XCTAssertTrue(BashSettingsVisibility.showsPolicySections(mode: .manual))
        XCTAssertTrue(BashSettingsVisibility.showsPolicySections(mode: .auto))
    }
}
