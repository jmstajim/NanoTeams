import Foundation

/// Stateless executor for tool calls within a single meeting turn.
/// Handles the LLM → tools → LLM loop for meeting participants.
enum MeetingToolExecutor {

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
        networkLogger: NetworkLogger? = nil
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

            // Execute valid tool calls; rejected results already built above
            let freshResults = runtime.executeAll(context: toolContext, toolCalls: validCalls)
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
                context: meetingContext
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
