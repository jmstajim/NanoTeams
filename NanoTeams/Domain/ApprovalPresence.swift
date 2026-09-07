import Foundation

/// Whether a HUMAN is there to answer an approval card in a given run.
///
/// The bash and computer-use gates hold an `.ask` action for a person's Allow/Deny; a run with
/// nobody to hold it for refuses the action instead. Two facts decide it, and both are the
/// run's, not the tool's: the team's `SupervisorMode` — `.autonomous` replaces the human with
/// `SupervisorAutoAnswerService` for QUESTIONS, but an approval card has no LLM answerer, so
/// there is no one — and Autovisor supervision, where the manager answers the task's questions
/// and, likewise, no card. `.off` counts as a human present: it removes `ask_supervisor` from
/// the ROLES, not the approval card from the person (see the `SupervisorMode` contract).
///
/// One predicate, read by everything that must agree with the gates: the gates themselves,
/// the schema resolver (which withholds a tool no call of which could ever be approved), the
/// role-list badge, the wire preview and the offline first-prompt renderer. Until 2026-09-07
/// the two gates each spelled it inline — identically, by luck.
nonisolated enum ApprovalPresence {
    static func humanPresent(supervisorMode: SupervisorMode, underAutovisor: Bool) -> Bool {
        supervisorMode != .autonomous && !underAutovisor
    }
}
