import XCTest
@testable import NanoTeams

/// Pins the classifier behind the activity feed's collapsed system-notice row.
///
/// Three of the `MessageSourceContext` cases are authored by the RUNTIME, not by
/// a human or a model: the retry nudges (`handleNoToolCalls`), the loop-break
/// correction (`LoopRecoveryPolicy.retryWithNudge`) and the transient
/// server-error retry note (`TaskMutationService.appendOrReplaceRetryNotice`).
/// They used to render as full prose bubbles attributed to the working role —
/// visually indistinguishable from that role's own turns. `MessageBubbleView`
/// now collapses them into a one-line row that opens the full text in a window.
///
/// The truth table iterates `MessageSourceContext.allCases` on purpose: a
/// context added later is asserted to fall on the NOT-a-notice side by default,
/// which is the safe direction (it keeps rendering as prose) and is exactly the
/// assertion a hand-maintained list would silently stop making.
final class SystemNoticePresentationTests: XCTestCase {

    /// The three system-authored contexts. Spelled out here rather than read
    /// back from the production table — a pin that sources its expectation from
    /// the thing it pins asserts nothing.
    private static let expectedNoticeContexts: Set<MessageSourceContext> = [
        .retryNudge, .loopCorrection, .serverError,
    ]

    // MARK: - Truth table over every context

    func testResolve_exactlyTheSystemAuthoredContextsProduceANotice() {
        for context in MessageSourceContext.allCases {
            let notice = SystemNoticePresentation.resolve(context: context, content: "body")
            if Self.expectedNoticeContexts.contains(context) {
                XCTAssertNotNil(notice, "\(context) is system-authored and must collapse")
            } else {
                XCTAssertNil(notice, "\(context) carries human/model content and must stay prose")
            }
        }
    }

    func testResolve_nilContext_isNotANotice() {
        // Plain assistant turns and debug-mode context-less user turns.
        XCTAssertNil(SystemNoticePresentation.resolve(context: nil, content: "body"))
    }

    func testResolve_coversEveryCase_soTheTableIsNotVacuous() {
        // Guards the guard: if `allCases` ever came back short the loop above
        // would pass while checking almost nothing.
        XCTAssertGreaterThanOrEqual(MessageSourceContext.allCases.count, 10)
        XCTAssertTrue(Self.expectedNoticeContexts.isSubset(of: Set(MessageSourceContext.allCases)))
    }

    // MARK: - Labels

    func testResolve_retryNudge_labels() {
        let notice = SystemNoticePresentation.resolve(context: .retryNudge, content: "body")
        XCTAssertEqual(notice?.rowLabel, "system · retry")
        XCTAssertEqual(notice?.windowTitle, "retry")
        XCTAssertEqual(notice?.isError, false)
    }

    func testResolve_loopCorrection_labels() {
        let notice = SystemNoticePresentation.resolve(context: .loopCorrection, content: "body")
        XCTAssertEqual(notice?.rowLabel, "system · loop correction")
        XCTAssertEqual(notice?.windowTitle, "loop correction")
        XCTAssertEqual(notice?.isError, false)
    }

    func testResolve_serverError_labelsAndIsTheOnlyErrorKind() {
        let notice = SystemNoticePresentation.resolve(context: .serverError, content: "body")
        XCTAssertEqual(notice?.rowLabel, "system · server error")
        XCTAssertEqual(notice?.windowTitle, "server error")
        XCTAssertEqual(notice?.isError, true)

        for context in Self.expectedNoticeContexts where context != .serverError {
            XCTAssertEqual(
                SystemNoticePresentation.resolve(context: context, content: "b")?.isError, false,
                "\(context) is a correction, not a failure — it must not render red")
        }
    }

