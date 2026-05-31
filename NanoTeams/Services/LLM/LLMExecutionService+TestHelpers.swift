import Foundation

#if DEBUG
extension LLMExecutionService {
    func _testRegisterStepTask(stepID: String, taskID: Int) {
        if executionStates[stepID] == nil {
            executionStates[stepID] = StepExecutionState(taskID: taskID)
        }
    }

    /// Injects a `runningTask` into the step's execution state so tests can verify
    /// `cancelStepExecution` actually awaits its completion before tearing down state.
    /// Cancels any pre-existing `runningTask` so it can't outlive the test and leak
    /// mutations into a subsequent test's `taskToMutate`.
    func _testInjectRunningTask(stepID: String, taskID: Int, runningTask: Task<Void, Never>) {
        if let existing = executionStates[stepID]?.runningTask {
            existing.cancel()
        }
        if executionStates[stepID] == nil {
            executionStates[stepID] = StepExecutionState(taskID: taskID)
        }
        executionStates[stepID]?.runningTask = runningTask
    }

    /// Returns whether an execution state entry exists for the step.
    func _testHasExecutionState(stepID: String) -> Bool {
        executionStates[stepID] != nil
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

    // MARK: - Test Helpers for Post-Stream Processing (slice anchor)

    /// Invokes `processStreamingResult` directly with a synthesized `StreamingResult`.
    /// Used to verify the stateful-continuation slice anchor advances even when a model
    /// turn yields neither assistant content nor resolved tool calls (the consumed-but-
    /// unparsed Harmony envelope case). Returns the completion stop (nil unless the LLM
    /// signalled completion); `conversationMessages` is mutated in place.
    func _testProcessStreamingResult(
        stepID: String,
        assistantContent: String,
        thinkingContent: String = "",
        resolvedToolCalls: [StepToolCall] = [],
        sawHarmonyMarker: Bool = false,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop? {
        let streamResult = StreamingResult(
            assistantContent: assistantContent,
            thinkingContent: thinkingContent,
            resolvedToolCalls: resolvedToolCalls,
            sawHarmonyMarker: sawHarmonyMarker,
            harmonyBuffer: ""
        )
        return await processStreamingResult(
            streamResult, stepID: stepID, conversationMessages: &conversationMessages)
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
        conversationMessages: inout [ChatMessage],
        thinkingContent: String = ""
    ) async -> LLMStepStop {
        let streamResult = StreamingResult(
            assistantContent: assistantContent,
            thinkingContent: thinkingContent,
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
            tracker: ToolCallTracker(),
            roleDefinition: roleDefinition,
            conversationMessages: &conversationMessages
        )
    }

    /// Reads the current drift counter for a step (for integration tests).
    func _testDriftCounter(stepID: String) -> Int {
        executionStates[stepID]?.consecutiveDriftTurnCount ?? -1
    }

    /// Mirrors the production drift-counter reset that happens just before
    /// `executeToolCalls` runs (the model is acting, not just reasoning). Used by
    /// tests to simulate "tool call ran between two drift turns" without spinning
    /// up the full streaming + tool-execution pipeline.
    func _testResetDriftCounter(stepID: String) {
        executionStates[stepID]?.consecutiveDriftTurnCount = 0
    }

    /// Reads the current advisory-no-tool counter for a step (for advisory auto-finish tests).
    func _testAdvisoryNoToolCounter(stepID: String) -> Int {
        executionStates[stepID]?.consecutiveAdvisoryNoToolTurns ?? -1
    }

    /// Reads the current Harmony parse-failure counter for a step (for parse-failure cap tests).
    func _testHarmonyParseFailureCounter(stepID: String) -> Int {
        executionStates[stepID]?.consecutiveHarmonyParseFailureCount ?? -1
    }

    /// Mirrors the production parse-failure counter reset that happens just before
    /// `executeToolCalls` runs (the model emitted a parseable tool call). Used by tests
    /// to simulate "successful tool call between two malformed-JSON turns" without
    /// spinning up the full streaming + tool-execution pipeline.
    /// Delegates to the production `resetCountersOnParseableToolCall` so a refactor
    /// that drops the parse-failure reset from the helper would also have to drop it
    /// from production — and the cap tests would fail.
    func _testResetHarmonyParseFailureCounter(stepID: String) {
        resetCountersOnParseableToolCall(stepID: stepID)
    }

    /// Direct accessor to the production reset method, for tests pinning the
    /// "production reset point" contract (T1).
    func _testResetCountersOnParseableToolCall(stepID: String) {
        resetCountersOnParseableToolCall(stepID: stepID)
    }

    /// Mirrors the production advisory-counter reset that happens just before
    /// `executeToolCalls` runs (counter resets when the model takes a tool action).
    func _testResetAdvisoryNoToolCounter(stepID: String) {
        executionStates[stepID]?.consecutiveAdvisoryNoToolTurns = 0
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
