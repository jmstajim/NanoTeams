import Foundation

// The single-iteration tool-loop orchestrator. Extracted from the core; it
// delegates to the focused +Streaming / +StepFlowControl / +ToolExecution /
// +ToolResultProcessing / +ToolLoopState methods.
extension LLMExecutionService {

    // MARK: - LLM Tool Iteration

    /// Run exactly one assistant generation + optional tool execution pass.
    ///
    /// This method orchestrates a single LLM iteration by delegating to focused methods:
    /// - `applyPlanningPhase` — manages first-iteration planning constraints
    /// - `performStreamingCall` — executes the LLM streaming call and collects tokens
    /// - `processStreamingResult` — appends messages and detects completion signals
    /// - `handleNoToolCalls` — handles missing tool calls (learning + retry)
    /// - `executeToolCalls` — executes tools through `ToolRuntime`
    /// - `processToolResults` — processes results (teammate, meeting, scratchpad, errors)
    /// - `handleSupervisorAutoAnswer` — auto-answers Supervisor questions in autonomous mode
    /// - `injectMemories` — keeps the LLM oriented with tag index and plan context
    /// - `checkAndInjectLoopWarning` — detects and warns about looping patterns
    func runOneLLMToolIteration(
        stepID: String,
        roleForMessage: Role,
        client: any LLMClient,
        config: LLMConfig,
        tools: [ToolSchema],
        runtime: ToolRuntime,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        supervisorMode: SupervisorMode,
        conversationMessages: inout [ChatMessage],
        tracker: ToolCallTracker,
        memoryStore: MemoryTagStore,
        iterationNumber: Int,
        session: inout LLMSession?,
        cumulativeUsage: inout TokenUsage,
        networkLogger: NetworkLogger? = nil,
        toolObserver: (([StepToolCall], [ToolExecutionResult]) -> Void)? = nil
    ) async throws -> LLMStepStop {
        guard let delegate else { return .toolFailure(message: "Delegate not available") }

        // Refresh the task snapshot so every downstream read this iteration sees
        // the state just committed through `delegate.mutateTask`.
        let task = Self.refreshedTaskSnapshot(task, delegate: delegate)
        let resolvedTeam = resolveTeam(task: task)
        let step = task.runs[runIndex].steps[stepIndex]
        let roleDefinition = resolvedTeam?.findRole(byIdentifier: step.effectiveRoleID)

        // 2. Apply planning phase (first iteration only)
        let (toolsForIteration, resetSession) = await applyPlanningPhase(
            stepID: stepID,
            taskID: task.id,
            roleForMessage: roleForMessage,
            tools: tools,
            step: step,
            tracker: tracker,
            conversationMessages: &conversationMessages,
            roleDefinition: roleDefinition
        )
        // After planning→implementation transition, the system prompt changed.
        // Clear session so the next call sends the full original prompt in a fresh chain
        // (NativeLMStudioClient omits system_prompt on stateful continuations).
        if resetSession { session = nil }

        // 2a. Consume any queued Supervisor message targeted at this role (or the
        // untargeted Team queue). Appends a user turn to `conversationMessages`
        // for this iteration's request. Skipped on iteration-1 continuation paths
        // (see `injectQueuedSupervisorMessage` for the stateful-chain rationale).
        if isExecutionLive(stepID: stepID, taskID: task.id) {
            await injectQueuedSupervisorMessage(
                stepID: stepID,
                taskID: task.id,
                roleID: step.effectiveRoleID,
                iterationNumber: iterationNumber,
                session: session,
                conversationMessages: &conversationMessages
            )
        }

        // 2. Determine messages to send: on a stateful continuation, only the new messages
        // since the last call (the empty-slice case falls back to a fresh stateless turn).
        let slice = Self.statefulContinuationSlice(
            conversationMessages: conversationMessages, isStateful: session != nil)
        if slice.fallBackToStateless { session = nil }
        let messagesToSend = slice.messages

        // 2b. Stream LLM response
        let streamResult = try await performStreamingCall(
            stepID: stepID,
            taskID: task.id,
            roleForMessage: roleForMessage,
            client: client,
            config: config,
            tools: toolsForIteration,
            conversationMessages: messagesToSend,
            session: session,
            networkLogger: networkLogger,
            roleName: roleForMessage.displayName.isEmpty ? nil : roleForMessage.displayName
        )

        // Update session and accumulate token usage
        if let newSession = streamResult.session {
            session = newSession
        }
        if let usage = streamResult.tokenUsage { cumulativeUsage.accumulate(usage) }

        // 2c. Top-level thinking-loop break: the stream was aborted + the looping
        // generation discarded (no anchor in `conversationMessages`, nothing in
        // `step.messages`). Recover via `LoopRecoveryPolicy` — clean retry or a
        // mode-aware terminal — BEFORE `processStreamingResult`. Any clean stream
        // completion (no signal) resets the consecutive-break counter.
        if let loopSignal = streamResult.thinkingLoopSignal {
            return await handleStreamLoopBreak(
                stepID: stepID, signal: loopSignal, task: task,
                roleForMessage: roleForMessage, supervisorMode: supervisorMode,
                session: &session)
        }
        resetThinkingLoopBreakCount(stepID: stepID, taskID: task.id)

        // 3. Process streaming result (append messages, check completion signals)
        if let completionStop = await processStreamingResult(
            streamResult, stepID: stepID, taskID: task.id,
            conversationMessages: &conversationMessages)
        {
            return completionStop
        }

        // 4. If no tool calls, handle accordingly
        if streamResult.resolvedToolCalls.isEmpty {
            return await handleNoToolCalls(
                stepID: stepID,
                result: streamResult,
                roleForMessage: roleForMessage,
                task: task,
                runIndex: runIndex,
                stepIndex: stepIndex,
                tracker: tracker,
                roleDefinition: roleDefinition,
                runtime: runtime,
                conversationMessages: &conversationMessages
            )
        }

        // 5. Execute tool calls (authorization + identical-write guard)
        // Reset drift + Harmony parse-failure counters: the model is acting and
        // produced a parseable tool call. Centralized so a refactor that drops
        // the call here is also detected by `LLMExecutionServiceParseFailureCapTests`
        // (regression: T1 — the helper-only reset was not exercising this prod path).
        resetCountersOnParseableToolCall(stepID: stepID, taskID: task.id)
        // Reset advisory no-tool-call counter only when at least one tool call is
        // *productive*. `ask_supervisor` doesn't qualify under autonomous supervisor
        // mode — it gets auto-answered, and the model can ping itself in a loop with
        // it forever without doing any real work. So a turn whose only tool calls are
        // `ask_supervisor` is treated the same as a no-tool-call turn for the purposes
        // of the advisory auto-finish safeguard (incremented in `handleNoToolCalls`).
        let toolNamesThisTurn = Set(streamResult.resolvedToolCalls.map(\.name))
        let isAskSupervisorOnly = toolNamesThisTurn == [ToolNames.askSupervisor]
        if isAskSupervisorOnly {
            // Non-productive turn: ask_supervisor gets auto-answered in autonomous mode,
            // so the model can ping itself in a loop with it forever. Treat it as a
            // no-tool-call turn for the advisory auto-finish counter.
            if let stop = await attemptAdvisoryAutoFinish(
                stepID: stepID, taskID: task.id, roleDefinition: roleDefinition)
            {
                return stop
            }
        } else {
            executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?
                .consecutiveAdvisoryNoToolTurns = 0
        }
        let allowedToolNames = Set(toolsForIteration.map(\.name))

        // 5a. Bash permission gate (pre-pass): intercept shell commands that must
        // be denied or judged (Auto) BEFORE they reach `executeToolCalls`. Returns
        // synthetic results (carrying each call's providerID — no orphan tool_call)
        // for the calls it handles; everything else passes through to
        // `executeToolCalls`. With a human present, an `.ask` command is HELD and the
        // gate awaits the human's Allow/Deny in-loop (bypassing the model) — not
        // surfaced as a supervisor question; with no human it is denied.
        let gateResults = await gateBashCalls(
            resolvedToolCalls: streamResult.resolvedToolCalls,
            allowedToolNames: allowedToolNames,
            stepID: stepID,
            taskID: task.id,
            supervisorMode: supervisorMode,
            task: task,
            client: client,
            config: config,
            networkLogger: networkLogger
        )
        let callsToExecute = streamResult.resolvedToolCalls.enumerated()
            .filter { gateResults[$0.offset] == nil }
            .map(\.element)
        let executedResults = await executeToolCalls(
            resolvedToolCalls: callsToExecute,
            allowedToolNames: allowedToolNames,
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: runIndex,
            roleID: step.effectiveRoleID
        )
        // Merge gate synthetics back into the original emit order so
        // `processToolResults` can `zip(resolvedToolCalls, results)` by index.
        var toolResults: [ToolExecutionResult] = []
        toolResults.reserveCapacity(streamResult.resolvedToolCalls.count)
        var executedIdx = 0
        for (idx, _) in streamResult.resolvedToolCalls.enumerated() {
            if let synth = gateResults[idx] {
                toolResults.append(synth)
            } else if executedIdx < executedResults.count {
                toolResults.append(executedResults[executedIdx])
                executedIdx += 1
            }
        }

        toolObserver?(streamResult.resolvedToolCalls, toolResults)

        // 6. Process tool results (teammate, meeting, scratchpad, errors, learning)
        let outcome = await processToolResults(
            resolvedToolCalls: streamResult.resolvedToolCalls,
            results: toolResults,
            stepID: stepID,
            roleForMessage: roleForMessage,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            assistantContent: streamResult.assistantContent,
            client: client,
            config: config,
            tracker: tracker,
            memoryStore: memoryStore,
            iterationNumber: iterationNumber,
            conversationMessages: &conversationMessages,
            networkLogger: networkLogger
        )

        // 6b. Handle Supervisor question BEFORE artifact completeness — if the LLM both
        // completed all artifacts AND asked a supervisor question in one batch, the question
        // must not be silently dropped.
        if let autoAnswerStop = await handleSupervisorAutoAnswer(
            outcome: outcome,
            stepID: stepID,
            supervisorMode: supervisorMode,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            client: client,
            config: config,
            conversationMessages: &conversationMessages
        ) {
            return autoAnswerStop
        }

        if outcome.shouldStopForSupervisor, let q = outcome.supervisorQuestion {
            return .needsSupervisorInput(question: q)
        }

        // 7. Check if all expected artifacts have been created → auto-complete
        if let artifactStop = checkArtifactCompleteness(stepID: stepID, taskID: task.id) {
            return artifactStop
        }

        // 8. Inject Memories (tag index + plan summary)
        await injectMemories(
            stepID: stepID,
            taskID: task.id,
            memoryStore: memoryStore,
            session: session,
            conversationMessages: &conversationMessages
        )

        // 9. Check for looping patterns
        await checkAndInjectLoopWarning(
            stepID: stepID,
            taskID: task.id,
            tracker: tracker,
            conversationMessages: &conversationMessages
        )

        return .continueLoop
    }
}
