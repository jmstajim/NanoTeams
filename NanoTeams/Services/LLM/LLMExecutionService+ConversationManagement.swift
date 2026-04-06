import Foundation

/// Extension containing conversation building, persistence, and repair logic.
extension LLMExecutionService {

    // MARK: - Chat Message Building

    func buildChatMessages(
        for task: NTMSTask,
        stepID: String,
        tools: [ToolSchema],
        supervisorMode _: SupervisorMode
    ) -> [ChatMessage] {
        guard let delegate else { return [] }
        guard let run = task.runs.last else { return [] }
        guard let stepIndex = run.steps.firstIndex(where: { $0.id == stepID }) else { return [] }
        let step = run.steps[stepIndex]

        // Resolve team: prefer task's preferredTeamID, then project's activeTeam
        let resolvedTeam: Team? = {
            if let preferredTeamID = task.preferredTeamID,
               let team = delegate.snapshot?.workFolder.team(withID: preferredTeamID) {
                return team
            }
            return delegate.snapshot?.workFolder.activeTeam
        }()

        let context = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: stepIndex,
            run: run,
            workFolder: delegate.snapshot?.workFolder,
            artifactReader: { [weak self] artifact in
                guard let self, let workFolderRoot = self.delegate?.workFolderURL else { return nil }
                return ArtifactService.readContent(artifact: artifact, workFolderRoot: workFolderRoot)
            },
            activeTeam: resolvedTeam,
            roleDefinition: resolvedTeam?.findRole(byIdentifier: step.effectiveRoleID)
        )

        return PromptBuilder.buildChatMessages(context: context, tools: tools)
    }

    // MARK: - LLM Conversation Persistence

    func saveLLMConversation(
        stepID: String,
        messages: [ChatMessage]
    ) async {
        guard let delegate, let tid = taskIDForStep(stepID) else { return }
        let now = MonotonicClock.shared.now()
        let llmMessages = messages.enumerated().map { index, msg in
            LLMMessage(
                id: UUID(),
                createdAt: now.addingTimeInterval(Double(index) * 0.001),
                role: LLMRole(rawValue: msg.role.rawValue) ?? .user,
                content: msg.content ?? ""
            )
        }

        await delegate.mutateTask(taskID: tid) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            task.runs[runIndex].steps[stepIndex].llmConversation = llmMessages
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
        }
    }

    /// Updates only the system message in the persisted llmConversation without replacing other messages.
    /// Used after planning phase to restore the original system prompt without losing thinking content.
    func updatePersistedSystemMessage(stepID: String, content: String) async {
        guard let delegate, let tid = taskIDForStep(stepID) else { return }

        await delegate.mutateTask(taskID: tid) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            if let sysIdx = task.runs[runIndex].steps[stepIndex].llmConversation
                .firstIndex(where: { $0.role == .system })
            {
                task.runs[runIndex].steps[stepIndex].llmConversation[sysIdx].content = content
            }
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
        }
    }

    // MARK: - LLM Message Appending

    func appendLLMMessage(stepID: String, role: LLMRole, content: String, thinking: String? = nil, sourceRole: Role? = nil, sourceContext: MessageSourceContext? = nil) async {
        let cleanedContent = ConversationRepairService.cleanHarmonyTokens(content)
        let cleanedThinking = thinking.map { ConversationRepairService.cleanHarmonyTokens($0) }
        let hasContent = !cleanedContent.isEmpty
        let hasThinking = cleanedThinking.map { !$0.isEmpty } ?? false
        guard hasContent || hasThinking else { return }
        guard let delegate, let tid = taskIDForStep(stepID) else { return }

        let msg = LLMMessage(role: role, content: cleanedContent, thinking: cleanedThinking, sourceRole: sourceRole, sourceContext: sourceContext)

        await delegate.mutateTask(taskID: tid) { task in
            TaskMutationService.appendLLMMessage(msg, to: stepID, in: &task)
        }
    }

}
