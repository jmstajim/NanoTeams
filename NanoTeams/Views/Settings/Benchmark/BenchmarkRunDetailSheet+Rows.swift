import Foundation

// MARK: - Pure presentation (unit-tested)

/// Every decision the detail sheet makes about what to print, as pure functions over the record.
///
/// Separated from the view for the reason the rest of this screen already is: a `View` body cannot
/// be asserted on, so a rule that lives only inside one is a rule with no pin.
extension BenchmarkRunDetailSheet {

    /// One label/value line.
    nonisolated struct DetailRow: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// One sample, already formatted. Every field is a `String` because the absent case is a
    /// dash and not a zero, and deciding that per cell in the view is how "0 tok/s" gets printed
    /// about a sample that measured nothing.
    nonisolated struct SampleRow: Identifiable, Equatable, Sendable {
        let id: UUID
        let index: String
        let promptTokens: String
        let outputTokens: String
        let ttft: String
        let prefill: String
        let generation: String
        let load: String
        let total: String
        let stop: String
        let outcome: String
        let isVoid: Bool
    }

    static let sampleColumnTitles = [
        "#", "Prompt", "Output", "TTFT", "Prefill", "Generation", "Load", "Total", "Stop",
        "Outcome",
    ]

    static func subtitle(for run: GenerationBenchmarkRun) -> String {
        [
            run.provider.displayName,
            run.baseURLString.endpointHostLabel,
            BenchmarkResultsCard.runTimestampFull(run.startedAt),
        ].joined(separator: " · ")
    }

    // MARK: Samples

    /// The warm-up first, then the measured samples in the order they ran.
    ///
    /// The warm-up is IN this table, and that is the point of the table. It is the one sample the
    /// medians deliberately exclude — it pays for loading the model and materialising the KV
    /// cache — so a reader who wants to know what loading cost has nowhere else to look. It
    /// carries `stoppedEarly` on every healthy run, which is why its outcome reads as a note
    /// rather than as a failure.
    static func sampleRows(for samples: [GenerationBenchmarkSample]) -> [SampleRow] {
        samples
            .sorted {
                if $0.phase != $1.phase { return $0.phase == .warmup }
                return $0.sampleIndex < $1.sampleIndex
            }
            .map { sample in
                let rate = BenchmarkMetricsPolicy.generationRate(
                    outputTokens: sample.outputTokens,
                    clientWindowMs: sample.generationMs,
                    serverWindowMs: sample.serverGenerationMs,
                    reportedRate: sample.serverGenerationTokensPerSecond)
                let prefill = BenchmarkMetricsPolicy.prefillRate(
                    promptTokens: sample.inputTokens, windowMs: sample.prefillMs)
                return SampleRow(
                    id: sample.id,
                    index: sample.phase == .warmup ? "warm-up" : "\(sample.sampleIndex + 1)",
                    promptTokens: count(sample.inputTokens),
                    outputTokens: outputTokenCell(sample),
                    ttft: BenchmarkMetricsPolicy.formatDuration(sample.timeToFirstTokenMs),
                    prefill: BenchmarkRunCard.decorate(
                        value: BenchmarkMetricsPolicy.formatRate(prefill),
                        unit: "",
                        approximate: sample.prefillSource?.isApproximate ?? true),
                    generation: BenchmarkRunCard.decorate(
                        value: BenchmarkMetricsPolicy.formatRate(rate?.rate),
                        unit: "",
                        approximate: rate?.source.isApproximate ?? true),
                    load: loadCell(sample),
                    total: totalCell(sample),
                    stop: sample.doneReason ?? BenchmarkMetricsPolicy.noValue,
                    outcome: outcome(sample),
                    isVoid: sample.void != nil)
            }
    }

    /// Output tokens, with the reasoning share named where the provider separates it — the number
    /// beside it is the denominator of the Generation cell, and a reader comparing two models on
    /// speed alone would otherwise miss that one of them spent most of it thinking.
    private static func outputTokenCell(_ sample: GenerationBenchmarkSample) -> String {
        guard let output = sample.outputTokens else { return BenchmarkMetricsPolicy.noValue }
        guard let reasoning = sample.reasoningOutputTokens, reasoning > 0 else { return "\(output)" }
        return "\(output) (\(reasoning) thinking)"
    }

    /// Server-reported load where the server reported one, the app's own measurement otherwise —
    /// and the cell says which. The two are different facts on different clocks, and a column that
    /// silently mixed them would be exactly the "an inference indistinguishable from a
    /// measurement" defect the Format column was rewritten to avoid.
    private static func loadCell(_ sample: GenerationBenchmarkSample) -> String {
        if let server = sample.modelLoadMs {
            return BenchmarkMetricsPolicy.formatDuration(server)
        }
        guard let app = sample.appModelLoadMs else { return BenchmarkMetricsPolicy.noValue }
        return BenchmarkMetricsPolicy.formatDuration(app) + " (app)"
    }

    /// The app's clock, and the server's beside it where the server keeps one. The gap between
    /// them is transport and scheduling — the difference between a slow model and a busy machine.
    private static func totalCell(_ sample: GenerationBenchmarkSample) -> String {
        let app = BenchmarkMetricsPolicy.formatDuration(sample.totalMs)
        guard let server = sample.serverTotalMs else { return app }
        return app + " · srv " + BenchmarkMetricsPolicy.formatDuration(server)
    }

