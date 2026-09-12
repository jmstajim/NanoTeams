import XCTest
@testable import NanoTeams

/// Tests for the ask_supervisor question merge logic in processRegularToolResult.
/// Validates that multiple ask_supervisor signals in a single batch are correctly
/// accumulated, empty questions are filtered, and outcome fields are set properly.
final class SupervisorQuestionMergeTests: XCTestCase {

    // MARK: - Helpers

    /// Drives the REAL merge. This helper used to re-implement it line for line, which meant this
    /// suite guarded a copy: the production rule could change — and did, wrongly — without a single
    /// assertion here moving. The rule now lives in one place and both callers use it.
    private func applySignals(
        _ signals: [(question: String, providerID: String)]
    ) -> LLMExecutionService.ToolResultsOutcome {
        var outcome = LLMExecutionService.ToolResultsOutcome()
        for signal in signals {
            LLMExecutionService.accumulateSupervisorQuestion(
                signal.question, providerID: signal.providerID, into: &outcome)
        }
        return outcome
    }

    /// Drives the REAL form merge beside the plain one, in the order the batch delivered them.
    private func applyBatch(
        _ items: [(question: String?, form: SupervisorInquiry?, providerID: String)]
    ) -> LLMExecutionService.ToolResultsOutcome {
        var outcome = LLMExecutionService.ToolResultsOutcome()
        for item in items {
            if let form = item.form {
                LLMExecutionService.accumulateSupervisorForm(
                    headline: form.headline, inquiry: form,
                    providerID: item.providerID, into: &outcome)
            } else if let question = item.question {
                LLMExecutionService.accumulateSupervisorQuestion(
                    question, providerID: item.providerID, into: &outcome)
            }
        }
        return outcome
    }

    private func inquiry(
        _ headline: String, _ questions: [(id: String, prompt: String)]
    ) -> SupervisorInquiry {
        SupervisorInquiry(
            headline: headline,
            questions: questions.map {
                SupervisorInquiryQuestion(id: $0.id, prompt: $0.prompt, kind: .freeText)
            })
    }

    // MARK: - Single question

    func testSingleQuestion_storesQuestionAndStops() {
        let outcome = applySignals([("What color?", "tc-1")])

        XCTAssertEqual(outcome.supervisorQuestion, "What color?")
        XCTAssertEqual(outcome.supervisorToolCallProviderIDs.first, "tc-1")
        XCTAssertTrue(outcome.shouldStopForSupervisor)
    }

    // MARK: - Multiple questions merged

    func testTwoQuestions_mergedWithSeparator() {
        let outcome = applySignals([
            ("What color?", "tc-1"),
            ("What size?", "tc-2"),
        ])

        XCTAssertEqual(outcome.supervisorQuestion, "What color?\n\nWhat size?")
        XCTAssertTrue(outcome.shouldStopForSupervisor)
    }

    func testThreeQuestions_allMerged() {
        let outcome = applySignals([
            ("Q1", "tc-1"),
            ("Q2", "tc-2"),
            ("Q3", "tc-3"),
        ])

        XCTAssertEqual(outcome.supervisorQuestion, "Q1\n\nQ2\n\nQ3")
    }

    // MARK: - Provider ID tracks first valid question

    func testProviderID_tracksFirstValidQuestion() {
        let outcome = applySignals([
            ("First question", "tc-first"),
            ("Second question", "tc-second"),
        ])

        XCTAssertEqual(
            outcome.supervisorToolCallProviderIDs.first, "tc-first",
            "Provider ID should track the first valid question, not the last")
    }

    func testProviderID_skipsEmptyLeading_tracksFirstValid() {
        let outcome = applySignals([
            ("", "tc-empty"),
            ("Real question", "tc-real"),
        ])

        XCTAssertEqual(
            outcome.supervisorToolCallProviderIDs.first, "tc-real",
            "Provider ID should skip empty questions and track the first valid one")
    }

    // MARK: - Empty question filtering

    func testEmptyQuestion_notStored() {
        let outcome = applySignals([("", "tc-1")])

        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertFalse(outcome.shouldStopForSupervisor)
        XCTAssertTrue(outcome.supervisorToolCallProviderIDs.isEmpty)
    }

    func testWhitespaceOnlyQuestion_notStored() {
        let outcome = applySignals([("   \n\t  ", "tc-1")])

        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertFalse(outcome.shouldStopForSupervisor)
    }

    func testAllEmptyQuestions_nothingStored() {
        let outcome = applySignals([
            ("", "tc-1"),
            ("   ", "tc-2"),
            ("\n", "tc-3"),
        ])

        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertFalse(outcome.shouldStopForSupervisor,
                       "shouldStopForSupervisor must NOT be set when all questions are empty")
        XCTAssertTrue(outcome.supervisorToolCallProviderIDs.isEmpty)
    }

