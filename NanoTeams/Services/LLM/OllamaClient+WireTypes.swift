import Foundation

/// Wire types for OllamaClient: request/response serialization structs for the
/// Ollama native API (`/api/chat`, `/api/tags`, `/api/show`).
nonisolated extension OllamaClient {

    // MARK: - Chat Request

    /// `POST /api/chat` body. Deliberately carries NO sampling keys beyond the
    /// optional `options.temperature` (internal-only: the security-judge
    /// verdict pin) — an omitted key means "the server / modelfile decides",
    /// the same policy the LM Studio client follows.
    ///
    /// `keep_alive` IS sent (when configured). Ollama still owns eviction
    /// (`LLMProvider.managesModelResidency == false` — the app never loads or unloads
    /// its models), but its 5-minute idle default drops the KV prefix cache during a
    /// human's `ask_supervisor` round-trip, which is exactly when a replayed
    /// conversation needs that cache warm. Residency policy and cache warmth are
    /// different concerns; deferring the first does not require forfeiting the second.
    struct ChatRequest: Encodable {
        var model: String
        var messages: [ChatRequestMessage]
        var stream: Bool
        var options: Options?
        /// Seconds. Sent on EVERY request — Ollama restarts the idle timer per call.
        var keepAlive: Int?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, options
            case keepAlive = "keep_alive"
        }

        struct Options: Encodable {
            var temperature: Double?
        }
    }

    /// One message in the `/api/chat` `messages` array. `images` carries raw
    /// base64 payloads (no `data:` URI prefix — Ollama's format, unlike the
    /// LM Studio `data_url` parts).
    struct ChatRequestMessage: Encodable, Equatable {
        var role: String
        var content: String
        var images: [String]?
    }

    // MARK: - Chat Stream Chunk (one NDJSON line)

    struct ChatChunk: Decodable {
        struct Message: Decodable {
            var content: String?
            var thinking: String?
        }

        var message: Message?
        var done: Bool?
        var promptEvalCount: Int?
        var evalCount: Int?
        /// Nanoseconds spent PREFILLING the prompt. Server-measured and decode-excluded, which
        /// makes `prompt_eval_duration / prompt_eval_count` the cleanest cache-hit signal either
        /// provider offers: `bench_baseline` measured ~0.45 ms/token cold against ~0.027 ms/token
        /// warm on the same prompt depth. (LM Studio's `time_to_first_token_seconds` is NOT the
        /// equivalent — it includes queue time, and this app streams parallel roles against one
        /// model as its normal mode.)
        var promptEvalDurationNs: Double?
        /// Nanoseconds Ollama says it spent loading the model — reported on EVERY request, the
        /// model already being resident included, so this is NOT a reload flag. Measured in
        /// `bench_baseline`: 20.6-25.1 ms on all 26 warm rows against 2236.6 ms for the one real
        /// load. Decoded verbatim; `PrefixCachePolicy.minimumLoadMsForReload` owns the threshold.
        var loadDurationNs: Double?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case message, done, error
            case promptEvalCount = "prompt_eval_count"
            case evalCount = "eval_count"
            case promptEvalDurationNs = "prompt_eval_duration"
            case loadDurationNs = "load_duration"
        }
    }

    // MARK: - Model Listing (`/api/tags`)

    /// `{ "models": [{ "name": "llama3.1:8b", … }] }` — tags carry NO
    /// capability metadata; capability filters go through `/api/show`.
    ///
    /// `size` / `modifiedAt` / `details` are decoded for the Downloaded Models
    /// card (`OllamaDownloadedModelStore`), which needs on-disk size to make a
    /// "free up space" decision meaningful. All optional: `fetchTagNames` only
    /// ever reads `name`, so an older build omitting them still decodes.
    struct TagsResponse: Decodable {
        struct Details: Decodable {
            var format: String?
            var parameterSize: String?
            var quantizationLevel: String?

            enum CodingKeys: String, CodingKey {
                case format
                case parameterSize = "parameter_size"
                case quantizationLevel = "quantization_level"
            }
        }

        struct ModelEntry: Decodable {
            var name: String
            /// Bytes on disk, as the server reports them.
            var size: Int64?
            var modifiedAt: String?
            var details: Details?

            enum CodingKeys: String, CodingKey {
                case name, size, details
                case modifiedAt = "modified_at"
            }
        }
        var models: [ModelEntry]
    }

    // MARK: - Running Models (`/api/ps`)

    /// `GET /api/ps` — models currently resident. Used by the Model Details
    /// card for loaded-state / VRAM / keep-alive expiry. Sizes are bytes.
    struct PSResponse: Decodable {
        struct Entry: Decodable {
            var name: String?
            var model: String?
            var sizeVram: Int64?
            var expiresAt: String?
            /// The window this instance is ACTUALLY loaded with (the CONTEXT column of
            /// `ollama ps`) — it already reflects `OLLAMA_CONTEXT_LENGTH`, a per-request
            /// `num_ctx`, and the runner's own clamping, so it is strictly better than
            /// the modelfile's declared `num_ctx`. Optional: older Ollama builds omit it,
            /// and an absent value must fall through rather than assert a window.
            var contextLength: Int?

            enum CodingKeys: String, CodingKey {
                case name, model
                case sizeVram = "size_vram"
                case expiresAt = "expires_at"
                case contextLength = "context_length"
            }
        }
        var models: [Entry]
    }

    // MARK: - Model Metadata (`/api/show`)

    /// `POST /api/show` body. `name` is the legacy alias older Ollama builds
    /// read; sending both keys is accepted by every version.
    struct ShowRequest: Encodable {
        var model: String
        var name: String

        init(model: String) {
            self.model = model
            self.name = model
        }
    }
}
