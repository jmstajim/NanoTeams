import Foundation

/// Every number the benchmark shows, and the rules for refusing to show one.
///
/// Pure and `nonisolated`: no clock, no state, no I/O. Both rate functions take the values they
/// divide rather than reading them, so every case below — including the ones that would divide by
/// zero — is testable without a server and without a sleep.
///
/// Two rate functions, not one, because the two windows mean different things and one of them
/// needs a fence-post correction the other must NOT get. See `clientRate` / `serverRate`.
nonisolated enum BenchmarkMetricsPolicy {

    // MARK: - Thresholds

    /// Below this a window is too narrow to divide by: at 4 ms, two tokens read as 250 tok/s.
    static let minimumWindowMs: Double = 50

    /// A rate needs at least this many tokens. Two is the arithmetic floor (one token spans no
    /// interval at all — see `clientRate`); eight is where a single tokenizer quirk stops moving
    /// the figure by double digits.
    static let minimumTokensForRate = 8

    /// Rows kept per model in the "recent runs" view before the store prunes.
    static let historyRowLimit = 500

    // MARK: - Rates

    /// Tokens per second over a CLIENT-measured window (`last delta − first delta`).
    ///
    /// The numerator is `tokens − 1`, and this is the whole reason the function exists rather
    /// than being written inline at two call sites. `n` deltas observed at `t₁ … tₙ` span exactly
    /// `n − 1` inter-token intervals: the first token defines the origin of the window and
    /// contributes no elapsed time to it. Dividing `n` by that window overstates the rate by
    /// `n / (n − 1)` — **+33% at n = 4, +11% at n = 10**. On 400 tokens of prose it is a rounding
    /// error; on a four-token tool call it is a third, and a benchmark has to be right on the
    /// sample somebody checks by hand.
    ///
    /// Returns `nil`, never `0`, when it will not divide: zero is a claim ("this model produces
    /// nothing per second"), `nil` is the absence of a measurement. Same rule as
    /// `ServerPrefillReport.nsPerToken`.
    static func clientRate(tokens: Int?, windowMs: Double?) -> Double? {
        guard let tokens, tokens >= 2,
              let windowMs, windowMs >= minimumWindowMs
        else { return nil }
        return Double(tokens - 1) / (windowMs / 1000)
    }

    /// Tokens per second over a SERVER-measured window (Ollama `eval_duration`).
    ///
    /// No fence-post correction here, deliberately: the server's decode window starts before it
    /// emits the first token, so all `tokens` were produced inside it. Applying `tokens − 1` to
    /// this window would understate the rate by `1/n` — the mirror image of the bug `clientRate`
    /// exists to avoid, which is why the two are separate functions with separate tests.
    static func serverRate(tokens: Int?, windowMs: Double?) -> Double? {
        guard let tokens, tokens >= 1,
              let windowMs, windowMs > 0
        else { return nil }
        return Double(tokens) / (windowMs / 1000)
    }

    /// Prompt tokens per second over the prefill window. Same shape as `serverRate`: the prefill
    /// window brackets the whole prompt, so every prompt token is inside it.
    static func prefillRate(promptTokens: Int?, windowMs: Double?) -> Double? {
        serverRate(tokens: promptTokens, windowMs: windowMs)
    }

    /// One sample's generation rate, and which source produced it.
    ///
    /// Order is a claim about provenance, not convenience. A window the server measured lets us
    /// do the division here and see both operands; a rate the server computed is taken on trust;
    /// the app's own window comes last because it also contains transport jitter and per-chunk
    /// scheduling. The two server branches never both answer — no provider reports both shapes —
    /// so their relative order is documentation rather than arbitration.
    ///
    /// `minimumTokensForRate` guards the reported-rate branch ALONE, and that asymmetry is the
    /// point: on the window branches the operands are visible and their fence-post treatment is
    /// pinned at `tokens: 1` and `tokens: 4`, so a floor there would contradict tests that encode
    /// deliberate intent. On the reported branch we cannot see what was divided, so a handful of
    /// tokens is exactly where the server's own arithmetic could be dominated by whatever it
    /// counts as the start of decoding — measured: LM Studio answers 1 000 000 tok/s for a
    /// one-token completion.
    static func generationRate(
        outputTokens: Int?,
        clientWindowMs: Double?,
        serverWindowMs: Double?,
        reportedRate: Double?
    ) -> (rate: Double, source: GenerationRateSource)? {
        if let rate = serverRate(tokens: outputTokens, windowMs: serverWindowMs) {
            return (rate, .serverDecodeWindow)
        }
        if let reportedRate, reportedRate.isFinite, reportedRate > 0,
           let outputTokens, outputTokens >= minimumTokensForRate {
            return (reportedRate, .serverReportedRate)
        }
        if let rate = clientRate(tokens: outputTokens, windowMs: clientWindowMs) {
            return (rate, .clientWindow)
        }
        return nil
    }

    // MARK: - Aggregation

    /// Median, or `nil` for an empty input. Median rather than mean because a single thermally
    /// unlucky sample must not move the figure — `benchmark_prompt_processing.sh` reaches the
    /// same conclusion for the same reason.
    ///
    /// `nil` entries are dropped BEFORE the count is taken, so an even/odd decision is made on
    /// the surviving values, not on the input length.
    static func median(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }.sorted()
        guard !present.isEmpty else { return nil }
        let mid = present.count / 2
        if present.count % 2 == 1 { return present[mid] }
        return (present[mid - 1] + present[mid]) / 2
    }

    /// The samples a figure may be computed from: measured phase only, no void reason.
    ///
    /// Two filters, not one. Dropping only voids would fold the warm-up — which paid for model
    /// load and KV materialisation — into the median; dropping only warm-ups would fold in an
    /// HTTP 500 that reported zero tokens.
    static func usableSamples(_ samples: [GenerationBenchmarkSample]) -> [GenerationBenchmarkSample] {
        samples.filter { $0.phase == .measured && $0.void == nil }
    }

    // MARK: - Per-run summary

    /// What one run is worth. `nil` figures mean "not measurable from these samples", and
    /// `usableCount == 0` means the run FAILED — never an empty success.
    struct RunSummary: Equatable, Sendable {
        /// The headline: the server's own figure wherever it exists, the app's window otherwise.
        /// Which one is in it is `generationRateSource` — the figure alone cannot say.
        var generationTokensPerSecond: Double?
        /// The source every usable sample agreed on, or `nil` when they disagreed.
        var generationRateSource: GenerationRateSource?
        /// The app-measured window, always computed and shown BESIDE the headline as a
        /// cross-check. On Ollama the pair agreed to 0.06 % on a live run (DEBTS.md), which is
        /// the only reason to trust either; before this existed, LM Studio rows had no such
        /// check at all.
        var clientGenerationTokensPerSecond: Double?
        var timeToFirstTokenMs: Double?
        var prefillTokensPerSecond: Double?
        /// The source every usable sample agreed on, or `nil` when they disagreed — in which case
        /// the figure is a mix and must not be labelled with a single source.
        var prefillSource: PrefillSource?
        /// Median share of output tokens the server attributed to reasoning, 0…1. Nil where the
        /// provider does not separate them.
        var reasoningTokenShare: Double?
        var usableCount: Int
        var voidedCount: Int

        var isFailed: Bool { usableCount == 0 }
        var prefillIsApproximate: Bool { prefillSource?.isApproximate ?? true }
        /// Unknown source reads as approximate, same rule as `prefillIsApproximate`: an unlabelled
        /// mixture is exactly the case a reader must not take at face value.
        var generationRateIsApproximate: Bool { generationRateSource?.isApproximate ?? true }
    }

    static func summarize(_ samples: [GenerationBenchmarkSample]) -> RunSummary {
        let usable = usableSamples(samples)
        // MEASURED samples only, and the reason is the warm-up: it is stopped on purpose the
        // moment it has done its job, so it carries a void every healthy run. Counting it here
        // would tell the user "1 sample could not be used and was excluded from the medians" after
        // every single successful run — about a sample that was never going to be in a median.
        let voided = samples.filter { $0.phase == .measured && $0.void != nil }.count

        let sources = Set(usable.compactMap(\.prefillSource))

        let rates = usable.map {
            generationRate(
                outputTokens: $0.outputTokens,
                clientWindowMs: $0.generationMs,
                serverWindowMs: $0.serverGenerationMs,
                reportedRate: $0.serverGenerationTokensPerSecond)
        }
        let rateSources = Set(rates.compactMap { $0?.source })

        return RunSummary(
            generationTokensPerSecond: median(rates.map { $0?.rate }),
            generationRateSource: rateSources.count == 1 ? rateSources.first : nil,
            clientGenerationTokensPerSecond: median(
                usable.map { clientRate(tokens: $0.outputTokens, windowMs: $0.generationMs) }),
            timeToFirstTokenMs: median(usable.map(\.timeToFirstTokenMs)),
            prefillTokensPerSecond: median(
                usable.map { prefillRate(promptTokens: $0.inputTokens, windowMs: $0.prefillMs) }),
            prefillSource: sources.count == 1 ? sources.first : nil,
            reasoningTokenShare: median(usable.map(reasoningShare)),
            usableCount: usable.count,
            voidedCount: voided)
    }

    /// Share of one sample's output the server called reasoning, 0…1.
    ///
    /// Nil rather than 0 when the provider reported no reasoning count: "none was reasoning" and
    /// "this provider does not say" are different facts, and only the first is a measurement.
    static func reasoningShare(_ sample: GenerationBenchmarkSample) -> Double? {
        guard let reasoning = sample.reasoningOutputTokens, reasoning >= 0,
              let output = sample.outputTokens, output > 0
        else { return nil }
        return min(Double(reasoning) / Double(output), 1)
    }

    // MARK: - Formatting

    /// Rendered in place of a figure that was not measured. A shared constant, not a literal at
    /// each site: the callers that DECORATE a value (unit suffix, approximate marker) have to
    /// recognise it, and two spellings would let one of them decorate the absence — "— tok/s"
    /// reads as a measurement of nothing.
    static let noValue = "—"


    /// Rate for display. One decimal below 10, whole numbers above — at 3 tok/s a whole token is
    /// a 30% difference and has to be visible; at 143 tok/s a decimal is noise.
    ///
    /// The threshold is applied to the ROUNDED value, so 9.96 formats as `"10"` (two characters)
    /// and not `"10.0"` (four). `PrefixCachePolicy.formatSeconds` has that off-by-one and gets
    /// away with it because nothing reserves width for its output; here a leaderboard column
    /// does.
    static func formatRate(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate >= 0 else { return noValue }
        if (rate * 10).rounded() / 10 < 10 {
            return String(format: "%.1f", rate)
        }
        return String(Int(rate.rounded()))
    }

    /// Milliseconds for display: `840 ms` below a second, `1.9 s` above.
    static func formatDuration(_ ms: Double?) -> String {
        guard let ms, ms.isFinite, ms >= 0 else { return noValue }
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        return String(format: "%.1f s", ms / 1000)
    }

}
