import XCTest

@testable import NanoTeams

final class LMStudioEmbeddingClientTests: XCTestCase {

    // MARK: - Mocks

    private final class MockNetworkSession: NetworkSession, @unchecked Sendable {
        var capturedURL: URL?
        var capturedBody: Data?
        var statusCode: Int = 200
        var responseBody: Data = Data()
        var errorToThrow: Error?

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedURL = request.url
            capturedBody = request.httpBody
            if let errorToThrow { throw errorToThrow }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (responseBody, response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("Not used in these tests")
        }
    }

    // MARK: - Fixtures

    private let config = EmbeddingConfig(
        baseURLString: "http://127.0.0.1:1234",
        modelName: "text-embedding-nomic-embed-text-v1.5",
        batchSize: 64,
        requestTimeout: 10
    )

    /// Builds a JSON response body matching LM Studio's `/v1/embeddings` shape.
    /// Vectors go in the order declared; `index` field preserves original order.
    private func makeResponseBody(
        _ items: [(index: Int, embedding: [Float])]
    ) -> Data {
        let pairs = items.map { item in
            "{\"embedding\":\(item.embedding),\"index\":\(item.index)}"
        }.joined(separator: ",")
        return Data("{\"data\":[\(pairs)]}".utf8)
    }

    // MARK: - Happy path

    func testEmbed_returnsVectorsInOrder_whenServerReturnsInOrder() async throws {
        let mock = MockNetworkSession()
        mock.responseBody = makeResponseBody([
            (0, [0.1, 0.2, 0.3]),
            (1, [0.4, 0.5, 0.6]),
            (2, [0.7, 0.8, 0.9]),
        ])
        let client = LMStudioEmbeddingClient(session: mock)

        let vectors = try await client.embed(texts: ["a", "b", "c"], config: config)

        XCTAssertEqual(vectors.count, 3)
        XCTAssertEqual(vectors[0], [0.1, 0.2, 0.3])
        XCTAssertEqual(vectors[1], [0.4, 0.5, 0.6])
        XCTAssertEqual(vectors[2], [0.7, 0.8, 0.9])
    }

    func testEmbed_reordersByIndex_whenServerReturnsOutOfOrder() async throws {
        // Server returns items in scrambled order; client sorts by `index`.
        let mock = MockNetworkSession()
        mock.responseBody = makeResponseBody([
            (2, [0.7, 0.8, 0.9]),
            (0, [0.1, 0.2, 0.3]),
            (1, [0.4, 0.5, 0.6]),
        ])
        let client = LMStudioEmbeddingClient(session: mock)

        let vectors = try await client.embed(texts: ["a", "b", "c"], config: config)

        XCTAssertEqual(vectors[0], [0.1, 0.2, 0.3], "vector[0] must correspond to input index 0")
        XCTAssertEqual(vectors[1], [0.4, 0.5, 0.6])
        XCTAssertEqual(vectors[2], [0.7, 0.8, 0.9])
    }

    func testEmbed_emptyInput_doesNotHitNetwork() async throws {
        let mock = MockNetworkSession()
        mock.errorToThrow = URLError(.notConnectedToInternet)
        let client = LMStudioEmbeddingClient(session: mock)

        let vectors = try await client.embed(texts: [], config: config)

        XCTAssertTrue(vectors.isEmpty)
        XCTAssertNil(mock.capturedURL, "empty input must not fire a network call")
    }

    func testEmbed_targetsCorrectEndpointPath() async throws {
        let mock = MockNetworkSession()
        mock.responseBody = makeResponseBody([(0, [0.5, 0.5])])
        let client = LMStudioEmbeddingClient(session: mock)

        _ = try await client.embed(texts: ["x"], config: config)

        XCTAssertNotNil(mock.capturedURL)
        XCTAssertEqual(mock.capturedURL?.path, "/v1/embeddings")
    }

    func testEmbed_sendsModelNameAndInputInBody() async throws {
        let mock = MockNetworkSession()
        mock.responseBody = makeResponseBody([(0, [1.0])])
        let client = LMStudioEmbeddingClient(session: mock)

        _ = try await client.embed(texts: ["search_document: hello"], config: config)

        XCTAssertNotNil(mock.capturedBody)
        let bodyString = String(data: mock.capturedBody!, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("\"model\""))
        XCTAssertTrue(bodyString.contains(config.modelName))
        XCTAssertTrue(bodyString.contains("search_document: hello"))
    }

    // MARK: - Error classification

