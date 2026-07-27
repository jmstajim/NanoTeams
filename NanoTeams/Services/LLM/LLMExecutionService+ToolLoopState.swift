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
    //   5. Exempt it in `reportPrefixCacheMissIfAny`. The rebuild-in-place below
    //      rewrites the block at `memoriesMessageIndex` — early in the array —
    //      and the version counter guarantees the bytes differ every iteration,
    //      so the prompt-prefix cache detector would correctly but uselessly
    //      report a total miss on EVERY tool-using turn. Decide there whether
    //      the rewrite is a defect worth reporting or a deliberate reset.
    private static let isMemoriesInjectionEnabled = false

    /// Injects the Memories index into the conversation. Skipped when the store
    /// is empty (no tag-producing tools were called yet).
    ///
    /// Rebuilds in place so there's only ever ONE block: the whole conversation
    /// is resent every iteration, so appending a fresh block per update would
    /// accumulate N stale copies. The persisted copy is the block VERBATIM — a
    /// `[MEMORIES]` bracket sigil would mix a second delimiter system into the
    /// `##`-headed block [Sclar2024].
    func injectMemories(
        stepID: String,
        taskID: Int,
        memoryStore: MemoryTagStore,
        conversationMessages: inout [ChatMessage]
    ) async {
        guard Self.isMemoriesInjectionEnabled else { return }

        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        let nextVersion = (executionStates[stepKey]?.memoriesVersion ?? 0) + 1
        executionStates[stepKey]?.memoriesVersion = nextVersion

        guard let memories = memoryStore.generateMemories(version: nextVersion) else { return }

        if let existingIndex = executionStates[stepKey]?.memoriesMessageIndex,
           existingIndex < conversationMessages.count {
            conversationMessages[existingIndex] = ChatMessage(role: .user, content: memories)
        } else {
            executionStates[stepKey]?.memoriesMessageIndex = conversationMessages.count
            conversationMessages.append(ChatMessage(role: .user, content: memories))
        }
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: memories)
    }

    // MARK: - Queued Supervisor Message Injection

    /// Consumes the next queued Supervisor message targeted at this role (or the
    /// untargeted Team queue) and appends it to `conversationMessages` as a user
    /// turn for this iteration's LLM request.
    ///
    /// The delegate performs attachment finalization AND persists the matching
    /// `LLMMessage` to `step.llmConversation` atomically — we must NOT also call
    /// `appendLLMMessage` here (double-append).
    func injectQueuedSupervisorMessage(
        stepID: String,
        taskID: Int,
        roleID: String,
        conversationMessages: inout [ChatMessage]
    ) async {
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
    nonisolated static func loopWarningMessage(
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

    // MARK: - No-Tool-Call Nudges (tool-aware)
    //
    // Same contract as `loopWarningMessage` above and for the same reason: name ONLY
    // tools in the role's CURRENT schema. `allowedToolNames` is the set
    // `executeToolCalls` authorizes against (narrowed during the planning phase), so a
    // name that isn't in it can only ever come back `tool_not_authorized`.
    //
    // This is not hypothetical: `resolveToolSchemas` strips `ask_supervisor` from the
    // Autovisor manager unconditionally, yet every branch below used to name it — the
    // manager was told to call a tool it provably does not have, on the very turn it
    // was already failing to act.

    /// The completion-channel nudge for a role that replied with text and no tool call.
    ///
    /// `wait_for_events` is checked first because it identifies the Autovisor manager,
    /// the one role for which the "plain text does not reach the Supervisor" framing is
    /// FALSE — its Supervisor is the human reading that very chat, and its own system
    /// prompt calls plain text "your only reply channel". Telling it otherwise while
    /// pointing at a missing tool is how a pass burns its recovery budget emitting
    /// nothing. Keyed on the schema rather than on team identity so a role that holds
    /// the tool gets the right text however it acquired it.
    nonisolated static func noToolCallNudge(allowedToolNames: Set<String>) -> String {
        if allowedToolNames.contains(ToolNames.waitForEvents) {
            return "You replied with text but did not call a tool. Your reply is recorded. "
                + "If you have nothing left to do this pass, call wait_for_events to go idle; "
                + "otherwise call the next tool you need to continue."
        }
        if allowedToolNames.contains(ToolNames.askSupervisor) {
            return "You responded with text but did not call any tools — plain text "
                + "does not reach the Supervisor. If your reply is complete, send it via "
                + "ask_supervisor; otherwise call the next tool you need to continue."
        }
        return "You responded with text but did not call any tools — plain text does not "
            + "reach the Supervisor. Call the next tool you need to continue."
    }

    /// The nudge for N near-identical no-tool responses (`.repetitiveNonTool`).
    ///
    /// Discriminates on the SCHEMA, not on `producesArtifacts`: a producing role in the
    /// planning phase has `create_artifact` withheld, and this branch runs ABOVE the
    /// planning-phase handler, so the config signal would steer it straight into the
    /// phase's `plan_required` rejection.
    nonisolated static func repetitiveNonToolNudge(count: Int, allowedToolNames: Set<String>) -> String {
        let escalation = allowedToolNames.contains(ToolNames.askSupervisor)
            ? " If you're blocked, call ask_supervisor with a specific question."
            : ""
        let action: String
        if allowedToolNames.contains(ToolNames.createArtifact) {
            action = "If you've finished your work, call create_artifact to submit "
                + "your deliverable.\(escalation)"
        } else if allowedToolNames.contains(ToolNames.waitForEvents) {
            action = "If you have nothing left to do this pass, call wait_for_events to go idle."
        } else if allowedToolNames.contains(ToolNames.askSupervisor) {
            action = "If your reply is complete, send it via ask_supervisor and wait "
                + "for the Supervisor's response."
        } else {
            action = "Call the tool that advances your next step."
        }
        return "Your last \(count) responses were near-identical and "
            + "contained no tool calls. \(action) Do not repeat this response."
    }

    /// Illustrative tool ids for the "missing top-level `name`" explainer, filtered to
    /// the role's schema and capped at three. `nil` when none survive — the caller then
    /// drops the parenthetical rather than shipping an empty one. An example naming a
    /// tool the role lacks teaches a vocabulary the runtime rejects.
    /// Illustration candidates, most-teachable first. Shared so the quoted list and the
    /// single bare name below can never disagree about which tool a role is shown.
    nonisolated private static let preferredExampleTools = [
        ToolNames.createArtifact, ToolNames.writeFile, ToolNames.askSupervisor,
        ToolNames.readFile, ToolNames.updateScratchpad, ToolNames.waitForEvents,
    ]

    nonisolated static func toolNameExamples(allowedToolNames: Set<String>) -> String? {
        let picked = preferredExampleTools.filter(allowedToolNames.contains).prefix(3)
        guard !picked.isEmpty else { return nil }
        return picked.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    /// One bare tool id for an example that must be syntactically valid — a Harmony
    /// `to=NAME` recipient, or the `name` field of a call envelope. Returns nil when the
    /// role holds none of the candidates, so the caller can drop the illustration rather
    /// than teach a tool the runtime would reject.
    nonisolated static func toolNameExample(allowedToolNames: Set<String>) -> String? {
        preferredExampleTools.first(where: allowedToolNames.contains)
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
