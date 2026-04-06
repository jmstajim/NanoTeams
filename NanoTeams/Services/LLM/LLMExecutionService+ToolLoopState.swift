import Foundation

/// Extension for conversation state management between tool loop iterations:
/// memories injection, loop detection warnings, and Supervisor auto-answer during tool loops.
extension LLMExecutionService {

    // MARK: - Memories Injection

    /// Injects Memories index into the conversation to keep the LLM oriented about
    /// tool result tags, file states, and scratchpad progress.
    func injectMemories(
        stepID: String,
        memoryStore: MemoryTagStore,
        session: LLMSession?,
        conversationMessages: inout [ChatMessage]
    ) async {
        let nextVersion = (executionStates[stepID]?.memoriesVersion ?? 0) + 1
        executionStates[stepID]?.memoriesVersion = nextVersion
        let version = nextVersion

        let memories = memoryStore.generateMemories(version: version)

        if session != nil {
            // Stateful: always append (can't modify messages on server)
            conversationMessages.append(ChatMessage(role: .user, content: memories))
            await appendLLMMessage(stepID: stepID, role: .user, content: memories)
        } else {
            // Stateless: rebuild in-place
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
