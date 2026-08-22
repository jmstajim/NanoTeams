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
/// **Why two revisions, never one.** The two facts drive different machinery and
/// the comments at `MainLayoutView`'s two `onChange` sites explain why merging
/// them is wrong: the status edge must keep waking the Autovisor on `.failed` /
/// `.done`, which the wait fact does not distinguish, and the seen-set sweep must
/// key on the DURABLE wait fact, not on `TaskStatus` — a status-keyed sweep read
/// recovery's launch-time parking as "answered" and wiped the persisted set.
///
/// **One home.** Every mutation arrives through `TasksIndex.upsert`'s outcome or
/// through a whole-index replacement, so the projection cannot drift from the
/// index it mirrors; `WorkFolderProjectionParityTests` re-derives it from
/// `tasksIndex.tasks` after each path.
@Observable @MainActor
final class TaskFactsProjection {

    private(set) var statusByTaskID: [Int: TaskStatus] = [:]
    private(set) var waitStateByTaskID: [Int: SupervisorWaitState] = [:]

    /// Bumped only when some task's derived status changed (or a row appeared /
    /// disappeared). Cheap `onChange` key: an `Int` compare, not a `Dictionary` one.
    private(set) var statusRevision: Int = 0

    /// Bumped only when some task's durable wait state changed. Deliberately
    /// separate from `statusRevision` — see the type's note.
    private(set) var waitRevision: Int = 0

    // MARK: - Incremental maintenance

    /// Applies one row. Bumps a revision only when that row's fact actually moved,
    /// so an `updatedAt` tick — the overwhelming majority of mutations — is inert.
    func apply(_ summary: TaskSummary) {
        let status = summary.status
        if statusByTaskID.updateValue(status, forKey: summary.id) != status {
            statusRevision &+= 1
        }
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
            statusRevision &+= 1
        }
        if waits != waitStateByTaskID {
            waitStateByTaskID = waits
            waitRevision &+= 1
        }
    }

    /// Work folder closed: the ids are folder-scoped, so keeping them would let
    /// one folder's task 3 answer for another's.
    func clear() {
        if !statusByTaskID.isEmpty { statusByTaskID = [:]; statusRevision &+= 1 }
        if !waitStateByTaskID.isEmpty { waitStateByTaskID = [:]; waitRevision &+= 1 }
    }
}
