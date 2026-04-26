import Foundation

/// Extension for step flow control: no-tool-call handling and planning phase management.
extension LLMExecutionService {

    /// True when the step has a pending supervisor-feedback revision. Reads the
    /// freshest task from the delegate so mid-iteration mutations are observed.
    func isStepInRevision(stepID: String) -> Bool {
        guard let delegate, let tid = taskIDForStep(stepID),
              let t = delegate.loadedTask(tid),
              let ri = t.runs.indices.last,
              let s = t.runs[ri].steps.first(where: { $0.id == stepID })
        else { return false }
        return s.revisionComment != nil
    }

    // MARK: - No-Tool-Call Handling

    /// Handles the case where the LLM produced no tool calls.
    /// Always returns `.continueLoop` — roles never self-terminate here.
    /// Producing roles get artifact-missing reminders; other roles get tool-use nudges.
    func handleNoToolCalls(
        stepID: String,
        result: StreamingResult,
        roleForMessage: Role,
        task _: NTMSTask,
        runIndex _: Int,
        stepIndex _: Int,
        memory _: ToolCallCache,
        roleDefinition: TeamRoleDefinition?,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop {
        // Thinking-drift detection: the model produced a long reasoning trace with
        // no tool call and no user-visible content. First occurrence → targeted
        // nudge. Second consecutive → escalate to supervisor. The counter is kept
        // in executionStates and reset whenever tool calls execute.
        // Skipped during revision — supervisor is already driving.
        let assistantTrimmedLen = result.assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).count
        let thinkingTrimmedLen = result.thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines).count
        let isDrift = ConversationRepairService.isThinkingDrift(
            thinkingLength: thinkingTrimmedLen,
            contentLength: assistantTrimmedLen,
            toolCallCount: result.resolvedToolCalls.count
        )
        if isDrift, !isStepInRevision(stepID: stepID) {
            let newCount = (executionStates[stepID]?.consecutiveDriftTurnCount ?? 0) + 1
            executionStates[stepID]?.consecutiveDriftTurnCount = newCount
            if newCount >= 2 {
                // Reset so a post-supervisor restart starts clean.
                executionStates[stepID]?.consecutiveDriftTurnCount = 0
                let question = """
                Role \(roleForMessage.displayName) produced two consecutive long reasoning \
                responses (~\(thinkingTrimmedLen / 1000)k characters of internal thinking \
                last turn) without calling any tool. The model is reasoning instead of acting \
                — please advise how to proceed (clarify the task, give an explicit next step, \
                or mark the step failed).
                """
                await setNeedsSupervisorInput(stepID: stepID, question: question, sessionID: nil)
                return .needsSupervisorInput(question: question)
            }
            let nudge = """
            Your previous response had ~\(thinkingTrimmedLen / 1000)k characters of internal \
            reasoning but no tool call. Internal reasoning is not a tool call — it cannot write \
            files, read anything, or submit artifacts. Take one concrete action now by calling \
            a tool (e.g. `write_file`, `read_lines`, `create_artifact`, or `ask_supervisor` if \
            you genuinely need input). Keep reasoning brief next turn.
            """
            conversationMessages.append(ChatMessage(role: .user, content: nudge))
            await appendLLMMessage(stepID: stepID, role: .user, content: nudge)
            return .continueLoop
        } else {
            // Reset on EITHER non-drift turn (model produced content) OR drift-during-
            // revision (the supervisor is already driving via the revision flow; an
            // accumulated counter from before the revision shouldn't pre-trigger a
            // post-revision escalation on the very first new drift turn).
            executionStates[stepID]?.consecutiveDriftTurnCount = 0
        }

        // Loop detection runs first — once the supervisor is asked (or the nudge
        // fires), the other branches are moot. Skipped during revision because
        // the supervisor is already driving.
        if !isStepInRevision(stepID: stepID) {
            switch ConversationRepairService.detectMessageLoop(conversationMessages: conversationMessages) {
            case .refusalLoop(let count, let sample):
                let snippet = String(sample.prefix(300))
                let question = """
                Role \(roleForMessage.displayName) emitted \(count) consecutive refusal messages without \
                calling any tools. The model appears stuck — please advise how to proceed (answer the \
                underlying need, provide explicit instructions, or mark the step failed).

                Last message excerpt:
                \(snippet)
                """
                await setNeedsSupervisorInput(stepID: stepID, question: question, sessionID: nil)
                return .needsSupervisorInput(question: question)

            case .repetitiveNonTool(let count):
                let retryMessage = """
                Your last \(count) responses were near-identical and contained no tool calls. \
                If you've finished your work, call create_artifact to submit your deliverable. \
                If you're blocked, call ask_supervisor with a specific question. \
                Do not repeat this response again — take a concrete action.
                """
                conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
                return .continueLoop

            case .noLoop:
                break
            }
        }

