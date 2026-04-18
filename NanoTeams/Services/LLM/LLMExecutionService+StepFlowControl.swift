import Foundation

/// Extension for step flow control: no-tool-call handling and planning phase management.
extension LLMExecutionService {

    /// True when the step has a pending supervisor-feedback revision. Reads the
    /// freshest task from the delegate so mid-iteration mutations are observed.
    func isStepInRevision(stepID: String) -> Bool {
        guard let delegate, let tid = taskIDForStep(stepID),
              let t = delegate.loadedTask(tid),
              let ri = t.runs.indices.last,
              let s = t.runs[ri].steps.first(where: { $0.id == stepID })
        else { return false }
        return s.revisionComment != nil
    }

    // MARK: - No-Tool-Call Handling

    /// Handles the case where the LLM produced no tool calls.
    /// Always returns `.continueLoop` — roles never self-terminate here.
    /// Producing roles get artifact-missing reminders; other roles get tool-use nudges.
    func handleNoToolCalls(
        stepID: String,
        result: StreamingResult,
        roleForMessage: Role,
        task _: NTMSTask,
        runIndex _: Int,
        stepIndex _: Int,
        memory _: ToolCallCache,
        roleDefinition: TeamRoleDefinition?,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop {
        // Loop detection runs first — once the supervisor is asked (or the nudge
        // fires), the other branches are moot. Skipped during revision because
        // the supervisor is already driving.
        if !isStepInRevision(stepID: stepID) {
            switch ConversationRepairService.detectMessageLoop(conversationMessages: conversationMessages) {
            case .refusalLoop(let count, let sample):
                let snippet = String(sample.prefix(300))
                let question = """
                Role \(roleForMessage.displayName) emitted \(count) consecutive refusal messages without \
                calling any tools. The model appears stuck — please advise how to proceed (answer the \
                underlying need, provide explicit instructions, or mark the step failed).

                Last message excerpt:
                \(snippet)
                """
                await setNeedsSupervisorInput(stepID: stepID, question: question, sessionID: nil)
                return .needsSupervisorInput(question: question)

            case .repetitiveNonTool(let count):
                let retryMessage = """
                Your last \(count) responses were near-identical and contained no tool calls. \
                If you've finished your work, call create_artifact to submit your deliverable. \
                If you're blocked, call ask_supervisor with a specific question. \
                Do not repeat this response again — take a concrete action.
                """
                conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
                return .continueLoop

            case .noLoop:
                break
            }
        }

        // Harmony markers were detected but parsing failed — the model attempted a tool
        // call with broken JSON (most commonly a missing closing brace). Give targeted
        // feedback so it can self-correct. Must be checked BEFORE the generic "only tokens"
        // branch: the pre-marker text is usually just whitespace, which would otherwise
        // match the tokens-only case and send a misleading retry message.
        if result.sawHarmonyMarker {
            let retryMessage = "Your previous tool call had malformed JSON and could not be parsed (e.g. a missing closing brace `}`, an unescaped quote inside a string, or a trailing comma). Retry with valid JSON, e.g. `<|call|>{\"name\":\"TOOL_NAME\",\"arguments\":{…}}<|end|>` — note the two closing braces before `<|end|>`."
            conversationMessages.append(
                ChatMessage(role: .user, content: retryMessage)
            )
            await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
            return .continueLoop
        }

        // Check if content contains only model tokens (Issue #24, #32)
        let originalContent = result.assistantContent
        let cleanedContent = ModelTokenCleaner.clean(originalContent)

        if !originalContent.isEmpty && cleanedContent.isEmpty {
            // Content was entirely garbled tokens with no substantive text
            let retryMessage = "Your previous response contained only model-internal tokens (<|...|>) with no actual content. Please provide a substantive response with proper tool calls or completion message."
            conversationMessages.append(
                ChatMessage(role: .user, content: retryMessage)
            )
            await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
            return .continueLoop
        }

        // Planning phase fallback: the model emitted prose instead of calling
        // update_scratchpad. Persist the prose as the implicit plan so the next
        // iteration's applyPlanningPhase sees a non-nil scratchpad and transitions
        // to implementation. The user nudge is required — without it, the next
        // stateful continuation would send `{"input":""}` and LM Studio rejects
        // with HTTP 400.
        if let systemMsg = conversationMessages.first(where: { $0.role == .system }),
           systemMsg.content?.contains("PLANNING PHASE") == true {
            let plan = cleanedContent.isEmpty ? "(no plan provided)" : cleanedContent
            if let tid = taskIDForStep(stepID), let delegate {
                _ = await delegate.mutateTask(taskID: tid) { task in
                    guard let runIndex = task.runs.indices.last,
                          let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
                    else { return }
                    if task.runs[runIndex].steps[stepIndex].scratchpad == nil {
                        task.runs[runIndex].steps[stepIndex].scratchpad = plan
                    }
                }
            }
            let nudge = "Plan recorded from your text response. Now proceeding to IMPLEMENTATION PHASE — execute your plan using your full toolset."
            conversationMessages.append(ChatMessage(role: .user, content: nudge))
            await appendLLMMessage(stepID: stepID, role: .user, content: nudge)
            return .continueLoop
        }

        // Producing role — retry if artifacts missing, complete if all present
        if let roleDef = roleDefinition {
            let expected = roleDef.dependencies.producesArtifacts.filter { $0 != ArtifactConstants.buildDiagnosticsName }
            if !expected.isEmpty {
                // Producing role — check artifact completeness
                if let artifactStop = checkArtifactCompleteness(stepID: stepID) {
                    return artifactStop
                }

                if isStepInRevision(stepID: stepID) {
                    let retryMessage = "Please address the supervisor's feedback and submit updated artifacts via create_artifact."
                    conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                    await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
                    return .continueLoop
                }

                // Missing artifacts — retry. Names must be quoted and verbatim;
                // extensions / prefixes / rewordings cause name-resolution misses.
                let quoted = expected.map { "\"\($0)\"" }.joined(separator: ", ")
                let retryMessage = "You haven't submitted all expected artifacts yet. Missing deliverables: \(quoted). Call create_artifact(name=\"<exact name from quotes>\", content=\"...\") for each. Do NOT add file extensions (.md), prefixes, or rewordings — use the quoted name verbatim."
                conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
                await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
                return .continueLoop
            }
        }

        // No tool calls and no artifacts to produce — nudge to use tools.
        // Roles never self-terminate here; only artifact completion or Supervisor's "Finish Role" ends a step.
        let retryMessage = "You responded with text but did not call any tools. Use your available tools to continue working. If you need input from the Supervisor, call ask_supervisor."
        conversationMessages.append(ChatMessage(role: .user, content: retryMessage))
        await appendLLMMessage(stepID: stepID, role: .user, content: retryMessage)
        return .continueLoop
    }

    // MARK: - Planning Phase

    /// Applies planning phase modifications to conversation and tools for the first iteration.
    /// Returns the tool set to use for this iteration.
    /// Returns `(tools, resetSession)`. When `resetSession` is `true`, the caller must clear
    /// the stateful session so the next LLM call sends the full (restored) system prompt,
    /// establishing it in a fresh response chain.
    func applyPlanningPhase(
        stepID: String,
        roleForMessage: Role,
        tools: [ToolSchema],
        step: StepExecution,
        memory: ToolCallCache,
        conversationMessages: inout [ChatMessage],
        roleDefinition: TeamRoleDefinition?
    ) async -> (tools: [ToolSchema], resetSession: Bool) {
        let usePlanningPhase = roleDefinition?.usePlanningPhase ?? true
        let isFirstIteration = step.scratchpad == nil && memory.recentCalls(limit: 1).isEmpty
        let hasPriorConversation = !step.llmConversation.isEmpty
        let hasScratchpadTool = tools.contains { $0.name == ToolNames.updateScratchpad }

        if usePlanningPhase && isFirstIteration && hasScratchpadTool {
            // Save original system prompt before replacing
            if let systemMsg = conversationMessages.first(where: { $0.role == .system }) {
                executionStates[stepID]?.originalSystemPrompt = systemMsg.content
            }

            let planningSystemPrompt = """
            You are \(roleForMessage.displayName).

            PLANNING PHASE
            ==============
            Before starting work, create your plan.

            Call update_scratchpad(content: "...") with a numbered list of steps you will take.

            Example:
            update_scratchpad(content: \"\"\"
            1. Review the requirements
            2. Research relevant context
            3. Create an outline
            4. Produce the deliverable
            \"\"\")

            This is the only tool available now. After you create your plan, you will have access to all your tools.
            """

            if let systemIdx = conversationMessages.firstIndex(where: { $0.role == .system }) {
                conversationMessages[systemIdx] = ChatMessage(
                    role: .system,
                    content: planningSystemPrompt
                )
            }
            await saveLLMConversation(stepID: stepID, messages: conversationMessages)
            return (tools.filter { $0.name == ToolNames.updateScratchpad }, resetSession: false)
        } else {
            // Restore original system prompt after planning phase
            var didRestorePrompt = false
            if let savedPrompt = executionStates[stepID]?.originalSystemPrompt,
               let systemIdx = conversationMessages.firstIndex(where: { $0.role == .system }),
               conversationMessages[systemIdx].content?.contains("PLANNING PHASE") == true {
                conversationMessages[systemIdx] = ChatMessage(
                    role: .system,
                    content: savedPrompt
                )
                executionStates[stepID]?.originalSystemPrompt = nil
                didRestorePrompt = true
                // Update only the system message — saveLLMConversation would replace all messages
                // and lose thinking content from the planning phase assistant response
                await updatePersistedSystemMessage(stepID: stepID, content: savedPrompt)
            } else if isFirstIteration && !hasPriorConversation {
                await saveLLMConversation(stepID: stepID, messages: conversationMessages)
            }
            // Reset session when system prompt was swapped so the next call sends the full
            // original prompt in a fresh chain (NativeLMStudioClient omits system_prompt on
            // stateful continuations, so stale planning prompt in the chain would be wrong).
            return (tools, resetSession: didRestorePrompt)
        }
    }
}
