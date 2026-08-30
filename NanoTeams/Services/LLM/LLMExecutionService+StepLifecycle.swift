import Foundation

/// Extension containing the step execution lifecycle: setup, tool loop, and error
/// recovery. Extracted from the main LLMExecutionService file for SRP.
extension LLMExecutionService {

    // MARK: - Step Execution

    /// Starts LLM execution for a step if it's in the running state.
    func startStepExecution(
        stepID: String,
        taskID: Int,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int
    ) {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        // Cancel any still-registered execution for this key BEFORE replacing the
        // entry. The pre-fix order replaced first and then cancelled — which
        // targeted the FRESH state's nil runningTask, silently leaking the
        // previous execution on a same-key re-entry.
        executionStates[stepKey]?.runningTask?.cancel()
        executionStates[stepKey] = StepExecutionState()
        guard let delegate else { return }
        guard let workFolderRoot = delegate.workFolderURL else { return }
        guard task.runs[runIndex].steps[stepIndex].status == .running else { return }

        let isDefaultStorage = workFolderRoot == NTMSOrchestrator.defaultStorageURL
        let globalConfig = delegate.globalLLMConfig

        // Resolve per-role LLM override from team settings
        let resolvedTeam = resolveTeam(task: task)
        let step = task.runs[runIndex].steps[stepIndex]
        let roleForMessage = step.role
        let effectiveID = step.effectiveRoleID
        let roleDefinition = resolvedTeam?.findRole(byIdentifier: effectiveID)
        let roleOverride = roleDefinition?.llmOverride

        // Build effective config applying per-role override
        let effectiveConfig = Self.buildEffectiveConfig(
            globalConfig: globalConfig,
            roleOverride: roleOverride
        )

        let client = clientFactory()
        let supervisorMode = resolvedTeam?.settings.supervisorMode ?? .manual
        // Enter stage 1 with the DEFINITION resolved on line 36 (an exact
        // `$0.id ==` hit) instead of round-tripping `roleForMessage` through
        // `findRole` again — that reverse lookup returns the FIRST role sharing a
        // `systemRoleID`, so a role duplicated in the team editor would silently
        // run with its twin's toolset. Falls back to the `Role` path only when no
        // definition exists, which is exactly where the fallback IDs belong.
        let stage1 = roleDefinition.map { toolSchemas(forDefinition: $0, team: resolvedTeam) }
            ?? toolSchemas(for: roleForMessage, team: resolvedTeam)
        let tools = EffectiveToolset.applyStorageFilters(
            stage1,
            storage: isDefaultStorage ? .defaultStorage : .realFolder(root: workFolderRoot)
        )

        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let runID = task.runs[runIndex].id
        // For delegated child tasks, log paths nest under the parent's directory tree.
        let ancestors = delegate.snapshot?.tasksIndex.ancestorIDs(of: task.id) ?? []
        let networkLogger: NetworkLogger? = delegate.loggingEnabled
            ? NetworkLogger(logURL: paths.networkLogJSONL(taskID: task.id, runID: runID, ancestors: ancestors))
            : nil
        let toolCallsLogURL: URL? = delegate.loggingEnabled
            ? paths.toolCallsJSONL(taskID: task.id, runID: runID, ancestors: ancestors)
            : nil
        let bashPolicy = delegate.bashPolicy
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: workFolderRoot, toolCallsLogURL: toolCallsLogURL,
            networkLogger: networkLogger,
            isDefaultStorage: isDefaultStorage,
            searchExploratoryByDefault: delegate.searchExploratoryByDefault,
            readFileMaxLines: delegate.readFileMaxLines,
            searchMaxResults: delegate.searchMaxResults,
            searchContextBefore: delegate.searchContextBefore,
            searchContextAfter: delegate.searchContextAfter,
            bashSandboxEnabled: bashPolicy.sandboxEnabled,
            bashSandboxPermissions: bashPolicy.sandboxPermissions,
            bashAllowUnsandboxedFallback: bashPolicy.allowUnsandboxedFallback
        )

