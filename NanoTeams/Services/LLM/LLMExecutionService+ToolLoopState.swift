import Foundation

/// Extension for conversation state management between tool loop iterations:
/// memories injection, loop detection warnings, and Supervisor auto-answer during tool loops.
extension LLMExecutionService {

    // MARK: - Memories Injection

    // TODO(memories-disabled, 2026-05-19): The rolling `## Memories vN` index is
    // temporarily NOT injected into the conversation. The underlying mechanism
    // (`MemoryTagStore` — tag emission in tool results, dedup of repeat reads via
    // `.reference` envelopes, OUTDATED/REPLACED status tracking, cascade
    // invalidation of builds/git on edits) is left fully intact: tagged tool
    // results still flow through `processToolResult`, and the compact
    // `{status:"unchanged", ref:"<§Tag§>", _hint:"Do NOT re-read..."}` envelope
    // continues to short-circuit repeat reads.
    //
    // Why disabled: the rendered index conflates R/E/W semantics into a single
    // "trust CURRENT" instruction, lacks tags for `list_files`/`search`,
    // surfaces a `"base":"?"` sentinel, and reuses tag IDs across snapshots —
    // all of which need fixing before the index goes back on or the same
    // failure modes return.
    //
    // (Observed instance: a single tool-loop iteration mis-applied read-tag
    // semantics to a chain of `<§E§> CURRENT` edit markers and emitted a giant
    // `edit_file` with stale `old_text`, wasting on the order of thousands of
    // output tokens — a typical small/medium open-weight model under LM Studio.
    // Treat as evidence the structural causes above are load-bearing, not the
    // sole failure mode.)
    //
    // Prerequisite: land the planned structural fixes (split R/E/W semantics
    // in the prompt, add `<§L§>` listing tags, drop the `"?"` sentinel) before
    // re-enabling. Then:
    //   1. Flip `isMemoriesInjectionEnabled` below to `true`.
    //   2. Restore the second sentence in
    //      `PromptBuilder.buildConversationMechanicsGuidance` (paired TODO).
    //   3. Remove the skip guard at the top of each test under the
    //      `// MARK: - injectMemories` section in
    //      `NanoTeamsTests/Services/LLM/ToolExecutionTests.swift` (paired TODO).
    //   4. Delete `testInjectMemories_disabledFlag_skipsSeededStore` — its
    //      assertion fails-on-flip and is the tripwire forcing this step.
    private static let isMemoriesInjectionEnabled = false

