import XCTest
@testable import NanoTeams

/// Tests the pure blink-gating policy of `WatchtowerHeader`. `shouldBlink` is
/// `nonisolated static`, so this suite needs no `@MainActor` and constructs no
/// view — sidestepping the sync-test main-actor abort gotcha (CLAUDE.md).
final class WatchtowerHeaderTests: XCTestCase {

    // MARK: - shouldBlink (finding #5: no forever-ticking TimelineView with nothing to animate)

    /// Motion allowed + pending work → blink (mount the `TimelineView`).
    func testShouldBlink_motionAllowedWithTasks_isTrue() {
        XCTAssertTrue(WatchtowerHeader.shouldBlink(reduceMotion: false, hasTasks: true))
    }

    /// Reduce Motion → static (steady) cursor, no blink — the `TimelineView` (and
    /// its forever 0.55s ticks) must not be mounted.
    func testShouldBlink_reduceMotion_isFalse() {
        XCTAssertFalse(WatchtowerHeader.shouldBlink(reduceMotion: true, hasTasks: true))
    }

    /// Empty inbox → no cursor is rendered at all, so no blink.
    func testShouldBlink_emptyInbox_isFalse() {
        XCTAssertFalse(WatchtowerHeader.shouldBlink(reduceMotion: false, hasTasks: false))
    }

    /// Both conditions failing → still no blink (no double-negative resurrection).
    func testShouldBlink_reduceMotionAndEmptyInbox_isFalse() {
        XCTAssertFalse(WatchtowerHeader.shouldBlink(reduceMotion: true, hasTasks: false))
    }
}