        let fullConversation = buildChatMessages(
            for: task, stepID: stepID, tools: tools, supervisorMode: supervisorMode)

        // Re-entry: continue the conversation this step actually sent instead of
        // re-synthesizing one. `resume` is nil only for a genuinely fresh step.
        // The two re-entry triggers are made mutually exclusive below: an
        // UNDELIVERED answer outranks a revision comment.
        let resumeConversation = ConversationReplay.resume(from: step)
        // `.legacyConversation` is a documented guaranteed prefix-cache miss ("not byte-identical
        // to what was sent"). Recording WHERE the conversation came from is what lets the
        // detector tell that apart from a genuinely fresh step, which is inherent and never
        // reported — the two are otherwise both "this step's first request".
        executionStates[stepKey]?.replaySource = resumeConversation?.source
        // `supervisorAnswerPendingDelivery`, NOT the answer itself: `supervisorAnswer` is
        // a display field that survives until the NEXT park, so keying on it made this a
        // standing condition — every later re-entry of the same step (an ordinary
        // pause/resume was enough) re-appended the identical `ask_supervisor` envelope and
        // the model executed the instruction again. Observed in the wild as a role
        // submitting its deliverable twice.
        let hasSupervisorAnswer =
            step.supervisorAnswerPendingDelivery && step.effectiveSupervisorAnswer != nil
        // Derived from the branch above rather than re-testing the answer, so a DELIVERED
        // answer no longer outranks a fresh revision: "Request Changes" on a step that had
        // ever been answered used to replay the stale answer instead of the feedback.
        let hasRevisionFeedback = step.revisionComment != nil && !hasSupervisorAnswer

