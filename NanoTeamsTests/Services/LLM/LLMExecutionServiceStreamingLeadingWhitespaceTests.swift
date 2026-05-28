import XCTest

@testable import NanoTeams

/// Pins the contract that `LLMExecutionService+Streaming` strips leading
/// whitespace from streamed assistant content while the buffer is still empty.
///
/// Background: some Harmony-format models on LM Studio emit a
/// `[reasoning]…[/reasoning]\n\n\n\nactual text` shape. The SSE parser
/// routes `[reasoning]…[/reasoning]` into `thinkingDelta`, but the
/// trailing newlines stay in `contentDelta` and render as a visible gap
/// in the live `SelectableMessageText` preview during streaming.
/// Post-commit cleanup (`ModelTokenCleaner.clean`) trims both ends, so
/// the persisted `step.llmConversation` content is already clean —
/// this strip is purely a streaming-preview fix.
///
/// Strip is gated on `assistantCollected.isEmpty`, so internal / trailing
/// whitespace are preserved once the first non-whitespace char is in.
@MainActor
final class LLMExecutionServiceStreamingLeadingWhitespaceTests: XCTestCase {

    private final class MockStreamClient: LLMClient, @unchecked Sendable {
        var deltas: [StreamEvent] = []
        /// When `true`, the stream finishes by throwing `CancellationError`
        /// after all `deltas` have been yielded. Drives the `catch is
        /// CancellationError` partial-commit branch in `performStreamingCall`.
        var finishCancelled: Bool = false

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            session: LLMSession?,
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let events = deltas
            let cancelAfter = finishCancelled
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                if cancelAfter {
                    continuation.finish(throwing: CancellationError())
                } else {
                    continuation.finish()
                }
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "test_step"
    private let taskID = 0

    override func setUp() {
        super.setUp()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        // Register step → task mapping so `taskIDForStep` resolves.
        service.executionStates[stepID] = LLMExecutionService.StepExecutionState(taskID: taskID)
    }

    override func tearDown() {
        service = nil
        mockDelegate = nil
        mockClient = nil
        super.tearDown()
    }

    // MARK: - Helper unit cases (boundary correctness)

    func testStripLeadingWhitespace_dropsLeadingNewlines() {
        XCTAssertEqual(
            LLMExecutionService.stripLeadingWhitespace("\n\n\n\nHello"),
            "Hello"
        )
    }

    func testStripLeadingWhitespace_dropsLeadingMixedWhitespace() {
        XCTAssertEqual(
            LLMExecutionService.stripLeadingWhitespace(" \t\nHi"),
            "Hi"
        )
    }

    func testStripLeadingWhitespace_pureWhitespaceCollapses() {
        XCTAssertEqual(LLMExecutionService.stripLeadingWhitespace("\n\n"), "")
    }

    func testStripLeadingWhitespace_preservesNonLeadingNewlines() {
        XCTAssertEqual(
            LLMExecutionService.stripLeadingWhitespace("Hello\n\nWorld"),
            "Hello\n\nWorld"
        )
    }

    func testStripLeadingWhitespace_preservesTrailingNewlines() {
        XCTAssertEqual(
            LLMExecutionService.stripLeadingWhitespace("\n\nHello\n\n"),
            "Hello\n\n"
        )
    }

    func testStripLeadingWhitespace_noOpOnNonWhitespacePrefix() {
        XCTAssertEqual(LLMExecutionService.stripLeadingWhitespace("Hello"), "Hello")
    }

    func testStripLeadingWhitespace_dropsNBSP() {
        XCTAssertEqual(LLMExecutionService.stripLeadingWhitespace("\u{00A0}Hi"), "Hi")
    }

    func testStripLeadingWhitespace_emptyInput() {
        XCTAssertEqual(LLMExecutionService.stripLeadingWhitespace(""), "")
    }

    /// `Character.isWhitespace` is Unicode-aware — line separator U+2028
    /// and paragraph separator U+2029 are dropped too. Some models emit
    /// these instead of `\n`.
    func testStripLeadingWhitespace_dropsUnicodeLineAndParagraphSeparators() {
        XCTAssertEqual(
            LLMExecutionService.stripLeadingWhitespace("\u{2028}\u{2029}Hi"),
            "Hi"
        )
    }

    // MARK: - End-to-end via mock stream

