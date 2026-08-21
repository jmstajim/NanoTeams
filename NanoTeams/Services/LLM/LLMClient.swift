import Foundation

// MARK: - Network Session

/// DIP abstraction over URLSession for testable network I/O.
/// URLSession conforms automatically via its existing `data(for:)` and `bytes(for:)` overloads.
nonisolated protocol NetworkSession: Sendable {
    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse)
    func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

extension URLSession: NetworkSession {
    // Bridge to URLSession methods which have an additional `delegate` parameter with default value.
    // Swift protocols don't match methods with extra defaulted parameters automatically.
    public func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
    public func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await bytes(for: request)
    }
}

// MARK: - LLM Client

/// Protocol for all LLM clients (ChatCompletions, Responses API).
/// Callers use this protocol — the router dispatches to the correct implementation.
nonisolated protocol LLMClient: Sendable {

    /// Stream a chat completion from the LLM provider.
    ///
    /// Every call is stateless: `messages` is the FULL conversation, and the
    /// provider is expected to reuse its prompt-prefix cache on the byte-identical
    /// prefix. Server-side response chains (`previous_response_id`) were removed —
    /// measured on this project's models they bought nothing (LM Studio: 348 ms
    /// chained vs 339 ms unchained at 13k tokens) while being the root of a class
    /// of provider-specific bugs.
    ///
    /// - Parameters:
    ///   - config: Provider configuration (URL, model, API key, etc.)
    ///   - messages: Full conversation history
    ///   - tools: Available tool schemas
    ///   - logger: Optional network logger
    ///   - stepID: Optional step ID for log correlation
    ///   - roleName: Optional role name for log attribution
    /// - Returns: Async stream of events (content, thinking, tool calls, usage)
    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error>

    /// Fetch available models from the provider.
    /// Not all providers may support this.
    ///
    /// Returns descriptors rather than names because both providers report each model's format and
    /// quantization in this very response, and a `[String]` return was throwing them away — see
    /// `LLMModelInfo`. A provider that reports neither leaves both nil; nothing is inferred.
    /// - Parameter visionOnly: When `true`, returns only vision-capable models.
    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo]

    /// Fetch available *embedding* models from the provider. Used by the
    /// broad-search semantic-expansion card which needs to let the user
    /// pick from LM Studio's embedding family (e.g. `nomic-embed-text-v1.5`).
    /// Default implementation returns `[]` so test doubles don't break —
    /// real clients (`NativeLMStudioClient`, `LLMClientRouter`) override.
    ///
    /// Names only, deliberately asymmetric with `fetchModels`: the Embeddings card renders no
    /// format/quantization chips, so widening this would be a protocol change with no reader.
    func fetchEmbeddingModels(config: LLMConfig) async throws -> [String]

    /// Load a model into the server's runtime. Takes a raw `baseURLString`
    /// rather than `LLMConfig` because the embed URL is distinct from the
    /// chat-LLM URL (separate `EmbeddingConfig`), and an explicit `provider`
    /// because a base URL names a SERVER and every server belongs to one.
    /// Returns the `instance_id` to use for subsequent `unloadModel`.
    /// Default impl throws `providerError` so a client that cannot do this is
    /// loud instead of silently lying.
    ///
    /// Only LM Studio implements it. Ollama loads on first use and exposes no
    /// load endpoint (`LLMProvider.managesModelResidency == false`), so asking
    /// it here throws rather than pretending.
    func loadModel(
        provider: LLMProvider, modelName: String, baseURLString: String) async throws -> String

    /// Unload a previously loaded model instance. Idempotent on the server
    /// side: if the instance is already gone (e.g. LM Studio restarted),
    /// implementations should return without throwing.
    ///
    /// Implemented on BOTH providers, for different reasons: LM Studio because
    /// the app owns its residency ledger, Ollama because the benchmark has to
    /// be able to clear the machine before it measures it (there it is
    /// `keep_alive: 0`, the only eviction Ollama offers).
    func unloadModel(
        provider: LLMProvider, instanceID: String, baseURLString: String) async throws

    /// Lists model instances currently loaded on the server. The server
    /// is the source of truth; in-process state can drift across app
    /// restarts. Used by `EmbeddingModelLifecycleService` to adopt an
    /// existing instance instead of spawning a duplicate (LM Studio
    /// otherwise creates `name`, `name:2`, `name:3`, … per `loadModel`
    /// call), and by the benchmark to see what else is resident.
    ///
    /// **`provider` is not decoration — it is the parameter whose absence was a
    /// defect.** Until 2026-08-19 this surface took a bare base URL, so
    /// `LLMClientRouter` had nothing to dispatch on and sent every call to the
    /// LM Studio client. Pointed at an Ollama server that client asks for
    /// `/api/v0/models`, Ollama answers `404 page not found` (measured), and the
    /// 404 branch — which means "an older LM Studio without v0" — returns `[]`.
    /// The benchmark then recorded `Residency: already alone` about a machine it
    /// had never asked. Silence read as absence, in one under-specified
    /// signature.
    ///
    /// Default impl returns `.unsupported` — a client that did not implement
    /// this cannot answer, and says so.
    ///
    /// `modelName` is the canonical name (suffix-stripped) for matching
    /// against `EmbeddingConfig.modelName`; `instanceID` is the raw id
    /// to pass to `unloadModel`.
    func listLoadedInstances(
        provider: LLMProvider, baseURLString: String) async throws -> LoadedInstanceListing

    /// Whether `config.modelName` can see images, per the provider's model
    /// metadata. `nil` = undeterminable (no capability metadata / transport
    /// failure / model not listed) — callers must fail toward the "cannot see
    /// images" path (vision-model fallback), never assume vision. Auto-detected
    /// replacement for the removed "Main model supports vision" toggle.
    func modelSupportsVision(config: LLMConfig) async -> Bool?

    /// The context-window size (in tokens) of `config.modelName`, per the
    /// provider's model metadata. `nil` = undeterminable (no metadata /
    /// transport failure / model not listed) — callers must degrade to a
    /// conservative fallback, never assume a large window. Used to size the
    /// one-shot work-folder-context prompt so it fits the loaded model.
    func modelContextLength(config: LLMConfig) async -> Int?

    /// Human-readable load parameters of `config.modelName` (residency state,
    /// effective context window, quantization, …) for the Settings → LLM
    /// "Model Details" card. `nil` = undeterminable (transport failure /
    /// model not listed). Purely informational — nothing routes on it.
    func modelLoadDetails(config: LLMConfig) async -> ModelLoadDetails?

    // Facts about the SERVER PROCESS rather than about a model on it — its version, its build,
    // its engines — deliberately do not live here. Every member above is keyed by
    // `config.modelName` and answered by the model endpoints; those are keyed by nothing, are
    // answered over a WebSocket on LM Studio, and no part of the run loop reads them. See
    // `ServerProvenanceProbe`.
}