    /// Drift guard against `MessageSourceContext.displayLabel`. Two of the three
    /// kinds have a Domain label; the row must agree with it or the same concept
    /// would read differently in the feed row and in the transcript's `(retry)`
    /// anchor. `.serverError` is the documented exception — Domain deliberately
    /// leaves it out of `displayLabelMap` (it used to be conveyed by the red
    /// card), so the row supplies the wording.
    func testLabels_agreeWithDomainDisplayLabel_exceptTheDocumentedServerErrorGap() {
        XCTAssertEqual(
            SystemNoticePresentation.resolve(context: .retryNudge, content: "b")?.windowTitle,
            MessageSourceContext.retryNudge.displayLabel)
        XCTAssertEqual(
            SystemNoticePresentation.resolve(context: .loopCorrection, content: "b")?.windowTitle,
            MessageSourceContext.loopCorrection.displayLabel)

        XCTAssertEqual(MessageSourceContext.serverError.displayLabel, "serverError",
                       "Domain still has no label for it — the raw-value fallback is pinned by "
                       + "LLMMessageSourceContextTests; the row's wording is deliberately local.")
        XCTAssertEqual(
            SystemNoticePresentation.resolve(context: .serverError, content: "b")?.windowTitle,
            "server error")
    }

    // MARK: - The gate is the CONTEXT, never the content

    /// `.serverError` mutates `content` in place on the same message id across
    /// retry attempts. If emptiness could flip the verdict, the bubble's
    /// `_ConditionalContent` arm would swap mid-update.
    func testResolve_emptyContent_stillANotice_withEmptyPreview() {
        let notice = SystemNoticePresentation.resolve(context: .serverError, content: "")
        XCTAssertNotNil(notice)
        XCTAssertEqual(notice?.preview, "")
        XCTAssertEqual(notice?.rowLabel, "system · server error")
    }

    func testResolve_whitespaceOnlyContent_stillANotice_withEmptyPreview() {
        let notice = SystemNoticePresentation.resolve(context: .retryNudge, content: "  \n\t \n ")
        XCTAssertNotNil(notice)
        XCTAssertEqual(notice?.preview, "")
    }

    func testResolve_contentGrowingFromEmpty_neverChangesTheVerdict() {
        let bodies = ["", " ", "LLM server error (attempt 1/1): boom. Retrying in 10s…"]
        for body in bodies {
            XCTAssertNotNil(SystemNoticePresentation.resolve(context: .serverError, content: body),
                            "verdict must depend on context alone, not on \(body.debugDescription)")
        }
    }

    // MARK: - previewLine

    func testPreviewLine_singleLine_passesThrough() {
        XCTAssertEqual(SystemNoticePresentation.previewLine(from: "Retry with valid JSON."),
                       "Retry with valid JSON.")
    }

    func testPreviewLine_multiline_takesTheFirstNonEmptyLine() {
        let content = """
        That looked like a tool call, but it did not parse as one.
        <|call|>{"name":"read_file","arguments":{"path":"a.swift"}}<|end|>
        """
        XCTAssertEqual(SystemNoticePresentation.previewLine(from: content),
                       "That looked like a tool call, but it did not parse as one.")
    }

    func testPreviewLine_leadingBlankLines_areSkipped() {
        XCTAssertEqual(SystemNoticePresentation.previewLine(from: "\n\n   \nreal line\nsecond"),
                       "real line")
    }

    func testPreviewLine_crlf_doesNotLeakACarriageReturn() {
        let preview = SystemNoticePresentation.previewLine(from: "first\r\nsecond")
        XCTAssertEqual(preview, "first")
        XCTAssertFalse(preview.contains("\r"))
    }

    func testPreviewLine_collapsesInternalWhitespaceRuns() {
        XCTAssertEqual(SystemNoticePresentation.previewLine(from: "a   b\t\tc     d"), "a b c d")
    }

