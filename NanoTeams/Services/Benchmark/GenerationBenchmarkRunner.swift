import Foundation
import Observation

/// Runs a generation-speed benchmark against the configured model and records the result.
///
/// Owns only the orchestration: the arithmetic lives in `BenchmarkMetricsPolicy`, the measurement
/// in `GenerationSampleRecorder`, the ranking in `BenchmarkLeaderboard`, and persistence in
/// `BenchmarkHistoryStore`. This class touches the clock — `ContinuousClock`, never
/// `MonotonicClock`, whose readings order events rather than measure elapsed time.
///
/// Every dependency is REQUIRED, with no default. A `client: any LLMClient = LLMClientRouter()`
/// default would resolve outward to a live server, so a test that forgot the argument would fire
/// real generations at whatever is listening on the user's machine — the shape CLAUDE.md #49 was
/// written about. Here a forgotten argument fails to compile instead.
@MainActor
@Observable
final class GenerationBenchmarkRunner {

    enum Phase: Equatable, Sendable {
        case idle
        /// Collecting provenance (server version, model metadata) before the first request.
        case preparing
        /// The throwaway request that pays for model load and KV materialisation, stopped as soon
        /// as it has (`BenchmarkWarmUpPolicy`) rather than read to the end.
        case warmingUp
        case measuring(sample: Int, of: Int)
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var summary: BenchmarkMetricsPolicy.RunSummary?
    private(set) var lastRun: GenerationBenchmarkRun?

    private let client: any LLMClient
    /// Asks the server about itself. Required, with no default, for the same reason `client` is:
    /// a defaulted probe would resolve OUTWARD to a live server, and a forgotten argument would
    /// compile (#49).
    private let probe: any ServerProvenanceProbe
    private let store: BenchmarkHistoryStore
    /// Whether any other LLM stream is in flight. The app's own H1 hygiene check: roles run
    /// concurrently by design, and a sample taken while another stream shares the machine measures
    /// the two of them together.
    private let isBusy: @MainActor () -> Bool
    private let appVersion: String
    /// Reads the elapsed-time clock. Injectable so tests drive a whole run with hand-advanced
    /// instants instead of real sleeps — a 60 ms sleep would make every timing assertion loose
    /// enough to stop distinguishing the bugs it was written for.
    ///
    /// The default resolves INWARD (a clock read has no side effects and reaches no server), so
    /// unlike `client` and `store` it is safe to default.
    private let now: @MainActor () -> ContinuousClock.Instant
    /// Hard ceiling on the warm-up. Injectable for the same reason `now` is — the deadline path
    /// only fires against a stream that produces nothing, and a test that had to wait out the real
    /// one would take ten seconds to assert a single fact, so it would not be written.
    ///
    /// Defaulted, unlike `client`/`probe`/`store`: a `Duration` reaches no server and has no
    /// side effects, so a forgotten argument here cannot start real work (#49 is about the
    /// arguments whose `nil` resolves OUTWARD).
    private let warmUpDeadline: Duration

    /// Whether a measurement is in flight, derived from `phase`.
    ///
    /// Read for RENDERING only, never as a start guard. `phase` is assigned inside `run`, so two
    /// callers arriving in the same runloop turn would both see `.idle` and both proceed — which
    /// is why the door is a stored flag on `BenchmarkSweepRunner`, set synchronously before its
    /// task is spawned, and why this class no longer offers a `start` for anyone to race.
    var isRunning: Bool {
        switch phase {
        case .idle, .finished, .failed: false
        case .preparing, .warmingUp, .measuring: true
        }
    }

    init(
        client: any LLMClient,
        probe: any ServerProvenanceProbe,
        store: BenchmarkHistoryStore,
        isBusy: @escaping @MainActor () -> Bool,
        appVersion: String = AppVersion.current,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        warmUpDeadline: Duration = BenchmarkWarmUpPolicy.deadline
    ) {
        self.client = client
        self.probe = probe
        self.store = store
        self.isBusy = isBusy
        self.appVersion = appVersion
        self.now = now
        self.warmUpDeadline = warmUpDeadline
    }

