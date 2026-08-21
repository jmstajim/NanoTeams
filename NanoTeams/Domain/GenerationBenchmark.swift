import Foundation

// MARK: - Prefill source

/// Which measurement the prompt-prefill window came from.
///
/// Recorded per SAMPLE, never assumed per provider: LM Studio narrates its prefill with
/// `prompt_processing.*` SSE frames on some builds and not others, so the same server can
/// produce both `.promptProcessingFrames` and `.timeToFirstToken` rows. Mixing the three under
/// one label is exactly what `prefill_src` in `bench_baseline/results.jsonl` exists to prevent —
/// a row measured one way is not comparable to a row measured another.
nonisolated enum PrefillSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// Ollama `prompt_eval_duration` — server-measured, decode excluded. Exact.
    case serverPromptEval
    /// LM Studio: the app's own clock across the server-narrated `prompt_processing`
    /// 0.0 → 1.0 window. The queue sits BEFORE `.start`, so it is excluded by construction.
    case promptProcessingFrames
    /// Time to first token, used when the server narrated nothing. APPROXIMATE: it also
    /// contains queue time and model load, so the window is too wide and the rate too low.
    case timeToFirstToken

    /// Whether a figure derived from this source must be marked as approximate in the UI.
    var isApproximate: Bool { self == .timeToFirstToken }
}

// MARK: - Generation-rate source

/// Where a generation rate came from. The exact counterpart of `PrefillSource`, and for the same
/// reason: three sources can produce the same column, and a row measured one way is not
/// comparable to a row measured another unless the row says which.
///
/// The two server shapes are not a redundancy — neither provider reports the other's: Ollama
/// states the decode WINDOW (`eval_duration`), LM Studio states the RATE
/// (`tokens_per_second`). They are kept apart because a division we performed and a division the
/// server performed are different claims: the first one we can show the operands for, the second
/// we take on trust.
///
/// Measured 2026-08-19 on LM Studio 0.4.21: its rate is
/// `completion_tokens / (generation_time − time_to_first_token)` to 0.00 % across five completion
/// lengths — decode only, numerator NOT fence-post corrected, i.e. exactly the convention
/// `BenchmarkMetricsPolicy.serverRate` applies to Ollama's window. That measurement is what makes
/// one shared column legitimate; this label is what keeps it honest if a build changes its mind.
nonisolated enum GenerationRateSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// Ollama `eval_duration`: tokens ÷ the server's decode window, divided here.
    case serverDecodeWindow
    /// LM Studio `tokens_per_second`: the server's own rate, verbatim.
    case serverReportedRate
    /// No server figure — the app's own first-delta → last-delta window. APPROXIMATE: it also
    /// carries transport jitter and per-chunk scheduling, which the server's windows do not.
    case clientWindow

    /// Whether a figure from this source must be marked as approximate in the UI.
    var isApproximate: Bool { self == .clientWindow }
}

// MARK: - Void reason

/// Why a sample cannot be used. Recorded rather than dropped: a history whose only record of a
/// bad run is its absence cannot be audited, and "no samples" must never render as a clean run.
nonisolated enum BenchmarkVoidReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// Non-2xx HTTP. The status lands in `voidDetail`.
    case httpError
    /// Transport failure, timeout, decode failure. Message in `voidDetail`.
    case transportError
    /// The user cancelled while this sample was in flight.
    case cancelled
    /// The stream ended without a terminal usage event, so there is no server token count.
    case noTokensReported
    /// Not a single generation delta arrived.
    case noOutput
    /// Another LLM stream was running, so the machine was shared and the timing is not this
    /// model's. See `GenerationBenchmarkRunner` — this is the app's own H1 hygiene check.
    case concurrentActivity
    /// The generation window was too short to divide by.
    case windowTooShort
    /// The app stopped reading on purpose, having got what it asked for. The warm-up's only job is
    /// to pay the one-off costs of the first request, and it is complete the moment the model is
    /// loaded and decoding; the rest of the answer is time the user waits for nothing.
    ///
    /// Not a failure, which is why it is a distinct reason rather than `noTokensReported`: no
    /// terminal usage frame arrives because nobody waited for one. `BenchmarkMetricsPolicy`
    /// therefore counts voids on MEASURED samples only — a deliberate stop must never be reported
    /// to the user as a sample that "could not be used".
    case stoppedEarly
}

