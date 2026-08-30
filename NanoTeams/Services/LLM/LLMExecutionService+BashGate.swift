import Foundation

// MARK: - Bash approval types

/// A human's verdict on a `bash` command awaiting approval — plus the case where
/// there is no verdict at all.
nonisolated enum BashApprovalDecision: Hashable {
    case allow
    case deny
    /// The hold ended WITHOUT a human answer: Pause, work-folder switch, or teardown
    /// cancelled the step task. Fail-safe is unchanged — the command still does not
    /// run — but the outcome is not a refusal, and the model must not be told it was
    /// one. A two-case enum could not say this, so every one of those paths resolved
    /// `.deny` and shipped the human-declined envelope for a decision nobody made
    /// (CLAUDE.md #152).
    case cancelled
}

/// The command a step is currently HOLDING for the human's in-loop approval.
/// Carried only for the duration of `awaitBashApproval` so the on-demand "Ask AI"
/// advisor (`requestBashJudgeAdvice`) can judge the exact held command under the
/// cwd the run would use.
nonisolated struct PendingBashApproval: Hashable {
    /// The raw commands, in gate order.
    let commands: [String]
    /// Per-command working directory (parallel to `commands`), captured from the
    /// tool-call args at gate time — the same value the Auto judge would see.
    let workingDirectories: [String?]
    /// The effective LLM config the gate would judge with (global + role override),
    /// snapshotted so the advisor hits the same judge endpoint/model as the real gate.
    let judgeConfig: LLMConfig
    /// The policy the gate would judge with, snapshotted for the same reason as `judgeConfig`:
    /// during a planning-phase hold the real confinement is the write-disabled one, and
    /// `sandboxConfinementDescription` renders whatever it is handed straight into the prompt.
    /// Reading the LIVE policy here would tell the advisor "writes are confined to the project
    /// work folder" about a command that cannot write at all.
    let judgePolicy: BashPolicy
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
    ///   on Deny a denial is synthesized; on `.cancelled` (Pause / teardown, no human
    ///   answer) a `CANCELLED` envelope is synthesized instead — same fail-safe, a
    ///   different fact. With no human (autonomous / Autovisor / headless) the `.ask`
    ///   command is denied — set Auto to run unattended.
    func gateBashCalls(
        resolvedToolCalls: [StepToolCall],
        allowedToolNames: Set<String>,
        isPlanningPhase: Bool = false,
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
        // What the REVIEWERS must reason about. During the planning phase `BashTool` rebuilds
        // its profile with every write scope off, so the live policy no longer describes the
        // confinement in force — and both reviewers render it verbatim:
        // `BashJudgeService.sandboxConfinementDescription` into the judge's system prompt, and
        // the "Ask AI" advisor behind a human approval card through the same function. Told the
        // wrong sandbox, the judge is permissive about writes that cannot happen and strict
        // about reads that are harmless.
        //
        // `BashPermissionService.evaluate` below keeps the UNNARROWED `policy` on purpose: it
        // never reads a sandbox field, so passing either one is equivalent — and passing the
        // real one keeps "the deny/ask/allow tiering is identical during planning" true by
        // construction rather than by inspection.
        let judgePolicy = isPlanningPhase ? policy.withWritesDisabled() : policy
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
                    // The judge runs against the SAME (server, model) as the step whose tool
                    // loop we are inside, so record its presence: if the server later reports it
                    // re-processed this step's prompt, this is the caller to name.
                    await noteInterleavingCall(label: "bash judge", config: config)
                    let verdict = await BashJudgeService.judge(
                        command: command, workingDirectory: workingDir,
                        policy: judgePolicy, config: config, client: client, logger: networkLogger)
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
                    // A Pause cancels the await → `.cancelled` (fail safe; re-prompts on resume).
                    // `offerAlways` is suppressed during the phase, and that is a safety rule,
                    // not tidiness. "Always allow" persists a permanent, global allow rule
                    // (`NTMSOrchestrator+BashAdvice`), so a human approving `rm -rf build` while
                    // writes are blocked would be minting a standing grant that takes effect
                    // AFTER the boundary, under the full write profile, with no further review —
                    // a decision made about a write-blocked run silently governing a
                    // write-enabled one, created inside the transcript the phase then destroys.
                    let decision = await awaitBashApproval(
                        taskID: taskID, stepID: stepID, command: command, commandKey: commandKey,
                        workingDirectory: BashArguments.workingDirectory(fromJSON: call.argumentsJSON),
                        offerAlways: policy.mode != .manual && !isPlanningPhase,
                        judgeConfig: config, judgePolicy: judgePolicy)
                    switch decision {
                    case .allow:
                        continue
                    case .deny:
                        // Third person, because the reader is the MODEL. "You" in every
                        // other envelope in this tree means the model itself (`your
                        // arguments`, `your plan`, `your role`) — spelling the human's
                        // act as "You declined" told the model it had refused the command
                        // it had just asked to run. Terse on purpose: the alternative
                        // ("choose a different approach") arrives one turn later from
                        // `ToolErrorNotePolicy.direction`'s `bash_denied` arm, and saying
                        // it here too is the duplication documented below as removed.
                        synthetic[idx] = makeBashDeniedResult(
                            call: call, reason: "The Supervisor denied this command.")
                    case .cancelled:
                        // Not a denial: the run was paused / torn down while the command
                        // was held. `BASH_DENIED` would earn the don't-retry direction for
                        // a block that does not exist — and this envelope is PERSISTED into
                        // the step's conversation, so it would still be there telling the
                        // model that on resume, when the very same command is re-held.
                        synthetic[idx] = makeCancelledResult(for: call)
                    }
                } else {
                    // Manual mode with no human (autonomous team / Autovisor / headless)
                    // → deny. The recourse named here must be one the MODEL can act on:
                    // it cannot open a Settings pane, so name what the supervisor would
                    // change, never where they would click. `ToolErrorNotePolicy.direction`'s
                    // `bash_denied` arm appends the don't-retry half, so this stays terse —
                    // and names only the recourse that arm CANNOT: a supervisor-side setting.
                    // Its generic "use a read-only or already-approved command" used to be
                    // spelled here too, so the model was handed the same alternative twice in
                    // consecutive turns. That arm keeps the generic half for the four sibling
                    // envelopes (deny rule, declined, judge, mode Off) that name no
                    // alternative at all; this is the one envelope that over-explained.
                    synthetic[idx] = makeBashDeniedResult(
                        call: call,
                        reason: "This command needs human approval (\(reason)), but no human is available to review it. "
                            + "Ask the supervisor to allow unattended command approval.")
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