    // MARK: - Run

    /// Measures one model and records it. Directly callable — and now ONLY directly callable: this
    /// class no longer owns a `Task`, because the thing that decides how many models are measured
    /// and when to stop is the thing that should own cancellation, and that is
    /// `BenchmarkSweepRunner`. A single run is a sweep of one target, so there is one loop, one
    /// Cancel and one "is anything measuring" predicate rather than two of each.
    ///
    /// Cancellation still lands here exactly as it did: `run` is awaited FROM the sweep's task, so
    /// every `Task.isCancelled` / `checkCancellation()` below reads that task's state, and
    /// `consumeWarmUp`'s `withTaskCancellationHandler` forwards it into the unstructured reader.
    ///
    /// `otherServers` names the machines the CALLER knows of besides the target's. It is required
    /// rather than defaulted: an empty array is a real answer, but it is also the answer that
    /// quietly reinstates a run measured beside a model on the other provider's server.
    @discardableResult
    func run(
        config: LLMConfig, repeats: Int, otherServers: [BenchmarkServer]
    ) async -> BenchmarkRunOutcome {
        // The guard lives HERE, on the shared resource, not only on the sequencer that normally
        // calls it. There is one machine and one model may be resident on it; two overlapping runs
        // would each unload the other's target and then measure the two streams together, which is
        // the exact contamination the residency preparer and `isBusy` exist to prevent. A guard
        // that sat only at the call site would be a coincidence rather than a defence (#51).
        guard !isRunning else { return .nothingRecorded }
        phase = .preparing
        summary = nil

        // Clear the machine BEFORE anything is measured: a co-resident model competes for memory
        // bandwidth and unified memory, so a figure taken beside one describes the pair rather
        // than the model. What this achieved rides into the run's provenance either way — a
        // benchmark that could not clear the machine is still worth running, but the reader has
        // to be able to tell which of the two happened.
        let residency = await BenchmarkResidencyPreparer.prepare(
            target: BenchmarkTarget(seededFrom: config),
            otherServers: otherServers,
            client: client)

        // Ask the server about itself BEFORE anything is measured, so the row can name what
        // produced it even if the measurement later fails.
        let provenance = await probe.serverProvenance(config: config)
        let details = await client.modelLoadDetails(config: config)

        guard !Task.isCancelled else {
            phase = .idle
            return .nothingRecorded
        }

        // The serving-engine probe SPENDS a one-token completion, so it runs only once the
        // preparer has confirmed the model is already in memory. Against a cold server it would
        // instead trigger a load outside `ChatModelEnsurer` — undoing the residency just
        // established, and leaving the warm-up to face a second instance of the same model.
        let servingEngine = residency.targetResidentAfterPrepare
            ? await probe.probeServingEngine(config: config)
            : nil

        guard !Task.isCancelled else {
            phase = .idle
            return .nothingRecorded
        }

        let runID = UUID()
        let startedAt = Date()
        var samples: [GenerationBenchmarkSample] = []

        phase = .warmingUp
        samples.append(await measure(config: config, runID: runID, phase: .warmup, index: 0))

        for index in 0..<max(repeats, 0) {
            if Task.isCancelled { break }
            phase = .measuring(sample: index + 1, of: repeats)
            samples.append(
                await measure(config: config, runID: runID, phase: .measured, index: index))
        }

        let run = GenerationBenchmarkRun(
            id: runID,
            startedAt: startedAt,
            provider: config.provider,
            baseURLString: config.baseURLString.normalizedBaseURL,
            modelName: config.modelName,
            instanceID: residency.targetInstanceID,
            providerVersion: provenance.version,
            modelFormat: details?.format,
            quantization: details?.quantization,
            serverFields: BenchmarkProvenance.serverFields(from: details)
                .merging(BenchmarkProvenance.residencyFields(residency)) { current, _ in current }
                .merging(BenchmarkProvenance.provenanceFields(provenance, servingEngine: servingEngine)) {
                    current, _ in current
                }
                .merging(
                    BenchmarkProvenance.outputCapField(
                        requested: config.maxOutputTokens,
                        measuredSamples: samples.filter { $0.phase == .measured })
                ) { current, _ in current },
            samplingParameters: BenchmarkProvenance.samplingParameters(from: details),
            temperature: config.temperature,
            requestTimeoutSeconds: config.requestTimeoutSeconds,
            keepAliveSeconds: config.keepAliveSeconds,
            promptID: BenchmarkPrompt.id,
            promptVersion: BenchmarkPrompt.version,
            repeats: repeats,
            thermalState: BenchmarkThermalState.label(for: ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            // The preparer's answer, and only it. It asked the server directly, before anything
            // was measured. The alternative was to infer residency from the warm-up's reported
            // load time — which a warm-up that stops as soon as decoding begins never receives,
            // since every provider puts that number in the terminal frame. An inference whose
            // input is structurally absent is not a fallback, it is a constant wearing one.
            modelWasResident: residency.targetWasResident,
            appVersion: appVersion)

        store.append(run: run)
        store.append(samples: samples)
        store.prune()

        let result = BenchmarkMetricsPolicy.summarize(samples)
        summary = result
        lastRun = run
        // A run with nothing usable is a FAILURE, never an empty success — the whole reason void
        // reasons are recorded rather than dropped.
        let failure = result.isFailed ? Self.failureMessage(for: samples) : nil
        phase = failure.map(Phase.failed) ?? .finished
        // Returned rather than left for the caller to read off `phase` and `summary`. A sweep
        // records an outcome per target, and reading two observable properties after an `await` —
        // even correctly, on one actor — is a contract that holds only until someone adds a
        // suspension point. The value says what happened; the properties say what to render.
        return BenchmarkRunOutcome(run: run, summary: result, failure: failure)
    }

    // MARK: - One sample

    private func measure(
        config: LLMConfig,
        runID: UUID,
        phase samplePhase: GenerationBenchmarkSample.Phase,
        index: Int
    ) async -> GenerationBenchmarkSample {
        // Re-checked per sample, not once per run: another role can start streaming halfway
        // through, and the samples taken after that point are the contaminated ones.
        if isBusy() {
            return voided(
                runID: runID, phase: samplePhase, index: index,
                reason: .concurrentActivity,
                detail: "another LLM stream was running")
        }
        // No `Task.isCancelled` check here on purpose. The run loop checks before every sample
        // and the preparation guard checks before the warm-up, and there is no suspension point
        // between either of those and this line — so a check here could never observe a
        // cancellation the caller had not already caught. A cancel that lands DURING the stream is
        // caught by `Task.checkCancellation()` below and classified as `.cancelled`, which is the
        // one path that can actually happen.
        var recorder = GenerationSampleRecorder(requestSentAt: now())
        do {
            // No logger: a benchmark is not part of any task's run, and writing it into a task's
            // network log would put synthetic traffic in an audit trail of real work.
            //
            // prefix-cache-owner: deliberately none. Every sample leads with a fresh nonce
            // (`BenchmarkPrompt.messages(nonce:)`) precisely so it CANNOT reuse a prefix — that is
            // what makes the prefill figure a cold measurement instead of a cache lookup. A caller
            // that never accumulates a prefix can be neither a victim nor a beneficiary, so
            // registering it would file a chain that structurally never grows. It cannot be a
            // suspect either: the runner refuses to sample while any task is streaming
            // (`isBusy`), so it never interleaves with a caller that does hold a warm prefix.
            let stream = client.streamChat(
                config: config,
                messages: BenchmarkPrompt.messages(nonce: BenchmarkPrompt.freshNonce()),
                tools: [],
                logger: nil,
                stepID: nil,
                roleName: "benchmark")
            if samplePhase == .warmup {
                let outcome = await consumeWarmUp(stream, into: recorder)
                recorder = outcome.recorder
                // A cancel that landed inside the bounded consume is a cancel, not a policy stop:
                // both exit the read the same way, and only the parent's state tells them apart.
                try Task.checkCancellation()
                if let failure = outcome.failure {
                    var measurements = recorder.measurements(endedAt: now())
                    measurements.void = failure.reason
                    var built = sample(
                        runID: runID, phase: samplePhase, index: index, from: measurements)
                    built.voidDetail = failure.detail
                    return built
                }
            } else {
                for try await event in stream {
                    try Task.checkCancellation()
                    recorder.note(event, at: now())
                }
                // The loop above can only observe a cancellation that arrives BETWEEN events. A
                // cancelled `AsyncThrowingStream` does not throw — its termination handler finishes
                // the continuation, so `next()` returns nil and the loop exits exactly as it would
                // if the server had ended the answer (CLAUDE.md #88). Without this line a sample
                // the user cut off is recorded as a complete measurement of a short reply, and its
                // rate lands in the leaderboard as if the model had produced it.
                try Task.checkCancellation()
            }
            return sample(
                runID: runID, phase: samplePhase, index: index,
                from: recorder.measurements(endedAt: now()))
        } catch {
            // Keep whatever was measured before the failure: "died at token 3" and "died at token
            // 3000" are different facts, and only the partial record tells them apart.
            var measurements = recorder.measurements(endedAt: now())
            let classified = BenchmarkVoidClassifier.classify(error)
            measurements.void = classified.reason
            var built = sample(runID: runID, phase: samplePhase, index: index, from: measurements)
            built.voidDetail = classified.detail
            return built
        }
    }

    /// Reads a warm-up only as far as it needs to be read, then stops the request.
    ///
    /// Two exits, and the second is the reason this is not a `break` inside the loop above:
    /// `BenchmarkWarmUpPolicy.isSatisfied` fires once the model is demonstrably decoding, but a
    /// stream that never produces a token would sit in `await` forever, and there is no suspension
    /// to check a deadline on. So the read runs in its own task with a watchdog that cancels it at
    /// `BenchmarkWarmUpPolicy.deadline`.
    ///
    /// Stopping IS the cancellation: dropping the iterator fires the stream's `onTermination`,
    /// which cancels the underlying URLSession task on both clients. That is the identical seam
    /// in-stream loop detection uses to stop a model mid-answer (`LLMExecutionService+Streaming`).
    ///
    /// The read task is unstructured, so the run's own cancellation does not reach it by descent —
    /// `withTaskCancellationHandler` is what forwards it. Without that, cancelling a run during
    /// the warm-up would leave the request alive for the rest of the deadline.
    private func consumeWarmUp(
        _ stream: AsyncThrowingStream<StreamEvent, Error>,
        into recorder: GenerationSampleRecorder
    ) async -> (
        recorder: GenerationSampleRecorder,
        failure: (reason: BenchmarkVoidReason, detail: String?)?
    ) {
        let reader = Task {
            () -> (GenerationSampleRecorder, Bool, (BenchmarkVoidReason, String?)?) in
            var recorder = recorder
            var stopped = false
            var failure: (BenchmarkVoidReason, String?)?
            do {
                for try await event in stream {
                    recorder.note(event, at: now())
                    if BenchmarkWarmUpPolicy.isSatisfied(deltaCount: recorder.deltaCount) {
                        stopped = true
                        break
                    }
                }
                // A cancelled `AsyncThrowingStream` does NOT throw: its cancellation handler
                // finishes the continuation, so `next()` returns nil and the loop above exits as
                // if the server had ended the answer. Without this line the deadline path records
                // `noOutput` — "the model produced no output" — for a request the app itself cut
                // off, which is the same class of lie as reporting our own stop as the server
                // failing to report tokens.
                if Task.isCancelled { stopped = true }
            } catch is CancellationError {
                // Defensive: a client that surfaces cancellation as a throw instead. Same fact.
                stopped = true
            } catch {
                // A real failure, classified in the one place that classifies them so a warm-up's
                // row cannot record the same outcome under a different name than a measured row.
                failure = BenchmarkVoidClassifier.classify(error)
            }
            return (recorder, stopped, failure)
        }
        let deadline = warmUpDeadline
        let watchdog = Task {
            try await Task.sleep(for: deadline)
            reader.cancel()
        }
        defer { watchdog.cancel() }

        var (result, stopped, failure) = await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
        // Only when it really was cut short. A model whose whole answer fits inside the policy
        // window ends the stream by itself, terminal frame included, and that row is a complete
        // record — labelling it "stopped early" would describe a decision nobody made.
        if stopped { result.stopEarly() }
        return (result, failure.map { (reason: $0.0, detail: $0.1) })
    }

    private func sample(
        runID: UUID,
        phase: GenerationBenchmarkSample.Phase,
        index: Int,
        from measurements: GenerationSampleRecorder.Measurements
    ) -> GenerationBenchmarkSample {
        GenerationBenchmarkSample(
            runID: runID,
            recordedAt: Date(),
            phase: phase,
            sampleIndex: index,
            inputTokens: measurements.inputTokens,
            outputTokens: measurements.outputTokens,
            timeToFirstTokenMs: measurements.timeToFirstTokenMs,
            generationMs: measurements.generationMs,
            prefillMs: measurements.prefillMs,
            prefillSource: measurements.prefillSource,
            serverGenerationMs: measurements.serverGenerationMs,
            serverGenerationTokensPerSecond: measurements.serverGenerationTokensPerSecond,
            reasoningOutputTokens: measurements.reasoningOutputTokens,
            modelLoadMs: measurements.modelLoadMs,
            appModelLoadMs: measurements.appModelLoadMs,
            totalMs: measurements.totalMs,
            serverTotalMs: measurements.serverTotalMs,
            doneReason: measurements.doneReason,
            void: measurements.void)
    }

    private func voided(
        runID: UUID,
        phase: GenerationBenchmarkSample.Phase,
        index: Int,
        reason: BenchmarkVoidReason,
        detail: String? = nil
    ) -> GenerationBenchmarkSample {
        GenerationBenchmarkSample(
            runID: runID,
            recordedAt: Date(),
            phase: phase,
            sampleIndex: index,
            void: reason,
            voidDetail: detail)
    }

    /// Names the dominant reason rather than saying "failed". A run that produced nothing is a
    /// question ("why?"), and the answer is already in the samples.
    ///
    /// Measured samples only. The warm-up is stopped on purpose in every healthy run, so including
    /// it would let "the warm-up was stopped once it had done its job" become the stated cause of
    /// a failure it had nothing to do with — and with `repeats: 0` it would be the ONLY reason
    /// there is.
    static func failureMessage(for samples: [GenerationBenchmarkSample]) -> String {
        let reasons = samples.filter { $0.phase == .measured }.compactMap(\.void)
        guard let dominant = reasons.mostFrequent() else {
            return "No usable samples."
        }
        return "No usable samples — \(Self.describe(dominant))."
    }

    static func describe(_ reason: BenchmarkVoidReason) -> String {
        switch reason {
        case .httpError: "the server returned an error"
        case .transportError: "the request failed"
        case .cancelled: "the run was cancelled"
        case .noTokensReported: "the server reported no token counts"
        case .noOutput: "the model produced no output"
        case .concurrentActivity: "another LLM stream was running"
        case .windowTooShort: "the responses were too short to time"
        case .stoppedEarly: "the sample was stopped once it had done its job"
        }
    }
}

private extension Array where Element: Hashable {
    /// Most frequent element, ties broken deterministically so a failure message does not change
    /// wording between identical runs.
    func mostFrequent() -> Element? where Element: RawRepresentable, Element.RawValue == String {
        var counts: [Element: Int] = [:]
        for element in self { counts[element, default: 0] += 1 }
        return counts.max {
            ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue)
        }?.key
    }
}
