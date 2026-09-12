import XCTest

@testable import NanoTeams

/// The `[ Ask as form ]` directive lives in `step.supervisorAnswer` because that field IS the
/// delivery slot — the tool result of the role's own `ask_supervisor` is the only way to reach
/// a parked step. Two prompt builders read that slot and both label what they find
/// "Supervisor", so both have to be told the difference.
///
/// The discriminator is `StepExecution.lastSupervisorAskResolution`, read off the resolving
/// turn rather than a step flag: a step keeps one answer slot but many parks.
final class FormRequestPromptAttributionTests: XCTestCase {

    // MARK: - Fixtures

    private func resolvingMessage(_ context: MessageSourceContext, _ body: String) -> LLMMessage {
        LLMMessage(
            role: .user,
            content: body,
            sourceRole: context == .supervisorAnswer ? .supervisor : nil,
            sourceContext: context)
    }

    private func parkedStep(
        resolvedBy context: MessageSourceContext,
        answer: String,
        status: StepStatus = .done
    ) -> StepExecution {
        StepExecution(
            id: "pm",
            role: .productManager,
            title: "PM Step",
            status: status,
            needsSupervisorInput: false,
            supervisorQuestion: "Which way should the screen go?",
            supervisorAnswer: answer,
            llmConversation: [resolvingMessage(context, answer)])
    }

    // MARK: - The run summary other roles read

    /// RED: leave `PipelineContext` reading the raw field → a DOWNSTREAM role is told
    /// «Supervisor A: The question was not answered. Ask it again as a form…» — a sentence the
    /// human never said, attributed to them, in the summary the next role plans from.
    func testPipelineContext_reportsAFormRequestAsAnUnansweredQuestion() {
        let parked = parkedStep(
            resolvedBy: .questionnaireRequest,
            answer: SupervisorQuestionnaireRequest.directive)
        let run = Run(id: 0, steps: [parked, StepExecution(id: "swe", role: .softwareEngineer, title: "SWE")])

        let context = PromptBuilder.buildPipelineContext(
            run: run, upToStepIndex: 1, artifactReader: { _ in nil })

        XCTAssertTrue(context.contains("Supervisor Q: Which way should the screen go?"))
        XCTAssertFalse(context.contains("Supervisor A:"), context)
        XCTAssertFalse(context.contains("Ask it again as a form"), context)
    }

    /// The human's real answers are untouched — the guard must not quietly eat those.
    func testPipelineContext_stillReportsARealAnswer() {
        let parked = parkedStep(resolvedBy: .supervisorAnswer, answer: "Go with the list layout.")
        let run = Run(id: 0, steps: [parked, StepExecution(id: "swe", role: .softwareEngineer, title: "SWE")])

        let context = PromptBuilder.buildPipelineContext(
            run: run, upToStepIndex: 1, artifactReader: { _ in nil })

        XCTAssertTrue(context.contains("Supervisor A: Go with the list layout."), context)
    }

    // MARK: - The asking role's own replayed prompt

    /// Here the text STAYS — the role has to know it was sent back to ask again — but without
    /// the `Supervisor answer: ` marker, which the live wire never attaches either: it sends
    /// the directive inside the ask's tool-result envelope.
    func testReplayedPrompt_keepsTheDirectiveButNotTheSupervisorMarker() {
        let step = parkedStep(
            resolvedBy: .questionnaireRequest,
            answer: SupervisorQuestionnaireRequest.directive,
            status: .running)

        let replay = Self.supervisorReplay(in: messages(for: step))

        XCTAssertEqual(replay, SupervisorQuestionnaireRequest.directive)
    }

    func testReplayedPrompt_keepsTheMarkerOnARealAnswer() {
        let step = parkedStep(
            resolvedBy: .supervisorAnswer, answer: "Go with the list layout.", status: .running)

        let replay = Self.supervisorReplay(in: messages(for: step))

        XCTAssertEqual(
            replay,
            "\(MessageSourceContext.supervisorAnswerPrefix)Go with the list layout.")
    }

    // MARK: - Helpers

    private func messages(for step: StepExecution) -> [ChatMessage] {
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "do")
        let run = Run(id: 0, steps: [step])
        return PromptBuilder.buildChatMessages(
            context: PromptBuilder.Context(
                task: task,
                step: step,
                stepIndex: 0,
                run: run,
                workFolder: nil,
                artifactReader: { _ in nil },
                activeTeam: nil,
                roleDefinition: nil,
                globalContext: "",
                agentInstructions: AgentInstructionsSnapshot(items: []),
                attachedSkills: []),
            tools: [])
    }

    /// The user turn that replays what came back from the ask — the one the marker rides.
    private static func supervisorReplay(in messages: [ChatMessage]) -> String? {
        messages.last { message in
            message.role == .user
                && (message.content?.contains("Go with the list layout.") == true
                    || message.content?.contains("Ask it again as a form") == true)
        }?.content
    }
}
