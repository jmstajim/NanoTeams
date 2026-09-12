import XCTest

@testable import NanoTeams

/// `requestQuestionnaire` — the `[ Ask as form ]` button's whole path through the orchestrator.
///
/// The directive reaches a parked role as the tool RESULT of its own `ask_supervisor`, which is
/// the only channel a parked step has. So the same fields an answer arms are the fields this
/// arms, and the tests read them: the wire sees the directive when, and only when, the step is
/// unparked with a delivery pending.
@MainActor
final class QuestionnaireRequestDeliveryTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private static let stepID = "engineer"

    /// A step parked the ordinary way — a plain `ask_supervisor` CALL, no questionnaire.
    ///
    /// The call is not decoration: `[ Ask as form ]` is offered only where the role asked
    /// something of its own (`SupervisorQuestionnaireRequest.isAvailable`), and a fixture that
    /// raises the flag alone is the app-raised escalation shape, which the API refuses.
    private func parkPlainAsk(question: String = "Which way should the screen go?") async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Screen", supervisorTask: "redesign", makeActive: true)!
        await sut.ensureTaskLoaded(taskID)
        await registerRoles([Self.stepID], onTeamOf: taskID)
        await sut.mutateTask(taskID: taskID) { task in
            var step = StepExecution(
                id: Self.stepID, role: .softwareEngineer, title: "Engineer", status: .paused)
            step.needsSupervisorInput = true
            step.supervisorQuestion = question
            step.toolCalls = [Self.askCall(question: question)]
            task.runs = [Run(id: 0, steps: [step], roleStatuses: [Self.stepID: .working])]
        }
        return taskID
    }

    /// The park a ROLE raised, as the tool log records it.
    private static func askCall(question: String) -> StepToolCall {
        StepToolCall(
            name: ToolNames.askSupervisor,
            argumentsJSON: "{\"question\": \"\(question)\"}",
            resultJSON: nil,
            isError: false)
    }

    /// The other shape of park: a loop cap, a drift cap, the Autovisor's idle park. The flag
    /// and the question text are written directly, with no call behind them.
    private func parkEscalation() async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Screen", supervisorTask: "redesign", makeActive: true)!
        await sut.ensureTaskLoaded(taskID)
        await registerRoles([Self.stepID], onTeamOf: taskID)
        await sut.mutateTask(taskID: taskID) { task in
            var step = StepExecution(
                id: Self.stepID, role: .softwareEngineer, title: "Engineer", status: .paused)
            step.needsSupervisorInput = true
            step.supervisorQuestion = "The role repeated the same call 25 times. Please advise."
            task.runs = [Run(id: 0, steps: [step], roleStatuses: [Self.stepID: .working])]
        }
        return taskID
    }

    private func park(inquiry: SupervisorInquiry) async -> Int {
        let taskID = await parkPlainAsk(question: inquiry.headline)
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].supervisorInquiry = inquiry
        }
        return taskID
    }

    private func step(_ taskID: Int) -> StepExecution? {
        sut.loadedTask(taskID)?.runs.last?.steps.first { $0.id == Self.stepID }
    }

    // MARK: - Happy path

    func testRequest_unparksTheStepWithTheDirectivePendingDelivery() async {
        let taskID = await parkPlainAsk()

        let ok = await sut.requestQuestionnaire(stepID: Self.stepID, taskID: taskID)

        XCTAssertTrue(ok)
        XCTAssertEqual(step(taskID)?.supervisorAnswer, SupervisorQuestionnaireRequest.directive)
        XCTAssertEqual(step(taskID)?.needsSupervisorInput, false)
        XCTAssertEqual(
            step(taskID)?.supervisorAnswerPendingDelivery, true,
            "the directive has not reached the model until the step re-enters")
    }

    /// The badge means "an LLM answerer stood in for the human". Here the human is the one who
    /// decided — they pressed the button.
    func testRequest_isNotMarkedAsAnAutoAnswer() async {
        let taskID = await parkPlainAsk()

        _ = await sut.requestQuestionnaire(stepID: Self.stepID, taskID: taskID)

        XCTAssertEqual(step(taskID)?.supervisorAnswerWasAuto, false)
    }

    func testRequest_carriesTheTypedNoteBelowTheDirective() async {
        let taskID = await parkPlainAsk()

        _ = await sut.requestQuestionnaire(
            stepID: Self.stepID, taskID: taskID, note: "дай три варианта дизайна")

        let answer = step(taskID)?.supervisorAnswer ?? ""
        XCTAssertTrue(answer.hasPrefix(SupervisorQuestionnaireRequest.directive))
        XCTAssertTrue(answer.hasSuffix("дай три варианта дизайна"))
    }

    func testRequest_withABlankNote_sendsTheDirectiveAlone() async {
        let taskID = await parkPlainAsk()

        _ = await sut.requestQuestionnaire(stepID: Self.stepID, taskID: taskID, note: "  \n ")

        XCTAssertEqual(step(taskID)?.supervisorAnswer, SupervisorQuestionnaireRequest.directive)
    }

    /// The directive is the APP speaking, and the appended turn says so: a system-notice
    /// context, no `sourceRole` (so the feed files it under the asking role, where every other
    /// system row sits), and no `Supervisor answer: ` marker on the body.
    ///
    /// RED: leave it `.supervisorAnswer` → the feed draws "The question was not answered" as
    /// the human's checkmarked reply to the question that role had just asked.
    func testRequest_appendsOneSystemTurnAndNotASupervisorAnswer() async {
        let taskID = await parkPlainAsk()

        _ = await sut.requestQuestionnaire(stepID: Self.stepID, taskID: taskID)

        let messages = step(taskID)?.llmConversation ?? []
        XCTAssertTrue(
            messages.allSatisfy { $0.sourceContext != .supervisorAnswer },
            "nothing here was said by the Supervisor")

        let requests = messages.filter { $0.sourceContext == .questionnaireRequest }
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.sourceRole)
        XCTAssertEqual(requests.first?.role, .user, "a `.system` role would render nowhere")
        XCTAssertEqual(requests.first?.content, SupervisorQuestionnaireRequest.directive)
        XCTAssertFalse(
            requests.first?.content.hasPrefix(MessageSourceContext.supervisorAnswerPrefix) == true)
    }

    /// Whatever the attribution, the turn has to UNPARK the step — it is the durable record
    /// `hasActiveSupervisorInput` reads. Without it the composer chip, the Watchtower inbox
    /// and the sidebar dot keep asking for an answer forever.
    func testRequest_leavesTheStepReadingAsResolved() async {
        let taskID = await parkPlainAsk()

        _ = await sut.requestQuestionnaire(stepID: Self.stepID, taskID: taskID)

        XCTAssertEqual(step(taskID)?.hasActiveSupervisorInput, false)
        XCTAssertEqual(step(taskID)?.lastSupervisorAskResolution, .questionnaireRequest)
    }

    // MARK: - Corner cases

    /// Fail-closed against the SAME policy the button reads. Without the guard the directive
    /// would reach `SupervisorInquiryReply.compose`, which reads prose back with the grammar
    /// written for a model's `Q2: 1, 3` reply — and an arbitrary sentence would be parsed as
    /// answers to questions nobody decided.
    func testRequest_isRefused_whenTheStepAlreadyParkedOnAForm() async {
        let inquiry = SupervisorInquiry(
            headline: "Which way should the screen go?",
            questions: [
                SupervisorInquiryQuestion(
                    id: "q1", prompt: "Which layout?", kind: .singleChoice,
                    options: [
                        SupervisorInquiryOption(id: "a", label: "List"),
                        SupervisorInquiryOption(id: "b", label: "Grid"),
                    ])
            ])
        let taskID = await park(inquiry: inquiry)

        let ok = await sut.requestQuestionnaire(stepID: Self.stepID, taskID: taskID)

        XCTAssertFalse(ok)
        XCTAssertEqual(
            step(taskID)?.needsSupervisorInput, true, "the step stays parked on its form")
        XCTAssertNil(step(taskID)?.supervisorAnswer)
        XCTAssertNotNil(sut.lastSurfacedError, "the refusal is surfaced, not silent")
    }

    /// A park the app raised — loop cap, drift cap, the Autovisor's idle park — has no ask
    /// call, so there is nothing to re-ask. The button is not offered there, and the API
    /// refuses against the same policy rather than trusting the UI to have hidden it.
    ///
    /// RED: drop the `askCallID` half of `isAvailable` → the role receives "The question was
    /// not answered. Ask it again as a form…" about a question it never asked.
    func testRequest_isRefused_onAParkTheRoleDidNotRaise() async {
        let taskID = await parkEscalation()

        let ok = await sut.requestQuestionnaire(stepID: Self.stepID, taskID: taskID)

        XCTAssertFalse(ok)
        XCTAssertNil(step(taskID)?.supervisorAnswer)
        XCTAssertEqual(step(taskID)?.needsSupervisorInput, true, "still waiting for a human")
        XCTAssertNotNil(sut.lastSurfacedError, "the refusal is surfaced, not silent")
    }

    /// Already answered: the ask is closed, so the request has no park to resolve.
    func testRequest_isRefused_onAnAlreadyResolvedAsk() async {
        let taskID = await parkPlainAsk()
        _ = await sut.answerSupervisorQuestion(
            stepID: Self.stepID, taskID: taskID, answer: "Go with the list layout.")

        let ok = await sut.requestQuestionnaire(stepID: Self.stepID, taskID: taskID)

        XCTAssertFalse(ok)
        XCTAssertEqual(
            step(taskID)?.supervisorAnswer, "Go with the list layout.",
            "the human's answer is not overwritten by a directive")
    }

    func testRequest_isRefused_forAStepThatIsNotThere() async {
        let taskID = await parkPlainAsk()

        let ok = await sut.requestQuestionnaire(stepID: "nobody", taskID: taskID)

        XCTAssertFalse(ok)
        XCTAssertEqual(step(taskID)?.needsSupervisorInput, true)
    }

    // MARK: - The invariant the directive rests on

    /// The role is asked to call a tool it must still hold on its next iteration. Resolver step
    /// 4-bis pairs the two ask tools in both directions, so a role that could park on the plain
    /// ask holds the form by construction — pinned here because the directive is unanswerable
    /// the moment that stops being true.
    func testARoleHoldingThePlainAsk_alsoHoldsTheForm() {
        for team in TeamTemplateFactory.allTemplates {
            for role in team.nonSupervisorRoles where role.toolIDs.contains(ToolNames.askSupervisor) {
                XCTAssertTrue(
                    role.toolIDs.contains(ToolNames.askSupervisorForm),
                    "\(team.name)/\(role.name) lists the plain ask without the form")
            }
        }
    }
}
