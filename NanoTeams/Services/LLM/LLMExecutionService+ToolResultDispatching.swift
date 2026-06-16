import Foundation

/// Extension for dispatching individual tool results: collaboration signal routing
/// (teammate consultations, meetings, change requests) and regular tool result handling
/// (scratchpad, artifacts, supervisor questions, error guidance).
extension LLMExecutionService {

    // MARK: - Collaboration Signal Dispatch

    /// Handles a collaboration tool result (ask_teammate, request_team_meeting, request_changes,
    /// delegate_to_team, cancel/resume/forward delegation, Autovisor management tools).
    ///
    /// Every signal resolves to a single `{"ok":…}` envelope, via one of two
    /// handler shapes: attribution handlers (consultation / meeting / change
    /// request) return a `CollaborationReply` (prose + outcome) that
    /// `reflectAttribution` wraps into the envelope; delegation / Autovisor
    /// handlers already return the envelope `String` directly (`reflectEnvelope`).
    /// We then reflect the real result onto the persisted `StepToolCall` card
    /// (written as a `pending` placeholder by `processToolResults`) so it stops lying:
    ///   • Attribution-bearing tools (consultation / meeting / change request)
    ///     reflect ALWAYS — green with the answer on success, red `{"ok":false}`
    ///     on failure. The answer ALSO renders as a role-attributed feed bubble,
    ///     but that bubble can be missed (or dropped when empty), so the card
    ///     must be a self-contained record.
    ///   • Delegation reflects only on FAILURE (success renders in the stacked
    ///     graph delegation layers; there is no single role's voice to attribute).
    ///   • Autovisor reflects ALWAYS (the manager's feed is its only surface).
    /// The LLM tool message is the same single envelope (no double-wrapping).
    ///
    /// Durability: the card reflect, the persisted tool message, and the
    /// attribution bubble are committed in ONE atomic `mutateTask`
    /// (`commitCollaborationOutcome`) gated by a single `isExecutionLive` check,
    /// so a teardown can't leave the answer half-written. `toolCallID` is the
    /// persisted row id (NOT `result.providerID`, the OpenAI tool_call_id).
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
        // The single `{"ok":…}` envelope shown to the LLM and (when reflected)
        // the card. `cardJSON == nil` leaves the `pending` placeholder untouched
        // (delegation success → graph layers). Attribution-bearing tools also
        // carry `bubbleText` + `attributionRole`/`attributionContext` for the feed bubble.
        var llmEnvelope = ""
        var cardJSON: String?
        var cardIsError = false
        var attributionRole: Role?
        var attributionContext: MessageSourceContext?
        var bubbleText: String?

        // Attribution-bearing handlers return prose + success flag; wrap into a
        // single success/failure envelope used for BOTH the card and the LLM.
        func reflectAttribution(_ reply: CollaborationReply, role: Role, context: MessageSourceContext) {
            let env = reply.succeeded
                ? buildCollaborationToolResult(toolName: result.toolName, response: reply.text)
                : buildCollaborationErrorResult(toolName: result.toolName, message: reply.text)
            llmEnvelope = env
            cardJSON = env
            cardIsError = !reply.succeeded
            bubbleText = reply.text
            attributionRole = role
            attributionContext = context
        }

        // Delegation / Autovisor handlers already return a `{"ok":…}` envelope —
        // use it directly (no double-wrap). Autovisor reflects always (its only
        // surface); delegation reflects only on failure (success → graph layers).
        func reflectEnvelope(_ env: String) {
            llmEnvelope = env
            let isFailure = envelopeStatus(env) == .failure
            if Self.isAutovisorSignal(result.signal) {
                cardJSON = env
                cardIsError = isFailure
            } else if isFailure {
                cardJSON = env
                cardIsError = true
            }
        }

