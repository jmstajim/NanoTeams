import XCTest

@testable import NanoTeams

/// `@MainActor` because the runner is, with EVERY test `async` and every main-actor object built
/// in `setUp` — a sync test method that constructs a main-actor class in its body aborts the
/// process on CI, and `setUp` is the one place XCTest guarantees main-actor dispatch.
@MainActor
final class GenerationBenchmarkRunnerTests: XCTestCase, @unchecked Sendable {

    private var directory: URL!
    private var store: BenchmarkHistoryStore!
    private var clock: SteppingClock!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-runner-\(UUID().uuidString)", isDirectory: true)
        store = BenchmarkHistoryStore(directory: directory)
        clock = SteppingClock(stepMilliseconds: Int(Self.clockStepMs))
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        store = nil
        clock = nil
        directory = nil
        try await super.tearDown()
    }

    private func makeRunner(
        client: any LLMClient,
        probe: any ServerProvenanceProbe = StubProvenanceProbe(),
        isBusy: @escaping @MainActor () -> Bool = { false },
        // A minute, deliberately far longer than any test here tolerates: it means a test that
        // FINISHES did so because the delta policy or a cancellation ended the warm-up, never
        // because a deadline quietly rescued it. The two tests that are about the deadline pass
        // their own.
        warmUpDeadline: Duration = .seconds(60)
    ) -> GenerationBenchmarkRunner {
        let clock = clock!
        return GenerationBenchmarkRunner(
            client: client, probe: probe, store: store, isBusy: isBusy,
            appVersion: "1.8.8", now: { clock.next() }, warmUpDeadline: warmUpDeadline)
    }

    private func config() -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "qwen3.8")
    }

    // MARK: - Happy path

    func testRun_recordsAWarmUpPlusTheRequestedSamples() async {
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()))
        await runner.run(config: config(), repeats: 3, otherServers: [])

        let samples = store.loadSamples()
        XCTAssertEqual(samples.filter { $0.phase == .warmup }.count, 1)
        XCTAssertEqual(samples.filter { $0.phase == .measured }.count, 3)
        XCTAssertEqual(runner.phase, .finished)
    }

    /// RED: folding the warm-up into the summary → lets the model-load cost of the first request
    /// into the reported speed.
    func testRun_warmUpIsRecordedButNotSummarized() async throws {
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()))
        await runner.run(config: config(), repeats: 2, otherServers: [])

        let summary = try XCTUnwrap(runner.summary)
        XCTAssertEqual(summary.usableCount, 2, "the warm-up must not be counted")
        XCTAssertTrue(store.loadSamples().contains { $0.phase == .warmup },
                      "…but it must still be on disk")
    }

    func testRun_persistsTheRunWithItsProvenance() async throws {
        let client = ScriptedClient(events: Self.healthyStream())
        let runner = makeRunner(
            client: client,
            probe: StubProvenanceProbe(provenance: ServerProvenance(version: "0.32.14")))
        await runner.run(config: config(), repeats: 1, otherServers: [])

        let run = try XCTUnwrap(store.loadRuns().first)
        XCTAssertEqual(run.providerVersion, "0.32.14")
        XCTAssertEqual(run.modelName, "qwen3.8")
        XCTAssertEqual(run.promptID, BenchmarkPrompt.id)
        XCTAssertEqual(run.promptVersion, BenchmarkPrompt.version)
        XCTAssertEqual(run.appVersion, "1.8.8")
    }

    /// RED: record the raw URL → one server appears twice in the leaderboard once a trailing
    /// slash creeps into the settings field.
    func testRun_normalizesTheServerURL() async throws {
        var configuration = config()
        configuration.baseURLString = "HTTP://127.0.0.1:11434/"
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()))
        await runner.run(config: configuration, repeats: 1, otherServers: [])

        XCTAssertEqual(store.loadRuns().first?.baseURLString, "http://127.0.0.1:11434")
    }

    /// A provider that reports no version must record none — never the app's own.
    func testRun_absentProviderVersion_staysNil() async throws {
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()))
        await runner.run(config: config(), repeats: 1, otherServers: [])
        XCTAssertNil(try XCTUnwrap(store.loadRuns().first).providerVersion)
    }

    // MARK: - Prefill source

    func testRun_serverPrefill_isPreferred() async throws {
        let events = [
            StreamEvent(processingProgress: 0.0),
            StreamEvent(processingProgress: 1.0),
            StreamEvent(contentDelta: "a"),
            StreamEvent(contentDelta: "b"),
            StreamEvent(
                tokenUsage: TokenUsage(inputTokens: 800, outputTokens: 401),
                serverPrefill: ServerPrefillReport(prefillNs: 400_000_000, promptTokens: 800)),
        ]
        let runner = makeRunner(client: ScriptedClient(events: events))
        await runner.run(config: config(), repeats: 1, otherServers: [])

        XCTAssertEqual(try XCTUnwrap(runner.summary).prefillSource, .serverPromptEval)
        XCTAssertFalse(try XCTUnwrap(runner.summary).prefillIsApproximate)
    }

    /// The LM Studio shape: no server measurement, but narrated frames. RED: falling through to
    /// TTFT → reports queue plus model load as if it were prompt processing.
    func testRun_promptProcessingFrames_areUsedWhenTheServerDoesNotMeasure() async throws {
        let events = [
            StreamEvent(processingProgress: 0.0),
            StreamEvent(processingProgress: 1.0),
            StreamEvent(contentDelta: "a"),
            StreamEvent(contentDelta: "b"),
            StreamEvent(tokenUsage: TokenUsage(inputTokens: 800, outputTokens: 401)),
        ]
        let runner = makeRunner(client: ScriptedClient(events: events))
        await runner.run(config: config(), repeats: 1, otherServers: [])

        XCTAssertEqual(try XCTUnwrap(runner.summary).prefillSource, .promptProcessingFrames)
    }

    /// Nothing narrated at all: approximate, and it must say so.
    func testRun_withoutAnyPrefillSignal_isApproximate() async throws {
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()))
        await runner.run(config: config(), repeats: 1, otherServers: [])

        let summary = try XCTUnwrap(runner.summary)
        XCTAssertEqual(summary.prefillSource, .timeToFirstToken)
        XCTAssertTrue(summary.prefillIsApproximate)
    }

    // MARK: - Void paths

    /// RED: defaulting the token count to something the app counted itself → makes the record
    /// indistinguishable from a server-reconciled one, and every later audit of the history
    /// silently measures the estimate against itself.
    func testRun_streamWithoutTerminalUsage_isVoidedAsNoTokensReported() async {
        let events = [
            StreamEvent(contentDelta: "a"),
            StreamEvent(contentDelta: "b"),
        ]
        let runner = makeRunner(client: ScriptedClient(events: events))
        await runner.run(config: config(), repeats: 1, otherServers: [])

        XCTAssertEqual(store.loadSamples().compactMap(\.void), [.noTokensReported, .noTokensReported])
        XCTAssertTrue(try! XCTUnwrap(runner.summary).isFailed)
    }

    func testRun_emptyStream_isVoidedAsNoOutput() async {
        let runner = makeRunner(client: ScriptedClient(events: []))
        await runner.run(config: config(), repeats: 1, otherServers: [])
        XCTAssertEqual(store.loadSamples().compactMap(\.void), [.noOutput, .noOutput])
    }

    /// RED: report an all-void run as `.finished` → a run in which nothing worked shows a clean
    /// result.
    func testRun_allSamplesVoided_endsInFailed_namingTheReason() async {
        let runner = makeRunner(client: ScriptedClient(events: [], failure: LLMClientError.badHTTPStatus(500, nil)))
        await runner.run(config: config(), repeats: 2, otherServers: [])

        guard case .failed(let message) = runner.phase else {
            return XCTFail("expected .failed, got \(runner.phase)")
        }
        XCTAssertTrue(message.contains("server returned an error"), message)
    }

    func testRun_httpError_isRecordedWithItsStatus() async throws {
        let runner = makeRunner(
            client: ScriptedClient(events: [], failure: LLMClientError.badHTTPStatus(503, "busy")))
        await runner.run(config: config(), repeats: 1, otherServers: [])

        let sample = try XCTUnwrap(store.loadSamples().first)
        XCTAssertEqual(sample.void, .httpError)
        XCTAssertEqual(sample.voidDetail, "HTTP 503")
    }

    /// RED: check `isBusy` once per RUN instead of per sample → a role that starts halfway
    /// through contaminates the later samples and none of them is marked.
    func testRun_whileAnotherStreamIsRunning_voidsEverySample() async {
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()), isBusy: { true })
        await runner.run(config: config(), repeats: 2, otherServers: [])

        let samples = store.loadSamples()
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(samples.allSatisfy { $0.void == .concurrentActivity })
    }

    /// Partial evidence beats no evidence: a cancelled run still records what it measured, marked
    /// as cancelled rather than silently dropped.
    ///
    /// Uses a stream that HANGS after yielding, so the run is genuinely in flight when the cancel
    /// lands. No sleep: the client flips a flag synchronously when the stream is built, and the
    /// test yields until it sees it. (Polling the store would not work — samples are persisted
    /// once at the end of the run, not per sample.)
    func testCancelledRun_recordsWhatItMeasured_markedCancelled() async {
        let client = HangingClient()
        let runner = makeRunner(client: client)

        let task = Task { await runner.run(config: config(), repeats: 50, otherServers: []) }
        while !client.didStart { await Task.yield() }
        task.cancel()
        _ = await task.value

        let samples = store.loadSamples()
        XCTAssertFalse(samples.isEmpty, "a cancelled run must still leave its evidence")
        XCTAssertLessThan(samples.count, 51, "it must not have run to completion")
        XCTAssertTrue(samples.contains { $0.void == .cancelled })
    }

    /// A cancelled `AsyncThrowingStream` does NOT throw: its termination handler finishes the
    /// continuation, so `next()` returns nil and `for try await` exits exactly as it would if the
    /// server had ended the answer (CLAUDE.md #88). The `checkCancellation` INSIDE that loop cannot
    /// see it — it only runs when another event arrives, and none ever will.
    ///
    /// RED: drop the `try Task.checkCancellation()` after the measured loop → the sample the user
    /// cut off is recorded with no void at all, i.e. as a complete measurement of a short reply,
    /// and its rate is averaged into the leaderboard as something the model produced.
    ///
    /// The warm-up already had this line; this is the sibling site that did not (#51).
    func testCancellingDuringAMeasuredSample_recordsItAsCancelled_notAsAShortAnswer() async throws {
        let client = WarmThenHangingClient()
        let runner = makeRunner(client: client)

        let task = Task { await runner.run(config: config(), repeats: 1, otherServers: []) }
        while !client.measuredSampleStarted { await Task.yield() }
        task.cancel()
        _ = await task.value

        let measured = try XCTUnwrap(store.loadSamples().first { $0.phase == .measured })
        XCTAssertEqual(measured.void, .cancelled,
                       "a stop we caused must never be recorded as an answer the model gave")
    }

    // MARK: - The warm-up is bounded

    /// The change this file exists to defend. Measured on LM Studio 0.4.21 / qwen3.5-9b: read to
    /// the end, one warm-up ran 233 s and produced 12 040 tokens (11 561 of them reasoning) — for
    /// a sample every median then discards.
    ///
    /// RED: read the warm-up to the end → its row carries the terminal frame's token counts and no
    /// void, which is exactly what a four-minute warm-up looks like in the record.
    func testWarmUp_stopsOnceTheModelIsDecoding_ratherThanReadingTheWholeAnswer() async throws {
        let deltas = BenchmarkWarmUpPolicy.sufficientDeltas * 3
        let runner = makeRunner(client: LongStreamClient(deltas: deltas))
        await runner.run(config: config(), repeats: 1, otherServers: [])

        let warmUp = try XCTUnwrap(store.loadSamples().first { $0.phase == .warmup })
        XCTAssertEqual(warmUp.void, .stoppedEarly)
        XCTAssertNil(
            warmUp.outputTokens,
            "the terminal usage frame comes after the answer, so a stopped warm-up cannot have it")
        // WHERE it stopped, not just that it did. The injected clock advances a fixed step per
        // read, so the window between the first and last delta counts the deltas consumed:
        // stopping at the policy spans `sufficientDeltas − 1` steps, reading to the end would span
        // `deltas − 1`. Without this the test passes for a warm-up truncated anywhere at all.
        XCTAssertEqual(
            warmUp.generationMs,
            Double(BenchmarkWarmUpPolicy.sufficientDeltas - 1) * Self.clockStepMs)
    }

    /// The anti-vacuum twin: truncation must be gated on the PHASE, not applied to every stream.
    /// RED: stop every sample at the policy → the measured rows lose the server's token counts and
    /// the whole benchmark reports nothing, which the test above would not notice.
    func testMeasuredSamples_areReadToTheEnd_howeverLongTheAnswer() async throws {
        let deltas = BenchmarkWarmUpPolicy.sufficientDeltas * 3
        let runner = makeRunner(client: LongStreamClient(deltas: deltas))
        await runner.run(config: config(), repeats: 2, otherServers: [])

        let measured = store.loadSamples().filter { $0.phase == .measured }
        XCTAssertEqual(measured.count, 2)
        XCTAssertTrue(measured.allSatisfy { $0.outputTokens == 401 && $0.void == nil })
        XCTAssertEqual(try XCTUnwrap(runner.summary).usableCount, 2)
    }

    /// Stopping has to mean the REQUEST stops, not just that we look away: a server left generating
    /// an answer nobody reads is still holding the machine the next sample is about to be measured
    /// on. The stream here never finishes, so cancellation is the only thing that can terminate it.
    ///
    /// RED: read to the end → the run never returns at all, because this stream has no end.
    func testWarmUp_cancelsTheRequest_ratherThanLeavingItToGenerate() async throws {
        let client = UnendingStreamClient(deltas: BenchmarkWarmUpPolicy.sufficientDeltas * 2)
        let runner = makeRunner(client: client)
        await runner.run(config: config(), repeats: 0, otherServers: [])

        XCTAssertEqual(client.terminations, ["cancelled"])
        XCTAssertEqual(store.loadSamples().first?.void, .stoppedEarly)
        // The stop came from the POLICY, not from the deadline rescuing a runaway read: this
        // runner's deadline is a minute, and the window says exactly `sufficientDeltas` deltas
        // were taken.
        XCTAssertEqual(
            store.loadSamples().first?.generationMs,
            Double(BenchmarkWarmUpPolicy.sufficientDeltas - 1) * Self.clockStepMs)
    }

    /// The other exit. A model that never produces a token never satisfies the delta policy, and
    /// there is no suspension point to check a clock on — so without the watchdog the warm-up is
    /// bounded by nothing the app controls.
    ///
    /// RED: drop the watchdog → this test hangs on a stream that yields nothing and never ends.
    func testWarmUp_thatNeverProducesAToken_isStoppedAtTheDeadline() async throws {
        let client = SilentStreamClient()
        let runner = makeRunner(client: client, warmUpDeadline: .milliseconds(50))
        // Bounded, so removing the watchdog fails this test in seconds instead of hanging the
        // suite: a pin whose only failure mode is a hang tells CI nothing but "something is stuck".
        let target = config()
        let finished = await Self.withTimeout(seconds: 10) {
            await runner.run(config: target, repeats: 0, otherServers: [])
            return true
        }
        XCTAssertEqual(finished, true, "nothing else can end a stream that never speaks")

        let warmUp = try XCTUnwrap(store.loadSamples().first)
        XCTAssertEqual(client.terminations, ["cancelled"])
        XCTAssertEqual(warmUp.void, .stoppedEarly)
        XCTAssertNil(warmUp.timeToFirstTokenMs, "nothing arrived, so there is nothing to time")
    }

    /// The read runs in an unstructured task, so the run's own cancellation does not descend into
    /// it — `withTaskCancellationHandler` is what forwards it. The deadline here is a minute, so
    /// only that forwarding can end this run.
    ///
    /// RED: drop the cancellation handler → Stop leaves the request alive for the rest of the
    /// deadline, and this test waits out the full minute instead of returning.
    func testCancellingDuringTheWarmUp_stopsItImmediately() async throws {
        let client = SilentStreamClient()
        let runner = makeRunner(client: client, warmUpDeadline: .seconds(60))

        let task = Task { await runner.run(config: config(), repeats: 1, otherServers: []) }
        while !client.didStart { await Task.yield() }
        task.cancel()
        // Bounded well under the runner's minute: without the forwarding the run is still alive
        // here, and this asserts that rather than sitting through it.
        let finished = await Self.withTimeout(seconds: 10) {
            _ = await task.value
            return true
        }
        XCTAssertEqual(finished, true, "Stop must reach the warm-up, not wait out its deadline")

        XCTAssertEqual(client.terminations, ["cancelled"])
        XCTAssertEqual(store.loadSamples().first?.void, .cancelled)
    }

    /// The stub streams here end by finishing, which is what a cancelled `AsyncThrowingStream`
    /// does — but a real client wraps a transport that can surface cancellation as a THROW instead
    /// (`continuation.finish(throwing:)`). That arm has to record the same fact, or the same event
    /// lands in the history under two names depending on which layer noticed it first.
    ///
    /// RED: classify it with everything else → a cancelled warm-up is filed as a transport
    /// failure, and `jq 'group_by(.void)'` counts one outcome twice.
    func testWarmUp_whenTheClientThrowsCancellation_isStillRecordedAsStopped() async throws {
        let runner = makeRunner(
            client: ScriptedClient(
                events: [StreamEvent(contentDelta: "a")], failure: CancellationError()))
        await runner.run(config: config(), repeats: 0, otherServers: [])

        let warmUp = try XCTUnwrap(store.loadSamples().first)
        XCTAssertEqual(warmUp.void, .stoppedEarly)
        XCTAssertNil(warmUp.voidDetail, "a deliberate stop has no failure to detail")
    }

    /// A warm-up short enough to end by itself was not stopped by anyone, and saying it was would
    /// describe a decision nobody made. RED: mark every warm-up stopped → a complete row with the
    /// server's own token counts is labelled as truncated.
    func testWarmUp_thatEndsOnItsOwn_isNotLabelledStopped() async throws {
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()))
        await runner.run(config: config(), repeats: 1, otherServers: [])

        let warmUp = try XCTUnwrap(store.loadSamples().first { $0.phase == .warmup })
        XCTAssertNil(warmUp.void)
        XCTAssertEqual(warmUp.outputTokens, 401)
    }

    /// RED: count voids across every phase → every healthy run tells the user "1 sample could not
    /// be used and was excluded from the medians", about the one sample that was never going to be
    /// in a median.
    func testStoppedWarmUp_isNotReportedAsAnUnusableSample() async throws {
        let runner = makeRunner(client: LongStreamClient(deltas: 40))
        await runner.run(config: config(), repeats: 2, otherServers: [])

        let summary = try XCTUnwrap(runner.summary)
        XCTAssertEqual(summary.voidedCount, 0)
        XCTAssertEqual(runner.phase, .finished)
    }

    /// Residency comes from the preparer, which asked the server before anything was measured.
    /// It used to fall back to inferring it from the warm-up's reported load time — a number that
    /// rides the terminal frame a stopped warm-up never reaches, so the inference could only have
    /// returned its no-evidence answer.
    ///
    /// RED: record the inference instead → every run reports "was resident" regardless, because
    /// an absent load time reads as "no load happened".
    func testRun_recordsResidencyFromThePreparer() async throws {
        let runner = makeRunner(client: ResidentModelClient())
        await runner.run(config: config(), repeats: 1, otherServers: [])
        XCTAssertTrue(try XCTUnwrap(runner.lastRun).modelWasResident)
    }

    /// The other half: a client that cannot enumerate instances gives no evidence of residency,
    /// and no evidence must not read as yes.
    func testRun_withoutAResidencyAnswer_doesNotClaimTheModelWasResident() async throws {
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()))
        await runner.run(config: config(), repeats: 1, otherServers: [])
        XCTAssertFalse(try XCTUnwrap(runner.lastRun).modelWasResident)
    }

    /// With `repeats: 0` the warm-up's void is the ONLY one there is, so an unfiltered failure
    /// message would state "stopped once it had done its job" as the reason a run produced nothing.
    /// RED: read reasons from every phase → the run blames the user's own design.
    func testFailureMessage_ignoresTheWarmUpsDeliberateStop() {
        let runID = UUID()
        let warmUp = GenerationBenchmarkSample(
            runID: runID, recordedAt: Date(), phase: .warmup, sampleIndex: 0,
            void: .stoppedEarly)
        XCTAssertEqual(
            GenerationBenchmarkRunner.failureMessage(for: [warmUp]), "No usable samples.")
    }

    // MARK: - Guards

    func testRun_zeroRepeats_stillRecordsTheWarmUpAndFails() async {
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()))
        await runner.run(config: config(), repeats: 0, otherServers: [])

        XCTAssertEqual(store.loadSamples().count, 1)
        XCTAssertEqual(store.loadSamples().first?.phase, .warmup)
        XCTAssertTrue(try! XCTUnwrap(runner.summary).isFailed)
    }

    /// The guard sits on the shared resource, so it holds however the second call arrives — from a
    /// second click, from the sweep, or from a caller that does not know about either.
    ///
    /// RED: drop `guard !isRunning` from `run` → two runs stack on one machine: each one's
    /// residency pass unloads the other's target, and each one's samples measure both streams.
    /// That is the contamination the preparer and `isBusy` exist to prevent, arriving through the
    /// one door neither of them watches.
    func testRun_whileAlreadyMeasuring_isRefusedWithoutTouchingTheServer() async {
        let client = HangingClient()
        let runner = makeRunner(client: client)

        let first = Task { await runner.run(config: config(), repeats: 2, otherServers: []) }
        while !client.didStart { await Task.yield() }
        XCTAssertTrue(runner.isRunning)

        let refused = await runner.run(config: config(), repeats: 2, otherServers: [])
        XCTAssertEqual(refused, .nothingRecorded)
        XCTAssertEqual(client.startCount, 1, "the second call must not open a second stream")

        first.cancel()
        _ = await first.value
        XCTAssertEqual(store.loadRuns().count, 1, "exactly one run may be recorded")
    }

    /// Cancelling before the first sample must leave the screen idle, not "finished" with an
    /// empty result. RED: fall through to the sampling loop → a cancelled-at-the-door run records
    /// a warm-up and reports a failure the user did not cause.
    func testCancelledDuringPreparation_endsIdle_andRecordsNothing() async {
        let probe = SlowProvenanceProbe()
        let runner = makeRunner(
            client: ScriptedClient(events: Self.healthyStream()), probe: probe)

        let task = Task { await runner.run(config: config(), repeats: 3, otherServers: []) }
        while !probe.didProbe { await Task.yield() }
        task.cancel()
        _ = await task.value

        XCTAssertEqual(runner.phase, .idle)
        XCTAssertTrue(store.loadRuns().isEmpty)
        XCTAssertTrue(store.loadSamples().isEmpty)
    }

    /// The second cancellation gate. The engine probe SPENDS a completion, so a cancel that lands
    /// between the two provenance steps must still end the run at idle rather than fall through
    /// into sampling with a half-gathered record.
    func testCancelledDuringTheEngineProbe_endsIdle_andRecordsNothing() async {
        let probe = SlowEnginePR()
        let runner = makeRunner(client: ResidentModelClient(), probe: probe)

        let task = Task { await runner.run(config: config(), repeats: 3, otherServers: []) }
        while !probe.didProbeEngine { await Task.yield() }
        task.cancel()
        _ = await task.value

        XCTAssertEqual(runner.phase, .idle)
        XCTAssertTrue(store.loadRuns().isEmpty)
    }

    /// The gate. Probing the serving engine spends a completion, and against a server where the
    /// model is NOT known to be resident that completion would trigger a load outside the app's
    /// own model lifecycle — undoing the residency the preparer just arranged. RED: drop the
    /// condition → the probe fires on a cold server.
    func testEngineProbe_isSkippedWhenResidencyCouldNotBeConfirmed() async {
        let probe = CountingEnginePR()
        let runner = makeRunner(
            client: ScriptedClient(events: Self.healthyStream()), probe: probe)

        await runner.run(config: config(), repeats: 1, otherServers: [])

        XCTAssertEqual(
            probe.engineProbeCount, 0,
            "nothing was reported resident, so the probe must not spend a completion")
    }

    func testEngineProbe_runsWhenTheTargetIsKnownResident() async {
        let probe = CountingEnginePR()
        let runner = makeRunner(client: ResidentModelClient(), probe: probe)

        await runner.run(config: config(), repeats: 1, otherServers: [])

        XCTAssertEqual(probe.engineProbeCount, 1)
    }

    /// Provenance from three sources lands in one bag, and a collision must not let the newest
    /// writer overwrite what the model's own details said. RED: drop the merge closure → the
    /// engine probe's label silently replaces a model field of the same name.
    func testRun_provenanceFieldsDoNotOverwriteModelFields() async throws {
        let probe = StubProvenanceProbe(
            provenance: ServerProvenance(
                version: "0.4.21",
                installedEngines: [.init(name: "llama.cpp", version: "2.29.0")]))
        let runner = makeRunner(
            client: CollidingDetailsClient(), probe: probe)
        await runner.run(config: config(), repeats: 1, otherServers: [])

        let run = try XCTUnwrap(store.loadRuns().first)
        XCTAssertEqual(
            run.serverFields["Engines installed"], "from the model details",
            "the model's own details were written first and must win the collision")
    }

    /// The typed format/quantization on the record come from the SAME `ModelLoadDetails` the
    /// `serverFields` bag is built from — one fetch, two representations, written in one breath.
    /// RED: drop the `modelFormat:`/`quantization:` arguments in `run` → every NEW run renders
    /// chipless while its own `serverFields` state the answer.
    func testRun_capturesModelFormatAndQuantizationFromTheModelDetails() async throws {
        let runner = makeRunner(client: FormatDetailsClient())
        await runner.run(config: config(), repeats: 1, otherServers: [])

        let run = try XCTUnwrap(store.loadRuns().first)
        XCTAssertEqual(run.modelFormat, "gguf")
        XCTAssertEqual(run.quantization, "Q4_K_M")
        // The verbatim bag still carries both: it is the audit record of everything the server
        // said, and the typed fields are promoted copies, not replacements.
        XCTAssertEqual(run.serverFields[ModelLoadDetails.formatLabel], "gguf")
        XCTAssertEqual(run.serverFields[ModelLoadDetails.quantizationLabel], "Q4_K_M")
    }

    /// A provider with no details surface (the protocol default returns nil) leaves the typed
    /// fields absent — never "", never a guess inferred from the model's name.
    func testRun_noModelDetails_leavesFormatAndQuantizationNil() async throws {
        let runner = makeRunner(client: ScriptedClient(events: Self.healthyStream()))
        await runner.run(config: config(), repeats: 1, otherServers: [])

        let run = try XCTUnwrap(store.loadRuns().first)
        XCTAssertNil(run.modelFormat)
        XCTAssertNil(run.quantization)
    }

    /// The clock parameter has a default because reading a clock has no side effects; the seam
    /// exists for determinism, not for safety. RED: remove the default → this fails to compile,
    /// which is the point: every other seam on this type is required precisely because its
    /// default WOULD reach outward.
    func testRunner_usesTheRealClockWhenNoneIsInjected() async {
        let runner = GenerationBenchmarkRunner(
            client: ScriptedClient(events: Self.healthyStream()),
            probe: StubProvenanceProbe(), store: store,
            isBusy: { false }, appVersion: "1.8.8")
        await runner.run(config: config(), repeats: 1, otherServers: [])

        // A real clock over an instant stream produces a window too short to price — which is the
        // honest answer, and proves the default was used rather than a frozen instant.
        XCTAssertEqual(store.loadSamples().count, 2)
        XCTAssertTrue(store.loadSamples().allSatisfy { $0.void == .windowTooShort })
    }

    /// RED: pick the first reason seen → the message changes between identical runs depending on
    /// dictionary order, so two runs that failed the same way read as different failures.
    func testFailureMessage_isDeterministicUnderATie() {
        let runID = UUID()
        func sample(_ reason: BenchmarkVoidReason, _ index: Int) -> GenerationBenchmarkSample {
            GenerationBenchmarkSample(
                runID: runID, recordedAt: Date(), phase: .measured, sampleIndex: index,
                void: reason)
        }
        let samples = [sample(.transportError, 0), sample(.httpError, 1)]
        let first = GenerationBenchmarkRunner.failureMessage(for: samples)
        let second = GenerationBenchmarkRunner.failureMessage(for: samples.reversed())
        XCTAssertEqual(first, second)
    }

    func testFailureMessage_withNoSamplesAtAll() {
        XCTAssertEqual(GenerationBenchmarkRunner.failureMessage(for: []), "No usable samples.")
    }

    /// Every void reason must have a sentence; a `default:` arm would give a new one the wrong
    /// wording silently.
    func testDescribe_coversEveryVoidReason() {
        for reason in BenchmarkVoidReason.allCases {
            XCTAssertFalse(GenerationBenchmarkRunner.describe(reason).isEmpty)
        }
    }

    // MARK: - Fixtures

    /// Two deltas and a terminal usage event — enough for a measurable window once the stepping
    /// clock advances 500 ms per read.
    /// The step `SteppingClock` advances per read, so a test can convert a recorded window back
    /// into a count of events consumed.
    static let clockStepMs: Double = 500

    /// Hard bound on an async call; nil means it never finished. Turns "the suite hangs" into a
    /// named assertion — the difference between CI reporting a stuck job and CI reporting which
    /// guarantee was removed.
    static func withTimeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func healthyStream() -> [StreamEvent] {
        [
            StreamEvent(contentDelta: "hello"),
            StreamEvent(contentDelta: " world"),
            StreamEvent(tokenUsage: TokenUsage(inputTokens: 800, outputTokens: 401)),
        ]
    }

    // MARK: - The outcome's two halves are one fact

    /// `run` and `summary` are written together at the single construction site, so they are
    /// both-or-neither — and two fields that cannot vary independently must not be readable as if
    /// they could (CLAUDE.md #95).
    /// RED: `run.map { ($0, summary ?? BenchmarkMetricsPolicy.summarize([])) }` → the third case
    /// fabricates an empty summary and reports a run that measured nothing as recorded.
    func testOutcome_recordedIsBothOrNeither() {
        XCTAssertNil(BenchmarkRunOutcome.nothingRecorded.recorded)

        let run = GenerationBenchmarkRun(
            startedAt: Date(), provider: .ollama, baseURLString: "http://127.0.0.1:11434",
            modelName: "m", requestTimeoutSeconds: 600, promptID: BenchmarkPrompt.id,
            promptVersion: BenchmarkPrompt.version, repeats: 1,
            thermalState: BenchmarkThermalState.nominal, lowPowerMode: false,
            modelWasResident: true, appVersion: "1.0")
        let summary = BenchmarkMetricsPolicy.RunSummary(usableCount: 1, voidedCount: 0)

        XCTAssertNotNil(BenchmarkRunOutcome(run: run, summary: summary).recorded)
        XCTAssertNil(
            BenchmarkRunOutcome(run: run, summary: nil).recorded,
            "a run with no summary is not a recorded measurement")
    }

}