    /// Worst case for the rewind branch: the model answers with a pure
    /// tool-call envelope, no preamble. The `\n\n\n\n` between `[/reasoning]`
    /// and `<|call|>` would otherwise produce a 4-line empty preview that
    /// flashes until the tool-call is rendered. Strip collapses it to "".
    func testHarmonyEnvelope_pureToolCallAfterReasoning_stripsGapToEmpty() async throws {
        let thinkingText = "The user is asking me to check a log file for crashes. Let me read the attached log file first."
        let leadingGap = "\n\n\n\n"
        let toolCall = #"<|call|>{"name":"read_file","arguments":{"path": "report.log"}}<|end|>"#

        mockClient.deltas = [
            StreamEvent(thinkingDelta: "\n" + thinkingText + "\n\n"),
            StreamEvent(contentDelta: leadingGap),
            StreamEvent(contentDelta: toolCall)
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        // 1. Committed content must not start with newline.
        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        let committed = mockDelegate.commitStreamingCalls[0].2
        XCTAssertFalse(
            committed.hasPrefix("\n"),
            "committed content must not start with newline — got \(committed.debugDescription)"
        )
        // Pure tool-call response — visible section was only "\n\n\n\n",
        // strips to "". Commit posts an empty string.
        XCTAssertEqual(committed, "")

        // 2. Preview rewind happens with empty string (strip("\n\n\n\n") == "").
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls.count, 1)
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls[0].3, "")

        // 3. Thinking pipeline untouched — internal formatting preserved.
        XCTAssertEqual(
            mockDelegate.commitStreamingCalls[0].3,
            "\n" + thinkingText + "\n\n"
        )
    }

    /// Same shape as the user's screenshots: a reasoning block, then visible
    /// explanatory text, then a tool-call. The leading `\n\n\n\n` gap must
    /// disappear, but the `\n\n` between the text and `<|call|>` must
    /// survive as valid internal formatting.
    func testHarmonyEnvelope_visibleContentAfterReasoning_stripsLeadingNotInternal() async throws {
        let thinkingText = "The file is huge — about 1.1M lines. I should not read it whole; let me grep for crash markers first."
        let leadingGap = "\n\n\n\n"
        let visibleContent = "The file is very large. Let me search for crash-related keywords first."
        let toolCallGap = "\n\n"
        let toolCall = #"<|call|>{"name":"search","arguments":{"path": "report.log", "query": "crash"}}<|end|>"#

        mockClient.deltas = [
            StreamEvent(thinkingDelta: "\n" + thinkingText + "\n\n"),
            StreamEvent(contentDelta: leadingGap + visibleContent + toolCallGap + toolCall)
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        // 1. Committed starts with content, not whitespace. Note that the
        //    committed value goes through `ModelTokenCleaner.clean(_:)`, which
        //    `.trimmingCharacters(in: .whitespacesAndNewlines)`s BOTH ends —
        //    so the `\n\n` separator before `<|call|>` doesn't survive into
        //    `step.llmConversation`. That's existing behavior, not our fix.
        //    Our fix guarantees the LEADING whitespace doesn't leak into
        //    the *live preview* (see assertion 2 below).
        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        let committed = mockDelegate.commitStreamingCalls[0].2
        XCTAssertFalse(committed.hasPrefix("\n"))
        XCTAssertTrue(committed.hasPrefix("The file is very large"))
        XCTAssertEqual(committed, visibleContent)

        // 2. Preview rewind carries the leading-stripped string (but keeps
        //    trailing `\n\n` — `stripLeadingWhitespace` is leading-only by
        //    design, internal/trailing formatting may carry meaning).
        //    This is what fixes the visible gap in the activity feed bubble
        //    during streaming, before `ModelTokenCleaner` runs on commit.
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls.count, 1)
        XCTAssertEqual(
            mockDelegate.replaceStreamingPreviewCalls[0].3,
            visibleContent + toolCallGap
        )
        XCTAssertFalse(mockDelegate.replaceStreamingPreviewCalls[0].3.hasPrefix("\n"))

        // 3. Joined preview history doesn't leak a leading `\n` either,
        //    in case the first chunk was pure whitespace and flushPendingUI
        //    fired before the rewind branch.
        let allPreview = mockDelegate.appendStreamingPreviewCalls.map(\.3).joined()
        XCTAssertFalse(
            allPreview.hasPrefix("\n"),
            "preview history must not start with whitespace — got \(allPreview.prefix(20).debugDescription)"
        )
    }

