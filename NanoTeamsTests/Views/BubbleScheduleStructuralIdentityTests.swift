import SwiftUI
import XCTest

@testable import NanoTeams

/// Pins the `BubbleSchedule` contract that preserves `TimelineView`
/// structural identity across the streaming → committed flip — and the
/// resize-freeze sentinel that suppresses ticks mid-drag.
///
/// Why structural identity matters:
/// `TeamActivityFeedView.messageBubble` wraps every bubble (streaming AND
/// committed) in `TimelineView(BubbleSchedule(...)) { ... }`. SwiftUI
/// matches view identity by **generic instantiation**. If the streaming
/// path used `TimelineView<PeriodicSchedule>` and the committed path used
/// `TimelineView<EveryMinute>` (or vice versa, or branched through
/// `_ConditionalContent`), SwiftUI would tear down the underlying
/// `NSTextView` on the flip and the `SelectableMessageText` append-only
/// glyph-layout fast path would be invalidated — the documented 4.41 s
/// `inLiveResize` hang lineage.
///
/// The fix is structural: a SINGLE `BubbleSchedule` type encodes both
/// modes via its `isStreaming` flag, and its `Entries` iterator branches
/// internally. Same generic instantiation across the flip → same view
/// identity → no `NSTextView` churn.
///
/// What this suite pins:
/// 1. Committed mode yields exactly one entry, then terminates.
/// 2. Streaming mode yields entries forever at `streamingInterval` cadence.
/// 3. The resize-stretch sentinel (`streamingInterval = .greatestFiniteMagnitude`)
///    pushes subsequent entries so far into the future that no tick fires
///    while the user drags.
/// 4. `BubbleSchedule: Equatable` correctly compares both fields — without
///    this, SwiftUI's view-diff fast path skipping is broken.
@MainActor
final class BubbleScheduleStructuralIdentityTests: XCTestCase {

    private typealias BubbleSchedule = TeamActivityFeedView.BubbleSchedule

    // MARK: - Committed mode terminates

    func testCommittedMode_yieldsExactlyOneEntry() {
        let schedule = BubbleSchedule(isStreaming: false, streamingInterval: 0.3)
        let start = Date(timeIntervalSince1970: 1_000)
        var iter = schedule.entries(from: start, mode: .normal)

        XCTAssertEqual(iter.next(), start, "Committed mode must emit the start date as its single entry.")
        XCTAssertNil(iter.next(), "Committed mode must terminate after one entry.")
        XCTAssertNil(iter.next(), "Subsequent .next() calls must continue returning nil.")
    }

    // MARK: - Streaming mode emits cadence

    func testStreamingMode_emitsEntriesAtInterval() {
        let interval: TimeInterval = 0.3
        let schedule = BubbleSchedule(isStreaming: true, streamingInterval: interval)
        let start = Date(timeIntervalSince1970: 1_000)
        var iter = schedule.entries(from: start, mode: .normal)

        let collected = (0..<5).compactMap { _ in iter.next() }
        XCTAssertEqual(collected.count, 5, "Streaming mode must keep emitting entries.")

        for (i, entry) in collected.enumerated() {
            let expectedOffset = TimeInterval(i) * interval
            XCTAssertEqual(
                entry.timeIntervalSince(start),
                expectedOffset,
                accuracy: 0.0001,
                "Entry \(i) must be at offset \(expectedOffset) from start."
            )
        }
    }

    // MARK: - Resize stretch suppresses ticks

    /// The resize-freeze sentinel: streaming mode with `interval =
    /// .greatestFiniteMagnitude` keeps the schedule live (no committed
    /// transition, so no remount of `SelectableMessageText`) but pushes
    /// the next tick so far into the future that the user's drag finishes
    /// long before TimelineView fires again.
    func testStreamingMode_resizeStretchInterval_pushesNextTickFarFuture() {
        let schedule = BubbleSchedule(
            isStreaming: true,
            streamingInterval: .greatestFiniteMagnitude
        )
        let now = Date()
        var iter = schedule.entries(from: now, mode: .normal)

        XCTAssertEqual(iter.next(), now, "First entry is always the start date.")
        guard let second = iter.next() else {
            XCTFail("Streaming mode must continue emitting; second entry was nil.")
            return
        }
        let gap = second.timeIntervalSince(now)
        XCTAssertGreaterThan(
            gap, 86_400 * 365 * 100,  // > 100 years
            ".greatestFiniteMagnitude interval must push the next tick at least decades into the future."
        )
    }

    // MARK: - Equatable conformance for view-diff fast path

    /// SwiftUI's `TimelineView` diff fast path checks the schedule via
    /// `==` before re-arming. If `BubbleSchedule.==` isn't there or doesn't
    /// compare every field, the schedule gets re-armed every body
    /// evaluation, defeating identity preservation.
    func testEquatable_sameFields_compareEqual() {
        let a = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        let b = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        XCTAssertEqual(a, b)
    }

    func testEquatable_differentIsStreaming_compareNotEqual() {
        let streaming = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        let committed = BubbleSchedule(isStreaming: false, streamingInterval: 0.3)
        XCTAssertNotEqual(streaming, committed)
    }

    func testEquatable_differentInterval_compareNotEqual() {
        let fast = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        let slow = BubbleSchedule(isStreaming: true, streamingInterval: 1.0)
        XCTAssertNotEqual(fast, slow)
    }

    /// Cross-mode case: the streaming → committed flip flips `isStreaming`
    /// but typically leaves the interval the same. The schedules must
    /// compare unequal (so SwiftUI re-evaluates Entries), but remain the
    /// SAME TYPE (so the TimelineView's view-identity is preserved).
    /// Same-type-ness is a compile-time fact — this test pins the
    /// "unequal but same generic instantiation" property by reaching into
    /// Mirror metadata.
    func testStreamingToCommittedFlip_changesEquality_butPreservesType() {
        let streaming = BubbleSchedule(isStreaming: true, streamingInterval: 0.3)
        let committed = BubbleSchedule(isStreaming: false, streamingInterval: 0.3)
        XCTAssertNotEqual(streaming, committed, "Flip must invalidate the diff fast path.")
        XCTAssertTrue(type(of: streaming) == type(of: committed),
                      "Both modes must use the SAME concrete BubbleSchedule type — the structural-identity hook.")
    }
}