    func testMixedEmptyAndValid_onlyValidMerged() {
        let outcome = applySignals([
            ("", "tc-empty1"),
            ("Real question", "tc-real"),
            ("   ", "tc-empty2"),
            ("Another question", "tc-another"),
        ])

        XCTAssertEqual(outcome.supervisorQuestion, "Real question\n\nAnother question")
        XCTAssertTrue(outcome.shouldStopForSupervisor)
        XCTAssertEqual(outcome.supervisorToolCallProviderIDs.first, "tc-real")
    }

    // MARK: - Whitespace trimming

    func testQuestionTrimmed() {
        let outcome = applySignals([("  What color?  \n", "tc-1")])

        XCTAssertEqual(outcome.supervisorQuestion, "What color?")
    }

    func testMultipleQuestions_eachTrimmed() {
        let outcome = applySignals([
            ("  Q1  ", "tc-1"),
            ("\nQ2\n", "tc-2"),
        ])

        XCTAssertEqual(outcome.supervisorQuestion, "Q1\n\nQ2")
    }

    // MARK: - Bug regression: hallucinated reset greeting (original issue)

    func testHallucinatedResetGreeting_bothQuestionsPreserved() {
        // Regression test for the original bug: model produced a hallucinated file list
        // question followed by a reset greeting in the same batch.
        // Before the fix, only the last question (greeting) was stored, losing the first.
        let outcome = applySignals([
            ("The .nanoteams directory contains files:\n- README.md\n- config.json", "tc-1"),
            ("Hello! I am your assistant. How can I help?", "tc-2"),
        ])

        XCTAssertTrue(outcome.supervisorQuestion!.contains("directory"))
        XCTAssertTrue(outcome.supervisorQuestion!.contains("assistant"))
        XCTAssertEqual(outcome.supervisorToolCallProviderIDs.first, "tc-1",
                       "Provider ID should be from the first question")
    }

    // MARK: - Every call is recorded, not just the first

    /// One answer resolves the merged question, but each call appended its own
    /// `{"status":"pending"}` tool result, and `handleSupervisorAutoAnswer` can only rewrite the
    /// ids it was given. Recording just the first left every other call pending on the wire for
    /// the rest of the step — resent each iteration, inviting the model to re-ask.
    ///
    /// RED: keep a single `String?` and assign it only when `supervisorQuestion` was nil (the
    /// pre-fix merge) → only `tc-1` is recorded and `tc-2`'s result is never resolved.
    func testEveryValidQuestionsProviderID_isRecordedInOrder() {
        let outcome = applySignals([
            ("What color?", "tc-1"),
            ("What size?", "tc-2"),
            ("", "tc-empty"),
            ("What shape?", "tc-3"),
        ])

        XCTAssertEqual(outcome.supervisorToolCallProviderIDs, ["tc-1", "tc-2", "tc-3"],
                       "every call whose question survived the merge must be resolvable")
    }

    /// A Harmony-parsed call can carry no provider id at all; it must not put an empty string into
    /// the list, which would match nothing and mask a real id's absence.
    ///
    /// RED: append `providerID ?? ""` → the list gains a phantom entry that never resolves.
    func testMissingProviderID_isNotRecorded() {
        var outcome = LLMExecutionService.ToolResultsOutcome()
        LLMExecutionService.accumulateSupervisorQuestion("Q", providerID: nil, into: &outcome)

        XCTAssertEqual(outcome.supervisorQuestion, "Q", "the question still counts")
        XCTAssertTrue(outcome.supervisorToolCallProviderIDs.isEmpty)
        XCTAssertTrue(outcome.shouldStopForSupervisor)
    }

    // MARK: - Default outcome state

    // MARK: - A batch mixing plain asks with a questionnaire

    /// Plain asks alone allocate NO structure. The common path is every chat-mode turn, and a
    /// questionnaire built for a batch that never carried one is memory nobody reads — the
    /// surfaces render `supervisorQuestion`, which is unchanged.
    ///
    /// RED: drop the `outcome.hasSupervisorForm` guard in `accumulateSupervisorQuestion` → the
    /// second assertion finds two questions on a batch with no form in it.
    func testPlainAsksAlone_buildNoQuestionnaire() {
        let outcome = applySignals([("Q1", "tc-1"), ("Q2", "tc-2")])

        XCTAssertEqual(outcome.supervisorQuestion, "Q1\n\nQ2")
        XCTAssertTrue(outcome.supervisorInquiryQuestions.isEmpty)
        XCTAssertFalse(outcome.hasSupervisorForm)
    }

