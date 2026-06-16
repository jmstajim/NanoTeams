import XCTest

@testable import NanoTeams

/// End-to-end leak guard. Fires a real LM Studio embedding request through
/// `LMStudioEmbeddingClient` with a known token in the resolver and a real
/// `NetworkLogger` writing to a temp directory. After the call, `network_log.json`
/// is read back and scanned for the token string.
///
/// If this test ever fails, a future change has started capturing HTTP
/// headers and the LM Studio bearer token would land in
/// `.nanoteams/internal/runs/*/network_log.json`.
/// The fix is NOT to change this test — it is to add explicit `Authorization`
/// redaction at the new capture point.
///
/// Note: `conversation_log.md` is no longer produced by `NetworkLogger` — it now
/// renders the activity feed (step/message data) via `ConversationTranscriptRenderer`,
/// which never sees HTTP headers, so that leak vector is closed by construction.
final class NetworkLogTokenLeakTests: XCTestCase {

    private static let canaryToken = "TOK-DO-NOT-LEAK-\(UUID().uuidString)"

    private final class CapturingNetworkSession: NetworkSession, @unchecked Sendable {
        var capturedRequest: URLRequest?
        let responseBody: Data

        init(responseBody: Data) {
            self.responseBody = responseBody
        }

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (responseBody, response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeamsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    func testEmbed_withRealLogger_doesNotLeakTokenToJSONLog() async throws {
        let logURL = tempDir.appendingPathComponent("network_log.json")
        let logger = NetworkLogger(logURL: logURL)
        let baseURL = "http://127.0.0.1:1234"

        let session = CapturingNetworkSession(
            responseBody: Data("{\"data\":[{\"embedding\":[0.1],\"index\":0}]}".utf8)
        )
        let client = LMStudioEmbeddingClient(
            session: session,
            tokenResolver: StubLLMTokenResolver([baseURL: Self.canaryToken])
        )
        let config = EmbeddingConfig(
            baseURLString: baseURL,
            modelName: "embed-test",
            batchSize: 1,
            requestTimeout: 5
        )

        // Sanity check: the request itself MUST carry the token (otherwise
        // the leak guard below is meaningless because there's no token in
        // flight).
        _ = try await client.embed(
            texts: ["canary-text-payload"],
            config: config,
            logger: logger,
            stepID: "step-canary"
        )
        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(Self.canaryToken)",
            "Sanity: request must carry the token, otherwise this test is vacuous."
        )

        // Now the actual leak guard.
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        let logContents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(
            logContents.contains(Self.canaryToken),
            "LM Studio bearer token leaked into network_log.json. "
                + "Find the new code path that's capturing HTTP headers and add "
                + "explicit `Authorization` redaction. Log contents: \(logContents.prefix(500))…"
        )
        XCTAssertFalse(
            logContents.lowercased().contains("authorization"),
            "An `Authorization` header field name leaked into network_log.json. "
                + "Even the field name shouldn't appear — it implies a header capture path was added."
        )
    }

}
