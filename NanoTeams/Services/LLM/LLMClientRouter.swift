import Foundation

/// Routes LLM requests to the correct client based on `config.provider`.
///
/// - LM Studio → `NativeLMStudioClient` (`/api/v1/chat`, explicit model lifecycle)
/// - Ollama → `OllamaClient` (`/api/chat`, server-managed residency)
///
/// Both are stateless: every request carries the full conversation.
///
/// The model-lifecycle surface (`loadModel` / `unloadModel` /
/// `listLoadedInstances`) dispatches on provider like everything else, because
/// it takes one explicitly. It did not until 2026-08-19: those three methods
/// carried a bare `baseURLString`, so this router had nothing to dispatch on
/// and sent every one of them to the LM Studio client. The comment here used to
/// call that "correct by construction" on the grounds that explicit lifecycle is
/// an LM-Studio-only concept — which was true of the residency LEDGER and false
/// of the surface, because `OllamaClient` had already implemented
/// `listLoadedInstances` (`/api/ps`) and `unloadModel` (`keep_alive: 0`) for the
/// benchmark, and neither was reachable. Pointed at Ollama the LM Studio client
/// asked for `/api/v0/models`, got `404 page not found`, and returned `[]` — so
/// the benchmark recorded "already alone" about a machine it had never asked.
///
/// `loadModel` stays LM-Studio-only in EFFECT — Ollama's client inherits the
/// throwing default, because Ollama loads on first use and offers no load
/// endpoint — but it is now the provider client that says so, not the router.
///
/// **Three clients, two providers** (2026-09-13). LM Studio's own `/api/v1/chat` has no `tools`
/// field, so a `.native` request there goes to `OpenAICompatLMStudioClient` on
/// `/v1/chat/completions`. The predicate is `usesOpenAICompatEndpoint` and it is explicit on
/// purpose: LM Studio, native mode, AND either a non-empty tool catalog or a wire that already
/// carries native `tool_calls` — a context-compaction summary of a native step passes the
/// step's tools for exactly that reason. Every tool-less call (vision, the judges, the
/// Supervisor auto-answer, consultations, the benchmark) stays on the native endpoint, which
/// is the one that reports `prompt_processing.*` and `stats`. Only `streamChat` is routed
/// this way; the lifecycle and probe surface has one LM Studio answer, the native client's,
/// which the OpenAI-compat client delegates to as well.
nonisolated struct LLMClientRouter: LLMClient {
    private let nativeClient: LLMClient
    private let ollamaClient: LLMClient
    private let openAICompatClient: LLMClient

    init(
        nativeClient: LLMClient = NativeLMStudioClient(),
        ollamaClient: LLMClient = OllamaClient(),
        openAICompatClient: LLMClient? = nil
    ) {
        self.nativeClient = nativeClient
        self.ollamaClient = ollamaClient
        // Built around the SAME native client when the default was taken, so the two LM
        // Studio routes share one ensurer census and one lifecycle owner. A router built on a
        // DOUBLE routes the compat surface to that double: the alternative resolved outward
        // to a real `NativeLMStudioClient` on `URLSession.shared` with the process-global
        // ensurer — the #49 seam, one `.native` request away from the network in a test.
        self.openAICompatClient = openAICompatClient
            ?? (nativeClient as? NativeLMStudioClient).map { OpenAICompatLMStudioClient(native: $0) }
            ?? nativeClient
    }

    /// Convenience init that builds provider clients with a non-default
    /// token resolver. Used by the settings UI to inject a typed-but-unsaved
    /// SecureField token for "Test Connection" / "Fetch Models" before the
    /// user has committed it to the Keychain.
    init(tokenResolver: any LLMTokenResolver) {
        let native = NativeLMStudioClient(tokenResolver: tokenResolver)
        self.nativeClient = native
        self.ollamaClient = OllamaClient(tokenResolver: tokenResolver)
        self.openAICompatClient = OpenAICompatLMStudioClient(tokenResolver: tokenResolver, native: native)
    }

    private func client(for provider: LLMProvider) -> LLMClient {
        switch provider {
        case .lmStudio: nativeClient
        case .ollama: ollamaClient
        }
    }

    /// Whether a chat request goes to the OpenAI-compatible LM Studio endpoint. Pinned by
    /// `LLMClientRouterDispatchTests`; see the type doc for why each clause is there.
    static func usesOpenAICompatEndpoint(
        config: LLMConfig, tools: [ToolSchema], messages: [ChatMessage]
    ) -> Bool {
        guard config.provider == .lmStudio, config.toolCallingMode == .native else { return false }
        if !tools.isEmpty { return true }
        return messages.contains { $0.role == .assistant && !($0.toolCalls ?? []).isEmpty }
    }

    private func chatClient(
        config: LLMConfig, tools: [ToolSchema], messages: [ChatMessage]
    ) -> LLMClient {
        Self.usesOpenAICompatEndpoint(config: config, tools: tools, messages: messages)
            ? openAICompatClient
            : client(for: config.provider)
    }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        chatClient(config: config, tools: tools, messages: messages).streamChat(
            config: config,
            messages: messages,
            tools: tools,
            logger: logger,
            stepID: stepID,
            roleName: roleName
        )
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] {
        try await client(for: config.provider).fetchModels(config: config, visionOnly: visionOnly)
    }

    func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] {
        try await client(for: config.provider).fetchEmbeddingModels(config: config)
    }

    func loadModel(
        provider: LLMProvider, modelName: String, baseURLString: String
    ) async throws -> String {
        try await client(for: provider)
            .loadModel(provider: provider, modelName: modelName, baseURLString: baseURLString)
    }

    func unloadModel(
        provider: LLMProvider, instanceID: String, baseURLString: String
    ) async throws {
        try await client(for: provider)
            .unloadModel(provider: provider, instanceID: instanceID, baseURLString: baseURLString)
    }

    func listLoadedInstances(
        provider: LLMProvider, baseURLString: String
    ) async throws -> LoadedInstanceListing {
        try await client(for: provider)
            .listLoadedInstances(provider: provider, baseURLString: baseURLString)
    }

    func modelSupportsVision(config: LLMConfig) async -> Bool? {
        await client(for: config.provider).modelSupportsVision(config: config)
    }

    func modelContextLength(config: LLMConfig) async -> Int? {
        await client(for: config.provider).modelContextLength(config: config)
    }

    func modelLoadDetails(config: LLMConfig) async -> ModelLoadDetails? {
        await client(for: config.provider).modelLoadDetails(config: config)
    }

    func toolCallingSupport(config: LLMConfig) async -> Bool? {
        await client(for: config.provider).toolCallingSupport(config: config)
    }
}
