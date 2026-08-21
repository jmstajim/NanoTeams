import CryptoKit
import XCTest

@testable import NanoTeams

/// The benchmark's workload, and the contract its whole leaderboard rests on.
///
/// `BenchmarkLeaderboard` refuses to rank rows from a different `BenchmarkPrompt.version`, which
/// makes the version the single mechanical guarantee that two figures describe the same work. Up
/// to 2026-08-19 that guarantee was held by a doc comment alone — this file had no tests at all —
/// so a one-word edit to the prompt would have gone on being compared against every row measured
/// before it.
final class BenchmarkPromptTests: XCTestCase {

    // MARK: - The version-bump contract, mechanically

    /// Couples `version` to the workload it names. The fingerprint covers the prompt text AND the
    /// output ceiling, because both decide how many tokens a sample produces — which is the file's
    /// own stated reason for versioning at all.
    ///
    /// When this fails you changed the workload. That is allowed; it costs two edits: bump
    /// `BenchmarkPrompt.version`, then paste the new fingerprint below. What it will not let you
    /// do is change the workload and leave the version alone, which silently mixes two regimes in
    /// one ranked column.
    ///
    /// RED: edit one word of `BenchmarkPrompt.text`, or move `maxOutputTokens`, while leaving
    /// `version` alone → the fingerprint assertion fails and names both edits it needs.
    func testWorkloadFingerprint_cannotMoveWithoutTheVersion() {
        XCTAssertEqual(
            BenchmarkPrompt.version, 4,
            "the version moved — update the fingerprint below in the same edit")
        XCTAssertEqual(
            Self.workloadFingerprint(),
            "fe38c9fb8774fbc6f46963c89eaace6d177d0f608f633bef2200995215b8fca0",
            """
            The benchmark's workload changed. Old rows measured a different amount of work, so \
            they are no longer comparable — bump `BenchmarkPrompt.version` (the leaderboard drops \
            rows from other versions) and paste the fingerprint printed above into this test.
            """)
    }

    /// The fingerprint is only a guarantee if it actually covers the ceiling. RED: hash the text
    /// alone → the cap could be halved with the version untouched, and every existing row would
    /// keep being ranked beside samples measuring half the work.
    func testWorkloadFingerprint_coversTheCeilingAndNotOnlyTheText() {
        let withCap = Self.digest(BenchmarkPrompt.text + "|cap=512")
        let withOther = Self.digest(BenchmarkPrompt.text + "|cap=256")
        XCTAssertNotEqual(withCap, withOther)
        XCTAssertEqual(withCap, Self.workloadFingerprint(), "512 is the shipped ceiling")
    }

    // MARK: - Properties the prompt's own doc comment claims

    /// The nonce is what makes the prefill figure a measurement instead of a cache lookup, and a
    /// prefix cache matches on the PREFIX — a marker at the end would let the whole body hit.
    ///
    /// RED: append the nonce instead of prepending it → every sample after the first reports a
    /// prefill time for a cache hit, and the number reads excellent and means nothing.
    func testNonce_leadsThePromptRatherThanTrailingIt() throws {
        let message = try XCTUnwrap(BenchmarkPrompt.messages(nonce: "abc12345").first)
        let content = try XCTUnwrap(message.content)

        XCTAssertTrue(content.hasPrefix("Request abc12345."), String(content.prefix(40)))
        XCTAssertFalse(content.hasSuffix("abc12345"), "a trailing marker breaks no prefix")
    }

    /// Two samples must not share a prompt, or the second measures the first's cache.
    func testEverySample_getsADifferentPrompt() {
        XCTAssertNotEqual(
            BenchmarkPrompt.messages(nonce: "aaaa1111").first?.content,
            BenchmarkPrompt.messages(nonce: "bbbb2222").first?.content)
    }

    /// One user turn, no system turn — deliberate, and the reason is portability: the roles a
    /// model accepts differ by family (Gemma takes user/model only, DeepSeek-R1 wants no system
    /// prompt), so a benchmark that populated the system slot would measure a different thing on
    /// those models or fail outright.
    ///
    /// RED: add a system message → the measured prompt stops being identical across providers and
    /// model families, which is the property this shape exists to keep.
    func testMessages_areOneUserTurnWithNoSystemPrompt() {
        let messages = BenchmarkPrompt.messages(nonce: "abc12345")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
    }

    /// Depth is the whole reason for the 52 repetitions: at 81 prompt tokens this project measured
    /// 40 tok/s of prefill — the fixed cost of a first eval — against 449 tok/s at 2 480. A prompt
    /// that shrank back under a thousand tokens would report the fixed cost as throughput.
    ///
    /// Characters rather than tokens because tokens are the server's to count, and the ratio is
    /// model-specific; this asserts the ORDER OF MAGNITUDE the depth argument rests on.
    func testText_staysDeepEnoughForThroughputToDominate() {
        XCTAssertGreaterThan(BenchmarkPrompt.text.count, 6_000)
    }

    /// The ceiling has to clear the arithmetic floors below it by a wide margin — a rate needs at
    /// least `minimumTokensForRate` tokens, and the reported-rate branch is exactly where a
    /// handful of tokens lets the server's own arithmetic dominate.
    ///
    /// RED: set the ceiling near the floor → samples start voiding as `windowTooShort`, and the
    /// run reports nothing while looking configured.
    func testCeiling_clearsTheMetricsFloorsByAWideMargin() {
        XCTAssertGreaterThan(
            BenchmarkPrompt.maxOutputTokens, BenchmarkMetricsPolicy.minimumTokensForRate * 10)
    }

    // MARK: - Fingerprint

    static func workloadFingerprint() -> String {
        digest(BenchmarkPrompt.text + "|cap=\(BenchmarkPrompt.maxOutputTokens)")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