    /// Injects the Memories index into the conversation. Skipped when the store
    /// is empty (no tag-producing tools were called yet) and, in stateful mode,
    /// when the content hasn't changed since the last injection — the prior
    /// block is already in the server's response chain, so re-sending it just
    /// bloats the conversation with N stale copies on long steps.
    func injectMemories(
        stepID: String,
        taskID: Int,
        memoryStore: MemoryTagStore,
        session: LLMSession?,
        conversationMessages: inout [ChatMessage]
    ) async {
        guard Self.isMemoriesInjectionEnabled else { return }

        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        let nextVersion = (executionStates[stepKey]?.memoriesVersion ?? 0) + 1
        executionStates[stepKey]?.memoriesVersion = nextVersion

        guard let memories = memoryStore.generateMemories(version: nextVersion) else { return }

        if session != nil {
            // Stateful: dedup — the prior block is already in the server chain.
            // Fingerprint skips the version header so bumping `v1`→`v2` alone
            // doesn't count as a change; only real entry changes trigger an append.
            let fingerprint = memories.split(separator: "\n").dropFirst().joined(separator: "\n")
            if executionStates[stepKey]?.lastMemoriesFingerprint == fingerprint { return }
            executionStates[stepKey]?.lastMemoriesFingerprint = fingerprint
            conversationMessages.append(ChatMessage(role: .user, content: memories))
            await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: memories)
        } else {
            // Stateless: rebuild in-place so there's only ever one block. The
            // persisted copy is the block VERBATIM — a `[MEMORIES]` bracket
            // sigil would mix a second delimiter system into the `##`-headed
            // block on stateless rebuild [Sclar2024].
            if let existingIndex = executionStates[stepKey]?.memoriesMessageIndex,
               existingIndex < conversationMessages.count {
                conversationMessages[existingIndex] = ChatMessage(role: .user, content: memories)
                await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: memories)
            } else {
                executionStates[stepKey]?.memoriesMessageIndex = conversationMessages.count
                conversationMessages.append(ChatMessage(role: .user, content: memories))
                await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: memories)
            }
        }
    }

    // MARK: - Queued Supervisor Message Injection

    /// Consumes the next queued Supervisor message targeted at this role (or the
    /// untargeted Team queue) and appends it to `conversationMessages` as a user
    /// turn for this iteration's LLM request.
    ///
    /// Skipped on iteration 1 with a non-nil session: that combination only
    /// occurs when a step resumes from a saved session (supervisor/revision
    /// continuation) and the conversation has no assistant turn to anchor the
    /// stateful-chain slice against — appending a user message there would send
    /// through stateless fallback while `session` stays set, causing the server
    /// to duplicate the response chain.
    ///
    /// The delegate performs attachment finalization AND persists the matching
    /// `LLMMessage` to `step.llmConversation` atomically — we must NOT also call
    /// `appendLLMMessage` here (double-append).
    func injectQueuedSupervisorMessage(
        stepID: String,
        taskID: Int,
        roleID: String,
        iterationNumber: Int,
        session: LLMSession?,
        conversationMessages: inout [ChatMessage]
    ) async {
        guard iterationNumber > 1 || session == nil else { return }
        guard let delegate else { return }
        guard let content = await delegate.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: roleID, stepID: stepID
        ) else { return }
        conversationMessages.append(ChatMessage(role: .user, content: content))
    }

    // MARK: - Loop Detection

    /// Checks for looping patterns and injects a warning message if detected.
    func checkAndInjectLoopWarning(
        stepID: String,
        taskID: Int,
        tracker: ToolCallTracker,
        allowedToolNames: Set<String>,
        conversationMessages: inout [ChatMessage]
    ) async {
        guard let loopDetection = ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6)) else { return }

        let warningMessage = Self.loopWarningMessage(
            loopDetection: loopDetection, allowedToolNames: allowedToolNames
        )
        conversationMessages.append(
            ChatMessage(role: .user, content: warningMessage)
        )
        // Persist with the SAME role that went over the wire. A `.system` copy
        // (the pre-fix behavior) put a mid-conversation system message into
        // every stateless rebuild (HTTP 400 fallback, resume, revision) —
        // violating the one-system-message chain structure.
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: warningMessage)
    }

    /// Builds the loop-break message. Tool-aware: names ONLY tools in the
    /// role's current schema — the pre-fix text unconditionally steered every
    /// role toward `edit_file`/`git_commit`/`create_artifact`, sending
    /// read-only and chat roles into a `tool_not_authorized` ping-pong (the
    /// error guidance says "don't retry" while the loop warning says "call
    /// it"). One directive beats a conditional menu for small models.
    /// Internal (not private) for test pinning.
    static func loopWarningMessage(
        loopDetection: LoopDetection,
        allowedToolNames: Set<String>
    ) -> String {
        let escalation = allowedToolNames.contains(ToolNames.askSupervisor)
            ? " If you are blocked, call ask_supervisor."
            : ""
        if case .repetitiveTool(let tool, let count, _) = loopDetection,
           tool == ToolNames.updateScratchpad {
            let firstStep: String
            if allowedToolNames.contains(ToolNames.editFile) {
                firstStep = "Execute step 1 of your plan now — start with edit_file or write_file."
            } else if allowedToolNames.contains(ToolNames.createArtifact) {
                firstStep = "Execute your plan now and submit the deliverable via create_artifact."
            } else {
                firstStep = "Execute step 1 of your plan now."
            }
            return "Plan already recorded (\(count) scratchpad updates) — do not call "
                + "update_scratchpad again except to mark a completed step. \(firstStep)\(escalation)"
        }
        return "Loop detected: \(loopDetection.message) Do one of: change the arguments, "
            + "or move on to the next step of your plan.\(escalation)"
    }

    // MARK: - Supervisor Auto-Answer in Tool Loop

    /// Handles Supervisor auto-answer when in auto-answer mode.
    /// Returns `.continueLoop` if auto-answered, `nil` if not applicable.
    func handleSupervisorAutoAnswer(
        outcome: ToolResultsOutcome,
        stepID: String,
        supervisorMode: SupervisorMode,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        client: any LLMClient,
        config: LLMConfig,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop? {
        // Autovisor as the folder's Supervisor: suppress the generic auto-answer
        // so the step parks at `.needsSupervisorInput`. The engine pauses on any
        // parked step (TeamEngine+RunLoop — mode-independent), which is what the
        // manager's needs-supervisor wake trigger observes via live engine state.
        if let settings = delegate?.snapshot?.workFolder.settings,
           AutovisorPolicy.supervisesTask(
               taskID: task.id,
               parentTaskID: task.parentTaskID,
               autovisorEnabled: settings.autovisorEnabled,
               activation: settings.autovisorActivation,
               autovisorTaskID: delegate?.snapshot?.workFolder.state.autovisorTaskID
           ) {
            return nil
        }
        guard let q = outcome.supervisorQuestion, supervisorMode == .autonomous else { return nil }

        let answer = await generateAutoSupervisorAnswer(
            question: q,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            client: client,
            config: config
        )
        await recordAutoSupervisorAnswer(stepID: stepID, taskID: task.id, question: q, answer: answer)

        // Replace the pending tool result with the actual answer
        let answerContent = buildCollaborationToolResult(toolName: ToolNames.askSupervisor, response: answer)
        if let toolCallID = outcome.supervisorToolCallProviderID,
           let idx = conversationMessages.lastIndex(where: { $0.toolCallID == toolCallID })
        {
            conversationMessages[idx] = ChatMessage(
                role: .tool, content: answerContent, toolCallID: toolCallID
            )
        } else {
            // Fallback: append as user message
            conversationMessages.append(
                ChatMessage(role: .user, content: "\(MessageSourceContext.supervisorAnswerPrefix)\(answer)")
            )
        }
        await appendLLMMessage(
            stepID: stepID, taskID: task.id, role: .user,
            content: "\(MessageSourceContext.supervisorAnswerPrefix)\(answer)",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer)
        return .continueLoop
    }
}
