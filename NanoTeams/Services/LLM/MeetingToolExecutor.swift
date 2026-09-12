import Foundation

/// Stateless executor for tool calls within a single meeting turn.
/// Handles the LLM → tools → LLM loop for meeting participants.
enum MeetingToolExecutor {

    /// The context for ONE speaker's turn: the meeting's base context (its `stepID` is the
    /// initiator's step, where the runtime state and the build-gate caption belong) with
    /// `roleID` rewritten to the speaker's DEFINITION id, so `tool_calls.jsonl` and the
    /// network log attribute the call to whoever made it. Until the evening of 2026-09-11
    /// every speaker's call carried the initiator's id — a Diff Reviewer building during a
    /// verifier-convened vote was logged as the verifier building, `queuedMS` included.
    /// Falls back to `speaker.baseID` for a fixture with no team.
    nonisolated static func turnContext(
        base: ToolExecutionContext, speaker: Role, team: Team?
    ) -> ToolExecutionContext {
        var context = base
        context.roleID = team?.findRole(byIdentifier: speaker.baseID)?.id ?? speaker.baseID
        return context
    }

    /// Receives the in-flight batch task each time a turn dispatches tool calls
    /// to the cooperative pool. The orchestrator stores the handle so a paused
    /// run can cancel it; passing `nil` signals "no batch in flight, clear any
    /// stored handle."
    typealias BatchCancellationRegistrar = @MainActor (Task<[ToolExecutionResult], Never>?) -> Void

