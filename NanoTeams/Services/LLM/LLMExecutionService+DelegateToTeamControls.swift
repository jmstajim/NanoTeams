import Foundation

// Pause-and-Decide control plane for delegate_to_team: the cancel /
// resume / forward_to_team follow-up handlers, re-entry context
// resolution, forwarded-message injection, and the DEBUG test seams.
extension LLMExecutionService {

    // MARK: - Pause-and-Decide Follow-ups

    /// `cancel_delegation` handler. Validates the child id matches the
    /// parent step's active delegation (LLM hallucinations / typos can't
    /// stop unrelated tasks), stops the child engine, clears delegation
    /// fields, returns a confirmation envelope for the parent's tool loop.
    func handleCancelDelegation(
        stepID: String,
        taskID: Int,
        childTaskID: Int,
        reason: String?
    ) async -> String {
        guard let delegate else {
            return makeErrorEnvelope(code: .commandFailed, message: "delegate unavailable")
        }
        let parentTID = taskID
        guard isExecutionLive(stepID: stepID, taskID: parentTID) else {
            return makeErrorEnvelope(code: .commandFailed, message: "no task context for step \(stepID)")
        }
        guard let activeChildID = delegate.activeDelegationChildID(taskID: parentTID, roleID: stepID),
              activeChildID == childTaskID
        else {
            return makeErrorEnvelope(
                code: .invalidArgs,
                message: "child_task_id \(childTaskID) is not the in-flight delegation for this role. Re-check the paused envelope's child_task_id."
            )
        }
        delegate.stopEngineForTask(childTaskID)
        await clearDelegationFields(parentTID: parentTID, stepID: stepID, delegate: delegate)
        struct CancelData: Codable {
            var status: String
            var child_task_id: Int
            var reason: String?
        }
        return makeSuccessEnvelope(data: CancelData(
            status: "cancelled",
            child_task_id: childTaskID,
            reason: reason
        ))
    }

    /// `resume_delegation` handler. Un-pauses the child engine and re-enters
    /// the awaiter loop — blocks the parent role's tool loop until the
    /// child reaches a terminal state or the Supervisor interrupts again.
    /// Returns the same envelope shape as the original `delegate_to_team`
    /// terminal outcomes.
    func handleResumeDelegation(
        stepID: String,
        childTaskID: Int,
        initiatingRole: Role,
        task: NTMSTask,
        client: any LLMClient,
        config: LLMConfig
    ) async -> String {
        guard let delegate else {
            return makeErrorEnvelope(code: .commandFailed, message: "delegate unavailable")
        }
        let parentTID = task.id
        guard isExecutionLive(stepID: stepID, taskID: parentTID) else {
            return makeErrorEnvelope(code: .commandFailed, message: "no task context for step \(stepID)")
        }
        guard let activeChildID = delegate.activeDelegationChildID(taskID: parentTID, roleID: stepID),
              activeChildID == childTaskID
        else {
            return makeErrorEnvelope(
                code: .invalidArgs,
                message: "child_task_id \(childTaskID) is not the in-flight delegation for this role. Re-check the paused envelope's child_task_id."
            )
        }
        guard let context = makeReentryContext(
            childTID: childTaskID,
            parentTID: parentTID,
            initiatingRole: initiatingRole,
            task: task,
            delegate: delegate
        ) else {
            return makeErrorEnvelope(
                code: .commandFailed,
                message: "Could not resolve teams for resume — child task #\(childTaskID) may have been unloaded."
            )
        }
        await delegate.resumeRun(taskID: childTaskID)
        return await awaitDelegationCompletion(
            childTID: childTaskID,
            parentTID: parentTID,
            stepID: stepID,
            parentRoleDef: context.parentRoleDef,
            parentTeam: context.parentTeam,
            targetTeam: context.childTeam,
            isGeneratedFlow: false,  // re-entry doesn't repeat generation
            generationWarnings: [],
            client: client,
            config: config,
            delegate: delegate
        )
    }

