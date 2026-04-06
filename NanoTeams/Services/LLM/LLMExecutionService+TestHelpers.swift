import Foundation

#if DEBUG
extension LLMExecutionService {
    func _testRegisterStepTask(stepID: String, taskID: Int) {
        if executionStates[stepID] == nil {
            executionStates[stepID] = StepExecutionState(taskID: taskID)
        }
    }

    func _testFinishStepWithWarning(stepID: String, warning: String) async {
        await completeStepWithWarning(stepID: stepID, warning: warning)
    }

    // MARK: - Test Helpers for Message Index Management

    /// Returns the current count of tracked plan message indices (for testing cleanup)
    var _testPlanMessageIndexCount: Int {
        executionStates.values.filter { $0.planMessageIndex != nil }.count
    }

    /// Returns the current count of tracked memories message indices (for testing cleanup)
    var _testMemoriesMessageIndexCount: Int {
        executionStates.values.filter { $0.memoriesMessageIndex != nil }.count
    }

    /// Sets the plan message index for a step (for testing in-place update logic)
    func _testSetPlanMessageIndex(stepID: String, index: Int) {
        if executionStates[stepID] == nil { executionStates[stepID] = StepExecutionState(taskID: Int()) }
        executionStates[stepID]?.planMessageIndex = index
    }

    /// Sets the memories message index for a step (for testing in-place update logic)
    func _testSetMemoriesMessageIndex(stepID: String, index: Int) {
        if executionStates[stepID] == nil { executionStates[stepID] = StepExecutionState(taskID: Int()) }
        executionStates[stepID]?.memoriesMessageIndex = index
    }

    /// Returns the plan message index for a step (for testing)
    func _testGetPlanMessageIndex(stepID: String) -> Int? {
        executionStates[stepID]?.planMessageIndex
    }

    /// Returns the memories message index for a step (for testing)
    func _testGetMemoriesMessageIndex(stepID: String) -> Int? {
        executionStates[stepID]?.memoriesMessageIndex
    }

    // MARK: - Test Helpers for System Prompt Restoration

    /// Returns the current count of stored original system prompts (for testing cleanup)
    var _testOriginalSystemPromptCount: Int {
        executionStates.values.filter { $0.originalSystemPrompt != nil }.count
    }

    /// Sets the original system prompt for a step (for testing restoration logic)
    func _testSetOriginalSystemPrompt(stepID: String, prompt: String) {
        if executionStates[stepID] == nil { executionStates[stepID] = StepExecutionState(taskID: Int()) }
        executionStates[stepID]?.originalSystemPrompt = prompt
    }

    /// Returns the original system prompt for a step (for testing)
    func _testGetOriginalSystemPrompt(stepID: String) -> String? {
        executionStates[stepID]?.originalSystemPrompt
    }

    /// Simulates the conversation saving logic after planning phase restoration.
    /// Returns the messages that would be saved based on the current state.
    func _testSimulateImplementationPhaseSave(
        stepID: String,
        conversationMessages: inout [ChatMessage],
        isFirstIteration: Bool
    ) async {
        // Restore original system prompt after planning phase
        if let savedPrompt = executionStates[stepID]?.originalSystemPrompt,
           let systemIdx = conversationMessages.firstIndex(where: { $0.role == .system }),
           conversationMessages[systemIdx].content?.contains("PLANNING PHASE") == true {
            conversationMessages[systemIdx] = ChatMessage(
                role: .system,
                content: savedPrompt
            )
            executionStates[stepID]?.originalSystemPrompt = nil

            // Save the RESTORED conversation with implementation prompt
            await saveLLMConversation(stepID: stepID, messages: conversationMessages)
        } else if isFirstIteration {
            // Save original conversation on first iteration (when no planning phase)
            await saveLLMConversation(stepID: stepID, messages: conversationMessages)
        }
    }
    // MARK: - Test Helpers for Change Request

    func _testExecuteAmendment(
        taskID: Int,
        targetRoleID: String,
        changes: String,
        reasoning: String,
        requestingRoleID: String,
        meetingID: UUID?,
        team: Team?
    ) async -> String {
        await executeAmendment(
            taskID: taskID,
            targetRoleID: targetRoleID,
            changes: changes,
            reasoning: reasoning,
            requestingRoleID: requestingRoleID,
            meetingID: meetingID,
            team: team
        )
    }

    // MARK: - Test Helpers for No-Tool-Call Flow Control

    /// Invokes `handleNoToolCalls` directly with a synthesized `StreamingResult`.
    /// Used to verify branch ordering (harmony-marker retry vs. tokens-only retry vs. nudges).
    func _testHandleNoToolCalls(
        stepID: String,
        assistantContent: String,
        sawHarmonyMarker: Bool,
        task: NTMSTask,
        roleDefinition: TeamRoleDefinition?,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop {
        let streamResult = StreamingResult(
            assistantContent: assistantContent,
            thinkingContent: "",
            resolvedToolCalls: [],
            sawHarmonyMarker: sawHarmonyMarker,
            harmonyBuffer: ""
        )
        return await handleNoToolCalls(
            stepID: stepID,
            result: streamResult,
            roleForMessage: .softwareEngineer,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            memory: ToolCallCache(),
            roleDefinition: roleDefinition,
            conversationMessages: &conversationMessages
        )
    }

    func _testPropagateAmendmentDownstream(
        taskID: Int,
        sourceRoleID: String,
        changes: String,
        team: Team?
    ) async -> String {
        await propagateAmendmentDownstream(
            taskID: taskID,
            sourceRoleID: sourceRoleID,
            changes: changes,
            team: team
        )
    }
}
#endif
