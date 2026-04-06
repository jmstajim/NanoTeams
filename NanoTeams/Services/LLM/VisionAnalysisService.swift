import Foundation

/// Stateless service for analyzing images using a vision-capable LLM model.
/// DIP: accepts `any LLMClient` — no HTTP/SSE duplication.
enum VisionAnalysisService {

    /// Analyzes an image using the vision LLM model.
    /// Each call creates a fresh chat (session: nil) — no persistent context between calls.
    static func analyze(
        prompt: String,
        imageBase64: String,
        mimeType: String,
        config: LLMConfig,
        client: any LLMClient = LLMClientRouter(),
        logger: NetworkLogger? = nil
    ) async throws -> String {
        let messages = [
            ChatMessage(
                role: .system,
                content: """
                    You are an image analysis assistant. Describe what you see accurately and concisely. \
                    Answer the user's question about the image.
                    """
            ),
            ChatMessage(
                role: .user,
                content: prompt,
                imageContent: [ImageContent(base64Data: imageBase64, mimeType: mimeType)]
            ),
        ]

        var result = ""
        let stream = client.streamChat(
            config: config,
            messages: messages,
            tools: [],
            session: nil,
            logger: logger,
            stepID: nil
        )
        for try await event in stream {
            result += event.contentDelta
        }

        return ModelTokenCleaner.clean(result.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