    /// `forward_to_team` handler. Injects the Supervisor message into the
    /// child team's running flow as a queued chat message (existing
    /// `notifyDelegationInterrupt`-style mechanism, but the message is
    /// directed at one of the child's working roles), un-pauses, and
    /// re-enters the awaiter loop. The child team sees the message on its
    /// next iteration.
    func handleForwardToTeam(
        stepID: String,
        childTaskID: Int,
        message: String,
        initiatingRole: Role,
        task: NTMSTask,
        client: any LLMClient,
        config: LLMConfig
    ) async -> String {
        guard let delegate else {
            return makeErrorEnvelope(code: .commandFailed, message: "delegate unavailable")
        }
        let parentTID = task.id
        guard isExecutionLive(stepID: stepID, taskID: parentTID) else {
            return makeErrorEnvelope(code: .commandFailed, message: "no task context for step \(stepID)")
        }
        guard let activeChildID = delegate.activeDelegationChildID(taskID: parentTID, roleID: stepID),
              activeChildID == childTaskID
        else {
            return makeErrorEnvelope(
                code: .invalidArgs,
                message: "child_task_id \(childTaskID) is not the in-flight delegation for this role. Re-check the paused envelope's child_task_id."
            )
        }
        guard let context = makeReentryContext(
            childTID: childTaskID,
            parentTID: parentTID,
            initiatingRole: initiatingRole,
            task: task,
            delegate: delegate
        ) else {
            return makeErrorEnvelope(
                code: .commandFailed,
                message: "Could not resolve teams for forward — child task #\(childTaskID) may have been unloaded."
            )
        }
        // Inject the message into the child task's run as a Supervisor turn
        // on the child's most-recently-streamed step. The child team's tool
        // loop picks it up on its next iteration via the same
        // queued-supervisor-message path used for normal queued chat
        // delivery. Failure surfaces with mode-specific diagnostics so the
        // LLM knows whether the child has wedged before producing a run
        // (retry possible) vs has no eligible step (re-plan likely).
        let injectionOutcome = await injectForwardedMessageIntoChild(
            childTaskID: childTaskID,
            message: message,
            delegate: delegate
        )
        switch injectionOutcome {
        case .injected:
            break
        case .noRun:
            return makeErrorEnvelope(
                code: .commandFailed,
                message: "Could not inject forwarded message — child task #\(childTaskID) has no run yet (the engine may be wedged before its first iteration). Try cancel_delegation and re-delegate."
            )
        case .noEligibleStep:
            return makeErrorEnvelope(
                code: .commandFailed,
                message: "Could not inject forwarded message — child task #\(childTaskID) has no working/paused/pending step (it may have already finished, been cancelled, or you have the wrong child_task_id). Verify the id against the most recent delegate_to_team result envelope; if the child has terminated, abandon the follow-up and proceed."
            )
        }
        await delegate.resumeRun(taskID: childTaskID)
        return await awaitDelegationCompletion(
            childTID: childTaskID,
            parentTID: parentTID,
            stepID: stepID,
            parentRoleDef: context.parentRoleDef,
            parentTeam: context.parentTeam,
            targetTeam: context.childTeam,
            isGeneratedFlow: false,
            generationWarnings: [],
            client: client,
            config: config,
            delegate: delegate
        )
    }

    /// Resolves the contextual structs (parent role def, parent team, child
    /// team) needed to re-enter `awaitDelegationCompletion` for resume /
    /// forward. Returns `nil` if any required piece can't be loaded — this
    /// includes a parentage mismatch where the child's recorded
    /// `parentTaskID` doesn't match the supplied `parentTID` (defense
    /// against stale `loadedTask` snapshots after recursive task removal).
    private func makeReentryContext(
        childTID: Int,
        parentTID: Int,
        initiatingRole: Role,
        task: NTMSTask,
        delegate: any LLMStateDelegate
    ) -> (parentRoleDef: TeamRoleDefinition, parentTeam: Team, childTeam: Team)? {
        guard let parentTeam = resolveTeam(task: task) else { return nil }
        guard let parentRoleDef = parentTeam.findRole(byIdentifier: initiatingRole.baseID) else { return nil }
        guard let childTask = delegate.loadedTask(childTID),
              let childTeam = childTask.generatedTeam
              ?? delegate.snapshot?.workFolder.teams.first(where: { $0.id == childTask.preferredTeamID })
        else { return nil }
        // Validate parentage — if a child's recorded `parentTaskID` doesn't
        // match the suspended handler's `parentTID`, something has gone
        // structurally wrong (e.g. a re-load after corruption, or a parent
        // task removed mid-delegation). Refuse to re-enter — caller surfaces
        // a `commandFailed` envelope instead of operating on the wrong tree.
        guard childTask.parentTaskID == parentTID else { return nil }
        return (parentRoleDef, parentTeam, childTeam)
    }

