import XCTest
@testable import NanoTeams

/// Pin: orchestrator's streaming-delegate methods (`appendStreamingPreview`,
/// `appendStreamingThinking`, `replaceStreamingPreview`,
/// `markStreamActivity`) all flip
/// `streamingPreviewManager.hasReceivedStreamActivity(stepID:taskID:)` to true. This
/// is the wiring that drives the UI's "Waiting" → "Generating" status
/// transition. Without these hooks the streaming-service-side
/// `delegate.markStreamActivity(stepID:taskID:)` calls would be no-ops in
/// production.
@MainActor
final class StreamingActivityWiringTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        TestOrchestrator.make()
    }

    // MARK: - Direct markStreamActivity

    func testMarkStreamActivity_setsManagerFlag() async {
        let store = makeOrchestrator()
        XCTAssertFalse(store.streamingPreviewManager.hasReceivedStreamActivity(stepID: "stepX", taskID: 0))

        store.markStreamActivity(stepID: "stepX", taskID: 0)

        XCTAssertTrue(
            store.streamingPreviewManager.hasReceivedStreamActivity(stepID: "stepX", taskID: 0),
            "Direct markStreamActivity on the orchestrator must propagate to the manager — the streaming service uses this path for tool-call/harmony deltas"
        )
    }

    // MARK: - Direct markStreamingToolCall

    func testMarkStreamingToolCall_setsManagerFlag() async {
        let store = makeOrchestrator()
        XCTAssertFalse(store.streamingPreviewManager.isStreamingToolCall(stepID: "stepX", taskID: 0))

        store.markStreamingToolCall(stepID: "stepX", taskID: 0)

        XCTAssertTrue(
            store.streamingPreviewManager.isStreamingToolCall(stepID: "stepX", taskID: 0),
            "Direct markStreamingToolCall on the orchestrator must propagate to the manager — the streaming service uses this path on harmony-marker detection and OpenAI tool-call deltas"
        )
    }

    func testClearStreamingPreview_clearsStreamingToolCall() async {
        let store = makeOrchestrator()
        store.markStreamingToolCall(stepID: "stepY", taskID: 0)
        XCTAssertTrue(store.streamingPreviewManager.isStreamingToolCall(stepID: "stepY", taskID: 0))

        store.clearStreamingPreview(stepID: "stepY", taskID: 0)

        XCTAssertFalse(
            store.streamingPreviewManager.isStreamingToolCall(stepID: "stepY", taskID: 0),
            "clearStreamingPreview must remove the tool-call flag — an abandoned stream must not show a false 'Generating' on the next session"
        )
    }

    // MARK: - Side-effect of preview/thinking append

    /// Token deltas through `appendStreamingPreview` ALSO mark activity —
    /// the orchestrator stamps it on the content path itself, so the flag does
    /// not depend on the streaming service remembering its paired
    /// `markStreamActivity` call.
    func testAppendStreamingPreview_marksActivity() async {
        let store = makeOrchestrator()
        let messageID = UUID()

        store.appendStreamingPreview(
            stepID: "stepA",
            taskID: 0,
            messageID: messageID,
            role: .softwareEngineer,
            content: "hello"
        )

        XCTAssertTrue(
            store.streamingPreviewManager.hasReceivedStreamActivity(stepID: "stepA", taskID: 0),
            "appendStreamingPreview must mark activity — content path"
        )
    }

    func testAppendStreamingThinking_marksActivity() async {
        let store = makeOrchestrator()

        store.appendStreamingThinking(stepID: "stepB", taskID: 0, content: "thinking...")

        XCTAssertTrue(
            store.streamingPreviewManager.hasReceivedStreamActivity(stepID: "stepB", taskID: 0),
            "appendStreamingThinking must mark activity — thinking path"
        )
    }

    /// `replaceStreamingPreview` is the rewind hook used when a Harmony
    /// tool-call marker is detected mid-flush. It also signals stream
    /// activity (the model is producing tokens, just under a marker
    /// envelope).
    func testReplaceStreamingPreview_marksActivity() async {
        let store = makeOrchestrator()
        let messageID = UUID()
        // Seed a preview directly on the manager — orchestrator's
        // beginStreaming is async + requires a real taskID; the manager-
        // level setup is enough to exercise replaceStreamingPreview.
        store.streamingPreviewManager.beginStreaming(
            stepID: "stepC", taskID: 0, messageID: messageID, role: .softwareEngineer
        )

        store.replaceStreamingPreview(
            stepID: "stepC",
            taskID: 0,
            messageID: messageID,
            role: .softwareEngineer,
            content: ""
        )

        XCTAssertTrue(
            store.streamingPreviewManager.hasReceivedStreamActivity(stepID: "stepC", taskID: 0),
            "replaceStreamingPreview must mark activity — the rewind path runs on every harmony-marker detection"
        )
    }

    // MARK: - Lifecycle: commit clears activity

    /// Orchestrator's `commitStreaming` finalizes a message and the
    /// underlying `streamingPreviewManager.commit` clears activity. The
    /// next stream on the same stepID starts from "Waiting" again.
    func testCommitStreaming_clearsActivity() async {
        let store = makeOrchestrator()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-stream-activity-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "x")!
        await store.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "stepD", role: .softwareEngineer, title: "Step")
            ])]
        }
        let messageID = UUID()
        store.appendStreamingPreview(
            stepID: "stepD", taskID: taskID, messageID: messageID,
            role: .softwareEngineer, content: "hello"
        )
        XCTAssertTrue(store.streamingPreviewManager.hasReceivedStreamActivity(stepID: "stepD", taskID: 0))

        await store.commitStreaming(stepID: "stepD", taskID: taskID, content: "hello", thinking: nil)

        XCTAssertFalse(
            store.streamingPreviewManager.hasReceivedStreamActivity(stepID: "stepD", taskID: 0),
            "commitStreaming must clear hasStreamActivity along with the preview/thinking/progress state — next stream starts clean"
        )
    }

    func testClearStreamingPreview_clearsActivity() async {
        let store = makeOrchestrator()
        store.markStreamActivity(stepID: "stepE", taskID: 0)
        XCTAssertTrue(store.streamingPreviewManager.hasReceivedStreamActivity(stepID: "stepE", taskID: 0))

        store.clearStreamingPreview(stepID: "stepE", taskID: 0)

        XCTAssertFalse(
            store.streamingPreviewManager.hasReceivedStreamActivity(stepID: "stepE", taskID: 0),
            "clearStreamingPreview must remove the activity flag — abandoned/cancelled streams must not poison the next session"
        )
    }

    /// A whitespace-only content delta is HELD by the manager rather than rendered
    /// (`StreamingPreviewManagerTrailingWhitespaceTests`), but it is still server activity:
    /// the orchestrator stamps the clock on the content path itself, so the Autovisor's
    /// stuck detector must not read a burst of inter-call newlines as silence.
    func testAppendStreamingPreview_whitespaceOnlyDelta_isHeldButStillMarksActivity() async {
        let store = makeOrchestrator()
        let messageID = UUID()
        store.streamingPreviewManager.beginStreaming(
            stepID: "stepF", taskID: 0, messageID: messageID, role: .softwareEngineer)
        store.appendStreamingPreview(
            stepID: "stepF", taskID: 0, messageID: messageID, role: .softwareEngineer, content: "prose")
        let stampedAfterProse = store.streamingPreviewManager.lastStreamActivity(stepID: "stepF", taskID: 0)

        store.appendStreamingPreview(
            stepID: "stepF", taskID: 0, messageID: messageID, role: .softwareEngineer, content: "\n")

        XCTAssertEqual(store.streamingPreviewManager.streamingContent(stepID: "stepF", taskID: 0), "prose",
                       "the newline is held, not rendered")
        let stampedAfterNewline = store.streamingPreviewManager.lastStreamActivity(stepID: "stepF", taskID: 0)
        XCTAssertNotNil(stampedAfterNewline)
        XCTAssertGreaterThan(stampedAfterNewline!, stampedAfterProse!,
                             "a held delta must still refresh the activity clock")
    }

    // MARK: - Service → orchestrator → manager: the native tool-call window end to end

    /// A provider the test drives: it yields what the test yields and keeps the request open
    /// until the test finishes it.
    private final class HeldOpenStreamClient: LLMClient, @unchecked Sendable {
        let stream: AsyncThrowingStream<StreamEvent, Error>

        init(stream: AsyncThrowingStream<StreamEvent, Error>) {
            self.stream = stream
        }

        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            logger: NetworkLogger?, stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            stream
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    /// The untouched streaming service against the REAL manager, in the parser's own event
    /// shape (`OpenAIChatChunkParser` emits `.contentDelta("\n")` and `.toolCallDeltas` as
    /// separate events): prose, the template's newline, a native call, two more newlines.
    /// While the request is open the preview reads exactly the prose and the tool-call flag
    /// is up; after the stream closes the committed turn carries the same bytes that were on
    /// screen. The guard against a future "helpful" trim in `appendAssistant` — the service
    /// forwards every delta verbatim, and the manager is what keeps the band off screen.
    func testNativeToolCallTurn_previewEndsWithoutTheTemplateNewlines_untilTheStreamCloses() async throws {
        let store = makeOrchestrator()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-native-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "x")!
        let stepID = "ultra_team_change_planner"
        await store.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: stepID, role: .softwareEngineer, title: "Step")
            ])]
        }
        store.llmExecutionService._testRegisterStepTask(stepID: stepID, taskID: taskID)

        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        continuation.yield(StreamEvent(contentDelta: "prose"))
        continuation.yield(StreamEvent(contentDelta: "\n"))
        continuation.yield(StreamEvent(toolCallDeltas: [
            .init(index: 0, id: "c1", name: "read_file", argumentsDelta: #"{"path":"a"}"#)
        ]))
        continuation.yield(StreamEvent(contentDelta: "\n"))
        continuation.yield(StreamEvent(contentDelta: "\n"))
        let client = HeldOpenStreamClient(stream: stream)
        let call = Task { @MainActor in
            try await store.llmExecutionService.performStreamingCall(
                stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
                client: client, config: LLMConfig(), tools: [], conversationMessages: [],
                networkLogger: nil)
        }

        await waitUntil("the prose on screen, the call flagged, the request still open", timeoutSeconds: 3) {
            store.streamingPreviewManager.streamingContent(stepID: stepID, taskID: taskID) == "prose"
                && store.streamingPreviewManager.isStreamingToolCall(stepID: stepID, taskID: taskID)
                && store.streamingPreviewManager.streamingThinking(stepID: stepID, taskID: taskID)?.contains("read_file") == true
        }
        XCTAssertFalse(
            store.streamingPreviewManager.streamingContent(stepID: stepID, taskID: taskID)?.hasSuffix("\n") ?? true,
            "the template's newlines must be held off screen for the whole tool-call window")

        continuation.finish()
        let result = try await call.value
        XCTAssertEqual(result.assistantContent, "prose\n\n\n",
                       "the service forwards every byte; the wire/commit trim is `clean`'s")
        XCTAssertEqual(result.resolvedToolCalls.map(\.name), ["read_file"])
        let turn = store.loadedTask(taskID)?.runs.last?.steps
            .first { $0.id == stepID }?.llmConversation.last { $0.role == .assistant }
        XCTAssertEqual(turn?.content, "prose", "committed content is byte-identical to what was on screen")
        XCTAssertNil(store.streamingPreviewManager.streamingContent(stepID: stepID, taskID: taskID))
    }

    /// The rewind seam, end to end: a stray `<|end|>` before the Harmony marker rides the RAW
    /// pre-marker text into the manager (the service strips whitespace only), which strips it
    /// for the screen and keeps the raw bytes as its stream — the bubble reads the prose while
    /// the envelope is still open, and the committed turn is the same bytes.
    func testHarmonyRewind_strayTokenBeforeTheMarker_screenShowsTheProse() async throws {
        let store = makeOrchestrator()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-harmony-rewind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "x")!
        let stepID = "ultra_team_change_planner"
        await store.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: stepID, role: .softwareEngineer, title: "Step")
            ])]
        }
        store.llmExecutionService._testRegisterStepTask(stepID: stepID, taskID: taskID)

        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        continuation.yield(StreamEvent(contentDelta: "Done thinking.<|end|>\n\n"))
        continuation.yield(StreamEvent(contentDelta: #"<|call|>{"name":"git_status","arguments":{}}"#))
        let client = HeldOpenStreamClient(stream: stream)
        let call = Task { @MainActor in
            try await store.llmExecutionService.performStreamingCall(
                stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
                client: client, config: LLMConfig(), tools: [], conversationMessages: [],
                networkLogger: nil)
        }

        await waitUntil("the prose on screen — token and gap stripped by the manager — with the envelope open", timeoutSeconds: 3) {
            store.streamingPreviewManager.streamingContent(stepID: stepID, taskID: taskID) == "Done thinking."
                && store.streamingPreviewManager.isStreamingToolCall(stepID: stepID, taskID: taskID)
        }

        continuation.yield(StreamEvent(contentDelta: "<|end|>"))
        continuation.finish()
        let result = try await call.value
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertEqual(result.assistantContent, "Done thinking.<|end|>",
                       "the service keeps the token for the tokens-only diagnostic; only whitespace is trimmed")
        let turn = store.loadedTask(taskID)?.runs.last?.steps
            .first { $0.id == stepID }?.llmConversation.last { $0.role == .assistant }
        XCTAssertEqual(turn?.content, "Done thinking.", "committed content is what was on screen")
    }
}
