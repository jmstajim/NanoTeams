import Foundation

/// `delegate_to_team` tool handler — synchronously runs a child task on another team
/// and returns its produced artifacts to the parent role's tool loop.
///
/// Mirrors the shape of `+TeamMeeting.swift`: an async function that runs a long
/// internal flow (await child engine state transitions, optionally answer the
/// child team's `ask_supervisor` calls via `DelegatedSupervisorAnswerService`)
/// and returns a JSON envelope `String` injected as the tool result.
extension LLMExecutionService {

    func handleDelegateToTeam(
        stepID: String,
        teamIDRaw: String,
        taskBrief: String,
        initiatingRole: Role,
        task: NTMSTask,
        runIndex _: Int,
        stepIndex _: Int,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger? = nil
    ) async -> String {
        guard let delegate else {
            return makeErrorEnvelope(code: .commandFailed, message: "delegate unavailable")
        }
        let parentTID = task.id
        guard isExecutionLive(stepID: stepID, taskID: parentTID) else {
            return makeErrorEnvelope(code: .commandFailed, message: "no task context for step \(stepID)")
        }

        // 1. Pre-flight: depth cap + eligibility (top-level role)
        if task.delegationDepth >= DelegationConstants.maxDelegationDepth {
            return makeErrorEnvelope(
                code: .delegationDenied,
                message: "Maximum delegation depth (\(DelegationConstants.maxDelegationDepth)) reached for this task chain."
            )
        }
        guard let parentTeam = resolveTeam(task: task) else {
            return makeErrorEnvelope(code: .commandFailed, message: "Could not resolve parent team.")
        }
        // Resolve the role definition once via `findRole(byIdentifier:)` —
        // `Role.baseID` for a built-in role is its `systemRoleID`, so the
        // lookup hits the systemRoleID branch. After this, every downstream
        // check operates on the single canonical `parentRoleDef.id`.
        guard let parentRoleDef = parentTeam.findRole(byIdentifier: initiatingRole.baseID) else {
            return makeErrorEnvelope(
                code: .commandFailed,
                message: "Could not resolve role \(initiatingRole.baseID) inside parent team."
            )
        }
        guard parentTeam.roleIsTopLevelDelegator(parentRoleDef) else {
            return makeErrorEnvelope(
                code: .delegationDenied,
                message: "Role \(parentRoleDef.name) is not peer-level with Supervisor (it has an upstream entry in the team hierarchy). Only peer roles may delegate."
            )
        }

        // 2. Resolve target team — two branches: "generated" sentinel OR existing UUID.
        let targetTeam: Team
        let preferredTeamIDForChild: NTMSID
        let isGeneratedFlow: Bool
        var generationWarnings: [String] = []

        if teamIDRaw == DelegationConstants.generatedTeamSentinel {
            // (a) Generated branch — synthesize a team from task_brief.
            guard parentRoleDef.allowDelegationToGeneratedTeams else {
                return makeErrorEnvelope(
                    code: .delegationDenied,
                    message: "This role is not allowed to generate new teams on the fly. Pick an existing team_id from the list embedded in delegate_to_team's description."
                )
            }
            let generationConfig = Self.buildEffectiveConfig(
                globalConfig: config,
                roleOverride: parentRoleDef.llmOverride
            )
            // Mirror `runTeamGeneration`'s pattern: persist a synthetic
            // `create_team` tool call on the delegating role's step BEFORE
            // streaming starts, carrying the `"status":"generating"` marker
            // that `StepToolCall.isGeneratingTeam` matches. The activity
            // feed renders this row with `NTMSLoader(.inline)` so the user
            // sees "team is being generated" instead of an opaque
            // delegate_to_team in-flight row. UI-only — never reaches the
            // LLM (conversation comes from `step.llmConversation`, not
            // `step.toolCalls`).
            let placeholderToolCallID = UUID()
            let placeholder = StepToolCall(
                id: placeholderToolCallID,
                name: ToolNames.createTeam,
                argumentsJSON: TeamGenerationEnvelopes.makeGenerationArgsJSON(taskDescription: taskBrief),
                resultJSON: TeamGenerationEnvelopes.makeGeneratingEnvelope(),
                isError: false
            )
            await appendToolCalls(stepID: stepID, taskID: parentTID, toolCalls: [placeholder])
            do {
                let buildResult = try await TeamGenerationService.generate(
                    taskDescription: taskBrief,
                    config: generationConfig,
                    client: client,
                    logger: networkLogger,
                    stepID: stepID
                )
                // Strip delegation-related tools and capabilities from teams
                // synthesized inside a `delegate_to_team` call. Without this,
                // the LLM that generated the team can include `delegate_to_team`
                // in role toolIDs, which
                // makes the child team itself attempt to spawn grandchildren —
                // depth-2+ delegation chains were observed in practice. By
                // stripping at the source, the generated team is structurally
                // terminal: it does the work it was given and returns artifacts.
                // Existing-team delegations (the `else` branch below) are
                // unaffected — those teams' toolsets are user-curated.
                // Re-check liveness AFTER the long generation await: if the parent
                // was torn down mid-generation (pause/cancel/remove), creating and
                // starting a child task now would spawn an orphan engine for a dead
                // parent, and the placeholder flip below would be an orphan write.
                guard isExecutionLive(stepID: stepID, taskID: parentTID) else {
                    return makeErrorEnvelope(
                        code: .commandFailed,
                        message: "Parent task was torn down during team generation; delegation aborted."
                    )
                }
                targetTeam = stripDelegationTools(from: buildResult.team)
                preferredTeamIDForChild = targetTeam.id
                isGeneratedFlow = true
                generationWarnings = buildResult.warnings

                // Flip the placeholder's spinner → ✓ with the success envelope.
                // The card stays in the activity feed as part of the audit
                // trail; subsequent failures of the broader delegation flow
                // (createDelegatedTask / adoptGeneratedTeam / marker persist)
                // are surfaced via this handler's return value — consumed by
                // the upstream tool loop as the `delegate_to_team` tool result
                // — not by mutating this placeholder.
                let successEnvelope = TeamGenerationEnvelopes.makeSuccessEnvelope(
                    team: targetTeam,
                    warnings: buildResult.warnings
                )
                await delegate.mutateTask(taskID: parentTID) { task in
                    guard let runIdx = task.runs.indices.last,
                          let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.id == stepID }),
                          let tcIdx = task.runs[runIdx].steps[stepIdx].toolCalls
                              .firstIndex(where: { $0.id == placeholderToolCallID })
                    else { return }
                    task.runs[runIdx].steps[stepIdx].toolCalls[tcIdx].resultJSON = successEnvelope
                    task.runs[runIdx].steps[stepIdx].toolCalls[tcIdx].isError = false
                }
            } catch {
                // Flip the placeholder's spinner → ✗ with the error envelope
                // BEFORE returning so the UI doesn't strand a forever-spinning
                // create_team row. The setLastErrorMessageForUI call below
                // independently surfaces the human banner.
                let errorEnvelope = TeamGenerationEnvelopes.makeErrorEnvelope(
                    message: error.localizedDescription
                )
                // Liveness barrier: a generation failing BECAUSE the parent was
                // cancelled mid-await must not flip a tool call on whatever now
                // answers to the captured parentTID.
                if isExecutionLive(stepID: stepID, taskID: parentTID) {
                    await delegate.mutateTask(taskID: parentTID) { task in
                        guard let runIdx = task.runs.indices.last,
                              let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.id == stepID }),
                              let tcIdx = task.runs[runIdx].steps[stepIdx].toolCalls
                                  .firstIndex(where: { $0.id == placeholderToolCallID })
                        else { return }
                        task.runs[runIdx].steps[stepIdx].toolCalls[tcIdx].resultJSON = errorEnvelope
                        task.runs[runIdx].steps[stepIdx].toolCalls[tcIdx].isError = true
                    }
                }
                // Surface to the user banner, not just the LLM envelope —
                // generation failures are real (LLM unreachable, model
                // unloaded, schema mismatch, parse error) and the human
                // Supervisor watching the run otherwise wouldn't see why
                // their delegation aborted (the envelope only reaches the
                // LLM's tool-call card). Mirrors the activeDelegationChildID
                // guard's banner at the top of the next step.
                delegate.setLastErrorMessageForUI("Team generation for delegated task failed: \(error.localizedDescription)")
                return makeErrorEnvelope(
                    code: .commandFailed,
                    message: "Failed to generate a delegated team: \(error.localizedDescription)"
                )
            }
        } else {
            // (b) Existing team branch — must be in this role's whitelist.
            let trimmedID = teamIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard parentRoleDef.allowedDelegationTeamIDs.contains(trimmedID) else {
                return makeErrorEnvelope(
                    code: .delegationDenied,
                    message: "Team \(trimmedID) is not in this role's delegation whitelist. See the list embedded in delegate_to_team's description for allowed options."
                )
            }
            guard let resolved = delegate.snapshot?.workFolder.team(withID: trimmedID) else {
                return makeErrorEnvelope(
                    code: .invalidArgs,
                    message: "Team \(trimmedID) does not exist in this project."
                )
            }
            targetTeam = resolved
            preferredTeamIDForChild = trimmedID
            isGeneratedFlow = false
        }

        // 3. Chat-mode rejection (applies to both branches).
        if targetTeam.isChatMode {
            return makeErrorEnvelope(
                code: .delegationDenied,
                message: "Chat-mode teams cannot be delegated to — they have no completion criterion."
            )
        }

        // 4. Create child task with parentage stamped on.
        let title = isGeneratedFlow
            ? "Delegated · \(targetTeam.name) (generated)"
            : "Delegated · \(targetTeam.name)"
        // `parentRoleID` is stored on the child task and used by the escalation
        // path (`DelegatedSupervisorAnswerService.askSupervisorRole`) to find the
        // owning step via `step.id == parentRoleID`. `StepExecution.id` is the
        // seeded `TeamRoleDefinition.id`, so this MUST be `parentRoleDef.id` —
        // not `initiatingRole.baseID` (which is the systemRoleID for built-ins
        // and the display name for customs; both miss the step.id key).
        guard let childTID = await delegate.createDelegatedTask(
            parentTaskID: parentTID,
            parentRoleID: parentRoleDef.id,
            title: title,
            supervisorTask: taskBrief,
            preferredTeamID: preferredTeamIDForChild,
            depth: task.delegationDepth + 1
        ) else {
            return makeErrorEnvelope(code: .commandFailed, message: "Could not create delegated child task.")
        }

        // 4a. Generated branch: install team in child's `generatedTeam` slot via
        // `adoptGeneratedTeam` so `TaskEngineStoreAdapter.resolvedTeam` finds it.
        // Verify the mutation actually landed: if `loadedTask(childTID)` is
        // missing or its `generatedTeam` is still nil after the mutateTask
        // call, the child engine would resolve its team via the parent-team
        // fallback chain in `TaskEngineStoreAdapter.resolvedTeam`, leading
        // to the recursion bug documented in `docs/delegation-feature.md` spec
        // #91. With the adapter's child-task fail-fast guard the engine will
        // refuse and transition to `.failed`, but we abort the delegation
        // here so the parent gets a clear error envelope rather than a generic
        // "child failed" message.
        if isGeneratedFlow {
            await delegate.mutateTask(taskID: childTID) { task in
                task.adoptGeneratedTeam(targetTeam)
            }
            let postMutationTeam = delegate.loadedTask(childTID)?.generatedTeam
            if postMutationTeam == nil {
                // Symmetric with the `activeDelegationChildID` guard below
                // (line ~206) — surface to the human banner so the user
                // sees why their delegation aborted, not just a collapsed
                // tool-call card with the LLM-facing envelope.
                delegate.setLastErrorMessageForUI("adoptGeneratedTeam did not persist on child task #\(childTID); aborting delegation to avoid parent-team fallback recursion.")
                return makeErrorEnvelope(
                    code: .commandFailed,
                    message: "adoptGeneratedTeam did not persist on child task \(childTID); aborting to avoid parent-team fallback recursion."
                )
            }
        }

        // 4b. Persist `activeDelegationChildID` on the parent step (in-flight
        // marker, cleared on terminal outcome) AND append `childTID` to
        // `delegationChildIDs` (append-only history). The history list is
        // what `GraphPanelView.resolveDelegationLayers` walks to render
        // completed delegation layers as muted "history" rows below the
        // active one — it persists across the lifecycle of the parent step
        // so users can see "what the team did" after delegation completes.
        // `pauseRun` keeps using `activeDelegationChildID` to identify
        // mid-delegation steps and avoid cancelling their runStep Task.
        //
        // Verify the mutation actually landed (CLAUDE.md §7: `mutateTask`
        // returning true means "persisted", NOT "the closure did something" —
        // a guard-let-else short-circuit still persists the unchanged task).
        // If `activeDelegationChildID` is missing post-mutation, the entire
        // pause/cancel control plane is broken: `pauseRun` won't recognize
        // the step as mid-delegation (cancels its runStep → orphans the
        // awaiter for 30min); `notifyDelegationInterrupt` returns false
        // (no marker → human's queued chat is silently dropped);
        // `cancel/resume/forward_to_team` all reject with INVALID_ARGS.
        // Loud failure here is much better than that silent cascade.
        await delegate.mutateTask(taskID: parentTID) { task in
            guard let runIdx = task.runs.indices.last,
                  let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.id == stepID })
            else { return }
            // Single mutator that enforces `activeChildID ∈ history` — replaces
            // the legacy two-write pattern (set marker + manually append to
            // history if not already there). Idempotent on duplicates.
            task.runs[runIdx].steps[stepIdx].setActiveDelegation(childID: childTID)
        }
        let postMarker = delegate.loadedTask(parentTID)?.runs.last?
            .steps.first(where: { $0.id == stepID })?.activeDelegationChildID
        if postMarker != childTID {
            delegate.setLastErrorMessageForUI("Could not persist delegation marker on parent step \(stepID); aborting delegation to avoid an orphaned child task and a hung awaiter.")
            delegate.stopEngineForTask(childTID)
            return makeErrorEnvelope(
                code: .commandFailed,
                message: "Could not persist delegation marker on parent step. The child task was created but the parent step does not record the child id — aborting to avoid a 30-minute hang."
            )
        }

        // 5. Start child engine — non-blocking; we observe via the awaiter.
        await delegate.startRunForTask(taskID: childTID)

        // 6. Block on the awaiter loop until child reaches a terminal state
        // (or the Supervisor interrupts via queued chat message — see
        // `awaitDelegationCompletion`). Same loop is reused by
        // `resume_delegation` and `forward_to_team` after the role un-pauses.
        return await awaitDelegationCompletion(
            childTID: childTID,
            parentTID: parentTID,
            stepID: stepID,
            parentRoleDef: parentRoleDef,
            parentTeam: parentTeam,
            targetTeam: targetTeam,
            isGeneratedFlow: isGeneratedFlow,
            generationWarnings: generationWarnings,
            client: client,
            config: config,
            delegate: delegate
        )
    }

    /// Awaiter loop shared by `delegate_to_team` (initial entry),
    /// `resume_delegation`, and `forward_to_team` (re-entry after a Supervisor
    /// interrupt). Blocks until the child reaches a terminal state, the
    /// Supervisor interrupts again, or the timeout fires. Returns the tool
    /// result envelope for the parent role's tool loop.
    ///
    /// On `.parentMessageQueued`, the loop **pauses** (does NOT stop) the
    /// child engine and returns a success envelope marked
    /// `status: "paused_by_supervisor"` — the parent role then chooses
    /// `cancel_delegation`, `resume_delegation`, or `forward_to_team` to
    /// drive the next step. The child task's `activeDelegationChildID` stays
    /// set on the parent step so those follow-up tools can find the paused
    /// child.
    func awaitDelegationCompletion(
        childTID: Int,
        parentTID: Int,
        stepID: String,
        parentRoleDef: TeamRoleDefinition,
        parentTeam: Team,
        targetTeam: Team,
        isGeneratedFlow: Bool,
        generationWarnings: [String],
        client: any LLMClient,
        config: LLMConfig,
        delegate: any LLMStateDelegate
    ) async -> String {
        let deadlineDate = Date().addingTimeInterval(DelegationConstants.delegationTimeoutSeconds)
        // Snapshot the global `lastErrorMessage` BEFORE the awaiter starts.
        // V1 limitation (per docs): error messages are not partitioned
        // per-task; `lastErrorMessageForTask(childTID)` returns the global
        // string regardless of which task owned the error. Without a
        // pre-await snapshot, an unrelated transient error from the parent
        // (or another background task) can be misattributed to the child's
        // failure. Treat only the *delta* (a string set after the awaiter
        // started) as evidence the child caused it.
        let baselineErrorAtEntry = delegate.lastErrorMessageForTask(childTID)
        while true {
            // Defensive timeout — if the child wedges, surface it instead of hanging the parent.
            if Date() >= deadlineDate {
                delegate.stopEngineForTask(childTID)
                await clearDelegationFields(parentTID: parentTID, stepID: stepID, delegate: delegate)
                // Surface to the human banner — without this, a wedged
                // child would only manifest as a collapsed tool-call card
                // 30 minutes after the user stopped paying attention.
                delegate.setLastErrorMessageForUI("Delegated task #\(childTID) timed out after \(Int(DelegationConstants.delegationTimeoutSeconds / 60)) minutes — the child team did not reach a terminal state.")
                return makeErrorEnvelope(
                    code: .delegationTimedOut,
                    message: "Delegated task #\(childTID) exceeded the \(Int(DelegationConstants.delegationTimeoutSeconds))-second timeout."
                )
            }

            let outcome = await delegate.awaitTaskTerminalState(taskID: childTID)
            switch outcome {
            case .needsSupervisorInput:
                let answered = await DelegatedSupervisorAnswerService.handleChildQuestion(
                    childTID: childTID,
                    parentTaskID: parentTID,
                    parentRoleID: parentRoleDef.id,
                    parentTeam: parentTeam,
                    targetTeamName: targetTeam.name,
                    client: client,
                    globalConfig: config,
                    delegate: delegate
                )
                if !answered {
                    await clearDelegationFields(parentTID: parentTID, stepID: stepID, delegate: delegate)
                    return makeErrorEnvelope(
                        code: .commandFailed,
                        message: "Failed to answer the delegated team's question — aborting delegation."
                    )
                }
                // Continue waiting; answerSupervisorQuestion auto-resumes the child engine.

            case .terminal(.needsAcceptance):
                // closeTask returns `false` when its internal `mutateTask` could not
                // persist (disk error, missing snapshot). Without handling that, the
                // next iteration's `awaitTaskTerminalState` fast-paths back to
                // `.needsAcceptance` and we loop tight until the 30-min timeout.
                // Force the engine down and abort with a clear envelope instead.
                let closed = await delegate.closeTask(taskID: childTID)
                if !closed {
                    delegate.stopEngineForTask(childTID)
                    await clearDelegationFields(parentTID: parentTID, stepID: stepID, delegate: delegate)
                    return makeErrorEnvelope(
                        code: .commandFailed,
                        message: "Could not close delegated task #\(childTID) after acceptance — the parent persistence layer rejected the close. Aborting delegation."
                    )
                }
                // Loop again — closeTask transitions engine to .done

            case .terminal(.failed):
                // Only attribute the global error message to the child if it
                // CHANGED since the awaiter started. If the global error
                // hasn't moved, it predates this delegation and naming it as
                // "child failed: …" would be misleading.
                let current = delegate.lastErrorMessageForTask(childTID)
                let attributable: String? = (current != baselineErrorAtEntry) ? current : nil
                let reason = attributable ?? "unknown failure (the engine reported a failure but no diagnostic was captured for this task)"
                await clearDelegationFields(parentTID: parentTID, stepID: stepID, delegate: delegate)
                return makeErrorEnvelope(
                    code: .commandFailed,
                    message: "Delegated task #\(childTID) failed: \(reason)"
                )

            case .terminal(.done):
                await clearDelegationFields(parentTID: parentTID, stepID: stepID, delegate: delegate)
                return await buildSuccessEnvelope(
                    childTID: childTID,
                    targetTeam: targetTeam,
                    isGeneratedFlow: isGeneratedFlow,
                    generationWarnings: generationWarnings,
                    delegate: delegate
                )

            case .parentMessageQueued(let text):
                // Pause-and-decide mode: pause the child engine (do NOT stop)
                // and hand control back to the parent role with a success
                // envelope marked `paused_by_supervisor`. The role then picks
                // one of: `cancel_delegation` (stop), `resume_delegation`
                // (continue waiting), `forward_to_team` (inject guidance and
                // continue). `activeDelegationChildID` stays set so those
                // follow-ups can find the paused child; only `delegationSession`
                // would normally clear here, but we leave it intact too —
                // resuming via the seeded chain is correct since no terminal
                // outcome happened.
                //
                // Race-safety re-check: if the child engine reached a
                // terminal state concurrently with the queued-message
                // delivery, pausing an already-`.done` task and returning
                // a paused envelope would mislead the parent role into
                // calling `resume_delegation` on a closed task — which then
                // recreates the engine via `engineForTask` and starts a
                // brand-new run. Re-read the child's task state after pause
                // and short-circuit to the corresponding terminal outcome
                // when that happened.
                await delegate.pauseRun(taskID: childTID)
                if let childTask = delegate.loadedTask(childTID), childTask.closedAt != nil {
                    await clearDelegationFields(parentTID: parentTID, stepID: stepID, delegate: delegate)
                    return await buildSuccessEnvelope(
                        childTID: childTID,
                        targetTeam: targetTeam,
                        isGeneratedFlow: isGeneratedFlow,
                        generationWarnings: generationWarnings,
                        delegate: delegate
                    )
                }
                if let childTask = delegate.loadedTask(childTID),
                   childTask.derivedStatusFromActiveRun() == .failed {
                    let current = delegate.lastErrorMessageForTask(childTID)
                    let attributable: String? = (current != baselineErrorAtEntry) ? current : nil
                    let reason = attributable ?? "unknown failure"
                    await clearDelegationFields(parentTID: parentTID, stepID: stepID, delegate: delegate)
                    return makeErrorEnvelope(
                        code: .commandFailed,
                        message: "Delegated task #\(childTID) failed concurrently with a Supervisor interrupt: \(reason)"
                    )
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return buildPausedEnvelope(
                    childTID: childTID,
                    targetTeamName: targetTeam.name,
                    supervisorMessage: trimmed
                )
            }
        }
    }
}
