import XCTest

@testable import NanoTeams

/// Every instant is handed in, so nothing here sleeps and nothing is timing-dependent.
/// Not `@MainActor`: the recorder is a `nonisolated` value type.
final class GenerationSampleRecorderTests: XCTestCase {

    private var origin: ContinuousClock.Instant!

    override func setUp() async throws {
        try await super.setUp()
        origin = ContinuousClock.now
    }

    override func tearDown() async throws {
        origin = nil
        try await super.tearDown()
    }

    private func at(_ ms: Double) -> ContinuousClock.Instant {
        origin.advanced(by: .milliseconds(Int(ms)))
    }

    private func makeRecorder() -> GenerationSampleRecorder {
        GenerationSampleRecorder(requestSentAt: origin)
    }

    // MARK: - Stopped on purpose

    /// A stream nobody finished reading has no terminal usage frame BECAUSE it was stopped. RED:
    /// resolve `noTokensReported` first → the app records its own decision as the server failing
    /// to report, and the warm-up row accuses a healthy provider.
    func testStoppedEarly_outranksTheMissingUsageFrame() {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(contentDelta: "b"), at: at(200))
        sut.stopEarly()

        XCTAssertEqual(sut.measurements(endedAt: at(300)).void, .stoppedEarly)
    }

    /// The deadline exit: stopped before a single token arrived. RED: order `noOutput` first →
    /// "the model produced no output" describes a request the app cut off at ten seconds.
    func testStoppedEarly_outranksNoOutput() {
        var sut = makeRecorder()
        sut.stopEarly()
        XCTAssertEqual(sut.measurements(endedAt: at(10_000)).void, .stoppedEarly)
    }

    /// And it must not fire on its own: a stream read to the end is a complete record.
    func testWithoutStoppingEarly_aCompleteStreamIsNotVoided() {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(contentDelta: "b"), at: at(1000))
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 5, outputTokens: 2)), at: at(1000))

        XCTAssertNil(sut.measurements(endedAt: at(1100)).void)
    }

    /// Stopping does not erase what was measured before it — the row still says how long the user
    /// waited for the first token, which is the only thing a warm-up can still tell anyone.
    func testStoppedEarly_keepsWhatItAlreadyMeasured() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(700))
        sut.note(StreamEvent(contentDelta: "b"), at: at(900))
        sut.stopEarly()

        let m = sut.measurements(endedAt: at(950))
        XCTAssertEqual(try XCTUnwrap(m.timeToFirstTokenMs), 700, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(m.generationMs), 200, accuracy: 1)
    }

    // MARK: - Time to first token

    /// TTFT is measured from the SEND, so it deliberately contains queue and model load. RED:
    /// measuring it from the first prompt-processing frame → would report a smaller number that
    /// answers a different question than "how long did I stare at nothing".
    func testTimeToFirstToken_isMeasuredFromTheSend() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(processingProgress: 0.0), at: at(100))
        sut.note(StreamEvent(contentDelta: "a"), at: at(600))
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 2)), at: at(700))

        let m = sut.measurements(endedAt: at(700))
        XCTAssertEqual(try XCTUnwrap(m.timeToFirstTokenMs), 600, accuracy: 1)
    }

    // MARK: - Generation window

    /// RED: ending the window at stream end rather than at the last delta folds the terminal frame
    /// → the transport teardown into the denominator, so the reported rate is low by whatever
    /// the tail cost.
    func testGenerationWindow_endsAtTheLastDelta_notAtStreamEnd() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(1000))
        sut.note(StreamEvent(contentDelta: "b"), at: at(3000))
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 3)), at: at(9000))

        let m = sut.measurements(endedAt: at(9000))
        XCTAssertEqual(try XCTUnwrap(m.generationMs), 2000, accuracy: 1)
    }

    /// RED: counting only content deltas → leaves reasoning tokens out of the window while the
    /// server still counts them in `outputTokens` — a whole numerator over a partial denominator.
    func testThinkingDeltas_countTowardTheWindow() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(thinkingDelta: "reasoning"), at: at(500))
        sut.note(StreamEvent(contentDelta: "answer"), at: at(2500))
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 5)), at: at(2600))

        let m = sut.measurements(endedAt: at(2600))
        XCTAssertEqual(try XCTUnwrap(m.timeToFirstTokenMs), 500, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(m.generationMs), 2000, accuracy: 1)
    }

    // MARK: - Prefill source precedence

    /// The server measured it — nothing else may win. RED: reordering the resolver → puts a
    /// queue-contaminated TTFT ahead of `prompt_eval_duration`.
    func testPrefill_serverPromptEvalWins() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(processingProgress: 0.0), at: at(10))
        sut.note(StreamEvent(processingProgress: 1.0), at: at(200))
        sut.note(StreamEvent(contentDelta: "a"), at: at(600))
        sut.note(
            StreamEvent(
                tokenUsage: TokenUsage(inputTokens: 900, outputTokens: 5),
                serverPrefill: ServerPrefillReport(prefillNs: 450_000_000, promptTokens: 900)),
            at: at(900))

        let m = sut.measurements(endedAt: at(900))
        XCTAssertEqual(m.prefillSource, .serverPromptEval)
        XCTAssertEqual(try XCTUnwrap(m.prefillMs), 450, accuracy: 0.5)
    }

    /// No server measurement, but the server narrated the window. RED: falling straight through to
    /// TTFT → reports 600 ms of queue-plus-load where the server said the prompt took 190 ms.
    func testPrefill_promptProcessingFramesBeatTimeToFirstToken() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(processingProgress: 0.0), at: at(10))
        sut.note(StreamEvent(processingProgress: 0.5), at: at(120))
        sut.note(StreamEvent(processingProgress: 1.0), at: at(200))
        sut.note(StreamEvent(contentDelta: "a"), at: at(600))
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 900, outputTokens: 5)), at: at(900))

        let m = sut.measurements(endedAt: at(900))
        XCTAssertEqual(m.prefillSource, .promptProcessingFrames)
        XCTAssertEqual(try XCTUnwrap(m.prefillMs), 190, accuracy: 1)
    }

    /// Nothing narrated: the fallback, and it must be flagged approximate rather than presented
    /// like the other two.
    func testPrefill_fallsBackToTimeToFirstToken_andIsApproximate() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(600))
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 900, outputTokens: 5)), at: at(900))

        let m = sut.measurements(endedAt: at(900))
        XCTAssertEqual(m.prefillSource, .timeToFirstToken)
        XCTAssertEqual(try XCTUnwrap(m.prefillMs), 600, accuracy: 1)
        XCTAssertTrue(try XCTUnwrap(m.prefillSource).isApproximate)
    }

    /// RED: accepting late `prompt_processing` frames → lets a stale one land AFTER generation has
    /// started and stretch a window that already closed.
    func testPrefill_ignoresProcessingFramesArrivingAfterTheFirstToken() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(processingProgress: 0.0), at: at(10))
        sut.note(StreamEvent(contentDelta: "a"), at: at(600))
        sut.note(StreamEvent(processingProgress: 1.0), at: at(5000))
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 900, outputTokens: 5)), at: at(5100))

        let m = sut.measurements(endedAt: at(5100))
        XCTAssertEqual(m.prefillSource, .timeToFirstToken)
        XCTAssertEqual(try XCTUnwrap(m.prefillMs), 600, accuracy: 1)
    }

    func testPrefill_noSignalAtAll_isNil() {
        var sut = makeRecorder()
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1)), at: at(100))
        let m = sut.measurements(endedAt: at(100))
        XCTAssertNil(m.prefillSource)
        XCTAssertNil(m.prefillMs)
    }

    // MARK: - Server generation window

    func testServerGenerationWindow_isConvertedToMilliseconds() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(contentDelta: "b"), at: at(2000))
        sut.note(
            StreamEvent(
                tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 120),
                serverGenerationNs: 6_000_000_000),
            at: at(2100))

        let m = sut.measurements(endedAt: at(2100))
        XCTAssertEqual(try XCTUnwrap(m.serverGenerationMs), 6000, accuracy: 0.5)
    }

    // MARK: - Void resolution

    /// RED: reordering the void checks → reports "no tokens" for a stream that produced nothing at
    /// all, which sends the reader looking at the wrong end of the problem.
    func testVoid_noDeltasAtAll_isNoOutput() {
        var sut = makeRecorder()
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 0)), at: at(50))
        XCTAssertEqual(sut.measurements(endedAt: at(50)).void, .noOutput)
    }

    /// A stream that generated but never reported usage cannot be priced against a server count.
    /// RED: defaulting the count to the delta count → makes the record indistinguishable from a
    /// reconciled one, and every later audit of it becomes self-satisfying.
    func testVoid_noTerminalUsage_isNoTokensReported() {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(contentDelta: "b"), at: at(2000))
        let m = sut.measurements(endedAt: at(2100))
        XCTAssertEqual(m.void, .noTokensReported)
        XCTAssertNil(m.outputTokens)
    }

    /// RED: dropping the window check → lets a two-token turn measured across 4 ms into the median
    /// as a several-hundred-tok/s sample.
    func testVoid_windowTooShort() {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(contentDelta: "b"), at: at(104))
        sut.note(StreamEvent(tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 2)), at: at(110))
        XCTAssertEqual(sut.measurements(endedAt: at(110)).void, .windowTooShort)
    }

    func testUsableSample_hasNoVoid() {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(contentDelta: "b"), at: at(10_100))
        sut.note(
            StreamEvent(tokenUsage: TokenUsage(inputTokens: 800, outputTokens: 401)), at: at(10_200))
        let m = sut.measurements(endedAt: at(10_200))
        XCTAssertNil(m.void)
        XCTAssertEqual(
            try XCTUnwrap(BenchmarkMetricsPolicy.clientRate(
                tokens: m.outputTokens, windowMs: m.generationMs)),
            40.0, accuracy: 0.1)
    }

    // MARK: - Passthrough facts

    func testModelLoadAndResidency_areCarried() throws {
        var sut = makeRecorder()
        sut.note(
            StreamEvent(clientResidency: ClientResidencyFacts(
                appLoadedModelForThisRequest: true, appModelLoadMs: 1234)),
            at: at(1))
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(contentDelta: "b"), at: at(1100))
        sut.note(
            StreamEvent(
                tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 2),
                serverPrefill: ServerPrefillReport(modelLoadMs: 2236.6)),
            at: at(1200))

        let m = sut.measurements(endedAt: at(1200))
        XCTAssertEqual(try XCTUnwrap(m.appModelLoadMs), 1234, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(m.modelLoadMs), 2236.6, accuracy: 0.5)
    }

    // MARK: - Error classification

    /// Every failure has to land under a reason the history can group by. RED: collapse them all
    /// to `.transportError` → `jq 'group_by(.void)'` stops telling a rate-limited server from a
    /// dead one, which is the first question anyone asks of a failed run.
    func testClassify_httpStatusCarriesTheCode() {
        let (reason, detail) = BenchmarkVoidClassifier.classify(
            LLMClientError.badHTTPStatus(503, "busy"))
        XCTAssertEqual(reason, .httpError)
        XCTAssertEqual(detail, "HTTP 503")
    }

    func testClassify_rateLimitIsAnHTTPError() {
        let (reason, detail) = BenchmarkVoidClassifier.classify(
            LLMClientError.rateLimited(retryAfter: 30))
        XCTAssertEqual(reason, .httpError)
        XCTAssertEqual(detail, "HTTP 429")
    }

    func testClassify_otherClientErrorsAreTransport() {
        let (reason, detail) = BenchmarkVoidClassifier.classify(LLMClientError.missingResponse)
        XCTAssertEqual(reason, .transportError)
        XCTAssertNotNil(detail)
    }

    func testClassify_cancellation() {
        XCTAssertEqual(BenchmarkVoidClassifier.classify(CancellationError()).reason, .cancelled)
    }

    /// URLSession reports a cancelled request as an `NSError`, not as `CancellationError`. RED:
    /// check only the Swift type → a run the user stopped is recorded as a transport failure and
    /// reads like the server broke.
    func testClassify_urlSessionCancellationIsStillACancel() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(BenchmarkVoidClassifier.classify(error).reason, .cancelled)
    }

    func testClassify_unknownErrorIsTransport() {
        let error = NSError(domain: "com.example", code: 42)
        let (reason, detail) = BenchmarkVoidClassifier.classify(error)
        XCTAssertEqual(reason, .transportError)
        XCTAssertNotNil(detail)
    }

    func testTotalMs_spansTheWholeRequest() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        let m = sut.measurements(endedAt: at(7500))
        XCTAssertEqual(try XCTUnwrap(m.totalMs), 7500, accuracy: 1)
    }

    // MARK: - Server-stated generation rate (LM Studio)

    /// The rate arrives on the terminal frame and is folded in unchanged. It is NOT turned into a
    /// window here: `tokens / rate` would invent endpoints the server never disclosed (#80).
    func testServerRate_isFoldedInVerbatim() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(contentDelta: "b"), at: at(2100))
        sut.note(
            StreamEvent(
                tokenUsage: TokenUsage(inputTokens: 12, outputTokens: 232),
                serverGenerationTokensPerSecond: 70.88376163013098,
                serverReasoningOutputTokens: 214),
            at: at(2200))

        let m = sut.measurements(endedAt: at(2200))
        XCTAssertEqual(
            try XCTUnwrap(m.serverGenerationTokensPerSecond), 70.88376163013098, accuracy: 1e-12)
        XCTAssertEqual(m.reasoningOutputTokens, 214)
        XCTAssertNil(m.serverGenerationMs, "a rate is not a window, and must not become one")
    }

    /// Ollama's shape through the same recorder: a window, no rate. The two never both arrive, and
    /// neither is synthesised from the other.
    func testServerWindow_leavesTheRateAbsent() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(
            StreamEvent(
                tokenUsage: TokenUsage(inputTokens: 12, outputTokens: 9),
                serverGenerationNs: 3_000_000_000),
            at: at(3200))

        let m = sut.measurements(endedAt: at(3200))
        XCTAssertEqual(try XCTUnwrap(m.serverGenerationMs), 3000, accuracy: 0.001)
        XCTAssertNil(m.serverGenerationTokensPerSecond)
        XCTAssertNil(m.reasoningOutputTokens)
    }

    /// Last writer wins, matching every other server-reported field on this recorder: a provider
    /// that restates its figures on a later frame must not be averaged with its earlier self.
    func testServerRate_lastFrameWins() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(serverGenerationTokensPerSecond: 10), at: at(200))
        sut.note(StreamEvent(serverGenerationTokensPerSecond: 70), at: at(300))

        XCTAssertEqual(sut.measurements(endedAt: at(400)).serverGenerationTokensPerSecond, 70)
    }

    /// A stream that reported no counts at all is void, and that verdict must survive the new
    /// fields: a rate without a token count still divides nothing.
    func testServerRate_withoutTokenCounts_isStillANoTokensReportedSample() throws {
        var sut = makeRecorder()
        sut.note(StreamEvent(contentDelta: "a"), at: at(100))
        sut.note(StreamEvent(contentDelta: "b"), at: at(2100))
        sut.note(StreamEvent(serverGenerationTokensPerSecond: 70), at: at(2200))

        XCTAssertEqual(sut.measurements(endedAt: at(2200)).void, .noTokensReported)
    }
}
