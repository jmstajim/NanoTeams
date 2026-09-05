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
        case .exploratorySearch, .visionAnalysis, .computerUse:
            return false
        default:
            return true
        }
    }

    /// Single source of truth for "this signal is handled by the deferred
    /// `appendCollaborationResult` path" (its real envelope/side-effects run there,
    /// not in `processRegularToolResult`). Adding a collaboration/delegation/manager
    /// signal to `ToolSignal` WITHOUT adding it here silently routes it to the
    /// regular path — for `wait_for_events` that meant `parkForEventsRequested` was
    /// never set and the manager looped forever. Keep in sync with the `switch` in
    /// `appendCollaborationResult`.
    nonisolated static func isCollaborationDeferredSignal(_ signal: ToolSignal?) -> Bool {
        switch signal {
        case .teammateConsultation, .teamMeeting, .changeRequest, .delegateToTeam,
             .cancelDelegation, .resumeDelegation, .forwardToTeam,
             .listTasks, .taskStatus, .createManagedTask, .controlTask, .manageRole,
             .answerTaskQuestion, .messageTask, .scheduleTask, .setWorkFolderContext,
             .waitForEvents:
            return true
        default:
            return false
        }
    }

    /// True for the Autovisor management signals. Unlike the rich-UI
    /// collaboration tools (delegation / consultation / meeting), these have NO
    /// separate UI surface — the tool-call card is the only place their result
    /// appears. So `appendCollaborationResult` reflects their real deferred
    /// response (success OR failure) onto the persisted `StepToolCall`, instead of
    /// leaving the synchronous `{"status":"pending"}` placeholder the handler
    /// emitted. Adding a manager signal WITHOUT listing it here leaves its card
    /// stuck on "pending" for the human supervising the manager.
    ///
    /// Invariant every listed handler MUST uphold: return a well-formed
    /// `makeSuccessEnvelope` / `makeErrorEnvelope` (always carries an `ok` field).
    /// A raw / non-envelope string parses as `EnvelopeStatus.indeterminate`, and
    /// `reflectEnvelope`'s `cardIsError = (envelopeStatus(env) == .failure)` would
    /// then render a broken result falsely green — so a non-envelope manager
    /// handler must never be added.
    nonisolated static func isAutovisorSignal(_ signal: ToolSignal?) -> Bool {
        switch signal {
        case .listTasks, .taskStatus, .createManagedTask, .controlTask, .manageRole,
             .answerTaskQuestion, .messageTask, .scheduleTask, .setWorkFolderContext,
             .waitForEvents:
            return true
        default:
            return false
        }
    }

    // MARK: - Tool Result Processing

    /// Result of processing all tool execution results for a single iteration.
    nonisolated struct ToolResultsOutcome {
        var shouldStopForSupervisor: Bool = false
        var supervisorQuestion: String?
        /// EVERY `ask_supervisor` call in the batch, in emit order — not just the first.
        ///
        /// The questions are merged into one `supervisorQuestion`, and one answer resolves all of
        /// them, but each call appended its own `{"status":"pending"}` tool result. Recording a
        /// single provider id meant the answer replaced one of them and left the rest pending on
        /// the wire for the remainder of the step, resent every iteration — a value reporting
        /// INTENT while the model waits for something that already arrived, which invites it to
        /// re-ask a question the merged answer already covered.
        var supervisorToolCallProviderIDs: [String] = []
        /// The batch with every DEFERRED signal's placeholder replaced by what it actually
        /// resolved to.
        ///
        /// Deferred handlers return `{"status":"pending"}` with `isError: false` synchronously and
        /// finish minutes later, so the array the caller holds describes intent, not outcome.
        /// `ToolTurnProductivity.classify` reads exactly that flag and is the sole writer that
        /// resets the no-tool ceiling — so an all-failed Autovisor turn used to count as
        /// productive. The merge belongs here, next to the finalizers that know the outcomes,
        /// rather than being re-derived by the caller.
        var effectiveResults: [ToolExecutionResult] = []
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
        wireIsMidPlanning: Bool,
        conversationMessages: inout [ChatMessage],
        networkLogger: NetworkLogger? = nil
    ) async -> ToolResultsOutcome {
        var outcome = ToolResultsOutcome()
        var effectiveResults = results

        // Update tool calls with their results.
        // Vision signals write an interim "analyzing" placeholder here;
        // appendVisionResult() will overwrite with the final result.
        for (call, result) in zip(resolvedToolCalls, results) {
            await updateToolCallResult(stepID: stepID, taskID: task.id, toolCallID: call.id, result: result)
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
            // Collaboration / delegation / manager signals run their real
            // side-effects in the deferred handler. Gated by the single-source
            // predicate so a new signal can't silently fall through to the
            // regular path (see `isCollaborationDeferredSignal`).
            if Self.isCollaborationDeferredSignal(result.signal) {
                effectiveResults[idx].isError = await appendCollaborationResult(
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
                continue
            }
            switch result.signal {
            case .visionAnalysis:
                let toolCallID = resolvedToolCalls[idx].id
                await appendVisionResult(
                    result: result,
                    toolCallID: toolCallID,
                    stepID: stepID,
                    taskID: task.id,
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
                    taskID: task.id,
                    conversationMessages: &conversationMessages,
                    tracker: tracker
                )
            case .computerUse:
                let toolCallID = resolvedToolCalls[idx].id
                await appendComputerUseResult(
                    result: result,
                    toolCallID: toolCallID,
                    stepID: stepID,
                    taskID: task.id,
                    client: client,
                    config: config,
                    networkLogger: networkLogger,
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
                    argumentRepairNote: resolvedToolCalls[idx].argumentRepairNote,
                    stepID: stepID,
                    taskID: task.id,
                    memoryStore: memoryStore,
                    wireIsMidPlanning: wireIsMidPlanning,
                    conversationMessages: &conversationMessages,
                    outcome: &outcome
                )
            default:
                await processRegularToolResult(
                    result: result,
                    argumentRepairNote: resolvedToolCalls[idx].argumentRepairNote,
                    stepID: stepID,
                    taskID: task.id,
                    memoryStore: memoryStore,
                    wireIsMidPlanning: wireIsMidPlanning,
                    conversationMessages: &conversationMessages,
                    outcome: &outcome
                )
            }
        }

        outcome.effectiveResults = effectiveResults
        return outcome
    }

}
