import Foundation

/// The per-step registry of held approvals, one entry per thing a human has yet to decide.
///
/// `ApprovalWaiter` already owns the hard part — the lock, the single resume, the resolve that
/// races ahead of the await. What sat around it was duplicated: the same
/// `[TaskStepKey: [String: Waiter]]` shape, the same register/release/prune-the-empty-inner-map
/// dance, and the same two teardown sweeps, written once for `bash` and once for computer-use.
/// The MCP gate is the third caller, and a third byte-clone of a structure whose bugs are
/// invisible (a leaked waiter is a role that never resumes) is how the clones drift.
///
/// **Keyed by `TaskStepKey`, never by stepID alone** (invariant #5): `StepExecution.id` is the
/// role id, so two tasks on one team share it, and a table keyed by stepID would let one task's
/// Pause resolve another task's held command.
nonisolated struct ApprovalHoldTable<Decision: Sendable> {

    private var holdsByStep: [TaskStepKey: [String: ApprovalWaiter<Decision>]] = [:]

    init() {}

    // MARK: - Reading

    /// The holds of one step, or `nil` when it has none. Read by tests and by the "what is
    /// this step waiting on" surfaces; the table prunes an emptied inner map, so `nil` and
    /// "no holds" are the same answer.
    subscript(key: TaskStepKey) -> [String: ApprovalWaiter<Decision>]? { holdsByStep[key] }

    var isEmpty: Bool { holdsByStep.isEmpty }

    var count: Int { holdsByStep.count }

    // MARK: - Writing

    /// Registers a hold and hands back its waiter. Replacing an existing hold under the same
    /// key is deliberate: a re-issued identical call means the earlier waiter's continuation
    /// is already gone (the gate that owned it returned), and keeping it would pin a
    /// continuation nothing will ever resume.
    mutating func register(_ key: TaskStepKey, holdKey: String) -> ApprovalWaiter<Decision> {
        let waiter = ApprovalWaiter<Decision>()
        holdsByStep[key, default: [:]][holdKey] = waiter
        return waiter
    }

    /// Drops one hold after its gate has resumed, pruning the step's entry when it was the
    /// last one — an empty inner map left behind reads as "this step is holding something"
    /// to every `[key] != nil` check.
    mutating func release(_ key: TaskStepKey, holdKey: String) {
        holdsByStep[key]?[holdKey] = nil
        if holdsByStep[key]?.isEmpty == true { holdsByStep[key] = nil }
    }

    /// Delivers a decision to one hold. A no-op when nothing is held — a double-tap, or a tap
    /// that lands after Pause, must not crash.
    func resolve(_ key: TaskStepKey, holdKey: String, with decision: Decision) {
        holdsByStep[key]?[holdKey]?.resolve(decision)
    }

    /// Fails every hold of one step. Idempotent: `ApprovalWaiter` absorbs a second resolution,
    /// so a human decision that landed first is not overwritten.
    mutating func failAll(_ key: TaskStepKey, with decision: Decision) {
        holdsByStep[key]?.values.forEach { $0.resolve(decision) }
        holdsByStep[key] = nil
    }

    /// Fails every hold of every step — the teardown sweep for a work-folder switch, a reset,
    /// or app termination. Without it a held gate keeps its continuation alive into the next
    /// folder, where task ids repeat.
    mutating func failAll(with decision: Decision) {
        holdsByStep.values.forEach { $0.values.forEach { $0.resolve(decision) } }
        holdsByStep.removeAll()
    }
}
