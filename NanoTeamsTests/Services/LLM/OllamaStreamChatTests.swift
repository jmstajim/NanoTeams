import XCTest

@testable import NanoTeams

/// End-to-end `OllamaClient.streamChat` over REAL `URLSession.AsyncBytes`
/// (fabricated via a `data:` URL — `AsyncBytes` has no public initializer, so
/// the double replays canned NDJSON through URLSession's built-in data-URL
/// handler). Pins the NDJSON parse contract at the transport level: content,
/// thinking, usage, mid-stream errors, and malformed lines.
final class OllamaStreamChatTests: XCTestCase {

    /// Replays canned NDJSON as a real byte stream with a fabricated HTTP status.
    private final class NDJSONBytesSession: NetworkSession, @unchecked Sendable {
        let ndjson: String
        let statusCode: Int
        let headers: [String: String]?
        var capturedRequest: URLRequest?

        init(ndjson: String, statusCode: Int = 200, headers: [String: String]? = nil) {
            self.ndjson = ndjson
            self.statusCode = statusCode
            self.headers = headers
        }

        func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) {
            fatalError("not used")
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            capturedRequest = request
            let dataURL = URL(string: "data:application/x-ndjson;base64,"
                + Data(ndjson.utf8).base64EncodedString())!
            let (bytes, _) = try await URLSession.shared.bytes(from: dataURL)
            let http = HTTPURLResponse(
                url: request.url!, statusCode: statusCode,
                httpVersion: nil, headerFields: headers)!
            return (bytes, http)
        }
    }

    private func makeConfig() -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "gpt-oss:20b")
    }

    private struct Collected {
        var content = ""
        var thinking = ""
        var usage: TokenUsage?
        var error: Error?
    }

    private func collect(_ session: NDJSONBytesSession) async -> Collected {
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let stream = client.streamChat(
            config: makeConfig(),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: [],
            logger: nil,
            stepID: nil
        )
        var out = Collected()
        do {
            for try await event in stream {
                out.content += event.contentDelta
                out.thinking += event.thinkingDelta
                if let usage = event.tokenUsage { out.usage = usage }
            }
        } catch {
            out.error = error
        }
        return out
    }

    func testStream_contentThinkingAndUsage() async {
        let ndjson = """
        {"model":"m","message":{"role":"assistant","thinking":"pondering"},"done":false}
        {"model":"m","message":{"role":"assistant","content":"Hello"},"done":false}
        {"model":"m","message":{"role":"assistant","content":" world"},"done":false}
        {"model":"m","done":true,"done_reason":"stop","prompt_eval_count":42,"eval_count":7}
        """
        let out = await collect(NDJSONBytesSession(ndjson: ndjson))
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "Hello world")
        XCTAssertEqual(out.thinking, "pondering")
        XCTAssertEqual(out.usage, TokenUsage(inputTokens: 42, outputTokens: 7))
    }

    func testStream_midStreamErrorLine_throwsProviderError() async {
        let ndjson = """
        {"model":"m","message":{"role":"assistant","content":"par"},"done":false}
        {"error":"unexpected server shutdown"}
        """
        let out = await collect(NDJSONBytesSession(ndjson: ndjson))
        XCTAssertEqual(out.content, "par", "content before the error still streams")
        guard case .providerError(let message)? = out.error as? LLMClientError else {
            return XCTFail("Expected providerError, got \(String(describing: out.error))")
        }
        XCTAssertEqual(message, "unexpected server shutdown")
    }

    func testStream_inlineThinkTags_reroutedToThinking() async {
        let ndjson = """
        {"message":{"content":"<think>plan"},"done":false}
        {"message":{"content":" it</think>answer"},"done":false}
        {"done":true}
        """
        let out = await collect(NDJSONBytesSession(ndjson: ndjson))
        XCTAssertEqual(out.thinking, "plan it")
        XCTAssertEqual(out.content, "answer")
    }

    func testStream_postsToApiChat() async {
        let session = NDJSONBytesSession(ndjson: #"{"done":true}"#)
        _ = await collect(session)
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/chat")
        XCTAssertEqual(session.capturedRequest?.httpMethod, "POST")
    }

    // MARK: - Transport corners

    func testHTTP404_throwsBadHTTPStatusWithBody() async {
        let out = await collect(NDJSONBytesSession(
            ndjson: #"{"error":"model \"gpt-oss:20b\" not found, try pulling it first"}"#,
            statusCode: 404))
        guard case .badHTTPStatus(let code, let body)? = out.error as? LLMClientError else {
            return XCTFail("Expected badHTTPStatus, got \(String(describing: out.error))")
        }
        XCTAssertEqual(code, 404)
        XCTAssertTrue(body?.contains("try pulling it first") == true,
                      "the actionable Ollama error body must reach the user")
        XCTAssertTrue(out.content.isEmpty, "no content events on an error response")
    }

    func testHTTP429_withRetryAfter_throwsRateLimited() async {
        let out = await collect(NDJSONBytesSession(
            ndjson: "", statusCode: 429, headers: ["Retry-After": "30"]))
        guard case .rateLimited(let retryAfter)? = out.error as? LLMClientError else {
            return XCTFail("Expected rateLimited, got \(String(describing: out.error))")
        }
        XCTAssertEqual(retryAfter, 30)
    }

    func testEmptyBody200_finishesCleanWithNoEvents() async {
        let out = await collect(NDJSONBytesSession(ndjson: ""))
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "")
        XCTAssertEqual(out.thinking, "")
        XCTAssertNil(out.usage)
    }

    func testStreamDiesWithoutDoneLine_contentSurvives_noUsage() async {
        // Connection drop mid-generation: whatever streamed stays streamed,
        // and the held-back partial <think> prefix must not vanish.
        let ndjson = """
        {"message":{"content":"partial answer"},"done":false}
        {"message":{"content":" then <thi"},"done":false}
        """
        let out = await collect(NDJSONBytesSession(ndjson: ndjson))
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "partial answer then <thi",
                       "finalize() must surface the held tag prefix at transport end")
        XCTAssertNil(out.usage)
    }

    func testBlankAndMalformedLinesInterspersed_ignored() async {
        let ndjson = """
        {"message":{"content":"a"},"done":false}
        
        not json at all
        {"message":{"content":"b"},"done":false}
        {"done":true,"prompt_eval_count":3,"eval_count":4}
        """
        let out = await collect(NDJSONBytesSession(ndjson: ndjson))
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "ab")
        XCTAssertEqual(out.usage, TokenUsage(inputTokens: 3, outputTokens: 4))
    }
}
