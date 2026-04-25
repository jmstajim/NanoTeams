import Foundation

/// DIP abstraction over an OpenAI-compatible `/v1/embeddings` endpoint.
///
/// Intentionally separate from `LLMClient` (chat): different endpoint, different
/// response shape, different failure modes (dim mismatch, model-not-loaded).
///
/// Atomic per call — one HTTP request per `embed(texts:config:)`. Higher-level
/// batching (slicing a large vocab into `config.batchSize` chunks) and retry
/// policy live in the caller (`VocabVectorIndexBuilder`). This keeps the client
/// testable with a single mock response and preserves the "one call = one
/// network record" observability invariant.
protocol EmbeddingClient: Sendable {

    /// Returns one vector per input text, in the same order as `texts`.
    /// Throws `EmbeddingClientError` on any failure — on partial decode, the
    /// whole call is rejected so the caller doesn't silently ship half-a-batch.
    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]]
}

// MARK: - Config

/// Configuration for an embedding endpoint. Lives in `StoreConfiguration` as
/// `expandedSearchEmbeddingConfig` and is produced at call-time via the
/// coordinator's `embeddingConfigProvider` closure so config changes (model
/// swap, URL change) take effect on the next rebuild without tearing down
/// the coordinator.
///
/// Invariants (enforced by init; programmer errors crash, user input that
/// violates them surfaces as a Codable decode failure):
/// - `baseURLString` parses as a `URL`.
/// - `modelName` is non-empty.
/// - `batchSize > 0`.
/// - `requestTimeout > 0`.
struct EmbeddingConfig: Sendable, Codable, Equatable {

    /// Base URL of the OpenAI-compatible server. No trailing slash required.
    /// Example: `http://127.0.0.1:1234`.
    let baseURLString: String

    /// Model id as registered with the server. For LM Studio shipping nomic
    /// by default: `text-embedding-nomic-embed-text-v1.5`.
    let modelName: String

    /// Texts per outbound HTTP call at the builder level. 64 is a reasonable
    /// default for nomic on Apple Silicon — enough to amortize HTTP overhead,
    /// small enough to keep a single batch under a few seconds so cancellation
    /// is responsive.
    let batchSize: Int

    /// Per-request timeout in seconds. Applied via `URLRequest.timeoutInterval`.
    let requestTimeout: TimeInterval

    /// Precondition-based init — constructing an invalid config inside the
    /// app is a programmer error (crash in debug). User-supplied configs
    /// from UI / disk go through `init?(validating:...)` / Codable decoding
    /// which surface the failure instead.
    init(
        baseURLString: String,
        modelName: String,
        batchSize: Int = 64,
        requestTimeout: TimeInterval = 60
    ) {
        precondition(URL(string: baseURLString) != nil,
                     "EmbeddingConfig.baseURLString must parse as URL: \(baseURLString)")
        precondition(!modelName.isEmpty, "EmbeddingConfig.modelName must be non-empty")
        precondition(batchSize > 0, "EmbeddingConfig.batchSize must be > 0, got \(batchSize)")
        precondition(requestTimeout > 0,
                     "EmbeddingConfig.requestTimeout must be > 0, got \(requestTimeout)")
        self.baseURLString = baseURLString
        self.modelName = modelName
        self.batchSize = batchSize
        self.requestTimeout = requestTimeout
    }

    /// Failable init for untrusted input (UI fields, persisted overrides).
    /// Returns `nil` on any invariant violation. Callers fall back to
    /// `defaultNomicLMStudio`.
    init?(validating baseURLString: String,
          modelName: String,
          batchSize: Int = 64,
          requestTimeout: TimeInterval = 60) {
        guard URL(string: baseURLString) != nil,
              !modelName.isEmpty,
              batchSize > 0,
              requestTimeout > 0 else { return nil }
        self.baseURLString = baseURLString
        self.modelName = modelName
        self.batchSize = batchSize
        self.requestTimeout = requestTimeout
    }

