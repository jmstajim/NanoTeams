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

    /// Which rung of the order a task lands on. Extracted so `resolve` and
    /// `resolveTeamID` cannot drift apart — a second hand-written copy of the
    /// order is exactly how the reconcile's running-role scan came to attribute
    /// busy tasks to `preferredTeamID` while the rest of the app used the run pin.
    private enum Pin {
        case generated(Team)
        case pinned(NTMSID, runID: Int)
        case pinnedMissing(NTMSID, runID: Int)
        case preferred(Team)
        case childOrphan
        case active(Team)
        case none
    }

    private static func pin(
        task: NTMSTask,
        teamProvider: (NTMSID) -> Team?,
        activeTeam: Team?
    ) -> Pin {
        // 1. generated/delegated children own their team
        if let generated = task.generatedTeam {
            return .generated(generated)
        }

        // 2. PIN: the active run's teamID is authoritative once a run exists.
        if let run = task.runs.last, let pinned = run.teamID {
            return teamProvider(pinned) != nil
                ? .pinned(pinned, runID: run.id)
                : .pinnedMissing(pinned, runID: run.id)
        }

        // 3. Legacy / no-run path: resolve via preferredTeamID.
        if let preferredID = task.preferredTeamID, let team = teamProvider(preferredID) {
            return .preferred(team)
        }

        // 4. Child-task fail-fast — never inherit the parent's active team.
        if task.parentTaskID != nil {
            return .childOrphan
        }

        // 5. Root fallback.
        if let activeTeam {
            return .active(activeTeam)
        }
        return .none
    }

    static func resolve(
        task: NTMSTask,
        teamProvider: (NTMSID) -> Team?,
        activeTeam: Team?
    ) -> Outcome {
        switch pin(task: task, teamProvider: teamProvider, activeTeam: activeTeam) {
        case .generated(let team):
            return .resolved(team)
        case .pinned(let id, _):
            // `pin` already proved this resolves.
            return teamProvider(id).map { .resolved($0) } ?? .noTeam
        case .pinnedMissing(let id, let runID):
            return .failed(reason:
                "Run \(runID) of task \(task.id) is pinned to team '\(id)' which no longer exists. "
                    + "Refusing to swap rosters mid-run."
            )
        case .preferred(let team):
            return .resolved(team)
        case .childOrphan:
            return .failed(reason:
                "Child task \(task.id) has no resolvable team (generatedTeam=nil, "
                    + "preferredTeamID=\(task.preferredTeamID ?? "nil") not in workFolder). "
                    + "Refusing to fall back to parent's active team to avoid Coding Agent self-recursion."
            )
        case .active(let team):
            return .resolved(team)
        case .none:
            return .noTeam
        }
    }

    /// The id-only half of `resolve`'s order, for callers that need "which team
    /// is this task bound to" without a roster.
    ///
    /// Built for the reconcile's running-role scan, which lives in the
    /// `nonisolated` repository layer and only has a raw decoded `NTMSTask`.
    /// That scan used to read `generatedTeam ?? preferredTeamID` directly, which
    /// disagrees with the run pin the rest of the app honours — so it deferred
    /// the wrong team (freezing its updates) and missed the team that was
    /// actually running (rewriting its `toolIDs` mid-flight).
    ///
    /// Returns the pinned id even when it no longer resolves: the caller is
    /// asking "which team does this task claim", and for a deferral decision a
    /// dangling pin is still the honest answer.
    static func resolveTeamID(
        task: NTMSTask,
        teamProvider: (NTMSID) -> Team?,
        activeTeam: Team?
    ) -> NTMSID? {
        switch pin(task: task, teamProvider: teamProvider, activeTeam: activeTeam) {
        case .generated(let team): return team.id
        case .pinned(let id, _): return id
        case .pinnedMissing(let id, _): return id
        case .preferred(let team): return team.id
        case .childOrphan: return nil
        case .active(let team): return team.id
        case .none: return nil
        }
    }

    /// Settings of the task's effective team, resolved from an EXPLICIT snapshot.
    ///
    /// Usable before `apply(snapshot)` has published the projection to the orchestrator —
    /// which is exactly what `openWorkFolder`'s stale-status recovery needs, since it runs
    /// on the raw snapshot so the sidebar never flashes the un-recovered status.
    ///
    /// Returns `nil` for `.failed` / `.noTeam` rather than substituting a fallback team's
    /// settings. `NTMSOrchestrator.resolvedTeam(for:)` is deliberately NOT reused here: it
    /// coalesces to `activeTeam ?? Team.default` for display purposes, which would silently
    /// apply a DIFFERENT team's acceptance mode to a task pinned to a deleted team.
    /// Callers decide what `nil` means (see `AcceptanceService.Gate`).
    static func teamSettings(for task: NTMSTask, in projection: WorkFolderProjection) -> TeamSettings? {
        team(for: task, in: projection)?.settings
    }

    /// The task's effective TEAM, resolved from an EXPLICIT snapshot — same rule as
    /// `teamSettings(for:in:)`, which is now derived from this so the two cannot disagree.
    ///
    /// Added for `StatusRecoveryService`, which needs the ROSTER (to strip role statuses whose
    /// role no longer exists) as well as the settings. Resolving once and passing the team down
    /// also removes the hazard `recoverStaleStatusesAcrossIndex` already worried about in its
    /// own comment: a second resolve could disagree with the first if the snapshot moved across
    /// an `await`.
    ///
    /// `nil` means "could not resolve" — a pinned team that was deleted, or no team at all — and
    /// is NOT the same as "resolved to a team with an empty roster". Callers must keep those
    /// apart (#97): stripping statuses on `nil` would empty the roster of every task pinned to a
    /// deleted team.
    static func team(for task: NTMSTask, in projection: WorkFolderProjection) -> Team? {
        switch resolve(
            task: task,
            teamProvider: { projection.team(withID: $0) },
            activeTeam: projection.activeTeam
        ) {
        case .resolved(let team):
            return team
        case .failed, .noTeam:
            return nil
        }
    }
}
