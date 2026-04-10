import XCTest
@testable import NanoTeams

/// Tests for the pure streaming-preview-line resolution logic used by
/// `QuickCaptureFormView.currentStreamingLine`. Covers the two subtle traps
/// documented in the production comments: (1) `StreamingPreviewManager`
/// returns `Optional("")` (not nil) between `beginStreaming` and the first
/// content chunk, so the content→thinking fallback must gate on emptiness,
/// and (2) `appendThinking` does not token-clean at source, so Harmony
/// markers must be stripped at display time.
///
/// The view's `private static` helpers are exposed via `#if DEBUG`
/// accessors (`_testLastNonEmptyLine`, `_testResolveStreamingLine`) at the
/// bottom of `QuickCaptureFormView.swift`.
@MainActor
final class QuickCaptureFormViewLogicTests: XCTestCase {

    // MARK: - lastNonEmptyLine

    func testLastNonEmptyLine_emptyString_returnsNil() {
        XCTAssertNil(QuickCaptureFormView._testLastNonEmptyLine(in: ""))
    }

    func testLastNonEmptyLine_whitespaceOnly_returnsNil() {
        XCTAssertNil(QuickCaptureFormView._testLastNonEmptyLine(in: "   \t  "))
    }

    func testLastNonEmptyLine_newlinesOnly_returnsNil() {
        XCTAssertNil(QuickCaptureFormView._testLastNonEmptyLine(in: "\n\n\n"))
    }

    func testLastNonEmptyLine_mixedWhitespaceAndNewlines_returnsNil() {
        XCTAssertNil(QuickCaptureFormView._testLastNonEmptyLine(in: "  \n \t \n  "))
    }

    func testLastNonEmptyLine_singleLine_returnsThatLine() {
        XCTAssertEqual(
            QuickCaptureFormView._testLastNonEmptyLine(in: "hello world"),
            "hello world"
        )
    }

    func testLastNonEmptyLine_singleLineWithSurroundingWhitespace_isTrimmed() {
        XCTAssertEqual(
            QuickCaptureFormView._testLastNonEmptyLine(in: "  hello world  "),
            "hello world"
        )
    }

    func testLastNonEmptyLine_multiLine_picksLastNonEmpty() {
        let text = """
        first line
        second line
        third line
        """
        XCTAssertEqual(
            QuickCaptureFormView._testLastNonEmptyLine(in: text),
            "third line"
        )
    }

    func testLastNonEmptyLine_trailingBlankLines_skippedToLastContentLine() {
        // Picking the last line shows what was most recently appended, but
        // we must skip trailing blank lines to avoid returning "".
        let text = "real content\n\n   \n"
        XCTAssertEqual(
            QuickCaptureFormView._testLastNonEmptyLine(in: text),
            "real content"
        )
    }

    func testLastNonEmptyLine_blankLinesBetweenContent_picksLastContentLine() {
        let text = "header\n\nbody paragraph one\n\nbody paragraph two"
        XCTAssertEqual(
            QuickCaptureFormView._testLastNonEmptyLine(in: text),
            "body paragraph two"
        )
    }

    func testLastNonEmptyLine_trailingWhitespaceOnLastLine_isTrimmed() {
        XCTAssertEqual(
            QuickCaptureFormView._testLastNonEmptyLine(in: "first\nsecond  \t "),
            "second"
        )
    }

    // MARK: - resolveStreamingLine: content branch

    func testResolveStreamingLine_contentWithText_returnsContentLine() {
        XCTAssertEqual(
            QuickCaptureFormView._testResolveStreamingLine(
                content: "streaming content here",
                thinking: nil
            ),
            "streaming content here"
        )
    }

    func testResolveStreamingLine_contentPrefersOverThinking() {
        // When both are present and content is non-empty, content wins.
        XCTAssertEqual(
            QuickCaptureFormView._testResolveStreamingLine(
                content: "the real content",
                thinking: "the inner monologue"
            ),
            "the real content"
        )
    }

    func testResolveStreamingLine_multiLineContent_picksLastLine() {
        let content = "chapter 1\nchapter 2\nchapter 3"
        XCTAssertEqual(
            QuickCaptureFormView._testResolveStreamingLine(content: content, thinking: nil),
            "chapter 3"
        )
    }

    // MARK: - resolveStreamingLine: Optional("") fall-through

    func testResolveStreamingLine_emptyContentNilThinking_returnsNil() {
        // `beginStreaming` installs an empty StepMessage so streamingContent(for:)
        // returns Optional("") before the first chunk arrives. With no thinking
        // to fall back to, the line should be nil — NOT the empty string that a
        // naive `?? thinking` fallback would have produced.
        XCTAssertNil(
            QuickCaptureFormView._testResolveStreamingLine(content: "", thinking: nil)
        )
    }

    func testResolveStreamingLine_emptyContentFallsThroughToThinking() {
        // The critical documented trap: empty content is Optional("") not nil,
        // so `if let content = ...` succeeds but `lastNonEmptyLine` returns nil
        // and we fall through to the thinking branch.
        XCTAssertEqual(
            QuickCaptureFormView._testResolveStreamingLine(
                content: "",
                thinking: "still reasoning"
            ),
            "still reasoning"
        )
    }

