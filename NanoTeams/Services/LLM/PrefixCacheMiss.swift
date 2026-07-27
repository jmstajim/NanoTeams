import Foundation

/// One prompt-prefix (KV) cache miss, as it travels from the detector to the UI.
///
/// A value rather than five parameters because the group moves together across every hop —
/// `LLMExecutionService` → `LLMStateDelegate` → `NTMSOrchestrator` → `PrefixCacheReporter.report`
/// — and each hop that re-spells it is a place two arguments can transpose in silence. That was
/// not hypothetical here: `taskID` and `runID` are both `Int`, and `modelName` and `owner` were
/// both `String`. Same shape and same reason as the sibling `BashApprovalRequest` /
/// `ComputerUseApprovalRequest` that already cross this protocol.
///
/// **`taskID` is DERIVED, never stored.** It is a fact about the owner, so carrying it separately
/// makes a disagreeing pair representable. Only `.step` owners belong to a task: a `.chain`
/// (consultation, meeting turn, delegated answer) and a `.oneShot` (judge, Vision, one context
/// generation) genuinely have no task, and `nil` is the honest answer that routes them past the
/// on-screen banner gate rather than onto some arbitrary task's screen.
nonisolated struct PrefixCacheMiss: Hashable, Sendable {

    /// Who lost the prefix. The typed owner, not its rendered name — the reporter needs the
    /// identity to derive the task, and `displayName` is a lossy projection of it.
    let owner: LLMCallOwner

    /// The run the miss happened in, for the banner latch. `nil` when the caller has no run.
    let runID: Int?

    /// The model that had to re-process, for the banner text.
    let modelName: String

    let diagnosis: PrefixCachePolicy.Diagnosis

    /// The task this miss belongs to, or `nil` for an owner that is not a step.
    var taskID: Int? {
        if case .step(let taskID, _) = owner { return taskID }
        return nil
    }
}
