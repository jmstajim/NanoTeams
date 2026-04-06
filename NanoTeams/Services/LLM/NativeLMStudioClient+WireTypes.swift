import Foundation

/// Wire types for NativeLMStudioClient: request/response serialization structs.
extension NativeLMStudioClient {

    // MARK: - Polymorphic Input (OCP)

    /// Polymorphic `input`: plain string for text, array for multimodal.
    enum NativeChatInput: Encodable {
        case text(String)
        case multimodal([MultimodalInputPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let s): try container.encode(s)
            case .multimodal(let parts): try container.encode(parts)
            }
        }
    }

    /// Multimodal input part for `/api/v1/chat`.
    /// - Text:  `{"type": "text", "content": "..."}`
    /// - Image: `{"type": "image", "data_url": "data:mime;base64,..."}`
    enum MultimodalInputPart: Encodable {
        case text(String)
        case image(dataURL: String)  // "data:mime;base64,..."

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let value):
                try container.encode("text", forKey: .type)
                try container.encode(value, forKey: .content)
            case .image(let dataURL):
                assert(dataURL.hasPrefix("data:"), "Image data URL must be a data: URI")
                try container.encode("image", forKey: .type)
                try container.encode(dataURL, forKey: .dataURL)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, content
            case dataURL = "data_url"
        }
    }

    // MARK: - Request

    struct NativeChatRequest: Encodable {
        var model: String
        var systemPrompt: String?
        var input: NativeChatInput
        var previousResponseID: String?
        var store: Bool
        var stream: Bool
        var maxOutputTokens: Int?
        var temperature: Double?

        enum CodingKeys: String, CodingKey {
            case model, input, store, stream, temperature
            case systemPrompt = "system_prompt"
            case previousResponseID = "previous_response_id"
            case maxOutputTokens = "max_output_tokens"
        }
    }

    // MARK: - SSE Event Types

    struct MessageDeltaEvent: Decodable {
        var content: String?
    }

    struct ChatEndEvent: Decodable {
        var responseID: String?
        var stats: Stats?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TopKeys.self)
            // Nested format: {"type":"chat.end","result":{"response_id":...,"stats":...}}
            if let result = try container.decodeIfPresent(ResultPayload.self, forKey: .result) {
                responseID = result.responseID
                stats = result.stats
            } else {
                // Flat format: {"response_id":...,"stats":...} (per docs)
                responseID = try container.decodeIfPresent(String.self, forKey: .responseID)
                stats = try container.decodeIfPresent(Stats.self, forKey: .stats)
            }
        }

        enum TopKeys: String, CodingKey {
            case result
            case responseID = "response_id"
            case stats
        }

        struct ResultPayload: Decodable {
            var responseID: String?
            var stats: Stats?
            enum CodingKeys: String, CodingKey {
                case responseID = "response_id"
                case stats
            }
        }

        struct Stats: Decodable {
            var inputTokens: Int
            var outputTokens: Int

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // Handle both: docs format (tokens_in/tokens_out) and actual server (input_tokens/total_output_tokens)
                inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
                    ?? container.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
                outputTokens = try container.decodeIfPresent(Int.self, forKey: .totalOutputTokens)
                    ?? container.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
            }

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case tokensIn = "tokens_in"
                case totalOutputTokens = "total_output_tokens"
                case tokensOut = "tokens_out"
            }
        }
    }

    struct ErrorEvent: Decodable {
        var message: String?
    }

    struct PromptProcessingProgressEvent: Decodable {
        var progress: Double
    }

    // MARK: - Model List Responses

    /// LM Studio native `/api/v1/models` response: `{ "models": [{ "key": "...", "type": "llm"|"embedding", ... }] }`
    struct NativeModelListResponse: Decodable {
        let models: [NativeModelInfo]

        struct NativeModelInfo: Decodable {
            let key: String
            let type: String?
            let capabilities: ModelCapabilities?
        }

        struct ModelCapabilities: Decodable {
            let vision: Bool?
        }
    }

    /// OpenAI-compatible `/v1/models` response: `{ "data": [{ "id": "..." }] }`
    struct OpenAIModelListResponse: Decodable {
        let data: [OpenAIModelInfo]

        struct OpenAIModelInfo: Decodable {
            let id: String
        }
    }
}
