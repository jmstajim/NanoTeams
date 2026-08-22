import XCTest

@testable import NanoTeams

/// Pins `StreamProbeGate`'s `.everyChars` cadence — the arithmetic gate that replaced the per-delta
/// `thinkingCollected.count + assistantCollected.count` in `scanForStreamLoop`
/// (`LLMExecutionService+Streaming`). The old spelling walked EVERY grapheme of
/// both accumulated buffers on every stream event to decide whether 400 new
/// characters had arrived — O(buffer) per delta, quadratic across the stream,
/// and the count itself was the throttle's input, so the throttle could not
/// save it. The gate mirrors the buffers' combined length from delta sizes
/// (O(delta) per event) and must reproduce the old arithmetic exactly:
/// fire when growth since the last advance reaches the cadence.
final class StreamProbeGateArithmeticCadenceTests: XCTestCase {

    func testDoesNotFireBelowCadence() {
        var gate = StreamProbeGate(cadence: .everyChars(400))
        gate.noteDelta(count: 399)
        XCTAssertFalse(gate.isDue)
    }

    func testFiresExactlyAtCadence() {
        // `>=` — the old code fired at `combinedLen - last >= cadence`.
        var gate = StreamProbeGate(cadence: .everyChars(400))
        gate.noteDelta(count: 400)
        XCTAssertTrue(gate.isDue)
    }

    func testAccumulatesAcrossSmallDeltas() {
        var gate = StreamProbeGate(cadence: .everyChars(400))
        for _ in 0..<399 { gate.noteDelta(count: 1) }
        XCTAssertFalse(gate.isDue)
        gate.noteDelta(count: 1)
        XCTAssertTrue(gate.isDue)
    }

    func testAdvanceOpensANewWindow() {
        var gate = StreamProbeGate(cadence: .everyChars(400))
        gate.noteDelta(count: 400)
        gate.recordProbe()
        XCTAssertFalse(gate.isDue)
        gate.noteDelta(count: 399)
        XCTAssertFalse(gate.isDue)
        gate.noteDelta(count: 1)
        XCTAssertTrue(gate.isDue)
    }

    /// The I4 hold: when `noteStreamLoop` reports no waiter, the caller does NOT
    /// advance — the gate must keep firing on the next event so the signal is
    /// re-offered until the parent awaiter registers.
    func testHoldWithoutAdvanceKeepsFiring() {
        var gate = StreamProbeGate(cadence: .everyChars(400))
        gate.noteDelta(count: 400)
        XCTAssertTrue(gate.isDue)
        gate.noteDelta(count: 0)
        XCTAssertTrue(gate.isDue)
        gate.noteDelta(count: 7)
        XCTAssertTrue(gate.isDue)
    }

    func testZeroDeltasNeverFire() {
        var gate = StreamProbeGate(cadence: .everyChars(400))
        for _ in 0..<10 { gate.noteDelta(count: 0) }
        XCTAssertFalse(gate.isDue)
    }

    func testZeroCadenceFiresImmediately() {
        // Degenerate but well-defined: growth of 0 satisfies `>= 0`.
        let gate = StreamProbeGate(cadence: .everyChars(0))
        XCTAssertTrue(gate.isDue)
    }

    /// Marker adoption truncates `assistantCollected` (`assistantCollected =
    /// preMarker`) — the mirrored length must follow the shrink, and a window
    /// that ends up BELOW the last advance stays closed until real regrowth,
    /// exactly as `combinedLen - lastLoopScanLen` went negative before.
    func testReplacementShrinkClosesTheWindow() {
        var gate = StreamProbeGate(cadence: .everyChars(400))
        gate.noteDelta(count: 1000)
        gate.recordProbe()
        gate.noteDelta(count: 100)
        gate.noteReplacement(oldCount: 1100, newCount: 50)
        XCTAssertFalse(gate.isDue)
        // Regrow: mirrored length is 50; last advance was at 1000, so the gate
        // reopens only at 1400 mirrored — 1350 more.
        gate.noteDelta(count: 1349)
        XCTAssertFalse(gate.isDue)
        gate.noteDelta(count: 1)
        XCTAssertTrue(gate.isDue)
    }

    func testReplacementGrowthCountsTowardTheWindow() {
        var gate = StreamProbeGate(cadence: .everyChars(400))
        gate.noteDelta(count: 100)
        gate.noteReplacement(oldCount: 100, newCount: 400)
        XCTAssertTrue(gate.isDue)
    }
}
