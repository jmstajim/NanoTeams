import XCTest

@testable import NanoTeams

/// Pins `StreamProbeGate`'s `.geometric` cadence — the Harmony probe's contract: first probe exactly at the second
/// close marker (today's detection point, unchanged), then geometric re-probes
/// only — the amortized-linear bound is the reason the gate exists.
final class StreamProbeGateGeometricCadenceTests: XCTestCase {

    func testFirstProbe_firesExactlyAtSecondClose() {
        var gate = StreamProbeGate(cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 2))
        gate.noteDelta(count: 500)
        gate.noteUnit()
        XCTAssertFalse(gate.probeIsDue(), "one close — dedup impossible by definition")
        gate.noteDelta(count: 500)
        gate.noteUnit()
        XCTAssertTrue(gate.probeIsDue(), "second close is the first possible duplicate")
    }

    /// The anti-quadratic pin: a close marker with negligible growth since the
    /// last probe must NOT re-probe — per-close whole-buffer parses were the
    /// O(segments × buffer) defect.
    func testCloseWithoutGrowth_doesNotReprobe() {
        var gate = StreamProbeGate(cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 2))
        gate.noteDelta(count: 10_000)
        gate.noteUnit()
        gate.noteUnit()
        XCTAssertTrue(gate.probeIsDue())
        gate.noteDelta(count: 100) // 1% growth
        gate.noteUnit()
        XCTAssertFalse(gate.probeIsDue(), "third close, no meaningful growth — not due")
    }

    func testGrowthByHalf_reprobes() {
        var gate = StreamProbeGate(cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 2))
        gate.noteDelta(count: 1_000)
        gate.noteUnit()
        gate.noteUnit()
        XCTAssertTrue(gate.probeIsDue())
        // One extra close only (3 < 2×2), so the growth criterion is isolated
        // from the closes-doubling one.
        gate.noteDelta(count: 499)
        gate.noteUnit()
        XCTAssertFalse(gate.probeIsDue(), "just under ×1.5, closes not doubled")
        gate.noteDelta(count: 1)
        XCTAssertTrue(gate.probeIsDue(), "exactly ×1.5 re-probes on growth alone")
    }

    /// Many tiny identical envelopes grow bytes slowly but closes fast — the
    /// 56-call reply probes at closes 2, 4, 8, 16 … and is caught early.
    func testClosesDoubling_reprobesWithoutByteGrowth() {
        var gate = StreamProbeGate(cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 2))
        gate.noteDelta(count: 200)
        var probesAtCloses: [Int] = []
        for close in 1...16 {
            gate.noteUnit()
            if gate.probeIsDue() { probesAtCloses.append(close) }
        }
        XCTAssertEqual(probesAtCloses, [2, 4, 8, 16])
    }

    func testSeed_adoptionWithTwoCloses_isImmediatelyDue() {
        var gate = StreamProbeGate(cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 2))
        gate.seed(adoptedLength: 4_000, units: 2)
        XCTAssertTrue(gate.probeIsDue())
    }

    func testSeed_singleClose_notDue() {
        var gate = StreamProbeGate(cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 2))
        gate.seed(adoptedLength: 4_000, units: 1)
        XCTAssertFalse(gate.probeIsDue())
    }

    /// The amortized bound itself: for a geometrically growing stream, the sum
    /// of buffer lengths at probe time — the total parse work — stays under
    /// 3 × the final length. Per-close probing would sum to ~N²/2c.
    func testTotalProbedWork_isAmortizedLinear() {
        var gate = StreamProbeGate(cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 2))
        var probedWork = 0
        let deltaSize = 400
        let rounds = 500
        for _ in 0..<rounds {
            gate.noteDelta(count: deltaSize)
            gate.noteUnit()
            if gate.probeIsDue() { probedWork += gate.runningLength }
        }
        let finalLength = deltaSize * rounds
        XCTAssertLessThanOrEqual(probedWork, 3 * finalLength,
                                 "geometric re-probing must keep total parse work ≤ 3× the stream")
    }
}

/// Equivalence vectors: the unified gate must decide EXACTLY what the two types
/// it replaced decided, on the same input sequence.
///
/// Asserted against reference implementations of the old arithmetic rather than
/// against remembered behaviour — a refactor of a hot streaming path is only
/// safe if "same decisions" is a measurement, not a claim (CLAUDE.md #96). The
/// oracles below are the retired `StreamScanCadenceGate.shouldScan` and
/// `HarmonyProbeGrowthGate.probeIsDue()` bodies, transcribed.
final class StreamProbeGateEquivalenceTests: XCTestCase {

    /// The retired `StreamScanCadenceGate`, verbatim.
    private struct ArithmeticOracle {
        var mirroredLength = 0
        var lastScanLength = 0
        let cadence: Int
        mutating func noteDelta(count: Int) { mirroredLength += count }
        mutating func noteReplacement(oldCount: Int, newCount: Int) {
            mirroredLength += newCount - oldCount
        }
        var shouldScan: Bool { mirroredLength - lastScanLength >= cadence }
        mutating func advance() { lastScanLength = mirroredLength }
    }

