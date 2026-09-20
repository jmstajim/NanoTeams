import XCTest

@testable import NanoTeams

/// The policy is two constants, and both are load-bearing: the ceiling decides how much the
/// warm-up asks the server to write, and the deadline is the only thing bounding a warm-up
/// against a model that never starts.
final class BenchmarkWarmUpPolicyTests: XCTestCase {

    /// A ceiling of one would be defensible — the model is loaded and the first decode step has
    /// compiled its graph — and a ceiling of thousands would not: at that point the warm-up is
    /// an answer again, and the deadline rather than the ceiling is what ends every run.
    ///
    /// RED: raise the constant to a "safer" larger number → silently reinstates the multi-minute
    /// warm-up this replaced (measured: 233 s, 12 040 tokens, on this very prompt).
    func testOutputCeiling_isASmallMargin_notAnAnswerLength() {
        XCTAssertGreaterThan(BenchmarkWarmUpPolicy.outputCeiling, 0)
        XCTAssertLessThanOrEqual(BenchmarkWarmUpPolicy.outputCeiling, 64)
    }

    /// The whole point of the 2026-09-20 change: the warm-up must be bounded far BELOW the
    /// measured workload, and by the same mechanism — a number on the wire.
    ///
    /// RED: set the warm-up's ceiling to `BenchmarkPrompt.outputCeiling` → the warm-up becomes a
    /// full measured sample that nothing reads, which is the cost the client-side stop existed to
    /// avoid and which this design has to keep avoiding without abandoning a generation.
    func testOutputCeiling_isFarBelowTheMeasuredWorkload() {
        XCTAssertLessThan(BenchmarkWarmUpPolicy.outputCeiling, BenchmarkPrompt.outputCeiling / 10)
    }

    /// The deadline exists to be short enough that a user notices nothing. RED: a deadline of
    /// minutes reads as a bound while bounding nothing a person would sit through.
    func testDeadline_isSecondsRatherThanMinutes() {
        XCTAssertGreaterThan(BenchmarkWarmUpPolicy.deadline, .seconds(1))
        XCTAssertLessThanOrEqual(BenchmarkWarmUpPolicy.deadline, .seconds(30))
    }

    /// The deadline has to cover a cold prefill of the benchmark prompt plus the ceiling's worth
    /// of decoding, or it fires on healthy runs and every warm-up records `.stoppedEarly`.
    ///
    /// The reading that matters is the COLD one, and it is not the typical one: measured on
    /// LM Studio 0.4.25 / `qwen3.8-27b-splash`, a warm-up against an idle model reported TTFT
    /// 9.29 s where the measured samples behind it reported 5.0–5.6 s. The warm-up is by
    /// definition the first request after idle, so it is the sample that pays that gap.
    ///
    /// RED: set the deadline against the warm figure (10 s was the shipped value until
    /// 2026-09-20) → it fires on a healthy run, the warm-up records `.stoppedEarly`, and the
    /// first measured sample pays the model load the warm-up existed to absorb.
    func testDeadline_clearsTheMeasuredColdWarmUp() {
        let measuredColdTimeToFirstToken = 9.29
        let decodeSeconds = Double(BenchmarkWarmUpPolicy.outputCeiling) / 35
        XCTAssertGreaterThan(
            BenchmarkWarmUpPolicy.deadline,
            .seconds(measuredColdTimeToFirstToken + decodeSeconds))
    }
}
