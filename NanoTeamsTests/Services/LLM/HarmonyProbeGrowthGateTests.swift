import XCTest

@testable import NanoTeams

/// Pins `HarmonyProbeGrowthGate`'s contract: first probe exactly at the second
/// close marker (today's detection point, unchanged), then geometric re-probes
/// only — the amortized-linear bound is the reason the gate exists.
final class HarmonyProbeGrowthGateTests: XCTestCase {

    func testFirstProbe_firesExactlyAtSecondClose() {
        var gate = HarmonyProbeGrowthGate()
        gate.noteDelta(count: 500)
        gate.noteClose()
        XCTAssertFalse(gate.probeIsDue(), "one close — dedup impossible by definition")
        gate.noteDelta(count: 500)
        gate.noteClose()
        XCTAssertTrue(gate.probeIsDue(), "second close is the first possible duplicate")
    }

    /// The anti-quadratic pin: a close marker with negligible growth since the
    /// last probe must NOT re-probe — per-close whole-buffer parses were the
    /// O(segments × buffer) defect.
    func testCloseWithoutGrowth_doesNotReprobe() {
        var gate = HarmonyProbeGrowthGate()
        gate.noteDelta(count: 10_000)
        gate.noteClose()
        gate.noteClose()
        XCTAssertTrue(gate.probeIsDue())
        gate.noteDelta(count: 100) // 1% growth
        gate.noteClose()
        XCTAssertFalse(gate.probeIsDue(), "third close, no meaningful growth — not due")
    }

    func testGrowthByHalf_reprobes() {
        var gate = HarmonyProbeGrowthGate()
        gate.noteDelta(count: 1_000)
        gate.noteClose()
        gate.noteClose()
        XCTAssertTrue(gate.probeIsDue())
        // One extra close only (3 < 2×2), so the growth criterion is isolated
        // from the closes-doubling one.
        gate.noteDelta(count: 499)
        gate.noteClose()
        XCTAssertFalse(gate.probeIsDue(), "just under ×1.5, closes not doubled")
        gate.noteDelta(count: 1)
        XCTAssertTrue(gate.probeIsDue(), "exactly ×1.5 re-probes on growth alone")
    }

    /// Many tiny identical envelopes grow bytes slowly but closes fast — the
    /// 56-call reply probes at closes 2, 4, 8, 16 … and is caught early.
    func testClosesDoubling_reprobesWithoutByteGrowth() {
        var gate = HarmonyProbeGrowthGate()
        gate.noteDelta(count: 200)
        var probesAtCloses: [Int] = []
        for close in 1...16 {
            gate.noteClose()
            if gate.probeIsDue() { probesAtCloses.append(close) }
        }
        XCTAssertEqual(probesAtCloses, [2, 4, 8, 16])
    }

    func testSeed_adoptionWithTwoCloses_isImmediatelyDue() {
        var gate = HarmonyProbeGrowthGate()
        gate.seed(adoptedLength: 4_000, closes: 2)
        XCTAssertTrue(gate.probeIsDue())
    }

    func testSeed_singleClose_notDue() {
        var gate = HarmonyProbeGrowthGate()
        gate.seed(adoptedLength: 4_000, closes: 1)
        XCTAssertFalse(gate.probeIsDue())
    }

    /// The amortized bound itself: for a geometrically growing stream, the sum
    /// of buffer lengths at probe time — the total parse work — stays under
    /// 3 × the final length. Per-close probing would sum to ~N²/2c.
    func testTotalProbedWork_isAmortizedLinear() {
        var gate = HarmonyProbeGrowthGate()
        var probedWork = 0
        let deltaSize = 400
        let rounds = 500
        for _ in 0..<rounds {
            gate.noteDelta(count: deltaSize)
            gate.noteClose()
            if gate.probeIsDue() { probedWork += gate.runningLength }
        }
        let finalLength = deltaSize * rounds
        XCTAssertLessThanOrEqual(probedWork, 3 * finalLength,
                                 "geometric re-probing must keep total parse work ≤ 3× the stream")
    }
}
