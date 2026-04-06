import Foundation

/// Routes LLM requests to the correct client based on provider.
///
/// - LM Studio → NativeLMStudioClient (`/api/v1/chat`)
struct LLMClientRouter: LLMClient {
    private let nativeClient: LLMClient

    init(nativeClient: LLMClient = NativeLMStudioClient()) {
        self.nativeClient = nativeClient
    }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        session: LLMSession?,
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        nativeClient.streamChat(
            config: config,
            messages: messages,
            tools: tools,
            session: session,
            logger: logger,
            stepID: stepID,
            roleName: roleName
        )
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] {
        try await nativeClient.fetchModels(config: config, visionOnly: visionOnly)
    }
}
