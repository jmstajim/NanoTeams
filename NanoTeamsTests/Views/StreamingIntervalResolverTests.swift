import XCTest

@testable import NanoTeams

/// Pins the three-way truth table behind `BubbleSchedule.streamingInterval`
/// in `TeamActivityFeedView.messageBubble`. The resize-stretch (`isResizing
/// → .greatestFiniteMagnitude`) is load-bearing for the 4.41 s
/// `inLiveResize` hang fix: it preserves the `TimelineView`'s structural
/// identity (so `SelectableMessageText`'s `NSTextView` isn't remounted) but
/// suppresses tick generation while the user drags.
///
/// Reduce Motion gets a 1 Hz tick — visible-streaming-without-churn for
/// users with the accessibility preference enabled.
final class StreamingIntervalResolverTests: XCTestCase {

    // MARK: - Resize stretches the interval to effectively infinity

    func testResolve_whenResizing_returnsGreatestFiniteMagnitude() {
        XCTAssertEqual(
            TeamActivityFeedView.resolveStreamingInterval(isResizing: true, reduceMotion: false),
            .greatestFiniteMagnitude,
            "Resize must stretch the interval so no new ticks fire mid-drag."
        )
    }

    /// Reduce Motion does NOT trump the resize stretch — the resize-state
    /// suppression is more aggressive than the Reduce-Motion slow-down.
    func testResolve_whenResizingAndReduceMotion_stillReturnsGreatestFiniteMagnitude() {
        XCTAssertEqual(
            TeamActivityFeedView.resolveStreamingInterval(isResizing: true, reduceMotion: true),
            .greatestFiniteMagnitude
        )
    }

    // MARK: - Reduce Motion fallback

    func testResolve_whenReduceMotion_returnsSlowTick() {
        XCTAssertEqual(
            TeamActivityFeedView.resolveStreamingInterval(isResizing: false, reduceMotion: true),
            1.0,
            "Reduce Motion must throttle to 1 Hz."
        )
    }

    // MARK: - Default heartbeat

    func testResolve_default_returnsFastTick() {
        XCTAssertEqual(
            TeamActivityFeedView.resolveStreamingInterval(isResizing: false, reduceMotion: false),
            0.3,
            "Default streaming tick is 0.3s (≈3.3 Hz)."
        )
    }

    // MARK: - Continuity

    /// The resize branch must return a value the `TimelineView` accepts as
    /// a valid `TimeInterval` — finite or infinite is fine, but `nan`
    /// would break the schedule. `.greatestFiniteMagnitude` is finite by
    /// definition.
    func testResolve_resizeValue_isFinite() {
        let v = TeamActivityFeedView.resolveStreamingInterval(isResizing: true, reduceMotion: false)
        XCTAssertTrue(v.isFinite, "Resize sentinel must be finite (TimelineView contract).")
    }

    /// Non-resize branches return small positive intervals — sanity check
    /// against regressions that would set the heartbeat to 0 (busy-loop)
    /// or negative.
    func testResolve_normalBranches_returnPositiveIntervals() {
        for (resizing, reduce) in [(false, false), (false, true)] {
            let v = TeamActivityFeedView.resolveStreamingInterval(
                isResizing: resizing, reduceMotion: reduce
            )
            XCTAssertGreaterThan(v, 0, "Non-resize interval must be > 0.")
            XCTAssertLessThan(v, 10, "Non-resize interval must be a reasonable heartbeat (< 10 s).")
        }
    }
}
