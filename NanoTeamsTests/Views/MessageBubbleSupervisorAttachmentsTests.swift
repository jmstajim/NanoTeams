import XCTest
@testable import NanoTeams

/// Pin: the user-facing contract for rendering `.supervisorMessage` bubbles.
///
/// Two producers tag messages with `sourceContext == .supervisorMessage`:
/// 1. `NTMSOrchestrator.consumeQueuedSupervisorMessage` — queued chat delivery
///    while a role is working. Wraps text + clips + non-embedded paths in
///    `## Clipped Text` / `## Attached Files` marker sections.
/// 2. `LLMExecutionService.injectForwardedMessageIntoChild` — `forward_to_team`
///    handler. Plain text only.
///
/// Both flow through `TeamActivityFeedView.messageBubble` non-streaming branch,
/// which composes `LLMMessage.displayContent` (strips `Supervisor:\n` prefix)
/// with `ActivityFeedBuilder.stripAttachedFiles` (extracts marker payloads).
/// The cleaned text + extracted paths/clips are then forwarded to
/// `MessageBubbleView`'s new `attachmentPaths`/`clippedTexts`/`workFolderURL`
/// params, which delegate rendering to the same `ReadOnlyAttachmentGrid`
/// already used by `SupervisorTaskItemView` and `SupervisorInputCard`.
///
/// These tests pin the (`displayContent` → `stripAttachedFiles`) composition
/// so a regression can't silently send raw `## Attached Files` text into
/// the bubble (see screenshot in zany-stargazing-thunder.md plan for the
/// regression we're guarding against).
@MainActor
final class MessageBubbleSupervisorAttachmentsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Helpers

    /// Mimics `consumeQueuedSupervisorMessage`'s output shape: full prefix +
    /// optional body + optional clip section + optional `## Attached Files`
    /// section. Returns the (cleaned text, paths, clips) the bubble actually receives.
    private func bubbleInputs(forContent content: String, sourceContext: MessageSourceContext = .supervisorMessage) -> (text: String?, paths: [String], clippedTexts: [String]) {
        let msg = LLMMessage(
            role: .user,
            content: content,
            sourceRole: .supervisor,
            sourceContext: sourceContext
        )
        return ActivityFeedBuilder.stripAttachedFiles(from: msg.displayContent)
    }

    // MARK: - Queued chat: user types text + attaches a non-embedded file

    /// Most common scenario: user types a message, drops a screenshot, hits Send.
    /// Activity feed should show their text + a thumbnail card — never the raw
    /// `## Attached Files` line.
    func testQueuedChat_textPlusOneFile_extractsPathAndCleansText() {
        let content = """
        Supervisor:
        что на этой картинке?

        ## Attached Files
        - .nanoteams/tasks/1/attachments/Screenshot-2026-05-04-152318837.png
        """

        let result = bubbleInputs(forContent: content)

        XCTAssertEqual(result.text, "что на этой картинке?", "Display text must contain only the user's typed message — no marker sections")
        XCTAssertEqual(result.paths, [".nanoteams/tasks/1/attachments/Screenshot-2026-05-04-152318837.png"])
        XCTAssertEqual(result.clippedTexts, [])
    }

    func testQueuedChat_textPlusMultipleFiles_extractsAllPaths() {
        let content = """
        Supervisor:
        review these

        ## Attached Files
        - .nanoteams/tasks/2/attachments/a.png
        - .nanoteams/tasks/2/attachments/b.swift
        - .nanoteams/tasks/2/attachments/c.pdf
        """

        let result = bubbleInputs(forContent: content)

        XCTAssertEqual(result.text, "review these")
        XCTAssertEqual(result.paths, [
            ".nanoteams/tasks/2/attachments/a.png",
            ".nanoteams/tasks/2/attachments/b.swift",
            ".nanoteams/tasks/2/attachments/c.pdf"
        ])
        XCTAssertEqual(result.clippedTexts, [])
    }

    // MARK: - Queued chat: only attachments, no typed text

    /// Edge case from dive-deeper finding #3: user attaches a file, types nothing.
    /// `consumeQueuedSupervisorMessage` produces `Supervisor:\n\n## Attached Files\n- path`
    /// — the builder's empty-skip guard sees raw content as non-empty, so the
    /// message survives. After strip: bubble renders just avatar + header + grid.
    func testQueuedChat_attachmentOnly_emptyTextWithPath() {
        let content = """
        Supervisor:

        ## Attached Files
        - .nanoteams/tasks/1/attachments/photo.jpg
        """

        let result = bubbleInputs(forContent: content)

        XCTAssertNil(result.text, "When the user types nothing, the cleaned text must be nil so MessageBubbleView's hasMessageContent guard hides the empty content bubble — only the grid renders")
        XCTAssertEqual(result.paths, [".nanoteams/tasks/1/attachments/photo.jpg"])
        XCTAssertEqual(result.clippedTexts, [])
    }

    // MARK: - Queued chat: clipped text from Context Capture (Ctrl+Opt+Cmd+K)

    func testQueuedChat_textPlusClippedText_extractsClip() {
        let content = """
        Supervisor:
        check this

        ## Clipped Text
        let foo = bar()
        return foo + 1
        """

        let result = bubbleInputs(forContent: content)

        XCTAssertEqual(result.text, "check this")
        XCTAssertEqual(result.paths, [])
        XCTAssertEqual(result.clippedTexts, ["let foo = bar()\nreturn foo + 1"])
    }

    /// Clip with source-file context (when user captured selection from a file
    /// inside the project root via `ClipboardCaptureService`).
    func testQueuedChat_clipWithSourceContext_extractsBody() {
        let content = """
        Supervisor:
        what does this do?

        ## Clipped Text \u{2014} Calculator.swift:42-51
        func add(_ a: Int, _ b: Int) -> Int {
            return a + b
        }
        """

        let result = bubbleInputs(forContent: content)

        XCTAssertEqual(result.text, "what does this do?")
        XCTAssertEqual(result.paths, [])
        XCTAssertEqual(result.clippedTexts.count, 1)
        XCTAssertTrue(result.clippedTexts[0].contains("func add"))
    }

    // MARK: - Queued chat: text + clips + files in one message

    func testQueuedChat_textPlusClipsPlusFiles_allExtracted() {
        let content = """
        Supervisor:
        please look

        ## Clipped Text
        snippet here

        ## Attached Files
        - a.png
        - b.png
        """

        let result = bubbleInputs(forContent: content)

        XCTAssertEqual(result.text, "please look")
        XCTAssertEqual(result.paths, ["a.png", "b.png"])
        XCTAssertEqual(result.clippedTexts, ["snippet here"])
    }

    // MARK: - forward_to_team: text-only injection

    /// `forward_to_team` injects a `.supervisorMessage` into a child task with
    /// only a `message: String` (no attachments). Strip is a no-op — paths and
    /// clips stay empty, no grid renders, full message text shows in bubble.
    /// Pin-test: confirms narrowing the strip to `sourceContext == .supervisorMessage`
    /// doesn't break the forward-to-team path.
    func testForwardToTeam_textOnly_noStripping() {
        let content = "Supervisor:\nuse the standard library Sort, not custom"

        let result = bubbleInputs(forContent: content)

        XCTAssertEqual(result.text, "use the standard library Sort, not custom")
        XCTAssertEqual(result.paths, [])
        XCTAssertEqual(result.clippedTexts, [])
    }

    // MARK: - Legacy persisted messages (pre-multiline-prefix builds)

    /// `LLMMessage.displayContent` fallback handles the legacy single-line
    /// `Supervisor: ` prefix. Older persisted messages (from before the
    /// prefix was changed to `Supervisor:\n`) must still render cleanly.
    func testLegacyInlinePrefix_stripsCorrectlyAndExtractsPath() {
        let content = """
        Supervisor: legacy single-line prefix

        ## Attached Files
        - foo.png
        """

        let result = bubbleInputs(forContent: content)

        XCTAssertEqual(result.text, "legacy single-line prefix")
        XCTAssertEqual(result.paths, ["foo.png"])
    }

    // MARK: - Plain text (no markers)

    /// User types text only — strip should leave content untouched, no
    /// attachments/clips. This is the common case for `forward_to_team`
    /// and for queued messages without attachments.
    func testQueuedChat_plainText_noExtractionNoChange() {
        let content = "Supervisor:\njust a regular message"

        let result = bubbleInputs(forContent: content)

        XCTAssertEqual(result.text, "just a regular message")
        XCTAssertEqual(result.paths, [])
        XCTAssertEqual(result.clippedTexts, [])
    }

    // MARK: - Source context gate

    /// Regression guard: a regular assistant turn must NEVER have its content
    /// stripped. The view-level gate only invokes `stripAttachedFiles` when
    /// `sourceContext == .supervisorMessage`. This test pins the contract
    /// of `displayContent`: for non-supervisor contexts it returns `content`
    /// verbatim (so even if some assistant LLM output happened to contain
    /// the literal text "## Attached Files", the strip would not run
    /// at the call site and the text would render as-is).
    func testAssistantMessage_displayContentReturnsRawContent() {
        let content = "Here are the changes:\n\n## Attached Files\n- (this is just text the LLM emitted)"

        let msg = LLMMessage(
            role: .assistant,
            content: content,
            sourceContext: nil
        )

        XCTAssertEqual(msg.displayContent, content, "Non-supervisorMessage contexts return content unchanged — the view's source-context gate is what prevents accidental stripping")
    }

    // MARK: - bubbleDisplayInputs (call-site composition pin)

    /// Pin: the call-site logic that resolves `(displayText, paths, clips)`
    /// for `MessageBubbleView`. Regression: an earlier version used
    /// `stripped?.text ?? raw`, which collapsed to `raw` (with markers intact)
    /// for the attachment-only case because `stripped?.text` was nil while
    /// `stripped` itself was non-nil. The bubble then rendered raw `--- Attached
    /// Files ---` text. The fix narrows the fallback to "stripped was never run".
    func testBubbleDisplayInputs_attachmentOnlySupervisor_dropsRawMarkers() {
        let raw = """

        ## Attached Files
        - photo.jpg
        """

        let inputs = ActivityFeedBuilder.bubbleDisplayInputs(raw: raw, isSupervisorMessage: true)

        XCTAssertEqual(inputs.text, "", "Attachment-only supervisor message must produce empty display text — never the raw marker line")
        XCTAssertFalse(inputs.text.contains("## Attached Files"), "Marker section must not leak into display text")
        XCTAssertEqual(inputs.paths, ["photo.jpg"])
    }

    func testBubbleDisplayInputs_textPlusFile_supervisor_returnsCleanedText() {
        let raw = """
        body

        ## Attached Files
        - a.png
        """

        let inputs = ActivityFeedBuilder.bubbleDisplayInputs(raw: raw, isSupervisorMessage: true)

        XCTAssertEqual(inputs.text, "body")
        XCTAssertEqual(inputs.paths, ["a.png"])
    }

    /// Non-supervisor messages must pass through unchanged — even if their
    /// content happens to contain marker-shaped text.
    func testBubbleDisplayInputs_nonSupervisor_returnsRawVerbatim() {
        let raw = "Here are notes:\n\n## Attached Files\n- (literal text from LLM)"

        let inputs = ActivityFeedBuilder.bubbleDisplayInputs(raw: raw, isSupervisorMessage: false)

        XCTAssertEqual(inputs.text, raw)
        XCTAssertEqual(inputs.paths, [])
        XCTAssertEqual(inputs.clippedTexts, [])
    }

    // MARK: - Display content order: prefix-strip BEFORE marker-strip

    /// Pin the order: `displayContent` strips the leading `Supervisor:\n`
    /// FIRST, then `stripAttachedFiles` scans the remainder. If the order
    /// reversed, the prefix would land inside the cleaned text.
    func testDisplayContent_stripsPrefixBeforeMarkerExtraction() {
        let content = """
        Supervisor:
        body

        ## Attached Files
        - a.png
        """

        let msg = LLMMessage(
            role: .user,
            content: content,
            sourceContext: .supervisorMessage
        )

        let displayed = msg.displayContent
        XCTAssertFalse(displayed.hasPrefix("Supervisor:"), "displayContent must drop the leading attribution prefix before any further parsing")
        XCTAssertTrue(displayed.hasPrefix("body"), "Body text must be the first non-empty line after prefix-strip")

        let stripped = ActivityFeedBuilder.stripAttachedFiles(from: displayed)
        XCTAssertEqual(stripped.text, "body")
        XCTAssertEqual(stripped.paths, ["a.png"])
    }
}
