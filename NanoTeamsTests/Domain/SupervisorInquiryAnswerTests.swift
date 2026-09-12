import XCTest

@testable import NanoTeams

/// Normalisation and rendering — the two halves of what the MODEL receives when a human
/// submits a questionnaire, including a partly-filled one.
final class SupervisorInquiryAnswerTests: XCTestCase {

    private func option(_ id: String, _ label: String) -> SupervisorInquiryOption {
        SupervisorInquiryOption(id: id, label: label)
    }

    private func choice(_ id: String, _ prompt: String, _ labels: [String]) -> SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(
            id: id, prompt: prompt, kind: .singleChoice,
            options: labels.map { option($0.lowercased(), $0) })
    }

    private func freeText(_ id: String, _ prompt: String) -> SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(id: id, prompt: prompt, kind: .freeText)
    }

    private func inquiry(_ questions: [SupervisorInquiryQuestion]) -> SupervisorInquiry {
        SupervisorInquiry(headline: "H", questions: questions)
    }

    // MARK: - Normalisation

    /// The agreed contract since 2026-09-12: submitting without deciding is allowed, and the
    /// skipped question stays skipped. Nothing is put in its place.
    ///
    /// RED: substitute `options[0]` for a question nobody touched → the asking role is told
    /// the Supervisor decided the one question they said nothing about.
    func testUnansweredChoiceStaysUnanswered() {
        let form = inquiry([choice("scheme", "Which scheme?", ["Debug", "Release"])])
        let decided = SupervisorInquiryAnswer().decided(in: form)
        XCTAssertNil(decided.byQuestionID["scheme"])
        XCTAssertTrue(decided.isEmpty)
    }

    /// Explicitly picking the recommended option is a decision and survives untouched — the
    /// half of the old contract that was always right.
    func testExplicitlyChoosingTheRecommendationIsKept() {
        let form = inquiry([choice("scheme", "Which scheme?", ["Debug", "Release"])])
        let answered = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"])
        ])
        XCTAssertEqual(
            answered.decided(in: form).byQuestionID["scheme"]?.selectedOptionIDs, ["debug"])
    }

    /// Free text and a choice report the same silence the same way. The asymmetry — a skipped
    /// choice filled from `options[0]`, a skipped free text absent — is what this replaced.
    func testUnansweredFreeTextStaysAbsent() {
        let form = inquiry([freeText("notes", "Anything else?")])
        XCTAssertNil(SupervisorInquiryAnswer().decided(in: form).byQuestionID["notes"])
    }

    /// Whitespace is not an answer — a stray space in a field the human tabbed through must
    /// not ship as a blank decision.
    func testWhitespaceOnlyAnswerIsDropped() {
        let form = inquiry([choice("scheme", "Which scheme?", ["Debug"])])
        let answered = SupervisorInquiryAnswer(byQuestionID: ["scheme": .init(freeText: "   ")])
        XCTAssertNil(answered.decided(in: form).byQuestionID["scheme"])
    }

    /// An "other" field opened and left blank is `isEmpty` and must not reach the record: on
    /// the CARD it is kept (removing it would close the field the human just opened), at the
    /// SUBMIT seam it says nothing.
    func testOpenButBlankFreeTextIsDropped() {
        let form = inquiry([choice("scheme", "Which scheme?", ["Debug", "Release"])])
        let opened = SupervisorInquiryAnswer(byQuestionID: ["scheme": .init(freeText: "")])
        XCTAssertNil(opened.decided(in: form).byQuestionID["scheme"])
    }

    func testDecidingIsIdempotent() {
        let form = inquiry([choice("a", "A?", ["One", "Two"]), freeText("b", "B?")])
        let once = SupervisorInquiryAnswer(byQuestionID: ["a": .init(selectedOptionIDs: ["one"])])
            .decided(in: form)
        XCTAssertEqual(once.decided(in: form), once)
    }

    /// A multi-choice with nothing ticked is not "none of the above" — it is a question
    /// nobody answered, and the two must not arrive identical.
    func testEmptyMultiChoiceIsUnanswered() {
        let question = SupervisorInquiryQuestion(
            id: "targets", prompt: "Which targets?", kind: .multiChoice,
            options: [option("app", "App"), option("tests", "Tests")])
        let form = inquiry([question])
        let empty = SupervisorInquiryAnswer(byQuestionID: ["targets": .init(selectedOptionIDs: [])])
        XCTAssertNil(empty.decided(in: form).byQuestionID["targets"])
    }

    /// A draft can outlive the question it was written for (the role re-asked, the model
    /// changed the form), and the composer's fields are aimed at whichever chip is selected —
    /// so an answer written for another questionnaire can be in hand at submit. It is scoped
    /// away (`scoped(to:)`), because a step must not be persisted holding answers to questions
    /// it never asked.
    ///
    /// RED: filter `byQuestionID` rather than `scoped(to: inquiry).byQuestionID` → the orphan
    /// survives composition and lands on the answered step's record.
    func testAnswersForUnknownQuestionsAreDropped() {
        let form = inquiry([choice("a", "A?", ["One"])])
        let stale = SupervisorInquiryAnswer(byQuestionID: [
            "a": .init(selectedOptionIDs: ["one"]),
            "gone": .init(freeText: "old"),
        ])
        let decided = stale.decided(in: form)
        XCTAssertEqual(decided.byQuestionID["a"]?.selectedOptionIDs, ["one"])
        XCTAssertNil(decided.byQuestionID["gone"])
    }

    // MARK: - Rendering

    func testRendersNumberedPairs() {
        let form = inquiry([
            choice("scheme", "Which scheme should I use?", ["Debug", "Release"]),
            freeText("notes", "Anything else?"),
        ])
        let answer = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"]),
            "notes": .init(freeText: "Keep the diff tight."),
        ])
        XCTAssertEqual(
            SupervisorInquiryRenderer.render(inquiry: form, answer: answer),
            """
            Q1. Which scheme should I use?
            A1. Debug
            Q2. Anything else?
            A2. Keep the diff tight.
            """)
    }

    /// RED: render an untouched choice as anything but the marker → the asking role reads a
    /// decision where the Supervisor was silent, and no label of the model's own options may
    /// appear on that line.
    func testUnansweredChoiceRendersTheAbsenceAndNamesNoOption() {
        let form = inquiry([choice("scheme", "Which scheme?", ["Debug", "Release"])])
        let text = SupervisorInquiryRenderer.render(
            inquiry: form, answer: SupervisorInquiryAnswer())
        XCTAssertTrue(text.contains("A1. \(SupervisorInquiryRenderer.unansweredMarker)"), text)
        XCTAssertFalse(text.contains("Debug"), text)
        XCTAssertFalse(text.contains("Release"), text)
    }

    func testUnansweredFreeTextRendersTheAbsence() {
        let form = inquiry([freeText("notes", "Anything else?")])
        let text = SupervisorInquiryRenderer.render(
            inquiry: form, answer: SupervisorInquiryAnswer())
        XCTAssertTrue(text.contains(SupervisorInquiryRenderer.unansweredMarker), text)
    }

    // MARK: - The direction

    /// The marker says what happened; the direction says what to do about it. Without one the
    /// role is left to invent a next action, and the cheapest one a local model invents is
    /// asking the same form again.
    func testAnyUnansweredQuestionAppendsTheDirection() {
        let form = inquiry([
            choice("scheme", "Which scheme?", ["Debug", "Release"]),
            freeText("notes", "Anything else?"),
        ])
        let answer = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"])
        ])
        let text = SupervisorInquiryRenderer.render(inquiry: form, answer: answer)
        XCTAssertTrue(text.hasSuffix(SupervisorInquiryRenderer.unansweredDirection), text)
    }

    /// Once for the whole answer, not once per absence: three unanswered questions are one
    /// situation, and a copy under each would spend the recency slot on repetition.
    func testTheDirectionAppearsExactlyOnceForManyAbsences() {
        let form = inquiry([
            choice("a", "A?", ["One", "Two"]),
            choice("b", "B?", ["One", "Two"]),
            freeText("c", "C?"),
        ])
        let text = SupervisorInquiryRenderer.render(
            inquiry: form, answer: SupervisorInquiryAnswer())
        XCTAssertEqual(
            text.components(separatedBy: SupervisorInquiryRenderer.unansweredDirection).count - 1,
            1, text)
    }

    /// A fully answered form carries no direction — there is nothing for it to be about.
    func testAFullyAnsweredFormCarriesNoDirection() {
        let form = inquiry([
            choice("scheme", "Which scheme?", ["Debug", "Release"]),
            freeText("notes", "Anything else?"),
        ])
        let answer = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"]),
            "notes": .init(freeText: "Keep it tight."),
        ])
        let text = SupervisorInquiryRenderer.render(inquiry: form, answer: answer)
        XCTAssertFalse(text.contains(SupervisorInquiryRenderer.unansweredDirection), text)
    }

    /// A selection whose option is gone renders as the absence — so it must also arm the
    /// direction, or the role reads a blank line with no instruction beside it.
    func testAStaleSelectionAlsoArmsTheDirection() {
        let form = inquiry([choice("scheme", "Which scheme?", ["Debug", "Release"])])
        let stale = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["gone"])
        ])
        let text = SupervisorInquiryRenderer.render(inquiry: form, answer: stale)
        XCTAssertTrue(text.contains(SupervisorInquiryRenderer.unansweredDirection), text)
    }

    func testMultiChoiceJoinsEverySelection() {
        let question = SupervisorInquiryQuestion(
            id: "targets", prompt: "Which targets?", kind: .multiChoice,
            options: [option("app", "App"), option("tests", "Tests"), option("ui", "UI")])
        let answer = SupervisorInquiryAnswer(byQuestionID: [
            "targets": .init(selectedOptionIDs: ["app", "ui"])
        ])
        XCTAssertEqual(
            SupervisorInquiryRenderer.renderAnswer(to: question, answer: answer.byQuestionID["targets"]),
            "App, UI")
    }

    /// Selection order follows the QUESTION, not the click order, so the same set always
    /// reads the same way and a re-render cannot reshuffle what the human said.
    func testMultiChoiceOrderFollowsTheQuestionNotTheSelection() {
        let question = SupervisorInquiryQuestion(
            id: "t", prompt: "P", kind: .multiChoice,
            options: [option("a", "A"), option("b", "B")])
        let reversed = SupervisorInquiryAnswer.QuestionAnswer(selectedOptionIDs: ["b", "a"])
        XCTAssertEqual(
            SupervisorInquiryRenderer.renderAnswer(to: question, answer: reversed), "A, B")
    }

    /// A human who picks an option AND qualifies it has said two things; dropping either
    /// half edits the answer.
    func testSelectionAndFreeTextAreBothReported() {
        let question = SupervisorInquiryQuestion(
            id: "q", prompt: "P", kind: .singleChoice, options: [option("yes", "Yes")])
        let answer = SupervisorInquiryAnswer.QuestionAnswer(
            selectedOptionIDs: ["yes"], freeText: "but only for Debug")
        XCTAssertEqual(
            SupervisorInquiryRenderer.renderAnswer(to: question, answer: answer),
            "Yes — but only for Debug")
    }

    /// The "other" escape: the model's options were all wrong and the human typed instead.
    func testFreeTextOnlyAnswerToAChoiceQuestion() {
        let question = SupervisorInquiryQuestion(
            id: "q", prompt: "P", kind: .singleChoice, options: [option("yes", "Yes")])
        XCTAssertEqual(
            SupervisorInquiryRenderer.renderAnswer(
                to: question, answer: .init(freeText: "Neither — use SwiftData")),
            "Neither — use SwiftData")
    }

    /// A selection whose option is gone (the form changed under a stale draft) must not
    /// render as a decision with no content.
    func testSelectionOfAnUnknownOptionReadsAsUnanswered() {
        let question = SupervisorInquiryQuestion(
            id: "q", prompt: "P", kind: .singleChoice, options: [option("yes", "Yes")])
        XCTAssertEqual(
            SupervisorInquiryRenderer.renderAnswer(to: question, answer: .init(selectedOptionIDs: ["gone"])),
            SupervisorInquiryRenderer.unansweredMarker)
    }

    func testNilAnswerReadsAsUnanswered() {
        let question = SupervisorInquiryQuestion(id: "q", prompt: "P", kind: .freeText)
        XCTAssertEqual(
            SupervisorInquiryRenderer.renderAnswer(to: question, answer: nil),
            SupervisorInquiryRenderer.unansweredMarker)
    }

    /// An answer containing parentheses must survive verbatim — the marker is appended, not
    /// woven into the text.
    func testAnswerWithParenthesesIsNotMangled() {
        let question = SupervisorInquiryQuestion(id: "q", prompt: "P", kind: .freeText)
        XCTAssertEqual(
            SupervisorInquiryRenderer.renderAnswer(to: question, answer: .init(freeText: "use f(x) (twice)")),
            "use f(x) (twice)")
    }
}