        let taskHandle = Task { [weak self] in
            guard let self else { return }

            // A conversation built from scratch shares nothing with what this step sent in a
            // previous run, so the ledger's chain for this owner is not a baseline — it is a
            // different conversation that happens to carry the same owner key. Dropping it is
            // what makes `.firstRequestForOwner`, and its exemption, reachable at all.
            //
            // Runs BEFORE the config block below on purpose: `preflightCheck` can replace
            // `effectiveConfig` with `globalConfig`, and a role override can be edited between
            // runs, so a `(server, model)`-keyed drop would clear one slot and leave the stale
            // chain live under the other. Owner-scoped makes that trap unrepresentable.
            await self.forgetPrefixChainForFreshConversation(stepID: stepID, taskID: taskID)

            // Resolve effective config with provider-aware pre-flight check
            let config: LLMConfig
            if effectiveConfig.provider != globalConfig.provider
                || effectiveConfig.baseURLString != globalConfig.baseURLString
            {
                // Different provider or server — pre-flight check needed
                config = await Self.preflightCheck(
                    effectiveConfig: effectiveConfig,
                    globalConfig: globalConfig,
                    stepID: stepID,
                    taskID: taskID,
                    service: self
                )
            } else {
                config = effectiveConfig
            }

            // Pin the resolved (base, model) as in-use for this step so a
            // residency reconcile fired by another engine's transition can't
            // unload the model this step will reuse across tool-execution gaps.
            self.recordActiveModel(stepID: stepID, taskID: taskID, config: config)

            var cumulativeUsage = TokenUsage()
            // Declared outside the `do` so the cancellation arm can persist it: a pause
            // must leave behind the conversation the step was mid-way through, or resume
            // re-synthesizes and loses the working history.
            var conversation: [ChatMessage] = []

            do {
                // LLM run with tool loop, capped to prevent infinite cycling.
                var safetyIterations = 0
                let tracker = ToolCallTracker()
                let memoryStore = MemoryTagStore(workFolderRoot: workFolderRoot)
                var llmErrorCount = 0

                // Re-entry replays the transcript this step actually sent and appends
                // the new turn — an append-only, byte-identical prefix, so the server's
                // prompt cache re-evaluates only what's new.
                //
                // The fall-through is `ConversationReplay`, NOT a `PromptBuilder` rebuild.
                // `buildChatMessages` never reads `step.llmConversation` or
                // `step.toolCalls`; it reads `step.messages`, which in a Harmony tool loop
                // receives nothing for envelope-only assistant turns and never receives
                // tool results at all. Rebuilding there silently dropped the entire
                // working history — every read, every write, every denied command — so the
                // model re-did the work it had already done.
                if let resume = resumeConversation, hasSupervisorAnswer {
                    // Append-only continuation: everything already processed, plus the
                    // answer as the tool result resolving the pending `ask_supervisor`.
                    // The `.supervisorAnswer` LLMMessage was appended to
                    // `step.llmConversation` atomically by
                    // `StepMessagingService.answerSupervisorQuestion`, so no
                    // duplicate append here. (Auto-answer path appends from
                    // `handleAutoSupervisorAnswer` within the same iteration
                    // and doesn't re-enter through here.)
                    //
                    // ONE-SHOT. `persistWireTranscript` clears
                    // `supervisorAnswerPendingDelivery` in the same mutation that stores
                    // the transcript containing this envelope, so the next re-entry of
                    // this step takes the plain-replay branch below instead of appending
                    // the answer a second time.
                    let answer = step.effectiveSupervisorAnswer ?? ""
                    let answerJSON = self.buildCollaborationToolResult(
                        toolName: ToolNames.askSupervisor,
                        response: answer)
                    conversation = resume.messages
                        + [ChatMessage(role: .tool, content: answerJSON)]
                } else if let resume = resumeConversation, hasRevisionFeedback,
                          let feedback = step.revisionComment {
                    // `revisionComment` is raw by contract, but tasks persisted by older
                    // builds stored the already-prefixed message content in it —
                    // `rawFeedback` strips before prefixing so legacy data can't resurrect
                    // the doubled "Supervisor Feedback: Supervisor Feedback:" output.
                    let outbound = MessageSourceContext.supervisorFeedbackPrefix
                        + MessageSourceContext.rawFeedback(feedback)
                    conversation = resume.messages
                        + [ChatMessage(role: .user, content: outbound)]
                    // Persist to llmConversation for activity feed display.
                    // `.supervisorFeedback` renders it as the Supervisor's own utterance —
                    // crowned bubble, no secondary label, and the `Supervisor Feedback: `
                    // marker above stripped for display only (it stays on the wire, where
                    // it is what separates this turn from the tool result before it).
                    // A `sourceContext` of some kind is mandatory, not decorative: without
                    // one, `sourceContextDisplayLabel` falls back to the generic
                    // "(consultation)" for any message carrying a `sourceRole`.
                    await self.appendLLMMessage(
                        stepID: stepID, taskID: taskID, role: .user,
                        content: outbound,
                        sourceRole: .supervisor,
                        sourceContext: .supervisorFeedback)
                } else if let resume = resumeConversation {
                    // A step that suspended WITHOUT a Supervisor answer or a
                    // revision — an ordinary pause, or a stop/resume — still has
                    // a transcript, and it is still the byte-identical prefix the
                    // server holds. Before this branch it fell through to
                    // `fullConversation`, discarding every read, write and denial
                    // the step had accumulated: the same history loss the
                    // stateless work fixed for the other two re-entry doors, just
                    // through a third one. Nothing is appended — resuming a pause
                    // adds no new turn.
                    conversation = resume.messages
                } else {
                    conversation = fullConversation
                    if hasRevisionFeedback, let feedback = step.revisionComment {
                        // No transcript to replay, so the branch above could not fire and
                        // the correction had no feed bubble at all — the case is a step
                        // corrected before it ever completed a request (`correctRole`
                        // Branch B on a step paused that early), where the cancellation
                        // arm stored an empty transcript and `llmConversation` is still
                        // empty.
                        //
                        // DISPLAY ONLY — `conversation` is deliberately untouched. On this
                        // path the wire copy is already in `fullConversation`: the trigger
                        // site appended a `StepMessage`, and `PromptBuilder` relays every
                        // `.supervisor` step message as a `user` turn. Appending here too
                        // would send the correction twice.
                        await self.appendLLMMessage(
                            stepID: stepID, taskID: taskID, role: .user,
                            content: MessageSourceContext.supervisorFeedbackPrefix
                                + MessageSourceContext.rawFeedback(feedback),
                            sourceRole: .supervisor,
                            sourceContext: .supervisorFeedback)
                    }
                }

                // A replayed transcript still carries the previous entry's tags,
                // and this store's counters start at zero — seed them past every
                // tag already on the wire so a resumed step can never mint a
                // handle the conversation already uses for a different payload.
                // (A fresh conversation has no tags; the scan is a no-op there.)
                memoryStore.seedTagCounters(replaying: conversation)

                // No per-role iteration ceiling: the global maxToolIterations is 0
                // (unbounded) for every step, the Autovisor manager included.
                let effectiveLimit = LLMConstants.maxToolIterations == 0
                    ? Int.max : LLMConstants.maxToolIterations
                while safetyIterations < effectiveLimit {
                    if Task.isCancelled { throw CancellationError() }
                    if executionStates[stepKey]?.finishRequested == true {
                        executionStates[stepKey]?.finishRequested = false
                        await self.persistWireTranscript(stepID: stepID, taskID: taskID, messages: conversation)
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        await self.finishStepGraceful(stepID: stepID, taskID: taskID)
                        return
                    }
                    // Autovisor idle park (`wait_for_events`): end the pass by parking
                    // at `.needsSupervisorInput` with the wire transcript persisted, so a
                    // human message continues the SAME conversation on re-entry.
                    // Deliberately bypasses the `.supervisorQuestion` machinery — the
                    // manager team is `.autonomous`, and the in-loop auto-answer would
                    // answer the park itself (same direct-park pattern as the
                    // `StepFlowControl` escalation caps). The re-entry appends the
                    // Supervisor's answer as a single synthesized `ask_supervisor`-shaped
                    // tool result (the `hasSupervisorAnswer` branch above).
                    if executionStates[stepKey]?.parkForEventsRequested == true {
                        executionStates[stepKey]?.parkForEventsRequested = false
                        // nil = the standard idle park; the thinking-loop terminal
                        // overrides it so a loop break is distinguishable from idle.
                        let parkQuestion = executionStates[stepKey]?.parkQuestionOverride
                        executionStates[stepKey]?.parkQuestionOverride = nil
                        await self.persistWireTranscript(stepID: stepID, taskID: taskID, messages: conversation)
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        await self.parkStepForEvents(
                            stepID: stepID, taskID: taskID,
                            question: parkQuestion ?? AutovisorConstants.idleParkQuestion)
                        return
                    }
                    safetyIterations += 1

                    let stop: LLMStepStop
                    do {
                        stop = try await self.runOneLLMToolIteration(
                            stepID: stepID,
                            roleForMessage: roleForMessage,
                            client: client,
                            config: config,
                            tools: tools,
                            runtime: runtime,
                            task: task,
                            runIndex: runIndex,
                            stepIndex: stepIndex,
                            supervisorMode: supervisorMode,
                            conversationMessages: &conversation,
                            tracker: tracker,
                            memoryStore: memoryStore,
                            cumulativeUsage: &cumulativeUsage,
                            networkLogger: networkLogger
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Permanent error (wrong model / 404, auth 401/403, bad URL)
                        // → fail the step now instead of looping forever. Throwing
                        // propagates to the outer catch → `completeStepFailure`, which
                        // produces the error bubble. No "attempt N" retry note is
                        // appended for these. Transient errors fall through to retry.
                        if !LLMRetryPolicy.isRetryable(error) { throw error }
                        // LLM server error — retry instead of killing the step. The
                        // conversation is already the whole request, so the retry needs
                        // no rebuild; repair below only fixes a poisoned tail.
                        llmErrorCount += 1
                        safetyIterations -= 1
                        let maxRetries = delegate.maxLLMRetries
                        if maxRetries > 0, llmErrorCount > maxRetries { throw error }
                        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        let limitLabel = maxRetries > 0 ? "/\(maxRetries)" : ""
                        let retryDelay = retryDelaySeconds
                        let retryNote = "\(LLMConstants.llmServerErrorRetryNotePrefix) \(llmErrorCount)\(limitLabel)): \(msg). Retrying in \(retryDelay)s…"
                        // Collapse a burst of retries into ONE live-updating bubble
                        // instead of appending a fresh message per attempt.
                        await appendOrReplaceRetryNotice(stepID: stepID, taskID: taskID, content: retryNote)
                        // The repair truncates the poisoned tail, which is a DELIBERATE prefix
                        // reset — necessary, because the alternative is an unrecoverable HTTP 500
                        // loop. Arm the same one-shot the planning boundary uses so the next
                        // request is not reported as a cache defect. Only when it actually fired:
                        // the flag is consumed on the next report, so arming it on a no-op would
                        // swallow a genuine miss instead.
                        if ConversationRepairService.repairConversationIfNeeded(&conversation) {
                            executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?
                                .expectedPrefixResetPending = true
                        }
                        try await Task.sleep(for: .seconds(retryDelay))
                        continue
                    }
                    llmErrorCount = 0

                    switch stop {
                    case .completed:
                        await self.persistWireTranscript(stepID: stepID, taskID: taskID, messages: conversation)
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        await self.completeStepSuccess(stepID: stepID, taskID: taskID)
                        return
                    case .needsSupervisorInput(let question):
                        await self.persistWireTranscript(stepID: stepID, taskID: taskID, messages: conversation)
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        let persisted = await self.setNeedsSupervisorInput(
                            stepID: stepID, taskID: taskID, question: question)
                        // Defense-in-depth: the inner caller (handleNoToolCalls cap branches)
                        // already handles persistence failures; this outer call is the last
                        // line of defense for ask_supervisor and other direct paths. Without
                        // this, a silent no-op leaves the engine pinned to .needsSupervisorInput
                        // with no question and no recovery.
                        if !persisted {
                            await self.completeStepFailure(
                                stepID: stepID,
                                taskID: taskID,
                                errorMessage: "Failed to persist Supervisor question; step aborted.")
                        }
                        return
                    case .continueLoop:
                        continue
                    case .toolFailure(let message):
                        await self.persistWireTranscript(stepID: stepID, taskID: taskID, messages: conversation)
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        await self.completeStepFailure(stepID: stepID, taskID: taskID, errorMessage: message)
                        return
                    }
                }

                await self.persistWireTranscript(stepID: stepID, taskID: taskID, messages: conversation)
                await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                await self.completeStepWithWarning(
                    stepID: stepID, taskID: taskID, warning: "Tool loop iteration limit reached.")
            } catch is CancellationError {
                await self.persistWireTranscript(stepID: stepID, taskID: taskID, messages: conversation)
                await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                delegate.clearStreamingPreview(stepID: stepID, taskID: taskID)
            } catch {
                // Persist the transcript and the accumulated usage before failing — a
                // permanent error can arrive after earlier iterations already spent tokens
                // and did real work. Mirrors every other terminal arm (success / acceptance
                // / toolFailure / warning).
                //
                // The transcript matters even though the step is about to be `.failed`:
                // `resetStepForRevision` acts on `.failed` as well as `.done` and preserves
                // the conversation, so a change request against a step that died on a
                // permanent error re-runs it. Without this the re-run falls back to
                // `ConversationReplay`'s lossy display-record rebuild for no reason.
                await self.persistWireTranscript(stepID: stepID, taskID: taskID, messages: conversation)
                await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                let message =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self.completeStepFailure(stepID: stepID, taskID: taskID, errorMessage: message)
            }
        }

        executionStates[stepKey]?.runningTask = taskHandle
    }
}
