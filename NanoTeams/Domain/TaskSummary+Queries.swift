//
//  TaskSummary+Queries.swift
//  NanoTeams
//
//  Read-only query layer for `TaskSummary`, split out of `NTMSTask.swift` (past the
//  ~400-line God-Object threshold) per SRP — same shape as `Team+Queries.swift`.
//
//  `nonisolated` is required: the app target defaults every type to `@MainActor`, and a
//  type's `nonisolated` does NOT propagate to its extensions in other files.
//

import Foundation

/// Verdict of the INDEX-ONLY half of the generated-placeholder chat-mode heal:
/// can this row's candidacy be decided without loading `task.json`?
///
/// Until 2026-08-21 the filter was a Bool whose "undecidable" arm read as
/// "candidate", so every never-run chat-mode task — including plain Coding
/// Assistant tasks, the default team — paid one blob read on EVERY work-folder
/// open, forever. Tri-state makes unknown a first-class answer (CLAUDE.md #91):
/// `.unknown` rows pay the read ONCE, the sweep's convergence write stamps the
/// deciding facts into the row, and the next open decides from the index alone.
nonisolated enum PlaceholderChatCandidacy {
    case decidedCandidate
    case decidedClear
    case unknown
}

nonisolated extension TaskSummary {

    /// Replicates `TeamResolution.resolveTeamID`'s id-only rung order against the
    /// summary's mirrored facts — keep the two in lockstep (the sweep's blob-side
    /// verdict still uses `resolveTeamID`, and they must agree):
    ///   1. `hasGeneratedTeam == true` → adopted team, never the placeholder → clear.
    ///   2. run pin (`pinnedTeamID`) → placeholder-membership decides.
    ///   3. `preferredTeamID`, only when it RESOLVES against the live teams →
    ///      membership decides (an unresolvable preferred falls through, exactly
    ///      as `TeamResolution`'s rung 3 does).
    ///   4. a child task (`parentTaskID != nil`) resolves to `.childOrphan` = nil
    ///      → never the placeholder → clear.
    ///   5. root fallback: the effective active team's membership decides.
    ///
    /// `isChatMode == false` can never be the bug — the old seed only ever erred
    /// toward `true`. `hasGeneratedTeam == nil` is a row written before the field
    /// existed: `.unknown`, pay the read, never assume.
    func placeholderChatCandidacy(
        placeholderTeamIDs: Set<NTMSID>,
        resolvableTeamIDs: Set<NTMSID>,
        activeTeamIsPlaceholder: Bool
    ) -> PlaceholderChatCandidacy {
        guard isChatMode else { return .decidedClear }
        guard let hasGeneratedTeam else { return .unknown }
        if hasGeneratedTeam { return .decidedClear }
        if let pinnedTeamID {
            return placeholderTeamIDs.contains(pinnedTeamID) ? .decidedCandidate : .decidedClear
        }
        if let preferredTeamID, resolvableTeamIDs.contains(preferredTeamID) {
            return placeholderTeamIDs.contains(preferredTeamID) ? .decidedCandidate : .decidedClear
        }
        if parentTaskID != nil { return .decidedClear }
        return activeTeamIsPlaceholder ? .decidedCandidate : .decidedClear
    }
}

nonisolated extension TaskSummary {

    /// "Someone is still owed a Supervisor answer on this task."
    ///
    /// The ONLY sanctioned way to read `hasPendingSupervisorInput` affirmatively.
    /// Deliberately total: an index row written before the field existed reads
    /// `false` here, and callers that must distinguish "no" from "don't know"
    /// ask `supervisorInputStateIsKnown` as well.
    ///
    /// Do NOT substitute `status == .needsSupervisorInput`. `StatusRecoveryService`
    /// parks every waiting step to `.paused` at launch while leaving the question
    /// intact, so the status says "answered" for a task that is still waiting —
    /// which is how an already-read chat came back as unanswered after a restart.
    var isWaitingForSupervisor: Bool { hasPendingSupervisorInput == true }

    /// False only for a legacy index row that predates the field. A destructive
    /// sweep must bail on these rather than treat unknown as "answered".
    var supervisorInputStateIsKnown: Bool { hasPendingSupervisorInput != nil }

    /// "A role on this task is parked on an acceptance decision."
    ///
    /// The ONLY sanctioned way to read `hasRolesAwaitingAcceptance` affirmatively, and
    /// deliberately total: a row written before the field existed reads `false` here, so an
    /// unknown row wakes nobody rather than waking on a guess.
    ///
    /// Do NOT substitute the engine mirror (`taskEngineStates[id] == .needsAcceptance`).
    /// After a relaunch `mapDerivedStatusToEngineState` seeds `.paused` for a task whose row
    /// still records the gate, so the mirror and the row answer different questions with
    /// different lifetimes (CLAUDE.md #91) — the same reason `isWaitingForSupervisor` exists
    /// beside `status == .needsSupervisorInput`.
    var hasRoleAtAcceptanceGate: Bool { hasRolesAwaitingAcceptance == true }

    /// False only for a legacy index row that predates the field — "don't know", which a
    /// destructive sweep must not read as "no gate".
    var acceptanceGateStateIsKnown: Bool { hasRolesAwaitingAcceptance != nil }
}

/// What the task index knows about "is this task waiting on the Supervisor".
///
/// Three cases, not two: `.unknown` is an index row written before
/// `TaskSummary.hasPendingSupervisorInput` existed. Collapsing it into
/// `.notWaiting` is exactly the mistake that would wipe every persisted "seen"
/// flag on the first launch after the upgrade, so every consumer must branch on
/// it explicitly rather than relying on a `Bool` default.
nonisolated enum SupervisorWaitState: Equatable, Sendable {
    case waiting
    case notWaiting
    case unknown

    init(_ summary: TaskSummary) {
        switch summary.hasPendingSupervisorInput {
        case .some(true):  self = .waiting
        case .some(false): self = .notWaiting
        case .none:        self = .unknown
        }
    }
}
