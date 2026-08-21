import XCTest

@testable import NanoTeams

/// Pins the arithmetic every benchmark figure is built from.
///
/// Deliberately NOT `@MainActor`: every type under test is a `nonisolated` value type, so the
/// suite stays outside the "sync test method constructing a main-actor class aborts" population
/// entirely rather than working around it.
final class BenchmarkMetricsPolicyTests: XCTestCase {

    // MARK: - clientRate: the fence-post

    /// Eleven tokens arriving across one second span TEN inter-token intervals — the first token
    /// defines the origin and contributes no elapsed time. RED: `tokens` instead of `tokens - 1`
    /// → yields 11.0.
    func testElevenTokensOverOneSecond_isTenPerSecond() throws {
        let rate = BenchmarkMetricsPolicy.clientRate(tokens: 11, windowMs: 1000)
        XCTAssertEqual(try XCTUnwrap(rate), 10.0, accuracy: 0.0001)
    }

    /// The case that makes the fence-post worth fixing: at four tokens the naive formula is 33%
    /// high. RED: `tokens` instead of `tokens - 1` → yields 4.0 instead of 3.0.
    func testFourTokens_shortTurn_isWhereTheFencePostBites() throws {
        let rate = BenchmarkMetricsPolicy.clientRate(tokens: 4, windowMs: 1000)
        XCTAssertEqual(try XCTUnwrap(rate), 3.0, accuracy: 0.0001)
    }

    /// RED: drop the `tokens >= 2` guard and one token → yields 0.0 — which renders as "0 tok/s"
    /// and reads as a stalled model rather than as an unmeasurable sample.
    func testOneToken_isNilNotZero() {
        XCTAssertNil(BenchmarkMetricsPolicy.clientRate(tokens: 1, windowMs: 1000))
    }

    func testZeroTokens_isNil() {
        XCTAssertNil(BenchmarkMetricsPolicy.clientRate(tokens: 0, windowMs: 1000))
    }

    func testNilTokens_isNil() {
        XCTAssertNil(BenchmarkMetricsPolicy.clientRate(tokens: nil, windowMs: 1000))
    }

    /// RED: drop the `windowMs >= minimumWindowMs` guard → `9.0 / 0.0` returns `.infinity`
    /// rather than nil. Swift does not trap on that; it renders as "inf tok/s".
    func testZeroWindow_isNilNotInfinity() {
        XCTAssertNil(BenchmarkMetricsPolicy.clientRate(tokens: 10, windowMs: 0))
    }

    func testWindowBelowMinimum_isNil() {
        let justUnder = BenchmarkMetricsPolicy.minimumWindowMs - 1
        XCTAssertNil(BenchmarkMetricsPolicy.clientRate(tokens: 10, windowMs: justUnder))
    }

    func testWindowExactlyAtMinimum_isMeasured() {
        XCTAssertNotNil(
            BenchmarkMetricsPolicy.clientRate(
                tokens: 10, windowMs: BenchmarkMetricsPolicy.minimumWindowMs))
    }

    func testNegativeWindow_isNil() {
        XCTAssertNil(BenchmarkMetricsPolicy.clientRate(tokens: 10, windowMs: -1000))
    }

    // MARK: - serverRate: the fence-post must NOT be applied

    /// The server's decode window starts before it emits the first token, so every token is
    /// inside it. RED: applying `tokens - 1` here too → yields 10.0 instead of 11.0 — the mirror
    /// image of the bug `clientRate` exists to avoid, and invisible unless pinned separately.
    func testServerRate_doesNotSubtractOne() throws {
        let rate = BenchmarkMetricsPolicy.serverRate(tokens: 11, windowMs: 1000)
        XCTAssertEqual(try XCTUnwrap(rate), 11.0, accuracy: 0.0001)
    }

    /// RED: drop the `windowMs > 0` guard → a division by zero returns `.infinity`. Live path,
    /// not hypothetical: `eval_duration` is optional on the wire and a reported 0 decodes as 0.
    func testServerRate_zeroWindow_isNil() {
        XCTAssertNil(BenchmarkMetricsPolicy.serverRate(tokens: 100, windowMs: 0))
    }

    /// A single token IS measurable against a server window, unlike a client one.
    func testServerRate_oneToken_isMeasured() throws {
        XCTAssertEqual(
            try XCTUnwrap(BenchmarkMetricsPolicy.serverRate(tokens: 1, windowMs: 1000)),
            1.0, accuracy: 0.0001)
    }

