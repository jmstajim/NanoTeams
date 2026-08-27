import CoreGraphics
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

    /// Injects a `currentToolBatchTask` so tests can verify that a teardown path cancels the
    /// DETACHED tool batch, not just the step's own running task. The batch is the half that
    /// outlives its owner: `executeToolCalls` spawns it with `Task.detached`, and clearing the
    /// state entry drops the only handle to it.
    func _testInjectToolBatchTask(
        stepID: String, taskID: Int, batchTask: Task<[ToolExecutionResult], Never>
    ) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil {
            executionStates[key] = StepExecutionState()
        }
        executionStates[key]?.currentToolBatchTask = batchTask
    }

    /// Returns whether an execution state entry exists for the step.
    func _testHasExecutionState(stepID: String, taskID: Int) -> Bool {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] != nil
    }

    /// Seeds the per-step flags the prompt-prefix cache detector reads for its exemptions.
    func _testSetPrefixCacheState(
        stepID: String,
        taskID: Int,
        replaySource: ConversationReplay.Source? = nil,
        lastRequestCarriedImages: Bool = false,
        expectedPrefixResetPending: Bool = false,
        didWarnContextOverflow: Bool = false
    ) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil { executionStates[key] = StepExecutionState() }
        executionStates[key]?.replaySource = replaySource
        executionStates[key]?.lastRequestCarriedImages = lastRequestCarriedImages
        executionStates[key]?.expectedPrefixResetPending = expectedPrefixResetPending
        executionStates[key]?.didWarnContextOverflow = didWarnContextOverflow
    }

    func _testExpectedPrefixResetPending(stepID: String, taskID: Int) -> Bool? {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.expectedPrefixResetPending
    }

    func _testDidWarnContextOverflow(stepID: String, taskID: Int) -> Bool? {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.didWarnContextOverflow
    }

    /// Seeds the service-wide window memo so a test can distinguish "the probe answered" from
    /// "the probe was spent and returned nothing" — the two states the post-send truncation
    /// observation branches on. Note the double optional: a stored `nil` means "asked, no answer".
    func _testSeedProbedContextLength(baseURL: String, model: String, contextLength: Int?) {
        probedContextLengths["\(baseURL.normalizedBaseURL)|\(model)"] = contextLength
    }

    func _testProbedContextLength(baseURL: String, model: String) -> Int? {
        probedContextLengths["\(baseURL.normalizedBaseURL)|\(model)"] ?? nil
    }

    /// Drives the planning-phase boundary's per-step reset without building a wire. The boundary
    /// itself needs a role with the phase enabled, a brief already on the wire and a recorded
    /// scratchpad; what the fields care about is only that the array they described was replaced.
    func _testResetConversationScopedState(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil { executionStates[key] = StepExecutionState() }
        executionStates[key]?.resetConversationScopedState()
    }

    /// The truncation detector's delta baseline. Written by `confirmContextTruncation` on every
    /// request that carries a count, so a test seeds it by driving that rather than by assignment.
    func _testLastServerPromptTokens(stepID: String, taskID: Int) -> Int? {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.lastServerPromptTokens
    }

    /// Marks a step as actively using (base, model) so residency-reconcile
    /// tests can exercise the model-specific in-use guard without driving a
    /// full run. Mirrors what `recordActiveModel` does after config resolution.
    func _testSetActiveModel(stepID: String, taskID: Int, base: String, model: String) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil {
            executionStates[key] = StepExecutionState()
        }
        executionStates[key]?.activeModelKey = ChatModelEnsurer.residencyKey(
            model: model, base: base)
    }

    func _testFinishStepWithWarning(stepID: String, taskID: Int, warning: String) async {
        await completeStepWithWarning(stepID: stepID, taskID: taskID, warning: warning)
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
        // Resolve the def the way production does (validation goes through
        // `findRole(byIdentifier:)`), so the seam keeps its role-id ergonomics while
        // exercising the real lookup.
        guard let targetRole = team?.findRole(byIdentifier: targetRoleID) else {
            return "Amendment failed: target step not found."
        }
        return await executeAmendment(
            taskID: taskID,
            targetRole: targetRole,
            changes: changes,
            reasoning: reasoning,
            requestingRoleID: requestingRoleID,
            requesterStepID: requesterStepID,
            meetingID: meetingID,
            team: team
        ).text
    }

    // MARK: - Test Helpers for Post-Stream Processing (slice anchor)


    // MARK: - Test Helpers for No-Tool-Call Flow Control

    /// Invokes `handleNoToolCalls` directly with a synthesized `StreamingResult`.
    /// Used to verify branch ordering (harmony-marker retry vs. tokens-only retry vs. nudges).
    ///
    /// `allowedToolNames` defaults to EMPTY, i.e. "this test does not exercise tool
    /// naming" — every nudge then takes its names-nothing arm. A test asserting that a
    /// message mentions a specific tool must pass that tool in, which is the point: the
    /// schema is now an input to the text, so it has to be visible at the call site.
    func _testHandleNoToolCalls(
        stepID: String,
        assistantContent: String,
        sawHarmonyMarker: Bool,
        task: NTMSTask,
        roleDefinition: TeamRoleDefinition?,
        conversationMessages: inout [ChatMessage],
        thinkingContent: String = "",
        harmonyBuffer: String = "",
        allowedToolNames: Set<String> = [],
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
            allowedToolNames: allowedToolNames,
            runtime: runtime,
            conversationMessages: &conversationMessages
        )
    }

    /// Drives `handleStreamLoopBreak` (top-level thinking-loop recovery) and returns
    /// the resulting stop.
    ///
    /// `conversationMessages` is `inout` deliberately and has no convenience overload:
    /// whether the retry arm PERTURBS the conversation is the whole point of the arm,
    /// so a caller must not be able to drive this without seeing it.
    func _testHandleStreamLoopBreak(
        stepID: String,
        signal: LoopSignal,
        task: NTMSTask,
        supervisorMode: SupervisorMode,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop {
        await handleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            roleForMessage: .softwareEngineer, supervisorMode: supervisorMode,
            conversationMessages: &conversationMessages)
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

    /// Reads the park question the thinking-loop terminal staged for the lifecycle
    /// guard. `nil` = the standard idle park.
    func _testParkQuestionOverride(stepID: String, taskID: Int) -> String? {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.parkQuestionOverride
    }

    /// Arms the idle-park handoff the way `wait_for_events`'s finalizer does, so a test
    /// can reach the loop-top park arm without driving a whole tool round-trip.
    /// `questionOverride` is the thinking-loop terminal's diagnostic; leaving it nil is
    /// the standard `wait_for_events` park.
    func _testArmParkForEvents(stepID: String, taskID: Int, questionOverride: String? = nil) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil { executionStates[key] = StepExecutionState() }
        executionStates[key]?.parkForEventsRequested = true
        if let questionOverride { executionStates[key]?.parkQuestionOverride = questionOverride }
    }

    /// Drives the shared click/scroll path with an INJECTED `perform`, so a test can assert
    /// whether input WOULD have been synthesized without synthesizing any.
    ///
    /// The real closure calls `InputControlService.click` / `.scroll`, which post CGEvents at
    /// the developer's actual cursor — a test that exercised the real path would move the mouse
    /// and click, and a RED run of the cancellation pin would click precisely because the fix
    /// was absent. `perform` is already a parameter of `runPointerAction`; this only exposes it.
    ///
    /// Pass a capture whose `bundleID` and `appName` are nil and a nil `target` so the activation
    /// branch resolves no app: no `NSRunningApplication` lookup, no window raise, no settle sleep.
    ///
    /// `capture: nil` seeds a step that has taken no screenshot yet — the "call screen_capture
    /// first" arm, which is otherwise reachable only through `appendComputerUseResult`, i.e. only
    /// past an Accessibility check whose answer depends on the developer's machine.
    func _testRunPointerAction(
        x: Int, y: Int, target: String?, warnOnMiss: Bool,
        stepID: String, taskID: Int,
        capture: CapturedScreen?,
        elements: [AXElementInfo] = [],
        actionsSinceCapture: Int = 0,
        conversationMessages: inout [ChatMessage],
        perform: (CGPoint) -> String
    ) async {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil { executionStates[key] = StepExecutionState() }
        executionStates[key]?.lastComputerUseCapture = capture
        executionStates[key]?.lastComputerUseElements = elements
        executionStates[key]?.computerUseActionsSinceCapture = actionsSinceCapture
        await runPointerAction(
            x: x, y: y, target: target, key: key, warnOnMiss: warnOnMiss, perform: perform,
            result: ToolExecutionResult(
                providerID: "call-1", toolName: ToolNames.uiClick,
                argumentsJSON: "{}", outputJSON: "", isError: false),
            toolCallID: UUID(), stepID: stepID, taskID: taskID,
            conversationMessages: &conversationMessages, tracker: nil)
    }

    /// How many screenshots this RUN has taken — the counter the first-capture-per-run privacy
    /// prompt keys on, and the reason a capture that FAILED must not increment it.
    func _testComputerUseCaptureCount(taskID: Int) -> Int {
        computerUseCaptureCountByTask[taskID] ?? 0
    }

    /// Seeds the per-step capture state a click/scroll resolves against, exactly as a DELIVERED
    /// `screen_capture` would have. Lets a test drive `appendComputerUseResult` — which enters at
    /// the permission gate, not at `runPointerAction` — against a step that has already taken a
    /// screenshot, without going through a real one.
    func _testSeedComputerUseCapture(
        stepID: String, taskID: Int, capture: CapturedScreen?, elements: [AXElementInfo] = []
    ) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if executionStates[key] == nil { executionStates[key] = StepExecutionState() }
        executionStates[key]?.lastComputerUseCapture = capture
        executionStates[key]?.lastComputerUseElements = elements
    }

    /// The capture clicks currently resolve against — `nil` when the step has taken none, or
    /// when the last one was never delivered to the model.
    func _testLastComputerUseCapture(stepID: String, taskID: Int) -> CapturedScreen? {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.lastComputerUseCapture
    }

    /// The element list shipped with that capture — what the click echo resolves against.
    func _testLastComputerUseElements(stepID: String, taskID: Int) -> [AXElementInfo]? {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.lastComputerUseElements
    }

    /// Reads the computer-use staleness counter — how many UI-changing actions have run since
    /// the capture whose coordinate space clicks are still resolving against. Only an action
    /// that actually reached the screen may advance it.
    func _testComputerUseActionsSinceCapture(stepID: String, taskID: Int) -> Int {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.computerUseActionsSinceCapture ?? -1
    }

    /// Reads the current drift counter for a step (for integration tests).
    func _testDriftCounter(stepID: String, taskID: Int) -> Int {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveDriftTurnCount ?? -1
    }

    /// Reads the reasoning-channel-envelope counter for a step — the streak of turns whose
    /// only dispatchable envelope was written into the reasoning channel.
    func _testReasoningEnvelopeCounter(stepID: String, taskID: Int) -> Int {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveReasoningEnvelopeCount ?? -1
    }

    /// Mirrors the production drift-counter reset that happens just before
    /// `executeToolCalls` runs (the model is acting, not just reasoning). Used by
    /// tests to simulate "tool call ran between two drift turns" without spinning
    /// up the full streaming + tool-execution pipeline.
    func _testResetDriftCounter(stepID: String, taskID: Int) {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveDriftTurnCount = 0
    }

    /// Reads the current advisory-no-tool counter for a step (for no-tool-backstop tests).
    func _testNonProductiveTurnCounter(stepID: String, taskID: Int) -> Int {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveNonProductiveTurns ?? -1
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

    /// Mirrors the production advisory-counter reset, which runs AFTER the tool results
    /// are known and only for a `ToolTurnProductivity.productive` turn — emitting a call
    /// is not acting, so a batch that came back entirely errors must not re-arm the
    /// ceiling. Tests calling this are asserting the *productive* case; the rule itself is
    /// pinned by `ToolTurnProductivityTests`.
    func _testResetNonProductiveTurnCounter(stepID: String, taskID: Int) {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveNonProductiveTurns = 0
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
