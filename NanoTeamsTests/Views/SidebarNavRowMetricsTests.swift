import XCTest
@testable import NanoTeams

/// Pins the shared trailing-⋯ alignment geometry (finding #6). `@MainActor` because
/// `SidebarNavRowMetrics` is MainActor-isolated; only static-constant reads here, so
/// no instance is constructed and the sync-test main-actor abort gotcha doesn't bite.
@MainActor
final class SidebarNavRowMetricsTests: XCTestCase {

    /// The alignment invariant: the Autovisor nav row reaches the trailing ⋯ inset
    /// as `chromeHInset + autovisorMenuNudge`, while the work-folder card pads to
    /// `menuTrailingInset` directly — these MUST be equal or the two ⋯ menus drift
    /// apart. This used to be a hand-tuned 8 + 4 = 12 coincidence across two files.
    func testMenuAlignmentInvariant() {
        XCTAssertEqual(
            SidebarNavRowMetrics.chromeHInset + SidebarNavRowMetrics.autovisorMenuNudge,
            SidebarNavRowMetrics.menuTrailingInset,
            accuracy: 0.0001,
            "Autovisor ⋯ (chromeHInset + nudge) must land at the card's menuTrailingInset")
    }

    /// The nudge is DERIVED from the inset difference, not an independent magic
    /// number — changing either inset keeps it in sync automatically.
    func testNudgeIsDerivedFromInsetDifference() {
        XCTAssertEqual(
            SidebarNavRowMetrics.autovisorMenuNudge,
            SidebarNavRowMetrics.menuTrailingInset - SidebarNavRowMetrics.chromeHInset,
            accuracy: 0.0001)
    }

    /// Concrete pixel values (8 / 12 / 4) — pins the no-pixel-change refactor so a
    /// token swap becomes a deliberate, test-visible decision rather than silent drift.
    func testConcreteValues() {
        XCTAssertEqual(SidebarNavRowMetrics.chromeHInset, 8, accuracy: 0.0001)
        XCTAssertEqual(SidebarNavRowMetrics.menuTrailingInset, 12, accuracy: 0.0001)
        XCTAssertEqual(SidebarNavRowMetrics.autovisorMenuNudge, 4, accuracy: 0.0001)
    }
}