    func testPrefillRate_usesTheServerShape() throws {
        // 800 prompt tokens prefilled in 400 ms is 2000 tok/s — all 800 inside the window.
        let rate = BenchmarkMetricsPolicy.prefillRate(promptTokens: 800, windowMs: 400)
        XCTAssertEqual(try XCTUnwrap(rate), 2000.0, accuracy: 0.0001)
    }

    // MARK: - median

    func testMedian_oddCount_isTheMiddleValue() throws {
        XCTAssertEqual(try XCTUnwrap(BenchmarkMetricsPolicy.median([3, 1, 2])), 2.0)
    }

    /// RED: returning `present[mid]` for the even case → yields 3.0 instead of 2.5.
    func testMedian_evenCount_averagesTheMiddleTwo() throws {
        XCTAssertEqual(try XCTUnwrap(BenchmarkMetricsPolicy.median([1, 2, 3, 4])), 2.5)
    }

    /// RED: computing parity from the INPUT length rather than the surviving values. With three
    /// entries of which one is nil, an input-length parity check takes `present[1]` (odd branch)
    /// → returns 20.0 instead of averaging to 15.0.
    func testMedian_nilsAreDroppedBeforeTheParityDecision() throws {
        XCTAssertEqual(try XCTUnwrap(BenchmarkMetricsPolicy.median([10, nil, 20])), 15.0)
    }

    func testMedian_allNil_isNil() {
        XCTAssertNil(BenchmarkMetricsPolicy.median([nil, nil]))
    }

    func testMedian_empty_isNil() {
        XCTAssertNil(BenchmarkMetricsPolicy.median([]))
    }

    /// RED: mean instead of median → 32.9 instead of 41, because one thermally unlucky sample
    /// drags a mean and not a median. Odd count on purpose: an even one would make the expected
    /// value an average of two neighbours and blunt the contrast.
    func testMedian_isNotDraggedByAnOutlier() throws {
        let withOutlier: [Double?] = [42, 41, 41, 40, 0.5]
        XCTAssertEqual(try XCTUnwrap(BenchmarkMetricsPolicy.median(withOutlier)), 41.0)
    }

    // MARK: - usableSamples

    /// RED: filter on `void` only → the warm-up enters the result, and since it paid for the
    /// model load, folding it in halves the reported speed.
    func testUsableSamples_excludeWarmup() {
        let samples = [
            sample(index: 0, phase: .warmup, outputTokens: 100, generationMs: 10_000),
            sample(index: 1, phase: .measured, outputTokens: 100, generationMs: 1000),
        ]
        let usable = BenchmarkMetricsPolicy.usableSamples(samples)
        XCTAssertEqual(usable.count, 1)
        XCTAssertEqual(usable.first?.sampleIndex, 1)
    }

    /// RED: filter on `phase` only → an HTTP 500 that reported zero tokens enters the median.
    func testUsableSamples_excludeVoided() {
        let samples = [
            sample(index: 0, phase: .measured, outputTokens: 0, generationMs: 5,
                   void: .httpError),
            sample(index: 1, phase: .measured, outputTokens: 100, generationMs: 1000),
        ]
        XCTAssertEqual(BenchmarkMetricsPolicy.usableSamples(samples).map(\.sampleIndex), [1])
    }

    // MARK: - summarize

    /// The warm-up is stopped on purpose in every healthy run, so it always carries a void. RED:
    /// count voids across every phase → each successful run reports "1 sample could not be used
    /// and was excluded from the medians", about a sample that was never eligible for one.
    func testSummarize_doesNotCountTheWarmUpsDeliberateStopAsAnUnusableSample() {
        let samples = [
            sample(index: 0, phase: .warmup, outputTokens: nil, generationMs: nil,
                   void: .stoppedEarly),
            sample(index: 1, phase: .measured, outputTokens: 100, generationMs: 1000),
        ]
        let summary = BenchmarkMetricsPolicy.summarize(samples)
        XCTAssertEqual(summary.voidedCount, 0)
        XCTAssertEqual(summary.usableCount, 1)
    }

    /// The complement, so the filter cannot be read as "never count anything": a MEASURED sample
    /// that failed is exactly what the count is for.
    func testSummarize_stillCountsVoidedMeasuredSamples() {
        let samples = [
            sample(index: 0, phase: .warmup, outputTokens: nil, generationMs: nil,
                   void: .stoppedEarly),
            sample(index: 1, phase: .measured, outputTokens: 0, generationMs: 5, void: .httpError),
            sample(index: 2, phase: .measured, outputTokens: 100, generationMs: 1000),
        ]
        XCTAssertEqual(BenchmarkMetricsPolicy.summarize(samples).voidedCount, 1)
    }

