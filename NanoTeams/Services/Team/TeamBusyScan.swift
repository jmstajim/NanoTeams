import Foundation

/// Answers "is a run currently in flight on this team?" for the Team Editor.
///
/// Motivation: renaming an artifact cascades into every role's
/// `requiredArtifacts` / `producesArtifacts` (see
/// `Team.renameArtifactReferences`), but `StepExecution.expectedArtifacts` is a
/// **creation-time snapshot** — `StepExecution.reset()` explicitly preserves it
/// and `findOrCreateStep` never refreshes it. So a rename landing mid-run
/// leaves the live step waiting on an artifact name no role produces any more,
/// with no code path that heals it. Refusing the edit is the honest option;
/// the alternative (rewriting live `StepExecution`s) reaches into run state the
/// editor has no business mutating.
///
/// Mirrors the precedent `NTMSRepository+Reconcile`'s running-role scan already
/// sets for *bundled* edits — this is the same guard on the *user*-edit path.
///
/// Pure and `nonisolated` so it can be unit-tested without an orchestrator; the
/// caller supplies the task list.
nonisolated enum TeamBusyScan {

    /// Task states in which a run will still consume `expectedArtifacts`.
    ///
    /// `.needsSupervisorAcceptance` is deliberately absent: its steps have all
    /// finished, so a rename cannot wedge execution. `.done` / `.failed` are
    /// terminal.
    static let inFlightStatuses: Set<TaskStatus> = [
        .running, .paused, .waiting, .needsSupervisorInput,
    ]

    /// True when any supplied task has a non-terminal run **pinned to**
    /// `teamID`.
    ///
    /// Pinning is read off `Run.teamID` — the same field
    /// `TaskEngineStoreAdapter.resolvedTeam` treats as authoritative for a
    /// started run — so a task whose team was switched mid-life is judged by
    /// the team its live run actually belongs to, not by `preferredTeamID`.
    /// A run with no `teamID` (legacy) is skipped rather than assumed to match:
    /// blocking every rename on every team would be worse than the hazard.
    static func hasInFlightRun(teamID: NTMSID, tasks: [NTMSTask]) -> Bool {
        tasks.contains { task in
            guard task.closedAt == nil else { return false }
            guard let run = task.runs.last, run.teamID == teamID else { return false }
            return inFlightStatuses.contains(task.derivedStatusFromActiveRun())
        }
    }
}
