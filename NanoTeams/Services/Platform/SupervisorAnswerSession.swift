import Foundation

// MARK: - Supervisor Answer Payload

/// One waiting Supervisor question, as Quick Capture renders it.
///
/// Lives beside `QuickCaptureModeCoordinator` — the type that PRODUCES it — rather than in the
/// view file that consumes it. The panel only prints these fields; deciding which question they
/// describe is a Platform decision, and it is the one with rules worth testing.
nonisolated struct SupervisorAnswerPayload {
    let stepID: String
    let taskID: Int
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let question: String
    /// The questionnaire behind `question`, when the role asked one — `question` is then its
    /// headline. Nil for a plain `ask_supervisor`, which is the whole of what this panel used
    /// to show and still shows unchanged.
    var inquiry: SupervisorInquiry? = nil
    /// The role's own `ask_supervisor` call, when this park came from one
    /// (`SupervisorQuestionInbox.PendingQuestion.askCallID`). Nil on a park the app raised —
    /// a loop or drift cap, the Autovisor's idle park — where `[ Ask as form ]` has nothing
    /// to send the role back to re-ask.
    ///
    /// Defaulted for the panel tests that exercise none of it, exactly as `inquiry` above is;
    /// the production mapping passes every field at once
    /// (`QuickCaptureModeCoordinator.resolve`, pinned by its own tests), which is what keeps
    /// the default out of a silent-failure path.
    var askCallID: UUID? = nil
    let messageContent: String?
    let thinking: String?
    let isChatMode: Bool
}

// MARK: - Supervisor Answer Session

/// Every question waiting on this task, and which of them the panel is showing.
///
/// The panel used to carry ONE question, resolved as `SupervisorQuestionInbox.pending(in:).first`
/// — and with parallel roles (CLAUDE.md #45) "first" is not a summary of the state, it is a
/// choice made on the user's behalf about which of several questions they are allowed to reach.
/// The others were not merely unshown: from the panel there was no route to them at all, so a
/// Supervisor who wanted to answer the second one had to answer the first to uncover it.
///
/// Non-empty by construction. A session of zero questions is not a state the panel has — it is
/// the panel not being in answer mode — so the failable init says so instead of leaving every
/// reader to guard an index.
///
/// Deliberately NOT `Equatable`. `SupervisorAnswerPayload` carries a `TeamRoleDefinition`, and
/// widening a Domain conformance to serve a panel-rebuild decision is exactly what
/// `QuickCapturePresentationPolicy.renderIdentity` exists to avoid; that string is the
/// comparison, and it folds this session's ordered ids and its selection.
nonisolated struct SupervisorAnswerSession {
    /// Oldest ask first — `SupervisorQuestionInbox`'s order, which is also the chip row's
    /// left-to-right order on BOTH surfaces.
    let questions: [SupervisorAnswerPayload]
    /// Always a valid index into `questions`.
    let selectedIndex: Int

    /// One question is a session of one.
    ///
    /// The shape every surface saw before a second question could be reached, and the shape a
    /// caller that genuinely has a single payload should still be able to say in one word.
    init(single payload: SupervisorAnswerPayload) {
        self.questions = [payload]
        self.selectedIndex = 0
    }

    /// - Parameter selectedStepID: what the user last picked, or nil for "whichever leads".
    ///   Honoured only while that question is still waiting (`SupervisorAnswerFocus.resolve`),
    ///   so a selection left over from an answered round decays instead of pinning the panel
    ///   to a question nobody is being asked.
    init?(questions: [SupervisorAnswerPayload], selectedStepID: String?) {
        guard !questions.isEmpty else { return nil }
        let resolved = SupervisorAnswerFocus.resolve(
            preferred: selectedStepID, among: questions.map(\.stepID))
        self.questions = questions
        // `?? 0` is unreachable — `resolve` returns an id from the list it was handed — and is
        // spelled anyway because the alternative to an unreachable default is a crash on an
        // index this type promises is valid.
        self.selectedIndex = questions.firstIndex { $0.stepID == resolved } ?? 0
    }

    /// The question on screen. Every surface that used to read the mode's single payload reads
    /// this instead, so nothing that renders one question had to learn about the rest.
    var selected: SupervisorAnswerPayload { questions[selectedIndex] }

    /// The row, in order. What the chips are keyed on and what `SupervisorAnswerFocus` measures
    /// "next" against.
    var stepIDs: [String] { questions.map(\.stepID) }
}