        // Harmony markers were detected but parsing failed — the model attempted a tool
        // call the parser couldn't extract. Classify *why*: broken JSON vs. valid JSON
        // without a top-level `name` (the `{"arguments":{…}}` shape some models emit).
        // Sending the wrong nudge burns retries on a defect the model can't fix.
        // Must be checked BEFORE the generic "only tokens" branch — pre-marker text is
        // usually whitespace that would otherwise match tokens-only and send an
        // unrelated retry.
        if result.sawHarmonyMarker {
            let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(in: result.assistantContent)
            let retryMessage: String
            switch issue {
            case .missingToolName(let inferredToolName):
                let example = inferredToolName ?? "TOOL_NAME"
                retryMessage = """
                Your tool call JSON parsed, but it is missing the top-level `name` field. \
                The top-level `name` identifies the tool to call (e.g. "create_artifact", \
                "write_file", "ask_supervisor"); the `name` inside `arguments` is a tool \
                *parameter* (e.g. the artifact name for create_artifact). Retry with:
                `<|call|>{"name":"\(example)","arguments":{…}}<|end|>`
                """
            case .malformedJSON:
                retryMessage = "Your previous tool call had malformed JSON and could not be parsed (e.g. a missing closing brace `}`, an unescaped quote inside a string, or a trailing comma). Retry with valid JSON, e.g. `<|call|>{\"name\":\"TOOL_NAME\",\"arguments\":{…}}<|end|>` — note the two closing braces before `<|end|>`."
            }
            conversationMessages.append(
                ChatMessage(role: .user, content: retryMessage)
            )
            await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
            return .continueLoop
        }

        // Check if content contains only model tokens (Issue #24, #32)
        let originalContent = result.assistantContent
        let cleanedContent = ModelTokenCleaner.clean(originalContent)

        if !originalContent.isEmpty && cleanedContent.isEmpty {
            // Content was entirely garbled tokens with no substantive text
            let retryMessage = "Your previous response contained only model-internal tokens (<|...|>) with no actual content. Please provide a substantive response with proper tool calls or completion message."
            conversationMessages.append(
                ChatMessage(role: .user, content: retryMessage)
            )
            await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
            return .continueLoop
        }

        // Planning phase fallback: the model emitted prose instead of calling
        // update_scratchpad. Persist the prose as the implicit plan so the next
        // iteration's applyPlanningPhase sees a non-nil scratchpad and transitions
        // to implementation. The user nudge is required — without it, the next
        // stateful continuation would send `{"input":""}` and LM Studio rejects
        // with HTTP 400.
        if let systemMsg = conversationMessages.first(where: { $0.role == .system }),
           systemMsg.content?.contains("PLANNING PHASE") == true {
            let plan = cleanedContent.isEmpty ? "(no plan provided)" : cleanedContent
            if let tid = taskIDForStep(stepID), let delegate {
                _ = await delegate.mutateTask(taskID: tid) { task in
                    guard let runIndex = task.runs.indices.last,
                          let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
                    else { return }
                    if task.runs[runIndex].steps[stepIndex].scratchpad == nil {
                        task.runs[runIndex].steps[stepIndex].scratchpad = plan
                    }
                }
            }
            let nudge = "Plan recorded from your text response. Now proceeding to IMPLEMENTATION PHASE — execute your plan using your full toolset."
            conversationMessages.append(ChatMessage(role: .user, content: nudge))
            await appendLLMMessage(stepID: stepID, role: .user, content: nudge)
            return .continueLoop
        }

        // Producing role — retry if artifacts missing, complete if all present
        if let roleDef = roleDefinition {
            let expected = roleDef.dependencies.producesArtifacts.filter { $0 != ArtifactConstants.buildDiagnosticsName }
            if !expected.isEmpty {
                // Producing role — check artifact completeness
                if let artifactStop = checkArtifactCompleteness(stepID: stepID) {
                    return artifactStop
                }

                if isStepInRevision(stepID: stepID) {
                    let retryMessage = "Please address the supervisor's feedback and submit updated artifacts via create_artifact."
                    conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                    await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
                    return .continueLoop
                }

                // Missing artifacts — retry. Names must be quoted and verbatim;
                // extensions / prefixes / rewordings cause name-resolution misses.
                let quoted = expected.map { "\"\($0)\"" }.joined(separator: ", ")
                let retryMessage = "You haven't submitted all expected artifacts yet. Missing deliverables: \(quoted). Call create_artifact(name=\"<exact name from quotes>\", content=\"...\") for each. Do NOT add file extensions (.md), prefixes, or rewordings — use the quoted name verbatim."
                conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
                return .continueLoop
            }
        }

