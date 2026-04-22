import Foundation

/// Extension for conversation state management between tool loop iterations:
/// memories injection, loop detection warnings, and Supervisor auto-answer during tool loops.
extension LLMExecutionService {

    // MARK: - Memories Injection

    /// Injects the Memories index into the conversation. Skipped when the store
    /// is empty (no tag-producing tools were called yet) and, in stateful mode,
    /// when the content hasn't changed since the last injection — the prior
    /// block is already in the server's response chain, so re-sending it just
    /// bloats the conversation with N stale copies on long steps.
    func injectMemories(
        stepID: String,
        memoryStore: MemoryTagStore,
        session: LLMSession?,
        conversationMessages: inout [ChatMessage]
    ) async {
        let nextVersion = (executionStates[stepID]?.memoriesVersion ?? 0) + 1
        executionStates[stepID]?.memoriesVersion = nextVersion

        guard let memories = memoryStore.generateMemories(version: nextVersion) else { return }

        if session != nil {
            // Stateful: dedup — the prior block is already in the server chain.
            // Fingerprint skips the version header so bumping `v1`→`v2` alone
            // doesn't count as a change; only real entry changes trigger an append.
            let fingerprint = memories.split(separator: "\n").dropFirst().joined(separator: "\n")
            if executionStates[stepID]?.lastMemoriesFingerprint == fingerprint { return }
            executionStates[stepID]?.lastMemoriesFingerprint = fingerprint
            conversationMessages.append(ChatMessage(role: .user, content: memories))
            await appendLLMMessage(stepID: stepID, role: .user, content: memories)
        } else {
            // Stateless: rebuild in-place so there's only ever one block.
            if let existingIndex = executionStates[stepID]?.memoriesMessageIndex,
               existingIndex < conversationMessages.count {
                conversationMessages[existingIndex] = ChatMessage(role: .user, content: memories)
                await appendLLMMessage(stepID: stepID, role: .user, content: "[MEMORIES]\n\(memories)")
            } else {
                executionStates[stepID]?.memoriesMessageIndex = conversationMessages.count
                conversationMessages.append(ChatMessage(role: .user, content: memories))
                await appendLLMMessage(stepID: stepID, role: .user, content: memories)
            }
        }
    }

    // MARK: - Queued Supervisor Message Injection

    /// Consumes the next queued Supervisor message targeted at this role (or the
    /// untargeted Team queue) and appends it to `conversationMessages` as a user
    /// turn for this iteration's LLM request.
    ///
    /// Skipped on iteration 1 with a non-nil session: that combination only
    /// occurs when a step resumes from a saved session (supervisor/revision
    /// continuation) and the conversation has no assistant turn to anchor the
    /// stateful-chain slice against — appending a user message there would send
    /// through stateless fallback while `session` stays set, causing the server
    /// to duplicate the response chain.
    ///
    /// The delegate performs attachment finalization AND persists the matching
    /// `LLMMessage` to `step.llmConversation` atomically — we must NOT also call
    /// `appendLLMMessage` here (double-append).
    func injectQueuedSupervisorMessage(
        stepID: String,
        taskID: Int,
        roleID: String,
        iterationNumber: Int,
        session: LLMSession?,
        conversationMessages: inout [ChatMessage]
    ) async {
        guard iterationNumber > 1 || session == nil else { return }
        guard let delegate else { return }
        guard let content = await delegate.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: roleID, stepID: stepID
        ) else { return }
        conversationMessages.append(ChatMessage(role: .user, content: content))
    }

    // MARK: - Loop Detection

    /// Checks for looping patterns and injects a warning message if detected.
    func checkAndInjectLoopWarning(
        stepID: String,
        memory: ToolCallCache,
        conversationMessages: inout [ChatMessage]
    ) async {
        guard let loopDetection = ToolCallLoopDetector.detectLoopPattern(in: memory.recentCalls(limit: 6)) else { return }

        let warningMessage: String
        if case .repetitiveTool(let tool, let count, _) = loopDetection,
           tool == ToolNames.updateScratchpad {
            warningMessage = """
            ⚠️ PLANNING LOOP DETECTED: You've updated the scratchpad \(count) times without implementing.

            STOP planning. START implementing:
            1. Your plan is already recorded - do NOT call update_scratchpad again
            2. Execute step 1: Use edit_file or write_file to make the code change
            3. Then git_add and git_commit
            4. Submit your deliverables using create_artifact
            """
        } else {
            warningMessage = """
            ⚠️ LOOP DETECTED: \(loopDetection.message)

            Suggestions to break out:
            1. If code is already changed, commit with git_add and git_commit
            2. If build is failing, read the error and fix the root cause
            3. If unclear what to do, use 'ask_supervisor' for guidance
            4. Submit your deliverables using create_artifact
            """
        }
        conversationMessages.append(
            ChatMessage(role: .user, content: warningMessage)
        )
        await appendLLMMessage(stepID: stepID, role: .system, content: warningMessage)
    }

    // MARK: - Supervisor Auto-Answer in Tool Loop

    /// Handles Supervisor auto-answer when in auto-answer mode.
    /// Returns `.continueLoop` if auto-answered, `nil` if not applicable.
    func handleSupervisorAutoAnswer(
        outcome: ToolResultsOutcome,
        stepID: String,
        supervisorMode: SupervisorMode,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        client: any LLMClient,
        config: LLMConfig,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop? {
        guard let q = outcome.supervisorQuestion, supervisorMode == .autonomous else { return nil }

        let answer = await generateAutoSupervisorAnswer(
            question: q,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            client: client,
            config: config
        )
        await recordAutoSupervisorAnswer(stepID: stepID, question: q, answer: answer)

        // Replace the pending tool result with the actual answer
        let answerContent = buildCollaborationToolResult(toolName: ToolNames.askSupervisor, response: answer)
        if let toolCallID = outcome.supervisorToolCallProviderID,
           let idx = conversationMessages.lastIndex(where: { $0.toolCallID == toolCallID })
        {
            conversationMessages[idx] = ChatMessage(
                role: .tool, content: answerContent, toolCallID: toolCallID
            )
        } else {
            // Fallback: append as user message
            conversationMessages.append(
                ChatMessage(role: .user, content: "Supervisor answer: \(answer)")
            )
        }
        await appendLLMMessage(
            stepID: stepID, role: .user,
            content: "Supervisor answer: \(answer)",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer)
        return .continueLoop
    }
}
