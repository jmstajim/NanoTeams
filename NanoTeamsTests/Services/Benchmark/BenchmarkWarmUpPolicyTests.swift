import XCTest

@testable import NanoTeams

/// The policy is two constants and a comparison, and every one of them is load-bearing: the
/// threshold decides when a warm-up stops, and the deadline is the only thing bounding a warm-up
/// against a model that never starts.
final class BenchmarkWarmUpPolicyTests: XCTestCase {

    /// RED: `>` instead of `>=` → the warm-up runs one delta past the policy every time, which no
    /// other assertion here would notice.
    func testIsSatisfied_atExactlyTheThreshold() {
        XCTAssertTrue(
            BenchmarkWarmUpPolicy.isSatisfied(
                deltaCount: BenchmarkWarmUpPolicy.sufficientDeltas))
    }

    func testIsSatisfied_belowTheThreshold() {
        XCTAssertFalse(
            BenchmarkWarmUpPolicy.isSatisfied(
                deltaCount: BenchmarkWarmUpPolicy.sufficientDeltas - 1))
    }

    /// The degenerate end: a stream that has produced nothing has warmed nothing. RED: a policy
    /// satisfied at zero would cut the warm-up before the model had even loaded, which is the one
    /// outcome that makes the FIRST measured sample pay for the load instead.
    func testIsSatisfied_isFalseBeforeAnyOutput() {
        XCTAssertFalse(BenchmarkWarmUpPolicy.isSatisfied(deltaCount: 0))
    }

    func testIsSatisfied_wellPastTheThreshold() {
        XCTAssertTrue(BenchmarkWarmUpPolicy.isSatisfied(deltaCount: 10_000))
    }

    /// A threshold of one would be defensible and a threshold of thousands would not: at that
    /// point the deadline, not the policy, is what ends every warm-up. RED: raise the constant to
    /// a "safer" larger number → silently reinstates the multi-minute warm-up this replaced.
    func testSufficientDeltas_isASmallMargin_notAnAnswerLength() {
        XCTAssertGreaterThan(BenchmarkWarmUpPolicy.sufficientDeltas, 0)
        XCTAssertLessThanOrEqual(BenchmarkWarmUpPolicy.sufficientDeltas, 64)
    }

    /// The ceiling exists to be short enough that a user notices nothing. RED: a deadline of
    /// minutes reads as a bound while bounding nothing a person would sit through.
    func testDeadline_isSecondsRatherThanMinutes() {
        XCTAssertGreaterThan(BenchmarkWarmUpPolicy.deadline, .seconds(1))
        XCTAssertLessThanOrEqual(BenchmarkWarmUpPolicy.deadline, .seconds(30))
    }
}
