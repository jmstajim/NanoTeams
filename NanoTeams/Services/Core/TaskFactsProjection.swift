import Foundation
import Observation

/// Per-task FACTS the shell reacts to — derived status, the durable
/// "waiting on the Supervisor" flag, the row's stamp, and a revision of the
/// row LIST — maintained incrementally on the write side instead of being
/// rebuilt on every SwiftUI body pass.
///
/// **Why this exists.** `MainLayoutView` is the app's root content view and its
/// body carries six independent reads of `NTMSOrchestrator.snapshot` /
/// `activeTask`, both of which `applyTaskUpdate` writes on EVERY `mutateTask` —
/// i.e. on every LLM message, wire persist and tool result. Two of those reads
/// were `onChange` KEYS, and an `onChange` key is evaluated on every body pass
/// even when its handler never fires. Each built a whole `Dictionary` over
/// `tasksIndex.tasks` (a `map` to T tuples, then a T-entry hash table) and then
/// compared it against the previous one. `tasks` is append-only for the life of
/// a work folder — `closeTask` deliberately keeps the row, delegation adds child
/// rows — so that was Θ(T) allocation per event to answer, in the common case,
/// nothing at all: the status handler discards both parameters, and the wait
/// handler early-returns while the seen-set is empty.
///
/// **Why the wait fact has a revision and the status does not.** The seen-set sweep
/// needs an EDGE and must key on the DURABLE wait fact, not on `TaskStatus` — a
/// status-keyed sweep read recovery's launch-time parking as "answered" and wiped
/// the persisted set. The status side used to carry a twin `statusRevision` for the
/// Autovisor's event wake; that wake moved onto the orchestrator's own engine-state
/// seam on 2026-08-30 (a manager that runs unattended cannot depend on a view that
/// is gone while the main window is closed), which left the counter with no reader.
/// `statusByTaskID` stayed: it answers `MainLayoutView.activeTaskDerivedStatus`.
///
/// **Why the row LIST has a revision (`rowsRevision`).** `SidebarView` is mounted
/// for the app's lifetime and rebuilt its whole `[SidebarTaskItem]` array from
/// `tasksIndex.tasks` on every body pass — the filter, the map, the row filter and
/// the pill counts, Θ(T) per LLM message. The rows themselves change rarely: a
/// message append re-stamps ONE row that is already at the head. So the revision
/// moves only when the list a reader would build has changed — a row is new, a row
/// changed index, or a row differs from its previous self in any field EXCEPT
/// `updatedAt`. The stamp is excluded because `mutateTask` re-stamps its row on
/// every write (`NTMSOrchestrator+StateMutation.swift`), so a fingerprint that
/// included it would miss on exactly the hot path; it is served per row from
/// `updatedAtByTaskID` instead, so the visible "just now" never freezes inside a
/// cached row. The comparison is the whole row minus the stamp — deliberately wider
/// than the fields the sidebar renders today, so a field the view starts rendering
/// tomorrow cannot go stale; the price is a rebuild on flips of fields nobody
/// renders (`pinnedTeamID`, acceptance gates), which are rare.
///
/// **One home.** Every mutation arrives through `TasksIndex.upsert`'s outcome or
/// through a whole-index replacement, so the projection cannot drift from the
/// index it mirrors; `TaskFactsProjectionParityTests` re-derives it from
/// `tasksIndex.tasks` after each path.
@Observable @MainActor
final class TaskFactsProjection {

    private(set) var statusByTaskID: [Int: TaskStatus] = [:]
    private(set) var waitStateByTaskID: [Int: SupervisorWaitState] = [:]

    /// Each row's `updatedAt`, mirrored so a cached sidebar row can render the live
    /// stamp without carrying it (`SidebarTaskRow.updatedAt`). Same pattern as
    /// `statusByTaskID`: O(1) per row, written on every `apply`.
    private(set) var updatedAtByTaskID: [Int: Date] = [:]

    /// Bumped only when some task's durable wait state changed — the seen-set sweep's
    /// `onChange` key: an `Int` compare, not a `Dictionary` one. There is deliberately no
    /// status twin; see the type's note.
    private(set) var waitRevision: Int = 0

