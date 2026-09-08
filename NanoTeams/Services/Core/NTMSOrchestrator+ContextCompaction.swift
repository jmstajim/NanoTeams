import Foundation

/// The Supervisor-facing half of context compaction: one action behind the composer's
/// context-fill indicator.
///
/// The two mechanisms below are not a fallback pair — they are the two states a step can be
/// in, and the wrong one for the state does nothing. A RUNNING step owns its wire inside a
/// tool loop, so the epoch is a flag consumed at the top of its next iteration; a suspended
/// one has no loop, so the epoch runs on its own and writes through a compare-and-swap.
extension NTMSOrchestrator {

    /// Compacts the conversation of one role in one task.
    ///
    /// - Returns: `true` when an epoch was armed or completed. `false` posts an info banner
    ///   saying why — a click that quietly does nothing is the failure mode this whole
    ///   indicator exists to remove.
    @discardableResult
    func compactRoleContext(taskID: Int, roleID: String) async -> Bool {
        // Resolve by `effectiveRoleID` against the latest run — the same predicate every
        // other role action uses, so a role with (legacy) duplicate step ids can never have
        // its compaction target a different step than its cancel.
        guard let step = loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == roleID })
        else {
            lastInfoMessage = "This role has no conversation to compact yet."
            return false
        }

        guard !llmExecutionService.isCompacting(stepID: step.id, taskID: taskID) else {
            lastInfoMessage = "This role is already compacting."
            return false
        }

        if llmExecutionService.requestCompaction(stepID: step.id, taskID: taskID) {
            // Armed, not done: the epoch runs at the top of the next iteration, which is the
            // only point in a live step where replacing the wire is safe.
            lastInfoMessage = "Compacting after the current turn."
            return true
        }

        guard await llmExecutionService.compactSuspendedStep(stepID: step.id, taskID: taskID)
        else {
            // `compactSuspendedStep` posts its own banner for the cases it can name (nothing
            // to fold, no summary, the conversation moved). This covers the rest: a step in a
            // status an out-of-loop epoch is not defined for.
            if lastInfoMessage == nil {
                lastInfoMessage = "This role cannot be compacted in its current state."
            }
            return false
        }
        return true
    }
}
