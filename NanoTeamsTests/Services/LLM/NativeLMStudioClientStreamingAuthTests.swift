import XCTest

@testable import NanoTeams

/// Pins `Authorization: Bearer …` on the streaming chat path
/// (`POST /api/v1/chat`). This is the single hottest auth path in the app —
/// every step every role makes goes through here. A regression silently 401s
/// every conversation.
///
/// Separate from `NativeLMStudioClientAuthTests` because streaming chat uses
/// `URLSession.bytes(for:)` (i.e. `sessionBytes` on the protocol), and
/// mocking that returns an `AsyncBytes` whose construction differs from a
/// plain `(Data, URLResponse)` mock.
final class NativeLMStudioClientStreamingAuthTests: XCTestCase {

    /// Captures the URLRequest before the chat client tries to consume the
    /// response stream. We don't need to deliver any actual SSE bytes —
    /// the assertion only inspects the outgoing request, so we throw
    /// `URLError.cancelled` to bail the stream tear-down without polluting
    /// stderr.
    private final class CapturingBytesSession: NetworkSession, @unchecked Sendable {
        var capturedRequest: URLRequest?

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            // streamChat doesn't call this; if it ever does, capture the
            // request here too.
            capturedRequest = request
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            capturedRequest = request
            // Simulate a transport-level cancellation so the streamChat
            // task unwinds without attempting to parse SSE events.
            throw URLError(.cancelled)
        }
    }

    private let baseURL = "http://localhost:1234"

    private func makeConfig() -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: baseURL,
            modelName: "test-model",
            maxTokens: 1024,
            temperature: nil
        )
    }

    func testStreamChat_setsAuthorizationHeader_whenResolverHasToken() async {
        let session = CapturingBytesSession()
        let client = NativeLMStudioClient(
            session: session,
            tokenResolver: StubLLMTokenResolver([baseURL: "stream-secret"])
        )

        let stream = client.streamChat(
            config: makeConfig(),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: [],
            session: nil,
            logger: nil,
            stepID: nil
        )
        // Drain the stream so the underlying Task fires sessionBytes.
        // We expect it to throw (URLError.cancelled), but the request must
        // already have been built and captured by then.
        do {
            for try await _ in stream {}
        } catch {
            // Expected — the mock cancels the stream after capture.
        }

        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer stream-secret",
            "streamChat must set Authorization: Bearer <token> on /api/v1/chat — "
                + "this is the hottest auth path; regression silently 401s every step."
        )
    }

    func testStreamChat_omitsAuthorizationHeader_whenNoToken() async {
        let session = CapturingBytesSession()
        let client = NativeLMStudioClient(
            session: session,
            tokenResolver: StubLLMTokenResolver([:])
        )

        let stream = client.streamChat(
            config: makeConfig(),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: [],
            session: nil,
            logger: nil,
            stepID: nil
        )
        do { for try await _ in stream {} } catch {}

        XCTAssertNil(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Without a token in the resolver, no Authorization header should be sent."
        )
    }

    func testStreamChat_correctMethodAndPath() async {
        let session = CapturingBytesSession()
        let client = NativeLMStudioClient(session: session)

        let stream = client.streamChat(
            config: makeConfig(),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: [],
            session: nil,
            logger: nil,
            stepID: nil
        )
        do { for try await _ in stream {} } catch {}

        XCTAssertEqual(session.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v1/chat")
    }
}
