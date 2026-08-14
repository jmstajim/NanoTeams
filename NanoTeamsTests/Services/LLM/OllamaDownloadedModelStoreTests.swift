import XCTest

@testable import NanoTeams

/// Wire contract for Ollama's downloaded-model surface. Every assertion here is
/// against a captured `URLRequest` — nothing reaches a real server.
final class OllamaDownloadedModelStoreTests: XCTestCase {

    private func config(_ url: String = "http://127.0.0.1:11434") -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: url, modelName: "m")
    }

    private static let tagsBody = """
        {"models":[
          {"name":"llama3.1:8b","size":4661224676,"modified_at":"2026-07-01T22:00:00Z",
           "details":{"format":"gguf","parameter_size":"8.0B","quantization_level":"Q4_K_M"}},
          {"name":"qwen3.6:35b","size":21910000000,
           "details":{"format":"gguf","parameter_size":"35B","quantization_level":"NVFP4"}}
        ]}
        """

    // MARK: - Listing

    func testList_decodesNameSizeAndQuantization() async throws {
        let session = RoutingSession(routes: [
            "/api/tags": .init(status: 200, body: Self.tagsBody),
            "/api/ps": .init(status: 200, body: #"{"models":[]}"#),
        ])
        let store = OllamaDownloadedModelStore(session: session, tokenResolver: StubLLMTokenResolver())

        let models = try await store.listDownloaded(config: config())

        XCTAssertEqual(models.map(\.id), ["llama3.1:8b", "qwen3.6:35b"])
        XCTAssertEqual(models[0].sizeBytes, 4_661_224_676)
        XCTAssertEqual(models[0].detail, "8.0B · Q4_K_M")
        XCTAssertEqual(models[0].referenceHints, ["llama3.1:8b"])
    }

    func testList_marksResidentModelsFromPS() async throws {
        let session = RoutingSession(routes: [
            "/api/tags": .init(status: 200, body: Self.tagsBody),
            "/api/ps": .init(status: 200, body: #"{"models":[{"name":"qwen3.6:35b","size_vram":123}]}"#),
        ])
        let store = OllamaDownloadedModelStore(session: session, tokenResolver: StubLLMTokenResolver())

        let models = try await store.listDownloaded(config: config())

        XCTAssertEqual(models.first { $0.id == "qwen3.6:35b" }?.isLoaded, true)
        XCTAssertEqual(models.first { $0.id == "llama3.1:8b" }?.isLoaded, false)
    }

    /// A FAILED `/api/ps` probe must omit the claim, not invert it — the same
    /// rule `OllamaClient.modelLoadDetails` follows.
    func testList_failedPSProbeStillLists() async throws {
        let session = RoutingSession(routes: [
            "/api/tags": .init(status: 200, body: Self.tagsBody),
            "/api/ps": .init(status: 500, body: "boom"),
        ])
        let store = OllamaDownloadedModelStore(session: session, tokenResolver: StubLLMTokenResolver())

        let models = try await store.listDownloaded(config: config())

        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(models.allSatisfy { !$0.isLoaded })
    }

    func testList_missingOptionalFieldsStillDecodes() async throws {
        let session = RoutingSession(routes: [
            "/api/tags": .init(status: 200, body: #"{"models":[{"name":"old:latest"}]}"#),
            "/api/ps": .init(status: 200, body: #"{"models":[]}"#),
        ])
        let store = OllamaDownloadedModelStore(session: session, tokenResolver: StubLLMTokenResolver())

        let models = try await store.listDownloaded(config: config())

        XCTAssertEqual(models.map(\.id), ["old:latest"])
        XCTAssertNil(models[0].sizeBytes)
        XCTAssertNil(models[0].detail)
    }

    func testList_propagatesTagsFailure() async {
        let session = RoutingSession(routes: ["/api/tags": .init(status: 503, body: "down")])
        let store = OllamaDownloadedModelStore(session: session, tokenResolver: StubLLMTokenResolver())

        do {
            _ = try await store.listDownloaded(config: config())
            XCTFail("expected a throw")
        } catch {
            guard case LLMClientError.badHTTPStatus(let code, _) = error else {
                return XCTFail("expected badHTTPStatus, got \(error)")
            }
            XCTAssertEqual(code, 503)
        }
    }

    func testList_invalidBaseURLThrows() async {
        let store = OllamaDownloadedModelStore(
            session: RoutingSession(routes: [:]), tokenResolver: StubLLMTokenResolver())
        do {
            _ = try await store.listDownloaded(config: config(""))
            XCTFail("expected a throw")
        } catch {
            guard case LLMClientError.invalidBaseURL = error else {
                return XCTFail("expected invalidBaseURL, got \(error)")
            }
        }
    }

    // MARK: - Capability

    /// `DELETE /api/delete` runs on the server that owns the files, so it is as
    /// valid against a remote host as a local one — the opposite of LM Studio.
    func testCapability_isPermanentEvenForARemoteHost() async {
        let store = OllamaDownloadedModelStore(
            session: RoutingSession(routes: [:]), tokenResolver: StubLLMTokenResolver())
        let capability = await store.deletionCapability(config: config("http://10.0.0.7:11434"))
        XCTAssertEqual(capability, .permanent)
    }

    // MARK: - Deletion

    func testDelete_issuesDeleteWithModelKey() async throws {
        let session = RoutingSession(routes: ["/api/delete": .init(status: 200, body: "")])
        let store = OllamaDownloadedModelStore(session: session, tokenResolver: StubLLMTokenResolver())

        try await store.delete(modelID: "llama3.1:8b", config: config())

        let request = try XCTUnwrap(session.captured.last)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/delete")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "llama3.1:8b")
        XCTAssertNil(
            json["name"],
            "`name` is deprecated in Ollama's api/types.go — send only the supported key")
    }

    /// Already gone is the outcome the caller asked for. Mirrors
    /// `NativeLMStudioClient.unloadModel`'s idempotent-404 rule so a double-tap
    /// or a concurrent deletion elsewhere isn't a spurious error.
    func testDelete_404IsSuccess() async throws {
        let session = RoutingSession(routes: [
            "/api/delete": .init(status: 404, body: #"{"error":"model 'x' not found"}"#)
        ])
        let store = OllamaDownloadedModelStore(session: session, tokenResolver: StubLLMTokenResolver())

        try await store.delete(modelID: "x", config: config())
    }

    func testDelete_otherFailuresThrow() async {
        let session = RoutingSession(routes: ["/api/delete": .init(status: 500, body: "boom")])
        let store = OllamaDownloadedModelStore(session: session, tokenResolver: StubLLMTokenResolver())

        do {
            try await store.delete(modelID: "x", config: config())
            XCTFail("expected a throw")
        } catch {
            guard case LLMClientError.badHTTPStatus(let code, _) = error else {
                return XCTFail("expected badHTTPStatus, got \(error)")
            }
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - Auth

    func testRequests_carryTheBearerToken() async throws {
        let session = RoutingSession(routes: [
            "/api/tags": .init(status: 200, body: #"{"models":[]}"#),
            "/api/ps": .init(status: 200, body: #"{"models":[]}"#),
            "/api/delete": .init(status: 200, body: ""),
        ])
        let store = OllamaDownloadedModelStore(
            session: session, tokenResolver: StubLLMTokenResolver(["http://127.0.0.1:11434": "tok-1"]))

        _ = try await store.listDownloaded(config: config())
        try await store.delete(modelID: "x", config: config())

        XCTAssertFalse(session.captured.isEmpty)
        for request in session.captured {
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1",
                "\(request.url?.path ?? "?") must carry the bearer token")
        }
    }
}

// MARK: - Doubles

/// Routes by URL path and records every request it served.
private final class RoutingSession: NetworkSession, @unchecked Sendable {
    struct Route {
        let status: Int
        let body: String
    }

    private let routes: [String: Route]
    private(set) var captured: [URLRequest] = []

    init(routes: [String: Route]) {
        self.routes = routes
    }

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        captured.append(request)
        let path = request.url?.path ?? ""
        guard let route = routes[path] else {
            throw LLMClientError.providerError("no route for \(path)")
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil)!
        return (Data(route.body.utf8), response)
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("RoutingSession.sessionBytes not supported")
    }
}
