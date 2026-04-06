import Foundation

/// Extension for dispatching individual tool results: collaboration signal routing
/// (teammate consultations, meetings, change requests) and regular tool result handling
/// (scratchpad, artifacts, supervisor questions, error guidance).
extension LLMExecutionService {

    // MARK: - Collaboration Signal Dispatch

    /// Handles a collaboration tool result (ask_teammate, request_team_meeting, request_changes).
    func appendCollaborationResult(
        result: ToolExecutionResult,
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
            let coordinatorRoleID = team?.settings.meetingCoordinatorRoleID
                ?? team?.roles.first(where: { !$0.isSupervisor })?.id
            attributionRole = coordinatorRoleID.flatMap { id in
                if let systemRoleID = team?.roles.first(where: { $0.id == id })?.systemRoleID {
                    return Role.builtInRole(for: systemRoleID)
                }
                return .custom(id: id)
            } ?? .tpm
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

        default:
            break
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
