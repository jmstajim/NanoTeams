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
        executionStates[stepID] = StepExecutionState(taskID: taskID)
        guard let delegate else { return }
        guard let workFolderRoot = delegate.workFolderURL else { return }
        guard task.runs[runIndex].steps[stepIndex].status == .running else { return }

        executionStates[stepID]?.runningTask?.cancel()

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
        let tools = Self.filterForDefaultStorage(
            toolSchemas(for: roleForMessage, team: resolvedTeam),
            isDefaultStorage: isDefaultStorage
        )

        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let runID = task.runs[runIndex].id
        let networkLogger: NetworkLogger? = delegate.loggingEnabled
            ? NetworkLogger(logURL: paths.networkLogJSON(taskID: task.id, runID: runID))
            : nil
        let toolCallsLogURL: URL? = delegate.loggingEnabled
            ? paths.toolCallsJSONL(taskID: task.id, runID: runID)
            : nil
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: workFolderRoot, toolCallsLogURL: toolCallsLogURL,
            isDefaultStorage: isDefaultStorage)

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
                    service: self
                )
            } else {
                config = effectiveConfig
            }

            var cumulativeUsage = TokenUsage()

            do {
                let role = roleForMessage

                // LLM run with tool loop, capped to prevent infinite cycling.
                var safetyIterations = 0
                var conversation: [ChatMessage]
                let memory = ToolCallCache()
                let memoryStore = MemoryTagStore()
                var llmErrorCount = 0
                var session: LLMSession?
                var needsSessionFallback = false

                if hasSupervisorContinuation, let sid = savedSessionID {
                    // Stateful continuation — send only the tool result with the Supervisor's answer.
                    session = LLMSession(responseID: sid)
                    let answer = step.effectiveSupervisorAnswer ?? ""
                    let answerJSON = self.buildCollaborationToolResult(
                        toolName: ToolNames.askSupervisor,
                        response: answer)
                    conversation = [ChatMessage(role: .tool, content: answerJSON)]
                    needsSessionFallback = true

                    // Persist the supervisor answer to llmConversation for UI display
                    await self.appendLLMMessage(
                        stepID: stepID, role: .user,
                        content: "Supervisor answer: \(answer)",
                        sourceRole: .supervisor,
                        sourceContext: .supervisorAnswer)
                } else if hasRevisionContinuation, let sid = savedSessionID,
                          let feedback = step.revisionComment {
                    // Revision continuation — send only the Supervisor's feedback via stateful session.
                    // The LLM server has the full prior conversation in its response chain.
                    session = LLMSession(responseID: sid)
                    conversation = [ChatMessage(role: .user, content: "Supervisor Feedback: \(feedback)")]
                    needsSessionFallback = true

                    // Persist to llmConversation for activity feed display
                    await self.appendLLMMessage(
                        stepID: stepID, role: .user,
                        content: "Supervisor Feedback: \(feedback)",
                        sourceRole: .supervisor)
                } else {
                    conversation = fullConversation
                }

                // Clear saved session ID now that we've used it (prevents stale session on retry after failure)
                if hasSupervisorContinuation || hasRevisionContinuation,
                   let delegate = self.delegate, let tid = self.taskIDForStep(stepID) {
                    await delegate.mutateTask(taskID: tid) { task in
                        guard let runIndex = task.runs.indices.last,
                              let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
                        else { return }
                        task.runs[runIndex].steps[stepIndex].llmSessionID = nil
                    }
                }

                let iterationLimit = LLMConstants.maxToolIterations
                let effectiveLimit = iterationLimit == 0 ? Int.max : iterationLimit
                while safetyIterations < effectiveLimit {
                    if Task.isCancelled { throw CancellationError() }
                    if executionStates[stepID]?.finishRequested == true {
                        executionStates[stepID]?.finishRequested = false
                        await self.persistSessionID(stepID: stepID, sessionID: session?.responseID)
                        await self.persistTokenUsage(stepID: stepID, usage: cumulativeUsage)
                        await self.completeStepNeedsAcceptance(stepID: stepID)
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
                            memory: memory,
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
                        print("[DEBUG] \(retryNote)")
                        await appendLLMMessage(stepID: stepID, role: .assistant, content: retryNote)
                        ConversationRepairService.repairConversationIfNeeded(&conversation)
                        try await Task.sleep(nanoseconds: LLMConstants.llmRetryDelaySeconds * 1_000_000_000)
                        continue
                    }
                    llmErrorCount = 0
                    needsSessionFallback = false

                    print("[DEBUG] LLM iteration \(safetyIterations) for \(roleForMessage.baseID) returned: \(stop)")

                    switch stop {
                    case .completed:
                        await self.persistSessionID(stepID: stepID, sessionID: session?.responseID)
                        await self.persistTokenUsage(stepID: stepID, usage: cumulativeUsage)
                        await self.completeStepSuccess(stepID: stepID)
                        return
                    case .needsSupervisorInput(let question):
                        await self.persistTokenUsage(stepID: stepID, usage: cumulativeUsage)
                        await self.setNeedsSupervisorInput(
                            stepID: stepID, question: question,
                            sessionID: session?.responseID)
                        return
                    case .continueLoop:
                        continue
                    case .needsAcceptance:
                        await self.persistSessionID(stepID: stepID, sessionID: session?.responseID)
                        await self.persistTokenUsage(stepID: stepID, usage: cumulativeUsage)
                        await self.completeStepNeedsAcceptance(stepID: stepID)
                        return
                    case .toolFailure(let message):
                        await self.persistSessionID(stepID: stepID, sessionID: session?.responseID)
                        await self.persistTokenUsage(stepID: stepID, usage: cumulativeUsage)
                        await self.completeStepFailure(stepID: stepID, errorMessage: message)
                        return
                    }
                }

                await self.persistSessionID(stepID: stepID, sessionID: session?.responseID)
                await self.persistTokenUsage(stepID: stepID, usage: cumulativeUsage)
                await self.completeStepWithWarning(
                    stepID: stepID, warning: "Tool loop iteration limit reached.")
            } catch is CancellationError {
                await self.persistTokenUsage(stepID: stepID, usage: cumulativeUsage)
                delegate.clearStreamingPreview(stepID: stepID)
            } catch {
                let message =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self.completeStepFailure(stepID: stepID, errorMessage: message)
            }
        }

        executionStates[stepID]?.runningTask = taskHandle
    }
}
