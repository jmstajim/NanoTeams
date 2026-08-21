import XCTest

@testable import NanoTeams

/// Pins the running-length cadence gate that replaced the per-delta
/// `thinkingCollected.count + assistantCollected.count` in `scanForStreamLoop`
/// (`LLMExecutionService+Streaming`). The old spelling walked EVERY grapheme of
/// both accumulated buffers on every stream event to decide whether 400 new
/// characters had arrived — O(buffer) per delta, quadratic across the stream,
/// and the count itself was the throttle's input, so the throttle could not
/// save it. The gate mirrors the buffers' combined length from delta sizes
/// (O(delta) per event) and must reproduce the old arithmetic exactly:
/// fire when growth since the last advance reaches the cadence.
final class StreamScanCadenceGateTests: XCTestCase {

    func testDoesNotFireBelowCadence() {
        var gate = StreamScanCadenceGate(cadence: 400)
        gate.noteDelta(count: 399)
        XCTAssertFalse(gate.shouldScan)
    }

    func testFiresExactlyAtCadence() {
        // `>=` — the old code fired at `combinedLen - last >= cadence`.
        var gate = StreamScanCadenceGate(cadence: 400)
        gate.noteDelta(count: 400)
        XCTAssertTrue(gate.shouldScan)
    }

    func testAccumulatesAcrossSmallDeltas() {
        var gate = StreamScanCadenceGate(cadence: 400)
        for _ in 0..<399 { gate.noteDelta(count: 1) }
        XCTAssertFalse(gate.shouldScan)
        gate.noteDelta(count: 1)
        XCTAssertTrue(gate.shouldScan)
    }

    func testAdvanceOpensANewWindow() {
        var gate = StreamScanCadenceGate(cadence: 400)
        gate.noteDelta(count: 400)
        gate.advance()
        XCTAssertFalse(gate.shouldScan)
        gate.noteDelta(count: 399)
        XCTAssertFalse(gate.shouldScan)
        gate.noteDelta(count: 1)
        XCTAssertTrue(gate.shouldScan)
    }

    /// The I4 hold: when `noteStreamLoop` reports no waiter, the caller does NOT
    /// advance — the gate must keep firing on the next event so the signal is
    /// re-offered until the parent awaiter registers.
    func testHoldWithoutAdvanceKeepsFiring() {
        var gate = StreamScanCadenceGate(cadence: 400)
        gate.noteDelta(count: 400)
        XCTAssertTrue(gate.shouldScan)
        gate.noteDelta(count: 0)
        XCTAssertTrue(gate.shouldScan)
        gate.noteDelta(count: 7)
        XCTAssertTrue(gate.shouldScan)
    }

    func testZeroDeltasNeverFire() {
        var gate = StreamScanCadenceGate(cadence: 400)
        for _ in 0..<10 { gate.noteDelta(count: 0) }
        XCTAssertFalse(gate.shouldScan)
    }

    func testZeroCadenceFiresImmediately() {
        // Degenerate but well-defined: growth of 0 satisfies `>= 0`.
        let gate = StreamScanCadenceGate(cadence: 0)
        XCTAssertTrue(gate.shouldScan)
    }

    /// Marker adoption truncates `assistantCollected` (`assistantCollected =
    /// preMarker`) — the mirrored length must follow the shrink, and a window
    /// that ends up BELOW the last advance stays closed until real regrowth,
    /// exactly as `combinedLen - lastLoopScanLen` went negative before.
    func testReplacementShrinkClosesTheWindow() {
        var gate = StreamScanCadenceGate(cadence: 400)
        gate.noteDelta(count: 1000)
        gate.advance()
        gate.noteDelta(count: 100)
        gate.noteReplacement(oldCount: 1100, newCount: 50)
        XCTAssertFalse(gate.shouldScan)
        // Regrow: mirrored length is 50; last advance was at 1000, so the gate
        // reopens only at 1400 mirrored — 1350 more.
        gate.noteDelta(count: 1349)
        XCTAssertFalse(gate.shouldScan)
        gate.noteDelta(count: 1)
        XCTAssertTrue(gate.shouldScan)
    }

    func testReplacementGrowthCountsTowardTheWindow() {
        var gate = StreamScanCadenceGate(cadence: 400)
        gate.noteDelta(count: 100)
        gate.noteReplacement(oldCount: 100, newCount: 400)
        XCTAssertTrue(gate.shouldScan)
    }
}
