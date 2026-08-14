import Foundation

/// Extension for conversation state management between tool loop iterations:
/// queued Supervisor message injection, loop detection warnings, and Supervisor
/// auto-answer during tool loops.
extension LLMExecutionService {

    // MARK: - Queued Supervisor Message Injection

    /// Consumes the next queued Supervisor message targeted at this role (or the
    /// untargeted Team queue) and appends it to `conversationMessages` as a user
    /// turn for this iteration's LLM request.
    ///
    /// The delegate performs attachment finalization AND persists the matching
    /// `LLMMessage` to `step.llmConversation` atomically — we must NOT also call
    /// `appendLLMMessage` here (double-append).
    ///
    /// Returns whether a turn was actually appended. That answer is the ONLY in-band
    /// signal the iteration has that information reached the model without a tool call
    /// of its own producing it, and `ToolCallLoopDetector` needs it: `nil` from the
    /// delegate is ambiguous by construction (no form state / nothing queued / finalize
    /// or persist failure), so the caller cannot re-derive it. Not `@discardableResult`
    /// — every caller must decide what the arrival means.
    func injectQueuedSupervisorMessage(
        stepID: String,
        taskID: Int,
        roleID: String,
        conversationMessages: inout [ChatMessage]
    ) async -> Bool {
        guard let delegate else { return false }
        guard let content = await delegate.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: roleID, stepID: stepID
        ) else { return false }
        conversationMessages.append(ChatMessage(role: .user, content: content))
        return true
    }

    // MARK: - Loop Detection

    /// Checks for looping patterns and injects a warning message if detected —
    /// at most ONCE per distinct condition per step.
    ///
    /// The gate is the whole point. `detectLoopPattern` is stateless and reads the tail of
    /// the tracker, so a condition it reports stays true for as long as the model keeps
    /// behaving that way; with `maxToolIterations = 0` (unbounded) and a read loop counting
    /// as a PRODUCTIVE turn — so no escalation ceiling advances — this appended the same
    /// sentence to `conversationMessages` and to `step.llmConversation` on every iteration,
    /// forever, on a transport that resends the whole array each time. Neither request
    /// builder dedupes: Ollama MERGES consecutive user turns and LM Studio flattens them,
    /// so every copy is paid for in full.
    ///
    /// The signature excludes the repeat COUNT, or the growing count would make each
    /// iteration's message a new string and defeat the gate. Accepted trade-off: a role that
    /// ignores the warning is not told twice. That is the right side to err on — repeating a
    /// directive the model already declined is what burned the budget, and the condition is
    /// still visible to the Supervisor in the feed.
    func checkAndInjectLoopWarning(
        stepID: String,
        taskID: Int,
        tracker: ToolCallTracker,
        allowedToolNames: Set<String>,
        conversationMessages: inout [ChatMessage]
    ) async {
        let calls = tracker.recentCalls(limit: ToolCallLoopDetector.windowSize)
        guard let loopDetection = ToolCallLoopDetector.detectLoopPattern(in: calls) else { return }

        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        // The epoch of the DETECTED RUN, not the tracker's current one: an arrival that has
        // not yet reached a single visible call must not re-arm this gate (see
        // `epochOfTrailingRun`).
        let signature = Self.loopWarningSignature(
            loopDetection, epoch: ToolCallLoopDetector.epochOfTrailingRun(in: calls))
        guard executionStates[stepKey]?.warnedLoopSignatures.contains(signature) != true else { return }
        executionStates[stepKey]?.warnedLoopSignatures.insert(signature)

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
        //
        // `.retryNudge` for the same reason every nudge in `+StepFlowControl` carries it:
        // `ActivityFeedBuilder` drops a `.user` turn with no `sourceRole` AND no
        // `sourceContext`, so without it the Supervisor watched a role read the same files
        // forever with nothing on screen saying the app had noticed.
        await appendLLMMessage(
            stepID: stepID, taskID: taskID, role: .user, content: warningMessage,
            sourceContext: .retryNudge)
    }

    /// Identity of a loop CONDITION, deliberately without the repeat count — but WITH the
    /// information epoch it was observed in.
    ///
    /// The count is excluded because a growing run is the same condition, and including it
    /// would make every additional repeat a fresh "new" condition to warn about. The epoch
    /// is included for the opposite reason: after information reaches the model that no
    /// call of its own produced, a role that resumes repeating is in a genuinely new
    /// situation — it was told something and looped anyway — and the previous warning
    /// answered a question that no longer stands. Without this the gate silently retires
    /// the mechanism after one use, since the run that follows a boundary is detected and
    /// then suppressed by the signature the pre-boundary run inserted.
    nonisolated static func loopWarningSignature(_ loopDetection: LoopDetection, epoch: Int) -> String {
        switch loopDetection {
        case .repetitivePlanning: return "planning@\(epoch)"
        case .repetitiveTool(let tool, _): return "repetitive:\(tool)@\(epoch)"
        // The error code is part of the CONDITION: the same call switching from
        // `INVALID_ARGS` to `ANCHOR_NOT_FOUND` is a different problem and deserves to be
        // said once more. The count stays out, for the same reason as its siblings.
        case .repetitiveFailure(let tool, _, let code):
            return "failing:\(tool):\(code ?? "-")@\(epoch)"
        }
    }

    /// Builds the loop-break message. Tool-aware: names ONLY tools in the
    /// role's current schema — the pre-fix text unconditionally steered every
    /// role toward `edit_file`/`git_commit`/`create_artifact`, sending
    /// read-only and chat roles into a `tool_not_authorized` ping-pong (the
    /// error guidance says "don't retry" while the loop warning says "call
    /// it"). One directive beats a conditional menu for small models.
    ///
    /// This function now owns the ADVICE for every branch, not just the scratchpad ladder.
    /// While `LoopDetection` carried its own text, two branches escaped the contract above:
    /// the since-deleted `.readOnlyLoop` told the built-in Code Reviewer — read-only plus
    /// `create_artifact` — to "make a code change or commit", and the generic tail appended
    /// "change the arguments" directly after the GUI advice that exists to say the opposite.
    /// (`.readOnlyLoop` itself died later, for a detection defect its tool-aware rewrite
    /// couldn't cure: it fired on six DISTINCT reads — prescribed exploration — and its text
    /// was false for them; see the `LoopDetection` doc.)
    /// Internal (not private) for test pinning.
    nonisolated static func loopWarningMessage(
        loopDetection: LoopDetection,
        allowedToolNames: Set<String>
    ) -> String {
        let escalation = allowedToolNames.contains(ToolNames.askSupervisor)
            ? " If you are blocked, call ask_supervisor."
            : ""

        switch loopDetection {
        case .repetitivePlanning(let count):
            return "Plan already recorded (\(count) scratchpad updates) — do not call "
                + "update_scratchpad again except to mark a completed step. "
                + "\(executeNowDirective(allowedToolNames: allowedToolNames))\(escalation)"

        case .repetitiveTool(let tool, let count):
            // For GUI tools "try different arguments" is the wrong cure — a repeated
            // identical click means the model is probing a UI it can no longer see; the fix
            // is a fresh look. `screen_capture` is only NAMED when the role holds it.
            let directive: String
            if ToolHandlerRegistry.computerUseTools.contains(tool) {
                directive = allowedToolNames.contains(ToolNames.screenCapture)
                    ? "Take a fresh screen_capture to see the current UI, then aim at an "
                        + "element's cx/cy."
                    : "Aim at a different element — the one you are clicking is not responding."
            } else {
                directive = "Change the arguments or move on to the next step of your plan."
            }
            return "Loop detected: you've called '\(tool)' with identical arguments "
                + "\(count) times in a row and the state isn't changing. \(directive)\(escalation)"

        case .repetitiveFailure(let tool, let count, let code):
            // The opposite advice from `.repetitiveTool`: nothing is stale, the call is
            // simply not valid as written. Saying "the state isn't changing" here would be
            // false — no state was ever reached.
            let codeClause = code.map { " with the same error (\($0))" } ?? ""
            let directive: String
            if code == "INVALID_ARGS" {
                // The one code whose cure is fully specified by the schema the role
                // already has on the wire.
                directive = "Re-read \(tool)'s parameter list in your instructions and send "
                    + "every required argument inside the `arguments` object."
            } else {
                directive = "Repeating it cannot succeed — read the error message, change "
                    + "the arguments, or take a different step."
            }
            return "Loop detected: '\(tool)' has failed \(count) times in a row with "
                + "identical arguments\(codeClause). \(directive)\(escalation)"
        }
    }

    /// The "stop planning, act" rung, shared by the scratchpad ladder.
    private nonisolated static func executeNowDirective(allowedToolNames: Set<String>) -> String {
        if allowedToolNames.contains(ToolNames.editFile) {
            return "Execute step 1 of your plan now — start with edit_file or write_file."
        }
        if allowedToolNames.contains(ToolNames.createArtifact) {
            return "Execute your plan now and submit the deliverable via create_artifact."
        }
        return "Execute step 1 of your plan now."
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

        // `nil` means CANCELLED, not "no answer". Returning `nil` here leaves the question
        // standing and lets the caller park the step at `.needsSupervisorInput`, which is
        // what a Pause should look like — the alternative was persisting a canned decision
        // and reporting `.continueLoop` on a task the user had just stopped.
        guard let answer = await generateAutoSupervisorAnswer(
            question: q,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            client: client,
            config: config
        ) else { return nil }
        await recordAutoSupervisorAnswer(stepID: stepID, taskID: task.id, question: q, answer: answer)

        // Replace EVERY pending `ask_supervisor` tool result with the answer. The questions were
        // merged, so one answer resolves all of them — but each call appended its own
        // `{"status":"pending"}`, and resolving only the first left the others pending on the wire
        // for the rest of the step, resent every iteration.
        let answerContent = buildCollaborationToolResult(toolName: ToolNames.askSupervisor, response: answer)
        var replacedAny = false
        for toolCallID in outcome.supervisorToolCallProviderIDs {
            guard let idx = conversationMessages.lastIndex(where: { $0.toolCallID == toolCallID })
            else { continue }
            conversationMessages[idx] = ChatMessage(
                role: .tool, content: answerContent, toolCallID: toolCallID
            )
            replacedAny = true
        }
        if !replacedAny {
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
