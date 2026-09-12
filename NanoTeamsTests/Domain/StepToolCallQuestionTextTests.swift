import XCTest

@testable import NanoTeams

/// `StepToolCall.parseSupervisorQuestion` — the one-line text a PARKING call carries.
///
/// Two keys, because the two parking tools spell the same slot differently
/// (`ask_supervisor.question`, `ask_supervisor_form.headline`) and every surface that
/// renders a supervisor question renders a `String`. The truncated branch is the reason
/// the form's headline is mandatory and declared first: the card renders while the call
/// is still streaming, and a form is a much larger body than a bare question.
final class StepToolCallQuestionTextTests: XCTestCase {

    // MARK: - Well-formed JSON

    func testParsesPlainQuestion() {
        XCTAssertEqual(
            StepToolCall.parseSupervisorQuestion(from: #"{"question":"Which scheme?"}"#),
            "Which scheme?")
    }

    func testParsesFormHeadline() {
        XCTAssertEqual(
            StepToolCall.parseSupervisorQuestion(
                from: #"{"headline":"Three questions about M20","form":"{}"}"#),
            "Three questions about M20")
    }

    /// Neither tool emits both keys; the order only decides which is tried first, and
    /// pinning it keeps the answer deterministic if a provider ever echoes both.
    func testQuestionWinsWhenBothPresent() {
        XCTAssertEqual(
            StepToolCall.parseSupervisorQuestion(
                from: #"{"headline":"H","question":"Q"}"#),
            "Q")
    }

    func testEmptyValueFallsThroughRatherThanReturningEmpty() {
        XCTAssertNil(StepToolCall.parseSupervisorQuestion(from: #"{"question":""}"#))
    }

    func testUnrelatedToolArgumentsYieldNil() {
        XCTAssertNil(StepToolCall.parseSupervisorQuestion(from: #"{"path":"a.swift"}"#))
    }

    // MARK: - Truncated stream

    func testTruncatedQuestionTakesTheTail() {
        XCTAssertEqual(
            StepToolCall.parseSupervisorQuestion(from: #"{"question":"Which sche"#),
            "Which sche")
    }

    /// The case the form exists to survive: the headline is COMPLETE, the body is still
    /// arriving, and the whole payload is unparseable.
    ///
    /// RED: drop `unescapedQuoteIndex` and keep the old suffix-trimming branch → this
    /// returns `Three questions","form":"{\"questions\":[{\"id` — the card renders the raw
    /// JSON tail as the question for as long as the form streams.
    func testTruncatedFormReturnsHeadlineWithoutTheStreamingBody() {
        let partial = #"{"headline":"Three questions","form":"{\"questions\":[{\"id"#
        XCTAssertEqual(
            StepToolCall.parseSupervisorQuestion(from: partial),
            "Three questions")
    }

    func testTruncatedValueKeepsAnEscapedQuote() {
        XCTAssertEqual(
            StepToolCall.parseSupervisorQuestion(from: #"{"question":"He said \"hi"#),
            "He said \"hi")
    }

    /// A backslash-escaped backslash immediately before the closing quote must not make the
    /// quote read as escaped — otherwise the value swallows the rest of the payload.
    func testEscapedBackslashBeforeClosingQuoteEndsTheValue() {
        let partial = #"{"headline":"path C:\\","form":"{\"q"#
        XCTAssertEqual(
            StepToolCall.parseSupervisorQuestion(from: partial),
            #"path C:\"#)
    }

    func testTruncatedNewlineIsUnescaped() {
        XCTAssertEqual(
            StepToolCall.parseSupervisorQuestion(from: #"{"question":"line one\nline two"#),
            "line one\nline two")
    }

    func testEmptyStringYieldsNil() {
        XCTAssertNil(StepToolCall.parseSupervisorQuestion(from: ""))
    }

    func testKeyPresentButValueNotYetStartedYieldsNil() {
        XCTAssertNil(StepToolCall.parseSupervisorQuestion(from: #"{"question":"#))
    }
}
