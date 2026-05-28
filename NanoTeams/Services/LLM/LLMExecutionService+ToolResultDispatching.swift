import Foundation

/// Extension for dispatching individual tool results: collaboration signal routing
/// (teammate consultations, meetings, change requests) and regular tool result handling
/// (scratchpad, artifacts, supervisor questions, error guidance).
extension LLMExecutionService {

    // MARK: - Collaboration Signal Dispatch

    /// Handles a collaboration tool result (ask_teammate, request_team_meeting, request_changes,
    /// delegate_to_team, cancel/resume/forward delegation).
    ///
    /// `toolCallID` identifies the persisted `StepToolCall` row written by
    /// `processToolResults` from the placeholder envelope (`isError: false`,
    /// `pending` status). After the deferred handler returns the real response,
    /// we re-update that row only when `envelopeStatus(response) == .failure` —
    /// i.e. the envelope explicitly carries `{"ok": false, ...}`. Malformed
    /// JSON, missing `ok` field, or non-Bool `ok` (`.indeterminate`) are
    /// treated as success and leave the placeholder green; this is intentional
    /// because every collaboration handler in this dispatch goes through
    /// `Tools+Envelope.makeSuccessResult` / `makeErrorResult`, so a non-failure
    /// envelope means the parser couldn't read it — never that the operation
    /// actually failed. Without this re-update, failed delegations /
    /// consultations / meetings render as success because the placeholder is
    /// the only thing ever persisted. `toolCallID` is `result.providerID`-
    /// independent: `providerID: String?` is the OpenAI tool_call_id used for
    /// chat correlation, NOT the row id.
    func appendCollaborationResult(
        result: ToolExecutionResult,
        toolCallID: UUID,
        roleForMessage: Role,
        stepID: String,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger?,
        conversationMessages: inout [ChatMessage]
    ) async {
        var response = ""
        var attributionRole: Role?
        var attributionContext: MessageSourceContext?

        switch result.signal {
        case .teammateConsultation(let id, let question, let context):
            response = await handleTeammateConsultation(
                stepID: stepID,
                consultedRoleID: id,
                question: question,
                context: context,
                requestingRole: roleForMessage,
                task: task,
                runIndex: runIndex,
                stepIndex: stepIndex,
                client: client,
                config: config,
                networkLogger: networkLogger
            )
            attributionRole = Role.builtInRole(for: id) ?? .custom(id: id)
            attributionContext = .consultation

        case .teamMeeting(let topic, let participants, let context):
            response = await handleTeamMeeting(
                stepID: stepID,
                topic: topic,
                participantIDs: participants,
                context: context,
                initiatingRole: roleForMessage,
                task: task,
                runIndex: runIndex,
                stepIndex: stepIndex,
                client: client,
                config: config,
                networkLogger: networkLogger
            )
            let team = resolveTeam(task: task)
            // Auto mode = initiator-as-coordinator. The meeting result is
            // attributed to the same effective coordinator the runtime used
            // for the meeting itself (designated coordinator if set,
            // otherwise the initiating role). Replaces the previous silent
            // `?? .tpm` fallback that masked misconfiguration.
            attributionRole = effectiveCoordinator(team: team, initiator: roleForMessage)
            attributionContext = .meeting

        case .changeRequest(let targetRoleID, let changes, let reasoning):
            response = await handleChangeRequest(
                stepID: stepID,
                targetRoleID: targetRoleID,
                changes: changes,
                reasoning: reasoning,
                requestingRole: roleForMessage,
                task: task,
                runIndex: runIndex,
                stepIndex: stepIndex,
                client: client,
                config: config,
                networkLogger: networkLogger
            )
            attributionRole = roleForMessage
            attributionContext = .changeRequest

        case .delegateToTeam(let teamID, let taskBrief):
            response = await handleDelegateToTeam(
                stepID: stepID,
                teamIDRaw: teamID,
                taskBrief: taskBrief,
                initiatingRole: roleForMessage,
                task: task,
                runIndex: runIndex,
                stepIndex: stepIndex,
                client: client,
                config: config,
                networkLogger: networkLogger
            )
            // No attribution turn — delegation result is the team's collective output,
            // not a single role's voice. The activity feed renders the tool call card
            // with the artifact summary; the parent's main loop sees the JSON envelope.

        case .cancelDelegation(let childTaskID, let reason):
            response = await handleCancelDelegation(
                stepID: stepID,
                childTaskID: childTaskID,
                reason: reason
            )

        case .resumeDelegation(let childTaskID):
            response = await handleResumeDelegation(
                stepID: stepID,
                childTaskID: childTaskID,
                initiatingRole: roleForMessage,
                task: task,
                client: client,
                config: config
            )

        case .forwardToTeam(let childTaskID, let message):
            response = await handleForwardToTeam(
                stepID: stepID,
                childTaskID: childTaskID,
                message: message,
                initiatingRole: roleForMessage,
                task: task,
                client: client,
                config: config
            )

        default:
            // Unhandled collaboration signal — `processToolResults` routed it
            // here but no `case` matched. The empty `response` would silently
            // pass `envelopeStatus("") == .indeterminate` (no isError flip)
            // AND ship as the tool result content to the LLM. Crash in DEBUG
            // so the missing case is loud during development; ship-build still
            // falls through.
            assertionFailure("appendCollaborationResult missing case for \(String(describing: result.signal))")
        }

        // Reflect the deferred handler's outcome onto the persisted `StepToolCall`.
        // The placeholder written in `processToolResults` had `isError: false`
        // (scheduling envelope, status `pending`); only the deferred response
        // knows whether the actual collaboration succeeded. Without this re-update,
        // failed delegations / consultations / meetings render with a green ✓.
        if envelopeStatus(response) == .failure {
            let updated = ToolExecutionResult(
                providerID: result.providerID,
                toolName: result.toolName,
                argumentsJSON: result.argumentsJSON,
                outputJSON: response,
                isError: true,
                signal: result.signal
            )
            await updateToolCallResult(stepID: stepID, toolCallID: toolCallID, result: updated)
        }

        let toolContent = buildCollaborationToolResult(toolName: result.toolName, response: response)
        conversationMessages.append(ChatMessage(
            role: .tool, content: toolContent, toolCallID: result.providerID
        ))
        let toolCallContent = """
            [CALL] \(result.toolName)
            Arguments: \(result.argumentsJSON)

            [RESULT]
            \(toolContent)
            """
        await appendLLMMessage(stepID: stepID, role: .tool, content: toolCallContent)

        if let attrRole = attributionRole, let attrContext = attributionContext {
            await appendLLMMessage(
                stepID: stepID, role: .user, content: response,
                sourceRole: attrRole, sourceContext: attrContext
            )
        }
    }