    /// Two plain asks, THEN a form: the earlier questions are stranded inside the merged
    /// headline text with no entry of their own, so the form promotes them — in the order they
    /// were asked, ahead of its own.
    ///
    /// RED: delete the promotion block in `accumulateSupervisorForm` → the card shows the form's
    /// question alone and the two the model actually asked first are answerable nowhere.
    func testPlainAsksThenForm_promotesTheEarlierOnesInOrder() {
        let outcome = applyBatch([
            (question: "How wide?", form: nil, providerID: "tc-1"),
            (question: "How tall?", form: nil, providerID: "tc-2"),
            (question: nil, form: inquiry("Layout", [(id: "scheme", prompt: "Which scheme?")]),
             providerID: "tc-3"),
        ])

        XCTAssertTrue(outcome.hasSupervisorForm)
        XCTAssertEqual(outcome.supervisorInquiryQuestions.map(\.prompt),
                       ["How wide?", "How tall?", "Which scheme?"])
        XCTAssertEqual(outcome.supervisorInquiryQuestions.map(\.id), ["ask_1", "ask_2", "scheme"])
        XCTAssertEqual(outcome.supervisorQuestion, "How wide?\n\nHow tall?\n\nLayout")
        XCTAssertEqual(outcome.supervisorToolCallProviderIDs, ["tc-1", "tc-2", "tc-3"])
    }

    /// A form, THEN a plain ask: the ask joins the questionnaire at the end rather than living
    /// only in the headline string.
    ///
    /// RED: drop the append in `accumulateSupervisorQuestion` → the trailing question is in the
    /// text and in no card.
    func testFormThenPlainAsk_appendsItToTheQuestionnaire() {
        let outcome = applyBatch([
            (question: nil, form: inquiry("Layout", [(id: "scheme", prompt: "Which scheme?")]),
             providerID: "tc-1"),
            (question: "Anything else?", form: nil, providerID: "tc-2"),
        ])

        XCTAssertEqual(outcome.supervisorInquiryQuestions.map(\.prompt),
                       ["Which scheme?", "Anything else?"])
        XCTAssertEqual(outcome.supervisorInquiryQuestions.map(\.id), ["scheme", "ask_2"])
    }

    /// Two IDENTICAL plain asks are two questions. The synthesized id is positional for exactly
    /// this reason: a text-derived id would collide and silently merge the two answers.
    ///
    /// RED: derive the id from the prompt text → both ids read `ask_which_one` and the second
    /// answer overwrites the first.
    func testTwoIdenticalPlainAsks_getDistinctPositionalIDs() {
        let outcome = applyBatch([
            (question: nil, form: inquiry("Pick", [(id: "a", prompt: "A?")]), providerID: "tc-1"),
            (question: "Which one?", form: nil, providerID: "tc-2"),
            (question: "Which one?", form: nil, providerID: "tc-3"),
        ])

        XCTAssertEqual(outcome.supervisorInquiryQuestions.map(\.id), ["a", "ask_2", "ask_3"])
        XCTAssertEqual(outcome.supervisorInquiryQuestions.count, 3, "identical text, two questions")
    }

    /// Two forms in one batch are each internally unique and can still collide with each other.
    /// The second one's colliding id is renamed, and the answers stay apart.
    ///
    /// RED: return `questions` unchanged from the dedupe → both entries carry `scheme`, and the
    /// answer map (`byQuestionID`) holds one of the two.
    func testTwoFormsInOneBatch_collidingIDsAreRenamed() {
        let outcome = applyBatch([
            (question: nil, form: inquiry("First", [(id: "scheme", prompt: "Which scheme?")]),
             providerID: "tc-1"),
            (question: nil, form: inquiry("Second", [(id: "scheme", prompt: "Which target?")]),
             providerID: "tc-2"),
        ])

        XCTAssertEqual(outcome.supervisorInquiryQuestions.map(\.id), ["scheme", "scheme_2"])
        XCTAssertEqual(outcome.supervisorInquiryQuestions.map(\.prompt),
                       ["Which scheme?", "Which target?"])
        XCTAssertEqual(outcome.supervisorQuestion, "First\n\nSecond")
    }

    /// A third collision walks past the taken suffix rather than reusing it.
    ///
    /// RED: stop the suffix search at 2 (`let id = "\(question.id)_2"`) → the third entry
    /// collides with the second and the map loses one answer again.
    func testThreeFormsSharingAnID_eachGetsItsOwn() {
        let outcome = applyBatch([
            (question: nil, form: inquiry("A", [(id: "q", prompt: "P1")]), providerID: "tc-1"),
            (question: nil, form: inquiry("B", [(id: "q", prompt: "P2")]), providerID: "tc-2"),
            (question: nil, form: inquiry("C", [(id: "q", prompt: "P3")]), providerID: "tc-3"),
        ])

        XCTAssertEqual(outcome.supervisorInquiryQuestions.map(\.id), ["q", "q_2", "q_3"])
    }

    func testDefaultOutcome_allNilAndFalse() {
        let outcome = LLMExecutionService.ToolResultsOutcome()

        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertTrue(outcome.supervisorToolCallProviderIDs.isEmpty)
        XCTAssertFalse(outcome.shouldStopForSupervisor)
    }
}
