import Foundation

/// Decides *when* the in-stream loop scan is allowed to run, from delta sizes
/// alone — never from re-counting the accumulated buffers.
///
/// The spelling it replaced computed
/// `thinkingCollected.count + assistantCollected.count` on every stream event:
/// `String.count` is O(graphemes), both buffers only grow, so the cadence
/// *check* itself cost O(buffer) per delta — quadratic across the stream — and
/// the throttle could not save it, because the count WAS the throttle's input
/// (found by `coverage/tools/algorithmic_complexity.py`, axis a5). This gate
/// mirrors the combined length instead: appends report their delta size
/// (O(delta), totalling O(stream)), the one truncation site reports the
/// before/after pair, and the arithmetic is byte-for-byte the old one —
/// fire when growth since the last `advance()` reaches the cadence, hold
/// (keep firing) while the caller declines to advance, stay closed while a
/// shrink leaves the mirror below the last advance point.
nonisolated struct StreamScanCadenceGate {

    /// Mirror of the combined buffer length, maintained from deltas.
    private var mirroredLength = 0
    /// `mirroredLength` at the last `advance()` — the old `lastLoopScanLen`.
    private var lastScanLength = 0
    private let cadence: Int

    init(cadence: Int) {
        self.cadence = cadence
    }

    /// A buffer grew by `count` characters (`+=` sites).
    mutating func noteDelta(count: Int) {
        mirroredLength += count
    }

    /// A buffer was REPLACED (marker adoption truncates `assistantCollected`).
    /// Keeps the mirror exact through the one non-append mutation; the two
    /// `count` reads at that call site run once per stream, not per delta.
    mutating func noteReplacement(oldCount: Int, newCount: Int) {
        mirroredLength += newCount - oldCount
    }

    /// The old `combinedLen - lastLoopScanLen >= cadence`, verbatim.
    var shouldScan: Bool {
        mirroredLength - lastScanLength >= cadence
    }

    /// Close the window — the caller ran (or deliberately swallowed) a scan.
    /// NOT advancing after a scan is the I4 hold: the gate keeps firing so the
    /// signal is re-offered until the parent awaiter registers.
    mutating func advance() {
        lastScanLength = mirroredLength
    }
}
