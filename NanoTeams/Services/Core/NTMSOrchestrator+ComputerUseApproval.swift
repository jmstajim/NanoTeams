import Foundation

/// The human's choice on the computer-use approval card.
nonisolated enum ComputerUseApprovalChoice: Hashable { case allow, deny, alwaysAllowApp }

extension NTMSOrchestrator {

    /// `LLMStateDelegate`: the gate began holding an action for human approval. Publish it so
    /// the activity feed renders the approval card with a screenshot + crosshair preview.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func computerUseApprovalDidBegin(_ request: ComputerUseApprovalRequest) {
        computerUseApprovalRequests[TaskStepKey(taskID: request.taskID, stepID: request.stepID)] = request
    }

    /// `LLMStateDelegate`: the gate stopped holding an action. Clears the card ONLY if it's the
    /// SAME hold instance (`createdAt` + `actionKey` discriminators) so a late end can't wipe a
    /// freshly-republished card.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func computerUseApprovalDidEnd(taskID: Int, stepID: String, actionKey: String, createdAt: Date) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if let request = computerUseApprovalRequests[key],
           request.actionKey == actionKey, request.createdAt == createdAt {
            computerUseApprovalRequests[key] = nil
        }
    }

    /// `LLMStateDelegate`: drop every published computer-use approval card on full teardown.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func clearAllComputerUseApprovalRequests() {
        computerUseApprovalRequests.removeAll()
    }

    /// Button surface: resolve a HELD computer-use action DIRECTLY — bypassing the model.
    /// `.alwaysAllowApp` also records a per-run grant so further actions on that app auto-allow.
    func resolveComputerUseApproval(
        taskID: Int, stepID: String, actionKey: String, choice: ComputerUseApprovalChoice
    ) {
        let decision: ComputerUseApprovalDecision
        switch choice {
        case .allow: decision = .allow
        case .deny: decision = .deny
        case .alwaysAllowApp: decision = .alwaysAllowApp
        }
        llmExecutionService.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: actionKey, decision: decision)
    }
}