    /// The retired `HarmonyProbeGrowthGate`, verbatim.
    private struct GeometricOracle {
        var runningLength = 0
        var closeCount = 0
        var lengthAtLastProbe: Int?
        var closesAtLastProbe = 0
        mutating func noteDelta(count: Int) { runningLength += count }
        mutating func noteClose() { closeCount += 1 }
        mutating func seed(adoptedLength: Int, closes: Int) {
            runningLength = adoptedLength
            closeCount = closes
        }
        mutating func probeIsDue() -> Bool {
            guard closeCount >= 2 else { return false }
            if let last = lengthAtLastProbe {
                guard runningLength * 2 >= last * 3 || closeCount >= closesAtLastProbe * 2
                else { return false }
            }
            lengthAtLastProbe = runningLength
            closesAtLastProbe = closeCount
            return true
        }
    }

    /// Deterministic pseudo-random deltas — no `Math.random`, so a failure is
    /// reproducible from the seed printed in the message.
    private func deltas(seed: UInt64, count: Int) -> [Int] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33) % 97
        }
    }

    func testArithmeticCadence_agreesWithTheRetiredGate_overRandomStreams() {
        for seed in [1 as UInt64, 7, 42, 1_337, 99_991] {
            var gate = StreamProbeGate(cadence: .everyChars(400))
            var oracle = ArithmeticOracle(cadence: 400)
            for (i, delta) in deltas(seed: seed, count: 800).enumerated() {
                gate.noteDelta(count: delta)
                oracle.noteDelta(count: delta)
                XCTAssertEqual(gate.isDue, oracle.shouldScan,
                               "seed \(seed) step \(i): decisions diverged")
                // Advance on two thirds of the fires — exercises the HOLD, where
                // the caller deliberately declines to record.
                if gate.isDue && i % 3 != 0 {
                    gate.recordProbe()
                    oracle.advance()
                }
                if i == 400 {
                    gate.noteReplacement(oldCount: 5_000, newCount: 120)
                    oracle.noteReplacement(oldCount: 5_000, newCount: 120)
                }
            }
        }
    }

    func testGeometricCadence_agreesWithTheRetiredGate_overRandomStreams() {
        for seed in [3 as UInt64, 11, 64, 2_027, 777_777] {
            var gate = StreamProbeGate(
                cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 2))
            var oracle = GeometricOracle()
            for (i, delta) in deltas(seed: seed, count: 800).enumerated() {
                gate.noteDelta(count: delta)
                oracle.noteDelta(count: delta)
                if i % 5 == 0 {
                    gate.noteUnit()
                    oracle.noteClose()
                }
                if i == 300 {
                    gate.seed(adoptedLength: 4_096, units: 3)
                    oracle.seed(adoptedLength: 4_096, closes: 3)
                }
                XCTAssertEqual(gate.probeIsDue(), oracle.probeIsDue(),
                               "seed \(seed) step \(i): decisions diverged")
            }
        }
    }

    /// Anti-vacuum: the two oracles must DISAGREE with each other on this input,
    /// or "matches its oracle" would be satisfied by any gate that matched both.
    func testTheTwoCadencesAreActuallyDifferentPolicies() {
        var arithmetic = StreamProbeGate(cadence: .everyChars(400))
        var geometric = StreamProbeGate(
            cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 0))
        var divergences = 0
        for _ in 0..<200 {
            arithmetic.noteDelta(count: 100)
            geometric.noteDelta(count: 100)
            let a = arithmetic.isDue
            let g = geometric.isDue
            if a != g { divergences += 1 }
            if a { arithmetic.recordProbe() }
            if g { geometric.recordProbe() }
        }
        XCTAssertGreaterThan(divergences, 0,
                             "the two cadences must be distinguishable, or the case name "
                                 + "carries no information")
    }

    /// The reason the tool-delta gate moved to `.geometric`: an arithmetic
    /// cadence in front of a probe that re-reads the accumulator sums to
    /// Θ(A²/cadence), while geometric spacing is amortized linear.
    func testGeometricBoundsTotalProbeWork_whereArithmeticDoesNot() {
        func totalProbedBytes(_ cadence: StreamProbeCadence) -> Int {
            var gate = StreamProbeGate(cadence: cadence)
            var work = 0
            for _ in 0..<2_000 {
                gate.noteDelta(count: 50)
                if gate.probeIsDue() { work += gate.runningLength }
            }
            return work
        }
        let finalLength = 2_000 * 50
        let geometric = totalProbedBytes(
            .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 0))
        let arithmetic = totalProbedBytes(.everyChars(400))

        XCTAssertLessThan(geometric, finalLength * 4,
                          "geometric spacing must keep Σ probe work within a small "
                              + "multiple of the final buffer: \(geometric) vs \(finalLength)")
        XCTAssertGreaterThan(arithmetic, finalLength * 50,
                             "control: the arithmetic cadence really is quadratic here — "
                                 + "otherwise this test proves nothing about the change")
    }
}
