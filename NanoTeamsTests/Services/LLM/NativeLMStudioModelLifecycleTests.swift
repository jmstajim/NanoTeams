import XCTest

@testable import NanoTeams

/// Wire tests for `NativeLMStudioClient.loadModel` / `unloadModel`. Exercises
/// the `/api/v1/models/load` and `/api/v1/models/unload` endpoints via a
/// recording mock session.
final class NativeLMStudioModelLifecycleTests: XCTestCase {

    // MARK: - Mock

    private final class RecordingSession: NetworkSession, @unchecked Sendable {
        var capturedURL: URL?
        var capturedMethod: String?
        var capturedBody: Data?
        var capturedContentType: String?
        var statusCode: Int = 200
        var responseBody: Data = Data()

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedURL = request.url
            capturedMethod = request.httpMethod
            capturedBody = request.httpBody
            capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (responseBody, response)
        }

        func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("Not used")
        }
    }

    private func decodeJSON(_ data: Data?) -> [String: Any] {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    // MARK: - load happy path

    func testLoad_postsCorrectURLMethodAndBody() async throws {
        let session = RecordingSession()
        session.responseBody = Data(#"{"instance_id":"openai/gpt-oss-20b","status":"loaded","type":"llm"}"#.utf8)
        let client = NativeLMStudioClient(session: session)

        let id = try await client.loadModel(
            modelName: "openai/gpt-oss-20b",
            baseURLString: "http://127.0.0.1:1234"
        )

        XCTAssertEqual(id, "openai/gpt-oss-20b")
        XCTAssertEqual(session.capturedURL?.absoluteString, "http://127.0.0.1:1234/api/v1/models/load")
        XCTAssertEqual(session.capturedMethod, "POST")
        XCTAssertEqual(session.capturedContentType, "application/json")

        let body = decodeJSON(session.capturedBody)
        XCTAssertEqual(body["model"] as? String, "openai/gpt-oss-20b")
        XCTAssertEqual(body["echo_load_config"] as? Bool, true,
                       "echo_load_config must be true so future diagnostics can read load_config")
    }

    // MARK: - load idempotency

    func testLoad_4xxWithEmbeddedInstanceID_returnsExistingID() async throws {
        // Some LM Studio builds surface duplicate-load via 4xx + body that still
        // includes the existing instance_id. Treat as success.
        let session = RecordingSession()
        session.statusCode = 409
        session.responseBody = Data(#"{"instance_id":"existing-id","status":"already_loaded"}"#.utf8)
        let client = NativeLMStudioClient(session: session)

        let id = try await client.loadModel(
            modelName: "model-a",
            baseURLString: "http://127.0.0.1:1234"
        )
        XCTAssertEqual(id, "existing-id")
    }

    /// I1 regression: when LM Studio returns a non-2xx with no parseable
    /// `instance_id`, the client MUST throw `badHTTPStatus` instead of
    /// fabricating `modelName` as a synthetic id. The previous fallback
    /// produced an unloadable id chain — silent VRAM leak. The C1 adoption
    /// path (`listLoadedInstances` ahead of `loadModel`) prevents the
    /// "already loaded" case from reaching this method in production.
    func testLoad_4xxWithAlreadyLoadedMessage_doesNotFabricateID_throws() async {
        let session = RecordingSession()
        session.statusCode = 409
        session.responseBody = Data(#"{"error":"model already loaded"}"#.utf8)
        let client = NativeLMStudioClient(session: session)

        do {
            _ = try await client.loadModel(
                modelName: "model-a",
                baseURLString: "http://127.0.0.1:1234"
            )
            XCTFail("Expected throw — fabricated ids would orphan instances")
        } catch let error as LLMClientError {
            if case .badHTTPStatus(let code, _) = error {
                XCTAssertEqual(code, 409)
            } else {
                XCTFail("Expected badHTTPStatus, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoad_5xx_throwsBadHTTPStatus() async {
        let session = RecordingSession()
        session.statusCode = 500
        session.responseBody = Data("internal error".utf8)
        let client = NativeLMStudioClient(session: session)

        do {
            _ = try await client.loadModel(
                modelName: "model-a",
                baseURLString: "http://127.0.0.1:1234"
            )
            XCTFail("Expected throw")
        } catch let error as LLMClientError {
            if case .badHTTPStatus(let code, _) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Expected badHTTPStatus, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoad_invalidBaseURL_throws() async {
        let session = RecordingSession()
        let client = NativeLMStudioClient(session: session)

        do {
            _ = try await client.loadModel(modelName: "m", baseURLString: "")
            XCTFail("Expected throw")
        } catch let error as LLMClientError {
            if case .invalidBaseURL = error { /* ok */ } else {
                XCTFail("Expected invalidBaseURL, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - unload happy path

    func testUnload_postsCorrectURLAndBody() async throws {
        let session = RecordingSession()
        session.responseBody = Data(#"{"instance_id":"openai/gpt-oss-20b"}"#.utf8)
        let client = NativeLMStudioClient(session: session)

        try await client.unloadModel(
            instanceID: "openai/gpt-oss-20b",
            baseURLString: "http://127.0.0.1:1234"
        )

        XCTAssertEqual(session.capturedURL?.absoluteString, "http://127.0.0.1:1234/api/v1/models/unload")
        XCTAssertEqual(session.capturedMethod, "POST")
        let body = decodeJSON(session.capturedBody)
        XCTAssertEqual(body["instance_id"] as? String, "openai/gpt-oss-20b")
    }

    // MARK: - unload idempotency

    func testUnload_404_isTreatedAsSuccess() async throws {
        let session = RecordingSession()
        session.statusCode = 404
        session.responseBody = Data(#"{"error":"instance not found"}"#.utf8)
        let client = NativeLMStudioClient(session: session)

        // Must not throw — instance is already gone, desired state holds.
        try await client.unloadModel(
            instanceID: "stale-id",
            baseURLString: "http://127.0.0.1:1234"
        )
    }

    func testUnload_2xx_isSuccess() async throws {
        // Plain 2xx — common happy path.
        let session = RecordingSession()
        session.statusCode = 200
        session.responseBody = Data(#"{"instance_id":"x"}"#.utf8)
        let client = NativeLMStudioClient(session: session)

        try await client.unloadModel(
            instanceID: "x",
            baseURLString: "http://127.0.0.1:1234"
        )
    }

    /// C5 regression: each documented "already unloaded" sentinel substring
    /// must be honored when it appears in the structured `error.message` of
    /// a non-404 error response.
    func testUnload_4xx_alreadyUnloadedSubstrings_isSuccess() async throws {
        let phrases = [
            "instance not found",
            "no such instance",
            "instance is not loaded",
        ]
        for phrase in phrases {
            let session = RecordingSession()
            session.statusCode = 400
            session.responseBody = Data(#"{"error":{"message":"\#(phrase)"}}"#.utf8)
            let client = NativeLMStudioClient(session: session)

            try await client.unloadModel(
                instanceID: "x",
                baseURLString: "http://127.0.0.1:1234"
            )
        }
    }

    /// C5 regression: substring "not loaded" appears in the LoRA error
    /// "the requested adapter is not loaded into the base model". That MUST
    /// throw — the adapter mismatch is a real failure, not "already
    /// unloaded". Pre-fix lower-bodied substring matching swallowed it.
    func testUnload_4xx_loraNotLoadedIntoBaseModel_throws() async {
        let session = RecordingSession()
        session.statusCode = 400
        session.responseBody = Data(#"{"error":{"message":"the requested adapter is not loaded into the base model"}}"#.utf8)
        let client = NativeLMStudioClient(session: session)

        do {
            try await client.unloadModel(instanceID: "x", baseURLString: "http://127.0.0.1:1234")
            XCTFail("Expected throw — LoRA error must not be classified as 'already unloaded'")
        } catch let error as LLMClientError {
            if case .badHTTPStatus(let code, _) = error {
                XCTAssertEqual(code, 400)
            } else {
                XCTFail("Expected badHTTPStatus, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// C5 regression: bare-string error envelope (`{"error": "..."}`) must
    /// also be parsed for the sentinel substrings.
    func testUnload_4xx_bareStringErrorEnvelope_alreadyUnloaded() async throws {
        let session = RecordingSession()
        session.statusCode = 400
        session.responseBody = Data(#"{"error":"instance not found"}"#.utf8)
        let client = NativeLMStudioClient(session: session)

        try await client.unloadModel(instanceID: "x", baseURLString: "http://127.0.0.1:1234")
    }

    // MARK: - listLoadedInstances (C1 wire test)

    /// C1 regression: the adoption path used by `EmbeddingModelLifecycleService`
    /// to detect models already loaded server-side. Must (a) hit
    /// `/api/v0/models`, (b) filter to `state == "loaded"`, (c) strip the
    /// LM Studio `:N` dedup suffix from the canonical name, and (d) preserve
    /// the raw id as `instanceID` so a subsequent unload targets the right
    /// instance.
    func testListLoadedInstances_returnsLoadedModels_canonicalizesSuffix() async throws {
        let session = RecordingSession()
        session.responseBody = Data(#"""
        {
          "data": [
            {"id":"text-embedding-nomic-embed-text-v1.5","state":"loaded","type":"embeddings"},
            {"id":"text-embedding-nomic-embed-text-v1.5:2","state":"loaded","type":"embeddings"},
            {"id":"granite-embedding","state":"not-loaded","type":"embeddings"},
            {"id":"qwen-llm","state":"loaded","type":"llm"}
          ]
        }
        """#.utf8)
        let client = NativeLMStudioClient(session: session)

        let loaded = try await client.listLoadedInstances(baseURLString: "http://127.0.0.1:1234")

        XCTAssertEqual(session.capturedURL?.absoluteString,
                       "http://127.0.0.1:1234/api/v0/models",
                       "Must hit the v0 endpoint — v1 has no per-instance state")
        XCTAssertEqual(session.capturedMethod, "GET")

        XCTAssertEqual(loaded.count, 3, "not-loaded entries must be filtered out")

        // Canonical names: suffix stripped for the duplicate, untouched for others.
        let names = Set(loaded.map(\.modelName))
        XCTAssertTrue(names.contains("text-embedding-nomic-embed-text-v1.5"))
        XCTAssertTrue(names.contains("qwen-llm"))

        // Both the suffixed and unsuffixed variants share the same canonical
        // name so adoption matches against `EmbeddingConfig.modelName` works
        // regardless of which instance is alive.
        let nomic = loaded.filter { $0.modelName == "text-embedding-nomic-embed-text-v1.5" }
        XCTAssertEqual(nomic.count, 2)
        let nomicIDs = Set(nomic.map(\.instanceID))
        XCTAssertEqual(nomicIDs, [
            "text-embedding-nomic-embed-text-v1.5",
            "text-embedding-nomic-embed-text-v1.5:2",
        ], "Raw ids preserved so unload can target each instance individually")
    }

    /// 404 from /api/v0/models means LM Studio is older than the v0 listing
    /// endpoint. Must degrade to `[]` so the lifecycle service's adoption
    /// path falls through to `loadModel` instead of crashing.
    func testListLoadedInstances_404_returnsEmpty_notThrows() async throws {
        let session = RecordingSession()
        session.statusCode = 404
        session.responseBody = Data(#"{"error":"unknown route"}"#.utf8)
        let client = NativeLMStudioClient(session: session)

        let loaded = try await client.listLoadedInstances(baseURLString: "http://127.0.0.1:1234")
        XCTAssertEqual(loaded, [])
    }

    func testCanonicalModelName_stripsNumericSuffixOnly() {
        XCTAssertEqual(NativeLMStudioClient.canonicalModelName("model-a"), "model-a")
        XCTAssertEqual(NativeLMStudioClient.canonicalModelName("model-a:2"), "model-a")
        XCTAssertEqual(NativeLMStudioClient.canonicalModelName("model-a:99"), "model-a")
        // Non-numeric suffix is real model versioning (e.g. `:latest`) — NOT
        // a dedup suffix. Must be preserved so we don't collapse unrelated
        // models.
        XCTAssertEqual(NativeLMStudioClient.canonicalModelName("model-a:latest"), "model-a:latest")
        XCTAssertEqual(NativeLMStudioClient.canonicalModelName("ns/model:1.5"), "ns/model:1.5",
                       "Decimal version strings (semver) are not dedup suffixes")
    }

    func testUnload_5xx_throws() async {
        let session = RecordingSession()
        session.statusCode = 500
        session.responseBody = Data("oops".utf8)
        let client = NativeLMStudioClient(session: session)

        do {
            try await client.unloadModel(instanceID: "x", baseURLString: "http://127.0.0.1:1234")
            XCTFail("Expected throw")
        } catch let error as LLMClientError {
            if case .badHTTPStatus(let code, _) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Expected badHTTPStatus, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