    // MARK: - Regular Tool Result Dispatch

    /// Handles a regular (non-collaboration) tool result.
    /// Supervisor questions are recorded in `outcome` but do not interrupt processing.
    @discardableResult
    func processRegularToolResult(
        result: ToolExecutionResult,
        stepID: String,
        memoryStore: MemoryTagStore,
        iterationNumber: Int,
        conversationMessages: inout [ChatMessage],
        outcome: inout ToolResultsOutcome
    ) async -> Bool {
        let tagResult = memoryStore.processToolResult(result, iteration: iterationNumber)
        let contentForConversation: String
        switch tagResult {
        case .passthrough:
            contentForConversation = result.outputJSON
        case .tagged(let content, _):
            contentForConversation = content
        case .reference(let content):
            contentForConversation = content
        }

        conversationMessages.append(
            ChatMessage(role: .tool, content: contentForConversation, toolCallID: result.providerID)
        )
        let toolCallContent = """
            [CALL] \(result.toolName)
            Arguments: \(result.argumentsJSON)

            [RESULT]
            \(result.outputJSON)
            """
        await appendLLMMessage(stepID: stepID, role: .tool, content: toolCallContent)

        // Process side effects (scratchpad, artifacts, error guidance) for ALL results,
        // including those in the same batch as a supervisor question.
        await processScratchpadResult(
            result: result,
            stepID: stepID,
            memoryStore: memoryStore,
            conversationMessages: &conversationMessages
        )
        await processCreateArtifactResult(result: result, stepID: stepID)

        if result.isError {
            let guidance = buildToolErrorGuidance(result: result)
            conversationMessages.append(ChatMessage(role: .user, content: guidance))
            await appendLLMMessage(stepID: stepID, role: .user, content: guidance)
        }

        if case .supervisorQuestion(let q) = result.signal {
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let existing = outcome.supervisorQuestion {
                    outcome.supervisorQuestion = existing + "\n\n" + trimmed
                } else {
                    outcome.supervisorQuestion = trimmed
                    outcome.supervisorToolCallProviderID = result.providerID
                }
                outcome.shouldStopForSupervisor = true
            }
        }
        return false
    }
}
