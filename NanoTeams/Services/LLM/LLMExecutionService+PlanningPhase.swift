import Foundation

/// The @MainActor half of the planning phase: reads the refreshed step, mutates
/// the wire array, and performs the boundary's resets. Every decision and every
/// prompt string lives in `PlanningPhasePolicy`.
///
/// Split out of `LLMExecutionService+StepFlowControl` (which was 675 lines, past
/// the ~400-line God-Object threshold in CLAUDE.md) when the one-shot phase was
/// replaced by this multi-turn one.
extension LLMExecutionService {

    /// Runs at the top of every tool-loop iteration, immediately after the task
    /// snapshot is refreshed. Returns what may execute this iteration.
    ///
    /// The boundary deliberately fires HERE — at the start of the iteration
    /// AFTER `update_scratchpad` returned — and not inside
    /// `processScratchpadResult`. The model can emit `update_scratchpad`
    /// alongside other calls, and results are appended to the wire one at a
    /// time; replacing the array mid-batch would strand the siblings' `.tool`
    /// messages in a conversation holding no assistant turn that requested
    /// them. Waiting one iteration means the batch is always resolved whole.
    func applyPlanningPhase(
        stepID: String,
        taskID: Int,
        tools: [ToolSchema],
        step: StepExecution,
        team: Team?,
        memoryStore: MemoryTagStore,
        conversationMessages: inout [ChatMessage],
        roleDefinition: TeamRoleDefinition?
    ) async -> PlanningPhasePolicy.Authorization {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        let expected = step.expectedArtifacts.filter { $0 != ArtifactConstants.buildDiagnosticsName }
        let scratchpadIsNil = step.scratchpad?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true

        let eligible = PlanningPhasePolicy.isEligible(
            scratchpadIsNil: scratchpadIsNil,
            revisionCommentIsNil: step.revisionComment == nil,
            supervisorAnswerIsNil: step.effectiveSupervisorAnswer == nil,
            usesPlanningPhase: roleDefinition?.usePlanningPhase ?? false,
            hasScratchpadTool: PlanningPhasePolicy.hasScratchpadTool(in: tools),
            // The manager has no file-read tools at all, its `update_scratchpad`
            // is MEMORY rather than a plan, and `wait_for_events` — its only way
            // to end a pass — would be withheld. A planning phase there is a
            // deadlock, so it is gated structurally rather than by its flag.
            isAutovisor: team?.templateID == AutovisorConstants.teamTemplateID
        )

        let decision = PlanningPhasePolicy.decide(
            isEligible: eligible,
            wireCarriesBrief: PlanningPhasePolicy.wireCarriesBrief(conversationMessages),
            scratchpadIsNil: scratchpadIsNil,
            wireCarriesClosedMarker: PlanningPhasePolicy.wireCarriesClosedMarker(
                conversationMessages)
        )
        let authorization = PlanningPhasePolicy.authorization(for: decision, tools: tools)

        switch decision {
        case .enterPlanning:
            // Seed the DISPLAY record BEFORE appending the brief. The brief is a
            // wire-only turn: `ActivityFeedBuilder` renders every `.user` message
            // as a bubble, so persisting it would put engine scaffolding in the
            // user's feed.
            await seedDisplayRecordIfFresh(
                stepID: stepID, taskID: taskID, step: step,
                scratchpadIsNil: scratchpadIsNil, messages: conversationMessages)
            conversationMessages.append(ChatMessage(
                role: .user,
                content: PlanningPhasePolicy.planningBrief(
                    exploreToolNames: Array(authorization.allowed),
                    expectedArtifacts: expected)))

        case .continuePlanning:
            break

        case .crossBoundary:
            // Human turns delivered during the phase die with the rest of it — they are neither
            // the task statement nor the scratchpad. Put them back at the head of the queue so
            // the model gets them again in the implementation phase; `consumeQueuedSupervisorMessage`
            // popped them destructively, so the slice would otherwise be the last time anyone saw
            // them. Before the slice, because it is what reads them off the wire.
            for text in PlanningPhasePolicy.discardedSupervisorMessages(in: conversationMessages) {
                delegate?.requeueSupervisorMessageAtHead(
                    taskID: taskID, roleID: step.effectiveRoleID, text: text)
            }
            conversationMessages = PlanningPhasePolicy.implementationWire(
                from: conversationMessages,
                seedTurn: PlanningPhasePolicy.implementationSeedTurn(
                    notes: step.scratchpad ?? "", expectedArtifacts: expected))
            // The array those indices pointed into no longer exists.
            executionStates[stepKey]?.resetConversationIndices()
            // This slice is a DELIBERATE prefix reset. Flag it so the prompt-prefix cache
            // detector does not report the phase boundary as a defect.
            executionStates[stepKey]?.expectedPrefixResetPending = true
            // The tags describe a conversation that was just discarded: without
            // this, a repeat read returns `{"status":"unchanged","ref":"<§R1§>"}`
            // — a pointer to content the model can no longer see, plus an
            // instruction not to re-read it.
            memoryStore.resetForFreshConversation()

        case .closeWithoutRebuild:
            conversationMessages.append(ChatMessage(
                role: .user, content: PlanningPhasePolicy.planningClosedTurn))

        case .execution:
            await seedDisplayRecordIfFresh(
                stepID: stepID, taskID: taskID, step: step,
                scratchpadIsNil: scratchpadIsNil, messages: conversationMessages)
        }

        return authorization
    }

    /// Writes the initial display record for a genuinely fresh step.
    ///
    /// `saveLLMConversation` REPLACES `step.llmConversation` wholesale, so it
    /// must never run for a step that is resuming — that is the data loss the
    /// re-entry guards in `isEligible` exist to prevent.
    private func seedDisplayRecordIfFresh(
        stepID: String,
        taskID: Int,
        step: StepExecution,
        scratchpadIsNil: Bool,
        messages: [ChatMessage]
    ) async {
        guard PlanningPhasePolicy.isFreshStepSave(
            scratchpadIsNil: scratchpadIsNil,
            revisionCommentIsNil: step.revisionComment == nil,
            supervisorAnswerIsNil: step.effectiveSupervisorAnswer == nil,
            hasPriorConversation: !step.llmConversation.isEmpty
        ) else { return }
        await saveLLMConversation(stepID: stepID, taskID: taskID, messages: messages)
    }
}
