import Foundation

/// Routes a delegated child team's `ask_supervisor` question back to the parent role
/// that called `delegate_to_team`, using a **seeded stateful chain** scoped to the
/// active delegation.
///
/// First question: seeds a fresh chain with the parent step's accumulated
/// `llmConversation` (so the parent answers from its full context). Subsequent
/// questions in the same delegation reuse the stored `parentStep.delegationSession`
/// via `previous_response_id`, growing one stateful chain per delegation.
///
/// The seeded chain is **isolated** from the parent's main response chain — the
/// side exchange does not perturb parent's main `llmSessionID`. This is required
/// for chain protocol safety: the parent's main chain has an unresolved
/// `delegate_to_team` tool call; injecting unrelated user/assistant turns there
/// would invalidate it. See plan file for the full rationale.
@MainActor
enum DelegatedSupervisorAnswerService {

    /// Single-question entry point.
    ///
    /// Reads the child team's pending `supervisorQuestion`, routes it to the parent
    /// role for an answer (potentially via escalation up the delegation chain), and
    /// delivers the final answer back to the child via `delegate.answerSupervisorQuestion`.
    ///
    /// Returns `true` iff the child step was successfully answered. Returns `false`
    /// on internal failure (missing context, LLM error, top-of-chain abort) — the caller
    /// (`handleDelegateToTeam`) then aborts the delegation.
    static func handleChildQuestion(
        childTID: Int,
        parentTaskID: Int,
        parentRoleID: String,
        parentTeam: Team,
        targetTeamName: String,
        client: any LLMClient,
        globalConfig: LLMConfig,
        delegate: any LLMStateDelegate
    ) async -> Bool {
        // 1. Read pending question from child's last step.
        // The child's `ask_supervisor` flow set this via `setNeedsSupervisorInput`.
        guard let childTask = delegate.loadedTask(childTID),
              let childRun = childTask.runs.last
        else {
            return false
        }
        guard let askingStep = childRun.steps.first(where: { $0.needsSupervisorInput && $0.supervisorQuestion != nil }),
              let question = askingStep.supervisorQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty
        else {
            return false
        }

        // 2. Ask the parent role (potentially recursing up the chain on escalation).
        // The recursive helper returns the final plain-text answer from whichever
        // role bottoms out the chain, or `nil` if escalation aborted at the top.
        guard let answer = await askSupervisorRole(
            question: question,
            taskID: parentTaskID,
            roleID: parentRoleID,
            roleTeam: parentTeam,
            targetTeamName: targetTeamName,
            client: client,
            globalConfig: globalConfig,
            delegate: delegate
        ) else { return false }

        // 3. Deliver the answer back to the child step. answerSupervisorQuestion
        // also resumes the engine so the child step exits `.needsSupervisorInput`.
        return await delegate.answerSupervisorQuestion(
            taskID: childTID,
            stepID: askingStep.id,
            answer: answer
        )
    }

