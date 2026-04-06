import XCTest
@testable import NanoTeams

/// Tests for the ask_supervisor question merge logic in processRegularToolResult.
/// Validates that multiple ask_supervisor signals in a single batch are correctly
/// accumulated, empty questions are filtered, and outcome fields are set properly.
final class SupervisorQuestionMergeTests: XCTestCase {

    // MARK: - Helpers

    /// Simulates the merge logic from processRegularToolResult by applying
    /// a sequence of ToolSignal.supervisorQuestion signals to a ToolResultsOutcome.
    private func applySignals(
        _ signals: [(question: String, providerID: String)]
    ) -> LLMExecutionService.ToolResultsOutcome {
        var outcome = LLMExecutionService.ToolResultsOutcome()
        for signal in signals {
            let trimmed = signal.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let existing = outcome.supervisorQuestion {
                    outcome.supervisorQuestion = existing + "\n\n" + trimmed
                } else {
                    outcome.supervisorQuestion = trimmed
                    outcome.supervisorToolCallProviderID = signal.providerID
                }
                outcome.shouldStopForSupervisor = true
            }
        }
        return outcome
    }

    // MARK: - Single question

    func testSingleQuestion_storesQuestionAndStops() {
        let outcome = applySignals([("What color?", "tc-1")])

        XCTAssertEqual(outcome.supervisorQuestion, "What color?")
        XCTAssertEqual(outcome.supervisorToolCallProviderID, "tc-1")
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
            outcome.supervisorToolCallProviderID, "tc-first",
            "Provider ID should track the first valid question, not the last")
    }

    func testProviderID_skipsEmptyLeading_tracksFirstValid() {
        let outcome = applySignals([
            ("", "tc-empty"),
            ("Real question", "tc-real"),
        ])

        XCTAssertEqual(
            outcome.supervisorToolCallProviderID, "tc-real",
            "Provider ID should skip empty questions and track the first valid one")
    }

    // MARK: - Empty question filtering

    func testEmptyQuestion_notStored() {
        let outcome = applySignals([("", "tc-1")])

        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertFalse(outcome.shouldStopForSupervisor)
        XCTAssertNil(outcome.supervisorToolCallProviderID)
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
        XCTAssertNil(outcome.supervisorToolCallProviderID)
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
        XCTAssertEqual(outcome.supervisorToolCallProviderID, "tc-real")
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
        XCTAssertEqual(outcome.supervisorToolCallProviderID, "tc-1",
                       "Provider ID should be from the first question")
    }

    // MARK: - Default outcome state

    func testDefaultOutcome_allNilAndFalse() {
        let outcome = LLMExecutionService.ToolResultsOutcome()

        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertNil(outcome.supervisorToolCallProviderID)
        XCTAssertFalse(outcome.shouldStopForSupervisor)
    }
}