// MARK: - Doubles

/// Advances a fixed step on every read, so a run produces deterministic windows with no sleeps.
private final class SteppingClock: @unchecked Sendable {
    private let step: Duration
    private var current: ContinuousClock.Instant

    init(stepMilliseconds: Int) {
        self.step = .milliseconds(stepMilliseconds)
        self.current = ContinuousClock.now
    }

    func next() -> ContinuousClock.Instant {
        defer { current = current.advanced(by: step) }
        return current
    }
}

/// Replays a scripted event list, optionally throwing at the end of it.
private struct ScriptedClient: LLMClient {
    let events: [StreamEvent]
    var failure: Error?

    init(events: [StreamEvent], failure: Error? = nil) {
        self.events = events
        self.failure = failure
    }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: failure)
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// A long answer: many more deltas than the warm-up policy needs, then the terminal usage frame.
/// "Read to the end" and "stopped once it was decoding" therefore produce visibly different rows —
/// one has the server's token counts, the other cannot.
private struct LongStreamClient: LLMClient {
    let deltas: Int

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for index in 0..<deltas {
                continuation.yield(StreamEvent(contentDelta: "t\(index)"))
            }
            continuation.yield(
                StreamEvent(tokenUsage: TokenUsage(inputTokens: 800, outputTokens: 401)))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// Yields past the policy threshold and then NEVER ends — no terminal frame, no finish. The only
/// thing that can terminate it is the consumer letting go, so `terminations` answers "was the
/// request actually stopped" rather than "did we stop reading".
private final class UnendingStreamClient: LLMClient, @unchecked Sendable {
    let deltas: Int
    private let lock = NSLock()
    private var _terminations: [String] = []

