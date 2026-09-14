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
        /// The native tool catalog — `.native` mode only. Ollama renders it into the model's
        /// own chat template and, when the model answers in its own call syntax, parses the
        /// reply into `message.tool_calls`. Absent (not `[]`) under `.promptTaught`: sending an
        /// empty array is still "tools were declared" to some templates.
        var tools: [NativeToolDeclaration]?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, options, tools
            case keepAlive = "keep_alive"
        }

        init(
            model: String,
            messages: [ChatRequestMessage],
            stream: Bool,
            options: Options?,
            keepAlive: Int?,
            tools: [NativeToolDeclaration]? = nil
        ) {
            self.model = model
            self.messages = messages
            self.stream = stream
            self.options = options
            self.keepAlive = keepAlive
            self.tools = tools
        }

        struct Options: Encodable {
            var temperature: Double?
            /// Hard ceiling on generated tokens. Absent for every role step; only the benchmark
            /// sets it (`LLMConfig.maxOutputTokens`).
            ///
            /// The name is corroborated by this project's own shell harness, which has been
            /// posting `options.num_predict` to this same `/api/chat` endpoint since it was
            /// written (`benchmark_prompt_processing.sh:214`, with `CAP_TOK=8` at :53) and reads
            /// `prompt_eval_*` back off the capped runs — so the terminal statistics survive a
            /// ceiling here, which is the property the whole measurement depends on.
            ///
            /// Still weaker evidence than its LM Studio counterpart, which was measured against a
            /// live server key by key. The asymmetry is worth knowing because the two servers
            /// disagree about a wrong name: `/api/v1/chat` answers HTTP 400
            /// `unrecognized_keys`, while Ollama silently ignores an option it does not know. A
            /// silent miss is caught downstream — `BenchmarkProvenance.outputCapField` reads the
            /// recorded token counts back and reports a ceiling that did not hold.
            var numPredict: Int?

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }
    }

    /// One message in the `/api/chat` `messages` array. `images` carries raw
    /// base64 payloads (no `data:` URI prefix — Ollama's format, unlike the
    /// LM Studio `data_url` parts).
    struct ChatRequestMessage: Encodable, Equatable {
        var role: String
        var content: String
        var images: [String]?
        /// `.native` assistant turns: the calls the model made, as the OBJECTS Ollama expects
        /// (`arguments` is structure here, not a string). Absent under `.promptTaught`, where
        /// the same calls ride `content` as Harmony text.
        var toolCalls: [ToolCallEntry]?
        /// `.native` tool turns: which tool this result answers. Optional on the wire too —
        /// Ollama accepts a bare `tool` message — and derived positionally when the app's
        /// own `.tool` message carries no id (`NativeToolTurnPairing`).
        var toolName: String?
        /// `.native` assistant turns: the reasoning the model generated on that turn, verbatim,
        /// in the message field Ollama's API documents for thinking models — the renderer's own
        /// gate decides whether the model sees it again. Absent (no key) when the turn had none,
        /// and absent under `.promptTaught`, where the turn is Harmony text with no slot for it.
        var thinking: String?

        enum CodingKeys: String, CodingKey {
            case role, content, images, thinking
            case toolCalls = "tool_calls"
            case toolName = "tool_name"
        }

        init(
            role: String,
            content: String,
            images: [String]? = nil,
            toolCalls: [ToolCallEntry]? = nil,
            toolName: String? = nil,
            thinking: String? = nil
        ) {
            self.role = role
            self.content = content
            self.images = images
            self.toolCalls = toolCalls
            self.toolName = toolName
            self.thinking = thinking
        }
    }

    /// One call on a replayed assistant turn: `{"function":{"index":0,"name":…,"arguments":{…}}}`.
    ///
    /// `arguments` is re-parsed from the call's `argumentsJSON`; a string that is not a JSON
    /// object becomes `{}` — the same fallback `HarmonyToolCallEnvelope` applies to an empty
    /// value, because a replayed turn must be a well-formed call or the whole request is refused.
    struct ToolCallEntry: Encodable, Equatable {
        struct Function: Encodable, Equatable {
            var index: Int
            var name: String
            var arguments: JSONValue
        }
        var function: Function

        init(index: Int, call: ChatToolCall) {
            let parsed = JSONValue(json: call.argumentsJSON)
            function = Function(
                index: index, name: call.name,
                arguments: parsed?.isObject == true ? parsed! : .object([:]))
        }
    }

    // MARK: - Chat Stream Chunk (one NDJSON line)

    struct ChatChunk: Decodable {
        struct Message: Decodable {
            var content: String?
            var thinking: String?
            /// Native calls, whole — Ollama emits each call complete, not as deltas, on one
            /// chunk (its own, or the terminal `done:true` one; both placements are measured
            /// on 2026-09-13 and both are pinned).
            ///
            /// Decoded LENIENTLY, like the telemetry: `content` and `thinking` stay strict so a
            /// malformed one costs the chunk rather than silently dropping text, but a call
            /// the server could not spell (an `arguments` that is not an object, a missing
            /// `function`) must not take the content and the terminal counts down with it.
            var toolCalls: [ToolCallChunk]?

            enum CodingKeys: String, CodingKey {
                case content, thinking
                case toolCalls = "tool_calls"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content = try c.decodeIfPresent(String.self, forKey: .content)
                thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
                toolCalls = (try? c.decodeIfPresent([ToolCallChunk].self, forKey: .toolCalls)) ?? nil
            }
        }

        /// `{"id":"call_…","function":{"index":0,"name":"read_file","arguments":{…}}}`. The id is
        /// `call_xxxxxxxx` from Ollama's own renderers and a 32-character token from a
        /// llama-server model; `index` is present on the renderer path and absent on the other.
        struct ToolCallChunk: Decodable {
            struct Function: Decodable {
                var index: Int?
                var name: String
                var arguments: JSONValue?
            }
            var id: String?
            var function: Function
        }

        var message: Message?
        var done: Bool?
        var promptEvalCount: Int?
        /// How many of `prompt_eval_count` the server served from its KV cache — the direct
        /// answer to "did the prefix hold", where `prompt_eval_duration` is only the indirect
        /// one. Reported by Ollama ≥ 0.12 on every terminal chunk; absent on older builds.
        var promptEvalCachedCount: Int?
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
        /// Nanoseconds Ollama spent DECODING — the window the `eval_count` tokens were produced
        /// in, and the counterpart of `promptEvalDurationNs` on the other side of the first token.
        /// `eval_count / eval_duration` is a tokens-per-second figure with no client clock in it,
        /// so it carries neither queue time nor transport jitter.
        ///
        /// The only generation WINDOW either provider reports — but not the only generation fact:
        /// LM Studio states the same thing as a finished rate (`stats.tokens_per_second`), which
        /// this codebase kept discarding until 2026-08-19. Measured that day, its rate is
        /// `completion_tokens / (generation_time − TTFT)`, i.e. this exact convention, which is
        /// why `BenchmarkMetricsPolicy.generationRate` may put the two in one column.
        ///
        /// Not routed into `ServerPrefillReport`: that type is about what happened BEFORE the
        /// first token, and its `isEmpty` (which counts only `modelLoadMs` and `prefillNs`) would
        /// silently discard a report carrying nothing but this.
        var evalDurationNs: Double?
        /// Nanoseconds Ollama says the WHOLE request took, its own clock, end to end. The benchmark
        /// times the same span itself, so this is a second opinion on a number that otherwise has
        /// none — and the gap between them is transport and scheduling, which is exactly what a
        /// reader wondering "is it the model or my machine" needs to see.
        var totalDurationNs: Double?
        /// Why generation stopped: `"stop"` when the model finished, `"length"` when it hit the
        /// requested ceiling. The benchmark asks for a fixed 512-token cap, and until this was
        /// decoded nothing could say whether a run had been cut off at it — `outputCapField` could
        /// only catch the opposite case, a server returning MORE than it was asked for, by reading
        /// the token counts back.
        var doneReason: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case message, done, error
            case promptEvalCount = "prompt_eval_count"
            case promptEvalCachedCount = "prompt_eval_cached_count"
            case evalCount = "eval_count"
            case promptEvalDurationNs = "prompt_eval_duration"
            case loadDurationNs = "load_duration"
            case evalDurationNs = "eval_duration"
            case totalDurationNs = "total_duration"
            case doneReason = "done_reason"
        }

        /// Decodes the DIAGNOSTIC numbers leniently, and the content strictly.
        ///
        /// `Optional` is not enough on its own, which is the trap this initializer exists for:
        /// `decodeIfPresent` returns nil only for an ABSENT or null key — on a type mismatch it
        /// THROWS. And `OllamaChatStreamParser.parse` does one `try? decode(ChatChunk.self)` per
        /// line and returns `[]` on any failure, so a single mistyped telemetry field would
        /// discard the ENTIRE terminal chunk: `eval_count`, `prompt_eval_count`,
        /// `prompt_eval_duration`, `done` — taking the prompt-prefix cache signal with it, for a
        /// number nothing routes on. Measured: a `"eval_duration":"fast"` chunk decoded to
        /// nothing at all before this.
        ///
        /// The cut is deliberate. `message` / `done` / `error` stay strict: they carry the
        /// response and the terminal signal, and silently reading a malformed one as nil would
        /// drop content rather than a diagnostic. Everything below is telemetry, and telemetry
        /// must never cost content.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = try c.decodeIfPresent(Message.self, forKey: .message)
            done = try c.decodeIfPresent(Bool.self, forKey: .done)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            promptEvalCount = (try? c.decodeIfPresent(Int.self, forKey: .promptEvalCount)) ?? nil
            promptEvalCachedCount =
                (try? c.decodeIfPresent(Int.self, forKey: .promptEvalCachedCount)) ?? nil
            evalCount = (try? c.decodeIfPresent(Int.self, forKey: .evalCount)) ?? nil
            promptEvalDurationNs =
                (try? c.decodeIfPresent(Double.self, forKey: .promptEvalDurationNs)) ?? nil
            loadDurationNs = (try? c.decodeIfPresent(Double.self, forKey: .loadDurationNs)) ?? nil
            evalDurationNs = (try? c.decodeIfPresent(Double.self, forKey: .evalDurationNs)) ?? nil
            totalDurationNs = (try? c.decodeIfPresent(Double.self, forKey: .totalDurationNs)) ?? nil
            // Lenient like every other diagnostic here, and `done_reason` being a String rather
            // than a number changes nothing about that: `error` above is strict because it carries
            // the failure, this one carries telemetry, and telemetry must never cost content.
            doneReason = (try? c.decodeIfPresent(String.self, forKey: .doneReason)) ?? nil
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

    // Server-version decoding moved to `OllamaServerProvenanceProbe` with the request that uses
    // it: it describes the server process, not a model, and this file is the model wire.

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