    func testSummarize_generationUsesTheClientWindow() throws {
        let samples = [
            sample(index: 0, phase: .warmup, outputTokens: 401, generationMs: 20_000),
            sample(index: 1, phase: .measured, outputTokens: 401, generationMs: 10_000),
            sample(index: 2, phase: .measured, outputTokens: 401, generationMs: 10_000),
        ]
        let summary = BenchmarkMetricsPolicy.summarize(samples)
        // 400 intervals over 10 s.
        XCTAssertEqual(try XCTUnwrap(summary.generationTokensPerSecond), 40.0, accuracy: 0.0001)
        XCTAssertEqual(summary.usableCount, 2)
    }

    /// A run whose every sample is unusable must announce itself as failed. RED: reporting an
    /// empty summary as success → makes a run where everything broke look clean.
    func testSummarize_allVoided_isFailed() {
        let samples = [
            sample(index: 0, phase: .measured, void: .transportError),
            sample(index: 1, phase: .measured, void: .noTokensReported),
        ]
        let summary = BenchmarkMetricsPolicy.summarize(samples)
        XCTAssertTrue(summary.isFailed)
        XCTAssertEqual(summary.usableCount, 0)
        XCTAssertEqual(summary.voidedCount, 2)
        XCTAssertNil(summary.generationTokensPerSecond)
    }

    /// One source across all usable samples — label it.
    ///
    /// RED: drop the agreement check → a mixed set is labelled with whichever source happened to
    /// come first, presenting a blend of three measurements as one.
    func testSummarize_singlePrefillSource_isReported() throws {
        let samples = [
            sample(index: 0, phase: .measured, inputTokens: 800, prefillMs: 400,
                   prefillSource: .serverPromptEval),
            sample(index: 1, phase: .measured, inputTokens: 800, prefillMs: 400,
                   prefillSource: .serverPromptEval),
        ]
        let summary = BenchmarkMetricsPolicy.summarize(samples)
        XCTAssertEqual(summary.prefillSource, .serverPromptEval)
        XCTAssertFalse(summary.prefillIsApproximate)
    }

    /// Samples measured different ways are not one figure.
    ///
    /// RED: return `sources.first` unconditionally → a mixed median is labelled exact.
    func testSummarize_mixedPrefillSources_reportsNoSource_andStaysApproximate() {
        let samples = [
            sample(index: 0, phase: .measured, inputTokens: 800, prefillMs: 400,
                   prefillSource: .serverPromptEval),
            sample(index: 1, phase: .measured, inputTokens: 800, prefillMs: 900,
                   prefillSource: .timeToFirstToken),
        ]
        let summary = BenchmarkMetricsPolicy.summarize(samples)
        XCTAssertNil(summary.prefillSource)
        XCTAssertTrue(summary.prefillIsApproximate)
    }

    /// RED: marking the whole prefill column approximate → would report Ollama's server-measured
    /// window as a guess; marking none would report LM Studio's TTFT fallback as exact.
    func testPrefillSource_onlyTimeToFirstTokenIsApproximate() {
        XCTAssertFalse(PrefillSource.serverPromptEval.isApproximate)
        XCTAssertFalse(PrefillSource.promptProcessingFrames.isApproximate)
        XCTAssertTrue(PrefillSource.timeToFirstToken.isApproximate)
    }

    // MARK: - Formatting

    /// RED: test `rate < 10` on the RAW value → 9.96 formats as "10.0", four characters where
    /// the leaderboard column reserved three.
    func testFormatRate_boundaryAt9_96_roundsToTwoCharacters() {
        XCTAssertEqual(BenchmarkMetricsPolicy.formatRate(9.96), "10")
    }

    func testFormatRate_belowTen_keepsOneDecimal() {
        XCTAssertEqual(BenchmarkMetricsPolicy.formatRate(3.44), "3.4")
    }

    func testFormatRate_aboveTen_isWhole() {
        XCTAssertEqual(BenchmarkMetricsPolicy.formatRate(142.7), "143")
    }

    /// RED: `?? 0` instead of the dash → an unmeasured figure renders as "0", which reads as a
    /// measured zero.
    func testFormatRate_nil_isDash() {
        XCTAssertEqual(BenchmarkMetricsPolicy.formatRate(nil), "—")
    }

