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

    // MARK: - headlineParts (pluralization: noun + verb agree in number)

    /// Single pending task → singular noun AND singular verb: "1 task needs you".
    /// Regression: the masthead previously hardcoded "tasks"/"need" → "1 tasks need you".
    func testHeadlineParts_oneTask_isSingular() {
        let parts = WatchtowerHeader.headlineParts(needsYouCount: 1)
        XCTAssertEqual(parts.prefix, "1 task ")
        XCTAssertEqual(parts.accent, "needs you")
        XCTAssertEqual(parts.prefix + parts.accent, "1 task needs you")
    }

    /// Multiple pending tasks → plural noun AND plural verb: "3 tasks need you".
    func testHeadlineParts_manyTasks_isPlural() {
        let parts = WatchtowerHeader.headlineParts(needsYouCount: 3)
        XCTAssertEqual(parts.prefix, "3 tasks ")
        XCTAssertEqual(parts.accent, "need you")
        XCTAssertEqual(parts.prefix + parts.accent, "3 tasks need you")
    }

    /// Boundary: exactly 2 is plural (only 1 is singular).
    func testHeadlineParts_twoTasks_isPlural() {
        let parts = WatchtowerHeader.headlineParts(needsYouCount: 2)
        XCTAssertEqual(parts.prefix, "2 tasks ")
        XCTAssertEqual(parts.accent, "need you")
    }

    /// Empty inbox → no count prefix, resting "all clear" phrase (no cursor target).
    func testHeadlineParts_emptyInbox_isAllClear() {
        let parts = WatchtowerHeader.headlineParts(needsYouCount: 0)
        XCTAssertEqual(parts.prefix, "")
        XCTAssertEqual(parts.accent, "all clear")
    }

    /// Defensive: a negative count (unreachable in practice) is treated as empty,
    /// not as a malformed "−1 tasks" headline.
    func testHeadlineParts_negativeCount_isAllClear() {
        let parts = WatchtowerHeader.headlineParts(needsYouCount: -1)
        XCTAssertEqual(parts.prefix, "")
        XCTAssertEqual(parts.accent, "all clear")
    }
}
