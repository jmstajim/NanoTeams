import Foundation

// MARK: - Network Session

/// DIP abstraction over URLSession for testable network I/O.
/// URLSession conforms automatically via its existing `data(for:)` and `bytes(for:)` overloads.
protocol NetworkSession: Sendable {
    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse)
    func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

extension URLSession: @retroactive NetworkSession {
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
protocol LLMClient: Sendable {

    /// Stream a chat completion from the LLM provider.
    ///
    /// - Parameters:
    ///   - config: Provider configuration (URL, model, API key, etc.)
    ///   - messages: Conversation history
    ///   - tools: Available tool schemas
    ///   - session: Optional session for stateful providers.
    ///     Stateless providers ignore this parameter.
    ///   - logger: Optional network logger
    ///   - stepID: Optional step ID for log correlation
    ///   - roleName: Optional role name for log attribution
    /// - Returns: Async stream of events (content, thinking, tool calls, usage, session)
    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        session: LLMSession?,
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error>

    /// Fetch available models from the provider.
    /// Not all providers may support this.
    /// - Parameter visionOnly: When `true`, returns only vision-capable models.
    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String]

    /// Fetch available *embedding* models from the provider. Used by the
    /// broad-search semantic-expansion card which needs to let the user
    /// pick from LM Studio's embedding family (e.g. `nomic-embed-text-v1.5`).
    /// Default implementation returns `[]` so test doubles don't break —
    /// real clients (`NativeLMStudioClient`, `LLMClientRouter`) override.
    func fetchEmbeddingModels(config: LLMConfig) async throws -> [String]

    /// Load a model into LM Studio's runtime. Provider-specific lifecycle
    /// surface used by `EmbeddingModelLifecycleService` to ensure the embed
    /// model is in memory while Expanded Search is enabled. Takes a raw
    /// `baseURLString` rather than `LLMConfig` because the embed URL is
    /// distinct from the chat-LLM URL (separate `EmbeddingConfig`).
    /// Returns the `instance_id` to use for subsequent `unloadModel`.
    /// Default impl throws `providerError` so a non-LM-Studio router is loud
    /// instead of silently lying.
    func loadModel(modelName: String, baseURLString: String) async throws -> String

    /// Unload a previously loaded model instance. Idempotent on the server
    /// side: if the instance is already gone (e.g. LM Studio restarted),
    /// implementations should return without throwing.
    func unloadModel(instanceID: String, baseURLString: String) async throws

    /// Lists model instances currently loaded on the server. The server
    /// is the source of truth; in-process state can drift across app
    /// restarts. Used by `EmbeddingModelLifecycleService` to adopt an
    /// existing instance instead of spawning a duplicate (LM Studio
    /// otherwise creates `name`, `name:2`, `name:3`, … per `loadModel`
    /// call). Default impl returns `[]` so non-LM-Studio routers fall
    /// through to `loadModel`.
    ///
    /// `modelName` is the canonical name (suffix-stripped) for matching
    /// against `EmbeddingConfig.modelName`; `instanceID` is the raw id
    /// to pass to `unloadModel`.
    func listLoadedInstances(baseURLString: String) async throws -> [LoadedModelInstance]
}

/// Server-side record of a loaded model instance. Returned by
/// `LLMClient.listLoadedInstances`.
struct LoadedModelInstance: Sendable, Equatable {
    /// Canonical model name (LM Studio dedup suffix `:N` stripped). Match
    /// this against `EmbeddingConfig.modelName` to decide whether to adopt
    /// an existing instance.
    let modelName: String

    /// Raw instance id as the server reports it. Pass this to
    /// `unloadModel(instanceID:)`. Equals `modelName` for the first
    /// loaded instance; `\(modelName):N` for duplicate-loads.
    let instanceID: String
}

extension LLMClient {
    /// Default: no embedding-model listing. Test doubles inherit this so
    /// production use of `fetchEmbeddingModels` doesn't force every mock to
    /// implement it.
    func fetchEmbeddingModels(config _: LLMConfig) async throws -> [String] { [] }

    /// Default: provider doesn't expose a model-lifecycle API. Throws so any
    /// accidental use surfaces immediately rather than masquerading as success.
    func loadModel(modelName _: String, baseURLString _: String) async throws -> String {
        throw LLMClientError.providerError("model lifecycle not supported by this client")
    }

    func unloadModel(instanceID _: String, baseURLString _: String) async throws {
        throw LLMClientError.providerError("model lifecycle not supported by this client")
    }

    /// Default: provider can't enumerate loaded instances. Returning `[]`
    /// (rather than throwing like `loadModel`/`unloadModel`) is the safer
    /// "lie" here — caller falls through to `loadModel`, which surfaces a
    /// real error if the provider doesn't support lifecycle at all.
    func listLoadedInstances(baseURLString _: String) async throws -> [LoadedModelInstance] {
        []
    }

    /// Convenience overload without roleName — existing callers don't need to change.
    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        session: LLMSession?,
        logger: NetworkLogger?,
        stepID: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        streamChat(
            config: config, messages: messages, tools: tools,
            session: session, logger: logger, stepID: stepID, roleName: nil)
    }
}