        switch result.signal {
        case .teammateConsultation(let id, let question, let context):
            let reply = await handleTeammateConsultation(
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
            reflectAttribution(reply, role: Role.builtInRole(for: id) ?? .custom(id: id), context: .consultation)

        case .teamMeeting(let topic, let participants, let context):
            let reply = await handleTeamMeeting(
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
            // Auto mode = initiator-as-coordinator. The meeting result is
            // attributed to the same effective coordinator the runtime used
            // for the meeting itself (designated coordinator if set,
            // otherwise the initiating role).
            reflectAttribution(reply, role: effectiveCoordinator(team: resolveTeam(task: task), initiator: roleForMessage), context: .meeting)

        case .changeRequest(let targetRoleID, let changes, let reasoning):
            let reply = await handleChangeRequest(
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
            reflectAttribution(reply, role: roleForMessage, context: .changeRequest)

        case .delegateToTeam(let teamID, let taskBrief):
            reflectEnvelope(await handleDelegateToTeam(
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
            ))

        case .cancelDelegation(let childTaskID, let reason):
            reflectEnvelope(await handleCancelDelegation(
                stepID: stepID,
                taskID: task.id,
                childTaskID: childTaskID,
                reason: reason
            ))

        case .resumeDelegation(let childTaskID):
            reflectEnvelope(await handleResumeDelegation(
                stepID: stepID,
                childTaskID: childTaskID,
                initiatingRole: roleForMessage,
                task: task,
                client: client,
                config: config
            ))

        case .forwardToTeam(let childTaskID, let message):
            reflectEnvelope(await handleForwardToTeam(
                stepID: stepID,
                childTaskID: childTaskID,
                message: message,
                initiatingRole: roleForMessage,
                task: task,
                client: client,
                config: config
            ))

        // MARK: Autovisor management tools (no attribution turn — the manager's
        // own activity feed renders these; the result is a plain JSON envelope).
        case .listTasks:
            reflectEnvelope(await handleListTasks())
        case .taskStatus(let taskID):
            reflectEnvelope(await handleTaskStatus(taskID: taskID))
        case .createManagedTask(let title, let brief, let teamID):
            reflectEnvelope(await handleCreateManagedTask(title: title, brief: brief, teamID: teamID))
        case .controlTask(let taskID, let verb):
            reflectEnvelope(await handleControlTask(taskID: taskID, verb: verb))
        case .manageRole(let taskID, let roleID, let verb):
            reflectEnvelope(await handleManageRole(taskID: taskID, roleID: roleID, verb: verb))
        case .answerTaskQuestion(let taskID, let answer):
            reflectEnvelope(await handleAnswerTaskQuestion(taskID: taskID, answer: answer))
        case .messageTask(let taskID, let text, let roleID):
            reflectEnvelope(await handleMessageTask(taskID: taskID, text: text, roleID: roleID))
        case .scheduleTask(let taskID, let intervalMinutes):
            reflectEnvelope(await handleScheduleTask(taskID: taskID, intervalMinutes: intervalMinutes))
        case .setWorkFolderContext(let content):
            reflectEnvelope(await handleSetWorkFolderContext(content: content))
        case .waitForEvents:
            reflectEnvelope(await handleWaitForEvents(stepID: stepID, taskID: task.id))

        default:
            // Unhandled collaboration signal — `processToolResults` routed it
            // here but no `case` matched (the routing predicate drifted from this
            // switch). Crash in DEBUG so the missing case is loud during
            // development; in release, fail loudly with an honest `{ok:false}`
            // envelope (red card + clear LLM signal) instead of shipping a blank
            // tool result.
            assertionFailure("appendCollaborationResult missing case for \(String(describing: result.signal))")
            reflectEnvelope(buildCollaborationErrorResult(
                toolName: result.toolName, message: "Unhandled collaboration signal."))
        }

        // In-memory tool result for THIS live iteration — unconditional so the
        // assistant tool_call always has a matching tool result (chain protocol).
        conversationMessages.append(ChatMessage(
            role: .tool, content: llmEnvelope, toolCallID: result.providerID
        ))

        // Durable persistence: card reflect + persisted tool message + attribution
        // bubble in one atomic mutateTask, gated by a single isExecutionLive check.
        await commitCollaborationOutcome(
            stepID: stepID,
            taskID: task.id,
            toolCallID: toolCallID,
            toolName: result.toolName,
            argumentsJSON: result.argumentsJSON,
            llmEnvelope: llmEnvelope,
            cardJSON: cardJSON,
            cardIsError: cardIsError,
            attributionRole: attributionRole,
            attributionContext: attributionContext,
            bubbleText: bubbleText
        )
    }

    /// Commits a collaboration outcome's three feed surfaces — the reflected card
    /// (`StepToolCall.resultJSON`/`isError`), the persisted `[CALL]…[RESULT]` tool
    /// message, and the optional role-attributed bubble — in ONE atomic
    /// `mutateTask`, gated by a single `isExecutionLive` check. Coalescing avoids a
    /// partial-persist window where a teardown lands between separate writes (the
    /// answer half-shown). It does NOT change the `isExecutionLive` barrier itself.
    private func commitCollaborationOutcome(
        stepID: String,
        taskID: Int,
        toolCallID: UUID,
        toolName: String,
        argumentsJSON: String,
        llmEnvelope: String,
        cardJSON: String?,
        cardIsError: Bool,
        attributionRole: Role?,
        attributionContext: MessageSourceContext?,
        bubbleText: String?
    ) async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }

        // Build cleaned/guarded messages outside the closure (same Harmony-token
        // cleaning + non-empty guard as `appendLLMMessage`).
        let toolCallContent = ConversationRepairService.cleanHarmonyTokens("""
            [CALL] \(toolName)
            Arguments: \(argumentsJSON)

            [RESULT]
            \(llmEnvelope)
            """)
        let toolMsg = toolCallContent.isEmpty
            ? nil
            : LLMMessage(role: .tool, content: toolCallContent)

        var bubbleMsg: LLMMessage?
        if let attributionRole, let attributionContext, let bubbleText {
            let cleaned = ConversationRepairService.cleanHarmonyTokens(bubbleText)
            if !cleaned.isEmpty {
                bubbleMsg = LLMMessage(
                    role: .user, content: cleaned,
                    sourceRole: attributionRole, sourceContext: attributionContext
                )
            }
        }

        await delegate.mutateTask(taskID: taskID) { task in
            if let cardJSON {
                TaskMutationService.updateToolCallResult(
                    toolCallID: toolCallID,
                    resultJSON: cardJSON,
                    isError: cardIsError,
                    stepID: stepID,
                    argumentsJSON: argumentsJSON,
                    in: &task
                )
            }
            if let toolMsg { TaskMutationService.appendLLMMessage(toolMsg, to: stepID, in: &task) }
            if let bubbleMsg { TaskMutationService.appendLLMMessage(bubbleMsg, to: stepID, in: &task) }
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