    /// Worst case for `appendAssistant`: the first chunk contains only
    /// whitespace, the second contains the actual text. Before the strip,
    /// the first chunk would land in the preview and show a 4-line empty
    /// block until the second chunk arrived. After the strip, the
    /// whitespace-only chunk is dropped entirely.
    func testLeadingWhitespace_inSeparateChunk_isStripped() async throws {
        let body = "No matches were found for that query — let me try alternatives."
        mockClient.deltas = [
            StreamEvent(contentDelta: "\n\n\n\n"),  // pure-whitespace chunk
            StreamEvent(contentDelta: body)
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        // Whitespace chunk dropped entirely in appendAssistant
        // (strip "" → guard return). Only the real chunk reaches the preview.
        let allPreview = mockDelegate.appendStreamingPreviewCalls.map(\.3).joined()
        XCTAssertEqual(allPreview, body)

        // Committed content is clean too.
        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        XCTAssertEqual(mockDelegate.commitStreamingCalls[0].2, body)
    }

    /// The strip must NOT touch whitespace that appears once the buffer
    /// has any non-whitespace content. Paragraph breaks (`\n\n`) inside
    /// the body carry intentional formatting and must round-trip.
    func testInternalNewlines_preservedAfterFirstNonWhitespaceChar() async throws {
        let body = "First paragraph.\n\nSecond paragraph."
        mockClient.deltas = [
            StreamEvent(contentDelta: body),
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        XCTAssertEqual(mockDelegate.commitStreamingCalls[0].2, body)
    }

    /// Non-Harmony path: a single delta crosses `uiFlushCharThreshold`
    /// (200 chars) and lands via `flushPendingUI` → `appendAssistant`,
    /// not via the marker rewind. The strip lives inside `appendAssistant`
    /// so it must fire on this funnel too. Without this test, moving the
    /// strip out of `appendAssistant` onto an inline call site would
    /// silently regress the flush-threshold path.
    func testFlushThresholdPath_stripsLeadingWhitespace() async throws {
        let body = String(repeating: "x", count: 250)
        mockClient.deltas = [
            StreamEvent(contentDelta: "\n\n\n\n" + body)
            // No Harmony marker — rewind branch never fires.
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        // No rewind happened (no marker).
        XCTAssertTrue(mockDelegate.replaceStreamingPreviewCalls.isEmpty)

        // Joined preview history is clean — first chunk through the
        // flush funnel had its leading whitespace stripped.
        let allPreview = mockDelegate.appendStreamingPreviewCalls.map(\.3).joined()
        XCTAssertFalse(allPreview.hasPrefix("\n"))
        XCTAssertEqual(allPreview, body)

        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        XCTAssertEqual(mockDelegate.commitStreamingCalls[0].2, body)
    }

    /// Mid-stream cancellation: model emits leading whitespace then some
    /// content, then the stream is cancelled (e.g. user paused the run).
    /// The `catch is CancellationError` branch in `performStreamingCall`
    /// calls `commitStreamingContent` with the partial buffer. Pins that
    /// the strip already filtered into `assistantCollected` before the
    /// cancellation could fire — so the partial commit is clean too.
    func testCancellation_partialCommitHasNoLeadingWhitespace() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "\n\n\n\nHe"),
            // Stream throws CancellationError before any further deltas.
        ]
        mockClient.finishCancelled = true

        do {
            _ = try await service.performStreamingCall(
                stepID: stepID, roleForMessage: .codingAgent,
                client: mockClient, config: LLMConfig(),
                tools: [], conversationMessages: [], session: nil,
                networkLogger: nil
            )
            XCTFail("Expected CancellationError to propagate")
        } catch is CancellationError {
            // Expected — cancellation branch re-throws after committing.
        }

        // Partial commit ran with stripped buffer.
        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        let committed = mockDelegate.commitStreamingCalls[0].2
        XCTAssertFalse(committed.hasPrefix("\n"))
        XCTAssertEqual(committed, "He")
    }

    /// Whitespace-only stream that gets cancelled before any visible
    /// content arrives. Strip drops the chunk via the guard in
    /// `appendAssistant`, `assistantCollected` stays empty, partial commit
    /// posts an empty string (ModelTokenCleaner.clean("") == "").
    func testCancellation_whitespaceOnlyStreamCommitsEmpty() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "\n\n\n\n"),
        ]
        mockClient.finishCancelled = true

        do {
            _ = try await service.performStreamingCall(
                stepID: stepID, roleForMessage: .codingAgent,
                client: mockClient, config: LLMConfig(),
                tools: [], conversationMessages: [], session: nil,
                networkLogger: nil
            )
            XCTFail("Expected CancellationError to propagate")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        XCTAssertEqual(mockDelegate.commitStreamingCalls[0].2, "")
        // No preview was ever rendered for the whitespace-only chunk.
        XCTAssertTrue(mockDelegate.appendStreamingPreviewCalls.isEmpty)
    }

    /// Split-delta gate-closure: first chunk is whitespace + content
    /// (strip drops the leading `\n\n`, gate closes), second chunk is
    /// `\n\nMore` (strip does NOT fire, internal newlines preserved).
    /// Pins the contract that the strip's "fire only while empty" gate
    /// transitions correctly across chunk boundaries.
    func testSplitDelta_stripGateClosesAfterFirstNonWhitespaceChunk() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "\n\nHello"),
            StreamEvent(contentDelta: "\n\nWorld")
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        // Joined preview: first chunk stripped to "Hello", second chunk
        // delivered verbatim ("\n\nWorld") because the gate closed.
        let allPreview = mockDelegate.appendStreamingPreviewCalls.map(\.3).joined()
        XCTAssertEqual(allPreview, "Hello\n\nWorld")
    }
}
