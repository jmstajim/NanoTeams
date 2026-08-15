import Foundation

/// The human's choice on the bash approval card. `.alwaysAllow` is offered only in
/// non-Manual modes (where a standing allow rule can persist).
nonisolated enum BashApprovalChoice: Hashable { case allow, deny, alwaysAllow }

// MARK: - On-demand bash judge advice (the "Ask AI" affordance)

extension NTMSOrchestrator {

    // MARK: - In-loop Allow / Deny (the buttons that bypass the model)

    /// `LLMStateDelegate`: the gate began holding a command for human approval.
    /// Publish it so the activity feed renders the approval card with buttons.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func bashApprovalDidBegin(_ request: BashApprovalRequest) {
        bashApprovalRequests[TaskStepKey(taskID: request.taskID, stepID: request.stepID)] = request
    }

    /// `LLMStateDelegate`: the gate stopped holding a command (decided or cancelled).
    /// Clears the card ONLY if it's the SAME hold instance (`createdAt` discriminator,
    /// not bare `commandKey`) — so a late end from a cancelled-then-re-prompted hold
    /// of the same command can't wipe the freshly-republished card and wedge the step.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func bashApprovalDidEnd(taskID: Int, stepID: String, commandKey: String, createdAt: Date) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if let request = bashApprovalRequests[key],
           request.commandKey == commandKey, request.createdAt == createdAt {
            bashApprovalRequests[key] = nil
        }
    }

    /// `LLMStateDelegate`: drop every published approval card on full execution
    /// teardown (work-folder switch / close / reset). Without this the orchestrator's
    /// mirror outlives the run — and task-ID reuse across folders could render a stale
    /// card under a same-ID task in the new folder.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func clearAllBashApprovalRequests() {
        bashApprovalRequests.removeAll()
    }

    /// Button surface: resolve a HELD bash command DIRECTLY — bypassing the model.
    /// On `.allow` the gate runs the real command and the model gets its real
    /// output; on `.deny` the model gets a denial. `.alwaysAllow` (offered only in
    /// non-Manual modes) persists a standing allow rule first so future emissions of
    /// the same command auto-run.
    func resolveBashApproval(taskID: Int, stepID: String, commandKey: String, choice: BashApprovalChoice) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        // Persist only the command the button actually resolved: require the held
        // request's `commandKey` to match the tapped one, so a stale-card tap (the
        // request was already replaced by a later hold) can't persist a mismatched
        // command. The command text comes from that same matched request snapshot.
        if choice == .alwaysAllow, configuration.bashMode != .manual,
           let request = bashApprovalRequests[key], request.commandKey == commandKey,
           !request.command.isEmpty {
            var rules = configuration.bashAllowRules
            if !rules.contains(request.command) {
                rules.append(request.command)
                configuration.bashAllowRules = rules
            }
        }
        let decision: BashApprovalDecision = (choice == .deny) ? .deny : .allow
        llmExecutionService.resolveBashApproval(
            taskID: taskID, stepID: stepID, commandKey: commandKey, decision: decision)
    }

    /// Runs the command judge as an *advisor* over the step's pending bash approval
    /// and returns a verdict per command. Read-only: it neither consumes the pending
    /// approval nor records a decision — the human still answers yes/no/always.
    ///
    /// Replays the gate's exact judge inputs: each command's snapshotted working
    /// directory and the effective config (global + role override) captured when the
    /// gate paused, plus the LIVE restriction level + sandbox via `bashPolicy` (the
    /// human wants advice under their CURRENT settings). Returns `[]` when nothing is
    /// pending. `client` defaults to the execution service's production client; tests
    /// inject a stub.
    func requestBashJudgeAdvice(
        taskID: Int,
        stepID: String,
        client: (any LLMClient)? = nil
    ) async -> [BashAdvice] {
        guard let pending = llmExecutionService.pendingBashApproval(stepID: stepID, taskID: taskID) else {
            return []
        }
        // Two sequential LLM calls (judge + explain) on the judge config, which inherits the
        // global model unless an override is set. Registered once for the pair: the point is to
        // be nameable as a suspect, not to count round-trips.
        await llmExecutionService.noteInterleavingCall(
            label: "bash advice", config: pending.judgeConfig)
        return await BashAdviceService.advise(
            commands: pending.commands,
            workingDirectories: pending.workingDirectories,
            // The SNAPSHOTTED policy, not the live one: while a planning-phase hold is active
            // the real confinement is the write-disabled profile `BashTool` will apply, and
            // `sandboxConfinementDescription` renders whatever it gets straight into the
            // advisor's prompt. Reading `bashPolicy` here would show the human an "Ask AI"
            // verdict reasoned about a sandbox that is not in force.
            policy: pending.judgePolicy,
            config: pending.judgeConfig,
            client: client ?? llmExecutionService.clientFactory(),
            logger: nil)
    }
}
