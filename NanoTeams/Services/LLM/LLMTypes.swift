import Foundation

// MARK: - LLMProvider

nonisolated enum LLMProvider: String, Codable, Hashable, CaseIterable, Identifiable {
    case lmStudio
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        }
    }

    var defaultBaseURL: String {
        // `127.0.0.1` over `localhost` because the UI placeholder + the
        // Keychain key normalization both treat them as distinct hosts —
        // keeping a single canonical form avoids drift between what the
        // user sees, what Reset restores, and what the bearer token is
        // saved under.
        switch self {
        case .lmStudio: "http://127.0.0.1:1234"
        case .ollama: "http://127.0.0.1:11434"
        }
    }

    var defaultModel: String {
        switch self {
        case .lmStudio: "openai/gpt-oss-20b"
        case .ollama: "gpt-oss:20b"
        }
    }

    var supportsModelFetching: Bool {
        true
    }

    /// Whether the app manages model residency (explicit load/unload, the
    /// `ChatModelEnsurer` ledger, reconcile sweeps) on this provider's server.
    /// LM Studio requires it: explicit loads opt out of Auto-Evict, so the
    /// app owns eviction. Ollama manages its own residency (`keep_alive`,
    /// `OLLAMA_MAX_LOADED_MODELS`) and exposes no load/unload REST surface —
    /// `switchChatModel` must not attempt an explicit load there (the 404
    /// would surface as a spurious "couldn't load model" banner).
    var managesModelResidency: Bool {
        switch self {
        case .lmStudio: true
        case .ollama: false
        }
    }

    /// Relative path probed by reachability checks (Test Connection, the
    /// status-bar pill, per-role override preflight). A cheap GET that any
    /// healthy server of this provider answers 2xx.
    var reachabilityProbePath: String {
        switch self {
        case .lmStudio: "api/v1/models"
        case .ollama: "api/tags"
        }
    }
}

// MARK: - LLMConfig

nonisolated struct LLMConfig: Hashable {
    var provider: LLMProvider
    var baseURLString: String
    var modelName: String
    /// Sampling temperature. `nil` = server decides (the model's own LM Studio
    /// config governs). The ONLY production writer is the security-judge
    /// verdict pin (`JudgeConfig.forVerdict` → 0 for deterministic verdicts);
    /// user-facing generation settings were removed — LM Studio is the single
    /// source of truth for sampling.
    var temperature: Double?
    /// Hard ceiling on generated tokens. `nil` = don't send the key at all, which is the setting
    /// for every role step: an agent turn cut off mid-thought produces a truncated tool call and a
    /// step that can never complete.
    ///
    /// The ONLY production writer is the generation benchmark (`BenchmarkPrompt.maxOutputTokens`)
    /// — same shape as `temperature`, and for the same reason: a measurement is allowed to demand
    /// determinism that real work is not. There it replaces an UNCONTROLLED variable with a
    /// controlled one. Measured on LM Studio 0.4.21 / qwen3.5-9b: one uncapped sample of this
    /// benchmark's prompt produced 12 040 tokens, 96 % of them reasoning, over 233 s — while
    /// another model on another day might answer the same prompt in 400. Comparing two rates
    /// measured over sequences that differ by an order of magnitude compares two different things,
    /// because per-token decode cost grows with the sequence being attended to.
    var maxOutputTokens: Int?
    /// Streaming HTTP request timeout in seconds. `0` = no timeout (wait indefinitely).
    /// Minimum effective value is 1s; values below 1 other than 0 are clamped up.
    var requestTimeoutSeconds: Int
    /// How long a stateless provider should keep the model — and therefore its KV
    /// prefix cache — resident after a request. `nil` = don't send the key, let the
    /// server decide.
    ///
    /// Only Ollama consumes this (`managesModelResidency == false`, so nothing in the
    /// app loads or pins its models). Its default is 5 minutes of idle, after which the
    /// model AND the cache are dropped — but a human answering an `ask_supervisor`
    /// question routinely takes longer, and that is precisely when the replayed
    /// conversation needs the cache to still be warm. Measured cost of a miss on this
    /// project's models: ~7 s instead of ~80 ms at 13k tokens.
    ///
    /// LM Studio ignores it: the app manages that residency explicitly through
    /// `ChatModelEnsurer` and its ownership ledger.
    var keepAliveSeconds: Int?

    init(
        provider: LLMProvider = .lmStudio,
        baseURLString: String? = nil,
        modelName: String? = nil,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        requestTimeoutSeconds: Int? = nil,
        keepAliveSeconds: Int? = nil
    ) {
        self.provider = provider
        self.baseURLString = baseURLString ?? provider.defaultBaseURL
        self.modelName = modelName ?? provider.defaultModel
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeoutSeconds = requestTimeoutSeconds ?? LLMConstants.defaultLLMRequestTimeoutSeconds
        self.keepAliveSeconds = keepAliveSeconds
    }
}

