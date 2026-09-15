import XCTest

@testable import NanoTeams

/// Pins `LiveMessageBubble.pollInterval` — when a feed bubble looks at the streaming preview,
/// and how often.
///
/// Retargeted 2026-09-15 from `StreamingIntervalResolverTests`, which pinned the interval of the
/// `TimelineView` schedule every bubble used to sit in. Two rows changed meaning, deliberately:
/// - A committed message no longer has a schedule at all — it does not poll (`nil`), where the
///   timeline still hung every committed row off the graph's clock.
/// - A live resize used to stretch the interval to `.greatestFiniteMagnitude` so the timeline
///   kept its structural identity; the poll lives in a `.task` whose view never changes shape,
///   so "no ticks while dragging" is now simply `nil`.
final class LiveMessageBubblePollIntervalTests: XCTestCase {

    // MARK: - Committed messages never poll

    /// RED: return an interval for a committed message → every row of a long feed runs a
    /// sleep loop, and the bubbles that never change pay for the one that does.
    func testNotStreaming_neverPolls() {
        for resizing in [false, true] {
            for reduceMotion in [false, true] {
                XCTAssertNil(
                    LiveMessageBubble.pollInterval(isStreaming: false, isResizing: resizing, reduceMotion: reduceMotion),
                    "resizing=\(resizing), reduceMotion=\(reduceMotion)"
                )
            }
        }
    }

    // MARK: - Live resize freezes the poll

    /// Resize suppression is more aggressive than the Reduce-Motion slow-down: nothing polls
    /// mid-drag, so streaming churn never compounds the per-width re-measure.
    func testStreaming_whileResizing_doesNotPoll() {
        XCTAssertNil(LiveMessageBubble.pollInterval(isStreaming: true, isResizing: true, reduceMotion: false))
        XCTAssertNil(LiveMessageBubble.pollInterval(isStreaming: true, isResizing: true, reduceMotion: true))
    }

    // MARK: - Streaming cadence

    func testStreaming_default_pollsAtThreeHertz() {
        XCTAssertEqual(LiveMessageBubble.pollInterval(isStreaming: true, isResizing: false, reduceMotion: false), 0.3)
    }

    /// Reduce Motion gets 1 Hz — visible streaming progress without churn.
    func testStreaming_withReduceMotion_pollsAtOneHertz() {
        XCTAssertEqual(LiveMessageBubble.pollInterval(isStreaming: true, isResizing: false, reduceMotion: true), 1.0)
    }

    /// Sanity against a busy loop (0) or a negative sleep.
    func testEveryInterval_isAPositiveHeartbeat() {
        for reduceMotion in [false, true] {
            let interval = LiveMessageBubble.pollInterval(isStreaming: true, isResizing: false, reduceMotion: reduceMotion)
            XCTAssertGreaterThan(interval ?? 0, 0)
            XCTAssertLessThan(interval ?? .infinity, 10)
        }
    }
}
