import Foundation

// MARK: - Request Building

extension NativeLMStudioClient {

    static func buildRequest(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        session: LLMSession?,
        omitSystemPromptOnContinuation: Bool = true
    ) -> NativeChatRequest {
        // Extract system prompt
        let systemMessages = messages.filter { $0.role == .system }
        var systemPrompt = systemMessages.compactMap(\.content).joined(separator: "\n\n")

        // Append tool schemas to system_prompt (native API has no `tools` parameter).
        // Models generate Harmony-format tool calls from message text, parsed by HarmonyToolCallParser.
        if !tools.isEmpty {
            if !systemPrompt.isEmpty { systemPrompt += "\n\n" }
            systemPrompt += buildToolSchemaSection(tools: tools)
        }

        // On stateful continuations, system_prompt can be omitted because `/api/v1/chat`
        // persists it in the response chain (unlike `/v1/responses` where `instructions`
        // do NOT carry over). This saves ~2500 tokens per call on iterations 3+.
        let effectiveSystemPrompt: String?
        if session != nil && omitSystemPromptOnContinuation {
            effectiveSystemPrompt = nil
        } else {
            effectiveSystemPrompt = systemPrompt.isEmpty ? nil : systemPrompt
        }

        // Build input as a plain string. The API documents `input` as `string | array(images)`.
        // For text-only, a string is the most compatible format.
        //
        // Stateful:  LLMExecutionService already sliced messages to new messages only.
        //            Tool results and user messages are joined into one string.
        // Stateless: Full conversation history as labelled text segments.
        let nonSystemMessages = messages.filter { $0.role != .system }
        var textParts: [String] = []

        if session != nil {
            // Stateful: only user + tool result messages; assistant is in the server chain
            for msg in nonSystemMessages {
                switch msg.role {
                case .user:
                    textParts.append(msg.content ?? "")
                case .tool:
                    textParts.append("[Tool Result]\n\(msg.content ?? "")")
                case .assistant, .system:
                    break
                }
            }
        } else {
            // Stateless: full conversation history (first call or after HTTP 400 session reset)
            for msg in nonSystemMessages {
                switch msg.role {
                case .user:
                    textParts.append(msg.content ?? "")
                case .assistant:
                    textParts.append("[Assistant]\n\(msg.content ?? "")")
                case .tool:
                    textParts.append("[Tool Result]\n\(msg.content ?? "")")
                case .system:
                    break
                }
            }
        }

        let inputString = textParts.joined(separator: "\n\n")

        // Detect multimodal messages (imageContent present) → build array input
        let hasImages = nonSystemMessages.contains { $0.imageContent != nil && !($0.imageContent!.isEmpty) }
        let input: NativeChatInput
        if hasImages {
            var parts: [MultimodalInputPart] = []
            if !inputString.isEmpty {
                parts.append(.text(inputString))
            }
            for msg in nonSystemMessages {
                for img in msg.imageContent ?? [] {
                    parts.append(.image(dataURL: "data:\(img.mimeType);base64,\(img.base64Data)"))
                }
            }
            input = .multimodal(parts)
        } else {
            input = .text(inputString)
        }

        return NativeChatRequest(
            model: config.modelName,
            systemPrompt: effectiveSystemPrompt,
            input: input,
            previousResponseID: session?.responseID,
            store: !hasImages,  // Vision: fresh chat, no server-side storage
            stream: true,
            maxOutputTokens: config.maxTokens > 0 ? config.maxTokens : nil,
            temperature: config.temperature
        )
    }

    // MARK: - Tool Schema Section

    private static func buildToolSchemaSection(tools: [ToolSchema]) -> String {
        var block = "## Tool Calling\n\n"
        block += "Call tools using this Harmony format:\n"
        block += "<|call|>{\"name\":\"TOOL_NAME\",\"arguments\":{...}}<|end|>\n\n"
        // Concrete example resolves a dual-`name` confusion: when a tool's
        // parameter is also called `name` (create_artifact.name = artifact
        // name), some models drop the outer `name` and emit
        // `{"arguments":{"name":...}}` by itself. Showing both levels filled
        // in pins the distinction.
        block += "Example:\n"
        block += "<|call|>{\"name\":\"create_artifact\","
        block += "\"arguments\":{\"name\":\"Product Requirements\","
        block += "\"content\":\"...\",\"format\":\"markdown\"}}<|end|>\n\n"
        block += "The top-level `name` is the tool id. "
        block += "If a tool parameter is also called `name`, it goes inside `arguments` — "
        block += "the top-level `name` must always be the tool id, never the parameter value.\n\n"
        block += "### Available Tools\n\n"

        // Compact JSON (no pretty-print) — saves ~30-40% of the schema-section bytes
        // vs `makeDisplayEncoder()`, which is significant: every first-call request
        // pays the system_prompt cost (15k+ chars when pretty-printed for 22 tools).
        // `sortedKeys` keeps the output deterministic for prompt caching;
        // `withoutEscapingSlashes` avoids `\/` noise in any path-like description text.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for tool in tools {
            block += "**\(tool.name)**: \(tool.description)\n"
            if let schemaData = try? encoder.encode(tool.parameters),
               let schemaString = String(data: schemaData, encoding: .utf8)
            {
                block += "Parameters: `\(schemaString)`\n\n"
            }
        }

        return block
    }
}
