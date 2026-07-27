import XCTest

@testable import NanoTeams

/// Wiring pin: `NativeLMStudioClient.streamChat` must ensure the model is
/// EXPLICITLY loaded BEFORE issuing the chat request. If the ensure ran after
/// (or not at all), LM Studio would JIT-load the model — and JIT instances are
/// Auto-Evicted by one another, so Vision and chat would fight over memory.
final class ChatModelEnsureWiringTests: XCTestCase, @unchecked Sendable {

    private let baseURL = "http://127.0.0.1:1234"

    /// Records the path of every request in order. Answers the loaded-models
    /// probe with a valid (empty) listing so the ensure path runs to
    /// completion, and cancels the chat stream so no SSE parsing is needed.
    private final class SequenceRecordingSession: NetworkSession, @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        var paths: [String] { lock.withLock { _paths } }

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            let path = request.url?.path ?? ""
            lock.withLock { _paths.append(path) }
            // Nothing loaded yet → the ensure must load; the load then answers
            // with a well-formed instance so the chat request can proceed.
            let body = path.contains("/models/load")
                ? #"{"instance_id": "qwen", "status": "loaded"}"#
                : #"{"data": []}"#
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            lock.withLock { _paths.append(request.url?.path ?? "") }
            throw URLError(.cancelled)
        }
    }

    private func drain(_ stream: AsyncThrowingStream<StreamEvent, Error>) async {
        do {
            for try await _ in stream {}
        } catch {
            // Transport cancellation is the expected unwind for this stub.
        }
    }

    func testStreamChat_ensuresModelLoaded_beforeIssuingChatRequest() async {
        let session = SequenceRecordingSession()
        let client = NativeLMStudioClient(
            session: session,
            tokenResolver: StubLLMTokenResolver([:]),
            modelEnsurer: ChatModelEnsurer()
        )

        await drain(client.streamChat(
            config: LLMConfig(baseURLString: baseURL, modelName: "qwen"),
            messages: [ChatMessage(role: .user, content: "Hi")],
            tools: [],
            logger: nil,
            stepID: nil
        ))

        guard let probeIndex = session.paths.firstIndex(where: { $0.contains("/api/v0/models") }),
              let loadIndex = session.paths.firstIndex(where: { $0.contains("/api/v1/models/load") }),
              let chatIndex = session.paths.firstIndex(where: { $0.contains("/api/v1/chat") })
        else {
            return XCTFail("Expected probe, load and chat requests: \(session.paths)")
        }
        XCTAssertLessThan(loadIndex, chatIndex,
                          "An unloaded model must be loaded explicitly, never left to JIT")
        XCTAssertLessThan(probeIndex, chatIndex,
                          "The load check must precede the chat request")
    }

    /// An unusable base URL must fail the same way it always did — the ensure
    /// step must not swallow or reshape that error.
    func testStreamChat_invalidBaseURL_stillThrowsBeforeEnsure() async {
        let session = SequenceRecordingSession()
        let client = NativeLMStudioClient(
            session: session,
            tokenResolver: StubLLMTokenResolver([:]),
            modelEnsurer: ChatModelEnsurer()
        )

        await drain(client.streamChat(
            config: LLMConfig(baseURLString: "not a valid url ://bad", modelName: "qwen"),
            messages: [ChatMessage(role: .user, content: "Hi")],
            tools: [],
            logger: nil,
            stepID: nil
        ))

        XCTAssertEqual(session.paths, [], "No request may be issued for an unusable base URL")
    }
}
