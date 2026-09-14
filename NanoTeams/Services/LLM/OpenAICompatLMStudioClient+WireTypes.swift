import Foundation

/// Wire types for `OpenAICompatLMStudioClient`: the OpenAI-shaped `/v1/chat/completions`
/// request and its streaming chunk. Every key is spelled explicitly — the wire decoder has
/// no snake_case strategy — and every telemetry field decodes leniently, the rule both
/// sibling clients' chunk types follow (`OllamaClient.ChatChunk`, `ChatEndEvent.Stats`).
nonisolated extension OpenAICompatLMStudioClient {

    // MARK: - Request

    /// `POST /v1/chat/completions`. Carries the SAME sampling policy as the two other request
    /// types: nothing beyond the optional `temperature` (the judge pin) and the benchmark's
    /// output cap, whose spelling here is `max_tokens` — the OpenAI name, distinct from the
    /// native endpoint's `max_output_tokens` (`NativeChatRequest`). Absent for every role step.
    struct ChatCompletionRequest: Encodable {
        var model: String
        var messages: [Message]
        /// The native tool catalog. Absent (not `[]`) on a tool-less request.
        var tools: [NativeToolDeclaration]?
        var stream: Bool
        /// `{"include_usage": true}` — without it the stream carries no token counts at all
        /// (measured 2026-09-13, LM Studio 0.4.21).
        var streamOptions: StreamOptions?
        var temperature: Double?
        var maxTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, messages, tools, stream, temperature
            case streamOptions = "stream_options"
            case maxTokens = "max_tokens"
        }

        struct StreamOptions: Encodable, Equatable {
            var includeUsage: Bool
            enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
        }

        /// One message. `content` is a string on every role but a multimodal user turn, where
        /// it is the parts array OpenAI defines (`text` / `image_url`).
        struct Message: Encodable, Equatable {
            var role: String
            var content: Content
            /// Assistant turns: the calls the model made, `arguments` as the STRING the model
            /// wrote — the OpenAI shape, and the one LM Studio rendered into its template.
            var toolCalls: [ToolCall]?
            /// Tool turns: the id of the call this result answers.
            var toolCallID: String?
            /// Assistant turns: the reasoning the model generated on that turn, verbatim, in the
            /// field the OpenAI-compatible shape reserves for it — the same name LM Studio
            /// streams it back under. Absent (no key, never `""`) when the turn had none: a
            /// template that reads `message.reasoning_content is string` would render an empty
            /// think block for `""`. The template's replay gate decides what the model sees.
            var reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
                case toolCallID = "tool_call_id"
                case reasoningContent = "reasoning_content"
            }

            init(
                role: String, content: Content, toolCalls: [ToolCall]? = nil,
                toolCallID: String? = nil, reasoningContent: String? = nil
            ) {
                self.role = role
                self.content = content
                self.toolCalls = toolCalls
                self.toolCallID = toolCallID
                self.reasoningContent = reasoningContent
            }
        }

        enum Content: Encodable, Equatable {
            case text(String)
            case parts([Part])

            func encode(to encoder: Encoder) throws {
                var single = encoder.singleValueContainer()
                switch self {
                case .text(let text): try single.encode(text)
                case .parts(let parts): try single.encode(parts)
                }
            }

            /// The text half, whichever shape — for tests and the log.
            var text: String {
                switch self {
                case .text(let text): return text
                case .parts(let parts):
                    return parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
                        .joined(separator: "\n\n")
                }
            }
        }

        enum Part: Encodable, Equatable {
            case text(String)
            case imageURL(String)

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: PartKeys.self)
                switch self {
                case .text(let text):
                    try container.encode("text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case .imageURL(let url):
                    try container.encode("image_url", forKey: .type)
                    try container.encode(ImageURL(url: url), forKey: .imageURL)
                }
            }

            private enum PartKeys: String, CodingKey {
                case type, text
                case imageURL = "image_url"
            }

            private struct ImageURL: Encodable { let url: String }
        }

        struct ToolCall: Encodable, Equatable {
            var id: String
            var type: String
            var function: Function

            struct Function: Encodable, Equatable {
                var name: String
                var arguments: String
            }

            init(_ call: ChatToolCall) {
                id = call.id
                type = "function"
                // The model's own bytes, verbatim: they are what the server rendered and cached.
                // An empty value is the one exception, as in `HarmonyToolCallEnvelope`.
                let trimmed = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                function = Function(name: call.name, arguments: trimmed.isEmpty ? "{}" : call.argumentsJSON)
            }
        }
    }

    // MARK: - Streaming chunk

    /// One `data:` payload of the stream: `{"choices":[{"delta":{…},"finish_reason":…}],"usage":…}`.
    /// A mid-stream failure arrives as `{"error": …}` in the same envelope shape the REST
    /// routes use (`NativeLMStudioClient.LMStudioErrorEnvelope`).
    struct ChatCompletionChunk: Decodable {
        var choices: [Choice]
        var usage: Usage?
        var error: NativeLMStudioClient.LMStudioErrorEnvelope.ErrorDetail?

        enum CodingKeys: String, CodingKey { case choices, usage, error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            choices = try c.decodeIfPresent([Choice].self, forKey: .choices) ?? []
            // Telemetry: a mistyped count must not cost the chunk its delta.
            usage = (try? c.decodeIfPresent(Usage.self, forKey: .usage)) ?? nil
            error = (try? c.decodeIfPresent(
                NativeLMStudioClient.LMStudioErrorEnvelope.ErrorDetail.self, forKey: .error)) ?? nil
        }

        struct Choice: Decodable {
            var delta: Delta?
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                delta = try c.decodeIfPresent(Delta.self, forKey: .delta)
                finishReason = (try? c.decodeIfPresent(String.self, forKey: .finishReason)) ?? nil
            }
        }

        struct Delta: Decodable {
            var content: String?
            /// LM Studio's reasoning field under its default app setting…
            var reasoningContent: String?
            /// …and the name gpt-oss-class models report it under.
            var reasoning: String?
            var toolCalls: [ToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content = try c.decodeIfPresent(String.self, forKey: .content)
                reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
                reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
                // Lenient: a call piece the server could not spell must not cost the content
                // piece beside it.
                toolCalls = (try? c.decodeIfPresent([ToolCallDelta].self, forKey: .toolCalls)) ?? nil
            }

            /// Whichever reasoning field the chunk carried. Both at once is not a shape any
            /// server sends; the LM Studio spelling wins if it ever did.
            var reasoningDelta: String? { reasoningContent ?? reasoning }
        }

        struct ToolCallDelta: Decodable {
            var index: Int?
            var id: String?
            var function: Function?

            struct Function: Decodable {
                var name: String?
                var arguments: String?
            }
        }

        struct Usage: Decodable {
            var promptTokens: Int?
            var completionTokens: Int?
            var reasoningTokens: Int?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case completionTokensDetails = "completion_tokens_details"
            }

            enum DetailKeys: String, CodingKey {
                case reasoningTokens = "reasoning_tokens"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                promptTokens = (try? c.decodeIfPresent(Int.self, forKey: .promptTokens)) ?? nil
                completionTokens = (try? c.decodeIfPresent(Int.self, forKey: .completionTokens)) ?? nil
                if let details = try? c.nestedContainer(keyedBy: DetailKeys.self, forKey: .completionTokensDetails) {
                    reasoningTokens = (try? details.decodeIfPresent(Int.self, forKey: .reasoningTokens)) ?? nil
                } else {
                    reasoningTokens = nil
                }
            }
        }
    }
}
