import Foundation

// MARK: - In-loop human approval for computer-use actions

/// A UI-facing request that a computer-use action is HELD awaiting the human's Allow / Deny /
/// "Always allow in this app" decision. Published while the gate suspends the tool loop so the
/// activity feed can render the approval card with a screenshot + target crosshair preview.
///
/// The `screenshotBase64` is the last-captured image (in-memory only — never persisted), so the
/// card can show what the model is about to touch. `targetX`/`targetY` are image-pixel coordinates
/// for a crosshair overlay (click/scroll only).
nonisolated struct ComputerUseApprovalRequest: Identifiable, Hashable, Sendable {
    let taskID: Int
    let stepID: String
    let actionKey: String
    let actionSummary: String
    let targetApp: String?
    /// Offer the "Always allow in <app> this run" button (only when a specific app is targeted).
    let offerAlways: Bool
    let screenshotBase64: String?
    let targetX: Int?
    let targetY: Int?
    let createdAt: Date

    var id: String { "\(taskID):\(stepID):\(actionKey)" }
}

/// One-shot approval bridge for computer-use — the generic `ApprovalWaiter` specialized to a
/// `ComputerUseApprovalDecision` (see `ApprovalWaiter` for the lock/race semantics).
typealias ComputerUseApprovalWaiter = ApprovalWaiter<ComputerUseApprovalDecision>

extension LLMExecutionService {

    /// Suspends the tool loop until the human approves or denies the action — or the step is
    /// cancelled (Pause / teardown), which resolves to `.cancelled` (fail-safe; never runs an
    /// unapproved action). Publishes a `ComputerUseApprovalRequest` to the UI for the duration.
    func awaitComputerUseApproval(request: ComputerUseApprovalRequest) async -> ComputerUseApprovalDecision {
        let key = TaskStepKey(taskID: request.taskID, stepID: request.stepID)
        let waiter = ComputerUseApprovalWaiter()
        computerUseApprovalWaiters[key, default: [:]][request.actionKey] = waiter

        delegate?.computerUseApprovalDidBegin(request)

        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ComputerUseApprovalDecision, Never>) in
                waiter.attach(cont)
            }
        } onCancel: {
            // `.cancelled`, not `.deny` — see `BashApprovalDecision.cancelled`.
            waiter.resolve(.cancelled)
        }

        computerUseApprovalWaiters[key]?[request.actionKey] = nil
        if computerUseApprovalWaiters[key]?.isEmpty == true { computerUseApprovalWaiters[key] = nil }
        delegate?.computerUseApprovalDidEnd(
            taskID: request.taskID, stepID: request.stepID,
            actionKey: request.actionKey, createdAt: request.createdAt)
        return decision
    }

    /// Resolves a held computer-use approval (called from the orchestrator on a button tap).
    /// No-op if no waiter is registered — a double-tap or a tap after Pause can't crash.
    func resolveComputerUseApproval(
        taskID: Int, stepID: String, actionKey: String, decision: ComputerUseApprovalDecision
    ) {
        computerUseApprovalWaiters[TaskStepKey(taskID: taskID, stepID: stepID)]?[actionKey]?.resolve(decision)
    }

    /// Resumes every still-pending computer-use waiter for a step with `.cancelled` (teardown
    /// safety). Idempotent — a human's decision that landed first is not overwritten.
    func failPendingComputerUseApprovals(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        computerUseApprovalWaiters[key]?.values.forEach { $0.resolve(.cancelled) }
        computerUseApprovalWaiters[key] = nil
    }

    /// Records a per-run "always allow in this app" grant (runtime only, not persisted).
    func allowComputerUseAppForRun(taskID: Int, bundleOrName: String) {
        computerUseSessionAllowedApps[taskID, default: []].insert(bundleOrName.lowercased())
    }
}
