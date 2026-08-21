import Foundation

/// Watches one streaming request and turns it into a measurement.
///
/// Pure and `nonisolated`, with every instant passed IN rather than read from a clock — the shape
/// `AutovisorStuckEvaluator.evaluate(step:now:…)` uses, and for the same reason: it makes the
/// whole state machine testable by handing it instants, with no sleeps and no flakiness. The
/// runner is the only thing that touches a clock, and it uses `ContinuousClock` — never
/// `MonotonicClock`, whose readings are an ORDERING source and whose differences are not elapsed
/// time (`Duration+Milliseconds`).
nonisolated struct GenerationSampleRecorder {

    /// What one request produced. Every field optional because a stream can end at any point, and
    /// `void` names the first reason the sample cannot be used.
    struct Measurements: Equatable, Sendable {
        var inputTokens: Int?
        var outputTokens: Int?
        var timeToFirstTokenMs: Double?
        var generationMs: Double?
        var prefillMs: Double?
        var prefillSource: PrefillSource?
        var serverGenerationMs: Double?
        var serverGenerationTokensPerSecond: Double?
        var reasoningOutputTokens: Int?
        var modelLoadMs: Double?
        var appModelLoadMs: Double?
        var totalMs: Double?
        /// The SERVER's own clock on the same span `totalMs` measures — Ollama `total_duration`.
        /// Two clocks on one span is two facts, not one fact in two homes: their difference is
        /// the transport and scheduling the app pays and the server does not see.
        var serverTotalMs: Double?
        /// Why the server stopped — `"stop"` or `"length"`. The direct answer to whether the
        /// requested token ceiling was hit.
        var doneReason: String?
        var void: BenchmarkVoidReason?
    }

    let requestSentAt: ContinuousClock.Instant

    private(set) var firstDeltaAt: ContinuousClock.Instant?
    private(set) var lastDeltaAt: ContinuousClock.Instant?
    private(set) var promptProcessingStartedAt: ContinuousClock.Instant?
    private(set) var promptProcessingEndedAt: ContinuousClock.Instant?
    private(set) var deltaCount = 0
    private(set) var usage: TokenUsage?
    private(set) var serverPrefillNs: Double?
    private(set) var serverGenerationNs: Double?
    /// LM Studio states the same fact as a rate rather than a window; both are kept as sent and
    /// reconciled by `BenchmarkMetricsPolicy`, never converted into one another here (#80).
    private(set) var serverGenerationTokensPerSecond: Double?
    private(set) var reasoningOutputTokens: Int?
    private(set) var modelLoadMs: Double?
    private(set) var appModelLoadMs: Double?
    private(set) var serverTotalNs: Double?
    private(set) var doneReason: String?
    /// The consumer stopped reading on purpose rather than the stream ending.
    private(set) var wasStoppedEarly = false

    init(requestSentAt: ContinuousClock.Instant) {
        self.requestSentAt = requestSentAt
    }

    /// Records that nobody waited for the rest of this stream.
    ///
    /// Set by the runner when it truncates a warm-up (`BenchmarkWarmUpPolicy`), and read back in
    /// `measurements(endedAt:)`. It lives here rather than being applied to the finished
    /// `Measurements` by the caller so that every `void` in the history is still decided in ONE
    /// place — a second site deciding void reasons is how the same outcome ends up recorded under
    /// two names and `jq 'group_by(.void)'` stops meaning anything.
    mutating func stopEarly() {
        wasStoppedEarly = true
    }

    /// Folds one stream event in.
    ///
    /// Content and thinking deltas count the same: the server counts reasoning tokens in
    /// `outputTokens`, so a window that excluded them would divide a whole numerator by a partial
    /// denominator.
    mutating func note(_ event: StreamEvent, at instant: ContinuousClock.Instant) {
        if !event.contentDelta.isEmpty || !event.thinkingDelta.isEmpty {
            if firstDeltaAt == nil { firstDeltaAt = instant }
            lastDeltaAt = instant
            deltaCount += 1
        }

        // The server narrating its prefill. Only meaningful BEFORE the first token: a late frame
        // would otherwise stretch a window that has already closed.
        if let progress = event.processingProgress, firstDeltaAt == nil {
            if progress <= 0, promptProcessingStartedAt == nil {
                promptProcessingStartedAt = instant
            }
            if progress >= 1 { promptProcessingEndedAt = instant }
        }

        if let tokenUsage = event.tokenUsage { usage = tokenUsage }
        if let prefill = event.serverPrefill {
            if let ns = prefill.prefillNs { serverPrefillNs = ns }
            if let load = prefill.modelLoadMs { modelLoadMs = load }
        }
        if let ns = event.serverGenerationNs { serverGenerationNs = ns }
        if let rate = event.serverGenerationTokensPerSecond {
            serverGenerationTokensPerSecond = rate
        }
        if let reasoning = event.serverReasoningOutputTokens { reasoningOutputTokens = reasoning }
        if let ns = event.serverTotalNs { serverTotalNs = ns }
        if let reason = event.serverDoneReason { doneReason = reason }
        if let residency = event.clientResidency {
            if let load = residency.appModelLoadMs { appModelLoadMs = load }
        }
    }

    /// The finished measurement.
    ///
    /// `void` is resolved here rather than by the caller so the three "the stream ran but said
    /// nothing usable" cases are decided in one place, in a fixed order: no output at all beats no
    /// token count, which beats a window too short to divide by.
    func measurements(endedAt: ContinuousClock.Instant) -> Measurements {
        var result = Measurements()
        result.inputTokens = usage?.inputTokens
        result.outputTokens = usage?.outputTokens
        result.serverGenerationMs = serverGenerationNs.map { $0 / 1_000_000 }
        result.serverGenerationTokensPerSecond = serverGenerationTokensPerSecond
        result.reasoningOutputTokens = reasoningOutputTokens
        result.modelLoadMs = modelLoadMs
        result.appModelLoadMs = appModelLoadMs
        result.totalMs = requestSentAt.duration(to: endedAt).milliseconds
        result.serverTotalMs = serverTotalNs.map { $0 / 1_000_000 }
        result.doneReason = doneReason

        if let first = firstDeltaAt {
            result.timeToFirstTokenMs = requestSentAt.duration(to: first).milliseconds
            // Last delta, not stream end: the terminal frame and the transport teardown after it
            // are not generation, and folding them in would widen the denominator.
            if let last = lastDeltaAt {
                result.generationMs = first.duration(to: last).milliseconds
            }
        }

        let prefill = resolvePrefill(result.timeToFirstTokenMs)
        result.prefillMs = prefill?.milliseconds
        result.prefillSource = prefill?.source

        if wasStoppedEarly {
            // First in the ladder, and that order is the claim: a stream nobody finished reading
            // has no terminal usage frame BECAUSE it was stopped, so `noTokensReported` would
            // report our own decision back to us as a failure of the server's.
            result.void = .stoppedEarly
        } else if deltaCount == 0 {
            result.void = .noOutput
        } else if usage == nil {
            result.void = .noTokensReported
        } else if (result.generationMs ?? 0) < BenchmarkMetricsPolicy.minimumWindowMs {
            result.void = .windowTooShort
        }
        return result
    }

    /// Picks the prefill window from the best source that answered.
    ///
    /// Order is a claim about accuracy, not convenience:
    /// 1. the server measured it (`prompt_eval_duration`) — decode excluded, nothing inferred;
    /// 2. the server narrated it (`prompt_processing` frames) — the app times a window the server
    ///    delimited, and queue time sits before `.start`, so it is outside the window;
    /// 3. time to first token — the fallback, and the only APPROXIMATE one, because it also
    ///    contains queue time and model load. Marked so at the point of use rather than silently
    ///    averaged in with the other two.
    private func resolvePrefill(
        _ timeToFirstTokenMs: Double?
    ) -> (milliseconds: Double, source: PrefillSource)? {
        if let ns = serverPrefillNs {
            return (ns / 1_000_000, .serverPromptEval)
        }
        if let start = promptProcessingStartedAt, let end = promptProcessingEndedAt {
            let window = start.duration(to: end).milliseconds
            if window >= 0 { return (window, .promptProcessingFrames) }
        }
        if let ttft = timeToFirstTokenMs {
            return (ttft, .timeToFirstToken)
        }
        return nil
    }
}


// MARK: - Error classification

/// Turns a thrown streaming error into the reason a sample is unusable.
///
/// Separate and pure so the mapping is testable without a server, and so every void reason in the
/// history comes from ONE place — a per-call-site `catch` would drift into recording the same
/// failure under two different names and break `jq 'group_by(.void)'` after the fact.
nonisolated enum BenchmarkVoidClassifier {

    static func classify(_ error: Error) -> (reason: BenchmarkVoidReason, detail: String?) {
        if error is CancellationError { return (.cancelled, nil) }
        if let clientError = error as? LLMClientError {
            switch clientError {
            case .badHTTPStatus(let code, _):
                return (.httpError, "HTTP \(code)")
            case .rateLimited:
                return (.httpError, "HTTP 429")
            default:
                return (.transportError, clientError.errorDescription)
            }
        }
        if (error as NSError).code == NSURLErrorCancelled { return (.cancelled, nil) }
        return (.transportError, error.localizedDescription)
    }
}
