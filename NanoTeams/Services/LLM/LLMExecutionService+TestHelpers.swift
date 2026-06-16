import Foundation

#if DEBUG
extension LLMExecutionService {
    func _testRegisterStepTask(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil {
            executionStates[key] = StepExecutionState()
        }
    }

    /// Injects a `runningTask` into the step's execution state so tests can verify
    /// `cancelStepExecution` actually awaits its completion before tearing down state.
    /// Cancels any pre-existing `runningTask` so it can't outlive the test and leak
    /// mutations into a subsequent test's `taskToMutate`.
    func _testInjectRunningTask(stepID: String, taskID: Int, runningTask: Task<Void, Never>) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if let existing = executionStates[key]?.runningTask {
            existing.cancel()
        }
        if executionStates[key] == nil {
            executionStates[key] = StepExecutionState()
        }
        executionStates[key]?.runningTask = runningTask
    }

    /// Returns whether an execution state entry exists for the step.
    func _testHasExecutionState(stepID: String, taskID: Int) -> Bool {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] != nil
    }

    func _testFinishStepWithWarning(stepID: String, taskID: Int, warning: String) async {
        await completeStepWithWarning(stepID: stepID, taskID: taskID, warning: warning)
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
    func _testSetPlanMessageIndex(stepID: String, taskID: Int, index: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil { executionStates[key] = StepExecutionState() }
        executionStates[key]?.planMessageIndex = index
    }

    /// Sets the memories message index for a step (for testing in-place update logic)
    func _testSetMemoriesMessageIndex(stepID: String, taskID: Int, index: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil { executionStates[key] = StepExecutionState() }
        executionStates[key]?.memoriesMessageIndex = index
    }

    /// Returns the plan message index for a step (for testing)
    func _testGetPlanMessageIndex(stepID: String, taskID: Int) -> Int? {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.planMessageIndex
    }

    /// Returns the memories message index for a step (for testing)
    func _testGetMemoriesMessageIndex(stepID: String, taskID: Int) -> Int? {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.memoriesMessageIndex
    }

    // MARK: - Test Helpers for System Prompt Restoration

    /// Returns the current count of stored original system prompts (for testing cleanup)
    var _testOriginalSystemPromptCount: Int {
        executionStates.values.filter { $0.originalSystemPrompt != nil }.count
    }

    /// Sets the original system prompt for a step (for testing restoration logic)
    func _testSetOriginalSystemPrompt(stepID: String, taskID: Int, prompt: String) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil { executionStates[key] = StepExecutionState() }
        executionStates[key]?.originalSystemPrompt = prompt
    }

    /// Returns the original system prompt for a step (for testing)
    func _testGetOriginalSystemPrompt(stepID: String, taskID: Int) -> String? {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.originalSystemPrompt
    }

    /// Simulates the conversation saving logic after planning phase restoration.
    /// Returns the messages that would be saved based on the current state.
    func _testSimulateImplementationPhaseSave(
        stepID: String,
        taskID: Int,
        conversationMessages: inout [ChatMessage],
        isFirstIteration: Bool
    ) async {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        // Restore original system prompt after planning phase
        if let savedPrompt = executionStates[key]?.originalSystemPrompt,
           let systemIdx = conversationMessages.firstIndex(where: { $0.role == .system }),
           conversationMessages[systemIdx].content?.contains("PLANNING PHASE") == true {
            conversationMessages[systemIdx] = ChatMessage(
                role: .system,
                content: savedPrompt
            )
            executionStates[key]?.originalSystemPrompt = nil

            // Save the RESTORED conversation with implementation prompt
            await saveLLMConversation(stepID: stepID, taskID: taskID, messages: conversationMessages)
        } else if isFirstIteration {
            // Save original conversation on first iteration (when no planning phase)
            await saveLLMConversation(stepID: stepID, taskID: taskID, messages: conversationMessages)
        }
    }
    // MARK: - Test Helpers for Change Request

    func _testExecuteAmendment(
        taskID: Int,
        targetRoleID: String,
        changes: String,
        reasoning: String,
        requestingRoleID: String,
        requesterStepID: String = "",
        meetingID: UUID?,
        team: Team?
    ) async -> String {
        await executeAmendment(
            taskID: taskID,
            targetRoleID: targetRoleID,
            changes: changes,
            reasoning: reasoning,
            requestingRoleID: requestingRoleID,
            requesterStepID: requesterStepID,
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
        taskID: Int,
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
            streamResult, stepID: stepID, taskID: taskID,
            conversationMessages: &conversationMessages)
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
        thinkingContent: String = "",
        harmonyBuffer: String = "",
        runtime: ToolRuntime? = nil
    ) async -> LLMStepStop {
        let streamResult = StreamingResult(
            assistantContent: assistantContent,
            thinkingContent: thinkingContent,
            resolvedToolCalls: [],
            sawHarmonyMarker: sawHarmonyMarker,
            harmonyBuffer: harmonyBuffer
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
            runtime: runtime,
            conversationMessages: &conversationMessages
        )
    }

    /// Drives `handleStreamLoopBreak` (top-level thinking-loop recovery) and returns
    /// both the resulting stop and the post-call `session` so tests can assert the
    /// stateless-replay session clear.
    func _testHandleStreamLoopBreak(
        stepID: String,
        signal: LoopSignal,
        task: NTMSTask,
        supervisorMode: SupervisorMode,
        sessionIn: LLMSession?
    ) async -> (stop: LLMStepStop, sessionOut: LLMSession?) {
        var session = sessionIn
        let stop = await handleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            roleForMessage: .softwareEngineer, supervisorMode: supervisorMode,
            session: &session)
        return (stop, session)
    }

    /// Reads the consecutive thinking-loop-break counter for a step.
    func _testThinkingLoopBreakCount(stepID: String, taskID: Int) -> Int {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveThinkingLoopBreaks ?? -1
    }

    /// Seeds the consecutive thinking-loop-break counter (for testing the
    /// clean-completion reset without driving the full streaming pipeline).
    func _testSetThinkingLoopBreakCount(stepID: String, taskID: Int, count: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil { executionStates[key] = StepExecutionState() }
        executionStates[key]?.consecutiveThinkingLoopBreaks = count
    }

    /// Delegates to the production `resetThinkingLoopBreakCount` — the same method
    /// `runOneLLMToolIteration` calls on a clean (no-loop) stream completion. A
    /// refactor that drops the reset from production would also drop it here, so the
    /// consecutive-break semantics stay pinned.
    func _testResetThinkingLoopBreakCount(stepID: String, taskID: Int) {
        resetThinkingLoopBreakCount(stepID: stepID, taskID: taskID)
    }

    /// Reads the `finishRequested` flag for a step (the graceful-finish handoff).
    func _testFinishRequested(stepID: String, taskID: Int) -> Bool {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.finishRequested ?? false
    }

    /// Reads the `parkForEventsRequested` flag for a step (the `wait_for_events`
    /// idle-park handoff).
    func _testParkForEventsRequested(stepID: String, taskID: Int) -> Bool {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.parkForEventsRequested ?? false
    }

    /// Reads the current drift counter for a step (for integration tests).
    func _testDriftCounter(stepID: String, taskID: Int) -> Int {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveDriftTurnCount ?? -1
    }

    /// Mirrors the production drift-counter reset that happens just before
    /// `executeToolCalls` runs (the model is acting, not just reasoning). Used by
    /// tests to simulate "tool call ran between two drift turns" without spinning
    /// up the full streaming + tool-execution pipeline.
    func _testResetDriftCounter(stepID: String, taskID: Int) {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveDriftTurnCount = 0
    }

    /// Reads the current advisory-no-tool counter for a step (for advisory auto-finish tests).
    func _testAdvisoryNoToolCounter(stepID: String, taskID: Int) -> Int {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveAdvisoryNoToolTurns ?? -1
    }

    /// Reads the current Harmony parse-failure counter for a step (for parse-failure cap tests).
    func _testHarmonyParseFailureCounter(stepID: String, taskID: Int) -> Int {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveHarmonyParseFailureCount ?? -1
    }

    /// Mirrors the production parse-failure counter reset that happens just before
    /// `executeToolCalls` runs (the model emitted a parseable tool call). Used by tests
    /// to simulate "successful tool call between two malformed-JSON turns" without
    /// spinning up the full streaming + tool-execution pipeline.
    /// Delegates to the production `resetCountersOnParseableToolCall` so a refactor
    /// that drops the parse-failure reset from the helper would also have to drop it
    /// from production — and the cap tests would fail.
    func _testResetHarmonyParseFailureCounter(stepID: String, taskID: Int) {
        resetCountersOnParseableToolCall(stepID: stepID, taskID: taskID)
    }

    /// Direct accessor to the production reset method, for tests pinning the
    /// "production reset point" contract (T1).
    func _testResetCountersOnParseableToolCall(stepID: String, taskID: Int) {
        resetCountersOnParseableToolCall(stepID: stepID, taskID: taskID)
    }

    /// Mirrors the production advisory-counter reset that happens just before
    /// `executeToolCalls` runs (counter resets when the model takes a tool action).
    func _testResetAdvisoryNoToolCounter(stepID: String, taskID: Int) {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveAdvisoryNoToolTurns = 0
    }

    func _testPropagateAmendmentDownstream(
        taskID: Int,
        sourceRoleID: String,
        changes: String,
        team: Team?
    ) async -> PropagationResult {
        await propagateAmendmentDownstream(
            taskID: taskID,
            sourceRoleID: sourceRoleID,
            changes: changes,
            team: team
        )
    }
}
#endif