    func testResolveStreamingLine_whitespaceOnlyContentFallsThroughToThinking() {
        // Same trap, with whitespace-only instead of truly empty content.
        XCTAssertEqual(
            QuickCaptureFormView._testResolveStreamingLine(
                content: "   \n  ",
                thinking: "figuring it out"
            ),
            "figuring it out"
        )
    }

    // MARK: - resolveStreamingLine: thinking branch + token cleaning

    func testResolveStreamingLine_nilContentWithThinking_returnsThinkingLine() {
        XCTAssertEqual(
            QuickCaptureFormView._testResolveStreamingLine(
                content: nil,
                thinking: "weighing the options"
            ),
            "weighing the options"
        )
    }

    func testResolveStreamingLine_thinkingWithHarmonyTokens_isCleaned() {
        // The other documented trap: `StreamingPreviewManager.appendThinking`
        // does not call `ModelTokenCleaner`, so tokens like `<|channel|>` can
        // appear in the raw stream. The view must strip them before display.
        let thinking = "<|channel|>analysis<|message|>evaluating the tradeoff"
        let result = QuickCaptureFormView._testResolveStreamingLine(
            content: nil,
            thinking: thinking
        )
        XCTAssertNotNil(result)
        // Validate via the cleaner directly so we test the "tokens are stripped"
        // invariant rather than the exact post-cleaning text (which belongs to
        // ModelTokenCleaner's contract, not this view's).
        XCTAssertFalse(result!.contains("<|"))
        XCTAssertFalse(result!.contains("|>"))
        XCTAssertTrue(result!.contains("evaluating the tradeoff"))
    }

    func testResolveStreamingLine_thinkingThatCleansToEmpty_returnsNil() {
        // Edge case: thinking consists entirely of model tokens. After cleaning
        // it becomes empty/whitespace, so we must return nil — not an empty
        // preview line.
        let result = QuickCaptureFormView._testResolveStreamingLine(
            content: nil,
            thinking: "<|channel|><|message|>"
        )
        XCTAssertNil(result)
    }

    func testResolveStreamingLine_multiLineThinkingWithTokens_picksLastCleanedLine() {
        let thinking = """
        <|channel|>analysis<|message|>first thought
        second thought
        final insight
        """
        let result = QuickCaptureFormView._testResolveStreamingLine(
            content: nil,
            thinking: thinking
        )
        XCTAssertEqual(result, "final insight")
    }

    // MARK: - resolveStreamingLine: nothing-to-show cases

    func testResolveStreamingLine_bothNil_returnsNil() {
        XCTAssertNil(
            QuickCaptureFormView._testResolveStreamingLine(content: nil, thinking: nil)
        )
    }

    func testResolveStreamingLine_bothEmpty_returnsNil() {
        XCTAssertNil(
            QuickCaptureFormView._testResolveStreamingLine(content: "", thinking: "")
        )
    }

    func testResolveStreamingLine_bothWhitespace_returnsNil() {
        XCTAssertNil(
            QuickCaptureFormView._testResolveStreamingLine(
                content: "  \n ",
                thinking: "  \n\n "
            )
        )
    }

    // MARK: - Integration with StreamingPreviewManager

    /// Verifies the documented `Optional("")` behavior of `StreamingPreviewManager`
    /// — this is the upstream invariant `resolveStreamingLine` is built around,
    /// so if this test ever fails the view's assumptions need to be revisited.
    func testStreamingPreviewManager_returnsEmptyStringBetweenBeginAndFirstAppend() {
        let manager = StreamingPreviewManager()
        let stepID = "test-step"
        let messageID = UUID()

        // Before beginStreaming — nil.
        XCTAssertNil(manager.streamingContent(for: stepID))

        // After beginStreaming, before any append — Optional("") not nil.
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        let content = manager.streamingContent(for: stepID)
        XCTAssertNotNil(content, "beginStreaming must install a preview before first chunk")
        XCTAssertEqual(content, "", "preview content must be empty string, not nil, before first append")

        // The view's resolveStreamingLine must treat this as "nothing to show"
        // and fall through to thinking (which is nil here → final nil).
        XCTAssertNil(
            QuickCaptureFormView._testResolveStreamingLine(content: content, thinking: nil)
        )
    }

    /// Verifies that `appendThinking` does NOT token-clean at source, which is
    /// why the view has to strip tokens at display. If `StreamingPreviewManager`
    /// ever starts cleaning thinking, the view-side cleaning becomes redundant.
    func testStreamingPreviewManager_appendThinking_doesNotStripTokens() {
        let manager = StreamingPreviewManager()
        let stepID = "test-step"

        manager.appendThinking(stepID: stepID, content: "<|channel|>analysis<|message|>raw")

        let thinking = manager.streamingThinking(for: stepID)
        XCTAssertNotNil(thinking)
        XCTAssertTrue(
            thinking!.contains("<|"),
            "appendThinking must NOT clean tokens — the view relies on raw storage " +
            "so it can call ModelTokenCleaner.stripTokens at display time"
        )
    }
}
