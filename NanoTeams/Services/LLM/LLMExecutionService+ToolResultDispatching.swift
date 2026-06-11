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
                taskID: task.id,
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

        // MARK: Autovisor management tools (no attribution turn — the manager's
        // own activity feed renders these; the result is a plain JSON envelope).
        case .listTasks:
            response = await handleListTasks()
        case .taskStatus(let taskID):
            response = await handleTaskStatus(taskID: taskID)
        case .createManagedTask(let title, let brief, let teamID):
            response = await handleCreateManagedTask(title: title, brief: brief, teamID: teamID)
        case .controlTask(let taskID, let verb):
            response = await handleControlTask(taskID: taskID, verb: verb)
        case .manageRole(let taskID, let roleID, let verb):
            response = await handleManageRole(taskID: taskID, roleID: roleID, verb: verb)
        case .answerTaskQuestion(let taskID, let answer):
            response = await handleAnswerTaskQuestion(taskID: taskID, answer: answer)
        case .messageTask(let taskID, let text, let roleID):
            response = await handleMessageTask(taskID: taskID, text: text, roleID: roleID)
        case .scheduleTask(let taskID, let intervalMinutes):
            response = await handleScheduleTask(taskID: taskID, intervalMinutes: intervalMinutes)
        case .setWorkFolderContext(let content):
            response = await handleSetWorkFolderContext(content: content)
        case .waitForEvents:
            response = await handleWaitForEvents(stepID: stepID, taskID: task.id)

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
        // knows the real result. Two reflect cases:
        //   • FAILURE (any signal) — flip the card green ✓ → red and surface the
        //     real error envelope, so failed delegations / consultations /
        //     meetings don't render as success.
        //   • Autovisor signals (success OR failure) — these have no other UI
        //     surface, so the card must show the real result (task list, status,
        //     etc.) instead of the `{"status":"pending"}` placeholder. Rich-UI
        //     collaboration tools (delegation / consultation / meeting) render their
        //     content in dedicated surfaces (graph delegation layers, attribution
        //     bubbles, meeting messages), so on success we intentionally leave their
        //     placeholder card untouched.
        let status = envelopeStatus(response)
        if status == .failure || Self.isAutovisorSignal(result.signal) {
            let updated = ToolExecutionResult(
                providerID: result.providerID,
                toolName: result.toolName,
                argumentsJSON: result.argumentsJSON,
                outputJSON: response,
                isError: status == .failure,
                signal: result.signal
            )
            await updateToolCallResult(stepID: stepID, taskID: task.id, toolCallID: toolCallID, result: updated)
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
        await appendLLMMessage(stepID: stepID, taskID: task.id, role: .tool, content: toolCallContent)

        if let attrRole = attributionRole, let attrContext = attributionContext {
            await appendLLMMessage(
                stepID: stepID, taskID: task.id, role: .user, content: response,
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
        taskID: Int,
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
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .tool, content: toolCallContent)

        // Process side effects (scratchpad, artifacts, error guidance) for ALL results,
        // including those in the same batch as a supervisor question.
        await processScratchpadResult(
            result: result,
            stepID: stepID,
            taskID: taskID,
            memoryStore: memoryStore,
            conversationMessages: &conversationMessages
        )
        await processCreateArtifactResult(result: result, stepID: stepID, taskID: taskID)

        if result.isError {
            let guidance = buildToolErrorGuidance(result: result)
            conversationMessages.append(ChatMessage(role: .user, content: guidance))
            await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: guidance)
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
