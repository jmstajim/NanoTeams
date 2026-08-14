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

nonisolated extension TaskSummary {

    /// True when this index entry MIGHT be carrying the vacuous chat-mode value the
    /// Generated Team placeholder used to seed — i.e. it is worth paying one `task.json`
    /// read to decide. Never a verdict on its own: the verdict is `TeamResolution.resolveTeamID`
    /// against the loaded task (see `NTMSRepository.normalizeGeneratedPlaceholderChatMode`).
    ///
    /// `isChatMode == false` can never be the bug — the old seed only ever erred toward
    /// `true` — so the honest majority of the index is filtered out with no I/O at all.
    ///
    /// A nil `pinnedTeamID` is treated as UNDECIDABLE, not as "not a candidate".
    /// `toSummary` derives the pin from `runs.last?.teamID` and `createTask` leaves `runs`
    /// empty, so a generated task that was created and never started has no pin to test —
    /// yet it still appears in the Autovisor's `list_tasks` as an open-ended chat it is
    /// told to `control_task close`. The extra reads that costs are bounded by "chat-mode
    /// tasks with no started run", a handful per folder, paid once per work-folder open.
    ///
    /// An ADOPTED generated task is excluded for free: `applyGeneratedTeamSuccess` re-pins
    /// `run.teamID` to the generated team's own `_gen_<uuid>`, so its summary never names
    /// the placeholder.
    func mayCarryPlaceholderChatMode(placeholderTeamIDs: Set<NTMSID>) -> Bool {
        guard isChatMode else { return false }
        guard let pinnedTeamID else { return true }
        return placeholderTeamIDs.contains(pinnedTeamID)
    }
}