    init(deltas: Int) { self.deltas = deltas }

    var terminations: [String] { lock.withLock { _terminations } }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [lock] reason in
                let label: String
                switch reason {
                case .cancelled: label = "cancelled"
                case .finished: label = "finished"
                @unknown default: label = "unknown"
                }
                lock.withLock { self._terminations.append(label) }
            }
            for index in 0..<deltas {
                continuation.yield(StreamEvent(contentDelta: "t\(index)"))
            }
            // Deliberately never finished.
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// Accepts the request and says nothing, forever — the shape a warm-up's delta policy can never
/// satisfy, and the only thing the deadline exists for.
private final class SilentStreamClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _terminations: [String] = []
    private var _didStart = false

    var terminations: [String] { lock.withLock { _terminations } }
    var didStart: Bool { lock.withLock { _didStart } }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _didStart = true }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [lock] reason in
                let label: String
                switch reason {
                case .cancelled: label = "cancelled"
                case .finished: label = "finished"
                @unknown default: label = "unknown"
                }
                lock.withLock { self._terminations.append(label) }
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// Reports the benchmark's target as already resident, which is the precondition the engine probe
/// is gated on.
private struct ResidentModelClient: LLMClient {
    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: "a"))
            continuation.yield(StreamEvent(contentDelta: "b"))
            continuation.yield(
                StreamEvent(tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 20)))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

    func listLoadedInstances(
        provider _: LLMProvider, baseURLString _: String
    ) async throws -> LoadedInstanceListing {
        .listed([LoadedModelInstance(modelName: "qwen3.8", instanceID: "qwen3.8:1")])
    }
}

