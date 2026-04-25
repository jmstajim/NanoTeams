import Foundation

/// `EmbeddingClient` implementation backed by LM Studio's OpenAI-compatible
/// `/v1/embeddings` endpoint.
///
/// Atomic per call (see protocol doc): one outbound HTTP request per
/// `embed(texts:config:)` invocation. Higher-level batching, retry, and
/// partial-failure bookkeeping live in `VocabVectorIndexBuilder`.
///
/// Error classification (see `EmbeddingClientError`):
/// - HTTP 404 + response body `{"error":{"message": "... model ... not found ..."}}`
///   → `.modelNotLoaded` — distinct from generic 404 so the UI can tell the
///   user to load the model instead of showing a generic error.
/// - `URLError.timedOut` → `.timeout`.
/// - `URLError.cancelled` → propagates `CancellationError` (not wrapped) so
///   the cooperative-cancellation tree unwinds cleanly instead of burning a
///   retry cycle inside the builder.
/// - Other non-2xx → `.httpError(status:message:)`.
/// - 2xx but unparseable / wrong item count → `.invalidResponse`.
/// - 2xx with inconsistent vector dims across items → `.dimensionMismatch`.
/// - Outbound encode failure → `.requestEncodingFailed` (programming bug).
///
/// `NetworkLogger` and `stepID` are passed per-call, not stored on the struct,
/// so `LMStudioEmbeddingClient` conforms to the `Sendable` constraint from
/// `EmbeddingClient` without a `@unchecked` escape hatch.
struct LMStudioEmbeddingClient: EmbeddingClient {

    let session: any NetworkSession

