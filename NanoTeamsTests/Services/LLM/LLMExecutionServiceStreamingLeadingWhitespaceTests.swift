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
/// Two layers, two owners (2026-09-14): the SERVICE keeps the WIRE buffer
/// (`assistantCollected`) free of the leading gap and trims the rewind value; the
/// PREVIEW's edges belong to `StreamingPreviewManager`, which keeps `.content`
/// `clean`-normal at both ends on every route (see
/// `StreamingPreviewManagerTrailingWhitespaceTests`). This suite asserts on a
/// mock delegate, so it pins the service's half alone.
///
/// Two funnels, two rules — the distinction this suite exists to hold:
///
/// - GROWTH (`appendAssistant`): `stripLeadingWhitespace`, gated on
///   `assistantCollected.isEmpty`. Leading only, because a buffer that is
///   still growing may legitimately end in whitespace the next delta
///   continues from.
/// - REWIND (the marker branch): `stripSurroundingWhitespace`, BOTH ends.
///   Here the prose is final for the rest of the turn — every later delta
///   routes to the thinking pipe — so a trailing `\n\n` is a hanging tail
///   before an envelope the user never sees, and it renders as real empty
///   line fragments for the whole envelope-assembly window.
///
/// INTERNAL whitespace is preserved by both — see
/// `testInternalNewlines_preservedAfterFirstNonWhitespaceChar`.
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

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "test_step"
    private let taskID = 0

    override func setUp() async throws {
        try await super.setUp()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        // Register the (taskID, stepID) execution state so streaming resolves it.
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] =
            LLMExecutionService.StepExecutionState()
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        mockClient = nil
        try await super.tearDown()
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

    /// The set is `ModelTokenCleaner.edgeWhitespace` — what `clean` trims at commit — on
    /// SCALARS. Foundation's set contains U+200B (Unicode's `White_Space` does not), so a reply
    /// of one zero-width space is nothing to commit and must be nothing here too: until
    /// 2026-09-14 `Character.isWhitespace` kept it, `assistantCollected` was non-empty,
    /// `clean` emptied it, and the tokens-only nudge fired with no token in sight.
    func testStripLeadingWhitespace_dropsZeroWidthSpace_asCleanDoes() {
        XCTAssertEqual(LLMExecutionService.stripLeadingWhitespace("\u{200B}"), "")
        XCTAssertEqual(LLMExecutionService.stripLeadingWhitespace("\u{200B}\nHi"), "Hi")
        XCTAssertEqual(ModelTokenCleaner.clean("\u{200B}"), "", "the premise")
    }

    /// Scalars, not Characters: `" \u{301}"` is ONE Character (space + combining acute), which
    /// `Character.isWhitespace` dropped whole; `clean` keeps the mark, and so does this.
    func testStripLeadingWhitespace_cutsAtScalars_keepsACombiningMarkAfterASpace() {
        XCTAssertEqual(LLMExecutionService.stripLeadingWhitespace(" \u{0301}x"), "\u{0301}x")
        XCTAssertEqual(LLMExecutionService.stripLeadingWhitespace(" \u{0301}x"),
                       ModelTokenCleaner.clean(" \u{0301}x"))
    }

    /// The set is Unicode-aware — line separator U+2028 and paragraph
    /// separator U+2029 are dropped too. Some models emit these instead of `\n`.
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
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
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
    /// explanatory text, then a tool-call. BOTH the leading `\n\n\n\n` and the
    /// `\n\n` between the text and `<|call|>` must disappear from the preview.
    ///
    /// The trailing half was previously asserted the other way here, on the
    /// rationale that "internal/trailing formatting may carry meaning". That
    /// conflated internal with trailing: at the rewind the prose is FINAL
    /// (later deltas go to the thinking pipe), so the `\n\n` is not a
    /// paragraph break awaiting more text — it is what the user reported as a
    /// blank band under the bubble, held for the whole envelope assembly.
    /// Internal breaks keep their contract in
    /// `testInternalNewlines_preservedAfterFirstNonWhitespaceChar`.
    ///
    /// RED: revert `stripSurroundingWhitespace` to `stripLeadingWhitespace` at
    /// the rewind → assertions 2 and 3 fail together with the trailing `\n\n` back.
    ///
    /// Since 2026-09-14 the delegate argument IS `preMarker` — the value the wire
    /// keeps — so the rewind's one trim is what both assertions read: the preview
    /// is no longer trimmed a second time here. What the manager then shows (its
    /// own `clean`, trailing run held) is pinned by
    /// `StreamingPreviewManagerTrailingWhitespaceTests`.
    func testHarmonyEnvelope_visibleContentAfterReasoning_stripsLeadingAndTrailingNotInternal() async throws {
        let thinkingText = "The file is huge — about 1.1M lines. I should not read it whole; let me grep for crash markers first."
        let leadingGap = "\n\n\n\n"
        let visibleContent = "The file is very large. Let me search for crash-related keywords first."
        let toolCallGap = "\n\n"
        let toolCall = #"<|call|>{"name":"search","arguments":{"path": "report.log", "query": "crash"}}<|end|>"#

        mockClient.deltas = [
            StreamEvent(thinkingDelta: "\n" + thinkingText + "\n\n"),
            StreamEvent(contentDelta: leadingGap + visibleContent + toolCallGap + toolCall)
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
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

        // 2. Preview rewind carries the string trimmed at BOTH ends — this is
        //    what fixes the visible gap in the activity feed bubble during
        //    streaming, before `ModelTokenCleaner` runs on commit.
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls.count, 1)
        let rewound = mockDelegate.replaceStreamingPreviewCalls[0].3
        XCTAssertEqual(rewound, visibleContent)
        XCTAssertFalse(rewound.hasPrefix("\n"))
        XCTAssertFalse(
            rewound.hasSuffix("\n"),
            "the trailing gap is the reported blank band — it must not reach the preview"
        )
        // The point of matching `ModelTokenCleaner.clean`'s character set: the
        // bubble must not shift when the turn commits.
        XCTAssertEqual(rewound, committed,
                       "preview and committed content must be byte-identical")

        // 3. The `preMarker` trim itself, on the wire's side of the same value.
        XCTAssertEqual(
            result.assistantContent, visibleContent,
            "the rewind must trim its own buffer — the value both the wire and the preview's stream receive"
        )

        // 3. Joined preview history doesn't leak a leading `\n` either,
        //    in case the first chunk was pure whitespace and reached the
        //    preview before the rewind branch.
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
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
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
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        XCTAssertEqual(mockDelegate.commitStreamingCalls[0].2, body)
    }

    /// Non-Harmony path: a delta with no marker lands via `appendAssistant`
    /// directly, not via the marker rewind. The strip lives inside
    /// `appendAssistant`, so it must fire on this funnel too. Without this
    /// test, moving the strip out of `appendAssistant` onto an inline call
    /// site would silently regress the growth path.
    func testGrowthPath_stripsLeadingWhitespace() async throws {
        let body = String(repeating: "x", count: 250)
        mockClient.deltas = [
            StreamEvent(contentDelta: "\n\n\n\n" + body)
            // No Harmony marker — rewind branch never fires.
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
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
                stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
                client: mockClient, config: LLMConfig(),
                tools: [], conversationMessages: [],
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
                stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
                client: mockClient, config: LLMConfig(),
                tools: [], conversationMessages: [],
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
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        // Joined preview: first chunk stripped to "Hello", second chunk
        // delivered verbatim ("\n\nWorld") because the gate closed.
        let allPreview = mockDelegate.appendStreamingPreviewCalls.map(\.3).joined()
        XCTAssertEqual(allPreview, "Hello\n\nWorld")
    }

    // MARK: - Rewind: trailing half of the same defect class

    func testStripSurroundingWhitespace_dropsBothEnds() {
        XCTAssertEqual(
            LLMExecutionService.stripSurroundingWhitespace("\n\nHello\n\n"),
            "Hello"
        )
    }

    func testStripSurroundingWhitespace_preservesInternalNewlines() {
        XCTAssertEqual(
            LLMExecutionService.stripSurroundingWhitespace("Hello\n\nWorld\n"),
            "Hello\n\nWorld"
        )
    }

    /// The reported symptom, end to end: prose, then the model's `\n\n`, then
    /// the envelope. The rewind must hand the bubble prose with no tail — the
    /// blank band was ~2 empty mono lines held for the whole assembly window.
    ///
    /// RED: `stripSurroundingWhitespace` → `stripLeadingWhitespace` at the
    /// rewind → preview is `prose + "\n\n"` and both assertions fail.
    func testRewind_trailingGapBeforeEnvelope_doesNotReachThePreview() async throws {
        let prose = "Now let me read the rest of building_gallery.gd and the remaining files."
        mockClient.deltas = [
            StreamEvent(contentDelta: prose + "\n\n"
                + #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#)
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls.count, 1)
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls[0].3, prose)
        // Anti-vacuum: the prose survives whole — the trim must not be
        // eating content on its way to "no trailing whitespace".
        XCTAssertEqual(result.assistantContent, prose)
    }

    /// No whitespace before the marker ⇒ byte-identical behaviour to before
    /// the fix. This is the guard on WHICH character set the rewind trims:
    /// the plan's whole design choice is that it matches
    /// `ModelTokenCleaner.clean`'s, so preview and committed agree.
    ///
    /// RED: widen `stripSurroundingWhitespace` past whitespace — e.g.
    /// `.whitespacesAndNewlines.union(.punctuationCharacters)` → the prose
    /// loses its terminal `.` and the preview no longer matches what the
    /// model actually said.
    func testRewind_noWhitespaceBeforeEnvelope_isUnchanged() async throws {
        let prose = "Applying the change now."
        mockClient.deltas = [
            StreamEvent(contentDelta: prose
                + #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#)
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls[0].3, prose)
    }

    /// `uiBuffer` holds RAW deltas, and so does the manager's stream: the rewind hands the
    /// manager the pre-marker text with its tokens IN — the same bytes `assistantCollected`
    /// keeps — and the manager derives the display (`ModelTokenCleaner.clean`) and re-seeds its
    /// stream from them. `<|end|>` is not in `harmonyMarkers`, so it can legitimately precede
    /// the earliest one; what reaches the SCREEN is the manager's business, pinned end to end by
    /// `StreamingActivityWiringTests.testHarmonyRewind_strayTokenBeforeTheMarker_screenShowsTheProse`.
    ///
    /// RED: strip the tokens before the delegate call (the shape until 2026-09-14) → the
    /// argument no longer equals `assistantContent`, and a seed `clean` already touched is a
    /// different stream than the one commit strips (`clean` is not idempotent).
    func testRewind_handsTheManagerTheRawPreMarker_tokensIncluded() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Done thinking.<|end|>\n\n"
                + #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#)
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        let rewound = mockDelegate.replaceStreamingPreviewCalls[0].3
        XCTAssertEqual(rewound, "Done thinking.<|end|>", "whitespace trimmed, tokens kept — the wire's value")
        XCTAssertEqual(rewound, result.assistantContent, "one truth for the wire and for the preview's stream")
    }

    /// The regression guard for the fix's own scope: `+StepFlowControl`'s
    /// tokens-only retry fires on `!assistantContent.isEmpty &&
    /// clean(assistantContent).isEmpty`. Folding `stripTokens` into
    /// `assistantCollected` would make that branch unreachable, so the rewind
    /// must leave tokens in place on the result. The token strip for the SCREEN
    /// belongs to the manager: the service hands it the same tokens-included value.
    ///
    /// RED: apply `stripTokens` to `assistantCollected` → the result is
    /// empty and the diagnostic silently dies.
    func testRewind_tokensOnlyProse_staysDetectableAsTokensOnly() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "<|end|>\n\n"
                + #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#)
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertFalse(result.assistantContent.isEmpty,
                       "pre-cleaning here kills the tokens-only retry in +StepFlowControl")
        XCTAssertTrue(ModelTokenCleaner.clean(result.assistantContent).isEmpty,
                      "…and it must still clean to empty, or the branch never fires")
    }
}