    func testFormatRate_infinity_isDash() {
        XCTAssertEqual(BenchmarkMetricsPolicy.formatRate(.infinity), "—")
    }

    func testFormatDuration_belowASecond_isMilliseconds() {
        XCTAssertEqual(BenchmarkMetricsPolicy.formatDuration(612), "612 ms")
    }

    func testFormatDuration_aboveASecond_isSeconds() {
        XCTAssertEqual(BenchmarkMetricsPolicy.formatDuration(1900), "1.9 s")
    }

    func testFormatDuration_nil_isDash() {
        XCTAssertEqual(BenchmarkMetricsPolicy.formatDuration(nil), "—")
    }

    // MARK: - Helpers

    private func sample(
        index: Int,
        phase: GenerationBenchmarkSample.Phase,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        generationMs: Double? = nil,
        prefillMs: Double? = nil,
        prefillSource: PrefillSource? = nil,
        serverGenerationMs: Double? = nil,
        serverGenerationTokensPerSecond: Double? = nil,
        reasoningOutputTokens: Int? = nil,
        void: BenchmarkVoidReason? = nil
    ) -> GenerationBenchmarkSample {
        GenerationBenchmarkSample(
            runID: UUID(),
            recordedAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)),
            phase: phase,
            sampleIndex: index,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            timeToFirstTokenMs: 600,
            generationMs: generationMs,
            prefillMs: prefillMs,
            prefillSource: prefillSource,
            serverGenerationMs: serverGenerationMs,
            serverGenerationTokensPerSecond: serverGenerationTokensPerSecond,
            reasoningOutputTokens: reasoningOutputTokens,
            void: void)
    }

    // MARK: - generationRate: which source answers, and in what order

    /// The server's own window wins: we can see both operands, so the division is ours to show.
    func testGenerationRate_prefersTheServerWindowOverEverythingElse() {
        let result = BenchmarkMetricsPolicy.generationRate(
            outputTokens: 100, clientWindowMs: 2000, serverWindowMs: 1000, reportedRate: 999)
        XCTAssertEqual(result?.rate ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(result?.source, .serverDecodeWindow)
    }

    /// No window, but the server stated a rate: taken VERBATIM, not re-derived. Re-deriving would
    /// silently impose our fence-post convention on a number that already has one.
    func testGenerationRate_takesTheReportedRateVerbatim() {
        let result = BenchmarkMetricsPolicy.generationRate(
            outputTokens: 232, clientWindowMs: 3400, serverWindowMs: nil,
            reportedRate: 70.88376163013098)
        XCTAssertEqual(result?.rate ?? 0, 70.88376163013098, accuracy: 1e-12)
        XCTAssertEqual(result?.source, .serverReportedRate)
    }

    /// With no server figure at all the app's own window answers, and says so.
    func testGenerationRate_fallsBackToTheClientWindow() {
        let result = BenchmarkMetricsPolicy.generationRate(
            outputTokens: 101, clientWindowMs: 1000, serverWindowMs: nil, reportedRate: nil)
        XCTAssertEqual(result?.rate ?? 0, 100, accuracy: 0.0001, "fence-post: tokens − 1")
        XCTAssertEqual(result?.source, .clientWindow)
    }

    /// The floor guards the one branch whose operands are invisible. Below it the reported rate is
    /// refused and the visible-operand window answers instead — measured motivation: LM Studio
    /// answers 1 000 000 tok/s for a one-token completion.
    func testGenerationRate_belowTheTokenFloor_refusesTheReportedRate() {
        let result = BenchmarkMetricsPolicy.generationRate(
            outputTokens: BenchmarkMetricsPolicy.minimumTokensForRate - 1,
            clientWindowMs: 1000, serverWindowMs: nil, reportedRate: 1_000_000)
        XCTAssertEqual(result?.source, .clientWindow)
        XCTAssertNotEqual(result?.rate, 1_000_000)
    }

    func testGenerationRate_atTheTokenFloor_acceptsTheReportedRate() {
        let result = BenchmarkMetricsPolicy.generationRate(
            outputTokens: BenchmarkMetricsPolicy.minimumTokensForRate,
            clientWindowMs: 1000, serverWindowMs: nil, reportedRate: 42)
        XCTAssertEqual(result?.rate, 42)
        XCTAssertEqual(result?.source, .serverReportedRate)
    }

    /// The floor must NOT reach the window branches: their fence-post treatment is pinned at
    /// `tokens: 1` and `tokens: 4`, and a floor there would contradict deliberate intent.
    func testGenerationRate_theTokenFloorDoesNotReachTheWindowBranches() {
        let server = BenchmarkMetricsPolicy.generationRate(
            outputTokens: 2, clientWindowMs: nil, serverWindowMs: 1000, reportedRate: nil)
        XCTAssertEqual(server?.source, .serverDecodeWindow)
        let client = BenchmarkMetricsPolicy.generationRate(
            outputTokens: 2, clientWindowMs: 1000, serverWindowMs: nil, reportedRate: nil)
        XCTAssertEqual(client?.source, .clientWindow)
    }

    func testGenerationRate_degenerateReportedRates_areRefused() {
        for bad in [0, -5, Double.infinity, Double.nan] {
            let result = BenchmarkMetricsPolicy.generationRate(
                outputTokens: 100, clientWindowMs: nil, serverWindowMs: nil, reportedRate: bad)
            XCTAssertNil(result, "a rate of \(bad) is not a measurement")
        }
    }

    func testGenerationRate_withNothingToDivide_isNil() {
        XCTAssertNil(BenchmarkMetricsPolicy.generationRate(
            outputTokens: nil, clientWindowMs: nil, serverWindowMs: nil, reportedRate: nil))
    }

    // MARK: - summarize: the headline and its label

    func testSummarize_headlineUsesTheReportedRate_andLabelsIt() {
        let summary = BenchmarkMetricsPolicy.summarize([
            sample(index: 0, phase: .measured, outputTokens: 100, generationMs: 2000,
                   serverGenerationTokensPerSecond: 70),
            sample(index: 1, phase: .measured, outputTokens: 100, generationMs: 2000,
                   serverGenerationTokensPerSecond: 72),
        ])
        XCTAssertEqual(summary.generationTokensPerSecond ?? 0, 71, accuracy: 0.0001)
        XCTAssertEqual(summary.generationRateSource, .serverReportedRate)
        XCTAssertFalse(summary.generationRateIsApproximate)
        XCTAssertEqual(
            summary.clientGenerationTokensPerSecond ?? 0, 49.5, accuracy: 0.0001,
            "the app's own window is still computed, as the cross-check")
    }

    /// Two providers can never appear in one run, but a provider that answers on some samples and
    /// not others can — and then the median is a mixture that must not carry a single label.
    func testSummarize_whenSourcesDisagree_theLabelIsWithheld() {
        let summary = BenchmarkMetricsPolicy.summarize([
            sample(index: 0, phase: .measured, outputTokens: 100, generationMs: 2000,
                   serverGenerationTokensPerSecond: 70),
            sample(index: 1, phase: .measured, outputTokens: 100, generationMs: 2000),
        ])
        XCTAssertNotNil(summary.generationTokensPerSecond)
        XCTAssertNil(summary.generationRateSource)
        XCTAssertTrue(
            summary.generationRateIsApproximate,
            "an unlabelled mixture must not read as exact")
    }

    // MARK: - reasoning share

    func testReasoningShare_isTheRatioOfReasoningToOutput() {
        let summary = BenchmarkMetricsPolicy.summarize([
            sample(index: 0, phase: .measured, outputTokens: 232, generationMs: 2000,
                   reasoningOutputTokens: 214),
        ])
        XCTAssertEqual(summary.reasoningTokenShare ?? 0, 214.0 / 232.0, accuracy: 1e-9)
    }

    /// Absence is not zero: a provider that never separates reasoning has not measured "none".
    func testReasoningShare_isNilWhenTheProviderDoesNotSeparateReasoning() {
        let summary = BenchmarkMetricsPolicy.summarize([
            sample(index: 0, phase: .measured, outputTokens: 232, generationMs: 2000),
        ])
        XCTAssertNil(summary.reasoningTokenShare)
    }

    func testReasoningShare_degenerateInputs_areRefusedOrClamped() {
        XCTAssertNil(
            BenchmarkMetricsPolicy.reasoningShare(
                sample(index: 0, phase: .measured, outputTokens: 0, reasoningOutputTokens: 5)),
            "a zero denominator is not a share")
        XCTAssertNil(
            BenchmarkMetricsPolicy.reasoningShare(
                sample(index: 0, phase: .measured, outputTokens: 10, reasoningOutputTokens: -1)),
            "a negative count is not a measurement")
        XCTAssertEqual(
            BenchmarkMetricsPolicy.reasoningShare(
                sample(index: 0, phase: .measured, outputTokens: 10, reasoningOutputTokens: 99)),
            1, "a server that counts more reasoning than output is clamped, not believed")
    }
}