// MARK: - ToolSchema

nonisolated struct ToolSchema: Hashable, Codable {
    var name: String
    var description: String
    var parameters: JSONSchema

    init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - StreamEvent

nonisolated struct StreamEvent: Hashable {
    var contentDelta: String
    var thinkingDelta: String
    var toolCallDeltas: [ToolCallDelta]
    var tokenUsage: TokenUsage?
    /// Prompt processing progress (0.0–1.0). Non-nil during prompt_processing phase.
    var processingProgress: Double?
    /// What the server reported about how it processed this request's prompt. Same category as
    /// `tokenUsage` — a terminal, server-authoritative diagnostic riding the event stream — and
    /// emitted alongside it. Used to tell a prompt-prefix cache hit from a silent re-prefill.
    var serverPrefill: ServerPrefillReport?
    /// What THIS APP did to the model's residency for this request. The complement of
    /// `serverPrefill` — see `ClientResidencyFacts`.
    var clientResidency: ClientResidencyFacts?
    /// Nanoseconds the server says it spent GENERATING, decode only — Ollama `eval_duration`.
    /// Stays nil on LM Studio, which reports the same fact as a RATE rather than a window; see
    /// `serverGenerationTokensPerSecond`.
    ///
    /// Terminal, emitted alongside `tokenUsage`. Deliberately NOT folded into `serverPrefill`:
    /// that report describes what happened BEFORE the first token, and its `isEmpty` counts only
    /// `modelLoadMs` and `prefillNs` — a report carrying nothing but this would be dropped on the
    /// way out of the parser.
    ///
    /// A bare `Double?` rather than a new wrapper type, matching `processingProgress`: one
    /// number with one meaning does not earn a struct.
    var serverGenerationNs: Double?
    /// Tokens per second the server measured over its decode window — LM Studio
    /// `stats.tokens_per_second`, verbatim. Stays nil on Ollama, which reports the window.
    ///
    /// Kept as a RATE rather than converted into `serverGenerationNs`, and the reason is #80: a
    /// duration derived as `tokens / rate` fabricates a window whose endpoints the server never
    /// disclosed, and silently adopts whatever fence-post convention the server used. Measured
    /// on LM Studio 0.4.21 (2026-08-19), that convention is
    /// `completion_tokens / (generation_time − time_to_first_token)` to 0.00 % — decode only,
    /// numerator uncorrected, i.e. identical to Ollama's — but that is a fact about one build,
    /// and recording the rate as sent is what lets it be re-derived from a log instead of
    /// re-assumed.
    var serverGenerationTokensPerSecond: Double?
    /// How much of `tokenUsage.outputTokens` the server attributes to reasoning — LM Studio
    /// `stats.reasoning_output_tokens`. Nil on Ollama, which reports thinking as content without
    /// counting it separately.
    ///
    /// Not folded into `TokenUsage`: that type is accumulated across tool-loop iterations, and
    /// giving it an optional third term would introduce optional arithmetic on the app's hottest
    /// value type for the benefit of one reader.
    var serverReasoningOutputTokens: Int?
    /// Nanoseconds the server says the WHOLE request took, its own clock — Ollama
    /// `total_duration`. Nil on LM Studio, which reports no equivalent over the streaming API.
    ///
    /// The app measures the same span itself and always has, so this is not a replacement but the
    /// only second opinion that span has ever had. Where the two disagree, the difference is
    /// transport and scheduling — which is the difference between "the model is slow" and "this
    /// machine is busy", and neither number can say that alone.
    var serverTotalNs: Double?
    /// Why the server stopped generating — Ollama `done_reason`: `"stop"` when the model finished
    /// on its own, `"length"` when it hit the requested ceiling. Nil on LM Studio.
    ///
    /// Recorded verbatim rather than mapped onto a Bool. `"stop"` and `"length"` are today's two
    /// values; a server that adds a third would be flattened into "not length" by a Bool, and the
    /// string costs nothing to keep.
    var serverDoneReason: String?

    init(
        contentDelta: String = "",
        thinkingDelta: String = "",
        toolCallDeltas: [ToolCallDelta] = [],
        tokenUsage: TokenUsage? = nil,
        processingProgress: Double? = nil,
        serverPrefill: ServerPrefillReport? = nil,
        clientResidency: ClientResidencyFacts? = nil,
        serverGenerationNs: Double? = nil,
        serverGenerationTokensPerSecond: Double? = nil,
        serverReasoningOutputTokens: Int? = nil,
        serverTotalNs: Double? = nil,
        serverDoneReason: String? = nil
    ) {
        self.contentDelta = contentDelta
        self.thinkingDelta = thinkingDelta
        self.toolCallDeltas = toolCallDeltas
        self.tokenUsage = tokenUsage
        self.processingProgress = processingProgress
        self.serverPrefill = serverPrefill
        self.clientResidency = clientResidency
        self.serverGenerationNs = serverGenerationNs
        self.serverGenerationTokensPerSecond = serverGenerationTokensPerSecond
        self.serverReasoningOutputTokens = serverReasoningOutputTokens
        self.serverTotalNs = serverTotalNs
        self.serverDoneReason = serverDoneReason
    }

    var isEmpty: Bool {
        contentDelta.isEmpty && thinkingDelta.isEmpty && toolCallDeltas.isEmpty
            && tokenUsage == nil && processingProgress == nil && serverPrefill == nil
            && clientResidency == nil && serverGenerationNs == nil
            && serverGenerationTokensPerSecond == nil && serverReasoningOutputTokens == nil
            && serverTotalNs == nil && serverDoneReason == nil
    }

    struct ToolCallDelta: Hashable {
        var index: Int?
        var id: String?
        var name: String?
        var argumentsDelta: String?
    }
}

// MARK: - ClientResidencyFacts

/// What this app did to the model's residency while serving a request.
///
/// The two providers are exactly complementary, which is why this exists alongside
/// `ServerPrefillReport` rather than inside it:
///
/// - **Ollama** manages its own residency and reports `load_duration`, so a reload is visible in
///   the server's own numbers.
/// - **LM Studio** reports `model_load_time_seconds` as exactly `0` on every measured row — all
///   27 in `bench_baseline` — while its residency is managed by THIS APP through
///   `ChatModelEnsurer` and the ownership ledger. The server cannot tell us it reloaded; we are
///   the ones who reloaded it.
///
/// So `Cause.modelReloaded` has two evidence channels selected by who owns residency, and the
/// one that was previously unreachable — a reload on the default provider, typically after a
/// parked step let the reconciler reclaim the model — becomes observable. The facts are PUSHED
/// per request rather than pulled from the ensurer: a pull would make `LLMExecutionService` hold
/// a `ChatModelEnsurer`, whose only sane default is the process-global `.shared`, i.e. exactly
/// the outward-resolving seam CLAUDE.md #49 forbids.
///
/// Known gap: an instance the app unloaded and a THIRD PARTY reloaded comes back as `.adopted`,
/// which sets nothing here. The cache is cold and this reports nothing — the same blindness as
/// before, not a regression.
nonisolated struct ClientResidencyFacts: Hashable, Sendable {
    /// The app performed an explicit load for this request (`EnsureOutcome.loaded`). Never true
    /// for `.adopted` (already resident, cache intact) or `.skipped`.
    var appLoadedModelForThisRequest: Bool
    /// Wall-clock milliseconds that load took, measured by the app. Diagnostic only — the verdict
    /// keys on the boolean, because "we loaded it" is categorical and needs no threshold, unlike
    /// the server figure it complements.
    var appModelLoadMs: Double?

    init(appLoadedModelForThisRequest: Bool, appModelLoadMs: Double? = nil) {
        self.appLoadedModelForThisRequest = appLoadedModelForThisRequest
        self.appModelLoadMs = appModelLoadMs
    }
}

// MARK: - ServerPrefillReport

/// The server's own account of how it processed a request's prompt.
///
/// Every field is optional because neither provider promises any of them, and absence is never
/// evidence of anything — a provider that reports nothing must produce no verdict rather than a
/// guess.
nonisolated struct ServerPrefillReport: Hashable {
    /// Milliseconds the server says it spent loading the model, VERBATIM — a transport fact, not
    /// a reload flag: `bench_baseline` records 20.6–25.1 ms on every warm Ollama request against
    /// 2236.6 ms for the one real load. `PrefixCachePolicy.minimumLoadMsForReload` owns the
    /// threshold, and keeping it out of here is what lets `NetworkLogger` record what the server
    /// actually said — which is how that threshold gets re-derived from a real run.
    /// LM Studio `model_load_time_seconds`, Ollama `load_duration`.
    var modelLoadMs: Double?
    /// Nanoseconds spent prefilling, decode excluded. Ollama `prompt_eval_duration` only.
    var prefillNs: Double?
    /// Tokens the server says it prefilled. Ollama `prompt_eval_count`, LM Studio `input_tokens`.
    var promptTokens: Int?

    init(modelLoadMs: Double? = nil, prefillNs: Double? = nil, promptTokens: Int? = nil) {
        self.modelLoadMs = modelLoadMs
        self.prefillNs = prefillNs
        self.promptTokens = promptTokens
    }

    /// Nanoseconds per prefilled token — the scale-free form that can be compared against a warm
    /// floor. `nil` unless BOTH halves are present and positive.
    var nsPerToken: Double? {
        guard let prefillNs, prefillNs > 0, let promptTokens, promptTokens > 0 else { return nil }
        return prefillNs / Double(promptTokens)
    }

    /// True when the report carries no signal worth acting on. `promptTokens` deliberately does
    /// NOT count: it is only the denominator for `nsPerToken`, it duplicates `TokenUsage`, and
    /// every provider always sends it — so counting it would make the report non-empty on every
    /// request while saying nothing about the cache.
    var isEmpty: Bool { modelLoadMs == nil && prefillNs == nil }
}

// MARK: - TokenUsage

nonisolated struct TokenUsage: Codable, Hashable {
    var inputTokens: Int
    var outputTokens: Int

    init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Accumulate usage from another instance (for multi-iteration tool loops).
    mutating func accumulate(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
    }
}

// MARK: - LLMClientError

nonisolated enum LLMClientError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case badHTTPStatus(Int, String?)
    case missingResponse
    case rateLimited(retryAfter: Double?)
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let s):
            // Empty / whitespace URL means "not configured yet" rather than
            // "user typed something invalid" — surface a hint instead of the
            // raw empty string so onAppear-triggered preflights don't show
            // a useless `Invalid LLM base URL:` row.
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "Server address is empty. Enter the server URL in Settings → LLM."
            } else {
                "Invalid LLM base URL: \(s)"
            }
        case .badHTTPStatus(let code, let body):
            // 401 / 403: route through the auth classifier so every UI that
            // surfaces this error (settings cards, role editor, status banners)
            // shows the actionable "add your API token" message instead of
            // dumping the raw LM Studio JSON envelope.
            if LLMAuthErrorClassifier.isAuthFailure(status: code) {
                LLMAuthErrorClassifier.message(forStatus: code, body: body)
            } else if let body, ModelLoadFailureClassifier.matches(body) {
                // Same one-place-every-surface routing as the auth classifier:
                // replace the raw LM Studio envelope with something the user
                // can act on. Naming the model matters — the envelope buries it
                // mid-sentence.
                if let model = ModelLoadFailureClassifier.quotedModelName(in: body) {
                    "Couldn't load '\(model)' — LM Studio doesn't have enough free memory. "
                        + "Unload a model in LM Studio, or lower its context length "
                        + "(My Models → gear)."
                } else {
                    "Couldn't load the model — LM Studio doesn't have enough free memory. "
                        + "Unload a model in LM Studio, or lower its context length "
                        + "(My Models → gear)."
                }
            } else if let body {
                "LLM request failed with HTTP \(code): \(body)"
            } else {
                "LLM request failed with HTTP status \(code)"
            }
        case .missingResponse:
            "Missing HTTP response from LLM server"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                "Rate limited. Retry after \(Int(seconds))s"
            } else {
                "Rate limited. Please retry later"
            }
        case .providerError(let message):
            "LLM provider error: \(message)"
        }
    }
}
