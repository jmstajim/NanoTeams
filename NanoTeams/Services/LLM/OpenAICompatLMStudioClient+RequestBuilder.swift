import Foundation

// MARK: - Request Building

extension OpenAICompatLMStudioClient {

    /// Builds one stateless `/v1/chat/completions` request: the full conversation every
    /// call in the OpenAI message shape, the tool catalog on `tools`.
    ///
    /// Mirrors `NativeLMStudioClient.buildRequest` where the two agree — every system message
    /// joins into one, the tool block auto-appends when the prompt lacks it (here the NATIVE
    /// block: the one-tool rule and the injection boundary, never the catalog), images ride
    /// the request — and departs where the endpoint's own shape does:
    ///
    /// - Assistant turns carry `tool_calls` as OpenAI objects (`arguments` a string), never
    ///   Harmony text. The streaming path files the calls under `ChatMessage.toolCalls` and
    ///   truncates nothing here — a native turn has no envelope in its content.
    /// - Every tool result is its own `role: tool` message with the `tool_call_id` of the call
    ///   it answers, paired by `NativeToolTurnPairing` when the message carries no id.
    /// - `content` is `""` rather than absent on an assistant turn that only made calls —
    ///   measured as what the server accepts (2026-09-13).
    /// - An assistant turn's `reasoning` rides `reasoning_content`, verbatim (2026-09-14). The
    ///   turn goes back as the model generated it — think block, calls, content — so a server
    ///   whose cache cannot be trimmed finds the request a byte-identical continuation of what
    ///   it already holds; the template's gate decides what of it the model sees again. See
    ///   `ChatMessage.reasoning` for the measurement and `docs/architecture/prefix-cache.md`.
    /// - Images: a user turn with images becomes the parts array; a TOOL turn with images
    ///   (a screenshot result) keeps its text and is followed by a user turn holding only the
    ///   image parts, because the OpenAI tool role takes a string. Position is preserved,
    ///   which is what the single-use image strip depends on.
    static func buildRequest(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema]
    ) -> ChatCompletionRequest {
        let systemMessages = messages.filter { $0.role == .system }
        var systemPrompt = systemMessages.compactMap(\.content).joined(separator: "\n\n")
        if !tools.isEmpty && !systemPrompt.contains(NativeLMStudioClient.toolBlockMarker) {
            systemPrompt = TemplateResolver.appendingToolCallingSection(
                NativeLMStudioClient.buildToolSchemaSection(tools: tools, mode: .native),
                to: systemPrompt)
        }

        var out: [ChatCompletionRequest.Message] = []
        if !systemPrompt.isEmpty {
            out.append(.init(role: "system", content: .text(systemPrompt)))
        }

        let pairs = NativeToolTurnPairing.pairs(in: messages)

        for (index, msg) in messages.enumerated() {
            let images = msg.imageContent ?? []
            switch msg.role {
            case .system:
                // Already merged into the first message above.
                continue
            case .user:
                out.append(.init(role: "user", content: content(text: msg.content ?? "", images: images)))
            case .tool:
                out.append(.init(
                    role: "tool",
                    content: .text(msg.content ?? ""),
                    toolCallID: pairs[index]?.id ?? msg.toolCallID ?? UUID().uuidString))
                if !images.isEmpty {
                    out.append(.init(
                        role: "user",
                        content: .parts(images.map { .imageURL(dataURL(for: $0)) })))
                }
            case .assistant:
                let calls = (msg.toolCalls ?? []).map(ChatCompletionRequest.ToolCall.init)
                out.append(.init(
                    role: "assistant",
                    content: .text(msg.content ?? ""),
                    toolCalls: calls.isEmpty ? nil : calls,
                    reasoningContent: msg.reasoning))
            }
        }

        return ChatCompletionRequest(
            model: config.modelName,
            messages: out,
            tools: tools.isEmpty ? nil : tools.map(NativeToolDeclaration.init),
            stream: true,
            streamOptions: .init(includeUsage: true),
            temperature: config.temperature,
            maxTokens: config.maxOutputTokens
        )
    }

    private static func content(
        text: String, images: [ImageContent]
    ) -> ChatCompletionRequest.Content {
        guard !images.isEmpty else { return .text(text) }
        var parts: [ChatCompletionRequest.Part] = []
        if !text.isEmpty { parts.append(.text(text)) }
        parts += images.map { .imageURL(dataURL(for: $0)) }
        return .parts(parts)
    }

    private static func dataURL(for image: ImageContent) -> String {
        "data:\(image.mimeType);base64,\(image.base64Data)"
    }
}
