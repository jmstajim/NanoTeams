import XCTest
@testable import NanoTeams

/// Pins `TeamActivityFeedView.resolveBubbleInputs(msg:streaming:)` —
/// the static helper that maps `(LLMMessage, StreamingSnapshot)` into
/// the typed `BubbleInputs` discriminated union the dispatcher
/// forwards to `MessageBubbleView`.
///
/// Critical behaviors pinned here:
/// - Streaming branch carries content/progress, NOT attachments.
/// - Committed `.supervisorMessage` strips embedded marker sections
///   and surfaces them as structured paths/clips.
/// - Committed non-supervisor messages preserve the verbatim text
///   (no marker stripping leaks across source-context boundaries).
@MainActor
final class TeamActivityFeedBubbleResolutionTests: XCTestCase {

    typealias StreamingSnapshot = TeamActivityFeedView.StreamingSnapshot

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Streaming branch

    func testResolveBubbleInputs_streaming_returnsStreamingCase() async {
        let msg = LLMMessage(role: .assistant, content: "committed text — should be ignored")
        let snap = StreamingSnapshot(
            isStreaming: true,
            content: "live tokens…",
            thinking: "internal monologue",
            processingStatus: .fraction(0.42),
            hasStreamActivity: true,
            isStreamingToolCall: false
        )
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: msg, streaming: snap)
        guard case .streaming(let content, let thinking, let progress, let hasActivity, let toolCall) = inputs else {
            return XCTFail("Expected .streaming case, got \(inputs)")
        }
        XCTAssertEqual(content, "live tokens…")
        XCTAssertEqual(thinking, "internal monologue")
        XCTAssertEqual(progress, .fraction(0.42))
        XCTAssertTrue(hasActivity)
        XCTAssertFalse(toolCall)
    }

    /// Streaming branch must NOT inherit attachments from the message body
    /// — they belong to the committed turn only. A future refactor that
    /// "helpfully" pulled paths from the streaming msg would silently
    /// surface a stripped marker block in the streaming bubble.
    func testResolveBubbleInputs_streaming_doesNotLeakAttachments() async {
        let raw = """
        Supervisor:
        body text

        ## Attached Files
        /path/to/file.swift
        """
        let msg = LLMMessage(
            role: .user, content: raw,
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        let snap = StreamingSnapshot(
            isStreaming: true,
            content: "still streaming…",
            thinking: nil,
            processingStatus: nil,
            hasStreamActivity: true,
            isStreamingToolCall: false
        )
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: msg, streaming: snap)
        // The discriminated union enforces this at compile time: a
        // `.streaming` case has no `attachmentPaths`/`clippedTexts`
        // fields. We pin runtime that the branch resolves to `.streaming`
        // (not `.committed` with the marker-stripped body of the message).
        guard case .streaming = inputs else {
            return XCTFail("Streaming snapshot must resolve to .streaming, not the committed body of the message.")
        }
    }

    /// Streaming with nil content snapshot → committed-fallback to empty
    /// string. Important because `streamingContent(stepID:taskID:)` returns
    /// `Optional` from the manager.
    func testResolveBubbleInputs_streaming_nilContent_isEmptyString() async {
        let msg = LLMMessage(role: .assistant, content: "")
        let snap = StreamingSnapshot(
            isStreaming: true,
            content: nil,
            thinking: nil,
            processingStatus: nil,
            hasStreamActivity: false,
            isStreamingToolCall: false
        )
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: msg, streaming: snap)
        guard case .streaming(let content, _, _, _, _) = inputs else {
            return XCTFail("Expected .streaming")
        }
        XCTAssertEqual(content, "", "nil streaming content must resolve to empty string.")
    }

    /// The tool-call flag must carry through the streaming branch — it
    /// keeps the Thinking loader animating during envelope assembly (the
    /// envelope text streams into the thinking preview) and backs the
    /// indicator's "Generating" fallback while that preview is empty.
    func testResolveBubbleInputs_streaming_carriesStreamingToolCall() async {
        let msg = LLMMessage(role: .assistant, content: "")
        let snap = StreamingSnapshot(
            isStreaming: true,
            content: "I will now implement the fix.",
            thinking: "reasoning…",
            processingStatus: nil,
            hasStreamActivity: true,
            isStreamingToolCall: true
        )
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: msg, streaming: snap)
        guard case .streaming(_, _, _, _, let toolCall) = inputs else {
            return XCTFail("Expected .streaming case")
        }
        XCTAssertTrue(toolCall)
        XCTAssertTrue(inputs.isStreamingToolCall, "Accessor must surface the flag for the streaming case")
    }

    /// Committed bubbles structurally cannot show a stale "Generating":
    /// the `.committed` case has no tool-call slot and the accessor
    /// hard-returns false, regardless of what the manager's dictionaries
    /// hold at poll time.
    func testBubbleInputs_committed_isStreamingToolCallIsFalse() async {
        let msg = LLMMessage(role: .assistant, content: "done")
        let snap = StreamingSnapshot(
            isStreaming: false, content: nil, thinking: nil,
            processingStatus: nil, hasStreamActivity: false,
            isStreamingToolCall: true  // stale manager state must be discarded
        )
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: msg, streaming: snap)
        guard case .committed = inputs else {
            return XCTFail("Expected .committed case")
        }
        XCTAssertFalse(inputs.isStreamingToolCall,
                       "Committed accessor must hard-return false — no stale 'Generating' on committed bubbles")
    }

    // MARK: - Committed branch

    /// Committed `.supervisorMessage`: leading `Supervisor:\n` prefix
    /// stripped via `displayContent`, then `## Attached Files` and
    /// `## Clipped Text` marker sections extracted via
    /// `stripAttachedFiles`. Resulting BubbleInputs:
    /// - `content` = clean user text only
    /// - `attachmentPaths` = extracted paths
    /// - `clippedTexts` = extracted clip bodies
    func testResolveBubbleInputs_committedSupervisorMessage_stripsMarkers() async {
        // Order matters: stripAttachedFiles extracts the file section FIRST
        // and discards everything after the separator, so Clipped Text must
        // appear BEFORE Attached Files in the producer-emitted body.
        // Mirrors ActivityFeedBuilderTests fixture conventions.
        let raw = """
        Supervisor:
        Look at this please

        ## Clipped Text
        let x = 1

        ## Attached Files
        - /path/to/file.swift
        """
        let msg = LLMMessage(
            role: .user, content: raw,
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        let snap = StreamingSnapshot(
            isStreaming: false, content: nil, thinking: nil,
            processingStatus: nil, hasStreamActivity: false,
            isStreamingToolCall: false
        )
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: msg, streaming: snap)
        guard case .committed(let content, _, let paths, let clips) = inputs else {
            return XCTFail("Expected .committed case")
        }
        XCTAssertFalse(content.contains("## Attached Files"),
                       "Marker section must be stripped from displayed text.")
        XCTAssertFalse(content.contains("## Clipped Text"))
        XCTAssertFalse(content.contains("Supervisor:"),
                       "Leading Supervisor: prefix must be stripped via displayContent.")
        XCTAssertEqual(paths, ["/path/to/file.swift"])
        XCTAssertEqual(clips, ["let x = 1"])
    }

    /// Committed `.supervisorAnswer` (the durable bubble an unpaired
    /// escalation / Autovisor idle-park answer renders as): the leading
    /// `Supervisor answer: ` marker strips via `displayContent`, and embedded
    /// attachment/clip marker sections extract into structured fields —
    /// same treatment as `.supervisorMessage`.
    func testResolveBubbleInputs_supervisorAnswer_stripsAttachmentMarkers() async {
        let raw = """
        Supervisor answer: Проверь этот файл

        ## Clipped Text
        let x = 1

        ## Attached Files
        - /path/to/file.swift
        """
        let msg = LLMMessage(
            role: .user, content: raw,
            sourceRole: .supervisor, sourceContext: .supervisorAnswer
        )
        let snap = StreamingSnapshot(
            isStreaming: false, content: nil, thinking: nil,
            processingStatus: nil, hasStreamActivity: false,
            isStreamingToolCall: false
        )
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: msg, streaming: snap)
        guard case .committed(let content, _, let paths, let clips) = inputs else {
            return XCTFail("Expected .committed case")
        }
        XCTAssertFalse(content.contains("Supervisor answer:"),
                       "Leading answer marker must be stripped via displayContent.")
        XCTAssertFalse(content.contains("## Attached Files"))
        XCTAssertFalse(content.contains("## Clipped Text"))
        XCTAssertEqual(paths, ["/path/to/file.swift"])
        XCTAssertEqual(clips, ["let x = 1"])
    }

    /// Committed non-supervisor messages must NOT strip marker text. A
    /// regular assistant message that happens to contain
    /// "## Attached Files" verbatim renders verbatim — the strip
    /// path is supervisor-only.
    func testResolveBubbleInputs_committedRegularMessage_doesNotStripMarkers() async {
        let raw = "Here's the format: ## Attached Files\n- /foo"
        let msg = LLMMessage(role: .assistant, content: raw, sourceContext: nil)
        let snap = StreamingSnapshot(
            isStreaming: false, content: nil, thinking: nil,
            processingStatus: nil, hasStreamActivity: false,
            isStreamingToolCall: false
        )
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: msg, streaming: snap)
        guard case .committed(let content, _, let paths, let clips) = inputs else {
            return XCTFail("Expected .committed case")
        }
        XCTAssertEqual(content, raw,
                       "Non-supervisor messages must render verbatim — no marker stripping.")
        XCTAssertTrue(paths.isEmpty)
        XCTAssertTrue(clips.isEmpty)
    }

    /// Committed branch propagates `msg.thinking` through the inputs.
    /// nil in → nil out.
    func testResolveBubbleInputs_committedNilThinking_propagates() async {
        let msg = LLMMessage(role: .assistant, content: "x", thinking: nil)
        let snap = StreamingSnapshot(
            isStreaming: false, content: nil, thinking: nil,
            processingStatus: nil, hasStreamActivity: false,
            isStreamingToolCall: false
        )
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: msg, streaming: snap)
        guard case .committed(_, let thinking, _, _) = inputs else {
            return XCTFail("Expected .committed case")
        }
        XCTAssertNil(thinking, "nil msg.thinking must propagate as nil into BubbleInputs.committed.")
    }
}
