import Foundation

/// Extension for orchestrating tool result processing: iterates results, dispatches to
/// collaboration or regular handlers (in +ToolResultDispatching), and records learning events.
extension LLMExecutionService {

    // MARK: - Tool Result Processing

    /// Result of processing all tool execution results for a single iteration.
    struct ToolResultsOutcome {
        var shouldStopForSupervisor: Bool = false
        var supervisorQuestion: String?
        var supervisorToolCallProviderID: String?
    }

    /// Processes all tool results: updates persisted state, handles teammate/meeting/scratchpad,
    /// records learning insights, and injects guidance messages.
    func processToolResults(
        resolvedToolCalls: [StepToolCall],
        results: [ToolExecutionResult],
        stepID: String,
        roleForMessage: Role,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        assistantContent _: String,
        client: any LLMClient,
        config: LLMConfig,
        memory: ToolCallCache,
        memoryStore: MemoryTagStore,
        iterationNumber: Int,
        cachedIndices: Set<Int>,
        conversationMessages: inout [ChatMessage],
        networkLogger: NetworkLogger? = nil
    ) async -> ToolResultsOutcome {
        var outcome = ToolResultsOutcome()

        // Update tool calls with their results.
        // Vision signals write an interim "analyzing" placeholder here;
        // appendVisionResult() will overwrite with the final result.
        for (call, result) in zip(resolvedToolCalls, results) {
            await updateToolCallResult(stepID: stepID, toolCallID: call.id, result: result)
        }

        // Record tool calls to memory
        for (idx, (call, result)) in zip(resolvedToolCalls, results).enumerated() {
            if !cachedIndices.contains(idx) {
                memory.record(
                    toolName: call.name,
                    argumentsJSON: call.argumentsJSON,
                    resultJSON: result.outputJSON,
                    isError: result.isError
                )
            }
        }

        for (idx, result) in results.enumerated() {
            switch result.signal {
            case .teammateConsultation, .teamMeeting, .changeRequest:
                await appendCollaborationResult(
                    result: result,
                    roleForMessage: roleForMessage,
                    stepID: stepID,
                    task: task,
                    runIndex: runIndex,
                    stepIndex: stepIndex,
                    client: client,
                    config: config,
                    networkLogger: networkLogger,
                    conversationMessages: &conversationMessages
                )
            case .visionAnalysis:
                let toolCallID = resolvedToolCalls[idx].id
                await appendVisionResult(
                    result: result,
                    toolCallID: toolCallID,
                    stepID: stepID,
                    client: client,
                    config: config,
                    networkLogger: networkLogger,
                    conversationMessages: &conversationMessages
                )
            case .teamCreation:
                // create_team is invoked exclusively by TeamGenerationService, not via
                // the runtime. Filtered out of role schemas via `availableToRoles=false`,
                // so reaching this branch means a misconfigured role attempted to call
                // it — process as a regular result and let the model see the success
                // envelope, but do NOT install the team (that path belongs to
                // `runTeamGeneration`).
                await processRegularToolResult(
                    result: result,
                    stepID: stepID,
                    memoryStore: memoryStore,
                    iterationNumber: iterationNumber,
                    conversationMessages: &conversationMessages,
                    outcome: &outcome
                )
            default:
                await processRegularToolResult(
                    result: result,
                    stepID: stepID,
                    memoryStore: memoryStore,
                    iterationNumber: iterationNumber,
                    conversationMessages: &conversationMessages,
                    outcome: &outcome
                )
            }
        }

        return outcome
    }

}
