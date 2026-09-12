import Foundation

/// The Supervisor asking a parked role to re-ask its question as a questionnaire.
///
/// A role parks on a plain `ask_supervisor` and puts the whole decision in one run of prose.
/// Sometimes that decision is not one question at all — it has a scope, an approach, edges,
/// and a failure mode, and answering it in prose means writing all four out by hand. The
/// `[ Ask as form ]` button sends this directive instead, and the role re-asks with
/// `ask_supervisor_form`: one question per side, each with the options it would pick from.
///
/// It reaches the role as the tool RESULT of its own `ask_supervisor` — that is the only
/// channel a parked step has (`StepMessagingService.answerSupervisorQuestion`), and it is why
/// the first sentence says the question was not answered: without it the role reads a
/// directive in the slot where it expected a decision.
///
/// Answering it is always possible: resolver step 4-bis pairs the two ask tools in both
/// directions, and both strips that can remove the form remove `ToolNames.supervisorAskTools`
/// whole — so a role that managed to park on the plain ask holds the form on its next
/// iteration by construction.
nonisolated enum SupervisorQuestionnaireRequest {

    /// The sides a decision is broken into.
    ///
    /// Named literally, and that is deliberate: a local model asked to "cover every side"
    /// abstractly returns the same question with a menu bolted on. Four concrete axes are the
    /// same lever R2.8.1 applies to enum values — the enumeration is what makes the
    /// decomposition happen.
    static let axes = ["its scope", "the approach", "the edges", "what happens on failure"]

    /// runtime-prompt
    ///
    /// One run of prose, because `compose` uses the blank line to separate it from whatever the
    /// Supervisor typed beside the button.
    ///
    /// The kinds are spelled from `SupervisorInquiryKind` rather than typed out, so a renamed
    /// case cannot leave the directive teaching a value the decoder rejects. `multi_choice` is
    /// deliberately not offered: one decision per side is what makes the answers comparable,
    /// and the card always keeps an "other" escape anyway.
    ///
    /// No ceiling on the number of questions — a ceiling stated here would be an exception
    /// clause inside a standing instruction (R4.4.1). There is none at the tool seam either
    /// since 2026-09-13 (`SupervisorInquiryLimits`): the axes below name the shape this
    /// directive asks for, not a limit anything enforces.
    static let directive =
        "The question was not answered. Ask it again as a form that covers the decision from "
            + "every side it has — \(axes.joined(separator: ", ")): call "
            + "`\(ToolNames.askSupervisorForm)` with one `questions` entry per side, each a "
            + "\(SupervisorInquiryKind.singleChoice.rawValue) with its options, and one "
            + "\(SupervisorInquiryKind.freeText.rawValue) entry for what the options miss."

    /// The text that reaches the role: the directive, then whatever the Supervisor had already
    /// typed in the answer field.
    ///
    /// The note narrows the form the role is about to write ("three design directions, not
    /// two"), so it rides BELOW the directive — leading with it would put a fragment of prose
    /// in the slot the role reads as its answer.
    static func compose(note: String?) -> String {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? directive : directive + "\n\n" + trimmed
    }

    /// Whether the button belongs beside this question.
    ///
    /// Two conditions, and each closes a directive that would be a false statement:
    ///
    /// - A step parked on a questionnaire already shows the card with the options; asking it
    ///   to produce one would ask for what is on screen.
    /// - A park the ROLE did not raise — a loop or drift cap, the Autovisor's idle park — has
    ///   no question of its own, and the directive opens by saying the question was not
    ///   answered. `askCallID` (`StepExecution.activeSupervisorQuestionID`, carried by
    ///   `SupervisorQuestionInbox.PendingQuestion`) is nil on exactly that branch, and nil
    ///   again once the park is resolved.
    ///
    /// The policy lives here rather than in each host because three surfaces render the same
    /// question — the docked composer, the Watchtower banner, and the Quick Capture answer
    /// panel — and `NTMSOrchestrator.requestQuestionnaire` refuses against this same function,
    /// so the API cannot reach a state the UI declines to offer.
    static func isAvailable(inquiry: SupervisorInquiry?, askCallID: UUID?) -> Bool {
        inquiry == nil && askCallID != nil
    }
}
