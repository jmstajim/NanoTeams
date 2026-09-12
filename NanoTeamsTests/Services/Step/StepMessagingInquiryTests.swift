import XCTest

@testable import NanoTeams

/// The ONE seam every answer to a questionnaire passes through.
///
/// Four origins funnel into `StepMessagingService.answerSupervisorQuestion`: the human card,
/// the Autovisor's `answer_task_question`, a delegating parent role, and — after a
/// pause/resume — the `.autonomous` re-entry. Three of them can only speak prose. If the
/// composition lived at each origin instead of here, "what an unanswered question means"
/// would be defined three times, and the asking role would have to know which kind of
/// Supervisor it got in order to read the answer.
final class StepMessagingInquiryTests: XCTestCase {

    // MARK: - Fixtures

    private let form = SupervisorInquiry(
        headline: "Which build settings?",
        questions: [
            SupervisorInquiryQuestion(
                id: "scheme", prompt: "Which scheme?", kind: .singleChoice,
                options: [
                    SupervisorInquiryOption(id: "debug", label: "Debug"),
                    SupervisorInquiryOption(id: "release", label: "Release"),
                ]),
            SupervisorInquiryQuestion(id: "notes", prompt: "Anything else?", kind: .freeText),
        ])

    private func parkedTask(inquiry: SupervisorInquiry?) -> (task: NTMSTask, stepID: String) {
        var task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Test goal")
        var run = Run(id: 0)
        var step = StepExecution(
            id: "engineer", role: .softwareEngineer, title: "Software Engineer",
            status: .needsSupervisorInput)
        step.needsSupervisorInput = true
        step.supervisorQuestion = inquiry?.headline ?? "Which scheme?"
        step.supervisorInquiry = inquiry
        run.steps.append(step)
        task.runs.append(run)
        return (task, step.id)
    }

    private func answeredStep(_ task: NTMSTask) -> StepExecution { task.runs[0].steps[0] }

    // MARK: - The plain path is untouched

    /// Chat-mode teams route EVERY assistant turn through `ask_supervisor`, so this is the
    /// most-travelled path in the app. A form-shaped rewrite of it would change every reply
    /// in every chat.
    func testAPlainQuestionsAnswerIsStoredVerbatim() {
        var (task, stepID) = parkedTask(inquiry: nil)
        XCTAssertTrue(StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "  Use Debug.  ", in: &task))
        XCTAssertEqual(answeredStep(task).supervisorAnswer, "Use Debug.")
        XCTAssertNil(answeredStep(task).supervisorInquiryAnswer)
    }

    // MARK: - Automated answerers: prose in, structure out

    /// What the Autovisor and a delegating parent role actually send: prose shaped by the
    /// reply contract they were shown.
    func testAProseReplyIsReadBackAgainstTheQuestionnaire() {
        var (task, stepID) = parkedTask(inquiry: form)
        XCTAssertTrue(StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "Q1: 2\nQ2: keep the diff tight", origin: .automated, in: &task))

        let step = answeredStep(task)
        XCTAssertEqual(step.supervisorInquiryAnswer?.byQuestionID["scheme"]?.selectedOptionIDs, ["release"])
        XCTAssertEqual(step.supervisorInquiryAnswer?.byQuestionID["notes"]?.freeText, "keep the diff tight")
        XCTAssertEqual(step.supervisorAnswer?.contains("A1. Release"), true, step.supervisorAnswer ?? "")
        XCTAssertEqual(step.supervisorAnswerWasAuto, true)
    }

    /// An answerer that replies in prose has still answered — but it has DECIDED nothing. The
    /// prose rides once above the pairs, every question reports the absence, and the direction
    /// below tells the asking role to decide them itself: nothing the Supervisor said is
    /// dropped, and nothing they did not say is invented.
    ///
    /// RED: fill the choice from `options[0]` → "whatever CI uses is fine" is recorded as a
    /// decision for Debug, which is a scheme nobody named.
    func testAnUnstructuredReplyDecidesNothingAndKeepsTheProse() {
        var (task, stepID) = parkedTask(inquiry: form)
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "Whatever CI uses is fine.", origin: .automated, in: &task)

        let step = answeredStep(task)
        let answer = step.supervisorAnswer ?? ""
        XCTAssertNil(step.supervisorInquiryAnswer?.byQuestionID["scheme"])
        XCTAssertTrue(answer.hasPrefix("Whatever CI uses is fine."), answer)
        XCTAssertTrue(answer.contains(SupervisorInquiryRenderer.unansweredMarker), answer)
        XCTAssertTrue(answer.contains(SupervisorInquiryRenderer.unansweredDirection), answer)
    }

    // MARK: - The human card

    func testAStructuredAnswerKeepsTheHumansChoicesAndLeavesTheRestUnanswered() {
        var (task, stepID) = parkedTask(inquiry: form)
        let structured = SupervisorInquiryAnswer(byQuestionID: [
            "notes": .init(freeText: "Ship it."),
        ])
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "",
            submission: SupervisorInquirySubmission(answer: structured), in: &task)

        let step = answeredStep(task)
        XCTAssertEqual(step.supervisorInquiryAnswer?.byQuestionID["notes"]?.freeText, "Ship it.")
        XCTAssertNil(step.supervisorInquiryAnswer?.byQuestionID["scheme"])
    }

    // MARK: - Delivery

    /// An empty submit on a form is a LEGAL submit — that is the whole reason a partial
    /// answer is allowed. It still has to reach the model, or the role waits forever for an
    /// answer that was given. RED: compose before the delivery flag is inferred, and an empty
    /// reply arms nothing.
    func testAnEmptySubmitOnAFormStillArmsDelivery() {
        var (task, stepID) = parkedTask(inquiry: form)
        _ = StepMessagingService.answerSupervisorQuestion(stepID: stepID, answer: "", in: &task)

        let step = answeredStep(task)
        XCTAssertTrue(step.supervisorAnswerPendingDelivery)
        XCTAssertFalse(step.needsSupervisorInput)
        XCTAssertEqual(step.status, .pending)
        XCTAssertEqual(
            step.llmConversation.last?.sourceContext, .supervisorAnswer,
            "the durable record that the question was resolved")
    }

    /// An empty submit on a PLAIN question is not an answer, and must not arm a delivery that
    /// has nothing to deliver — the pre-existing contract the form must not disturb.
    func testAnEmptySubmitOnAPlainQuestionStillArmsNothing() {
        var (task, stepID) = parkedTask(inquiry: nil)
        _ = StepMessagingService.answerSupervisorQuestion(stepID: stepID, answer: "", in: &task)
        XCTAssertFalse(answeredStep(task).supervisorAnswerPendingDelivery)
    }

    /// The prose sent to the model and the structure kept on the step are one record. If they
    /// could disagree, no surface could be trusted to re-render the answered card.
    func testTheSentProseAndTheStoredStructureAgree() {
        var (task, stepID) = parkedTask(inquiry: form)
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "Q1: Release", in: &task)

        let step = answeredStep(task)
        let structured = step.supervisorInquiryAnswer ?? SupervisorInquiryAnswer()
        XCTAssertEqual(
            step.supervisorAnswer,
            SupervisorInquiryRenderer.render(inquiry: form, answer: structured))
    }

    func testAnswerAgainstAMissingStepStillReportsFailure() {
        var (task, _) = parkedTask(inquiry: form)
        XCTAssertFalse(StepMessagingService.answerSupervisorQuestion(
            stepID: "no_such_step", answer: "Q1: 1", in: &task))
    }
}
