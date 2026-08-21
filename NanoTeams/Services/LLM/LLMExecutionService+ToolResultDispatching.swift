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
    ///   • Delegation reflects ALWAYS. It used to reflect only on FAILURE, on the
    ///     grounds that success "renders in the stacked graph delegation layers" —
    ///     false at exactly the moment it matters: every terminal arm calls
    ///     `clearDelegationFields` BEFORE returning its envelope, and
    ///     `GraphPanelView.resolveDelegationLayers()` gates on
    ///     `activeDelegationChildID != nil`, so those layers disappear the instant the
    ///     delegation resolves. The real envelope then survived only as a `.tool`
    ///     message, which `ActivityFeedBuilder` filters out — while that same builder
    ///     deliberately suppresses the child's own supervisor brief BECAUSE this card is
    ///     supposed to stand in for it. Net: a finished delegation left no durable
    ///     human-visible record, and the one card claiming to be that record still read
    ///     `"status":"pending"`, green, forever.
    ///   • Autovisor reflects ALWAYS (the manager's feed is its only surface).
    /// The LLM tool message is the same single envelope (no double-wrapping).
    ///
    /// Returns the RESOLVED `isError`. The synchronous placeholder every deferred handler
    /// emits is green, so a caller that keeps the placeholder's flag believes a turn whose
    /// every call failed was productive — which re-arms `maxNonProductiveTurns`, the only
    /// shape-independent unbounded-loop guard the Autovisor has.
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
    ) async -> Bool {
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
            cardJSON = env
            cardIsError = envelopeStatus(env) == .failure
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
        return cardIsError
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
    /// Splices the parser's argument-repair note onto the tool result the model reads.
    ///
    /// Rides the RESULT rather than a separate `.user` turn on purpose: a turn would grow
    /// the prompt prefix every time the defect recurs, and the result is already on its
    /// way to the model. Placed AFTER the tagging switch so it survives both the tagged
    /// and passthrough paths — `MemoryTagStore` rebuilds some envelopes from scratch, so
    /// anything spliced before it would be discarded.
    ///
    /// Emitted as a JSON member when the result is a JSON object (the normal case) so it
    /// reads as part of the envelope rather than as loose prose the model might echo back.
    nonisolated static func appendingRepairNote(_ note: String?, to content: String) -> String {
        guard let note, !note.isEmpty else { return content }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let escaped = ToolCallParsingHelpers.stableJSONString(from: ["format_note": note]),
              let openingBrace = escaped.firstIndex(of: "{")
        else {
            return content + "\nformat_note: " + note
        }
        // `{"format_note":"…"}` → `,"format_note":"…"` spliced before the closing brace,
        // so Foundation owns the escaping of a note that will contain backticks and
        // whatever key names the model invented.
        let member = escaped[
            escaped.index(after: openingBrace)..<escaped.index(before: escaped.endIndex)]
        let body = trimmed.dropFirst().dropLast()
        // An empty envelope takes no separator, or the result is `{,"format_note":…}`.
        let separator = body.allSatisfy(\.isWhitespace) ? "" : ","
        return "{" + body + separator + member + "}"
    }

    /// Supervisor questions are recorded in `outcome` but do not interrupt processing.
    @discardableResult
    func processRegularToolResult(
        result: ToolExecutionResult,
        argumentRepairNote: String? = nil,
        stepID: String,
        taskID: Int,
        memoryStore: MemoryTagStore,
        conversationMessages: inout [ChatMessage],
        outcome: inout ToolResultsOutcome
    ) async -> Bool {
        let tagResult = memoryStore.processToolResult(result)
        let contentForConversation: String
        switch tagResult {
        case .passthrough:
            contentForConversation = result.outputJSON
        case .tagged(let content, _):
            contentForConversation = content
        }

        conversationMessages.append(
            ChatMessage(
                role: .tool,
                content: Self.appendingRepairNote(argumentRepairNote, to: contentForConversation),
                toolCallID: result.providerID)
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
            conversationMessages: &conversationMessages
        )
        await processCreateArtifactResult(result: result, stepID: stepID, taskID: taskID)

        // Conditional, and `nil` is the common case for `edit_file`: the envelope is the
        // preceding turn, so a direction that only restates it costs context and teaches
        // nothing (`ToolErrorNotePolicy`).
        if result.isError, let guidance = ToolErrorNotePolicy.direction(for: result) {
            conversationMessages.append(ChatMessage(role: .user, content: guidance))
            // Persisted despite being invisible, and that is not belt-and-braces — two
            // consumers read the display record rather than the wire:
            // `ConversationReplay.rebuildFromDisplayRecord` (the `wireTranscript`-less
            // fallback, which would otherwise re-show the model its failed call with the
            // steering stripped) and `DelegatedSupervisorAnswerService.buildSeed`, which drops
            // `.tool` turns outright — making this the only surviving evidence in that seed
            // that a call failed at all.
            //
            // Deliberately NOT the `.retryNudge` the eight `handleNoToolCalls` sites carry.
            // Those follow a bare assistant turn, and the loop warning spans SEVERAL cards;
            // nothing else on screen records either, so their rows are the whole point. The
            // discriminator is origin, not position: does this comment on one event the feed
            // already draws? Same question, same answer, same wording as the screenshot turn
            // in `+ComputerUse` — a second, less informative entry for one event.
            //
            // feed-invisible-by-design: this comments on ONE event the feed already draws —
            // the failed call's own card. Every arm that still emits is a constant keyed on
            // the error CODE, so the row restated the red line directly above it.
            await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: guidance)
        }

        if case .supervisorQuestion(let q) = result.signal {
            Self.accumulateSupervisorQuestion(q, providerID: result.providerID, into: &outcome)
        }
        return false
    }

    /// Folds one `ask_supervisor` call into the batch's pending question.
    ///
    /// Extracted because it was previously inline here and RE-IMPLEMENTED in
    /// `SupervisorQuestionMergeTests` — so the suite that guards the merge was exercising a copy,
    /// and could not have caught the provider-id defect this fix closes.
    ///
    /// Empty and whitespace-only questions are dropped rather than merged: the dispatcher would
    /// otherwise park the step on a blank question that `activeSupervisorQuestions` then has to
    /// invent a placeholder for.
    nonisolated static func accumulateSupervisorQuestion(
        _ question: String, providerID: String?, into outcome: inout ToolResultsOutcome
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = outcome.supervisorQuestion {
            outcome.supervisorQuestion = existing + "\n\n" + trimmed
        } else {
            outcome.supervisorQuestion = trimmed
        }
        if let providerID { outcome.supervisorToolCallProviderIDs.append(providerID) }
        outcome.shouldStopForSupervisor = true
    }
}
