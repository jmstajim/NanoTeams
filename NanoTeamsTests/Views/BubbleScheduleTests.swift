import XCTest
import SwiftUI
@testable import NanoTeams

/// Pins the `BubbleSchedule` contract — periodic while streaming,
/// one-shot post-commit. The whole point of the custom schedule (vs
/// `.periodic`) is the post-commit branch: committed bubbles must NOT
/// pay a per-bubble timer heartbeat for the lifetime of the view, or
/// every committed bubble runs `MessageBubbleView` body re-evaluation
/// at 3.3Hz forever.
///
/// A future refactor that "simplifies" to plain `.periodic` for both
/// branches re-introduces that regression silently — these tests are
/// the only guard against it.
@MainActor
final class BubbleScheduleTests: XCTestCase {

    typealias BubbleSchedule = TeamActivityFeedView.BubbleSchedule

    // MARK: - Committed branch — emit-once-then-terminate

    /// The load-bearing assertion: a committed schedule's iterator
    /// emits the start date once and then returns nil. TimelineView
    /// uses this to schedule no further wake-ups.
    func testCommittedSchedule_emitsExactlyOneEntry_thenTerminates() async {
        let schedule = BubbleSchedule(isStreaming: false, streamingInterval: 0.3)
        let start = Date(timeIntervalSince1970: 1_000)
        var iter = schedule.entries(from: start, mode: .normal).makeIterator()
        XCTAssertEqual(iter.next(), start, "Committed schedule must emit exactly the start date.")
        XCTAssertNil(iter.next(), "Committed schedule must terminate after one entry — no timer heartbeat post-commit.")
        XCTAssertNil(iter.next(), "Repeated next() after termination stays nil.")
    }

    /// Parallel pin under `.lowFrequency` mode (low-power / occluded
    /// window). The committed branch ignores `mode` and behaves the
    /// same — emit-once-then-terminate.
    func testCommittedSchedule_underLowFrequency_stillEmitsOnce() async {
        let schedule = BubbleSchedule(isStreaming: false, streamingInterval: 0.3)
        let start = Date()
        var iter = schedule.entries(from: start, mode: .lowFrequency).makeIterator()
        XCTAssertNotNil(iter.next())
        XCTAssertNil(iter.next())
    }

    // MARK: - Streaming branch — periodic forever

    func testStreamingSchedule_emitsAtIntervalForever() async {
        let schedule = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        let start = Date(timeIntervalSince1970: 1_000)
        var iter = schedule.entries(from: start, mode: .normal).makeIterator()
        let first = iter.next()
        let second = iter.next()
        let fifth = (0..<3).reduce(into: nil as Date?) { acc, _ in acc = iter.next() }

        XCTAssertEqual(first, start, "First streaming entry must be at start date.")
        XCTAssertEqual(second?.timeIntervalSince(start) ?? 0, 0.3, accuracy: 1e-6,
                       "Second entry must be one interval after start.")
        XCTAssertEqual(fifth?.timeIntervalSince(start) ?? 0, 1.2, accuracy: 1e-6,
                       "Fifth entry (4th interval) must be at 4×interval.")
    }

    /// Streaming iterator never terminates. Pull a thousand entries to
    /// catch the regression where a future "off-by-one" stops the
    /// stream prematurely.
    func testStreamingSchedule_neverTerminates() async {
        let schedule = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        var iter = schedule.entries(from: Date(), mode: .normal).makeIterator()
        for _ in 0..<1_000 {
            XCTAssertNotNil(iter.next(), "Streaming schedule must not terminate.")
        }
    }

    /// `streamingInterval` is forwarded verbatim — pinned so a future
    /// refactor doesn't hardcode 0.3 inside the schedule and ignore the
    /// caller's reduce-motion 1.0s.
    func testStreamingInterval_honorsCallerSuppliedValue() async {
        let schedule = BubbleSchedule(isStreaming: true, streamingInterval: 1.0)
        let start = Date(timeIntervalSince1970: 1_000)
        var iter = schedule.entries(from: start, mode: .normal).makeIterator()
        _ = iter.next()
        let second = iter.next()
        XCTAssertEqual(second?.timeIntervalSince(start) ?? 0, 1.0, accuracy: 1e-6,
                       "Streaming interval must match caller-supplied value (1.0s under reduce-motion).")
    }

    /// `mode: .lowFrequency` is the low-power / occluded-window hint.
    /// The streaming branch ignores it — a future refactor that throttled
    /// streaming under low power would silently degrade UX during long
    /// generations on battery. Pin so the regression surfaces.
    func testStreamingSchedule_underLowFrequency_emitsAtSameInterval() async {
        let schedule = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        let start = Date(timeIntervalSince1970: 1_000)
        var iter = schedule.entries(from: start, mode: .lowFrequency).makeIterator()
        _ = iter.next()
        let second = iter.next()
        XCTAssertEqual(second?.timeIntervalSince(start) ?? 0, 0.3, accuracy: 1e-6,
                       "Low-frequency mode must NOT throttle streaming — interval stays at caller-supplied value.")
    }

    // MARK: - Equatable / Hashable identity

    /// SwiftUI's view diff fast-path uses `Equatable` to short-circuit
    /// re-evaluation when properties haven't changed. Pin that two
    /// schedules with identical fields compare equal so the diff fires.
    func testSchedule_equalFields_compareEqual() async {
        let a = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        let b = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        XCTAssertEqual(a, b)
    }

    func testSchedule_differentIsStreaming_compareNotEqual() async {
        let streaming = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        let committed = BubbleSchedule(isStreaming: false, streamingInterval: 0.3)
        XCTAssertNotEqual(streaming, committed)
    }
}
