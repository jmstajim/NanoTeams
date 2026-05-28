import Foundation

/// Extension for orchestrating tool result processing: iterates results, dispatches to
/// collaboration or regular handlers (in +ToolResultDispatching), and records learning events.
extension LLMExecutionService {

    // MARK: - Skip predicate for async-finalized signals

    /// Returns `false` when the result's signal indicates an interim placeholder
    /// envelope that will be rewritten asynchronously by a dedicated finalizer
    /// (`appendExploratorySearchResult`, `appendVisionResult`). In that case the
    /// finalizer records the FINAL envelope into the tracker itself — recording
    /// the placeholder here would poison the loop detector's next-iteration
    /// `recentCalls` snapshot.
    ///
    /// All other signals (and `nil` for plain results) are recorded synchronously
    /// in the pre-record loop, since their `outputJSON` is final at this point.
    nonisolated static func shouldRecordInTrackerPreFinalize(signal: ToolSignal?) -> Bool {
        switch signal {
        case .exploratorySearch, .visionAnalysis:
            return false
        default:
            return true
        }
    }

    // MARK: - Tool Result Processing

    /// Result of processing all tool execution results for a single iteration.
    nonisolated struct ToolResultsOutcome {
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
        tracker: ToolCallTracker,
        memoryStore: MemoryTagStore,
        iterationNumber: Int,
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

        // Record tool calls in the tracker (loop-detector input).
        //
        // `.exploratorySearch` and `.visionAnalysis` results carry an interim
        // `{"status":"exploring"}` / `{"status":"analyzing"}` placeholder
        // at this point — their envelopes get rewritten asynchronously by
        // `appendExploratorySearchResult` / `appendVisionResult`. We skip them
        // here (via `shouldRecordInTrackerPreFinalize`) and let those finalizers
        // record the real envelope; otherwise the `recentCalls` snapshot the
        // loop detector reads next iteration would see the placeholder
        // instead of the real result.
        for (call, result) in zip(resolvedToolCalls, results) {
            guard Self.shouldRecordInTrackerPreFinalize(signal: result.signal) else { continue }
            tracker.record(
                toolName: call.name,
                argumentsJSON: call.argumentsJSON,
                resultJSON: result.outputJSON,
                isError: result.isError
            )
        }

        for (idx, result) in results.enumerated() {
            switch result.signal {
            case .teammateConsultation, .teamMeeting, .changeRequest, .delegateToTeam,
                 .cancelDelegation, .resumeDelegation, .forwardToTeam:
                await appendCollaborationResult(
                    result: result,
                    toolCallID: resolvedToolCalls[idx].id,
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
                    conversationMessages: &conversationMessages,
                    tracker: tracker
                )
            case .exploratorySearch:
                let toolCallID = resolvedToolCalls[idx].id
                await appendExploratorySearchResult(
                    result: result,
                    toolCallID: toolCallID,
                    stepID: stepID,
                    conversationMessages: &conversationMessages,
                    tracker: tracker
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
