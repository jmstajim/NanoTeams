import Foundation

/// Wire types for NativeLMStudioClient: request/response serialization structs.
nonisolated extension NativeLMStudioClient {

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

    /// Deliberately carries NO sampling keys beyond the optional `temperature`
    /// (internal-only: the security-judge verdict pin). LM Studio's per-model
    /// config is the source of truth for generation parameters — an omitted
    /// key means "server decides".
    ///
    /// Carries no `previous_response_id` either: every request is stateless and
    /// self-contained (see `buildRequest`).
    struct NativeChatRequest: Encodable {
        var model: String
        var systemPrompt: String?
        var input: NativeChatInput
        var store: Bool
        var stream: Bool
        var temperature: Double?

        enum CodingKeys: String, CodingKey {
            case model, input, store, stream, temperature
            case systemPrompt = "system_prompt"
        }
    }

    // MARK: - SSE Event Types

    struct MessageDeltaEvent: Decodable {
        var content: String?
    }

    /// Terminal SSE frame. Only `stats` is read — `response_id` is deliberately
    /// ignored now that requests carry no chain to resume.
    struct ChatEndEvent: Decodable {
        var stats: Stats?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TopKeys.self)
            // Nested format: {"type":"chat.end","result":{"stats":...}}
            if let result = try container.decodeIfPresent(ResultPayload.self, forKey: .result) {
                stats = result.stats
            } else {
                // Flat format: {"stats":...} (per docs)
                stats = try container.decodeIfPresent(Stats.self, forKey: .stats)
            }
        }

        enum TopKeys: String, CodingKey {
            case result
            case stats
        }

        struct ResultPayload: Decodable {
            var stats: Stats?
            enum CodingKeys: String, CodingKey {
                case stats
            }
        }

        struct Stats: Decodable {
            var inputTokens: Int
            var outputTokens: Int
            /// Seconds the server spent LOADING the model for this request. Undocumented but
            /// present — `benchmark_prompt_processing.sh` reads it off a live server, where LM
            /// Studio returns exactly 0 on all 27 warm rows.
            ///
            /// A positive value is not by itself a reload: Ollama's counterpart reports ~22 ms of
            /// per-request bookkeeping on a resident model, and this field is decoded into the
            /// same provider-neutral `ServerPrefillReport.modelLoadMs`. The threshold that turns
            /// it into a verdict is `PrefixCachePolicy.minimumLoadMsForReload`, which needs no
            /// per-model calibration — unlike the prefill-rate branch beside it.
            var modelLoadTimeSeconds: Double?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // Handle both: docs format (tokens_in/tokens_out) and actual server (input_tokens/total_output_tokens)
                inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
                    ?? container.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
                outputTokens = try container.decodeIfPresent(Int.self, forKey: .totalOutputTokens)
                    ?? container.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
                modelLoadTimeSeconds = try container.decodeIfPresent(
                    Double.self, forKey: .modelLoadTimeSeconds)
            }

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case tokensIn = "tokens_in"
                case totalOutputTokens = "total_output_tokens"
                case tokensOut = "tokens_out"
                case modelLoadTimeSeconds = "model_load_time_seconds"
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
    /// restart, and by `modelContextLength` to size prompts to the model's
    /// context window. `id`/`state`/context-length fields are consumed;
    /// other fields decoded best-effort.
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
            /// The model's maximum supported context length (`max_context_length`).
            /// Present for both loaded and not-loaded entries. Best-effort optional.
            let maxContextLength: Int?
            /// The context length the model was actually loaded with
            /// (`loaded_context_length`) — can be SMALLER than `maxContextLength`
            /// when the user loads the model with a reduced window. Present ONLY
            /// on `state == "loaded"` entries. **Undocumented by LM Studio** —
            /// observed on a live server; decoded best-effort so its absence on
            /// older builds degrades to `maxContextLength`.
            let loadedContextLength: Int?
            /// Display metadata for the Model Details card — all best-effort
            /// optionals, absent on older builds.
            let arch: String?
            let quantization: String?
            let publisher: String?
            let compatibilityType: String?

            // Explicit keys: the wire decoder (`JSONCoderFactory.makeWireDecoder`)
            // has NO snake_case strategy, so the context-length keys must be
            // mapped by hand. `capabilities` is deliberately absent — in v0 it
            // is an array of strings (unlike v1's object with `.vision`), so
            // decoding it here would be wrong; it is simply not consumed.
            enum CodingKeys: String, CodingKey {
                case id
                case state
                case type
                case arch
                case quantization
                case publisher
                case maxContextLength = "max_context_length"
                case loadedContextLength = "loaded_context_length"
                case compatibilityType = "compatibility_type"
            }
        }
    }
}