/// Counts engine probes, so "was it skipped" is asserted rather than inferred from a hang.
private final class CountingEnginePR: ServerProvenanceProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var engineProbeCount: Int { lock.withLock { count } }

    func serverProvenance(config _: LLMConfig) async -> ServerProvenance { ServerProvenance() }

    func probeServingEngine(config _: LLMConfig) async -> ServerProvenance.Engine? {
        lock.withLock { count += 1 }
        return nil
    }
}

/// Stalls inside the ENGINE probe, which runs after the residency check, so a cancel lands at the
/// second gate rather than the first.
private final class SlowEnginePR: ServerProvenanceProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _didProbeEngine = false
    var didProbeEngine: Bool { lock.withLock { _didProbeEngine } }

    func serverProvenance(config _: LLMConfig) async -> ServerProvenance { ServerProvenance() }

    func probeServingEngine(config _: LLMConfig) async -> ServerProvenance.Engine? {
        lock.withLock { _didProbeEngine = true }
        try? await Task.sleep(for: .seconds(60))
        return nil
    }
}

/// Reports a model detail under the SAME label the provenance bag uses, so the merge rule has
/// something to arbitrate.
private struct CollidingDetailsClient: LLMClient {
    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: "a"))
            continuation.yield(StreamEvent(contentDelta: "b"))
            continuation.yield(
                StreamEvent(tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 20)))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

    func modelLoadDetails(config _: LLMConfig) async -> ModelLoadDetails? {
        ModelLoadDetails(fields: [.init(label: "Engines installed", value: "from the model details")])
    }
}

