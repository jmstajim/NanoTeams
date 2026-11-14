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
    /// - `.ask` → AUTO judge (mode `.auto`) — a judge call the run's cancellation cut short
    ///   is a `CANCELLED` envelope, never a denial; or, with a human present, the command
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
        // The one predicate the schema resolver reads too (`ApprovalPresence`): under `.manual`
        // with no human the resolver has already withheld `bash`, so the no-human arm below is
        // reachable in production only under `.semiAutomatic` — for the commands that are not
        // read-only.
        let humanPresent = approvalHumanPresent(task: task, supervisorMode: supervisorMode)

        var synthetic: [Int: ToolExecutionResult] = [:]

        for (idx, call) in resolvedToolCalls.enumerated() {
            guard ToolRegistry.resolveToolName(call.name) == ToolNames.bash else { continue }
            guard let command = BashArguments.command(fromJSON: call.argumentsJSON) else {
                // Nothing would run: the runtime refuses the document, or the handler finds no
                // command in it — either way the model gets that refusal, and no card is held
                // for a call that cannot run. Resolved by the runtime's own reading and the
                // handler's own resolver, so no command can reach `BashTool` unjudged.
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
                    let ruling = await askApprovalJudge(label: "bash judge", config: config) {
                        await BashJudgeService.judge(
                            command: command, workingDirectory: workingDir,
                            policy: judgePolicy, config: config, client: client, logger: networkLogger)
                    }
                    switch ruling {
                    case .decided(let verdict) where verdict.allowed:
                        continue
                    case .decided(let verdict):
                        synthetic[idx] = makeBashDeniedResult(call: call, reason: verdict.reason)
                    case .cancelled:
                        // Paused while the judge was being asked, or before it could be:
                        // nobody ruled, so no `BASH_DENIED` — twin of the human hold's
                        // `.cancelled` below.
                        synthetic[idx] = makeCancelledResult(for: call)
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
                    // No human (autonomous team / Autovisor / headless) and a command the
                    // read-only bypass did not admit. Not a denial — nobody decided — so its
                    // own code: `ToolErrorNotePolicy`'s `approval_unavailable` arm adds the
                    // don't-retry half WITHOUT an escalation channel, because the channel a
                    // role holds (`ask_supervisor`) reaches the same answerer that cannot
                    // approve. Until 2026-09-07 this envelope asked the supervisor to "allow
                    // unattended command approval" — a setting that never existed — and the
                    // autonomous Supervisor duly "approved" (KNOWN_ISSUES A15). Third person:
                    // the reader is the model. Truthful for the one mode that reaches here
                    // (Semi-automatic — Manual is withheld from the schema): read-only
                    // commands DO run without approval.
                    synthetic[idx] = makeApprovalUnavailableResult(
                        call: call,
                        reason: "This command needs human approval (\(reason)), and this run has no human to give it. "
                            + "Read-only commands run without approval; nothing inside the run can approve the rest — "
                            + "take a different step.")
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

    /// The no-human refusal of BOTH gates — see `ToolErrorCode.approvalUnavailable`.
    func makeApprovalUnavailableResult(call: StepToolCall, reason: String) -> ToolExecutionResult {
        ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeErrorEnvelope(code: .approvalUnavailable, message: reason),
            isError: true)
    }

    // MARK: - Helpers

    /// Asks an approval judge on a gate's behalf — the one place both gates (`bash`,
    /// computer-use) do it.
    ///
    /// The judge runs against the SAME (server, model) as the step whose tool loop we are inside,
    /// so its presence is noted on the prompt-prefix ledger first: if the server later reports it
    /// re-processed this step's prompt, this is the caller to name.
    ///
    /// Unless the run has already stopped. A batch can hold several calls that need a verdict,
    /// and a Pause that cut the first judge short leaves the gate's loop running under the
    /// cancelled task: every later call used to note a judge — a suspect `serverDroppedCache`
    /// could name for a request that never went out — and then reach `JudgeCall.run`, which sends
    /// nothing for a stopped run. It is answered `.cancelled` here instead, like the judge the
    /// Pause interrupted, so the gate writes the same cancellation envelope for each of them.
    func askApprovalJudge(
        label: String, config: LLMConfig, _ judge: () async -> JudgeRuling
    ) async -> JudgeRuling {
        if Task.isCancelled { return .cancelled }
        await noteInterleavingCall(label: label, config: config)
        return await judge()
    }

    func isUnderAutovisor(task: NTMSTask) -> Bool {
        guard let settings = delegate?.snapshot?.workFolder.settings else { return false }
        return AutovisorPolicy.supervisesTask(
            taskID: task.id,
            parentTaskID: task.parentTaskID,
            autovisorEnabled: settings.autovisorEnabled,
            activation: settings.autovisorActivation,
            autovisorTaskID: delegate?.snapshot?.workFolder.state.autovisorTaskID,
            driver: settings.autovisorDriver,
            origin: task.origin
        )
    }

    /// Whether nobody but the Autovisor stands behind this task's approval cards — the
    /// `underAutovisor:` that `ApprovalPresence.humanPresent` reads for the schema resolver and both
    /// gates. Wider than `isUnderAutovisor` by one case: a DELEGATED child (`parentTaskID != nil`)
    /// whose root task an external agent created, while the external driver is on and the Autovisor
    /// is enabled. Such a child inherits its root's absence of a person — it has no `origin` of its
    /// own, and its cards would wait on a person the agent's task never had. Supervision itself does
    /// not widen: `isUnderAutovisor` (the manager's wake, the auto-answer suppression) stays
    /// top-level only, so the child's questions still go through its own team's
    /// `SupervisorMode` — an autonomous child team still answers itself. A child of a person's task
    /// is unchanged under either driver: its root has no agent origin, so a person approves.
    func underAutovisorForApproval(task: NTMSTask) -> Bool {
        if isUnderAutovisor(task: task) {
            return true
        }
        guard let settings = delegate?.snapshot?.workFolder.settings,
              settings.autovisorEnabled,
              settings.autovisorDriver == .externalAgent,
              task.parentTaskID != nil else {
            return false
        }
        return rootTaskOriginIsExternalAgent(for: task)
    }

    private func rootTaskOriginIsExternalAgent(for task: NTMSTask) -> Bool {
        guard let snapshot = delegate?.snapshot else { return false }
        let ancestorIDs = snapshot.tasksIndex.ancestorIDs(of: task.id)
        guard let rootID = ancestorIDs.first,
              let rootSummary = snapshot.tasksIndex.tasks.first(where: { $0.id == rootID }) else {
            return false
        }
        return rootSummary.origin?.isExternalAgent == true
    }
}
