import Foundation

/// Extension for step flow control: no-tool-call handling and escalation caps.
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
    ///
    /// - Parameter allowedToolNames: the set `executeToolCalls` authorizes against this
    ///   iteration (`PlanningPhasePolicy.Authorization.allowed`). Every nudge below that
    ///   names a tool filters through it — see the builders in `+ToolLoopState`.
    func handleNoToolCalls(
        stepID: String,
        result: StreamingResult,
        roleForMessage: Role,
        task: NTMSTask,
        runIndex: Int,
        stepIndex _: Int,
        tracker _: ToolCallTracker,
        roleDefinition: TeamRoleDefinition?,
        allowedToolNames: Set<String>,
        runtime: ToolRuntime? = nil,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop {
        // The one bound that doesn't care HOW the model failed. Every cap below it is
        // shape-specific (drift = 2, Harmony parse failure = 3), so a model that varies
        // its failure shape from turn to turn slips past all of them — and
        // `maxToolIterations` is unlimited, so nothing downstream is watching either.
        //
        // Incremented FIRST, before any branch can return, and the terminal is taken here
        // rather than per-branch so no future branch can accidentally bypass it. That is
        // not hypothetical: the `.repetitiveNonTool` arm below used to return above the
        // counter, which froze it and made that path unbounded.
        //
        // Safe to pre-empt the branches below, because each of them either nudges and
        // retries or escalates on a cap far under this one. In particular a producing
        // role's artifact-completeness check cannot be starved: submitting an artifact is
        // a productive turn, which zeroes this counter, so a completable role never
        // reaches the cap.
        if let stop = await noteNonProductiveTurn(
            stepID: stepID, taskID: task.id, roleDefinition: roleDefinition)
        {
            return stop
        }

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
                    stepID: stepID, taskID: task.id, question: question)
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
            reasoning but no tool call — reasoning alone cannot read files, write files, or \
            submit artifacts. Take one concrete action now: call the tool that advances your \
            next step.
            """
            conversationMessages.append(ChatMessage(role: .user, content: nudge))
            await appendLLMMessage(
                stepID: stepID, taskID: task.id, role: .user, content: nudge,
                sourceContext: .retryNudge)
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
                    stepID: stepID, taskID: task.id, question: question)
                guard escalated else {
                    return .toolFailure(message: "Refusal-loop cap exceeded but Supervisor escalation failed to persist; aborting step.")
                }
                return .needsSupervisorInput(question: question)

            case .repetitiveNonTool(let count):
                let retryMessage = Self.repetitiveNonToolNudge(
                    count: count, allowedToolNames: allowedToolNames)
                conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                await appendLLMMessage(
                    stepID: stepID, taskID: task.id, role: .user, content: retryMessage,
                    sourceContext: .retryNudge)
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
                // Examples filtered to the role's schema — an illustration naming a
                // tool it doesn't have teaches a vocabulary the runtime rejects.
                let examples = Self.toolNameExamples(allowedToolNames: allowedToolNames)
                    .map { " (e.g. \($0))" } ?? ""
                retryMessage = """
                Your tool call JSON parsed, but it is missing the top-level `name` field. \
                The top-level `name` identifies the tool to call\(examples); the `name` \
                inside `arguments` is a tool *parameter*, not the tool id. Retry, keeping \
                your original arguments object:
                `<|call|>{"name":"\(example)","arguments":{"param":"value"}}<|end|>`
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
                        // The example defect is safe to name now that `.noCallEnvelope` is
                        // its own case: this arm fires only when a `<|call|>` block really
                        // was opened and its payload really is broken JSON. Before the
                        // split it also fired for envelopes containing no JSON at all,
                        // misdiagnosing the fault to the HUMAN reading this question.
                        let question = """
                        Role \(roleForMessage.displayName) produced 3 consecutive malformed \
                        tool-call JSON envelopes (often an unescaped `"` inside a string literal — \
                        a common defect when models emit HTML/JS content inside `create_artifact`). \
                        The model cannot self-correct from generic retry hints. Please advise: \
                        restart the role with a different model, simplify the brief to avoid \
                        embedded markup, or mark the step failed and re-plan.
                        """
                        let escalated = await setNeedsSupervisorInput(
                            stepID: stepID, taskID: task.id, question: question)
                        // Critical fallback: if persistence fails the engine would otherwise
                        // transition to "needs Supervisor input" with no question rendered —
                        // strictly worse than the loop the cap replaced.
                        guard escalated else {
                            return .toolFailure(message: "Parse-failure cap exceeded but Supervisor escalation failed to persist; aborting step. Question would have been: \(question)")
                        }
                        return .needsSupervisorInput(question: question)
                    }
                }
                // Attach the ACTUAL parser error when one is derivable — a model
                // that sees "unescaped control character around character 217"
                // can fix THAT; the generic brace/quote/comma guesses stay as
                // the fallback for envelopes with no single nameable defect.
                let defect = ToolCallParsingHelpers.malformedJSONDiagnostic(in: envelopeSource)
                    .map { "parser error: \($0)" }
                    ?? "e.g. a missing closing brace `}`, an unescaped quote inside a string, or a trailing comma"
                // Name a tool the role actually holds, exactly as the `.missingToolName`
                // and `.noCallEnvelope` arms already do. This arm was the only one still
                // shipping the literal `TOOL_NAME`, so the model was asked to fix a call
                // without being shown a single valid id — and, before the anchor now
                // carries the raw buffer, without being shown its own attempt either.
                let example = Self.toolNameExample(allowedToolNames: allowedToolNames)
                    ?? "TOOL_NAME"
                retryMessage = "Your previous tool call had malformed JSON and could not be parsed (\(defect)). Your attempt is quoted verbatim in your previous turn — compare it against this shape: `<|call|>{\"name\":\"\(example)\",\"arguments\":{\"param\":\"value\"}}<|end|>` — note the two closing braces before `<|end|>`."
            case .noCallEnvelope:
                // Framing without a call: a `<|channel|>` / `<|start|>` envelope whose
                // recipient is missing or reserved, or whose body is prose. Deliberately
                // does NOT touch `consecutiveHarmonyParseFailureCount` — nothing failed to
                // parse — and the text names the shape the model ACTUALLY emits. gpt-oss
                // reaches for the channel form and may never emit `<|call|>` in a whole
                // pass, so a nudge teaching only the canonical form describes a syntax the
                // model isn't using while saying nothing about the one it is.
                let example = Self.toolNameExample(allowedToolNames: allowedToolNames)
                    ?? "TOOL_NAME"
                retryMessage = """
                Your previous response opened a Harmony channel but never made a tool call — \
                there was no recipient and no JSON body to dispatch. Name the tool and give it \
                arguments, either as \
                `<|channel|>commentary to=\(example)<|message|>{"param":"value"}` or as \
                `<|call|>{"name":"\(example)","arguments":{"param":"value"}}<|end|>`.
                """
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
                await appendLLMMessage(
                    stepID: stepID, taskID: task.id, role: .user, content: retryMessage,
                    sourceContext: .retryNudge)
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
            await appendLLMMessage(
                stepID: stepID, taskID: task.id, role: .user, content: retryMessage,
                sourceContext: .retryNudge)
            return .continueLoop
        }

        // Planning-phase fallback: the model wrote its plan as prose instead of
        // calling update_scratchpad — the single most common way this phase
        // fails to end. Persist the prose as the plan so the next iteration's
        // `applyPlanningPhase` sees a non-nil scratchpad and crosses the
        // boundary. Detected from the WIRE (the brief turn) rather than from the
        // system prompt, which the phase no longer touches.
        //
        // MUST stay above the producing-role branch below: that one steers
        // toward `create_artifact`, which the planning phase withholds, so the
        // model would be told to call a tool that is guaranteed to be rejected.
        // `isMidPlanning`, not `wireCarriesBrief`: after `.closeWithoutRebuild` the brief is still
        // on the wire but the phase is over. Writing a "plan" there would both promise a
        // boundary that will never fire and — before the close became terminal — trigger one
        // that sliced away the revision turn the close was protecting.
        if PlanningPhasePolicy.isMidPlanning(conversationMessages) {
            // A failed tool call is not a plan. The only content test used to be
            // `isEmpty`, so a call the parser dropped was recorded as the step's durable
            // plan — and `implementationWire` keeps exactly that one turn across the
            // boundary, making it the sole memory of the exploration phase. Nudge with
            // the defect instead and let the model retry the call it meant to make;
            // leaving `scratchpad` nil keeps the phase open for a real plan.
            if BareToolCallSalvage.looksLikeToolCallAttempt(cleanedContent) {
                let nudge = """
                    That looked like a tool call, but it did not parse as one, so nothing ran \
                    and nothing was recorded. Emit it as a single envelope on its own line:
                    `<|call|>{"name":"TOOL_NAME","arguments":{"param":"value"}}<|end|>`
                    Nothing before the `<|call|>` and nothing after the `<|end|>`.
                    """
                conversationMessages.append(ChatMessage(role: .user, content: nudge))
                await appendLLMMessage(
                    stepID: stepID, taskID: task.id, role: .user, content: nudge,
                    sourceContext: .retryNudge)
                return .continueLoop
            }
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
            let nudge = "Plan recorded from your text response. The implementation phase starts on your next turn with your full toolset."
            conversationMessages.append(ChatMessage(role: .user, content: nudge))
            await appendLLMMessage(
                stepID: stepID, taskID: task.id, role: .user, content: nudge,
                sourceContext: .retryNudge)
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
                    await appendLLMMessage(
                        stepID: stepID, taskID: task.id, role: .user, content: retryMessage,
                        sourceContext: .retryNudge)
                    return .continueLoop
                }

                // Missing artifacts — retry. Names must be quoted and verbatim;
                // extensions / prefixes / rewordings cause name-resolution misses.
                let quoted = expected.map { "\"\($0)\"" }.joined(separator: ", ")
                let retryMessage = "You haven't submitted all expected artifacts yet. Missing deliverables: \(quoted). Submit each via create_artifact, copying the quoted name exactly as shown."
                conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                await appendLLMMessage(
                    stepID: stepID, taskID: task.id, role: .user, content: retryMessage,
                    sourceContext: .retryNudge)
                return .continueLoop
            }
        }

        // No tool calls and no artifacts to produce — reached by advisory/chat roles
        // (producing roles returned above) and by a role-definition miss. The pre-fix
        // generic "Use a tool to continue" named no tool and no goal — the canonical
        // loop-inducing nudge for small models — so the text names the role's actual
        // completion channel, resolved from its schema. Roles never self-terminate
        // here; only artifact completion, the no-tool backstop, or the Supervisor's
        // "Finish Role" ends a step.
        let retryMessage = Self.noToolCallNudge(allowedToolNames: allowedToolNames)
        conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
        await appendLLMMessage(
            stepID: stepID, taskID: task.id, role: .user, content: retryMessage,
            sourceContext: .retryNudge)
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
        case .noCallEnvelope, .noEnvelopeAttempt:
            // No call block was opened, so there is no attempt to surface. (Before the
            // split, `.noCallEnvelope` reached here as `.malformedJSON` and was filtered
            // by the guard above — same outcome, now stated rather than incidental.)
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
    ///  - within the retry budget → append a correction turn and re-enter the loop.
    ///    The correction is load-bearing: the discarded turn never entered the
    ///    conversation and `performStreamingCall` takes it by value, so WITHOUT a
    ///    perturbation the next request is byte-identical to the one that just
    ///    looped and re-enters the same loop (observed in production: two 40-second
    ///    breaks 46ms apart, then a silently-ended Autovisor pass);
    ///  - budget exhausted → a mode-aware terminal: manual → escalate to Supervisor;
    ///    autonomous chat-mode → park with the diagnostic when something will wake
    ///    the role again, else graceful finish; autonomous non-chat → fail the step
    ///    (honest, no busy-spin).
    func handleStreamLoopBreak(
        stepID: String,
        signal: LoopSignal,
        task: NTMSTask,
        roleForMessage: Role,
        supervisorMode: SupervisorMode,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop {
        let stepKey = TaskStepKey(taskID: task.id, stepID: stepID)
        let n = (executionStates[stepKey]?.consecutiveThinkingLoopBreaks ?? 0) + 1
        executionStates[stepKey]?.consecutiveThinkingLoopBreaks = n
        let team = resolveTeam(task: task)
        let decision = LoopRecoveryPolicy.decide(
            signal: signal,
            breakCount: n,
            maxRetries: LLMConstants.maxThinkingLoopBreaks,
            supervisorMode: supervisorMode,
            isChatMode: team?.isChatMode ?? false,
            // Only the Autovisor manager has a waker (its recurrence + the event
            // wakes). Resolved here rather than inside the pure policy so no team
            // identity leaks into it.
            canParkForSupervisor: team?.templateID == AutovisorConstants.teamTemplateID,
            roleName: roleForMessage.displayName
        )
        switch decision {
        case .retryWithNudge(let nudge):
            // Appended, never spliced or rewritten in place: removing or rewriting an
            // earlier nudge would change an EARLY byte, invalidating the server's KV
            // prefix from that point — a full re-prefill to save ~115 tokens, in the one
            // subsystem built to keep that prefix intact. An append is the only
            // prefix-preserving mutation.
            //
            // `maxThinkingLoopBreaks` bounds nudges within ONE episode only:
            // `consecutiveThinkingLoopBreaks` resets on every clean stream
            // (`+ToolIteration`), so `break → nudge → clean stream → break` is reachable and
            // a step can carry several. That is why `nudgePrefix` is anchored to the note's
            // own position instead of to "your previous turn" — each copy has to stay true
            // when it is read again dozens of turns later (both providers are stateless;
            // nothing prunes the conversation).
            conversationMessages.append(ChatMessage(role: .user, content: nudge))
            await appendLLMMessage(
                stepID: stepID, taskID: task.id, role: .user, content: nudge,
                sourceContext: .loopCorrection)
            return .continueLoop
        case .terminal(let terminal):
            executionStates[stepKey]?.consecutiveThinkingLoopBreaks = 0
            switch terminal {
            case .escalateSupervisor(let question):
                let escalated = await setNeedsSupervisorInput(
                    stepID: stepID, taskID: task.id, question: question)
                guard escalated else {
                    return .toolFailure(message: "Thinking-loop cap exceeded but Supervisor escalation failed to persist; aborting step. Question would have been: \(question)")
                }
                return .needsSupervisorInput(question: question)
            case .parkForSupervisor(let question):
                // Same loop-top handoff as `.finishGraceful` and the idle park, and
                // for the same reason the idle park uses it: the lifecycle guard
                // persists the wire transcript BEFORE publishing the park. Calling
                // `setNeedsSupervisorInput` here instead would publish "parked,
                // answer me" while the transcript is still empty, and the queued-
                // message backstop it fires synchronously could resume the step
                // against nothing.
                executionStates[stepKey]?.parkQuestionOverride = question
                executionStates[stepKey]?.parkForEventsRequested = true
                return .continueLoop
            case .finishGraceful:
                // Mirror the loop-top handoff pattern (same as the idle park): flag
                // finish so the step-lifecycle while-loop guard calls
                // `finishStepGraceful` at the top of the next iteration (preserving
                // the transcript/usage persist sequence). Calling it directly here
                // would bypass that.
                executionStates[stepKey]?.finishRequested = true
                return .continueLoop
            case .failStep(let message):
                return .toolFailure(message: message)
            }
        }
    }

    /// Increments `consecutiveNonProductiveTurns` and terminates the step once the cap is
    /// reached. Called after ANY non-productive turn — no tool calls at all, only
    /// `ask_supervisor` (auto-answered, so not progress), or a batch whose every result
    /// came back an error. Returns a stop when the cap is reached AND the terminal
    /// actually landed; `nil` otherwise, leaving room for
    /// `LLMConstants.maxNonProductiveTurns - 1` nudges to recover first.
    ///
    /// **Counted for EVERY role, not just an advisory one under autonomous mode.** The old
    /// guards (`isAdvisory && isAutonomousSupervisorMode`) plus a chat-mode-only terminal
    /// left five shapes with no bound at all: a repetitive-text turn (which returned above
    /// the counter entirely), a producing role, manual supervisor mode, an unresolved role
    /// definition, and an advisory role in a non-chat team. `maxToolIterations` is `0`, so
    /// each of those was an infinite loop, not a slow one.
    ///
    /// Revision is the one deliberate exemption — the Supervisor is already driving, so
    /// the runaway this bounds cannot happen unobserved.
    ///
    /// The TERMINAL is role-shaped, and that distinction is the whole point of this
    /// function's shape:
    ///  - **Autovisor manager** → park for events (`.continueLoop` + the loop-top
    ///    flag). Its designed terminal is the `wait_for_events` idle park, which
    ///    preserves the conversation for a human continuation, reads as idle in the
    ///    sidebar (`autovisorIsIdleParked`), and keeps the recurrence/event supersede
    ///    protections live. Finishing it `.done` instead abandons the transcript on
    ///    the next human message, drops those protections, and hands the queue to the
    ///    `.done`-chat give-up path.
    ///  - **every other chat advisory role** (autonomous mode) → finish `.done` (below).
    ///  - **everything else** — a producing role, manual supervisor mode, a non-chat
    ///    advisory role, an unresolved role definition → escalate to the Supervisor.
    ///    Never force `.done` there: a producing role that never submitted its artifacts
    ///    would strand the pipeline with the role marked complete and no deliverable, and
    ///    in manual mode there is a human who can simply answer. `TeamEngine.runLoop`'s
    ///    transition to `.needsSupervisorInput` is mode-independent, so the Autovisor or
    ///    the human picks it up either way.
    ///
    /// Important: the finish path writes `roleStatuses[roleID] = .done` directly, bypassing
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
    /// The park question for a manager that hit the non-productive-turn cap.
    ///
    /// DUAL-MASTER: it renders as the pending question in the activity-feed composer and
    /// QuickCapture answer mode (human), AND it reaches the model — `PromptBuilder` emits an
    /// unanswered `step.supervisorQuestion` as a `.user` turn, and `+PipelineContext` repeats
    /// it for every downstream role. So it names the observable fact and the capability to
    /// change, never the Settings pane: truthful for the human, actionable-shaped for the
    /// model. Deliberately NOT `AutovisorConstants.idleParkQuestion` — see the call site.
    nonisolated static func noToolParkQuestion(turns: Int) -> String {
        """
        The Autovisor produced \(turns) consecutive turns without calling any tool, so this review pass \
        could not end normally (it never reached wait_for_events). Send a message to steer it, or switch \
        the model it runs on if this keeps happening.
        """
    }

    /// The Supervisor question for a role that hit the cap with no role-shaped terminal of
    /// its own. Human facing: it names the observable fact and the three things the human
    /// (or the Autovisor answering on their behalf) can actually do.
    nonisolated static func nonProductiveEscalationQuestion(roleName: String, turns: Int) -> String {
        """
        Role \(roleName) produced \(turns) consecutive turns without completing a single tool \
        call, so this step cannot advance on its own. Please advise how to proceed (clarify \
        the task, give an explicit next step, or mark the step failed).
        """
    }

    func noteNonProductiveTurn(
        stepID: String,
        taskID: Int,
        roleDefinition: TeamRoleDefinition?
    ) async -> LLMStepStop? {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        guard !isStepInRevision(stepID: stepID, taskID: taskID),
              executionStates[stepKey] != nil
        else { return nil }
        executionStates[stepKey]!.consecutiveNonProductiveTurns += 1
        let count = executionStates[stepKey]!.consecutiveNonProductiveTurns
        guard count >= LLMConstants.maxNonProductiveTurns else { return nil }

        // Hard guard: without a delegate, the bypass path can't land at all —
        // falling through and announcing completion would write a fake
        // assistant message and return `.completed` despite step still being
        // `.running`. Keep counter incremented (so the next iteration notices
        // the cap is past) and bail out by returning nil.
        guard let delegate else {
            return nil
        }

        // The Autovisor manager parks instead of finishing. Same loop-top handoff
        // the idle park and the thinking-loop terminal use, for the same reason:
        // the lifecycle guard persists the wire transcript BEFORE publishing the
        // park, and `setNeedsSupervisorInput` synchronously fires the queued-message
        // backstop — publishing from here could resume the step against an empty
        // transcript. Costs no LLM round-trip: the guard runs above
        // `safetyIterations += 1`, so `.continueLoop` parks without another call.
        //
        // The question is the DIAGNOSTIC, never `idleParkQuestion`: that constant is
        // matched verbatim by `taskHasIdleParkStep` and the sidebar gates the
        // manager's attention badge on `!isIdleParked`, so reusing it would render a
        // manager that stopped driving its own loop pixel-identical to a healthy
        // `wait_for_events` idle — hiding exactly what the human needs to see.
        if isAutovisorStep(stepID: stepID, taskID: taskID) {
            executionStates[stepKey]!.consecutiveNonProductiveTurns = 0
            executionStates[stepKey]!.parkQuestionOverride = Self.noToolParkQuestion(turns: count)
            executionStates[stepKey]!.parkForEventsRequested = true
            return .continueLoop
        }

        // Chat-mode-only bypass (I6): direct status writes are safe only when
        // the engine's chat-mode arm consumes them. Non-chat teams must route
        // through `handleRoleCompleted` so acceptance/checkpointing plumbing
        // fires. If we can't determine chat-mode (no team, no task), prefer
        // safety: don't bypass — escalate below instead of finishing.
        let isChatMode = (delegate.loadedTask(taskID).flatMap(resolveTeam(task:))?.isChatMode) ?? false
        if let roleDef = roleDefinition, roleDef.isAdvisory, isChatMode,
           isAutonomousSupervisorMode(taskID: taskID) {
            // CLAUDE.md §7 capture-flag discipline lives in the shared helper.
            guard await markChatModeAdvisoryStepDone(stepID: stepID, taskID: taskID) else {
                // Don't reset the counter — leave it at its current value so a
                // retry on the next iteration will re-attempt rather than silently
                // burying the threshold breach. Don't post a "finished" message
                // either — that would lie about state that didn't change.
                return nil
            }

            executionStates[stepKey]!.consecutiveNonProductiveTurns = 0
            let finishNote = "Advisory role auto-finished after \(count) consecutive turns without productive tool calls."
            await appendLLMMessage(stepID: stepID, taskID: taskID, role: .assistant, content: finishNote)
            return .completed
        }

        // Everything else escalates to the Supervisor rather than looping forever: a
        // producing role (whose natural terminal, artifact completeness, a non-productive
        // loop never reaches), manual supervisor mode (there IS a human to ask), an
        // advisory role in a non-chat team, or a role definition that didn't resolve.
        // Same failed-persist discipline as the drift and refusal caps above — a silent
        // transition to "needs Supervisor input" with no question rendered is strictly
        // worse than the loop it replaced.
        let roleName = roleDefinition?.name ?? stepID
        let question = Self.nonProductiveEscalationQuestion(roleName: roleName, turns: count)
        let escalated = await setNeedsSupervisorInput(
            stepID: stepID, taskID: taskID, question: question)
        guard escalated else {
            return .toolFailure(message: "Non-productive-turn cap exceeded but Supervisor escalation failed to persist; aborting step. Question would have been: \(question)")
        }
        // Reset so a post-supervisor continuation starts clean (mirrors the drift cap).
        executionStates[stepKey]?.consecutiveNonProductiveTurns = 0
        return .needsSupervisorInput(question: question)
    }

    /// Writes `step.done` + `roleStatuses[roleID] = .done` directly, the chat-mode
    /// advisory completion that lets the engine's chat-mode all-terminal arm reach
    /// `.done` (bypassing `handleRoleCompleted`'s `.finalOnly` → `.needsAcceptance`
    /// routing, which deadlocks in chat mode). Shared by `noteNonProductiveTurn`
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
    /// `completeStepSuccess` terminal sequence (mirrors `noteNonProductiveTurn`);
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

    /// Gates `noteNonProductiveTurn` — BOTH its terminals, the manager's park and the
    /// chat-advisory finish: with a human Supervisor in the loop
    /// (`.manual`), the role can wait indefinitely for a "Finish Role" click; without
    /// one (`.autonomous`), it would loop forever once it stops calling tools.
    private func isAutonomousSupervisorMode(taskID: Int) -> Bool {
        guard let delegate,
              let task = delegate.loadedTask(taskID),
              let team = resolveTeam(task: task)
        else { return false }
        return team.settings.supervisorMode == .autonomous
    }
}
