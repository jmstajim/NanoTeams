import Foundation

/// Single source of truth for resolving the effective `Team` of a task.
///
/// The resolution order PINS a started run to its `Run.teamID` so the roster
/// cannot be swapped underneath a live run. This closes the bug where a root
/// task whose `preferredTeamID` team was deleted mid-run silently fell back to
/// `workFolder.activeTeam`, causing the engine to seed a SECOND team's roster
/// into the same run (two rosters commingled in one run — the "two Tech Lead"
/// bug; see the CLAUDE.md TaskEngineStoreAdapter tree entry and
/// docs/delegation-feature.md spec #91).
///
/// Order:
///  1. `task.generatedTeam` — delegated/generated children own their team here.
///  2. **PIN**: the active run's `teamID` (`task.runs.last?.teamID`). If set but
///     unresolvable → `.failed` (deleted-mid-run). NEVER falls through to a
///     different team.
///  3. Legacy / no-run path: `task.preferredTeamID` lookup (run has no `teamID`
///     yet, or no run exists).
///  4. Child-task fail-fast: a child (`parentTaskID != nil`) must NOT inherit the
///     parent's `activeTeam` (Coding Agent self-recursion guard, spec #91) → `.failed`.
///  5. Root fallback: `activeTeam` (`.resolved` if present, else `.noTeam`).
///
/// Returns a 3-case `Outcome` so callers can distinguish a LOUD failure
/// (pinned-team-deleted / child-orphaned — surface a diagnostic, fail the run)
/// from the legitimate "no team selected yet" case (root task, nothing picked —
/// silent). The engine adapter / LLM services surface `.failed` and treat both
/// `.failed` and `.noTeam` as nil; the view-reachable `NTMSOrchestrator`
/// resolver coalesces silently to `Team.default` and MUST NOT mutate observable
/// state (it is called from SwiftUI `body`).
///
/// Pure and `nonisolated`: callers inject `teamProvider` (`workFolder.team(withID:)`)
/// and `activeTeam`. No side effects.
nonisolated enum TeamResolution {

    /// The three semantically-distinct outcomes of team resolution.
    enum Outcome {
        /// A team resolved successfully.
        case resolved(Team)
        /// Resolution failed loudly — the carried `reason` should be surfaced and
        /// the run should fail. Covers pinned-team-deleted (mid-run) and
        /// child-task-orphaned (no parent `activeTeam` inheritance).
        case failed(reason: String)
        /// No team is selected (root task, no pin / no preferred match, and
        /// `activeTeam` is nil). NOT an error — the UI shows nothing, the engine
        /// treats it as nil.
        case noTeam
    }

    static func resolve(
        task: NTMSTask,
        teamProvider: (NTMSID) -> Team?,
        activeTeam: Team?
    ) -> Outcome {
        // 1. generated/delegated children own their team
        if let generated = task.generatedTeam {
            return .resolved(generated)
        }

        // 2. PIN: the active run's teamID is authoritative once a run exists.
        if let run = task.runs.last, let pinned = run.teamID {
            if let team = teamProvider(pinned) {
                return .resolved(team)
            }
            return .failed(reason:
                "Run \(run.id) of task \(task.id) is pinned to team '\(pinned)' which no longer exists. "
                + "Refusing to swap rosters mid-run."
            )
        }

        // 3. Legacy / no-run path: resolve via preferredTeamID.
        if let preferredID = task.preferredTeamID, let team = teamProvider(preferredID) {
            return .resolved(team)
        }

        // 4. Child-task fail-fast — never inherit the parent's active team.
        if task.parentTaskID != nil {
            return .failed(reason:
                "Child task \(task.id) has no resolvable team (generatedTeam=nil, "
                + "preferredTeamID=\(task.preferredTeamID ?? "nil") not in workFolder). "
                + "Refusing to fall back to parent's active team to avoid Coding Agent self-recursion."
            )
        }

        // 5. Root fallback.
        if let activeTeam {
            return .resolved(activeTeam)
        }
        return .noTeam
    }
}
