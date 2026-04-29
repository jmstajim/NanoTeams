import XCTest

@testable import NanoTeams

final class LMStudioEmbeddingClientAuthTests: XCTestCase {

    private final class CapturingNetworkSession: NetworkSession, @unchecked Sendable {
        var capturedRequest: URLRequest?
        var responseBody: Data = Data("{\"data\":[{\"embedding\":[1.0],\"index\":0}]}".utf8)
        var statusCode: Int = 200

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (responseBody, response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("Not used")
        }
    }

    private let config = EmbeddingConfig(
        baseURLString: "http://127.0.0.1:1234",
        modelName: "embed-test",
        batchSize: 8,
        requestTimeout: 5
    )

    func testEmbed_setsAuthorizationHeader_whenResolverHasToken() async throws {
        let session = CapturingNetworkSession()
        let client = LMStudioEmbeddingClient(
            session: session,
            tokenResolver: StubLLMTokenResolver(["http://127.0.0.1:1234": "embed-secret"])
        )

        _ = try await client.embed(texts: ["hello"], config: config)

        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer embed-secret"
        )
    }

    func testEmbed_omitsHeader_whenResolverEmpty() async throws {
        let session = CapturingNetworkSession()
        let client = LMStudioEmbeddingClient(
            session: session,
            tokenResolver: StubLLMTokenResolver([:])
        )

        _ = try await client.embed(texts: ["hello"], config: config)

        XCTAssertNil(session.capturedRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testEmbed_omitsHeader_whenResolverHasOtherURL() async throws {
        let session = CapturingNetworkSession()
        let client = LMStudioEmbeddingClient(
            session: session,
            tokenResolver: StubLLMTokenResolver(["http://other:9999": "x"])
        )

        _ = try await client.embed(texts: ["hello"], config: config)

        XCTAssertNil(session.capturedRequest?.value(forHTTPHeaderField: "Authorization"))
    }
}