    /// Outcome of a forward-message injection — distinguishes the two failure
    /// modes that previously collapsed into a single `false` return so the
    /// caller can give the LLM (and the user) actionable diagnostics.
    enum ForwardInjectionResult {
        case injected(stepID: String)
        case noRun                  // child has no runs yet — start race or partial create
        case noEligibleStep         // run exists but no .running / .paused / .pending step
    }

    /// Appends a `Supervisor:`-prefixed message to the child task's most
    /// recently active step's conversation, so the child role's next
    /// iteration sees it as new guidance. Mirrors the
    /// `consumeQueuedSupervisorMessage` mechanism but bypasses the queue
    /// (the message originates from the parent role, not the human).
    ///
    /// Step targeting (deterministic): per CLAUDE.md #45 parallel-ready
    /// siblings can be `.running`/`.paused` simultaneously. Plain
    /// `firstIndex(where: .running)` is array-order-dependent — the
    /// Supervisor's "use library X" guidance can land on Code Reviewer
    /// instead of Software Engineer. We pick the step whose `updatedAt` is
    /// most recent among the eligible-status candidates: that's the step
    /// last touched by streaming, which is the one the human's guidance
    /// most likely refers to.
    func injectForwardedMessageIntoChild(
        childTaskID: Int,
        message: String,
        delegate: any LLMStateDelegate
    ) async -> ForwardInjectionResult {
        var injectedStepID: String?
        var sawRun = false
        await delegate.mutateTask(taskID: childTaskID) { task in
            guard let runIdx = task.runs.indices.last else { return }
            sawRun = true
            let steps = task.runs[runIdx].steps
            // Priority 1: most-recently-updated `.running` or `.paused` step.
            // Priority 2: most-recently-updated `.pending` step (for forwards
            // that arrive between iterations).
            let livePriority: [StepStatus] = [.running, .paused]
            let live = steps.indices
                .filter { livePriority.contains(steps[$0].status) }
                .max(by: { steps[$0].updatedAt < steps[$1].updatedAt })
            let pending = steps.indices
                .filter { steps[$0].status == .pending }
                .max(by: { steps[$0].updatedAt < steps[$1].updatedAt })
            guard let stepIdx = live ?? pending else { return }
            let prefix = MessageSourceContext.supervisorMessagePrefix
            let body = "\(prefix)\(message)"
            task.runs[runIdx].steps[stepIdx].llmConversation.append(LLMMessage(
                role: .user,
                content: body,
                sourceRole: .supervisor,
                sourceContext: .supervisorMessage
            ))
            injectedStepID = task.runs[runIdx].steps[stepIdx].id
        }
        if let id = injectedStepID {
            return .injected(stepID: id)
        }
        return sawRun ? .noEligibleStep : .noRun
    }

    #if DEBUG
    /// Test seam: directly construct the paused envelope without driving
    /// `awaitDelegationCompletion`. Used by `DelegationPausedEnvelopeTests`
    /// to pin the JSON contract.
    func _testBuildPausedEnvelope(
        childTID: Int,
        targetTeamName: String,
        supervisorMessage: String
    ) -> String {
        buildPausedEnvelope(
            childTID: childTID,
            targetTeamName: targetTeamName,
            supervisorMessage: supervisorMessage
        )
    }

    /// Test seam: drives `injectForwardedMessageIntoChild` directly so a
    /// test can verify the exact `LLMMessage` shape (role, content, prefix,
    /// sourceContext) lands on the child step's `llmConversation`.
    @discardableResult
    func _testInjectForwardedMessageIntoChild(
        childTaskID: Int,
        message: String,
        delegate: any LLMStateDelegate
    ) async -> Bool {
        let outcome = await injectForwardedMessageIntoChild(
            childTaskID: childTaskID,
            message: message,
            delegate: delegate
        )
        if case .injected = outcome { return true }
        return false
    }

    /// Test seam exposing the full injection outcome (run-missing vs
    /// no-eligible-step vs success-with-stepID) so tests can pin both the
    /// happy path and each failure mode independently.
    func _testInjectForwardedMessageIntoChildOutcome(
        childTaskID: Int,
        message: String,
        delegate: any LLMStateDelegate
    ) async -> ForwardInjectionResult {
        await injectForwardedMessageIntoChild(
            childTaskID: childTaskID,
            message: message,
            delegate: delegate
        )
    }
    #endif
}