    /// What became of a sample. Empty for one that counted — a word there would put "ok" on every
    /// healthy row and bury the one row that says something.
    static func outcome(_ sample: GenerationBenchmarkSample) -> String {
        guard let void = sample.void else { return "" }
        let reason = sample.phase == .warmup && void == .stoppedEarly
            ? "stopped once warm"
            : void.rawValue
        guard let detail = sample.voidDetail, !detail.isEmpty else { return reason }
        return "\(reason) — \(detail)"
    }

    private static func count(_ value: Int?) -> String {
        value.map { "\($0)" } ?? BenchmarkMetricsPolicy.noValue
    }

    // MARK: Conditions

    /// The run's own typed fields — what the app asked for and what the machine was doing.
    ///
    /// Format and Quantization appear here even though `serverFields` may also carry them: these
    /// are the typed fields, promoted at decode so they are present on rows recorded before the
    /// columns existed, while the dictionary below is whatever the server actually sent.
    static func conditionRows(for run: GenerationBenchmarkRun) -> [DetailRow] {
        var rows: [DetailRow] = [
            DetailRow(label: "Provider", value: run.provider.displayName),
            DetailRow(label: "Endpoint", value: run.baseURLString),
        ]
        rows.append(DetailRow(
            label: "Server version", value: run.providerVersion ?? BenchmarkMetricsPolicy.noValue))
        if let instance = run.instanceID {
            rows.append(DetailRow(label: "Instance", value: instance))
        }
        rows.append(DetailRow(
            label: "Format", value: ModelDescriptorText.format(run.modelFormat)
                ?? BenchmarkMetricsPolicy.noValue))
        rows.append(DetailRow(
            label: "Quantization", value: ModelDescriptorText.quantization(run.quantization)
                ?? BenchmarkMetricsPolicy.noValue))
        rows.append(DetailRow(label: "Prompt", value: "\(run.promptID) v\(run.promptVersion)"))
        rows.append(DetailRow(label: "Repeats", value: "\(run.repeats)"))
        rows.append(DetailRow(
            label: "Temperature",
            value: run.temperature.map { "\($0)" } ?? "not sent"))
        rows.append(DetailRow(label: "Request timeout", value: "\(run.requestTimeoutSeconds) s"))
        rows.append(DetailRow(
            label: "Keep-alive",
            value: run.keepAliveSeconds.map { "\($0) s" } ?? "not sent"))
        // Two rows, not one. `wasThrottled` is their OR, and it is already what the warning glyph
        // says; folding them here would make a third representation of one fact and lose which of
        // the two was true (CLAUDE.md #95).
        rows.append(DetailRow(label: "Thermal state", value: run.thermalState))
        rows.append(DetailRow(label: "Low Power Mode", value: yesNo(run.lowPowerMode)))
        rows.append(DetailRow(
            label: "Model was resident",
            value: run.modelWasResident ? "yes — it was already loaded" : "no — it was loaded first"))
        rows.append(DetailRow(label: "App version", value: run.appVersion))
        return rows
    }

    static func serverFieldRows(for run: GenerationBenchmarkRun) -> [DetailRow] {
        // Key-sorted so two runs of the same model can be read side by side, and VERBATIM: this
        // string is what you would match against a model card or another tool's output, and a
        // tidied-up spelling would match nothing.
        run.serverFields.keys.sorted().map { DetailRow(label: $0, value: run.serverFields[$0] ?? "") }
    }

    static func samplingParameterRows(for run: GenerationBenchmarkRun) -> [DetailRow] {
        run.samplingParameters.keys.sorted().map {
            DetailRow(label: $0, value: run.samplingParameters[$0] ?? "")
        }
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    // MARK: Wording

    static let ratesHelp =
        "The medians this run contributes to the tables, over its usable samples. The same figures "
            + "the Runs row shows, plus the two it has no column for: how much of the output was "
            + "reasoning, and the app's own timing of a generation the server measured itself."

    static let samplesHelp =
        "Every sample this run took, including the warm-up and every one the medians excluded — "
            + "with the reason. The warm-up pays for loading the model and is stopped as soon as "
            + "it is decoding, so it is the only place the load cost is visible, and its "
            + "\"stopped once warm\" note is the healthy outcome rather than a failure."

    static let conditionsHelp =
        "What was asked for and what the machine was doing at the time. A run measured while "
            + "thermally throttled or in Low Power Mode describes that state as much as the model."

    static let serverFieldsHelp =
        "What the server reported about itself and the loaded model, verbatim and untranslated. "
            + "The key set differs between providers and between builds by design — a field a "
            + "server starts reporting tomorrow lands here without a schema change."

    static let samplingHelp =
        "The generation parameters the model was loaded with, where the server reports them."

    static let noServerFields =
        "This server reported nothing about itself on this run. Recorded as silence rather than "
            + "as empty values — the two are different, and only one of them is a measurement."

    static func noSamplingParameters(provider: LLMProvider) -> String {
        switch provider {
        case .lmStudio:
            "LM Studio keeps sampling parameters in its per-model config and does not report them "
                + "over its REST API, so this run has none recorded — not because none were used."
        case .ollama:
            "This run recorded no sampling parameters."
        }
    }
}
