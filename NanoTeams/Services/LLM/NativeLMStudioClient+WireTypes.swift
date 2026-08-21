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
        /// Hard ceiling on generated tokens. Absent for every role step — only the benchmark
        /// sets it (`LLMConfig.maxOutputTokens`).
        ///
        /// **`max_output_tokens` is the only spelling this endpoint accepts, and the name was
        /// MEASURED, not assumed** (2026-08-19, LM Studio 0.4.21): `max_tokens`,
        /// `max_completion_tokens`, `maxTokens`, `max_predicted_tokens` and `num_predict` are
        /// each rejected with `{"code":"unrecognized_keys"}` and HTTP 400. Note this endpoint is
        /// STRICT about unknown keys where the rest of the surface is not — the same server
        /// answers 200 with an error body on an unknown PATH. A wrong name here therefore fails
        /// loudly rather than silently omitting the cap, which is why the pin below asserts the
        /// encoded bytes.
        ///
        /// The sibling `/api/v0/chat/completions` uses `max_tokens` instead
        /// (`LMStudioServerProvenanceProbe`), so the two endpoints genuinely disagree; neither
        /// name can be copied across.
        var maxOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, input, store, stream, temperature
            case systemPrompt = "system_prompt"
            case maxOutputTokens = "max_output_tokens"
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

        /// Every field here is telemetry, and every one decodes LENIENTLY.
        ///
        /// `decodeIfPresent` returns nil for an ABSENT key but THROWS on a type mismatch (#83),
        /// and `SSEEventParser` decodes this whole frame under a single `try?` — so one strict
        /// field lets one mistyped number discard the terminal frame entire: both token counts,
        /// the prefill report, and the prompt-prefix cache signal riding inside it. The Ollama
        /// twin (`OllamaClient.ChatChunk.init(from:)`) draws exactly this line; this side was
        /// left strict until 2026-08-19, which is #51 in one file.
        struct Stats: Decodable {
            /// Prompt tokens the server counted — `nil` when it counted none, NOT `0`.
            ///
            /// Optional on purpose: nil is the only way to say "the server sent no counts", and
            /// a fabricated zero is indistinguishable from a measured one. Downstream,
            /// `GenerationSampleRecorder` raises `.noTokensReported` only when usage is absent,
            /// so a fabricated zero turns a benchmark run that measured nothing into a finished
            /// run of dashes.
            var inputTokens: Int?
            var outputTokens: Int?
            /// How much of `outputTokens` the server attributes to reasoning. Measured 214 of
            /// 232 on one qwen3.8-4b turn — which is what makes a perfectly healthy rate read as
            /// slow to someone counting only the visible answer.
            var reasoningOutputTokens: Int?
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
            /// Tokens per second the server measured over its own DECODE window, verbatim.
            ///
            /// Measured against LM Studio 0.4.21 on 2026-08-19: this equals
            /// `completion_tokens / (generation_time − time_to_first_token)` to 0.00 % across
            /// 16/32/64/128/256-token completions. Decode only, and the numerator is NOT
            /// fence-post corrected — byte-for-byte the convention of Ollama's
            /// `eval_count / eval_duration` and of `BenchmarkMetricsPolicy.serverRate`, so the
            /// two providers' figures land in one column without mixing units.
            var tokensPerSecond: Double?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // Both spellings: the docs say tokens_in/tokens_out, the server sends
                // input_tokens/total_output_tokens.
                inputTokens = Self.int(c, .inputTokens) ?? Self.int(c, .tokensIn)
                outputTokens = Self.int(c, .totalOutputTokens) ?? Self.int(c, .tokensOut)
                reasoningOutputTokens = Self.int(c, .reasoningOutputTokens)
                modelLoadTimeSeconds = Self.double(c, .modelLoadTimeSeconds)
                tokensPerSecond = Self.double(c, .tokensPerSecond)
            }

            /// `try?` over a `T?` expression yields `T??`; the trailing `?? nil` flattens it.
            /// Both halves are load-bearing — dropping either turns a mismatch back into a throw.
            private static func int(
                _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
            ) -> Int? {
                (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil
            }

            private static func double(
                _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
            ) -> Double? {
                (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil
            }

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case tokensIn = "tokens_in"
                case totalOutputTokens = "total_output_tokens"
                case tokensOut = "tokens_out"
                case reasoningOutputTokens = "reasoning_output_tokens"
                case modelLoadTimeSeconds = "model_load_time_seconds"
                case tokensPerSecond = "tokens_per_second"
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
            /// The model's runtime/file format — `"gguf"` / `"mlx"`. The same fact `/api/v0/models`
            /// spells `compatibility_type`, and the same VALUES, so a format read here and one read
            /// there are comparable without a mapping table.
            let format: String?
            /// `{ "name": "4bit", "bits_per_weight": 4 }` on current builds, a bare string on
            /// older ones. See `Quantization`.
            let quantization: Quantization?

            // Explicit keys for the same reason `V0ModelListResponse.Entry` spells its own out:
            // `JSONCoderFactory.makeWireDecoder()` is a bare `JSONDecoder` with NO snake_case
            // strategy. These four happen to be snake-free, and listing them is what keeps that
            // from being luck.
            enum CodingKeys: String, CodingKey {
                case key, type, capabilities, format, quantization
            }

            /// `key` / `type` / `capabilities` decode exactly as the synthesized initializer did —
            /// they are load-bearing, and a malformed one should still fail over to the
            /// OpenAI-compatible shape.
            ///
            /// `format` and `quantization` are decoration and are decoded with `try?` ON THE FIELD,
            /// because the failure they would otherwise cause is out of all proportion to what they
            /// are worth: `decodeIfPresent` THROWS on a type mismatch rather than returning nil
            /// (CLAUDE.md #83), one throw fails the whole `NativeModelListResponse`, and the
            /// caller's `catch` drops onto the OpenAI-compatible branch — which carries no `type`,
            /// so an unexpected quantization shape on one model would stop every LLM picker in the
            /// app from filtering out embedders.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                key = try container.decode(String.self, forKey: .key)
                type = try container.decodeIfPresent(String.self, forKey: .type)
                capabilities = try container.decodeIfPresent(
                    ModelCapabilities.self, forKey: .capabilities)
                format = (try? container.decodeIfPresent(String.self, forKey: .format)) ?? nil
                quantization =
                    (try? container.decodeIfPresent(Quantization.self, forKey: .quantization)) ?? nil
            }
        }

        /// Two observed spellings of one fact, so both are accepted here rather than at every
        /// reader: current LM Studio sends an object (`{ "name": "Q4_K_M", "bits_per_weight": 4 }`),
        /// and the sibling `/api/v0/models` route sends a bare string. Only the name is consumed —
        /// `bits_per_weight` is derivable from it and nothing renders it.
        struct Quantization: Decodable {
            let name: String?

            init(from decoder: Decoder) throws {
                if let bare = try? decoder.singleValueContainer().decode(String.self) {
                    name = bare
                    return
                }
                name = try decoder.container(keyedBy: CodingKeys.self)
                    .decodeIfPresent(String.self, forKey: .name)
            }

            enum CodingKeys: String, CodingKey { case name }
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