    func testPreviewLine_trimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(SystemNoticePresentation.previewLine(from: "   padded   "), "padded")
    }

    func testPreviewLine_emptyAndWhitespaceOnly_areEmpty() {
        XCTAssertEqual(SystemNoticePresentation.previewLine(from: ""), "")
        XCTAssertEqual(SystemNoticePresentation.previewLine(from: "   \n\t\n  "), "")
    }

    // MARK: - previewLine capping

    func testPreviewLine_exactlyAtTheLimit_isNotEllipsized() {
        let line = String(repeating: "a", count: 20)
        let preview = SystemNoticePresentation.previewLine(from: line, maxLength: 20)
        XCTAssertEqual(preview, line)
        XCTAssertFalse(preview.hasSuffix("…"))
    }

    func testPreviewLine_overTheLimit_isCutAndEllipsized() {
        let preview = SystemNoticePresentation.previewLine(
            from: String(repeating: "a", count: 21), maxLength: 20)
        XCTAssertEqual(preview, String(repeating: "a", count: 20) + "…")
        // The ellipsis is OURS: once the string is cut it fits, so `lineLimit(1)`
        // would render it as if nothing had been dropped.
        XCTAssertEqual(preview.count, 21)
    }

    func testPreviewLine_nonPositiveLimit_disablesTheCap() {
        let line = String(repeating: "b", count: 500)
        XCTAssertEqual(SystemNoticePresentation.previewLine(from: line, maxLength: 0), line)
        XCTAssertEqual(SystemNoticePresentation.previewLine(from: line, maxLength: -1), line)
    }

    func testPreviewLine_capsByGrapheme_notByUTF16OrBytes() {
        // Family emoji: one Character, many UTF-16 units. A UTF-16 prefix would
        // split the ZWJ sequence into mojibake.
        let family = "👨‍👩‍👧‍👦"
        let preview = SystemNoticePresentation.previewLine(
            from: String(repeating: family, count: 5), maxLength: 3)
        XCTAssertEqual(preview, String(repeating: family, count: 3) + "…")
        XCTAssertEqual(preview.count, 4)
    }

    func testPreviewLine_capsCJKByCharacter() {
        let preview = SystemNoticePresentation.previewLine(from: "日本語テキスト", maxLength: 3)
        XCTAssertEqual(preview, "日本語…")
    }

    func testPreviewLine_defaultLimit_isTheProductionConstant() {
        let line = String(repeating: "c", count: SystemNoticePresentation.previewCharacterLimit + 10)
        let preview = SystemNoticePresentation.previewLine(from: line)
        XCTAssertEqual(preview.count, SystemNoticePresentation.previewCharacterLimit + 1)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    // MARK: - Real production texts

    func testResolve_malformedJSONNudge_previewsItsOpeningSentence() {
        let content = "Your previous tool call had malformed JSON and could not be parsed "
            + "(parser error: No string key for value in object around line 1, column 1.). "
            + "Retry with valid JSON, e.g. `<|call|>{\"name\":\"TOOL_NAME\",\"arguments\":"
            + "{\"param\":\"value\"}}<|end|>` — note the two closing braces before `<|end|>`."
        let notice = SystemNoticePresentation.resolve(context: .retryNudge, content: content)
        XCTAssertEqual(notice?.rowLabel, "system · retry")
        XCTAssertTrue(notice?.preview.hasPrefix("Your previous tool call had malformed JSON") == true)
        XCTAssertTrue(notice?.preview.hasSuffix("…") == true, "the nudge is longer than the cap")
        XCTAssertEqual(notice?.preview.count, SystemNoticePresentation.previewCharacterLimit + 1)
    }

    func testResolve_genericNoToolNudge_previewIsWholeWhenShort() {
        let content = "You replied with text but did not call a tool. "
            + "Call `create_artifact` to submit your deliverable."
        let notice = SystemNoticePresentation.resolve(context: .retryNudge, content: content)
        XCTAssertEqual(notice?.preview, content)
        XCTAssertFalse(notice?.preview.hasSuffix("…") == true)
    }

    func testResolve_serverErrorNote_previewKeepsTheAttemptCounter() {
        let content = "LLM server error (attempt 2/3): The request timed out. Retrying in 10s…"
        let notice = SystemNoticePresentation.resolve(context: .serverError, content: content)
        XCTAssertEqual(notice?.preview, content)
        XCTAssertEqual(notice?.isError, true)
    }
}
