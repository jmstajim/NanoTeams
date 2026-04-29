import XCTest

@testable import NanoTeams

/// Pins `Authorization: Bearer …` on every NativeLMStudioClient request site
/// EXCEPT streaming chat (POST /api/v1/chat) — that path uses `sessionBytes`
/// rather than `sessionData` and is covered by
/// `NativeLMStudioClientStreamingAuthTests` in the same directory.
final class NativeLMStudioClientAuthTests: XCTestCase {

    private final class CapturingNetworkSession: NetworkSession, @unchecked Sendable {
        var capturedRequest: URLRequest?
        var responseBody: Data = Data()
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            return (responseBody, response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    private let baseURL = "http://localhost:1234"

    private func makeClient(
        session: any NetworkSession,
        tokens: [String: String] = [:]
    ) -> NativeLMStudioClient {
        NativeLMStudioClient(
            session: session,
            tokenResolver: StubLLMTokenResolver(tokens)
        )
    }

    private func makeConfig() -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: baseURL,
            modelName: "test-model",
            maxTokens: 1024,
            temperature: nil
        )
    }

    // MARK: - GET /api/v1/models

    func testFetchModels_setsAuthHeader_whenTokenPresent() async throws {
        let session = CapturingNetworkSession()
        session.responseBody = Data("{\"data\":[]}".utf8)
        let client = makeClient(session: session, tokens: [baseURL: "tok-1"])

        _ = try await client.fetchModels(config: makeConfig(), visionOnly: false)

        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer tok-1"
        )
    }

    func testFetchModels_omitsAuthHeader_whenTokenAbsent() async throws {
        let session = CapturingNetworkSession()
        session.responseBody = Data("{\"data\":[]}".utf8)
        let client = makeClient(session: session)

        _ = try await client.fetchModels(config: makeConfig(), visionOnly: false)

        XCTAssertNil(session.capturedRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - POST /api/v1/models/load

    func testLoadModel_setsAuthHeader_whenTokenPresent() async throws {
        let session = CapturingNetworkSession()
        session.responseBody = Data("{\"instance_id\":\"abc\"}".utf8)
        let client = makeClient(session: session, tokens: [baseURL: "tok-load"])

        _ = try await client.loadModel(modelName: "m", baseURLString: baseURL)

        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer tok-load"
        )
    }

    // MARK: - POST /api/v1/models/unload

    func testUnloadModel_setsAuthHeader_whenTokenPresent() async throws {
        let session = CapturingNetworkSession()
        session.statusCode = 200
        let client = makeClient(session: session, tokens: [baseURL: "tok-unload"])

        try await client.unloadModel(instanceID: "abc", baseURLString: baseURL)

        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer tok-unload"
        )
    }

    // MARK: - GET /api/v0/models

    func testListLoadedInstances_setsAuthHeader_whenTokenPresent() async throws {
        let session = CapturingNetworkSession()
        session.responseBody = Data("{\"data\":[]}".utf8)
        let client = makeClient(session: session, tokens: [baseURL: "tok-list"])

        _ = try await client.listLoadedInstances(baseURLString: baseURL)

        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer tok-list"
        )
    }
}