    // Codable: decode raw fields, then re-run validation. A corrupted persisted
    // config surfaces as a decode failure and `StoreConfiguration` falls back
    // to `defaultNomicLMStudio`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let baseURLString = try c.decode(String.self, forKey: .baseURLString)
        let modelName = try c.decode(String.self, forKey: .modelName)
        let batchSize = try c.decode(Int.self, forKey: .batchSize)
        let requestTimeout = try c.decode(TimeInterval.self, forKey: .requestTimeout)
        guard let valid = EmbeddingConfig(
            validating: baseURLString,
            modelName: modelName,
            batchSize: batchSize,
            requestTimeout: requestTimeout
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .baseURLString, in: c,
                debugDescription: "EmbeddingConfig failed validation"
            )
        }
        self = valid
    }

    enum CodingKeys: String, CodingKey {
        case baseURLString, modelName, batchSize, requestTimeout
    }

    /// Default config wired to LM Studio's default port + the nomic embedding
    /// model shipped out-of-the-box. Used when the user has not explicitly
    /// configured anything.
    static let defaultNomicLMStudio = EmbeddingConfig(
        baseURLString: "http://127.0.0.1:1234",
        modelName: "text-embedding-nomic-embed-text-v1.5"
    )

    // MARK: - Per-model prompting convention

    /// Prefix prepended to every DOCUMENT (vocab token) before embedding.
    /// Different models were trained with different retrieval prompts —
    /// mismatched prefixes silently degrade recall (the model treats the
    /// raw token as a query-style input and lands in a different region of
    /// the embedding space). Looked up by substring of `modelName` so
    /// `text-embedding-nomic-...` and `nomic-ai/nomic-embed-text-v1.5`
    /// both resolve correctly.
    var documentPrefix: String { Self.prefixes(for: modelName).document }

    /// Prefix prepended to every QUERY before embedding (whole-phrase tier
    /// in `VocabVectorIndexService.expand`). Per-token expansion uses the
    /// document-prefixed vector that's already in the vocab, so no query
    /// prefix is needed there.
    var queryPrefix: String { Self.prefixes(for: modelName).query }

    private static func prefixes(for modelName: String) -> (document: String, query: String) {
        let lower = modelName.lowercased()
        if lower.contains("nomic-embed") {
            return ("search_document: ", "search_query: ")
        }
        if lower.contains("mxbai-embed") {
            // Mixedbread mxbai-embed — query-only prompt, no document prefix.
            // Source: https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1
            return ("", "Represent this sentence for searching relevant passages: ")
        }
        if lower.contains("multilingual-e5") || lower.hasPrefix("e5-") || lower.contains("/e5-") {
            // intfloat/e5-* family — symmetric "query: " / "passage: ".
            return ("passage: ", "query: ")
        }
        if lower.contains("bge-m3") || lower.contains("bge-large") || lower.contains("bge-base") {
            // BAAI bge-* — no prefixes.
            return ("", "")
        }
        if lower.contains("granite-embedding") {
            // IBM granite-embedding-* — symmetric sentence-transformer,
            // multilingual variants included. No prompt template.
            return ("", "")
        }
        // Unknown model: assume nomic-style. Safe default for LM Studio
        // since nomic-embed-text-v1.5 is the most common preset.
        return ("search_document: ", "search_query: ")
    }
}

// MARK: - Errors

/// Classification of every failure the embedding endpoint can surface. The
/// caller (`VocabVectorIndexService`) switches on this to decide whether to
/// retry, mark the vector index as `modelUnavailable`, or surface a generic
/// error. Keep the case set small and meaningful — adding a catch-all here
/// erodes the classification the UI depends on.
enum EmbeddingClientError: LocalizedError, Equatable {

    /// Server-side response was not usable: non-JSON body, missing `data`
    /// array, or `data.count != texts.count`. Unlike `requestEncodingFailed`,
    /// this means the server saw the request but returned something garbled.
    case invalidResponse(String)

    /// Failed to serialize the outbound request body (programming bug —
    /// never observed in production; kept distinct from `.invalidResponse`
    /// so classification stays accurate). Terminal — retrying won't help.
    case requestEncodingFailed(String)

    /// The server returned vectors whose length disagrees with what we expected.
    /// For nomic v1.5 we expect 768. If the server was reconfigured to a
    /// different embedding model under the same name, this is how we notice.
    /// Terminal — retrying will get the same mismatched response.
    case dimensionMismatch(expected: Int, got: Int)

    /// HTTP 404 with a `model`/`not found` message. Distinct from generic 404
    /// because the UI surfaces this as "load the model in LM Studio".
    /// Terminal — the model needs human action to load.
    case modelNotLoaded(String)

    /// `URLError.timedOut` or equivalent transport timeout.
    case timeout

    /// Any non-2xx that didn't classify as `modelNotLoaded` or `dimensionMismatch`.
    case httpError(status: Int, message: String?)

    /// Underlying `URLSession` failure (connection refused, DNS, TLS).
    case transportError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail):
            return "Embedding response was not usable: \(detail.prefix(160))"
        case .requestEncodingFailed(let detail):
            return "Failed to encode embedding request: \(detail.prefix(160))"
        case .dimensionMismatch(let expected, let got):
            return "Embedding dimensions mismatch (expected \(expected), got \(got)). Model likely changed."
        case .modelNotLoaded(let name):
            return "Embedding model '\(name)' is not loaded in LM Studio."
        case .timeout:
            return "Embedding request timed out."
        case .httpError(let status, let message):
            if let message, !message.isEmpty {
                return "Embedding HTTP \(status): \(message.prefix(160))"
            }
            return "Embedding HTTP \(status)."
        case .transportError(let detail):
            return "Embedding transport error: \(detail.prefix(160))"
        }
    }

    /// Canonical string used as `expansion_error` reason in the `expand`
    /// envelope surfaced to the chat LLM. Keep this set pinned — the LLM-side
    /// handling depends on the exact strings.
    var envelopeReason: String {
        switch self {
        case .modelNotLoaded: return "embedding_model_not_loaded"
        case .timeout: return "embedding_timeout"
        case .dimensionMismatch: return "embedding_dimension_mismatch"
        case .httpError: return "embedding_http_error"
        case .invalidResponse: return "embedding_invalid_response"
        case .requestEncodingFailed: return "embedding_request_encoding_failed"
        case .transportError: return "embedding_transport_error"
        }
    }

    /// `true` when retrying the call will never succeed without outside
    /// intervention (model load, config change, bug fix). The builder uses
    /// this to short-circuit the retry loop: without it, `.modelNotLoaded`
    /// burns ~2.5s per batch × hundreds of batches before the build finishes
    /// with every token in `failedTokens` — and the service's
    /// `.modelUnavailable` routing becomes dead code.
    var isTerminal: Bool {
        switch self {
        case .modelNotLoaded, .dimensionMismatch, .requestEncodingFailed:
            return true
        case .invalidResponse, .timeout, .httpError, .transportError:
            return false
        }
    }
}