// MARK: - Sample

/// One measured request. Flat and all-scalar so a row stays readable in `jq` years later.
nonisolated struct GenerationBenchmarkSample: Codable, Hashable, Identifiable, Sendable {

    /// Warm-up samples pay for model load and KV materialisation, so they are recorded but never
    /// aggregated — the same split `benchmark_prompt_processing.sh` makes with its two throwaway
    /// warmup rows.
    ///
    /// A warm-up is also STOPPED as soon as it has paid those costs (`BenchmarkWarmUpPolicy`), so
    /// its row normally carries `void == .stoppedEarly` and no token counts. Measured on
    /// LM Studio 0.4.21 / qwen3.5-9b: read to the end, one warm-up ran 233 s and produced 12 040
    /// tokens, 11 561 of them reasoning — four minutes of output that exists only to be discarded.
    enum Phase: String, Codable, Hashable, Sendable {
        case warmup
        case measured
    }

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var runID: UUID
    var recordedAt: Date
    var phase: Phase
    var sampleIndex: Int

    /// Server-reported prompt tokens.
    var inputTokens: Int?
    /// Server-reported generated tokens, reasoning included (the server counts them, and the
    /// client window covers the thinking deltas — counting one without the other would
    /// desynchronise numerator from denominator).
    var outputTokens: Int?
    /// Request sent → first generation delta, measured by the app. Includes queue, model load
    /// and prefill; that is what it means, not a defect. Never a generation denominator.
    var timeToFirstTokenMs: Double?
    /// First generation delta → last generation delta, measured by the app. Queue and prefill
    /// both sit before the first delta, so this window excludes them by construction — which is
    /// what makes it comparable across providers while `timeToFirstTokenMs` is not.
    var generationMs: Double?
    /// The prompt-prefill window, from whichever source `prefillSource` names.
    var prefillMs: Double?
    var prefillSource: PrefillSource?
    /// Ollama `eval_duration` — server-measured decode time, i.e. the generation window with no
    /// client clock in it.
    var serverGenerationMs: Double?
    /// LM Studio `stats.tokens_per_second` — the SAME fact stated as a rate instead of a window.
    ///
    /// Both are recorded verbatim and reconciled by `BenchmarkMetricsPolicy.serverGenerationRate`
    /// rather than converted into one another: `tokens / rate` would fabricate a window whose
    /// endpoints the server never disclosed (#80). Measured on LM Studio 0.4.21 (2026-08-19), the
    /// server's own derivation is `completion_tokens / (generation_time − TTFT)` to 0.00 % —
    /// decode only, numerator uncorrected — which is Ollama's convention exactly, so the two
    /// providers now share one column honestly.
    var serverGenerationTokensPerSecond: Double?
    /// How much of `outputTokens` the server attributes to reasoning. LM Studio only; nil where
    /// the provider does not separate them. Explains a rate that looks slow to a reader counting
    /// only the visible answer.
    var reasoningOutputTokens: Int?
    /// Server-reported model load time, verbatim. A positive value is not by itself a reload.
    var modelLoadMs: Double?
    /// Milliseconds this app spent explicitly loading the model, when it did. Kept separate from
    /// `modelLoadMs` for the same reason `NetworkLogRecord` keeps them apart: different
    /// provenance, and folding one into the other poisons both.
    var appModelLoadMs: Double?
    /// Whole-request wall time, by THIS APP's clock.
    var totalMs: Double?
    /// The same span by the SERVER's clock — Ollama `total_duration`. Nil on LM Studio, which
    /// reports no equivalent over the streaming API.
    ///
    /// Beside `totalMs` rather than instead of it, on the convention this file already uses twice
    /// (`serverGenerationMs` beside `generationMs`, `modelLoadMs` beside `appModelLoadMs`): two
    /// clocks on one span are two facts. Their gap is the transport and scheduling the app pays
    /// for and the server never sees.
    var serverTotalMs: Double?
    /// Why the server stopped generating — `"stop"` when the model finished, `"length"` when it
    /// hit the requested ceiling. Nil where the provider does not say.
    ///
    /// The benchmark asks for a fixed 512-token cap, and this is the only direct answer to
    /// whether a sample was cut off at it. `BenchmarkProvenance.outputCapField` could previously
    /// only detect the opposite — a server returning MORE than it was asked for — by reading the
    /// token counts back, which is an inference about a fact the server was already stating.
    var doneReason: String?

    var void: BenchmarkVoidReason?
    /// Free-text detail for `void` — an HTTP status, an error message. Separate from the reason
    /// so `jq 'group_by(.void)'` stays useful.
    var voidDetail: String?

    var isUsable: Bool { void == nil }

    init(
        schemaVersion: Int = GenerationBenchmarkSample.currentSchemaVersion,
        id: UUID = UUID(),
        runID: UUID,
        recordedAt: Date,
        phase: Phase,
        sampleIndex: Int,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        timeToFirstTokenMs: Double? = nil,
        generationMs: Double? = nil,
        prefillMs: Double? = nil,
        prefillSource: PrefillSource? = nil,
        serverGenerationMs: Double? = nil,
        serverGenerationTokensPerSecond: Double? = nil,
        reasoningOutputTokens: Int? = nil,
        modelLoadMs: Double? = nil,
        appModelLoadMs: Double? = nil,
        totalMs: Double? = nil,
        serverTotalMs: Double? = nil,
        doneReason: String? = nil,
        void: BenchmarkVoidReason? = nil,
        voidDetail: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.runID = runID
        self.recordedAt = recordedAt
        self.phase = phase
        self.sampleIndex = sampleIndex
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.generationMs = generationMs
        self.prefillMs = prefillMs
        self.prefillSource = prefillSource
        self.serverGenerationMs = serverGenerationMs
        self.serverGenerationTokensPerSecond = serverGenerationTokensPerSecond
        self.reasoningOutputTokens = reasoningOutputTokens
        self.modelLoadMs = modelLoadMs
        self.appModelLoadMs = appModelLoadMs
        self.totalMs = totalMs
        self.serverTotalMs = serverTotalMs
        self.doneReason = doneReason
        self.void = void
        self.voidDetail = voidDetail
    }

    init(from decoder: Decoder) throws {
        self = try Self.decode(from: decoder)
    }

    /// Extracted from `init(from:)`: Swift 6.3.1 crashes (`bad_optional_access`) on a
    /// `nonisolated struct`'s long `init(from:)` built from generic `decodeIfPresent` chains.
    private static func decode(from decoder: Decoder) throws -> GenerationBenchmarkSample {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        var sample = GenerationBenchmarkSample(
            // A row written by a NEWER build keeps its higher version, so a forward-rolled
            // binary does not silently downgrade it on rewrite (CLAUDE.md #48).
            schemaVersion: max(storedVersion, currentSchemaVersion),
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            runID: try c.decode(UUID.self, forKey: .runID),
            recordedAt: try c.decode(Date.self, forKey: .recordedAt),
            phase: try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .measured,
            sampleIndex: try c.decodeIfPresent(Int.self, forKey: .sampleIndex) ?? 0)
        sample.inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        sample.outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        sample.timeToFirstTokenMs = try c.decodeIfPresent(Double.self, forKey: .timeToFirstTokenMs)
        sample.generationMs = try c.decodeIfPresent(Double.self, forKey: .generationMs)
        sample.prefillMs = try c.decodeIfPresent(Double.self, forKey: .prefillMs)
        sample.prefillSource = try c.decodeIfPresent(PrefillSource.self, forKey: .prefillSource)
        sample.serverGenerationMs = try c.decodeIfPresent(Double.self, forKey: .serverGenerationMs)
        sample.serverGenerationTokensPerSecond = try c.decodeIfPresent(
            Double.self, forKey: .serverGenerationTokensPerSecond)
        sample.reasoningOutputTokens = try c.decodeIfPresent(
            Int.self, forKey: .reasoningOutputTokens)
        sample.modelLoadMs = try c.decodeIfPresent(Double.self, forKey: .modelLoadMs)
        sample.appModelLoadMs = try c.decodeIfPresent(Double.self, forKey: .appModelLoadMs)
        sample.totalMs = try c.decodeIfPresent(Double.self, forKey: .totalMs)
        // Additive and optional, so no schema bump: a row written before these existed decodes
        // as "the server did not say", which is exactly what it means. Same shape as the
        // `modelFormat` / `quantization` addition.
        sample.serverTotalMs = try c.decodeIfPresent(Double.self, forKey: .serverTotalMs)
        sample.doneReason = try c.decodeIfPresent(String.self, forKey: .doneReason)
        sample.void = try c.decodeIfPresent(BenchmarkVoidReason.self, forKey: .void)
        sample.voidDetail = try c.decodeIfPresent(String.self, forKey: .voidDetail)
        return sample
    }
}