    /// Recursive helper: poses `question` to the role identified by `(taskID, roleID)`
    /// using its seeded delegation chain. Returns the role's plain-text answer, or
    /// recurses to the role's own supervisor if the role escalates via `ask_supervisor`.
    /// Returns `nil` if the chain bottoms out at the human Supervisor (top-level task)
    /// — V1 surfaces a banner and aborts.
    private static func askSupervisorRole(
        question: String,
        taskID: Int,
        roleID: String,
        roleTeam: Team,
        targetTeamName: String,
        client: any LLMClient,
        globalConfig: LLMConfig,
        delegate: any LLMStateDelegate
    ) async -> String? {
        // Locate the role's step and resolve its effective LLM config.
        guard let task = delegate.loadedTask(taskID),
              let run = task.runs.last,
              let step = run.steps.first(where: { $0.id == roleID })
        else {
            return nil
        }
        let roleDef = roleTeam.findRole(byIdentifier: roleID)
        let effectiveConfig = LLMExecutionService.buildEffectiveConfig(
            globalConfig: globalConfig,
            roleOverride: roleDef?.llmOverride
        )

        // 3. Build messages for the side exchange:
        //    - First question (delegationSession == nil): seed with full parent llmConversation + new user turn.
        //    - Subsequent question: only the new user turn; previous_response_id chain carries history.
        let questionTurn = ChatMessage(
            role: .user,
            content: """
                Delegated team «\(targetTeamName)» asks:
                \(question)

                Answer briefly. If outside your scope, say so and the system will escalate.
                """
        )

        let messagesToSend: [ChatMessage]
        let session: LLMSession?
        if let existingSessionID = step.delegationSession {
            session = LLMSession(responseID: existingSessionID)
            messagesToSend = [questionTurn]
        } else {
            session = nil
            // Seed with the role's accumulated llmConversation.
            //
            // Chain-protocol safety (CLAUDE.md §LLM #2 — `input` in stateful
            // mode must only contain `function_call_output` tool results
            // and `user` messages): `LLMMessage` does NOT persist
            // `tool_call_id` / `tool_calls` (they're stripped at
            // `LLMExecutionService+ConversationManagement.persistConversation`),
            // so any `tool`-role message in the persisted history is an
            // orphan tool result without its binding `tool_call_id` —
            // sending it would cause the server to reject the seeded
            // chain. We also drop the legacy `developer` role (CLAUDE.md
            // §LLM #3 invariant — would corrupt the response chain on LM
            // Studio). System prompt and plain user/assistant text turns
            // are kept; the system prompt persists server-side once the
            // seeded chain is established (NativeLMStudioClient omits
            // system_prompt on continuations).
            let seed: [ChatMessage] = step.llmConversation.compactMap { llm in
                guard let role = MessageRole(rawValue: llm.role.rawValue) else { return nil }
                if role == .tool { return nil }
                return ChatMessage(role: role, content: llm.content)
            }
            messagesToSend = seed + [questionTurn]
        }

        // Stream the side exchange.
        //
        // On failure we MUST surface the underlying cause to the UI banner.
        // Bare `return nil` swallows 401 (auth), HTTP 400 (which would normally
        // drive stateless fallback per CLAUDE.md §LLM session invariants),
        // model-unloaded, transport failures, and JSON parse errors — the
        // caller (`handleDelegateToTeam`) then surfaces a generic "Failed to
        // answer the delegated team's question" with no diagnostic.
        //
        // For 400 specifically: the seeded chain has been invalidated (often
        // because the seed contains an unresolved tool_call). Retry once
        // statelessly so the seeded-chain is re-established with no stale
        // `previous_response_id`.
        var captured: (content: String, toolCalls: [StepToolCall], session: LLMSession?) = ("", [], nil)
        var accumulator = ToolCallAccumulator()
        var stateless = false
        for attempt in 0..<2 {
            captured = ("", [], nil)
            accumulator = ToolCallAccumulator()
            let attemptSession: LLMSession? = stateless ? nil : session
            let attemptMessages: [ChatMessage] = stateless
                ? Self.rebuildStatelessSeed(step: step, questionTurn: questionTurn)
                : messagesToSend
            do {
                let stream = client.streamChat(
                    config: effectiveConfig,
                    messages: attemptMessages,
                    tools: [AskSupervisorTool.schema],
                    session: attemptSession,
                    logger: nil,
                    stepID: nil
                )
                for try await event in stream {
                    captured.content += event.contentDelta
                    if !event.toolCallDeltas.isEmpty {
                        accumulator.absorb(event.toolCallDeltas)
                    }
                    if let s = event.session {
                        captured.session = s
                    }
                }
                captured.toolCalls = accumulator.finalize()
                break
            } catch {
                if attempt == 0,
                   Self.shouldRetryStateless(error: error),
                   session != nil {
                    // First attempt failed with HTTP 400 (or equivalent
                    // chain-protocol invalidation). Drop the seeded-chain
                    // session id and rebuild from full conversation.
                    stateless = true
                    continue
                }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                delegate.setLastErrorMessageForUI(
                    "Delegated supervisor answer failed for role \(roleID): \(reason)"
                )
                return nil
            }
        }
        if stateless {
            // Seeded chain was discarded — clear the persisted session so the
            // next question seeds a fresh chain.
            await delegate.mutateTask(taskID: taskID) { task in
                guard let runIdx = task.runs.indices.last,
                      let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.id == roleID })
                else { return }
                task.runs[runIdx].steps[stepIdx].setDelegationSession(nil)
            }
        }

        // Persist updated delegation session id so the next question in this
        // delegation continues the chain.
        if let newSession = captured.session {
            await delegate.mutateTask(taskID: taskID) { task in
                guard let runIdx = task.runs.indices.last,
                      let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.id == roleID })
                else { return }
                task.runs[runIdx].steps[stepIdx].setDelegationSession(newSession.responseID)
            }
        }

        // Persist (question, answer) pair to the role's llmConversation for UI.
        await persistExchange(
            parentTaskID: taskID,
            parentRoleID: roleID,
            question: question,
            response: captured,
            delegate: delegate
        )

        // Plain text answer or escalation?
        if let escalation = captured.toolCalls.first(where: { $0.name == ToolNames.askSupervisor }) {
            let escalatedQuestion = extractQuestion(from: escalation.argumentsJSON) ?? question

            // Recurse to the role's own supervisor in the chain (if any).
            if let grandparentTID = task.parentTaskID,
               let grandparentRoleID = task.parentRoleID,
               let grandparentTask = delegate.loadedTask(grandparentTID),
               let grandparentTeamRef = resolveTeam(task: grandparentTask, delegate: delegate)
            {
                return await askSupervisorRole(
                    question: escalatedQuestion,
                    taskID: grandparentTID,
                    roleID: grandparentRoleID,
                    roleTeam: grandparentTeamRef,
                    targetTeamName: roleTeam.name,
                    client: client,
                    globalConfig: globalConfig,
                    delegate: delegate
                )
            } else {
                // V1: bottom-of-chain escalation has no UI surface yet — the activity
                // feed doesn't render `ancillaryQuestion` cards (V2 follow-up). Persist
                // the question on `step.ancillaryQuestion` for diagnostics, surface a
                // banner, and return nil so the original handler aborts the delegation
                // with a clear envelope.
                await delegate.mutateTask(taskID: taskID) { task in
                    guard let runIdx = task.runs.indices.last,
                          let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.id == roleID })
                    else { return }
                    task.runs[runIdx].steps[stepIdx].setAncillaryQuestion(escalatedQuestion)
                }
                delegate.setLastInfoMessageForUI(
                    "Delegated team escalated a question that requires Supervisor input. The delegation was aborted; the question is recorded on the step's ancillary log."
                )
                return nil
            }
        }

        // Plain-text answer path.
        let answerText = captured.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return answerText.isEmpty ? "(no answer provided)" : answerText
    }

    /// Persists the (question, answer) pair to the parent step's llmConversation
    /// so the activity feed renders the side exchange. The escalation case is
    /// tagged with `.delegationEscalation`; the plain-answer case uses
    /// `.delegatedQuestion`.
    private static func persistExchange(
        parentTaskID: Int,
        parentRoleID: String,
        question: String,
        response: (content: String, toolCalls: [StepToolCall], session: LLMSession?),
        delegate: any LLMStateDelegate
    ) async {
        let isEscalation = response.toolCalls.contains(where: { $0.name == ToolNames.askSupervisor })
        let questionContext: MessageSourceContext = isEscalation ? .delegationEscalation : .delegatedQuestion
        let questionMessage = LLMMessage(
            role: .user,
            content: question,
            sourceRole: nil,
            sourceContext: questionContext
        )
        let answerContent: String
        if isEscalation {
            answerContent = "(escalated to supervisor)"
        } else {
            answerContent = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let answerMessage = LLMMessage(
            role: .assistant,
            content: answerContent,
            sourceRole: nil,
            sourceContext: nil
        )
        await delegate.mutateTask(taskID: parentTaskID) { task in
            guard let runIdx = task.runs.indices.last,
                  let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.id == parentRoleID })
            else { return }
            task.runs[runIdx].steps[stepIdx].llmConversation.append(questionMessage)
            task.runs[runIdx].steps[stepIdx].llmConversation.append(answerMessage)
        }
    }

    /// Returns `true` when an LLM streaming error is the kind that should
    /// drive a stateless retry (HTTP 400 = chain invalidated; transport
    /// errors are NOT retried statelessly because they're symmetric across
    /// session vs no-session).
    static func shouldRetryStateless(error: Error) -> Bool {
        if let llmErr = error as? LLMClientError {
            switch llmErr {
            case .badHTTPStatus(let code, _) where code == 400:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Builds a fresh stateless seed from the step's persisted conversation
    /// when the seeded chain was rejected. Mirrors the chain-protocol-safe
    /// filtering used by the initial-seed branch (drops orphan `tool`-role
    /// messages whose `tool_call_id` was lost on persistence).
    static func rebuildStatelessSeed(step: StepExecution, questionTurn: ChatMessage) -> [ChatMessage] {
        let seed: [ChatMessage] = step.llmConversation.compactMap { llm in
            guard let role = MessageRole(rawValue: llm.role.rawValue) else { return nil }
            if role == .tool { return nil }
            return ChatMessage(role: role, content: llm.content)
        }
        return seed + [questionTurn]
    }

    /// Best-effort extraction of the question text from an `ask_supervisor`
    /// tool call's arguments JSON. Falls back to `nil` so the caller can use
    /// the original question as the escalation payload.
    private static func extractQuestion(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = obj["question"] as? String
        else { return nil }
        return q
    }

    /// Resolves the team for a task using the same priority as
    /// `TaskEngineStoreAdapter.resolvedTeam` / `LLMExecutionService.resolveTeam`:
    /// `generatedTeam` slot first, then `preferredTeamID` lookup against the
    /// project's stored teams. Returns `nil` only when neither resolves.
    private static func resolveTeam(task: NTMSTask, delegate: any LLMStateDelegate) -> Team? {
        if let generated = task.generatedTeam { return generated }
        if let preferredID = task.preferredTeamID,
           let team = delegate.snapshot?.workFolder.team(withID: preferredID)
        {
            return team
        }
        return delegate.snapshot?.workFolder.activeTeam
    }
}
