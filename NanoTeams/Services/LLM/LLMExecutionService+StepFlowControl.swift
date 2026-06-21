import Foundation

/// Extension for step flow control: no-tool-call handling and planning phase management.
extension LLMExecutionService {

    /// True when the step has a pending supervisor-feedback revision. Reads the
    /// freshest task from the delegate so mid-iteration mutations are observed.
    func isStepInRevision(stepID: String, taskID: Int) -> Bool {
        guard let delegate,
              let t = delegate.loadedTask(taskID),
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
        task: NTMSTask,
        runIndex: Int,
        stepIndex _: Int,
        tracker _: ToolCallTracker,
        roleDefinition: TeamRoleDefinition?,
        runtime: ToolRuntime? = nil,
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
        let stepKey = TaskStepKey(taskID: task.id, stepID: stepID)
        if isDrift, !isStepInRevision(stepID: stepID, taskID: task.id) {
            let newCount = (executionStates[stepKey]?.consecutiveDriftTurnCount ?? 0) + 1
            executionStates[stepKey]?.consecutiveDriftTurnCount = newCount
            if newCount >= 2 {
                // Reset so a post-supervisor restart starts clean.
                executionStates[stepKey]?.consecutiveDriftTurnCount = 0
                let question = """
                Role \(roleForMessage.displayName) produced two consecutive long reasoning \
                responses (~\(thinkingTrimmedLen / 1000)k characters of internal thinking \
                last turn) without calling any tool. The model is reasoning instead of acting \
                — please advise how to proceed (clarify the task, give an explicit next step, \
                or mark the step failed).
                """
                let escalated = await setNeedsSupervisorInput(
                    stepID: stepID, taskID: task.id, question: question, sessionID: nil)
                // If persistence failed, surface a real failure instead of transitioning to
                // "needs Supervisor input" with no question rendered — which is strictly
                // worse than the loop this branch replaced.
                guard escalated else {
                    return .toolFailure(message: "Drift cap exceeded but Supervisor escalation failed to persist; aborting step. Question would have been: \(question)")
                }
                return .needsSupervisorInput(question: question)
            }
            let nudge = """
            Your previous response had ~\(thinkingTrimmedLen / 1000)k characters of internal \
            reasoning but no tool call. Internal reasoning is not a tool call — it cannot write \
            files, read anything, or submit artifacts. Take one concrete action now. Keep \
            reasoning brief next turn.
            """
            conversationMessages.append(ChatMessage(role: .user, content: nudge))
            await appendLLMMessage(stepID: stepID, taskID: task.id, role: .user, content: nudge)
            return .continueLoop
        } else {
            // Reset on EITHER non-drift turn (model produced content) OR drift-during-
            // revision (the supervisor is already driving via the revision flow; an
            // accumulated counter from before the revision shouldn't pre-trigger a
            // post-revision escalation on the very first new drift turn).
            executionStates[stepKey]?.consecutiveDriftTurnCount = 0
        }

        // Loop detection runs first — once the supervisor is asked (or the nudge
        // fires), the other branches are moot. Skipped during revision because
        // the supervisor is already driving.
        if !isStepInRevision(stepID: stepID, taskID: task.id) {
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
                let escalated = await setNeedsSupervisorInput(
                    stepID: stepID, taskID: task.id, question: question, sessionID: nil)
                guard escalated else {
                    return .toolFailure(message: "Refusal-loop cap exceeded but Supervisor escalation failed to persist; aborting step.")
                }
                return .needsSupervisorInput(question: question)

            case .repetitiveNonTool(let count):
                let retryMessage = """
                Your last \(count) responses were near-identical and contained no tool calls. \
                If you've finished your work, call create_artifact to submit your deliverable. \
                If you're blocked, call ask_supervisor with a specific question. \
                Do not repeat this response again — take a concrete action.
                """
                conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                await appendLLMMessage(stepID: stepID, taskID: task.id, role: .user, content: retryMessage)
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
            // The raw envelope is in `harmonyBuffer` once a Harmony marker was seen mid-stream
            // (or `thinkingContent` for the reasoning-channel fallback) — NOT `assistantContent`,
            // which holds only the pre-marker prose. Classify and surface from there.
            let envelopeSource: String = {
                if !result.harmonyBuffer.isEmpty { return result.harmonyBuffer }
                if result.thinkingContent.contains("<|") { return result.thinkingContent }
                return result.assistantContent
            }()
            let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(in: envelopeSource)
            // Surface the failed attempt as a visible, errored feed card. Without this the
            // model's malformed / name-missing tool call never becomes a `StepToolCall` and is
            // invisible in Team Activity (only a retry nudge appears in the conversation).
            let runID = task.runs.indices.contains(runIndex)
                ? task.runs[runIndex].id : (task.runs.last?.id ?? 0)
            await recordFailedToolCallAttemptIfNeeded(
                stepID: stepID, taskID: task.id, runID: runID, issue: issue, envelope: envelopeSource,
                runtime: runtime)
            let retryMessage: String?
            switch issue {
            case .missingToolName(let inferredToolName):
                // `.missingToolName` is a different recoverable defect — the inferred-name
                // nudge below usually self-corrects on the next attempt. Reset the
                // malformed-JSON counter so a previous .malformedJSON streak doesn't
                // pre-trigger escalation on the very next .malformedJSON turn after
                // the model recovered to a parseable-but-name-missing shape.
                executionStates[stepKey]?.consecutiveHarmonyParseFailureCount = 0
                let example = inferredToolName ?? "TOOL_NAME"
                retryMessage = """
                Your tool call JSON parsed, but it is missing the top-level `name` field. \
                The top-level `name` identifies the tool to call (e.g. "create_artifact", \
                "write_file", "ask_supervisor"); the `name` inside `arguments` is a tool \
                *parameter* (e.g. the artifact name for create_artifact). Retry with:
                `<|call|>{"name":"\(example)","arguments":{…}}<|end|>`
                """
            case .malformedJSON:
                // Cap consecutive malformed-JSON retries — some models reproduce the
                // same broken envelope every iteration (e.g. unescaped `"` inside HTML
                // string literals) and can't self-correct from a generic nudge. After
                // 3 attempts, escalate to the Supervisor with an actionable question
                // instead of looping until `delegate_to_team`'s 30-min timeout.
                //
                // Skipped during revision — supervisor is already driving via the
                // revision flow. Mirroring the drift-counter pattern, we ALSO reset
                // the counter on the revision branch: an accumulated counter from
                // before the revision shouldn't pre-trigger a post-revision escalation
                // on the very first new malformed-JSON turn.
                if isStepInRevision(stepID: stepID, taskID: task.id) {
                    executionStates[stepKey]?.consecutiveHarmonyParseFailureCount = 0
                } else {
                    let newCount = (executionStates[stepKey]?.consecutiveHarmonyParseFailureCount ?? 0) + 1
                    executionStates[stepKey]?.consecutiveHarmonyParseFailureCount = newCount
                    if newCount >= 3 {
                        // Reset so a post-supervisor restart starts clean.
                        executionStates[stepKey]?.consecutiveHarmonyParseFailureCount = 0
                        let question = """
                        Role \(roleForMessage.displayName) produced 3 consecutive malformed \
                        tool-call JSON envelopes (e.g. unescaped `"` inside string literals — \
                        a common defect when models emit HTML/JS content inside `create_artifact`). \
                        The model cannot self-correct from generic retry hints. Please advise: \
                        restart the role with a different model, simplify the brief to avoid \
                        embedded markup, or mark the step failed and re-plan.
                        """
                        let escalated = await setNeedsSupervisorInput(
                            stepID: stepID, taskID: task.id, question: question, sessionID: nil)
                        // Critical fallback: if persistence fails the engine would otherwise
                        // transition to "needs Supervisor input" with no question rendered —
                        // strictly worse than the loop the cap replaced.
                        guard escalated else {
                            return .toolFailure(message: "Parse-failure cap exceeded but Supervisor escalation failed to persist; aborting step. Question would have been: \(question)")
                        }
                        return .needsSupervisorInput(question: question)
                    }
                }
                retryMessage = "Your previous tool call had malformed JSON and could not be parsed (e.g. a missing closing brace `}`, an unescaped quote inside a string, or a trailing comma). Retry with valid JSON, e.g. `<|call|>{\"name\":\"TOOL_NAME\",\"arguments\":{…}}<|end|>` — note the two closing braces before `<|end|>`."
            case .noEnvelopeAttempt:
                // Inlined role turn (`<|start|>userhello<|end|>` and similar) —
                // the model didn't try to call a tool, just emitted a role
                // marker. Fall through to the generic "did not call any tools"
                // retry below; blaming "malformed JSON" would be misleading.
                retryMessage = nil
            }
            if let retryMessage {
                conversationMessages.append(
                    ChatMessage(role: .user, content: retryMessage)
                )
                await appendLLMMessage(stepID: stepID, taskID: task.id, role: .user, content: retryMessage)
                return .continueLoop
            }
            // .noEnvelopeAttempt falls through to the generic retry path.
        }

        // Check if content contains only model tokens (Issue #24, #32)
        let originalContent = result.assistantContent
        let cleanedContent = ModelTokenCleaner.clean(originalContent)

        if !originalContent.isEmpty && cleanedContent.isEmpty {
            // Content was entirely garbled tokens with no substantive text
            let retryMessage = "Your previous response contained only model-internal tokens (<|...|>) with no actual content. Emit a tool call or a completion message."
            conversationMessages.append(
                ChatMessage(role: .user, content: retryMessage)
            )
            await appendLLMMessage(stepID: stepID, taskID: task.id, role: .user, content: retryMessage)
            return .continueLoop
        }

        // Planning phase fallback: the model emitted prose instead of calling
        // update_scratchpad. Persist the prose as the implicit plan so the next
        // iteration's applyPlanningPhase sees a non-nil scratchpad and transitions
        // to implementation. The user nudge is required — without it, the next
        // stateful continuation would send `{"input":""}` and LM Studio rejects
        // with HTTP 400.
        if let systemMsg = conversationMessages.first(where: { $0.role == .system }),
           PlanningPhasePolicy.isPlanningSystemPrompt(systemMsg.content) {
            let plan = cleanedContent.isEmpty ? "(no plan provided)" : cleanedContent
            if let delegate, isExecutionLive(stepID: stepID, taskID: task.id) {
                _ = await delegate.mutateTask(taskID: task.id) { task in
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
            await appendLLMMessage(stepID: stepID, taskID: task.id, role: .user, content: nudge)
            return .continueLoop
        }

        // Producing role — retry if artifacts missing, complete if all present
        if let roleDef = roleDefinition {
            let expected = roleDef.dependencies.producesArtifacts.filter { $0 != ArtifactConstants.buildDiagnosticsName }
            if !expected.isEmpty {
                // Producing role — check artifact completeness
                if let artifactStop = checkArtifactCompleteness(stepID: stepID, taskID: task.id) {
                    return artifactStop
                }

                if isStepInRevision(stepID: stepID, taskID: task.id) {
                    let retryMessage = "Address the supervisor's feedback and submit updated artifacts via create_artifact."
                    conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                    await appendLLMMessage(stepID: stepID, taskID: task.id, role: .user, content: retryMessage)
                    return .continueLoop
                }

                // Missing artifacts — retry. Names must be quoted and verbatim;
                // extensions / prefixes / rewordings cause name-resolution misses.
                let quoted = expected.map { "\"\($0)\"" }.joined(separator: ", ")
                let retryMessage = "You haven't submitted all expected artifacts yet. Missing deliverables: \(quoted). Submit each via create_artifact using the quoted name verbatim — do not add file extensions, prefixes, or rewordings."
                conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                await appendLLMMessage(stepID: stepID, taskID: task.id, role: .user, content: retryMessage)
                return .continueLoop
            }
        }

        // Advisory role under autonomous supervisor — increment the non-productive-turn
        // counter and auto-finish if threshold is reached.
        if let stop = await attemptAdvisoryAutoFinish(
            stepID: stepID, taskID: task.id, roleDefinition: roleDefinition)
        {
            return stop
        }

        // No tool calls and no artifacts to produce — nudge to use tools.
        // Roles never self-terminate here; only artifact completion or Supervisor's "Finish Role" ends a step.
        let retryMessage = "You responded with text but did not call any tools. Use a tool to continue."
        conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
        await appendLLMMessage(stepID: stepID, taskID: task.id, role: .user, content: retryMessage)
        return .continueLoop
    }

    // MARK: - Failed Tool-Call Surfacing

    /// Surfaces a tool-call attempt the parser could not dispatch (`.malformedJSON` with an
    /// actual `<|call|>` block, or `.missingToolName`) as a visible, errored `StepToolCall`
    /// card. Without it the failed attempt is invisible in Team Activity — only a retry nudge
    /// appears in the conversation. UI/audit-only: the card lives in `step.toolCalls` (which
    /// the feed renders one card per entry) and never reaches the LLM wire conversation, which
    /// is built from `step.llmConversation`. A `<|channel|>`-only buffer or an inlined role
    /// turn (`.noEnvelopeAttempt`) is NOT a tool-call attempt → no card (avoids noise).
    private func recordFailedToolCallAttemptIfNeeded(
        stepID: String,
        taskID: Int,
        runID: Int,
        issue: ToolCallParsingHelpers.HarmonyCallIssue,
        envelope: String,
        runtime: ToolRuntime? = nil
    ) async {
        let name: String
        let code: String
        let message: String
        switch issue {
        case .missingToolName(let inferred):
            name = inferred ?? "unknown_tool"
            code = "MISSING_TOOL_NAME"
            message = "Tool-call JSON parsed but had no top-level `name` field; not dispatched."
        case .malformedJSON:
            // Only surface when an actual call block was attempted — a channel-only or
            // token-only buffer is a formatting hiccup, not a tool-call attempt.
            guard envelope.contains(CallMarkerStrategy.callMarker) else { return }
            name = "malformed_tool_call"
            code = "MALFORMED_TOOL_CALL"
            message = "Tool-call JSON could not be parsed; not dispatched."
        case .noEnvelopeAttempt:
            return
        }
        let rawEnvelope = Self.extractCallEnvelope(from: envelope) ?? envelope
        let resultJSON = JSONUtilities.jsonStringForToolArgs([
            "ok": false,
            "error": ["code": code, "message": message],
        ])
        let card = StepToolCall(
            name: name, argumentsJSON: rawEnvelope, resultJSON: resultJSON, isError: true)
        await appendToolCalls(stepID: stepID, taskID: taskID, toolCalls: [card])

        // Mirror into BOTH per-run logs (tool_calls.jsonl + network_log.json) with the
        // SAME name/envelope as the card, so both audits match the feed. Off the main
        // actor (the loggers do synchronous file I/O). Gated to the same cases that
        // produced a card — channel-only / `.noEnvelopeAttempt` returned above, so no
        // record here either.
        if let runtime {
            Task.detached { [runtime] in
                runtime.logNonExecutedCall(
                    taskID: taskID,
                    runID: runID,
                    roleID: stepID,
                    toolName: name,
                    argumentsJSON: rawEnvelope,
                    resultJSON: resultJSON,
                    errorMessage: message
                )
            }
        }
    }

    /// Extracts the `{…}` JSON body of the first `<|call|>` block for the failed card's
    /// arguments. Returns nil when no call envelope is present (caller stores the buffer
    /// verbatim — `StepToolCall.argumentsJSON` may hold partial/invalid JSON by contract).
    private static func extractCallEnvelope(from text: String) -> String? {
        guard let callRange = text.range(of: CallMarkerStrategy.callMarker) else { return nil }
        let tail = text[callRange.upperBound...]
        let start = ToolCallParsingHelpers.skipWhitespace(in: tail, from: tail.startIndex)
        guard start < tail.endIndex, tail[start] == "{" else { return nil }
        return ToolCallParsingHelpers.extractJSONBracedValue(in: tail, from: start)?.0
    }

    // MARK: - Stream Loop Break (top-level)

    /// Recovers a TOP-LEVEL step whose stream was broken mid-flight by an in-stream
    /// thinking loop (`performStreamingCall` already discarded the looping
    /// generation). `LoopRecoveryPolicy` decides:
    ///  - within the retry budget → stateless replay (drop the session; the next
    ///    iteration resends the full conversation = system + prior good turns +
    ///    human + tool-results, the looping turn excluded);
    ///  - budget exhausted → a mode-aware terminal: manual → escalate to Supervisor;
    ///    autonomous chat-mode → graceful finish (`.done` idle); autonomous non-chat
    ///    → fail the step (honest, no busy-spin).
    func handleStreamLoopBreak(
        stepID: String,
        signal: LoopSignal,
        task: NTMSTask,
        roleForMessage: Role,
        supervisorMode: SupervisorMode,
        session: inout LLMSession?
    ) async -> LLMStepStop {
        let stepKey = TaskStepKey(taskID: task.id, stepID: stepID)
        let n = (executionStates[stepKey]?.consecutiveThinkingLoopBreaks ?? 0) + 1
        executionStates[stepKey]?.consecutiveThinkingLoopBreaks = n
        let isChatMode = resolveTeam(task: task)?.isChatMode ?? false
        let decision = LoopRecoveryPolicy.decide(
            signal: signal,
            breakCount: n,
            maxRetries: LLMConstants.maxThinkingLoopBreaks,
            supervisorMode: supervisorMode,
            isChatMode: isChatMode,
            roleName: roleForMessage.displayName
        )
        switch decision {
        case .retryStateless:
            // `performStreamingCall` returned `session: nil`, but the caller only
            // updates `session` on a non-nil value — so we clear it explicitly here,
            // else the prior (now-stale) chain would be reused on the replay.
            session = nil
            return .continueLoop
        case .terminal(let terminal):
            executionStates[stepKey]?.consecutiveThinkingLoopBreaks = 0
            // Drop the session for every terminal, same reason as `.retryStateless`:
            // the looping turn was discarded and `performStreamingCall` returned
            // `session: nil`, but the caller only assigns on non-nil, so the stale
            // chain ID is still live here. Without this, the lifecycle's
            // `.needsSupervisorInput` arm re-persists `session?.responseID` onto the
            // step — silently resuming the stateful chain whose last attempt was the
            // discarded loop. (`finishGraceful`/`failStep` don't resume, but clearing
            // keeps the persisted `llmSessionID` honest.)
            session = nil
            switch terminal {
            case .escalateSupervisor(let question):
                let escalated = await setNeedsSupervisorInput(
                    stepID: stepID, taskID: task.id, question: question, sessionID: nil)
                guard escalated else {
                    return .toolFailure(message: "Thinking-loop cap exceeded but Supervisor escalation failed to persist; aborting step. Question would have been: \(question)")
                }
                return .needsSupervisorInput(question: question)
            case .finishGraceful:
                // Mirror the loop-top handoff pattern (same as the idle park): flag
                // finish so the step-lifecycle while-loop guard calls
                // `finishStepGraceful` at the top of the next iteration (preserving
                // the session/usage persist sequence). Calling it directly here
                // would bypass that.
                executionStates[stepKey]?.finishRequested = true
                return .continueLoop
            case .failStep(let message):
                return .toolFailure(message: message)
            }
        }
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
        taskID: Int,
        roleDefinition: TeamRoleDefinition?
    ) async -> LLMStepStop? {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        guard let roleDef = roleDefinition, roleDef.isAdvisory,
              !isStepInRevision(stepID: stepID, taskID: taskID),
              isAutonomousSupervisorMode(stepID: stepID, taskID: taskID),
              executionStates[stepKey] != nil
        else { return nil }
        executionStates[stepKey]!.consecutiveAdvisoryNoToolTurns += 1
        let count = executionStates[stepKey]!.consecutiveAdvisoryNoToolTurns
        guard count >= 3 else { return nil }

        // Hard guard: without a delegate, the bypass path can't land at all —
        // falling through and announcing completion would write a fake
        // assistant message and return `.completed` despite step still being
        // `.running`. Keep counter incremented (so the next iteration notices
        // the cap is past) and bail out by returning nil.
        guard let delegate else {
            return nil
        }

        // Chat-mode-only bypass (I6): direct status writes are safe only when
        // the engine's chat-mode arm consumes them. Non-chat teams must route
        // through `handleRoleCompleted` so acceptance/checkpointing plumbing
        // fires. If we can't determine chat-mode (no team, no task), prefer
        // safety: don't bypass.
        let isChatMode = (delegate.loadedTask(taskID).flatMap(resolveTeam(task:))?.isChatMode) ?? false
        guard isChatMode else { return nil }

        // CLAUDE.md §7 capture-flag discipline lives in the shared helper.
        guard await markChatModeAdvisoryStepDone(stepID: stepID, taskID: taskID) else {
            // Don't reset the counter — leave it at its current value so a
            // retry on the next iteration will re-attempt rather than silently
            // burying the threshold breach. Don't post a "finished" message
            // either — that would lie about state that didn't change.
            return nil
        }

        executionStates[stepKey]!.consecutiveAdvisoryNoToolTurns = 0
        let finishNote = "Advisory role auto-finished after \(count) consecutive turns without productive tool calls."
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .assistant, content: finishNote)
        return .completed
    }

    /// Writes `step.done` + `roleStatuses[roleID] = .done` directly, the chat-mode
    /// advisory completion that lets the engine's chat-mode all-terminal arm reach
    /// `.done` (bypassing `handleRoleCompleted`'s `.finalOnly` → `.needsAcceptance`
    /// routing, which deadlocks in chat mode). Shared by `attemptAdvisoryAutoFinish`
    /// (the no-tool backstop) and `finishStepGraceful` (loop-recovery
    /// `.finishGraceful` terminal + `requestFinish`).
    /// Returns `true` only when the mutation actually landed — CLAUDE.md §7: a
    /// `mutateTask == true` return can hide a closure that short-circuited.
    func markChatModeAdvisoryStepDone(stepID: String, taskID: Int) async -> Bool {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return false }
        var didApply = false
        let mutated = await delegate.mutateTask(taskID: taskID) { task in
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
        return mutated && didApply
    }

    /// Completes a step whose `finishRequested` flag was set (the loop-recovery
    /// `.finishGraceful` terminal, or `requestFinish`). Chat-mode advisory roles
    /// finish directly as `.done` via `markChatModeAdvisoryStepDone` + the proven
    /// `completeStepSuccess` terminal sequence (mirrors `attemptAdvisoryAutoFinish`);
    /// any other team routes through `completeStepNeedsAcceptance`, preserving the
    /// acceptance flow the non-chat advisory "Finish Role" path expects.
    func finishStepGraceful(stepID: String, taskID: Int) async {
        let isChatMode: Bool = {
            guard let delegate,
                  let task = delegate.loadedTask(taskID) else { return false }
            return resolveTeam(task: task)?.isChatMode ?? false
        }()
        if isChatMode {
            _ = await markChatModeAdvisoryStepDone(stepID: stepID, taskID: taskID)
            await completeStepSuccess(stepID: stepID, taskID: taskID)
        } else {
            await completeStepNeedsAcceptance(stepID: stepID, taskID: taskID)
        }
    }

    /// Gates the advisory auto-finish path: with a human Supervisor in the loop
    /// (`.manual`), the role can wait indefinitely for a "Finish Role" click; without
    /// one (`.autonomous`), it would loop forever once it stops calling tools.
    private func isAutonomousSupervisorMode(stepID: String, taskID: Int) -> Bool {
        guard let delegate,
              let task = delegate.loadedTask(taskID),
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
        taskID: Int,
        roleForMessage: Role,
        tools: [ToolSchema],
        step: StepExecution,
        tracker: ToolCallTracker,
        conversationMessages: inout [ChatMessage],
        roleDefinition: TeamRoleDefinition?
    ) async -> (tools: [ToolSchema], resetSession: Bool) {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        let usePlanningPhase = roleDefinition?.usePlanningPhase ?? true
        // A step under revision (`revisionComment` set) is never "first iteration" work,
        // even when it has no scratchpad: entering planning here would swap the system
        // prompt to PLANNING PHASE, filter tools to update_scratchpad, and
        // saveLLMConversation below would wipe llmConversation — including the
        // just-appended revision-feedback message.
        let isFirstIteration = PlanningPhasePolicy.isFirstIteration(
            scratchpadIsNil: step.scratchpad == nil,
            hasNoRecentCalls: tracker.recentCalls(limit: 1).isEmpty,
            revisionCommentIsNil: step.revisionComment == nil
        )
        let hasPriorConversation = !step.llmConversation.isEmpty
        let hasScratchpadTool = PlanningPhasePolicy.hasScratchpadTool(in: tools)

        if PlanningPhasePolicy.shouldEnterPlanning(
            isFirstIteration: isFirstIteration,
            usePlanningPhase: usePlanningPhase,
            hasScratchpadTool: hasScratchpadTool
        ) {
            // Save original system prompt before replacing
            if let systemMsg = conversationMessages.first(where: { $0.role == .system }) {
                executionStates[stepKey]?.originalSystemPrompt = systemMsg.content
            }

            let basePlanningPrompt = PlanningPhasePolicy.basePlanningPrompt(
                roleName: roleForMessage.displayName)
            let planningSystemPrompt = TemplateResolver.appendingSeparator(
                delegate?.globalLLMContext ?? "",
                to: basePlanningPrompt
            )

            if let systemIdx = conversationMessages.firstIndex(where: { $0.role == .system }) {
                conversationMessages[systemIdx] = ChatMessage(
                    role: .system,
                    content: planningSystemPrompt
                )
            }
            await saveLLMConversation(stepID: stepID, taskID: taskID, messages: conversationMessages)
            return (PlanningPhasePolicy.planningTools(from: tools), resetSession: false)
        } else {
            // Restore original system prompt after planning phase
            var didRestorePrompt = false
            if let savedPrompt = executionStates[stepKey]?.originalSystemPrompt,
               let systemIdx = conversationMessages.firstIndex(where: { $0.role == .system }),
               PlanningPhasePolicy.isPlanningSystemPrompt(conversationMessages[systemIdx].content) {
                conversationMessages[systemIdx] = ChatMessage(
                    role: .system,
                    content: savedPrompt
                )
                executionStates[stepKey]?.originalSystemPrompt = nil
                didRestorePrompt = true
                // Update only the system message — saveLLMConversation would replace all messages
                // and lose thinking content from the planning phase assistant response
                await updatePersistedSystemMessage(stepID: stepID, taskID: taskID, content: savedPrompt)
            } else if isFirstIteration && !hasPriorConversation {
                await saveLLMConversation(stepID: stepID, taskID: taskID, messages: conversationMessages)
            }
            // Reset session when system prompt was swapped so the next call sends the full
            // original prompt in a fresh chain (NativeLMStudioClient omits system_prompt on
            // stateful continuations, so stale planning prompt in the chain would be wrong).
            return (tools, resetSession: didRestorePrompt)
        }
    }
}