        // Advisory role under autonomous supervisor — increment the non-productive-turn
        // counter and auto-finish if threshold is reached.
        if let stop = await attemptAdvisoryAutoFinish(stepID: stepID, roleDefinition: roleDefinition) {
            return stop
        }

        // No tool calls and no artifacts to produce — nudge to use tools.
        // Roles never self-terminate here; only artifact completion or Supervisor's "Finish Role" ends a step.
        let retryMessage = "You responded with text but did not call any tools. Use your available tools to continue working. If you need input from the Supervisor, call ask_supervisor."
        conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
        await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
        return .continueLoop
    }

    /// Increments `consecutiveAdvisoryNoToolTurns` and auto-finishes the step if the
    /// threshold is reached. Called for advisory roles under autonomous supervisor
    /// mode after any "non-productive" turn — either no tool calls at all, or only
    /// `ask_supervisor` (which gets auto-answered and so doesn't constitute progress).
    /// Returns `.completed` when the threshold is reached AND the mutation actually
    /// landed; `nil` otherwise.
    ///
    /// Threshold = 3 leaves room for 2 nudges to recover before terminating.
    ///
    /// Important: this path writes `roleStatuses[roleID] = .done` directly, bypassing
    /// `handleRoleCompleted`. That function would route an `.finalOnly` (default)
    /// acceptance into `.needsAcceptance`, which the engine's chat-mode arm in the
    /// `readyRoleIDs.isEmpty` block does NOT exit cleanly — leaving the role at
    /// `.needsAcceptance` deadlocks into `transition(to: .failed)` with
    /// "Execution stalled". Setting role.done here mirrors the semantics of
    /// `NTMSOrchestrator.finishAdvisoryRole` and lets the engine's chat-mode
    /// all-terminal arm transition to `.done`. Bypass is gated to chat-mode
    /// teams — non-chat teams (e.g. a custom FAANG variant with an advisory
    /// role) route through `handleRoleCompleted` so the engine's `.finalOnly`
    /// acceptance plumbing fires correctly.
    ///
    /// CLAUDE.md §7 discipline: `mutateTask`'s `Bool` return only means
    /// "persisted" — the closure can short-circuit (run/step indices fail to
    /// resolve after restart/revision) and `mutateTask` still returns true.
    /// We use a captured `didApply` flag to detect that and refuse to
    /// announce completion when the mutation didn't actually run.
    func attemptAdvisoryAutoFinish(
        stepID: String,
        roleDefinition: TeamRoleDefinition?
    ) async -> LLMStepStop? {
        guard let roleDef = roleDefinition, roleDef.isAdvisory,
              !isStepInRevision(stepID: stepID),
              isAutonomousSupervisorMode(stepID: stepID),
              executionStates[stepID] != nil
        else { return nil }
        executionStates[stepID]!.consecutiveAdvisoryNoToolTurns += 1
        let count = executionStates[stepID]!.consecutiveAdvisoryNoToolTurns
        guard count >= 3 else { return nil }

        // Hard guard: without a task id and a delegate, the bypass path can't
        // land at all — falling through and announcing completion would write
        // a fake assistant message and return `.completed` despite step still
        // being `.running`. Keep counter incremented (so the next iteration
        // notices the cap is past) and bail out by returning nil.
        guard let tid = taskIDForStep(stepID), let delegate else {
            return nil
        }

        // Chat-mode-only bypass (I6): direct status writes are safe only when
        // the engine's chat-mode arm consumes them. Non-chat teams must route
        // through `handleRoleCompleted` so acceptance/checkpointing plumbing
        // fires. If we can't determine chat-mode (no team, no task), prefer
        // safety: don't bypass.
        let isChatMode = (delegate.loadedTask(tid).flatMap(resolveTeam(task:))?.isChatMode) ?? false
        guard isChatMode else { return nil }

        // CLAUDE.md §7: capture-flag pattern. `mutateTask == true` only proves
        // persistence — the closure could have early-returned without applying.
        var didApply = false
        let mutated = await delegate.mutateTask(taskID: tid) { task in
            guard let runIdx = task.runs.indices.last,
                  let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.id == stepID })
            else { return }
            let roleID = task.runs[runIdx].steps[stepIdx].effectiveRoleID
            task.runs[runIdx].steps[stepIdx].status = .done
            task.runs[runIdx].steps[stepIdx].completedAt = MonotonicClock.shared.now()
            task.runs[runIdx].roleStatuses[roleID] = .done
            task.runs[runIdx].updatedAt = MonotonicClock.shared.now()
            didApply = true
        }
        guard mutated, didApply else {
            // Don't reset the counter — leave it at its current value so a
            // retry on the next iteration will re-attempt rather than silently
            // burying the threshold breach. Don't post a "finished" message
            // either — that would lie about state that didn't change.
            return nil
        }

        executionStates[stepID]!.consecutiveAdvisoryNoToolTurns = 0
        let finishNote = "Advisory role auto-finished after \(count) consecutive turns without productive tool calls."
        await appendLLMMessage(stepID: stepID, role: .assistant, content: finishNote)
        return .completed
    }

    /// Gates the advisory auto-finish path: with a human Supervisor in the loop
    /// (`.manual`), the role can wait indefinitely for a "Finish Role" click; without
    /// one (`.autonomous`), it would loop forever once it stops calling tools.
    private func isAutonomousSupervisorMode(stepID: String) -> Bool {
        guard let delegate, let tid = taskIDForStep(stepID),
              let task = delegate.loadedTask(tid),
              let team = resolveTeam(task: task)
        else { return false }
        return team.settings.supervisorMode == .autonomous
    }

    // MARK: - Planning Phase

    /// Applies planning phase modifications to conversation and tools for the first iteration.
    /// Returns the tool set to use for this iteration.
    /// Returns `(tools, resetSession)`. When `resetSession` is `true`, the caller must clear
    /// the stateful session so the next LLM call sends the full (restored) system prompt,
    /// establishing it in a fresh response chain.
    func applyPlanningPhase(
        stepID: String,
        roleForMessage: Role,
        tools: [ToolSchema],
        step: StepExecution,
        memory: ToolCallCache,
        conversationMessages: inout [ChatMessage],
        roleDefinition: TeamRoleDefinition?
    ) async -> (tools: [ToolSchema], resetSession: Bool) {
        let usePlanningPhase = roleDefinition?.usePlanningPhase ?? true
        let isFirstIteration = step.scratchpad == nil && memory.recentCalls(limit: 1).isEmpty
        let hasPriorConversation = !step.llmConversation.isEmpty
        let hasScratchpadTool = tools.contains { $0.name == ToolNames.updateScratchpad }

        if usePlanningPhase && isFirstIteration && hasScratchpadTool {
            // Save original system prompt before replacing
            if let systemMsg = conversationMessages.first(where: { $0.role == .system }) {
                executionStates[stepID]?.originalSystemPrompt = systemMsg.content
            }

            // Planning-phase prompt intentionally omits an inline tool-call example:
            // `buildToolSchemaSection` already appends a single `## Tool Calling`
            // block (with the Harmony format + a concrete example) to every system
            // prompt, and a second inline example in a different syntax produces
            // mixed-format output on smaller models.
            let planningSystemPrompt = """
            You are \(roleForMessage.displayName).

            PLANNING PHASE
            ==============
            Before starting work, create your plan.

            Call `update_scratchpad` with a numbered list of steps you will take, for example:
            1. Review the requirements
            2. Research relevant context
            3. Create an outline
            4. Produce the deliverable

            This is the only tool available now. After you create your plan, you will have access to all your tools.
            """

            if let systemIdx = conversationMessages.firstIndex(where: { $0.role == .system }) {
                conversationMessages[systemIdx] = ChatMessage(
                    role: .system,
                    content: planningSystemPrompt
                )
            }
            await saveLLMConversation(stepID: stepID, messages: conversationMessages)
            return (tools.filter { $0.name == ToolNames.updateScratchpad }, resetSession: false)
        } else {
            // Restore original system prompt after planning phase
            var didRestorePrompt = false
            if let savedPrompt = executionStates[stepID]?.originalSystemPrompt,
               let systemIdx = conversationMessages.firstIndex(where: { $0.role == .system }),
               conversationMessages[systemIdx].content?.contains("PLANNING PHASE") == true {
                conversationMessages[systemIdx] = ChatMessage(
                    role: .system,
                    content: savedPrompt
                )
                executionStates[stepID]?.originalSystemPrompt = nil
                didRestorePrompt = true
                // Update only the system message — saveLLMConversation would replace all messages
                // and lose thinking content from the planning phase assistant response
                await updatePersistedSystemMessage(stepID: stepID, content: savedPrompt)
            } else if isFirstIteration && !hasPriorConversation {
                await saveLLMConversation(stepID: stepID, messages: conversationMessages)
            }
            // Reset session when system prompt was swapped so the next call sends the full
            // original prompt in a fresh chain (NativeLMStudioClient omits system_prompt on
            // stateful continuations, so stale planning prompt in the chain would be wrong).
            return (tools, resetSession: didRestorePrompt)
        }
    }
}