/// Reports the model's format and quantization the way both real clients do — under the
/// well-known `ModelLoadDetails` labels — so the capture path from details to the typed record
/// fields runs end to end.
private struct FormatDetailsClient: LLMClient {
    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: "a"))
            continuation.yield(StreamEvent(contentDelta: "b"))
            continuation.yield(
                StreamEvent(tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 20)))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

    func modelLoadDetails(config _: LLMConfig) async -> ModelLoadDetails? {
        ModelLoadDetails(fields: [
            .init(label: ModelLoadDetails.formatLabel, value: "gguf"),
            .init(label: ModelLoadDetails.quantizationLabel, value: "Q4_K_M"),
        ])
    }
}

/// Answers instantly and says nothing — the shape of a provider that reports no provenance.
/// Every runner test that is not ABOUT provenance uses this, so none of them depends on a probe
/// reaching a server.
private struct StubProvenanceProbe: ServerProvenanceProbe {
    var provenance = ServerProvenance()
    var servingEngine: ServerProvenance.Engine?

    func serverProvenance(config _: LLMConfig) async -> ServerProvenance { provenance }
    func probeServingEngine(config _: LLMConfig) async -> ServerProvenance.Engine? { servingEngine }
}

/// Stalls while the runner is still gathering provenance, so a cancel lands before the first
/// sample is taken.
private final class SlowProvenanceProbe: ServerProvenanceProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _didProbe = false
    var didProbe: Bool { lock.withLock { _didProbe } }

    func serverProvenance(config _: LLMConfig) async -> ServerProvenance {
        lock.withLock { _didProbe = true }
        try? await Task.sleep(for: .seconds(60))
        return ServerProvenance()
    }

    func probeServingEngine(config _: LLMConfig) async -> ServerProvenance.Engine? { nil }
}

