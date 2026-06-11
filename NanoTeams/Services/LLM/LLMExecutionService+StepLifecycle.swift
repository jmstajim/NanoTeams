import Foundation

/// Extension containing the step execution lifecycle: setup, tool loop, error recovery,
/// and session management. Extracted from the main LLMExecutionService file for SRP.
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
        let tools = Self.filterForGitAvailability(
            Self.filterForDefaultStorage(
                toolSchemas(for: roleForMessage, team: resolvedTeam),
                isDefaultStorage: isDefaultStorage
            ),
            workFolderRoot: workFolderRoot
        )

        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let runID = task.runs[runIndex].id
        // For delegated child tasks, log paths nest under the parent's directory tree.
        let ancestors = delegate.snapshot?.tasksIndex.ancestorIDs(of: task.id) ?? []
        let networkLogger: NetworkLogger? = delegate.loggingEnabled
            ? NetworkLogger(logURL: paths.networkLogJSON(taskID: task.id, runID: runID, ancestors: ancestors))
            : nil
        let toolCallsLogURL: URL? = delegate.loggingEnabled
            ? paths.toolCallsJSONL(taskID: task.id, runID: runID, ancestors: ancestors)
            : nil
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: workFolderRoot, toolCallsLogURL: toolCallsLogURL,
            isDefaultStorage: isDefaultStorage,
            searchExploratoryByDefault: delegate.searchExploratoryByDefault,
            readFileMaxLines: delegate.readFileMaxLines,
            searchMaxResults: delegate.searchMaxResults,
            searchContextBefore: delegate.searchContextBefore,
            searchContextAfter: delegate.searchContextAfter
        )

        let fullConversation = buildChatMessages(
            for: task, stepID: stepID, tools: tools, supervisorMode: supervisorMode)

        // Check for supervisor continuation: saved session + answer means we can resume
        // the stateful chain instead of rebuilding from scratch.
        let savedSessionID = step.llmSessionID
        let hasSupervisorContinuation = savedSessionID != nil && step.effectiveSupervisorAnswer != nil
        let hasRevisionContinuation = savedSessionID != nil
            && step.revisionComment != nil
            && step.effectiveSupervisorAnswer == nil

        let taskHandle = Task { [weak self] in
            guard let self else { return }

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

            var cumulativeUsage = TokenUsage()

            do {
                // LLM run with tool loop, capped to prevent infinite cycling.
                var safetyIterations = 0
                var conversation: [ChatMessage]
                let tracker = ToolCallTracker()
                let memoryStore = MemoryTagStore(workFolderRoot: workFolderRoot)
                var llmErrorCount = 0
                var session: LLMSession?
                var needsSessionFallback = false

                if hasSupervisorContinuation, let sid = savedSessionID {
                    // Stateful continuation — send only the tool result with the Supervisor's answer.
                    // The `.supervisorAnswer` LLMMessage was appended to
                    // `step.llmConversation` atomically by
                    // `StepMessagingService.answerSupervisorQuestion`, so no
                    // duplicate append here. (Auto-answer path appends from
                    // `handleAutoSupervisorAnswer` within the same iteration
                    // and doesn't re-enter through here.)
                    session = LLMSession(responseID: sid)
                    let answer = step.effectiveSupervisorAnswer ?? ""
                    let answerJSON = self.buildCollaborationToolResult(
                        toolName: ToolNames.askSupervisor,
                        response: answer)
                    conversation = [ChatMessage(role: .tool, content: answerJSON)]
                    needsSessionFallback = true
                } else if hasRevisionContinuation, let sid = savedSessionID,
                          let feedback = step.revisionComment {
                    // Revision continuation — send only the Supervisor's feedback via stateful session.
                    // The LLM server has the full prior conversation in its response chain.
                    session = LLMSession(responseID: sid)
                    // `revisionComment` is raw by contract, but tasks persisted by older
                    // builds stored the already-prefixed message content in it —
                    // `rawFeedback` strips before prefixing so legacy data can't resurrect
                    // the doubled "Supervisor Feedback: Supervisor Feedback:" output.
                    let outbound = MessageSourceContext.supervisorFeedbackPrefix
                        + MessageSourceContext.rawFeedback(feedback)
                    conversation = [ChatMessage(role: .user, content: outbound)]
                    needsSessionFallback = true

                    // Persist to llmConversation for activity feed display.
                    // `.changeRequest` labels the bubble "(change request)" — without a
                    // sourceContext, `sourceContextDisplayLabel` falls back to the generic
                    // "(consultation)" for any message with a sourceRole.
                    await self.appendLLMMessage(
                        stepID: stepID, taskID: taskID, role: .user,
                        content: outbound,
                        sourceRole: .supervisor,
                        sourceContext: .changeRequest)
                } else {
                    conversation = fullConversation
                }

                // Clear saved session ID now that we've used it (prevents stale session on retry after failure)
                if hasSupervisorContinuation || hasRevisionContinuation,
                   let delegate = self.delegate,
                   self.isExecutionLive(stepID: stepID, taskID: taskID) {
                    await delegate.mutateTask(taskID: taskID) { task in
                        guard let runIndex = task.runs.indices.last,
                              let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
                        else { return }
                        task.runs[runIndex].steps[stepIndex].llmSessionID = nil
                    }
                }

                // No per-role iteration ceiling: the global maxToolIterations is 0
                // (unbounded) for every step, the Autovisor manager included.
                let effectiveLimit = LLMConstants.maxToolIterations == 0
                    ? Int.max : LLMConstants.maxToolIterations
                while safetyIterations < effectiveLimit {
                    if Task.isCancelled { throw CancellationError() }
                    if executionStates[stepKey]?.finishRequested == true {
                        executionStates[stepKey]?.finishRequested = false
                        await self.persistSessionID(stepID: stepID, taskID: taskID, sessionID: session?.responseID)
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        await self.finishStepGraceful(stepID: stepID, taskID: taskID)
                        return
                    }
                    // Autovisor idle park (`wait_for_events`): end the pass by parking
                    // at `.needsSupervisorInput` with the session preserved, so a human
                    // message continues the SAME conversation via stateful continuation.
                    // Deliberately bypasses the `.supervisorQuestion` machinery — the
                    // manager team is `.autonomous`, and the in-loop auto-answer would
                    // answer the park itself (same direct-park pattern as the
                    // `StepFlowControl` escalation caps). Chain stays valid: the
                    // continuation sends the Supervisor's answer as a single
                    // synthesized `ask_supervisor`-shaped tool result (this file's
                    // `hasSupervisorContinuation` branch), which resolves the pending
                    // tool_call on the server chain — the proven `ask_supervisor`
                    // shape. The `wait_for_events` envelope in `llmConversation` only
                    // ships on the stateless (`needsSessionFallback`) rebuild.
                    if executionStates[stepKey]?.parkForEventsRequested == true {
                        executionStates[stepKey]?.parkForEventsRequested = false
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        await self.parkStepForEvents(stepID: stepID, taskID: taskID, sessionID: session?.responseID)
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
                            iterationNumber: safetyIterations,
                            session: &session,
                            cumulativeUsage: &cumulativeUsage,
                            networkLogger: networkLogger
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // LLM server error — retry instead of killing the step.
                        // Clear session to avoid stale previous_response_id on retry.
                        // Any error (400, 429, network timeout, etc.) can leave the session invalid.
                        session = nil
                        if needsSessionFallback {
                            conversation = fullConversation
                            needsSessionFallback = false
                        }
                        llmErrorCount += 1
                        safetyIterations -= 1
                        let maxRetries = delegate.maxLLMRetries
                        if maxRetries > 0, llmErrorCount > maxRetries { throw error }
                        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        let limitLabel = maxRetries > 0 ? "/\(maxRetries)" : ""
                        let retryNote = "LLM server error (attempt \(llmErrorCount)\(limitLabel)): \(msg). Retrying in \(LLMConstants.llmRetryDelaySeconds)s…"
                        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .assistant, content: retryNote)
                        ConversationRepairService.repairConversationIfNeeded(&conversation)
                        ConversationRepairService.collapseRedundantAssistantTextRuns(&conversation)
                        try await Task.sleep(for: .seconds(LLMConstants.llmRetryDelaySeconds))
                        continue
                    }
                    llmErrorCount = 0
                    needsSessionFallback = false

                    switch stop {
                    case .completed:
                        await self.persistSessionID(stepID: stepID, taskID: taskID, sessionID: session?.responseID)
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        await self.completeStepSuccess(stepID: stepID, taskID: taskID)
                        return
                    case .needsSupervisorInput(let question):
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        let persisted = await self.setNeedsSupervisorInput(
                            stepID: stepID, taskID: taskID, question: question,
                            sessionID: session?.responseID)
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
                    case .needsAcceptance:
                        await self.persistSessionID(stepID: stepID, taskID: taskID, sessionID: session?.responseID)
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        await self.completeStepNeedsAcceptance(stepID: stepID, taskID: taskID)
                        return
                    case .toolFailure(let message):
                        await self.persistSessionID(stepID: stepID, taskID: taskID, sessionID: session?.responseID)
                        await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                        await self.completeStepFailure(stepID: stepID, taskID: taskID, errorMessage: message)
                        return
                    }
                }

                await self.persistSessionID(stepID: stepID, taskID: taskID, sessionID: session?.responseID)
                await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                await self.completeStepWithWarning(
                    stepID: stepID, taskID: taskID, warning: "Tool loop iteration limit reached.")
            } catch is CancellationError {
                await self.persistTokenUsage(stepID: stepID, taskID: taskID, usage: cumulativeUsage)
                delegate.clearStreamingPreview(stepID: stepID, taskID: taskID)
            } catch {
                let message =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self.completeStepFailure(stepID: stepID, taskID: taskID, errorMessage: message)
            }
        }

        executionStates[stepKey]?.runningTask = taskHandle
    }
}