    func testEmbed_mismatchedCount_throwsInvalidResponse() async {
        // Server returns 2 items for 3 inputs — considered unusable because
        // there's no way to know which two came back.
        let mock = MockNetworkSession()
        mock.responseBody = makeResponseBody([
            (0, [0.1, 0.2]),
            (1, [0.3, 0.4]),
        ])
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .invalidResponse = err { return true }
            return false
        }) {
            _ = try await client.embed(texts: ["a", "b", "c"], config: self.config)
        }
    }

    func testEmbed_inconsistentDims_throwsDimensionMismatch() async {
        // First item is 3-dim, second is 5-dim. Fail fast with
        // `.dimensionMismatch` so the caller sees a clear classification.
        let mock = MockNetworkSession()
        mock.responseBody = makeResponseBody([
            (0, [0.1, 0.2, 0.3]),
            (1, [0.4, 0.5, 0.6, 0.7, 0.8]),
        ])
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .dimensionMismatch(let expected, let got) = err {
                return expected == 3 && got == 5
            }
            return false
        }) {
            _ = try await client.embed(texts: ["a", "b"], config: self.config)
        }
    }

    func testEmbed_http404WithModelMessage_throwsModelNotLoaded() async {
        // The critical classification: LM Studio returns 404 + a message
        // mentioning the model name when the model isn't loaded.
        let mock = MockNetworkSession()
        mock.statusCode = 404
        mock.responseBody = Data("""
            {"error":{"message":"Model 'text-embedding-nomic-embed-text-v1.5' not found. Please load it in LM Studio.","type":"invalid_request_error"}}
            """.utf8)
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .modelNotLoaded(let name) = err {
                return name == "text-embedding-nomic-embed-text-v1.5"
            }
            return false
        }) {
            _ = try await client.embed(texts: ["a"], config: self.config)
        }
    }

    func testEmbed_http404WithoutMatchingMessage_throwsHTTPError() async {
        // Some other 404 — e.g. wrong endpoint path — shouldn't trigger the
        // "model not loaded" pathway. Falls back to generic `.httpError`.
        let mock = MockNetworkSession()
        mock.statusCode = 404
        mock.responseBody = Data("""
            {"error":{"message":"Endpoint /v1/embed does not exist","type":"invalid_request_error"}}
            """.utf8)
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .httpError(let status, _) = err { return status == 404 }
            return false
        }) {
            _ = try await client.embed(texts: ["a"], config: self.config)
        }
    }

    func testEmbed_http500_throwsHTTPError() async {
        let mock = MockNetworkSession()
        mock.statusCode = 500
        mock.responseBody = Data("{\"error\":{\"message\":\"OOM\"}}".utf8)
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .httpError(let status, let message) = err {
                return status == 500 && (message ?? "").contains("OOM")
            }
            return false
        }) {
            _ = try await client.embed(texts: ["a"], config: self.config)
        }
    }

    /// Some LM Studio deployments sit behind a reverse proxy that requires
    /// auth — the server returns 401 with the OpenAI error envelope. We must
    /// classify this as `.httpError(status: 401)` (NOT `.modelNotLoaded`),
    /// so the LLM-facing envelope reason makes the auth context recoverable
    /// for the user.
    func testEmbed_http401_throwsHTTPErrorWithStatus() async {
        let mock = MockNetworkSession()
        mock.statusCode = 401
        mock.responseBody = Data("""
            {"error":{"message":"Authentication required","type":"invalid_request_error"}}
            """.utf8)
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .httpError(let status, let message) = err {
                return status == 401 && (message ?? "").contains("Authentication")
            }
            return false
        }) {
            _ = try await client.embed(texts: ["a"], config: self.config)
        }
    }

    /// Forbidden — same pattern as 401 but the auth header was present and
    /// rejected. Must NOT be confused with `.modelNotLoaded`.
    func testEmbed_http403_throwsHTTPErrorWithStatus() async {
        let mock = MockNetworkSession()
        mock.statusCode = 403
        mock.responseBody = Data("""
            {"error":{"message":"Insufficient permissions","type":"invalid_request_error"}}
            """.utf8)
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .httpError(let status, _) = err { return status == 403 }
            return false
        }) {
            _ = try await client.embed(texts: ["a"], config: self.config)
        }
    }

    /// 401 with a model-themed message body must NOT trip the
    /// `.modelNotLoaded` heuristic. Pin the case ordering: status 401 dominates
    /// the message-substring match.
    func testEmbed_http401_eventIfMessageMentionsModel_classifiesAsHTTPError() async {
        let mock = MockNetworkSession()
        mock.statusCode = 401
        // Message intentionally contains "model" — the classifier could
        // mis-match this if the status check were skipped.
        mock.responseBody = Data("""
            {"error":{"message":"Cannot access model — auth required","type":"unauthorized"}}
            """.utf8)
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            // Must classify as httpError(status: 401), NOT as modelNotLoaded.
            if case .httpError(let status, _) = err { return status == 401 }
            if case .modelNotLoaded = err {
                XCTFail("401 must classify as httpError, not modelNotLoaded — auth path is distinct")
            }
            return false
        }) {
            _ = try await client.embed(texts: ["a"], config: self.config)
        }
    }

    func testEmbed_timeoutURLError_classifiesAsTimeout() async {
        let mock = MockNetworkSession()
        mock.errorToThrow = URLError(.timedOut)
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .timeout = err { return true }
            return false
        }) {
            _ = try await client.embed(texts: ["a"], config: self.config)
        }
    }

    func testEmbed_otherURLError_classifiesAsTransportError() async {
        let mock = MockNetworkSession()
        mock.errorToThrow = URLError(.notConnectedToInternet)
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .transportError = err { return true }
            return false
        }) {
            _ = try await client.embed(texts: ["a"], config: self.config)
        }
    }

    func testEmbed_unparseableBody_throwsInvalidResponse() async {
        let mock = MockNetworkSession()
        mock.responseBody = Data("not json at all".utf8)
        let client = LMStudioEmbeddingClient(session: mock)

        await assertThrows(EmbeddingClientError.self, matching: { err in
            if case .invalidResponse = err { return true }
            return false
        }) {
            _ = try await client.embed(texts: ["a"], config: self.config)
        }
    }

    // MARK: - Envelope reason canonicalization

    func testEnvelopeReason_hasCanonicalStrings() {
        // These strings are consumed by the `expand` envelope and read
        // by the chat LLM. Pin them so a rename here causes the test to
        // surface the downstream breakage.
        XCTAssertEqual(EmbeddingClientError.modelNotLoaded("x").envelopeReason,
                       "embedding_model_not_loaded")
        XCTAssertEqual(EmbeddingClientError.timeout.envelopeReason,
                       "embedding_timeout")
        XCTAssertEqual(EmbeddingClientError.dimensionMismatch(expected: 1, got: 2).envelopeReason,
                       "embedding_dimension_mismatch")
        XCTAssertEqual(EmbeddingClientError.httpError(status: 500, message: nil).envelopeReason,
                       "embedding_http_error")
        XCTAssertEqual(EmbeddingClientError.invalidResponse("").envelopeReason,
                       "embedding_invalid_response")
        XCTAssertEqual(EmbeddingClientError.requestEncodingFailed("").envelopeReason,
                       "embedding_request_encoding_failed")
        XCTAssertEqual(EmbeddingClientError.transportError("").envelopeReason,
                       "embedding_transport_error")
    }

    func testIsTerminal_classification() {
        // The builder's retry loop depends on this split — flipping a case
        // here is load-bearing, so pin both sides.
        XCTAssertTrue(EmbeddingClientError.modelNotLoaded("x").isTerminal)
        XCTAssertTrue(EmbeddingClientError.dimensionMismatch(expected: 1, got: 2).isTerminal)
        XCTAssertTrue(EmbeddingClientError.requestEncodingFailed("x").isTerminal)
        XCTAssertFalse(EmbeddingClientError.invalidResponse("x").isTerminal)
        XCTAssertFalse(EmbeddingClientError.timeout.isTerminal)
        XCTAssertFalse(EmbeddingClientError.httpError(status: 500, message: nil).isTerminal)
        XCTAssertFalse(EmbeddingClientError.transportError("x").isTerminal)
    }

    func testEmbed_urlErrorCancelled_throwsCancellationError() async {
        // URLError.cancelled must NOT wrap into .transportError("cancelled") —
        // the cooperative-cancellation tree relies on `catch is CancellationError`
        // to unwind cleanly and not trigger a retry cycle in the builder.
        let mock = MockNetworkSession()
        mock.errorToThrow = URLError(.cancelled)
        let client = LMStudioEmbeddingClient(session: mock)

        do {
            _ = try await client.embed(texts: ["a"], config: config)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Good
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - Helpers

    /// `XCTAssertThrowsError` variant that's async-aware and lets us match on
    /// a typed case via a predicate, so the test reads as intent ("must throw
    /// `.modelNotLoaded`") rather than fiddly error-unwrapping boilerplate.
    private func assertThrows<E: Error>(
        _ type: E.Type,
        matching predicate: (E) -> Bool,
        file: StaticString = #file,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(type) to be thrown", file: file, line: line)
        } catch let err as E {
            XCTAssertTrue(predicate(err),
                          "Thrown \(type) did not match predicate: \(err)",
                          file: file, line: line)
        } catch {
            XCTFail("Expected \(type), got \(error)", file: file, line: line)
        }
    }
}
