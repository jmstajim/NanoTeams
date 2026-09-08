import Foundation

/// Extension for step flow control: no-tool-call handling and escalation caps.
extension LLMExecutionService {

    /// The no-tool-call nudge for a producing role with deliverables outstanding. Dated to
    /// the note's own position: the sentence stays true after "B" is submitted, because it
    /// reports the state AS OF the turn before the note (R3.8.4 — "You haven't submitted
    /// all expected artifacts yet" was a claim about the reader's now, re-read on every
    /// later request). Names are quoted verbatim: extensions, prefixes and rewordings cause
    /// name-resolution misses. Registered in `RuntimePromptRegistry`.
    nonisolated static func missingArtifactsNudge(missing: [String]) -> String {
        let quoted = missing.map { "\"\($0)\"" }.joined(separator: ", ")
        return "The turn immediately before this note called no tool. Missing deliverables as of that turn: \(quoted). Submit each via create_artifact, copying the quoted name exactly as shown."
    }


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
    ///
    /// Contract: ten nudge paths append one correction and return `.continueLoop`. Terminal
    /// values leave here only by DELEGATION, never as a self-declared completion —
    /// `.completed` from `checkArtifactCompleteness` (every deliverable submitted, the
    /// `artifactStop` below) or from `noteNonProductiveTurn`'s chat-mode advisory backstop at
    /// `maxNonProductiveTurns`; `.needsSupervisorInput` from the five cap escalations
    /// (reasoning-channel ×2, thinking drift ×2, refusal loop, malformed JSON ×3, and the
    /// non-productive cap for every other role); `.toolFailure` when an escalation cannot
    /// persist its question. Until 2026-09-06 this comment said "always returns
    /// `.continueLoop`", and the playbook's R3.1.4 / REC.6 Checks repeated it.
    /// Producing roles get artifact-missing reminders; other roles get tool-use nudges.
    ///
    /// - Parameter allowedToolNames: the set `executeToolCalls` authorizes against this
    ///   iteration (`PlanningPhasePolicy.Authorization.allowed`). Every nudge below that
    ///   names a tool filters through it — see the builders in `+ToolLoopState`.
    /// - Parameter wireIsMidPlanning: the phase verdict `applyPlanningPhase` derived this
    ///   iteration (`Authorization.wireIsMidPlanning`). Replaces a per-call
    ///   `PlanningPhasePolicy.isMidPlanning` rescan of the whole wire — two O(conversation)
    ///   substring passes per no-tool turn; no default, because a default would assert a fact
    ///   about the caller's wire.
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
        wireIsMidPlanning: Bool,
        runtime: ToolRuntime?,
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

        let stepKey = TaskStepKey(taskID: task.id, stepID: stepID)