nonisolated extension LLMClient {
    /// Default: undeterminable — keeps existing test doubles compiling and
    /// deterministic (they exercise the no-vision fallback path unless they
    /// override). `NativeLMStudioClient` implements the real probe;
    /// `LLMClientRouter` forwards.
    func modelSupportsVision(config: LLMConfig) async -> Bool? { nil }

    /// Default: undeterminable — test doubles inherit this and callers fall
    /// back to their conservative context assumption. `NativeLMStudioClient`
    /// implements the real probe; `LLMClientRouter` forwards.
    func modelContextLength(config: LLMConfig) async -> Int? { nil }

    /// Default: no load-details surface — test doubles inherit this; the
    /// Model Details card renders its empty state.
    func modelLoadDetails(config: LLMConfig) async -> ModelLoadDetails? { nil }
}

/// Server-side record of a loaded model instance. Returned by
/// `LLMClient.listLoadedInstances`.
nonisolated struct LoadedModelInstance: Sendable, Equatable {
    /// Canonical model name (LM Studio dedup suffix `:N` stripped). Match
    /// this against `EmbeddingConfig.modelName` to decide whether to adopt
    /// an existing instance.
    let modelName: String

    /// Raw instance id as the server reports it. Pass this to
    /// `unloadModel(instanceID:)`. Equals `modelName` for the first
    /// loaded instance; `\(modelName):N` for duplicate-loads.
    let instanceID: String
}

