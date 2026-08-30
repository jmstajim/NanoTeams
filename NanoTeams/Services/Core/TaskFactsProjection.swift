import Foundation
import Observation

/// Per-task FACTS the shell reacts to — derived status and the durable
/// "waiting on the Supervisor" flag — maintained incrementally on the write
/// side instead of being rebuilt on every SwiftUI body pass.
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
/// **One home.** Every mutation arrives through `TasksIndex.upsert`'s outcome or
/// through a whole-index replacement, so the projection cannot drift from the
/// index it mirrors; `WorkFolderProjectionParityTests` re-derives it from
/// `tasksIndex.tasks` after each path.
@Observable @MainActor
final class TaskFactsProjection {

    private(set) var statusByTaskID: [Int: TaskStatus] = [:]
    private(set) var waitStateByTaskID: [Int: SupervisorWaitState] = [:]

    /// Bumped only when some task's durable wait state changed — the seen-set sweep's
    /// `onChange` key: an `Int` compare, not a `Dictionary` one. There is deliberately no
    /// status twin; see the type's note.
    private(set) var waitRevision: Int = 0

    // MARK: - Incremental maintenance

    /// Applies one row. Bumps `waitRevision` only when that row's wait fact actually
    /// moved, so an `updatedAt` tick — the overwhelming majority of mutations — is inert.
    ///
    /// Deliberately says nothing about the PREVIOUS row. `TasksIndex.upsert` returns that,
    /// and one fact must not have two sources (CLAUDE.md #91) — this class is a projection
    /// OF rows, so it can only ever answer for the slice it keeps, and a consumer needing
    /// more would quietly grow a second, narrower history beside the index's.
    func apply(_ summary: TaskSummary) {
        statusByTaskID[summary.id] = summary.status
        let wait = SupervisorWaitState(summary)
        if waitStateByTaskID.updateValue(wait, forKey: summary.id) != wait {
            waitRevision &+= 1
        }
    }

    /// Whole-index replacement — work-folder open/switch, task DELETE, and any
    /// path that rebuilds the snapshot rather than upserting a row. O(T) once, on
    /// a path that is already O(T).
    ///
    /// Deletion has no dedicated `remove(taskID:)` on purpose: `removeTask` goes
    /// through `apply(_:)` like every other rebuild, so a second entry point would
    /// be a code path with no caller — the class this wave spent its time deleting.
    /// `TaskFactsProjectionParityTests` drives the delete path and asserts the row
    /// is gone.
    func replaceAll(with summaries: [TaskSummary]) {
        var statuses: [Int: TaskStatus] = [:]
        var waits: [Int: SupervisorWaitState] = [:]
        statuses.reserveCapacity(summaries.count)
        waits.reserveCapacity(summaries.count)
        for summary in summaries {
            statuses[summary.id] = summary.status
            waits[summary.id] = SupervisorWaitState(summary)
        }
        if statuses != statusByTaskID {
            statusByTaskID = statuses
        }
        if waits != waitStateByTaskID {
            waitStateByTaskID = waits
            waitRevision &+= 1
        }
    }

    /// Work folder closed: the ids are folder-scoped, so keeping them would let
    /// one folder's task 3 answer for another's.
    func clear() {
        if !statusByTaskID.isEmpty { statusByTaskID = [:] }
        if !waitStateByTaskID.isEmpty { waitStateByTaskID = [:]; waitRevision &+= 1 }
    }
}
