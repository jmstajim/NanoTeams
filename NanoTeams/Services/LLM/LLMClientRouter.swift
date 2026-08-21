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
nonisolated struct LLMClientRouter: LLMClient {
    private let nativeClient: LLMClient
    private let ollamaClient: LLMClient

    init(
        nativeClient: LLMClient = NativeLMStudioClient(),
        ollamaClient: LLMClient = OllamaClient()
    ) {
        self.nativeClient = nativeClient
        self.ollamaClient = ollamaClient
    }

    /// Convenience init that builds provider clients with a non-default
    /// token resolver. Used by the settings UI to inject a typed-but-unsaved
    /// SecureField token for "Test Connection" / "Fetch Models" before the
    /// user has committed it to the Keychain.
    init(tokenResolver: any LLMTokenResolver) {
        self.nativeClient = NativeLMStudioClient(tokenResolver: tokenResolver)
        self.ollamaClient = OllamaClient(tokenResolver: tokenResolver)
    }

    private func client(for provider: LLMProvider) -> LLMClient {
        switch provider {
        case .lmStudio: nativeClient
        case .ollama: ollamaClient
        }
    }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        client(for: config.provider).streamChat(
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
}
