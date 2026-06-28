import Foundation

// MARK: - In-loop human approval for `bash`

/// A UI-facing request that a `bash` command is HELD awaiting the human's
/// Allow / Deny decision. Published while the gate suspends the tool loop, so the
/// activity feed can render the approval card with buttons. One per command — the
/// gate awaits each command individually, so at most one is pending per step.
///
/// The decision goes DIRECTLY to the gate (Allow → the real command runs; Deny →
/// a denial is synthesized). The model is never asked to re-issue — the approval
/// bypasses it entirely.
nonisolated struct BashApprovalRequest: Identifiable, Hashable, Sendable {
    let taskID: Int
    let stepID: String
    let commandKey: String
    let command: String
    let workingDirectory: String?
    /// Whether to offer the "Always allow" button — `false` in always-confirm
    /// Manual mode, where nothing can persist a standing allow.
    let offerAlways: Bool
    let createdAt: Date

    var id: String { "\(taskID):\(stepID):\(commandKey)" }
}

/// Thread-safe one-shot bridge between the gate's `await` and the resolution that
/// ends it (a human Allow/Deny tap, or a Pause cancellation). The continuation is
/// resumed EXACTLY once — whichever resolution arrives first wins; later calls and
/// a resolve that races ahead of `attach` are absorbed. `@unchecked Sendable`
/// because the lock serializes all access to the mutable state.
nonisolated final class BashApprovalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BashApprovalDecision, Never>?
    private var settled: BashApprovalDecision?

    /// Registers the gate's continuation. If a decision already arrived (resolve
    /// raced ahead of the await registering), resume immediately with it.
    func attach(_ cont: CheckedContinuation<BashApprovalDecision, Never>) {
        let early: BashApprovalDecision? = lock.withLock {
            if let settled { return settled }
            continuation = cont
            return nil
        }
        if let early { cont.resume(returning: early) }
    }

    func resolve(_ decision: BashApprovalDecision) {
        let toResume: CheckedContinuation<BashApprovalDecision, Never>? = lock.withLock {
            guard settled == nil else { return nil }
            settled = decision
            defer { continuation = nil }
            return continuation
        }
        toResume?.resume(returning: decision)
    }
}

extension LLMExecutionService {

    /// Suspends the tool loop until the human approves or denies `command` — or the
    /// step is cancelled (Pause / teardown), which resolves to `.deny` so the await
    /// returns promptly and the command is never run unapproved. Publishes a
    /// `BashApprovalRequest` to the UI for the duration and keeps
    /// `pendingBashApprovals` populated so the on-demand "Ask AI" advisor can judge
    /// the held command. The model is NOT involved: on `.allow` the gate lets the
    /// real command run; on `.deny` it synthesizes a denial.
    func awaitBashApproval(
        taskID: Int,
        stepID: String,
        command: String,
        commandKey: String,
        workingDirectory: String?,
        offerAlways: Bool,
        judgeConfig: LLMConfig
    ) async -> BashApprovalDecision {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let waiter = BashApprovalWaiter()
        bashApprovalWaiters[key, default: [:]][commandKey] = waiter

        // ONE timestamp identifies this specific hold instance — shared by the
        // pending record, the published UI request, and the matching `didEnd` below,
        // so a late `didEnd` from a prior (cancelled / re-prompted) hold of the SAME
        // command can't clear a freshly-republished card (the discriminator in
        // `bashApprovalDidEnd` keys on it, not bare `commandKey`).
        let createdAt = MonotonicClock.shared.now()

        // Carry the held command so the "Ask AI" advisor (requestBashJudgeAdvice)
        // can judge it under the exact cwd while the human decides.
        pendingBashApprovals[key] = PendingBashApproval(
            commandKeys: [commandKey],
            commands: [command],
            workingDirectories: [workingDirectory],
            question: command,
            judgeConfig: judgeConfig,
            createdAt: createdAt)

        delegate?.bashApprovalDidBegin(
            BashApprovalRequest(
                taskID: taskID, stepID: stepID, commandKey: commandKey, command: command,
                workingDirectory: workingDirectory, offerAlways: offerAlways,
                createdAt: createdAt))

        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<BashApprovalDecision, Never>) in
                waiter.attach(cont)
            }
        } onCancel: {
            // Pause / work-folder switch cancels the step task. Fail safe — never run
            // an unapproved command; on resume the step re-runs and re-prompts.
            waiter.resolve(.deny)
        }

        bashApprovalWaiters[key]?[commandKey] = nil
        if bashApprovalWaiters[key]?.isEmpty == true { bashApprovalWaiters[key] = nil }
        pendingBashApprovals[key] = nil
        delegate?.bashApprovalDidEnd(
            taskID: taskID, stepID: stepID, commandKey: commandKey, createdAt: createdAt)
        return decision
    }

    /// Resolves a held `bash` approval (called from the orchestrator when the human
    /// taps Allow / Deny). No-op if no waiter is registered (already resolved or torn
    /// down) — so a double-tap or a tap after Pause can't crash on a spent continuation.
    func resolveBashApproval(
        taskID: Int, stepID: String, commandKey: String, decision: BashApprovalDecision
    ) {
        bashApprovalWaiters[TaskStepKey(taskID: taskID, stepID: stepID)]?[commandKey]?.resolve(decision)
    }

    /// Resumes every still-pending waiter for a step with `.deny` (teardown safety —
    /// called from `clearBashState`). Idempotent: an already-settled waiter no-ops.
    func failPendingBashApprovals(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        bashApprovalWaiters[key]?.values.forEach { $0.resolve(.deny) }
        bashApprovalWaiters[key] = nil
    }
}
