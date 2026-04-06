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

            // Filter to only execute tools in the allowed meeting tool list (resolve aliases)
            let validCalls = currentResult.resolvedToolCalls.filter {
                let resolved = ToolRegistry.defaultAliases[$0.name.lowercased()] ?? $0.name
                return allowedToolNames.contains(resolved)
            }
            if validCalls.isEmpty { break }

            iteration += 1

            // Execute tool calls
            let toolResults = runtime.executeAll(context: toolContext, toolCalls: validCalls)

            // Record tool summaries
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

            // Add the assistant's response that contained tool calls
            followUpMessages.append(ChatMessage(
                role: .assistant,
                content: currentResult.content.isEmpty ? nil : currentResult.content,
                toolCalls: validCalls.map { call in
                    ChatToolCall(
                        id: call.providerID ?? call.id.uuidString,
                        name: call.name,
                        argumentsJSON: call.argumentsJSON
                    )
                }
            ))

            // Add tool results
            for (call, result) in zip(validCalls, toolResults) {
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