/// Yields one delta and then hangs, so a run stays in flight until it is cancelled. The producer
/// is torn down through `onTermination`, the same shape the codebase's other time-aware stub uses.
/// Satisfies the warm-up policy on its first call, then hangs on every call after it.
///
/// The shape exists to reach a MEASURED sample and stop there: `HangingClient` stalls the warm-up
/// instead, so a run against it never gets past one. Nothing ever finishes the continuation, so the
/// only thing that can end the measured read is the consumer being cancelled — which is precisely
/// the case where the stream finishes rather than throwing.
private final class WarmThenHangingClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var _measuredSampleStarted = false

    var measuredSampleStarted: Bool { lock.withLock { _measuredSampleStarted } }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let isWarmUp = lock.withLock {
            calls += 1
            if calls > 1 { _measuredSampleStarted = true }
            return calls == 1
        }
        return AsyncThrowingStream { continuation in
            // The measured call yields NOTHING, and that is what makes the pin sharp. With events
            // buffered, the consumer's `for try await` runs at least one iteration and the
            // `checkCancellation` INSIDE the loop catches the stop — so the post-loop check is
            // never the thing under test, and removing it leaves the test green. With no events
            // the loop body never executes, the stream ends by being cancelled rather than by
            // throwing, and only a check AFTER the loop can tell that apart from "the model said
            // nothing".
            guard isWarmUp else { return }
            for index in 0..<(BenchmarkWarmUpPolicy.sufficientDeltas + 2) {
                continuation.yield(StreamEvent(contentDelta: "t\(index)"))
            }
            // Deliberately never finished.
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

private final class HangingClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _didStart = false
    private var _startCount = 0

    var didStart: Bool { lock.withLock { _didStart } }
    var startCount: Int { lock.withLock { _startCount } }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock {
            _didStart = true
            _startCount += 1
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: "hello"))
            // Deliberately never finished: the consumer's cancellation is what ends it.
            let waiter = Task {
                try? await Task.sleep(for: .seconds(60))
                continuation.finish()
            }
            continuation.onTermination = { _ in waiter.cancel() }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