    /// Executes tool calls for a single meeting turn. If the LLM returns tool calls,
    /// executes them and re-calls the LLM with results, up to maxToolIterationsPerTurn.
    ///
    /// `conversationSoFar` is the FULL stateless render of the conversation the
    /// initial stream was grounded on (system prompt + artifact context + chat
    /// history + the meeting turn). Follow-up calls CONTINUE that stack —
    /// appending the assistant tool-call turn + tool results each iteration —
    /// so the model keeps the exact system prompt and grounding it spoke from.
    /// The pre-fix rebuild via `buildMeetingMessages` swapped in a different
    /// system prompt mid-turn and dropped the artifact grounding, letting a
    /// small model contradict its own pre-tool statement.
    static func executeTurnToolLoop(
        initialResult: TeamMeetingService.MeetingStreamResult,
        conversationSoFar: [ChatMessage],
        meetingContext: TeamMeetingService.MeetingContext,
        client: any LLMClient,
        config: LLMConfig,
        tools: [ToolSchema],
        runtime: ToolRuntime,
        toolContext: ToolExecutionContext,
        stepID: String? = nil,
        networkLogger: NetworkLogger? = nil,
        cancellationRegistrar: BatchCancellationRegistrar? = nil,
        /// Records each follow-up request against the meeting turn's prompt-prefix chain.
        ///
        /// A closure rather than the ledger itself: this is a stateless enum with no owner and no
        /// notion of which chain it belongs to, and the caller has both. Binding the chain id at
        /// the call site is also what guarantees the initial stream and its follow-ups land on the
        /// SAME chain — recomputing the id in two frames is how a key comes to disagree with
        /// itself (CLAUDE.md Грабли 2026-07-26).
        recordPrefixChain: (([ChatMessage]) async -> Void)? = nil
    ) async throws -> (
        content: String, thinking: String,
        toolSummaries: [MeetingToolSummary],
        conclusion: TeamMeetingService.MeetingConclusion?
    ) {
        var currentResult = initialResult
        var conversation = conversationSoFar
        var allThinking = initialResult.thinking
        var collectedToolSummaries: [MeetingToolSummary] = []
        var iteration = 0
        let allowedToolNames = Set(tools.map(\.name))

        while !currentResult.resolvedToolCalls.isEmpty
            && iteration < meetingContext.limits.maxMeetingToolIterationsPerTurn
        {
            if Task.isCancelled { throw CancellationError() }

            // Partition into valid vs rejected, using the shared resolver so
            // provider prefixes and aliases are handled uniformly with the main
            // executor / runtime. Rejected calls get an error envelope fed back to the
            // follow-up turn — silently dropping them (the prior behavior) stalled
            // meetings when a participant emitted only disallowed tools. The envelope is
            // the executor's name-shaped split (`nameShapedReason`): a name that is not a
            // tool at all (`unknown_tool` — `submit_vote`, `cast_vote`) and a real tool this
            // speaker does not hold (`tool_not_authorized`) have different remedies, and
            // until the evening of 2026-09-11 both read "did not run and returned nothing;
            // name the fact as unverified", which is meaningless for a name that names
            // nothing. Meeting turns append no `ToolErrorNotePolicy` direction, so the
            // envelope is the whole of what a speaker learns.
            var validCalls: [StepToolCall] = []
            var rejectedResults: [(result: ToolExecutionResult, reason: String)] = []
            for call in currentResult.resolvedToolCalls {
                let canonical = ToolRegistry.resolveToolName(call.name)
                if allowedToolNames.contains(canonical) {
                    validCalls.append(call)
                } else {
                    let reason = LLMExecutionService.nameShapedReason(canonical: canonical)
                    rejectedResults.append((
                        LLMExecutionService.makeUnavailableToolResult(
                            call: call, canonicalName: canonical, scope: "in this meeting",
                            reason: reason),
                        reason == .unknownToolName
                            ? "unknown tool name in this meeting"
                            : "tool not authorized in this meeting"))
                }
            }

            if validCalls.isEmpty && rejectedResults.isEmpty { break }

            iteration += 1

            // Off-main dispatch. Same Sendable contract as
            // `LLMExecutionService.executeToolCalls`. The registrar lets the
            // orchestrator hold the batch handle so `cancelAllExecutions`
            // reaches in — otherwise pause-during-meeting can't stop the
            // detached batch.
            let batchTask = Task.detached(priority: .userInitiated) {
                [runtime, toolContext, validCalls, rejectedResults] in
                // Mirror rejected meeting calls into both per-run logs — executed
                // calls log inside `executeOne`, so without this the wire/jsonl
                // audit would show meeting executions but silently drop meeting
                // rejections (the same asymmetry the step path avoids via its own
                // rejection mirror).
                for (r, reason) in rejectedResults {
                    runtime.logNonExecutedCall(
                        taskID: toolContext.taskID,
                        runID: toolContext.runID,
                        roleID: toolContext.roleID,
                        toolName: r.toolName,
                        argumentsJSON: r.argumentsJSON,
                        resultJSON: r.outputJSON,
                        errorMessage: reason
                    )
                }
                return await runtime.executeAll(context: toolContext, toolCalls: validCalls)
            }
            cancellationRegistrar?(batchTask)
            let freshResults = await batchTask.value
            cancellationRegistrar?(nil)
            let toolResults = freshResults + rejectedResults.map(\.result)

            // Record tool summaries for both executed and rejected calls
            for result in toolResults {
                collectedToolSummaries.append(MeetingToolSummary(
                    toolName: result.toolName,
                    arguments: String(result.argumentsJSON.prefix(500)),
                    result: String(result.outputJSON.prefix(1000)),
                    isError: result.isError
                ))
            }

            // `conclude_meeting` (coordinator only — anyone else's call was rejected
            // above as not authorized in this meeting) ends the TURN here and the
            // MEETING in the caller. No follow-up stream: the decision is the
            // coordinator's contribution, and asking the model to speak again after
            // it has concluded would only produce a reply nobody is listening to.
            // The turn's own text (if any) still lands as its spoken content.
            var conclusion: TeamMeetingService.MeetingConclusion?
            for result in freshResults {
                if case .concludeMeeting(let decision, let rationale, let nextSteps)? = result.signal {
                    conclusion = .init(decision: decision, rationale: rationale, nextSteps: nextSteps)
                    break
                }
            }
            if let conclusion {
                return (currentResult.content, allThinking, collectedToolSummaries, conclusion)
            }

            // Feed back every call the model made — both executed and rejected
            // — so the LLM sees why a tool was blocked and can self-correct.
            // Appending to the RUNNING conversation (not a rebuild) keeps
            // earlier iterations' tool results visible in later iterations.
            let allCalls = validCalls + currentResult.resolvedToolCalls.filter { call in
                !allowedToolNames.contains(ToolRegistry.resolveToolName(call.name))
            }
            conversation.append(ChatMessage(
                role: .assistant,
                content: currentResult.content.isEmpty ? nil : currentResult.content,
                toolCalls: allCalls.map { call in
                    ChatToolCall(
                        id: call.providerID ?? call.id.uuidString,
                        name: call.name,
                        argumentsJSON: call.argumentsJSON
                    )
                }
            ))

            // Add tool results — pair by position (allCalls order matches
            // validCalls + rejectedCalls, and toolResults matches that order)
            for (call, result) in zip(allCalls, toolResults) {
                conversation.append(ChatMessage(
                    role: .tool,
                    content: result.outputJSON,
                    toolCallID: result.providerID ?? call.providerID ?? call.id.uuidString
                ))
            }

            // Re-call the LLM with the tool results appended — the same full
            // conversation the initial stream was grounded on, plus this
            // iteration's calls and results. Append-only, so this is exactly the growing prefix
            // the ledger exists to track.
            await recordPrefixChain?(conversation)

            currentResult = try await MeetingStreamingService.streamParticipantResponse(
                messages: conversation,
                client: client,
                config: config,
                tools: tools,
                logger: networkLogger,
                stepID: stepID
            )

            if !currentResult.thinking.isEmpty {
                allThinking += (allThinking.isEmpty ? "" : "\n") + currentResult.thinking
            }
        }

        return (currentResult.content, allThinking, collectedToolSummaries, nil)
    }
}
