import XCTest

@testable import NanoTeams

/// `SupervisorInquiryCompleteness` — the validator half of the tolerant parse: a form can be
/// syntactically whole and still be missing what the model meant to send.
/// Not `@MainActor`: a pure function over a value type.
final class SupervisorInquiryCompletenessTests: XCTestCase {

    private func option(_ label: String) -> SupervisorInquiryOption {
        SupervisorInquiryOption(id: label.lowercased(), label: label)
    }

    private func inquiry(_ questions: SupervisorInquiryQuestion...) -> SupervisorInquiry {
        SupervisorInquiry(headline: "H", questions: questions)
    }

    private func choice(
        _ id: String, _ kind: SupervisorInquiryKind, _ labels: [String]
    ) -> SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(
            id: id, prompt: "Pick", kind: kind, options: labels.map(option))
    }

    private func freeText(_ id: String) -> SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(id: id, prompt: "Tell me", kind: .freeText)
    }

    // MARK: - Complete

    func testAChoiceWithTwoOptions_isComplete() {
        XCTAssertNil(SupervisorInquiryCompleteness.fault(
            in: inquiry(choice("q1", .singleChoice, ["Debug", "Release"]))))
    }

    /// A `free_text` question carries no options by construction, and the decoder already
    /// refuses one that does — it must not be read as a choice with too few.
    func testAFreeTextQuestion_isCompleteWithNoOptions() {
        XCTAssertNil(SupervisorInquiryCompleteness.fault(in: inquiry(freeText("q1"))))
    }

    func testAnEmptyQuestionnaire_isNotThisRulesBusiness() {
        XCTAssertNil(SupervisorInquiryCompleteness.fault(
            in: SupervisorInquiry(headline: "H", questions: [])))
    }

    // MARK: - Incomplete

    /// What a truncated emission decodes into once its dropped closer is put back: the model
    /// wrote `{"label": "X",` and stopped, so the choice it meant to offer has one answer.
    ///
    /// RED: return nil for every inquiry → the repair laundry passes and a choice with one
    /// option parks on the human.
    func testASingleChoiceWithOneOption_isNamedWithItsPositionAndCount() {
        let fault = SupervisorInquiryCompleteness.fault(
            in: inquiry(choice("q1", .singleChoice, ["Only"])))
        XCTAssertEqual(fault, SupervisorInquiryCompleteness.tooFewOptionsNote(
            questionNumber: 1, options: 1))
    }

    func testAMultiChoiceWithOneOption_isRefusedTheSameWay() {
        let fault = SupervisorInquiryCompleteness.fault(
            in: inquiry(choice("q1", .multiChoice, ["Only"])))
        XCTAssertEqual(fault, SupervisorInquiryCompleteness.tooFewOptionsNote(
            questionNumber: 1, options: 1))
    }

    /// The number the model reads is the position it wrote, counting from one — an index
    /// would name a different question than the one it has to fix.
    ///
    /// RED: report `questionNumber: index` → this names question 1 for the third question.
    func testThePositionIsOneBased() {
        let fault = SupervisorInquiryCompleteness.fault(in: inquiry(
            freeText("q1"),
            choice("q2", .singleChoice, ["A", "B"]),
            choice("q3", .singleChoice, ["Only"])))
        XCTAssertEqual(fault, SupervisorInquiryCompleteness.tooFewOptionsNote(
            questionNumber: 3, options: 1))
    }

    /// Only the first: one truncation usually costs the tail as well, and listing every
    /// consequence spends the message on noise instead of the edit.
    func testOnlyTheFirstIncompleteQuestionIsNamed() {
        let fault = SupervisorInquiryCompleteness.fault(in: inquiry(
            choice("q1", .singleChoice, ["Only"]),
            choice("q2", .multiChoice, ["AlsoOnly"])))
        XCTAssertEqual(fault, SupervisorInquiryCompleteness.tooFewOptionsNote(
            questionNumber: 1, options: 1))
    }

    /// The note has to say what to send instead — a question with one real answer is a
    /// `free_text` question, and without that arm the model can only invent a second option.
    func testTheNoteNamesBothRepairs() {
        let note = SupervisorInquiryCompleteness.tooFewOptionsNote(questionNumber: 2, options: 1)
        XCTAssertTrue(note.contains("Question 2"), note)
        XCTAssertTrue(note.contains("free_text"), note)
        XCTAssertTrue(note.contains("at least 2"), note)
    }
}
