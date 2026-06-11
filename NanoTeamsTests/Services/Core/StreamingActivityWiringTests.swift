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
        NTMSOrchestrator(
            repository: NTMSRepository(),
            searchEmbeddingClient: StubSearchEmbeddingClient()
        )
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

    /// Token deltas through `appendStreamingPreview` ALSO mark activity
    /// — covers the case where content streams normally but the UI hasn't
    /// flushed `pendingUI` yet (uiFlushInterval=0.2s); the indicator
    /// should already say "Generating" even with empty preview.
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
}
