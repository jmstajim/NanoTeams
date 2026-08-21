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
            temperature: nil
        )
    }

    /// Throws a real `CancellationError` out of the transport — the shape
    /// `URLSession.bytes(for:)` produces when its task is cancelled, which is what
    /// Pause / `cancelStepExecution` / a work-folder switch do to a live stream.
    private final class CancellingBytesSession: NetworkSession, @unchecked Sendable {
        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            // `ensureLoaded`'s adopt probe (`GET /api/v0/models`). An empty listing
            // is enough: nothing to adopt, and the load attempt that follows lands
            // on the same empty body, so the stream reaches `sessionBytes` either way.
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!)
        }

        func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            throw CancellationError()
        }
    }

    /// Cancellation is not a transport failure, and the two are handled by different
    /// arms of the same `do` — so the observable difference is what the LOG says.
    ///
    /// The generic `catch` writes a response record with `statusCode: 0` and the
    /// error text; the `catch is CancellationError` above it deliberately writes
    /// nothing and just finishes the stream. That asymmetry is the contract: every
    /// Pause during a stream would otherwise append a fabricated transport failure to
    /// `network_log.json` — the file the prefix-cache and latency work reads as
    /// ground truth, where a run littered with `statusCode: 0` rows reads as an
    /// unstable server rather than as the user pressing Pause.
    ///
    /// Until wave 12 this line was covered only INCIDENTALLY, by whichever unrelated
    /// test happened to cancel a stream mid-flight that run — it flipped between runs
    /// and showed up as unattributable drift in the coverage table. Pinning it removes
    /// a jitter source as well as covering the arm.
    ///
    /// RED: change `catch is CancellationError { continuation.finish(throwing:
    /// CancellationError()) }` to fall through to the generic `catch` (delete the arm)
    /// → a response record appears and both log assertions fail; the thrown-error
    /// assertion also fails, since the generic arm rethrows the original error wrapped
    /// as a transport failure.
    func testStreamChat_transportCancelled_finishesCleanlyAndLogsNoFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("network_log.json")
        let logger = NetworkLogger(logURL: logURL)

        let client = NativeLMStudioClient(
            session: CancellingBytesSession(),
            tokenResolver: StubLLMTokenResolver(),
            modelEnsurer: ChatModelEnsurer()
        )

        var thrown: Error?
        do {
            for try await _ in client.streamChat(
                config: makeConfig(),
                messages: [ChatMessage(role: .user, content: "hi")],
                tools: [],
                logger: logger,
                stepID: "step-1"
            ) {}
        } catch {
            thrown = error
        }

        XCTAssertTrue(thrown is CancellationError,
                      "a cancelled transport must surface as CancellationError, not as a "
                          + "transport failure the caller would banner; got \(String(describing: thrown))")

        let records = try NetworkLogTestReading.strictRecords(at: logURL)
        XCTAssertTrue(records.contains { $0.direction == .request },
                      "precondition: the request was logged, so the run really reached the transport")
        XCTAssertFalse(records.contains { $0.direction == .response },
                       "a cancellation must not fabricate a response record; got: \(records)")
        XCTAssertFalse(records.contains { $0.errorMessage != nil },
                       "…nor an error record; got: \(records)")
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
            logger: nil,
            stepID: nil
        )
        do { for try await _ in stream {} } catch {}

        XCTAssertEqual(session.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v1/chat")
    }
}
