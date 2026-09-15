import XCTest
@testable import NanoTeams

/// Every content delta that does not complete a Harmony envelope reaches the live preview as
/// it arrives — not when the NEXT delta happens to arrive.
///
/// Until 2026-09-13 the streaming loop batched content in `pendingUI` and decided whether to
/// flush only inside the delta handler: at 200 characters, or 0.2 s after the previous flush.
/// A delta that arrived early and small waited for the next one. That is invisible while
/// tokens flow and a stuck tail the moment a provider goes quiet with the request still open —
/// which is what native tool calling on Ollama does: `message.tool_calls` arrives whole, and
/// while the model writes the arguments the server sends nothing. MeditationApp task 111: the
/// Change Planner's preview read "…Now I'll write the" for 118 s while " Change Brief." sat in
/// the buffer; the Brief Critic's read "…to write the" for 204 s. The batching predated the
/// poll-driven feed — the preview is `@ObservationIgnored` and read by `LiveMessageBubble` every
/// 0.3 s — so it saved nothing.
@MainActor
final class StreamingContentTailDeliveryTests: XCTestCase {

    /// A provider the test drives: it yields what the test yields and keeps the request open
    /// until the test finishes it.
    private final class HeldOpenStreamClient: LLMClient, @unchecked Sendable {
        let stream: AsyncThrowingStream<StreamEvent, Error>

        init(stream: AsyncThrowingStream<StreamEvent, Error>) {
            self.stream = stream
        }

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            stream
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private let stepID = "test_step"
    private let taskID = 0

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] =
            LLMExecutionService.StepExecutionState()
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    /// Everything the content preview has been handed so far, in order.
    private var appendedPreview: String {
        mockDelegate.appendStreamingPreviewCalls.map(\.3).joined()
    }

    private func startCall(
        on stream: AsyncThrowingStream<StreamEvent, Error>
    ) -> Task<LLMExecutionService.StreamingResult, Error> {
        let client = HeldOpenStreamClient(stream: stream)
        return Task { @MainActor in
            try await self.service.performStreamingCall(
                stepID: self.stepID, taskID: self.taskID, roleForMessage: .softwareEngineer,
                client: client, config: LLMConfig(),
                tools: [], conversationMessages: [],
                networkLogger: nil)
        }
    }

    /// The reported shape: two small deltas in quick succession, then a provider that says
    /// nothing more while the request stays open.
    ///
    /// RED: restore the `pendingUI` batching (flush decided only when the next delta arrives) → the
    /// preview receives nothing before `finish()` and the `waitUntil` below times out.
    func testQuietProvider_lastDeltasReachThePreview_whileTheRequestIsStillOpen() async throws {
        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        continuation.yield(StreamEvent(contentDelta: "Now I'll write the"))
        continuation.yield(StreamEvent(contentDelta: " Change Brief."))
        let call = startCall(on: stream)

        await waitUntil("both deltas in the preview with the stream still open", timeoutSeconds: 3) {
            self.appendedPreview == "Now I'll write the Change Brief."
        }

        continuation.finish()
        let result = try await call.value
        XCTAssertEqual(result.assistantContent, "Now I'll write the Change Brief.")
        XCTAssertEqual(appendedPreview, "Now I'll write the Change Brief.",
                       "the end of the stream must not re-append what already reached the preview")
    }

    /// Corner: a single one-character delta followed by silence is still delivered.
    func testQuietProvider_singleShortDelta_reachesThePreview() async throws {
        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        continuation.yield(StreamEvent(contentDelta: "O"))
        let call = startCall(on: stream)

        await waitUntil("a one-character delta in the preview with the stream still open", timeoutSeconds: 3) {
            self.appendedPreview == "O"
        }

        continuation.finish()
        _ = try await call.value
    }

    /// Corner: delivering per delta must keep the leading-whitespace rule. A whitespace-only
    /// first delta reaches nothing, and the prose after it starts at its first character —
    /// the rule is gated on the COLLECTED buffer being empty, not on the delta.
    func testQuietProvider_whitespaceOnlyFirstDelta_previewStartsAtTheProse() async throws {
        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        continuation.yield(StreamEvent(contentDelta: "\n\n"))
        continuation.yield(StreamEvent(contentDelta: "\nHello"))
        let call = startCall(on: stream)

        await waitUntil("the prose in the preview with the stream still open", timeoutSeconds: 3) {
            self.appendedPreview == "Hello"
        }

        continuation.finish()
        let result = try await call.value
        XCTAssertEqual(result.assistantContent, "Hello")
    }

    /// Corner: the delta that completes a Harmony marker is not content. Prose before it is
    /// delivered while the request is open, the marker delta itself never reaches the content
    /// preview, and the rewind leaves exactly the prose on screen.
    func testQuietProvider_markerDelta_neverReachesTheContentPreview() async throws {
        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        continuation.yield(StreamEvent(contentDelta: "Text."))
        continuation.yield(StreamEvent(contentDelta: "<|call|>{\"name\":\"read_file\""))
        let call = startCall(on: stream)

        await waitUntil("the rewind to the prose with the envelope still open", timeoutSeconds: 3) {
            self.mockDelegate.replaceStreamingPreviewCalls.last?.3 == "Text."
        }
        XCTAssertEqual(appendedPreview, "Text.",
                       "only the prose may be appended — the marker delta routes to the envelope buffer")
        XCTAssertFalse(appendedPreview.contains("<|"))

        continuation.finish()
        let result = try await call.value
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertEqual(result.assistantContent, "Text.")
    }
}
