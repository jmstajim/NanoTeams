import Foundation

// MARK: - Bash approval types

/// A human's verdict on a `bash` command awaiting approval.
nonisolated enum BashApprovalDecision: Hashable {
    case allow
    case deny
}

/// The command a step is currently HOLDING for the human's in-loop approval.
/// Carried only for the duration of `awaitBashApproval` so the on-demand "Ask AI"
/// advisor (`requestBashJudgeAdvice`) can judge the exact held command under the
/// cwd the run would use.
nonisolated struct PendingBashApproval: Hashable {
    /// `BashPermissionService.decisionKey(for:)` for each held command.
    let commandKeys: [String]
    /// The raw commands, in the same order.
    let commands: [String]
    /// Per-command working directory (parallel to `commands`), captured from the
    /// tool-call args at gate time — the same value the Auto judge would see.
    let workingDirectories: [String?]
    /// The held command text (advisory display).
    let question: String
    /// The effective LLM config the gate would judge with (global + role override),
    /// snapshotted so the advisor hits the same judge endpoint/model as the real gate.
    let judgeConfig: LLMConfig
    /// Monotonic per-instance discriminator. The approval UI keys its advisory state
    /// to this token, so a later (or byte-identical re-held) approval gets a fresh
    /// advisory pass instead of rendering the prior instance's verdicts.
    let createdAt: Date
}

// MARK: - The gate

extension LLMExecutionService {

    /// Pre-pass over a turn's resolved tool calls that decides, for each `bash`
    /// command, whether it may execute. Returns a sparse map `index → synthetic
    /// result` for the calls it intercepts; indices NOT present pass through to
    /// `executeToolCalls` unchanged (i.e. they run for real).
    ///
    /// Every synthetic result carries the call's `providerID` (via
    /// `ToolExecutionResult.synthetic(for:)`) so the wire `tool_call_id` resolves
    /// and the model never sees an orphaned tool call.
    ///
    /// Resolution per `bash` command (deny > ask > allow already applied inside
    /// `BashPermissionService`):
    /// - `.deny` rule → `BASH_DENIED`
    /// - `.allow` / read-only → pass through (runs)
    /// - `.ask` → AUTO judge (mode `.auto`); or, with a human present, the command
    ///   is HELD and the gate AWAITS the human's Allow/Deny in-loop — the model is
    ///   never asked to re-issue. On Allow the call passes through (runs for real);
    ///   on Deny a denial is synthesized. With no human (autonomous / Autovisor /
    ///   headless) the `.ask` command is denied — set Auto to run unattended.
    func gateBashCalls(
        resolvedToolCalls: [StepToolCall],
        allowedToolNames: Set<String>,
        stepID: String,
        taskID: Int,
        supervisorMode: SupervisorMode,
        task: NTMSTask,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger?
    ) async -> [Int: ToolExecutionResult] {
        // Cheap exit: nothing to gate unless the role can actually run bash and a
        // bash call is present.
        guard allowedToolNames.contains(ToolNames.bash),
              resolvedToolCalls.contains(where: { ToolRegistry.resolveToolName($0.name) == ToolNames.bash })
        else { return [:] }

        let policy = delegate?.bashPolicy ?? BashPolicy()
        let underAutovisor = isUnderAutovisor(task: task)
        let humanPresent = (supervisorMode == .manual) && !underAutovisor

        var synthetic: [Int: ToolExecutionResult] = [:]

        for (idx, call) in resolvedToolCalls.enumerated() {
            guard ToolRegistry.resolveToolName(call.name) == ToolNames.bash else { continue }
            guard let command = BashArguments.command(fromJSON: call.argumentsJSON) else {
                // Malformed args — let the handler reject with a clear INVALID_ARGS.
                // (Resolves the command identically to BashTool, so a command under
                // an alternative key can't slip past the gate and run ungated.)
                continue
            }
            let commandKey = BashPermissionService.decisionKey(for: command)

            switch BashPermissionService.evaluate(command: command, policy: policy) {
            case .allow:
                continue
            case .deny(let reason):
                synthetic[idx] = makeBashDeniedResult(call: call, reason: reason)
            case .ask(let reason):
                if policy.mode == .auto {
                    // AUTO judge.
                    let workingDir = BashArguments.workingDirectory(fromJSON: call.argumentsJSON)
                    let verdict = await BashJudgeService.judge(
                        command: command, workingDirectory: workingDir,
                        policy: policy, config: config, client: client, logger: networkLogger)
                    if verdict.allowed {
                        continue
                    } else {
                        synthetic[idx] = makeBashDeniedResult(call: call, reason: verdict.reason)
                    }
                } else if humanPresent {
                    // HOLD the command and await the human's Allow/Deny in-loop. This
                    // bypasses the model — nothing is sent back asking it to re-issue.
                    // Allow → leave the index unhandled so the call flows to
                    // executeToolCalls and runs for real; Deny → synthesize a denial.
                    // A Pause cancels the await → `.deny` (fail safe; re-prompts on resume).
                    let decision = await awaitBashApproval(
                        taskID: taskID, stepID: stepID, command: command, commandKey: commandKey,
                        workingDirectory: BashArguments.workingDirectory(fromJSON: call.argumentsJSON),
                        offerAlways: policy.mode != .manual, judgeConfig: config)
                    switch decision {
                    case .allow:
                        continue
                    case .deny:
                        synthetic[idx] = makeBashDeniedResult(
                            call: call, reason: "You declined to approve this command.")
                    }
                } else {
                    // Manual mode with no human (autonomous team / Autovisor / headless)
                    // → deny. Set the bash mode to Auto to let the judge decide unattended.
                    synthetic[idx] = makeBashDeniedResult(
                        call: call,
                        reason: "This command needs human approval (\(reason)), but no human is available. "
                            + "Set the bash mode to Auto in Settings → Bash to let the judge decide unattended.")
                }
            }
        }

        return synthetic
    }

    // MARK: - Approval lookup (read by the "Ask AI" advisor)

    func pendingBashApproval(stepID: String, taskID: Int) -> PendingBashApproval? {
        pendingBashApprovals[TaskStepKey(taskID: taskID, stepID: stepID)]
    }

    // MARK: - Synthetic result builders

    func makeBashDeniedResult(call: StepToolCall, reason: String) -> ToolExecutionResult {
        ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeErrorEnvelope(code: .bashDenied, message: reason),
            isError: true)
    }

    // MARK: - Helpers

    func isUnderAutovisor(task: NTMSTask) -> Bool {
        guard let settings = delegate?.snapshot?.workFolder.settings else { return false }
        return AutovisorPolicy.supervisesTask(
            taskID: task.id,
            parentTaskID: task.parentTaskID,
            autovisorEnabled: settings.autovisorEnabled,
            activation: settings.autovisorActivation,
            autovisorTaskID: delegate?.snapshot?.workFolder.state.autovisorTaskID)
    }
}
