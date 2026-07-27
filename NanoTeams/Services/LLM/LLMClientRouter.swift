import Foundation

/// Routes LLM requests to the correct client based on `config.provider`.
///
/// - LM Studio → `NativeLMStudioClient` (`/api/v1/chat`, explicit model lifecycle)
/// - Ollama → `OllamaClient` (`/api/chat`, server-managed residency)
///
/// Both are stateless: every request carries the full conversation.
///
/// The model-lifecycle surface (`loadModel` / `unloadModel` /
/// `listLoadedInstances`) takes a bare `baseURLString` and cannot dispatch on
/// provider — it always goes to the LM Studio client. That is correct by
/// construction: explicit lifecycle is an LM-Studio-only concept
/// (`LLMProvider.managesModelResidency`), the residency ledger only ever
/// contains instances the LM Studio client loaded, and
/// `NativeLMStudioClient.listLoadedInstances` degrades to `[]` on a 404 from
/// a non-LM-Studio server.
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

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] {
        try await client(for: config.provider).fetchModels(config: config, visionOnly: visionOnly)
    }

    func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] {
        try await client(for: config.provider).fetchEmbeddingModels(config: config)
    }

    func loadModel(modelName: String, baseURLString: String) async throws -> String {
        try await nativeClient.loadModel(modelName: modelName, baseURLString: baseURLString)
    }

    func unloadModel(instanceID: String, baseURLString: String) async throws {
        try await nativeClient.unloadModel(instanceID: instanceID, baseURLString: baseURLString)
    }

    func listLoadedInstances(baseURLString: String) async throws -> [LoadedModelInstance] {
        try await nativeClient.listLoadedInstances(baseURLString: baseURLString)
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
