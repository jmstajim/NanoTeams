import Foundation

// MARK: - ScrollFollowState

/// The activity feed's bottom-follow bookkeeping: the last scroll-to-bottom target, the last
/// measured distance from the bottom, the settle burst, and the two pending tasks.
///
/// **A plain reference held in `@State` — not four `@State` values, and not observable.**
/// No body reads any of these; the scroll-geometry action writes them on every geometry tick.
/// As `@State` each such write scheduled a SwiftUI transaction on the window whether or not
/// anything read it — on the 2026-09-15 trace of an idle run, `@State` writes
/// (`StoredLocationBase.beginUpdate`) accounted for 440 ms of dirty-propagation in 10 s, these
/// among them. Mutating a class's stored property schedules nothing.
///
/// The one write that must reach SwiftUI — `ScrollPosition.scrollTo` — now happens only when
/// it moves something (`settleScroll`), for the same reason.
@MainActor
final class ScrollFollowState {

    /// A departure from the bottom must last this long before follow releases.
    nonisolated static let gateReleaseDelayMs = 160
    /// The settle-scroll fires this long after the LAST geometry tick…
    nonisolated static let scrollSettleQuietMs = 70
    /// …but never later than this after the burst began, so continuous streaming still follows.
    nonisolated static let scrollSettleMaxWaitMs = 220
    /// Within this of the bottom the feed is already there; a scroll would move nothing.
    nonisolated static let settledDistance: CGFloat = 0.5

    /// The `y` to feed `scrollTo(y:)` so the feed lands at the bottom; nil until a geometry tick
    /// of the CURRENT task has run.
    var lastBottomTargetY: CGFloat?
    /// The corrected distance from the bottom at the last geometry tick.
    var lastDistanceFromBottom: CGFloat?
    var settleBurstStart: Date?
    var scrollSettleTask: Task<Void, Never>?
    var gateReleaseTask: Task<Void, Never>?

    /// What a settle-scroll does when it fires.
    enum SettleScroll: Equatable {
        case toY(CGFloat)
        /// No target stashed yet (fresh task switch): edge-scroll rather than apply a stale one.
        case toBottomEdge
    }

    /// Milliseconds until a settle-scroll requested at `now` fires, for a burst that began at
    /// `burstStart`: `scrollSettleQuietMs` after this request, capped at `scrollSettleMaxWaitMs`
    /// after the burst's start, never negative.
    ///
    /// Rounded, not truncated: a `Date` difference of 20 ms comes back as 0.019999… s, and the
    /// truncating `Int(…)` the feed view used to inline turned it into 19.
    nonisolated static func settleDelayMs(now: Date, burstStart: Date) -> Int {
        let quietFireAt = now.addingTimeInterval(Double(scrollSettleQuietMs) / 1000)
        let maxFireAt = burstStart.addingTimeInterval(Double(scrollSettleMaxWaitMs) / 1000)
        return Int(max(0, min(quietFireAt, maxFireAt).timeIntervalSince(now) * 1000).rounded())
    }

    /// The decision at fire time. Not pinned → nothing. No target → the edge. Already within
    /// `settledDistance` of the bottom → nothing, because the write itself is a transaction and a
    /// scroll commit. Otherwise the exact target — including the `insTop` undershoot case, whose
    /// distance is the full top inset and so always scrolls.
    nonisolated static func settleScroll(
        isNearBottom: Bool,
        bottomTargetY: CGFloat?,
        distanceFromBottom: CGFloat?
    ) -> SettleScroll? {
        guard isNearBottom else { return nil }
        guard let bottomTargetY else { return .toBottomEdge }
        if let distanceFromBottom, abs(distanceFromBottom) <= settledDistance { return nil }
        return .toY(bottomTargetY)
    }

    /// Cancels both pending tasks and ends the burst. Keeps the stashed geometry — it still
    /// describes this task's feed.
    func cancelPending() {
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        gateReleaseTask?.cancel()
        // Cleared, not just cancelled: a cancelled task returns before it clears itself, and a
        // non-nil handle blocks the geometry action from ever scheduling the next release.
        gateReleaseTask = nil
        settleBurstStart = nil
    }

    /// Task switch: everything, including the geometry — a target stashed from the previous
    /// task's feed must never be applied to the next one.
    func resetForTaskSwitch() {
        cancelPending()
        lastBottomTargetY = nil
        lastDistanceFromBottom = nil
    }
}