// MARK: - Run (provenance)

/// One benchmark run: what was measured, under what conditions.
///
/// Separate from the samples for the same reason `benchmark_prompt_processing.sh` writes
/// `provenance.jsonl` beside `results.jsonl` — provenance is what makes a row from six months
/// ago interpretable, and repeating it on every sample would triple the file for no new fact.
nonisolated struct GenerationBenchmarkRun: Codable, Hashable, Identifiable, Sendable {

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var startedAt: Date

    // MARK: Identity

    var provider: LLMProvider
    /// Normalized through `String.normalizedBaseURL` — the single canonicalizer in this
    /// codebase. Comparing un-normalized URLs silently splits one server into two.
    var baseURLString: String
    var modelName: String
    /// LM Studio per-instance id, when the server reported one.
    var instanceID: String?

    /// The server's own version, VERBATIM. Ollama reports it at `GET /api/version`
    /// (measured: `0.32.14`). LM Studio exposes no version endpoint that this codebase or its
    /// probes could find, so it stays nil there — never backfilled with the app's version or
    /// anything else that would read as a server fact.
    var providerVersion: String?

    /// The model's file format as the server reported it, verbatim — `gguf`, `mlx`,
    /// `safetensors`. Promoted out of `serverFields` into a typed field because the tables render
    /// it (`ModelLoadDetails.format` at capture; the leaderboard and Runs chips at display).
    /// Legacy rows carry the same fact under `serverFields["Format"]`, and `decode` promotes it
    /// from there, so history recorded before this field existed still shows its chips.
    var modelFormat: String?

    /// The quantization as the server reported it, verbatim — `Q4_K_M`, `4bit`, `MXFP4`. Same
    /// promotion story as `modelFormat`, with `serverFields["Quantization"]` as the legacy home.
    var quantization: String?

    /// Everything else the server said about itself and the model, verbatim, key → value.
    ///
    /// A dictionary rather than typed fields because NEITHER provider reports an engine version
    /// (llama.cpp / MLX): it is absent from `/api/version`, `/api/ps` and `/api/show` on Ollama
    /// and from LM Studio's `/api/v0/models`. The engine is only INFERABLE from the format
    /// (`gguf` → llama.cpp runner, `safetensors`/`mlx` → otherwise), and recording an inference
    /// as a measurement is the failure mode this codebase refuses everywhere else. When a
    /// provider does start reporting one, the key lands here with no schema migration.
    var serverFields: [String: String]

    /// Sampling parameters as the SERVER reports them. A provider asymmetry, not a gap:
    /// Ollama answers with real values (`/api/show` → `parameters`), LM Studio reports nothing
    /// at all because its per-model config is server-side only. Empty rather than filled with
    /// plausible defaults.
    var samplingParameters: [String: String]

    // MARK: What the app sent

    var temperature: Double?
    var requestTimeoutSeconds: Int
    var keepAliveSeconds: Int?

    // MARK: Prompt

    var promptID: String
    /// Bumped whenever the prompt text changes. Rows from different versions are not comparable,
    /// and the leaderboard drops the older ones rather than ranking them side by side.
    var promptVersion: Int

    // MARK: Conditions

    var repeats: Int
    /// `ProcessInfo.ThermalState` as a string. On a local LLM, throttling moves the number by
    /// multiples — a row without it is unreadable a month later.
    var thermalState: String
    var lowPowerMode: Bool
    /// Whether the model was already resident before the warm-up sample.
    var modelWasResident: Bool
    var appVersion: String

    /// True when the machine was throttled for the whole run, so its numbers say more about the
    /// thermal state than about the model.
    var wasThrottled: Bool {
        lowPowerMode || thermalState != BenchmarkThermalState.nominal
    }

    init(
        schemaVersion: Int = GenerationBenchmarkRun.currentSchemaVersion,
        id: UUID = UUID(),
        startedAt: Date,
        provider: LLMProvider,
        baseURLString: String,
        modelName: String,
        instanceID: String? = nil,
        providerVersion: String? = nil,
        modelFormat: String? = nil,
        quantization: String? = nil,
        serverFields: [String: String] = [:],
        samplingParameters: [String: String] = [:],
        temperature: Double? = nil,
        requestTimeoutSeconds: Int,
        keepAliveSeconds: Int? = nil,
        promptID: String,
        promptVersion: Int,
        repeats: Int,
        thermalState: String,
        lowPowerMode: Bool,
        modelWasResident: Bool,
        appVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.startedAt = startedAt
        self.provider = provider
        self.baseURLString = baseURLString
        self.modelName = modelName
        self.instanceID = instanceID
        self.providerVersion = providerVersion
        self.modelFormat = modelFormat
        self.quantization = quantization
        self.serverFields = serverFields
        self.samplingParameters = samplingParameters
        self.temperature = temperature
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.keepAliveSeconds = keepAliveSeconds
        self.promptID = promptID
        self.promptVersion = promptVersion
        self.repeats = repeats
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.modelWasResident = modelWasResident
        self.appVersion = appVersion
    }

    init(from decoder: Decoder) throws {
        self = try Self.decode(from: decoder)
    }

    private static func decode(from decoder: Decoder) throws -> GenerationBenchmarkRun {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        var run = GenerationBenchmarkRun(
            schemaVersion: max(storedVersion, currentSchemaVersion),
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            startedAt: try c.decode(Date.self, forKey: .startedAt),
            provider: try c.decode(LLMProvider.self, forKey: .provider),
            baseURLString: try c.decodeIfPresent(String.self, forKey: .baseURLString) ?? "",
            modelName: try c.decodeIfPresent(String.self, forKey: .modelName) ?? "",
            requestTimeoutSeconds: try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? 0,
            promptID: try c.decodeIfPresent(String.self, forKey: .promptID) ?? "",
            promptVersion: try c.decodeIfPresent(Int.self, forKey: .promptVersion) ?? 0,
            repeats: try c.decodeIfPresent(Int.self, forKey: .repeats) ?? 0,
            thermalState: try c.decodeIfPresent(String.self, forKey: .thermalState)
                ?? BenchmarkThermalState.unknown,
            lowPowerMode: try c.decodeIfPresent(Bool.self, forKey: .lowPowerMode) ?? false,
            modelWasResident: try c.decodeIfPresent(Bool.self, forKey: .modelWasResident) ?? false,
            appVersion: try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "")
        run.instanceID = try c.decodeIfPresent(String.self, forKey: .instanceID)
        run.providerVersion = try c.decodeIfPresent(String.self, forKey: .providerVersion)
        run.serverFields = try c.decodeIfPresent([String: String].self, forKey: .serverFields) ?? [:]
        // Rows written before the typed fields existed carry the same facts in `serverFields`,
        // under the labels the provider clients report them with. The fallback keys are string
        // literals ON PURPOSE: they are the persisted spelling in files already on disk, frozen
        // even if `ModelLoadDetails.formatLabel`/`.quantizationLabel` (pinned equal in
        // `ModelLoadDetailsTests`) ever move. Promoting at decode rather than at display keeps
        // one in-memory representation, and a re-encode self-heals the row.
        run.modelFormat = try c.decodeIfPresent(String.self, forKey: .modelFormat)
            ?? run.serverFields["Format"]
        run.quantization = try c.decodeIfPresent(String.self, forKey: .quantization)
            ?? run.serverFields["Quantization"]
        run.samplingParameters = try c.decodeIfPresent(
            [String: String].self, forKey: .samplingParameters) ?? [:]
        run.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        run.keepAliveSeconds = try c.decodeIfPresent(Int.self, forKey: .keepAliveSeconds)
        return run
    }
}

// MARK: - Thermal state strings

/// String spellings for `ProcessInfo.ThermalState`, so the persisted value is stable across
/// OS releases and readable in `jq` without a lookup table.
nonisolated enum BenchmarkThermalState {
    static let nominal = "nominal"
    static let fair = "fair"
    static let serious = "serious"
    static let critical = "critical"
    static let unknown = "unknown"

    static func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: nominal
        case .fair: fair
        case .serious: serious
        case .critical: critical
        @unknown default: unknown
        }
    }
}