    /// Bumped when the row LIST a reader would build has changed: a row is new, changed
    /// index, or differs from its previous self in any field except `updatedAt`; and on
    /// every whole-index replacement or clear. Inert on an `updatedAt`-only tick of a row
    /// that stays put — the overwhelming majority of mutations. The sidebar's row memo
    /// (`SidebarViewLogic.RowsMemo`, keyed by `TaskManagementState.sidebarRows`) reads it.
    private(set) var rowsRevision: Int = 0

    // MARK: - Incremental maintenance

    /// Applies one row. Bumps `waitRevision` only when that row's wait fact actually
    /// moved, and `rowsRevision` only when the row is new, moved, or differs from its
    /// previous self in a field other than `updatedAt` — so a stamp-only tick of a row
    /// that keeps its index is inert on both counters.
    ///
    /// Receives `upsert`'s outcome rather than keeping its own history: `TasksIndex` is
    /// the one thing that holds rows and knows positions, so it is the one thing that can
    /// say what a row looked like a moment ago and whether it moved. A projection that
    /// remembered previous rows itself would be a second, narrower history beside the
    /// index's — one fact in two homes (CLAUDE.md #91).
    func apply(_ summary: TaskSummary, outcome: TasksIndex.UpsertOutcome) {
        statusByTaskID[summary.id] = summary.status
        let wait = SupervisorWaitState(summary)
        if waitStateByTaskID.updateValue(wait, forKey: summary.id) != wait {
            waitRevision &+= 1
        }
        updatedAtByTaskID[summary.id] = summary.updatedAt
        let rowChanged = outcome.previous.map { Self.differsIgnoringStamp($0, summary) } ?? true
        if outcome.moved || rowChanged {
            rowsRevision &+= 1
        }
    }

    /// Whole-row inequality with `updatedAt` neutralised — the synthesized
    /// `TaskSummary ==`, so a field added to the summary joins the fingerprint without
    /// anyone remembering to list it here.
    private static func differsIgnoringStamp(_ a: TaskSummary, _ b: TaskSummary) -> Bool {
        var a = a
        a.updatedAt = b.updatedAt
        return a != b
    }

    /// Whole-index replacement — work-folder open/switch, task DELETE, and any
    /// path that rebuilds the snapshot rather than upserting a row. O(T) once, on
    /// a path that is already O(T).
    ///
    /// `rowsRevision` bumps unconditionally here: deciding whether the rows really
    /// changed would need a retained copy of the previous rows, and this path is never
    /// per-message — one rebuild of the sidebar on a path that already rebuilt the
    /// snapshot is the cost it had before the memo existed.
    ///
    /// Deletion has no dedicated `remove(taskID:)` on purpose: `removeTask` goes
    /// through `apply(_:)` like every other rebuild, so a second entry point would
    /// be a code path with no caller — the class this wave spent its time deleting.
    /// `TaskFactsProjectionParityTests` drives the delete path and asserts the row
    /// is gone.
    func replaceAll(with summaries: [TaskSummary]) {
        var statuses: [Int: TaskStatus] = [:]
        var waits: [Int: SupervisorWaitState] = [:]
        var stamps: [Int: Date] = [:]
        statuses.reserveCapacity(summaries.count)
        waits.reserveCapacity(summaries.count)
        stamps.reserveCapacity(summaries.count)
        for summary in summaries {
            statuses[summary.id] = summary.status
            waits[summary.id] = SupervisorWaitState(summary)
            stamps[summary.id] = summary.updatedAt
        }
        if statuses != statusByTaskID {
            statusByTaskID = statuses
        }
        if waits != waitStateByTaskID {
            waitStateByTaskID = waits
            waitRevision &+= 1
        }
        if stamps != updatedAtByTaskID {
            updatedAtByTaskID = stamps
        }
        rowsRevision &+= 1
    }

    /// Work folder closed: the ids are folder-scoped, so keeping them would let
    /// one folder's task 3 answer for another's.
    func clear() {
        if !statusByTaskID.isEmpty { statusByTaskID = [:] }
        if !waitStateByTaskID.isEmpty { waitStateByTaskID = [:]; waitRevision &+= 1 }
        if !updatedAtByTaskID.isEmpty { updatedAtByTaskID = [:] }
        rowsRevision &+= 1
    }
}