        // The model wrote a dispatchable envelope into the REASONING channel and nothing
        // into the one that dispatches. The turn is already lost — no route reads reasoning
        // for calls, and none is being added (see `performStreamingCall`) — but the CAUSE is
        // known exactly here, so say it instead of guessing.
        //
        // Above the drift branch deliberately. Drift is a heuristic over LENGTH and fires at
        // 10,000 chars; measured across 291 network logs of the MeditationApp folder, only 2
        // of 30 reasoning-envelope turns were that long, so 28 of them reached the generic
        // no-tool-call nudge at the very bottom of this function — the one branch whose text
        // can say nothing about channels. Both facts can hold at once (`runs/273` #43: 11,789
        // chars AND two envelopes); the specific diagnosis wins the branch, the generic one
        // keeps its own streak.
        //
        // Names are filtered through `allowedToolNames` for the same reason the Harmony arms
        // filter their examples: a model that rehearsed a tool it does not hold must not have
        // that name confirmed back to it. An empty intersection drops the list, not the nudge.
        // Gated on `!sawHarmonyMarker`, which is what makes this branch's claim TRUE rather
        // than merely first. A content-channel marker means the model did aim at the channel
        // that dispatches and its envelope failed to parse there; saying "you wrote it in your
        // reasoning" would then name the wrong defect, and the Harmony classify-and-nudge
        // branch below already names the right one. Deliberately a gate rather than a
        // reordering: the branch must still sit above drift, and a gate says why in one line.
        let reasoningCallNames = result.sawHarmonyMarker
            ? []
            : ConversationRepairService.reasoningChannelToolCallNames(in: result.thinkingContent)
        if !reasoningCallNames.isEmpty {
            let inRevision = isStepInRevision(stepID: stepID, taskID: task.id)
            if inRevision {
                // Mirrors the drift branch: the Supervisor is already driving, so no
                // escalation recursion — and the pre-revision streak is cleared so the first
                // post-revision turn of this shape starts from one, not from the cap.
                executionStates[stepKey]?.consecutiveReasoningEnvelopeCount = 0
            } else {
                let newCount = (executionStates[stepKey]?.consecutiveReasoningEnvelopeCount ?? 0) + 1
                executionStates[stepKey]?.consecutiveReasoningEnvelopeCount = newCount
                if newCount >= 2 {
                    // Reset so a post-supervisor restart starts clean.
                    executionStates[stepKey]?.consecutiveReasoningEnvelopeCount = 0
                    let question = Self.reasoningEnvelopeEscalationQuestion(
                        roleName: roleForMessage.displayName)
                    let escalated = await setNeedsSupervisorInput(
                        stepID: stepID, taskID: task.id, question: question)
                    // Same fallback as the drift and malformed-JSON caps: transitioning to
                    // "needs Supervisor input" with no question rendered is strictly worse
                    // than the loop the cap replaced.
                    guard escalated else {
                        return .toolFailure(message: "Reasoning-channel cap exceeded but Supervisor escalation failed to persist; aborting step. Question would have been: \(question)")
                    }
                    return .needsSupervisorInput(question: question)
                }
            }
            let nudge = NoToolTurnNudges.reasoningChannel(
                namedCalls: reasoningCallNames, allowedToolNames: allowedToolNames)
            conversationMessages.append(ChatMessage(role: .user, content: nudge))
            await appendLLMMessage(
                stepID: stepID, taskID: task.id, role: .user, content: nudge,
                sourceContext: .retryNudge)
            return .continueLoop
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
        if isDrift, !isStepInRevision(stepID: stepID, taskID: task.id) {
            let newCount = (executionStates[stepKey]?.consecutiveDriftTurnCount ?? 0) + 1
            executionStates[stepKey]?.consecutiveDriftTurnCount = newCount
            if newCount >= 2 {
                // Reset so a post-supervisor restart starts clean.
                executionStates[stepKey]?.consecutiveDriftTurnCount = 0
                let question = Self.driftEscalationQuestion(
                    roleName: roleForMessage.displayName,
                    thousandsOfCharacters: thinkingTrimmedLen / 1000)
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
            let nudge = NoToolTurnNudges.thinkingDrift(
                thousandsOfCharacters: thinkingTrimmedLen / 1000)
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
        //
        // The classifier reads the RING, not the wire: `StepExecutionState.recentNoToolAssistantContents`
        // is the wire's last three qualifying assistant turns, maintained where turns are appended
        // (`appendAssistantTurn` in +Streaming) and re-seeded where the wire shrinks
        // (`reseedMessageLoopRing`). `detectMessageLoop` walked `conversationMessages.reversed()`
        // on every no-tool turn, and a tool-heavy wire has no qualifying turn near its tail, so
        // that walk was Θ(N) per iteration on an array with no ceiling. The `??` arm keeps a step
        // with no execution state (torn down mid-iteration) byte-identical to the old answer, at
        // the old cost.
        if !isStepInRevision(stepID: stepID, taskID: task.id) {
            switch ConversationRepairService.classifyMessageLoop(
                recentNoToolAssistantContents: executionStates[stepKey]?.recentNoToolAssistantContents
                    ?? ConversationRepairService.recentNoToolAssistantContents(in: conversationMessages))
            {
            case .refusalLoop(let count, _):
                // No excerpt. This question is not a private note to the Supervisor: it is
                // persisted as `step.supervisorQuestion`, and `PromptBuilder` step 5 replays
                // it into the role's OWN next request wrapped in `replayedAskSupervisorEnvelope`
                // — i.e. attributed to the model, in the few-shot slot whose own comment says
                // small models imitate the most recent shape. Quoting 300 characters of the
                // refusal there hands the loop back to the looping model as its own words, and
                // nudges are never retired, so it then rides the prefix of every remaining
                // request of the step (the harm `LoopRecoveryPolicy.shapeClause` was fixed for
                // on 2026-08-24).
                //
                // The human loses nothing: every refusal is already a card in the step's feed,
                // which is where the Supervisor reads it.
                let question = Self.refusalLoopEscalationQuestion(
                    roleName: roleForMessage.displayName, count: count)
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
            // The raw envelope is in `harmonyBuffer` once a Harmony marker was seen
            // mid-stream — NOT `assistantContent`, which holds only the pre-marker prose.
            // Classify and surface from there.
            //
            // `thinkingContent` is deliberately NOT consulted BY THIS BRANCH:
            // `sawHarmonyMarker` is a CONTENT-channel fact, and a reasoning-channel envelope
            // resolves nothing at all (see the route list in `performStreamingCall`), so a
            // reasoning-only turn must not be diagnosed as a broken tool call. A WELL-FORMED
            // reasoning envelope never gets here at all — the reasoning-channel branch above
            // claims it first and names the real cause; what can still arrive is a reasoning
            // channel whose envelope was too broken to parse, and that is exactly the turn
            // this branch must not blame on the wrong channel.
            let envelopeSource: String = result.harmonyBuffer.isEmpty
                ? result.assistantContent : result.harmonyBuffer
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
            case .missingToolName:
                // `.missingToolName` is a different recoverable defect — the inferred-name
                // nudge below usually self-corrects on the next attempt. Reset the
                // malformed-JSON counter so a previous .malformedJSON streak doesn't
                // pre-trigger escalation on the very next .malformedJSON turn after
                // the model recovered to a parseable-but-name-missing shape.
                executionStates[stepKey]?.consecutiveHarmonyParseFailureCount = 0
                retryMessage = NoToolTurnNudges.missingToolName(
                    allowedToolNames: allowedToolNames)
            case .toolNameInsideArguments:
                // Same class as `.missingToolName` — a shape defect the model corrects on
                // the next attempt — so the malformed-JSON counter resets rather than
                // advancing toward an escalation about broken braces.
                //
                // The id it wrote is deliberately NOT echoed: it names no registered tool,
                // and a nudge that repeats it teaches a vocabulary the runtime rejects
                // (R3.8.3). The card carries it for the human.
                executionStates[stepKey]?.consecutiveHarmonyParseFailureCount = 0
                retryMessage = NoToolTurnNudges.toolNameInsideArguments(
                    allowedToolNames: allowedToolNames)
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
                        let question = Self.malformedJSONEscalationQuestion(
                            roleName: roleForMessage.displayName)
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
                retryMessage = NoToolTurnNudges.malformedJSON(
                    defect: defect, allowedToolNames: allowedToolNames)
            case .noCallEnvelope:
                // Framing without a call: a `<|channel|>` / `<|start|>` envelope whose
                // recipient is missing or reserved, or whose body is prose. Deliberately
                // does NOT touch `consecutiveHarmonyParseFailureCount` — nothing failed to
                // parse — and the text names the shape the model ACTUALLY emits. gpt-oss
                // reaches for the channel form and may never emit `<|call|>` in a whole
                // pass, so a nudge teaching only the canonical form describes a syntax the
                // model isn't using while saying nothing about the one it is.
                retryMessage = NoToolTurnNudges.noCallEnvelope(
                    allowedToolNames: allowedToolNames)
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
        // A call sentinel the normalizer refused to repair. Derived ONCE here because two
        // branches below need the same verdict — the planning-phase plan guard and the
        // near-miss nudge — and re-deriving it would let them disagree about what counts
        // as an attempt. Content first, then the Harmony buffer: the buffer is populated
        // only once the latch closed, and a near-miss is precisely the turn where it did
        // not, so content is the usual home and the buffer covers the `.noEnvelopeAttempt`
        // fall-through (a role marker latched, an unrecognised sentinel beside it).
        let nearMissSentinel = HarmonySentinelNormalizer.unrepairedSentinel(in: originalContent)
            ?? HarmonySentinelNormalizer.unrepairedSentinel(in: result.harmonyBuffer)

        if !originalContent.isEmpty && cleanedContent.isEmpty {
            // Content was entirely garbled tokens with no substantive text
            // The turn this describes reaches the model EMPTY — that is the branch condition
            // (`cleanedContent.isEmpty`) — so "your previous response" names nothing it can
            // look at. The state is the anchor.
            let retryMessage = NoToolTurnNudges.tokensOnly()
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
        //
        // The fact is derived ONCE per iteration in `applyPlanningPhase` — still from the wire,
        // never a latch (the removed `planningTransitionDone` latch is the thing this must not
        // become) — and arrives here as `wireIsMidPlanning`. Re-deriving it was two more
        // O(conversation) passes per no-tool turn for an answer the iteration already held.
        if wireIsMidPlanning {
            // A failed tool call is not a plan. The only content test used to be
            // `isEmpty`, so a call the parser dropped was recorded as the step's durable
            // plan — and `implementationWire` keeps exactly that one turn across the
            // boundary, making it the sole memory of the exploration phase. Nudge with
            // the defect instead and let the model retry the call it meant to make;
            // leaving `scratchpad` nil keeps the phase open for a real plan.
            // Two predicates, one question: "was this an attempt?". `looksLikeToolCallAttempt`
            // answers it for an UNFRAMED reply — it requires the whole reply to be one JSON
            // object (`BareToolCallSalvage.jsonEnvelopeCall`'s `hasPrefix("{")`), so a reply
            // that is prose followed by a broken sentinel is invisible to it. That is the
            // shape task 39 run 8 recorded as its plan: the marker crossed the phase boundary
            // inside the seed turn and rode every later request as the freshest example in
            // the fresh conversation's first USER turn.
            if nearMissSentinel != nil || BareToolCallSalvage.looksLikeToolCallAttempt(cleanedContent) {
                // Anchored to the note, not to "That" — re-read on every later request, a
                // demonstrative points at whatever turn is nearest (R3.8.4). And a real id
                // from the phase's narrowed schema, as the `.malformedJSON` arm resolves —
                // this arm shipped the literal `TOOL_NAME` until 2026-09-06, in the one
                // phase where the model most needs to be shown which ids survive.
                let nudge = NoToolTurnNudges.planningSalvage(
                    allowedToolNames: allowedToolNames)
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
            let nudge = NoToolTurnNudges.planRecorded()
            conversationMessages.append(ChatMessage(role: .user, content: nudge))
            await appendLLMMessage(
                stepID: stepID, taskID: task.id, role: .user, content: nudge,
                sourceContext: .retryNudge)
            return .continueLoop
        }

        // A sentinel the normalizer refuses to repair, with a payload abutting it: the
        // model's attempt is plain to the eye and invisible to every latch. `sawHarmonyMarker`
        // is decided by exact substring against the three markers, so `classifyHarmonyCallIssue`
        // — which sits behind it — cannot run, and without this branch the turn falls through
        // to whichever arm happens to match. For a producing role that is the artifact nudge,
        // which answers a different question entirely: R3.8.2 ("a new failure shape gets its
        // own branch, not a neighbour's wording"), violated 16 times in one step of task 39
        // run 8 before this existed.
        //
        // ABOVE the producing-role branch for the same reason the planning branch is: that one
        // steers toward `create_artifact`, and a model whose sentinel is broken cannot call it
        // either. Below the planning branch because a plan is the more specific claim on the
        // same turn, and it has already returned by here.
        //
        // Shares `consecutiveHarmonyParseFailureCount` with the `.malformedJSON` arm rather
        // than adding a counter: both mean "the model emitted a call the parser could not
        // take", so three in any mixture is the same evidence that nudging has stopped
        // working. Repairing one more shape (which 2026-09-05 and 2026-09-07 both did) never
        // removes the need for this — the NEXT unrecognised shape is silent again, and the
        // only bound left is `maxNonProductiveTurns`, twenty turns away. Run 8 reached
        // sixteen consecutive nudges without tripping anything.
        //
        // The completeness check is repeated here rather than left to the branch below,
        // and it is not defensive noise: a step whose deliverables are all in is DONE
        // however its last turn was framed, and this branch stands ABOVE the arm that
        // would have said so. Without it a near-miss on a turn after the final
        // `create_artifact` nudges a step with nothing left to do, and the only thing that
        // ends it is the twenty-turn cap — the exact shape this branch exists to remove.
        // Cheap by construction: `checkArtifactCompleteness` is a read of
        // `step.isArtifactComplete`, and it answers `nil` for a role with no deliverables,
        // so an advisory role reaches the nudge unchanged.
        if let nearMissSentinel, checkArtifactCompleteness(stepID: stepID, taskID: task.id) == nil {
            let runID = task.runs.indices.contains(runIndex)
                ? task.runs[runIndex].id : (task.runs.last?.id ?? 0)
            await recordNonDispatchedAttempt(
                stepID: stepID, taskID: task.id, runID: runID,
                name: "unparsed_tool_call", code: "UNPARSED_SENTINEL",
                message: "Tool-call sentinel `\(nearMissSentinel)` was not recognised; not dispatched.",
                envelope: originalContent, runtime: runtime)

            // Same revision handling as the malformed-JSON cap: the Supervisor is already
            // driving, and a counter carried in from before the revision must not pre-trigger
            // an escalation on the first new turn after it.
            if isStepInRevision(stepID: stepID, taskID: task.id) {
                executionStates[stepKey]?.consecutiveHarmonyParseFailureCount = 0
            } else {
                let newCount = (executionStates[stepKey]?.consecutiveHarmonyParseFailureCount ?? 0) + 1
                executionStates[stepKey]?.consecutiveHarmonyParseFailureCount = newCount
                if newCount >= 3 {
                    executionStates[stepKey]?.consecutiveHarmonyParseFailureCount = 0
                    let question = Self.unrecognisedSentinelEscalationQuestion(
                        roleName: roleForMessage.displayName, sentinel: nearMissSentinel)
                    let escalated = await setNeedsSupervisorInput(
                        stepID: stepID, taskID: task.id, question: question)
                    // Same critical fallback as every other cap: a transition to "needs
                    // Supervisor input" with no question rendered is worse than the loop.
                    guard escalated else {
                        return .toolFailure(message: "Sentinel-failure cap exceeded but Supervisor escalation failed to persist; aborting step. Question would have been: \(question)")
                    }
                    return .needsSupervisorInput(question: question)
                }
            }

            // Anchored to the note's own position, and it names the form by OUR literal
            // rather than quoting the model's bytes: a nudge is never retired, so a quoted
            // attempt rides the prefix of every later request and re-seeds the loop it was
            // meant to break (R3.8.3, R3.8.4).
            let nudge = NoToolTurnNudges.unrecognisedSentinel(
                sentinel: nearMissSentinel, allowedToolNames: allowedToolNames)
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
                    let retryMessage = NoToolTurnNudges.revisionArtifacts(allowedToolNames: allowedToolNames)
                    conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                    await appendLLMMessage(
                        stepID: stepID, taskID: task.id, role: .user, content: retryMessage,
                        sourceContext: .retryNudge)
                    return .continueLoop
                }

                // Missing artifacts — retry. Names must be quoted and verbatim;
                // extensions / prefixes / rewordings cause name-resolution misses. The set
                // is the STEP's `missingArtifactNames` — the predicate
                // `checkArtifactCompleteness` just answered `nil` with — so a role that has
                // submitted "A" and lacks "B" is told about "B" alone. Until 2026-09-06 this
                // quoted the role definition's whole `producesArtifacts`, i.e. reported the
                // already-submitted deliverable as missing on every no-tool turn until the
                // step ended (R3.8.2).
                let missing = outstandingArtifactNames(stepID: stepID, task: task, fallback: expected)
                let retryMessage = Self.missingArtifactsNudge(missing: missing)
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

    /// The deliverables `stepID` still owes, read from the same record
    /// `checkArtifactCompleteness` reads (`delegate.loadedTask`, falling back to the
    /// iteration's `task`) so the nudge and the completion terminal agree. `fallback` is the
    /// role definition's list, used only when the step carries no `expectedArtifacts` of
    /// its own — the shape test fixtures build; a production step is created with the
    /// role's list, and reaching this branch means at least one of them is outstanding.
    private func outstandingArtifactNames(stepID: String, task: NTMSTask, fallback: [String]) -> [String] {
        let current = delegate?.loadedTask(task.id) ?? task
        guard let step = current.runs.last?.steps.first(where: { $0.id == stepID }) else { return fallback }
        let missing = step.missingArtifactNames
        return missing.isEmpty ? fallback : missing
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
        // No default, deliberately. The production caller holds a non-optional `ToolRuntime`
        // (`+ToolIteration`), so `= nil` served only the DEBUG test helper — and turned a
        // convenience into a silent parity break: `if let runtime` below writes the feed card
        // and drops BOTH per-run audit rows, so a future caller that forgot the argument
        // would ship a run whose logs disagree with its own feed. Same class as rule #199;
        // now the compiler carries the claim a comment used to.
        runtime: ToolRuntime?
    ) async {
        let name: String
        let code: String
        let message: String
        switch issue {
        case .missingToolName(let inferred):
            name = inferred ?? "unknown_tool"
            code = "MISSING_TOOL_NAME"
            message = "Tool-call JSON parsed but had no top-level `name` field; not dispatched."
        case .toolNameInsideArguments(let nested):
            // Named after what the model actually wrote, not `unknown_tool`: the card is the
            // human's record of what the parser saw, and "unknown" was false — the id was
            // right there, one level too deep. The CODE stays `MISSING_TOOL_NAME` so the
            // `jq` audits in `.claude/skills/train-app` keep matching; the message is what
            // separates the two cases.
            name = nested
            code = "MISSING_TOOL_NAME"
            message = "Tool-call JSON put the tool id inside `arguments` (`\(nested)`), "
                + "and no tool of that name is registered; not dispatched."
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
        await recordNonDispatchedAttempt(
            stepID: stepID, taskID: taskID, runID: runID,
            name: name, code: code, message: message, envelope: envelope, runtime: runtime)
    }

    /// Writes one errored `StepToolCall` card and mirrors it into both per-run logs.
    ///
    /// Extracted from `recordFailedToolCallAttemptIfNeeded` when the near-miss branch
    /// needed the same surfacing: the CLASSIFICATION of a non-dispatched attempt differs
    /// per branch (a `HarmonyCallIssue` behind the marker latch, an unrecognised sentinel
    /// in front of it), but what happens to it afterwards is one behaviour and belongs in
    /// one place. Deliberately NOT reached by adding a `HarmonyCallIssue` case: that enum
    /// classifies a buffer in which a marker was already found, and a near-miss is by
    /// definition a buffer where none was.
    private func recordNonDispatchedAttempt(
        stepID: String,
        taskID: Int,
        runID: Int,
        name: String,
        code: String,
        message: String,
        envelope: String,
        runtime: ToolRuntime?
    ) async {
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
        // actor (the loggers do synchronous file I/O).
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
        // The `<|end|>`-bounded RAW bytes, not the walker's span: the card exists to show
        // the model's attempt verbatim, and the walker's EOF salvage TRUNCATES mid-value
        // and pads synthetic closers — bytes the model never emitted. CubeCraft task 8
        // run 0 recorded `old_text` cut at its `]` plus a fabricated `}}`, and the
        // truncation read as the model's defect during diagnosis when the model's actual
        // `old_text` was complete. The walker remains the fallback for a buffer with no
        // end marker (a cut-off stream), where no better boundary exists.
        if let (body, _) = ToolCallParsingHelpers.endMarkerBoundedBody(
            in: tail, from: start, endMarker: CallMarkerStrategy.endMarker)
        {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        allowedToolNames: Set<String>,
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
            roleName: roleForMessage.displayName,
            allowedToolNames: allowedToolNames
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
    /// runtime-prompt — the five cap escalations `handleNoToolCalls` raises.
    ///
    /// Addressed to the Supervisor, which under `SupervisorMode.autonomous` is an LLM
    /// (`SupervisorAutoAnswerService`) and whose answer is replayed into the role's own next
    /// request — so these are model-facing text too, and `Ratchet/NudgeTextPinTests` reads
    /// them for politeness tokens and reader's-present anchoring.
    nonisolated static func reasoningEnvelopeEscalationQuestion(roleName: String) -> String {
        """
        Role \(roleName) wrote its tool call inside its reasoning \
        on two consecutive turns. Nothing dispatches from there, so both turns did \
        nothing — the model is not moving the call into its reply on its own. Advise \
        how to proceed (give an explicit next step, restart the role with a \
        different model, or mark the step failed).
        """
    }

    /// runtime-prompt
    nonisolated static func driftEscalationQuestion(
        roleName: String, thousandsOfCharacters: Int
    ) -> String {
        """
        Role \(roleName) produced two consecutive long reasoning \
        responses (~\(thousandsOfCharacters)k characters of internal thinking \
        last turn) without calling any tool. The model is reasoning instead of acting \
        — advise how to proceed (clarify the task, give an explicit next step, \
        or mark the step failed).
        """
    }

    /// runtime-prompt
    nonisolated static func refusalLoopEscalationQuestion(roleName: String, count: Int) -> String {
        """
        Role \(roleName) emitted \(count) consecutive refusal messages without \
        calling any tools. The model appears stuck — advise how to proceed (answer the \
        underlying need, provide explicit instructions, or mark the step failed).
        """
    }

    /// runtime-prompt
    nonisolated static func malformedJSONEscalationQuestion(roleName: String) -> String {
        // The example defect is safe to name now that `.noCallEnvelope` is its own case: the
        // arm that raises this fires only when a `<|call|>` block really was opened and its
        // payload really is broken JSON. Before the split it also fired for envelopes
        // containing no JSON at all, misdiagnosing the fault to the HUMAN reading this.
        """
        Role \(roleName) produced 3 consecutive malformed \
        tool-call JSON envelopes (often an unescaped `"` inside a string literal — \
        a common defect when models emit HTML/JS content inside `create_artifact`). \
        The model cannot self-correct from generic retry hints. Restart the role \
        with a different model, simplify the brief to avoid embedded markup, or \
        mark the step failed and re-plan.
        """
    }

    /// runtime-prompt
    nonisolated static func unrecognisedSentinelEscalationQuestion(
        roleName: String, sentinel: String
    ) -> String {
        """
        Role \(roleName) produced 3 consecutive tool calls whose \
        opening sentinel the parser could not recognise — the model writes \
        `\(sentinel)` where the format is `<|call|>`. On an append-only wire \
        it is copying its own broken form back from the conversation, so a nudge \
        cannot reach it. Restart the role with a different model, or mark the step \
        failed and re-plan.
        """
    }

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
        call, so this step cannot advance on its own. Advise how to proceed (clarify \
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

    // MARK: - Message-loop ring

    /// Rebuilds `StepExecutionState.recentNoToolAssistantContents` from `wire` — the same walk
    /// `ConversationRepairService.detectMessageLoop` performs, run ONCE per event that replaces
    /// or shrinks the array rather than once per iteration.
    ///
    /// Three PRODUCTION call sites, each a shrink/replace event (the two DEBUG helpers in
    /// `+TestHelpers`, `_testHandleNoToolCalls` and `_testSeedMessageLoopRing`, route through it
    /// as well and are excluded from the pin's count):
    ///  1. Step entry (`+StepLifecycle`, beside `seedTagCounters`) — a replayed transcript
    ///     already carries the turns the detector counts, and the fresh state starts empty.
    ///  2. The planning boundary (`+PlanningPhase`, `.crossBoundary`) — the slice keeps the
    ///     prefix before the brief, which may hold qualifying turns; the reset just cleared them.
    ///  3. A poisoned-tail repair (`+StepLifecycle`, `repairConversationIfNeeded` returned true)
    ///     — the removed assistant turn carries `toolCalls != nil`, which almost never
    ///     qualifies, but `toolCalls == []` would, so re-derive rather than argue.
    ///
    /// The single APPEND site (`appendAssistantTurn`, +Streaming) pushes instead of reseeding.
    /// Internal, not private (CLAUDE.md Swift Style #13): called from `+StepLifecycle`,
    /// `+PlanningPhase` and `+TestHelpers`.
    func reseedMessageLoopRing(stepKey: TaskStepKey, from wire: [ChatMessage]) {
        executionStates[stepKey]?.recentNoToolAssistantContents =
            ConversationRepairService.recentNoToolAssistantContents(in: wire)
    }
}
