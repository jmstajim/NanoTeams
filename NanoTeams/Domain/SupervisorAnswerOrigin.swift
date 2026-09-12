import Foundation

/// Who resolved a parked `ask_supervisor` — the one argument every answer seam carries, and
/// the single place that says what the resulting conversation turn looks like.
///
/// It replaced an `isAutoAnswer: Bool` that could name two of the three origins. The third —
/// the app's own `[ Ask as form ]` directive — is neither a human answer nor an automated
/// one: it resolves the park without answering the question. Expressed as a Bool beside a
/// separate context argument, the two could contradict each other (`isAutoAnswer: true` with
/// a directive's context is a state with no meaning); expressed as one value, the caller
/// makes one decision and every downstream field follows from it.
///
/// `StepMessagingService.answerSupervisorQuestion` is the only reader: it writes
/// `supervisorAnswerWasAuto` from `isAutomated` and builds the appended turn from the other
/// three properties.
nonisolated enum SupervisorAnswerOrigin: String, Codable, Hashable, CaseIterable {
    /// The human, at a question card, the Watchtower banner or the Quick Capture panel.
    case supervisor
    /// An LLM answerer standing in for the human: `SupervisorAutoAnswerService` under
    /// `.autonomous`, the Autovisor's `answer_task_question`, a delegating parent role.
    case automated
    /// The app's directive asking the role to re-ask its question as a questionnaire.
    case questionnaireRequest

    /// Drives the feed's "Auto-answered" badge (`StepExecution.supervisorAnswerWasAuto`).
    ///
    /// False for `.questionnaireRequest`: the badge means an LLM answerer stood in for the
    /// human, and the directive is sent BY the human — they pressed the button.
    var isAutomated: Bool { self == .automated }

    /// Attribution of the turn appended to `llmConversation` in the same mutation.
    ///
    /// Both values resolve the park (`MessageSourceContext.resolvesSupervisorAsk`); they
    /// differ in who is speaking, which is what the feed renders — a Supervisor reply, or a
    /// one-line system notice.
    var messageContext: MessageSourceContext {
        switch self {
        case .supervisor, .automated: return .supervisorAnswer
        case .questionnaireRequest: return .questionnaireRequest
        }
    }

    /// Whose avatar the turn renders under (`ActivityFeedBuilder`: `sourceRole ?? step.role`).
    ///
    /// `nil` for the directive, so it sits under the ASKING role the way every other system
    /// notice does — `.supervisor` would file the app's own words under the human's name,
    /// which is the defect this origin exists to fix.
    var messageSourceRole: Role? {
        self == .questionnaireRequest ? nil : .supervisor
    }

    /// Marker prepended to the turn's stored content.
    ///
    /// The marker is for the MODEL: on a flattened wire it separates a Supervisor turn from
    /// the tool result above it, and `displayContent` strips it back off for the bubble. The
    /// directive carries none — it is not the Supervisor's utterance, and it never travels
    /// as a user turn anyway (the wire receives it inside the ask's tool-result envelope,
    /// `LLMExecutionService+StepLifecycle`).
    var messageContentPrefix: String {
        self == .questionnaireRequest ? "" : MessageSourceContext.supervisorAnswerPrefix
    }
}
