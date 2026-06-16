import Foundation

/// Stateless executor for tool calls within a single meeting turn.
/// Handles the LLM → tools → LLM loop for meeting participants.
enum MeetingToolExecutor {

    /// Receives the in-flight batch task each time a turn dispatches tool calls
    /// to the cooperative pool. The orchestrator stores the handle so a paused
    /// run can cancel it; passing `nil` signals "no batch in flight, clear any
    /// stored handle."
    typealias BatchCancellationRegistrar = @MainActor (Task<[ToolExecutionResult], Never>?) -> Void

    /// Executes tool calls for a single meeting turn. If the LLM returns tool calls,
    /// executes them and re-calls the LLM with results, up to maxToolIterationsPerTurn.
    static func executeTurnToolLoop(
        initialResult: TeamMeetingService.MeetingStreamResult,
        speaker: Role,
        meeting: TeamMeeting,
        meetingContext: TeamMeetingService.MeetingContext,
        client: any LLMClient,
        config: LLMConfig,
        tools: [ToolSchema],
        runtime: ToolRuntime,
        toolContext: ToolExecutionContext,
        stepID: String? = nil,
        networkLogger: NetworkLogger? = nil,
        cancellationRegistrar: BatchCancellationRegistrar? = nil
    ) async throws -> (content: String, thinking: String, toolSummaries: [MeetingToolSummary]) {
        var currentResult = initialResult
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
            // executor / runtime. Rejected calls get a `tool_not_authorized`
            // envelope fed back to the follow-up turn — silently dropping them
            // (the prior behavior) stalled meetings when a participant emitted
            // only disallowed tools.
            var validCalls: [StepToolCall] = []
            var rejectedResults: [ToolExecutionResult] = []
            for call in currentResult.resolvedToolCalls {
                let canonical = ToolRegistry.resolveToolName(call.name)
                if allowedToolNames.contains(canonical) {
                    validCalls.append(call)
                } else {
                    rejectedResults.append(LLMExecutionService.makeToolNotAuthorizedResult(
                        call: call, canonicalName: canonical, scope: "in this meeting"
                    ))
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
                for r in rejectedResults {
                    runtime.logNonExecutedCall(
                        taskID: toolContext.taskID,
                        runID: toolContext.runID,
                        roleID: toolContext.roleID,
                        toolName: r.toolName,
                        argumentsJSON: r.argumentsJSON,
                        resultJSON: r.outputJSON,
                        errorMessage: "tool not authorized in this meeting"
                    )
                }
                return runtime.executeAll(context: toolContext, toolCalls: validCalls)
            }
            cancellationRegistrar?(batchTask)
            let freshResults = await batchTask.value
            cancellationRegistrar?(nil)
            let toolResults = freshResults + rejectedResults

            // Record tool summaries for both executed and rejected calls
            for result in toolResults {
                collectedToolSummaries.append(MeetingToolSummary(
                    toolName: result.toolName,
                    arguments: String(result.argumentsJSON.prefix(500)),
                    result: String(result.outputJSON.prefix(1000)),
                    isError: result.isError
                ))
            }

            // Build follow-up messages with tool results
            var followUpMessages = MeetingStreamingService.buildMeetingMessages(
                speaker: speaker,
                meeting: meeting,
                context: meetingContext,
                tools: tools
            )

            // Feed back every call the model made — both executed and rejected
            // — so the LLM sees why a tool was blocked and can self-correct.
            let allCalls = validCalls + currentResult.resolvedToolCalls.filter { call in
                !allowedToolNames.contains(ToolRegistry.resolveToolName(call.name))
            }
            followUpMessages.append(ChatMessage(
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
                followUpMessages.append(ChatMessage(
                    role: .tool,
                    content: result.outputJSON,
                    toolCallID: result.providerID ?? call.providerID ?? call.id.uuidString
                ))
            }

            // Re-call LLM with tool results
            currentResult = try await MeetingStreamingService.streamParticipantResponse(
                messages: followUpMessages,
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

        return (currentResult.content, allThinking, collectedToolSummaries)
    }
}
