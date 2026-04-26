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

    // MARK: - Model Lifecycle (load / unload)

    /// `POST /api/v1/models/load` request body. `echo_load_config: true` so the
    /// server returns the applied configuration in the response — we don't use
    /// it yet but it's cheap to ask for and useful for future diagnostics.
    /// Explicit `CodingKeys` insulate against any future encoder-strategy
    /// change that would silently double-snake `echo_load_config`.
    struct LoadModelRequest: Encodable {
        let model: String
        let echo_load_config: Bool

        enum CodingKeys: String, CodingKey {
            case model
            case echo_load_config
        }
    }

    /// `POST /api/v1/models/load` response. We only consume `instance_id` —
    /// other fields (`load_time_seconds`, `status`, `load_config`) are decoded
    /// best-effort for logs.
    struct LoadModelResponse: Decodable {
        let instance_id: String
        let status: String?
        let type: String?

        enum CodingKeys: String, CodingKey {
            case instance_id
            case status
            case type
        }
    }

    /// `POST /api/v1/models/unload` request body.
    struct UnloadModelRequest: Encodable {
        let instance_id: String

        enum CodingKeys: String, CodingKey {
            case instance_id
        }
    }

    /// LM Studio error envelope. Two observed shapes — `{"error": "msg"}`
    /// (bare string) and `{"error": {"message": "msg"}}` (object). Decoder
    /// accepts both via `singleValueContainer`. Used by `loadModel`/`unloadModel`
    /// to detect "already loaded" / "already unloaded" semantics from the
    /// `error.message` field ONLY — never from the raw body, because real
    /// error strings (e.g. LoRA "the requested adapter is not loaded into the
    /// base model") collide with our success substrings.
    struct LMStudioErrorEnvelope: Decodable {
        let error: ErrorDetail?

        struct ErrorDetail: Decodable {
            let message: String?

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer().decode(String.self) {
                    self.message = single
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.message = try container.decodeIfPresent(String.self, forKey: .message)
            }

            enum CodingKeys: String, CodingKey { case message }
        }
    }

    /// `GET /api/v0/models` response. LM Studio's per-instance listing,
    /// distinct from the OpenAI-shaped `/api/v1/models` (which has no
    /// per-instance state). Used by `listLoadedInstances` to detect models
    /// already loaded server-side and avoid creating duplicates on app
    /// restart. Only `id` and `state` are consumed; other fields decoded
    /// best-effort.
    struct V0ModelListResponse: Decodable {
        let data: [Entry]

        struct Entry: Decodable {
            /// Per-instance id. `name` for the first instance, `name:N`
            /// (N >= 2) for duplicates. Use `NativeLMStudioClient.canonicalModelName`
            /// to recover the un-suffixed model name.
            let id: String
            /// Either `"loaded"` or `"not-loaded"`. Filter on this before
            /// touching the entry.
            let state: String?
            /// Optional category — `"embeddings"`, `"llm"`, `"vlm"`, etc.
            /// Decoded best-effort.
            let type: String?
        }
    }
}
