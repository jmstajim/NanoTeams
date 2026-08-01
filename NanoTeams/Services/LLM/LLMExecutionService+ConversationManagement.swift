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

        // Resolve team via the shared pin/generatedTeam-aware resolver — a generated
        // team lives on `task.generatedTeam` (never in `workFolder.teams`), so the old
        // `preferredTeamID → activeTeam` lookup built the system prompt against the
        // empty "Generated Team" placeholder (wrong name, no roles, generic guidance).
        let resolvedTeam: Team? = resolveTeam(task: task)

        // Autovisor: append its standing memory to globalContext so it lands in the
        // manager's system prompt every fresh run (recurrence rebuilds the run, picking up
        // the latest persisted memory). The GOAL is injected separately — it's the manager's
        // brief, rendered as `## Supervisor Goal` by PromptBuilder. Other roles get plain
        // globalContext.
        let stepGlobalContext: String = {
            let base = delegate.globalLLMContext
            guard resolvedTeam?.templateID == AutovisorConstants.teamTemplateID else { return base }
            let block = autovisorPromptBlock()
            guard !block.isEmpty else { return base }
            return base.isEmpty ? block : base + "\n\n" + block
        }()

        let roleDefinition = resolvedTeam?.findRole(byIdentifier: step.effectiveRoleID)
        // Resolution drops ids the snapshot could not read (deleted / unreadable
        // SKILL.md) — those surface as `unresolvedIDs` in the editor rather than
        // as an empty section here.
        let attachedSkills = delegate.roleSkills?
            .resolve(roleDefinition?.attachedSkillIDs ?? []) ?? []

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
            roleDefinition: roleDefinition,
            globalContext: stepGlobalContext,
            agentInstructions: delegate.agentInstructions,
            attachedSkills: attachedSkills
        )

        return PromptBuilder.buildChatMessages(context: context, tools: tools)
    }

    // MARK: - LLM Conversation Persistence

    func saveLLMConversation(
        stepID: String,
        taskID: Int,
        messages: [ChatMessage]
    ) async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }
        let now = MonotonicClock.shared.now()
        let llmMessages = messages.enumerated().map { index, msg in
            LLMMessage(
                id: UUID(),
                createdAt: now.addingTimeInterval(Double(index) * 0.001),
                role: LLMRole(rawValue: msg.role.rawValue) ?? .user,
                content: msg.content ?? ""
            )
        }

        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            task.runs[runIndex].steps[stepIndex].llmConversation = llmMessages
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
        }
    }

    /// Persists the byte-faithful record of what this step last SENT.
    ///
    /// Written at every arm where the step stops with a chance of being resumed later —
    /// an answered `ask_supervisor`, the Autovisor idle park, a pause, and the terminal
    /// arms (a `.done`/`.failed` step is still re-enterable through
    /// `resetStepForRevision`). On re-entry `ConversationReplay.resume` hands this array
    /// straight back, so the continuation is an append-only extension of the conversation
    /// the server already processed rather than a fresh synthesis.
    ///
    /// Deliberately separate from ``saveLLMConversation``: that one writes the DISPLAY
    /// record, flattens to `(role, content)`, and is a destructive whole-array replace.
    func persistWireTranscript(stepID: String, taskID: Int, messages: [ChatMessage]) async {
        guard !messages.isEmpty else { return }
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }

        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }
            task.runs[runIndex].steps[stepIndex].wireTranscript = messages
            // The transcript now on disk ALREADY carries whatever supervisor answer this
            // execution appended, so a later re-entry must replay it rather than append
            // it again. Consumed here, in the same mutation as the transcript, precisely
            // so the two can't disagree: clearing the flag where the conversation is
            // BUILT would open a window in which a crash spends the answer while the
            // stored transcript still lacks it.
            //
            // Unconditional: a step that never had an answer has the flag `false`
            // already, and the re-park arm (`setNeedsSupervisorInput`) clears it too.
            task.runs[runIndex].steps[stepIndex].supervisorAnswerPendingDelivery = false
        }
    }

    // MARK: - LLM Message Appending

    func appendLLMMessage(stepID: String, taskID: Int, role: LLMRole, content: String, thinking: String? = nil, sourceRole: Role? = nil, sourceContext: MessageSourceContext? = nil) async {
        let cleanedContent = ConversationRepairService.cleanHarmonyTokens(content)
        let cleanedThinking = thinking.map { ConversationRepairService.cleanHarmonyTokens($0) }
        let hasContent = !cleanedContent.isEmpty
        let hasThinking = cleanedThinking.map { !$0.isEmpty } ?? false
        guard hasContent || hasThinking else { return }
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }

        let msg = LLMMessage(role: role, content: cleanedContent, thinking: cleanedThinking, sourceRole: sourceRole, sourceContext: sourceContext)

        await delegate.mutateTask(taskID: taskID) { task in
            TaskMutationService.appendLLMMessage(msg, to: stepID, in: &task)
        }
    }

    /// Surface the transient retry-status note, collapsing a burst of recoverable
    /// retries into a single live-updating bubble (replaces the previous note in
    /// place rather than appending a new one each attempt).
    func appendOrReplaceRetryNotice(stepID: String, taskID: Int, content: String) async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }
        await delegate.mutateTask(taskID: taskID) { task in
            TaskMutationService.appendOrReplaceRetryNotice(content, to: stepID, in: &task)
        }
    }

}
