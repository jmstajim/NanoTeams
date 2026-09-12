import XCTest

@testable import NanoTeams

/// The two seams where a questionnaire can be dropped in silence.
///
/// Both are the shape CLAUDE.md #25 names: a `case` that destructures an enum whose payload
/// grew. Dropping the second value COMPILES — the worst version of it binds a tuple and the
/// compiler says nothing at all, and the version here merely warns "never used". What follows
/// is not a crash but a feature that is quietly absent: the step parks carrying only the
/// headline, every surface renders a plain question, and the reply comes back as
/// undifferentiated prose — no question answered, none reported unanswered, and the asking
/// role told neither.
///
/// A source pin rather than a behavioural test because the seam is one arm of a ~200-line
/// closure inside `executeStep`, reachable only from a full step run; the pin asserts exactly
/// the thing that can regress, and says so in its message.
@MainActor
final class SupervisorInquiryParkPinTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        RatchetSourceScan.strippingLineComments(
            try String(contentsOf: RatchetSourceScan.repoRoot.appendingPathComponent(path),
                       encoding: .utf8))
    }

    /// The park seam: `.needsSupervisorInput` carries the questionnaire, and
    /// `setNeedsSupervisorInput` is the only thing that writes it onto the step.
    ///
    /// RED by construction on the tree of 2026-09-10: the arm bound `inquiry` and passed
    /// `question` alone, so `ask_supervisor_form` parked steps with no form on them.
    func testTheParkSeamPassesTheQuestionnaireToTheStep() throws {
        let code = try source("NanoTeams/Services/LLM/LLMExecutionService+StepLifecycle.swift")
        XCTAssertTrue(
            code.contains("case .needsSupervisorInput(let question, let inquiry):"),
            "the arm no longer destructures both values — re-point this pin at where it moved")
        XCTAssertTrue(
            code.contains("stepID: stepID, taskID: taskID, question: question, inquiry: inquiry)"),
            "the park seam drops the questionnaire: a form parks as a plain question, every "
                + "surface renders one, and the reply comes back as undifferentiated prose — "
                + "no question is answered, none is reported unanswered, and the asking role "
                + "is told neither")
    }

    /// The in-loop autonomous seam. Two arguments, two failures, both silent: without
    /// `inquiry` on the generate call the answerer is shown a headline and cannot choose;
    /// without it on the record call the answered card has no structure to re-render from.
    func testTheAutonomousSeamCarriesTheQuestionnaireBothWays() throws {
        let code = try source("NanoTeams/Services/LLM/LLMExecutionService+ToolLoopState.swift")
        let body = try XCTUnwrap(
            RatchetSourceScan.functionBody(after: "func handleSupervisorAutoAnswer(", in: code),
            "`handleSupervisorAutoAnswer` moved — re-point this pin")
        XCTAssertTrue(body.contains("outcome.supervisorInquiry"),
                      "the autonomous answerer never reads the batch's questionnaire")
        XCTAssertTrue(body.contains("SupervisorInquiryReply.compose("),
                      "the reply is stored raw: `Q1: 2` reaches the asking role as the answer, "
                          + "and nothing is persisted for the card to re-render")
    }

    /// The two parked automated answerers reach the questionnaire through a `String`, and
    /// each has exactly one place to render it. Sending the headline instead is not an error
    /// anywhere — it is a form whose options nobody was offered.
    func testBothParkedAnswerersAreShownTheQuestionnaire() throws {
        for path in [
            "NanoTeams/Services/LLM/LLMExecutionService+Autovisor.swift",
            "NanoTeams/Services/LLM/DelegatedSupervisorAnswerService.swift",
        ] {
            XCTAssertTrue(
                try source(path).contains("SupervisorInquiryReply.questionnaire(for:)"),
                "\(path) hands its answerer the headline alone — it cannot choose among "
                    + "options it was never shown, and every choice comes back defaulted")
        }
    }
}