    init(session: any NetworkSession = URLSession.shared) {
        self.session = session
    }

    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
        try await embed(texts: texts, config: config, logger: nil, stepID: nil)
    }

    /// Overload that plumbs `NetworkLogger` / `stepID` per call. Callers who
    /// already have a logger in scope use this; everyone else uses the
    /// protocol-conformant `embed(texts:config:)`.
    func embed(
        texts: [String],
        config: EmbeddingConfig,
        logger: NetworkLogger?,
        stepID: String?
    ) async throws -> [[Float]] {
        // Empty input is not an error — return empty without a network call.
        // Callers sometimes hand us a zero-length batch during diff'ing.
        if texts.isEmpty { return [] }

        let url = try makeEndpointURL(config: config)
        let body = try encodeRequest(texts: texts, modelName: config.modelName)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.requestTimeout
        request.httpBody = body

        let requestRecord = NetworkLogger.createRequestRecord(
            url: url, method: "POST", body: body, stepID: stepID
        )
        logger?.append(requestRecord)

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.sessionData(for: request)
        } catch {
            let duration = Date().timeIntervalSince(started) * 1000
            // URLError.cancelled surfaces as CancellationError — let the
            // cooperative cancellation tree unwind instead of masquerading
            // as a retryable transport error.
            if (error as? URLError)?.code == .cancelled {
                logger?.append(NetworkLogger.createResponseRecord(
                    for: requestRecord, statusCode: 0, durationMs: duration,
                    body: nil, error: CancellationError()
                ))
                throw CancellationError()
            }
            let wrapped = Self.classifyTransportError(error)
            logger?.append(NetworkLogger.createResponseRecord(
                for: requestRecord,
                statusCode: 0,
                durationMs: duration,
                body: nil,
                error: wrapped
            ))
            throw wrapped
        }
        let durationMs = Date().timeIntervalSince(started) * 1000

        guard let http = response as? HTTPURLResponse else {
            let err = EmbeddingClientError.invalidResponse("Non-HTTP response")
            logger?.append(NetworkLogger.createResponseRecord(
                for: requestRecord, statusCode: 0, durationMs: durationMs,
                body: String(data: data, encoding: .utf8), error: err
            ))
            throw err
        }

        let bodyString = String(data: data, encoding: .utf8)
        logger?.append(NetworkLogger.createResponseRecord(
            for: requestRecord,
            statusCode: http.statusCode,
            durationMs: durationMs,
            body: bodyString,
            error: nil
        ))

        guard (200..<300).contains(http.statusCode) else {
            throw Self.classifyHTTPError(
                status: http.statusCode,
                data: data,
                modelName: config.modelName
            )
        }

        return try Self.decode(data: data, expectedCount: texts.count)
    }

    // MARK: - Encoding

    /// Builds the endpoint URL for a given base (e.g. `http://127.0.0.1:1234`)
    /// by appending `v1/embeddings`. Falls back to `throw` on a malformed base.
    private func makeEndpointURL(config: EmbeddingConfig) throws -> URL {
        guard let base = URL(string: config.baseURLString) else {
            throw EmbeddingClientError.transportError(
                "Invalid baseURL: \(config.baseURLString)"
            )
        }
        return base.appendingPathComponent("v1/embeddings", isDirectory: false)
    }

    private func encodeRequest(texts: [String], modelName: String) throws -> Data {
        let req = EmbeddingRequest(model: modelName, input: texts)
        let encoder = JSONCoderFactory.makeWireEncoder()
        do {
            return try encoder.encode(req)
        } catch {
            // Programming bug: `EmbeddingRequest` is plain Encodable of
            // String/[String]. If encoding ever fails in the wild, the
            // request never reached the server — distinct classification
            // from `.invalidResponse`.
            throw EmbeddingClientError.requestEncodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Response classification (static so they're testable without a full client)

    static func classifyTransportError(_ error: Error) -> EmbeddingClientError {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut:
                return .timeout
            case .cancelled:
                // This branch is reached only via the static helper (e.g.
                // from tests); the main `embed` method intercepts
                // URLError.cancelled first and throws CancellationError.
                // Classify conservatively as a transport error for the
                // static API so existing callers see a typed EmbeddingClientError.
                return .transportError("cancelled")
            case .cannotFindHost, .dnsLookupFailed:
                return .transportError(urlErr.localizedDescription)
            default:
                return .transportError(urlErr.localizedDescription)
            }
        }
        return .transportError(error.localizedDescription)
    }

    static func classifyHTTPError(
        status: Int,
        data: Data,
        modelName: String
    ) -> EmbeddingClientError {
        // Try to parse `{"error":{"message":"...","type":"..."}}`. LM Studio
        // mirrors the OpenAI error shape; if the body isn't parseable we fall
        // back to a generic `.httpError`.
        let decoder = JSONCoderFactory.makeWireDecoder()
        let errorBody = (try? decoder.decode(
            EmbeddingErrorResponse.self, from: data
        ))?.error

        let message = errorBody?.message ?? String(data: data, encoding: .utf8)

        // 404 + a message that mentions "model" / "not found" is the signal
        // that the named embedding model isn't loaded in LM Studio. Pattern is
        // conservative — if the string match fails we fall through to generic
        // `.httpError`, which still surfaces the right status code.
        if status == 404, let msg = message?.lowercased(),
           msg.contains("model") || msg.contains("not found") {
            return .modelNotLoaded(modelName)
        }

        return .httpError(status: status, message: message)
    }

    // MARK: - Decoding

    static func decode(data: Data, expectedCount: Int) throws -> [[Float]] {
        let decoder = JSONCoderFactory.makeWireDecoder()
        let resp: EmbeddingResponse
        do {
            resp = try decoder.decode(EmbeddingResponse.self, from: data)
        } catch {
            throw EmbeddingClientError.invalidResponse(
                "JSON decode failed: \(error.localizedDescription)"
            )
        }

        guard resp.data.count == expectedCount else {
            throw EmbeddingClientError.invalidResponse(
                "Response contains \(resp.data.count) items, expected \(expectedCount)"
            )
        }

        // Sort by `index` so caller gets vectors in the same order as the
        // input `texts` regardless of any server-side reordering.
        let sorted = resp.data.sorted { $0.index < $1.index }

        // Validate dim consistency across items. First item's length defines
        // the expected dim — subsequent mismatches throw `.dimensionMismatch`.
        guard let firstDim = sorted.first?.embedding.count else {
            throw EmbeddingClientError.invalidResponse("Empty response data")
        }
        for item in sorted where item.embedding.count != firstDim {
            throw EmbeddingClientError.dimensionMismatch(
                expected: firstDim, got: item.embedding.count
            )
        }

        return sorted.map(\.embedding)
    }
}

// MARK: - Wire types

/// Outgoing request body. LM Studio accepts either a string or an array of
/// strings for `input`; we always send an array for consistent response
/// shape (`data: [Item]` even for single-text calls).
private struct EmbeddingRequest: Encodable {
    let model: String
    let input: [String]
}

/// Incoming response body. `data` length matches `input` length; `index`
/// preserves per-item ordering even if the server processes in parallel.
struct EmbeddingResponse: Decodable, Equatable {
    let data: [Item]

    struct Item: Decodable, Equatable {
        let embedding: [Float]
        let index: Int
    }
}

/// Shape LM Studio uses for non-2xx responses — mirrors OpenAI. `type` is
/// sometimes absent depending on which code path inside LM Studio emitted the
/// error, so it's optional.
struct EmbeddingErrorResponse: Decodable {
    let error: Body

    struct Body: Decodable {
        let message: String
        let type: String?
    }
}