/// What a server said when asked what it currently has loaded.
///
/// **Three states, not two.** "The server has nothing loaded" and "the server
/// cannot tell me what it has loaded" are different facts, and an `[]` that
/// means both is a lie for any caller that REPORTS rather than adopts.
/// `NativeLMStudioClient` used to return `[]` for a `404` on `/api/v0/models`
/// — a branch written for an older LM Studio that lacks the route, and the
/// right answer for the adoption callers it was written for. It reached the
/// benchmark's residency check anyway, which read the empty list as "verified:
/// nothing else is resident" and stamped `Residency: already alone` onto runs
/// whose server had never answered the question.
///
/// Transport failure stays a `throw` — unreachable is a fourth thing again, and
/// the callers that fail open on it already catch.
nonisolated enum LoadedInstanceListing: Sendable, Equatable {
    /// The server answered. `[]` here is a real answer: nothing is loaded.
    case listed([LoadedModelInstance])

    /// The server was reached but exposes no listing route, so the question has
    /// no answer here. Not an error — nothing is wrong and an explicit load may
    /// still proceed; it only means nothing can be adopted or audited.
    case unsupported

    /// Instances available to adopt, treating "cannot answer" as "nothing to
    /// adopt".
    ///
    /// Every adoption/reaping caller wants exactly this, and spelling it at the
    /// call site is the point: the collapse is a decision each caller makes out
    /// loud, rather than one the client makes for all of them. A caller that
    /// reports on the server's state must switch on the case instead — the
    /// benchmark does.
    var adoptable: [LoadedModelInstance] {
        switch self {
        case .listed(let instances): instances
        case .unsupported: []
        }
    }
}

nonisolated extension LLMClient {
    /// Default: no embedding-model listing. Test doubles inherit this so
    /// production use of `fetchEmbeddingModels` doesn't force every mock to
    /// implement it.
    func fetchEmbeddingModels(config _: LLMConfig) async throws -> [String] { [] }

    /// Default: provider doesn't expose a model-lifecycle API. Throws so any
    /// accidental use surfaces immediately rather than masquerading as success.
    func loadModel(
        provider _: LLMProvider, modelName _: String, baseURLString _: String
    ) async throws -> String {
        throw LLMClientError.providerError("model lifecycle not supported by this client")
    }

    func unloadModel(
        provider _: LLMProvider, instanceID _: String, baseURLString _: String
    ) async throws {
        throw LLMClientError.providerError("model lifecycle not supported by this client")
    }

    /// Default: this client can't enumerate loaded instances, and `.unsupported`
    /// is how it says that. It does not throw like `loadModel`/`unloadModel`,
    /// because being unable to LIST is not a failure — adoption callers fall
    /// through to `loadModel`, which surfaces a real error if the provider
    /// supports no lifecycle at all.
    ///
    /// This used to return `[]`, which is what a client says when the server
    /// really has nothing loaded. A double that never implemented the method
    /// thereby claimed an empty server, and so did the LM Studio client's 404
    /// branch in production.
    func listLoadedInstances(
        provider _: LLMProvider, baseURLString _: String
    ) async throws -> LoadedInstanceListing {
        .unsupported
    }

    /// Convenience overload without roleName — existing callers don't need to change.
    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger?,
        stepID: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        streamChat(
            config: config, messages: messages, tools: tools,
            logger: logger, stepID: stepID, roleName: nil)
    }
}
