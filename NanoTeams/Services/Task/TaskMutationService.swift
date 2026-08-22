import Foundation

/// Pure composition helpers for mutating `NTMSTask` state.
///
/// These functions operate on `inout NTMSTask` and do NOT persist on their own —
/// they are designed to be composed inside a single atomic mutation closure
/// passed to `TaskMutationDelegate.mutateTask(taskID:_:)`. This keeps persistence
/// at a single well-defined boundary (the orchestrator) while allowing multiple
/// mutations to batch into one disk write.
///
/// Usage:
/// ```swift
/// await delegate.mutateTask(taskID: tid) { task in
///     TaskMutationService.appendToolCall(toolCall, to: stepID, in: &task)
///     TaskMutationService.updateStepStatus(.running, stepID: stepID, in: &task)
/// }
/// ```
nonisolated enum TaskMutationService {

    // MARK: - Step Convenience Methods

    /// Appends a message to a step in a task.
    /// - Parameters:
    ///   - message: The message to append.
    ///   - stepID: The step ID.
    ///   - task: The task to mutate.
    static func appendMessage(_ message: StepMessage, to stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        task.runs[location.runIndex].steps[location.stepIndex].messages.append(message)
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
    }

    /// Appends a tool call to a step in a task.
    /// - Parameters:
    ///   - toolCall: The tool call to append.
    ///   - stepID: The step ID.
    ///   - task: The task to mutate.
    static func appendToolCall(_ toolCall: StepToolCall, to stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        task.runs[location.runIndex].steps[location.stepIndex].toolCalls.append(toolCall)
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
    }

    /// Updates a tool call result in a step.
    /// - Parameters:
    ///   - toolCallID: The tool call ID.
    ///   - resultJSON: The result JSON.
    ///   - isError: Whether the result is an error.
    ///   - stepID: The step ID.
    ///   - task: The task to mutate.
    static func updateToolCallResult(
        toolCallID: UUID,
        resultJSON: String,
        isError: Bool,
        stepID: String,
        argumentsJSON: String? = nil,
        in task: inout NTMSTask
    ) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else {
            print("[TaskMutation] updateToolCallResult: step \(stepID) not found in latest run")
            return
        }
        // `lastIndex`, not `firstIndex`: ids are unique so both find the same element, but
        // a tool RESULT always belongs to a call appended moments earlier — the match sits
        // at the tail, and `toolCalls` has no ceiling (`maxToolIterations == 0`, and
        // nothing prunes the conversation), so a forward scan is O(k) per result and
        // O(k²) per run. Same reasoning already recorded at
        // `LLMExecutionService+ToolLoopState.swift`'s `lastIndex(where:)`.
        guard
            let callIndex = task.runs[location.runIndex].steps[location.stepIndex].toolCalls
            .lastIndex(where: { $0.id == toolCallID })
        else {
            print("[TaskMutation] updateToolCallResult: tool call \(toolCallID) not found in step \(stepID)")
            return
        }
        task.runs[location.runIndex].steps[location.stepIndex].toolCalls[callIndex].resultJSON =
            resultJSON
        task.runs[location.runIndex].steps[location.stepIndex].toolCalls[callIndex].isError = isError
        if let argumentsJSON {
            task.runs[location.runIndex].steps[location.stepIndex].toolCalls[callIndex].argumentsJSON =
                argumentsJSON
        }
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
    }

    /// Updates the status of a step.
    /// - Parameters:
    ///   - status: The new status.
    ///   - stepID: The step ID.
    ///   - task: The task to mutate.
    static func updateStepStatus(_ status: StepStatus, stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        let now = MonotonicClock.shared.now()
        task.runs[location.runIndex].steps[location.stepIndex].status = status
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = now
        if (status == .done || status == .failed),
           task.runs[location.runIndex].steps[location.stepIndex].completedAt == nil {
            task.runs[location.runIndex].steps[location.stepIndex].completedAt = now
        }
    }

    /// Appends artifacts to a step.
    /// - Parameters:
    ///   - artifacts: The artifacts to append.
    ///   - stepID: The step ID.
    ///   - task: The task to mutate.
    static func appendArtifacts(_ artifacts: [Artifact], to stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        task.runs[location.runIndex].steps[location.stepIndex].artifacts.append(contentsOf: artifacts)
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
    }

    /// Attaches or updates a build diagnostics artifact on a step.
    /// - Parameters:
    ///   - relativePath: The relative path to the build diagnostics file.
    ///   - stepID: The step ID.
    ///   - task: The task to mutate.
    static func attachBuildDiagnosticsArtifact(
        relativePath: String,
        stepID: String,
        in task: inout NTMSTask
    ) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }

        let now = MonotonicClock.shared.now()
        if let idx = task.runs[location.runIndex].steps[location.stepIndex].artifacts.firstIndex(
            where: { $0.name.caseInsensitiveCompare(ArtifactConstants.buildDiagnosticsName) == .orderedSame })
        {
            task.runs[location.runIndex].steps[location.stepIndex].artifacts[idx].relativePath =
                relativePath
            task.runs[location.runIndex].steps[location.stepIndex].artifacts[idx].updatedAt = now
            task.runs[location.runIndex].steps[location.stepIndex].artifacts[idx].mimeType =
                "application/json"
            task.runs[location.runIndex].steps[location.stepIndex].artifacts[idx].name =
                ArtifactConstants.buildDiagnosticsName
            task.runs[location.runIndex].steps[location.stepIndex].artifacts[idx].icon =
                Artifact.defaultIconForName(ArtifactConstants.buildDiagnosticsName)
        } else {
            let artifact = Artifact(
                name: ArtifactConstants.buildDiagnosticsName,
                icon: Artifact.defaultIconForName(ArtifactConstants.buildDiagnosticsName),
                mimeType: "application/json",
                createdAt: now,
                updatedAt: now,
                relativePath: relativePath
            )
            task.runs[location.runIndex].steps[location.stepIndex].artifacts.append(artifact)
        }
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = now
    }

    /// Sets the Supervisor question for a step.
    /// - Parameters:
    ///   - question: The Supervisor question.
    ///   - required: Whether Supervisor input is required.
    ///   - stepID: The step ID.
    ///   - task: The task to mutate.
    static func setSupervisorQuestion(
        _ question: String,
        required: Bool,
        stepID: String,
        in task: inout NTMSTask
    ) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        task.runs[location.runIndex].steps[location.stepIndex].needsSupervisorInput = required
        task.runs[location.runIndex].steps[location.stepIndex].supervisorQuestion = question
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
    }

    /// Sets the Supervisor answer for a step.
    /// - Parameters:
    ///   - answer: The Supervisor answer.
    ///   - stepID: The step ID.
    ///   - isAutoAnswer: `true` when an automated path (auto-answer service,
    ///     delegating parent role, Autovisor) is answering — drives the feed's
    ///     "Auto-answered" badge via `supervisorAnswerWasAuto`. Human callers
    ///     use the default `false`.
    ///   - task: The task to mutate.
    static func setSupervisorAnswer(
        _ answer: String, stepID: String, isAutoAnswer: Bool = false, in task: inout NTMSTask
    ) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswer = answer
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerAttachmentPaths = []
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerWasAuto = isAutoAnswer
        // Arms the one-shot delivery to the wire (see
        // `StepExecution.supervisorAnswerPendingDelivery`).
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerPendingDelivery =
            StepExecution.inferPendingDelivery(answer: answer, attachmentPaths: [])
        task.runs[location.runIndex].steps[location.stepIndex].needsSupervisorInput = false
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
    }

    /// Appends an LLM message to the conversation history.
    /// - Parameters:
    ///   - message: The LLM message.
    ///   - stepID: The step ID.
    ///   - task: The task to mutate.
    static func appendLLMMessage(_ message: LLMMessage, to stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        task.runs[location.runIndex].steps[location.stepIndex].llmConversation.append(message)
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
    }

    /// Append a transient retry-status note (tagged `sourceContext: .serverError`
    /// so the feed renders it as a red bubble), OR replace the previous one in place
    /// when the last note is already a server-error note. A burst of recoverable
    /// retries (e.g. server unreachable) then collapses into a single live-updating
    /// bubble — `llmConversation` stays bounded and the `createdAt` bump lets the
    /// feed's version hash detect the in-place change. Keeping the same message `id`
    /// means the existing bubble updates in place (no remove/insert flicker).
    ///
    /// Before matching, drop a trailing EMPTY `.assistant` message: `beginStreaming`
    /// pre-creates one such placeholder before every attempt, and on a stream error
    /// it's never committed, so it sits at the tail. Left in place it would both
    /// leak and separate consecutive retry notes — defeating the collapse (each
    /// retry would see the empty placeholder, fail the match, and append a fresh
    /// note). Dropping it also reuses the dead slot cleanly.
    static func appendOrReplaceRetryNotice(
        _ content: String, to stepID: String, in task: inout NTMSTask
    ) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        let now = MonotonicClock.shared.now()
        // `&`-through the subscript chain, NOT `var conv = …` / assign-back: reading the
        // array out into a local leaves it referenced twice, so the first mutation copies
        // the WHOLE conversation — and `llmConversation` has no ceiling. The `_modify`
        // accessors keep the buffer uniquely referenced, so this is O(1) amortized.
        applyRetryNotice(
            content, now: now,
            to: &task.runs[location.runIndex].steps[location.stepIndex].llmConversation)
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = now
    }

    /// The tail edit `appendOrReplaceRetryNotice` performs, over the conversation alone —
    /// separated so it can be exercised without building a whole `NTMSTask`, and so the
    /// in-place `inout` chain above has exactly one place to go wrong.
    static func applyRetryNotice(_ content: String, now: Date, to conv: inout [LLMMessage]) {
        if let last = conv.indices.last,
           conv[last].role == .assistant,
           conv[last].content.isEmpty,
           conv[last].thinking?.isEmpty ?? true {
            conv.removeLast()
        }

        if let last = conv.indices.last, conv[last].sourceContext == .serverError {
            conv[last].content = content
            conv[last].createdAt = now
        } else {
            conv.append(LLMMessage(role: .assistant, content: content, sourceContext: .serverError))
        }
    }

    /// Removes an LLM message by id from a step's conversation. Used to drop the
    /// pre-created empty assistant turn when a top-level thinking loop discards
    /// its generation (`NTMSOrchestrator.discardStreaming`).
    static func removeLLMMessage(id: UUID, from stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        task.runs[location.runIndex].steps[location.stepIndex].llmConversation.removeAll { $0.id == id }
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
    }

    /// Commits streaming content to both step.llmConversation (LLMMessage) and step.messages (StepMessage).
    /// Updates the pre-created LLMMessage with final content/thinking, and creates/updates the StepMessage.
    /// - Parameters:
    ///   - stepID: The step ID.
    ///   - messageID: The message ID (shared between LLMMessage and StepMessage).
    ///   - content: The final accumulated content.
    ///   - thinking: The final accumulated thinking content.
    ///   - role: The role that produced the message.
    ///   - task: The task to mutate.
    static func commitStreamingContent(
        stepID: String,
        messageID: UUID,
        content: String,
        thinking: String?,
        role: Role,
        in task: inout NTMSTask
    ) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        let ri = location.runIndex
        let si = location.stepIndex
        let now = MonotonicClock.shared.now()

        // Update existing LLMMessage in llmConversation (pre-created by beginStreaming).
        // `lastIndex`, not `firstIndex`: `beginStreaming` planted this message as the LAST
        // element moments ago, and `llmConversation` has no ceiling — a forward scan is
        // O(k) per turn, O(k²) per run. Ids are unique, so both spellings find the same one.
        if let idx = task.runs[ri].steps[si].llmConversation.lastIndex(where: { $0.id == messageID }) {
            task.runs[ri].steps[si].llmConversation[idx].content = content
            if let thinking, !thinking.isEmpty {
                task.runs[ri].steps[si].llmConversation[idx].thinking = thinking
            }
            // Re-stamp to commit time so the committed turn sorts at turn-END (where
            // the user watched it stream — pinned to the feed bottom) — adjacent to
            // the tool call / artifact it produced — instead of snapping back to the
            // turn-START timestamp planted by `beginStreaming`. Without this, a long
            // turn is split across the chronological feed when other roles run
            // concurrently (CLAUDE.md #45): the assistant "Thinking" bubble orphans
            // at turn-start while its tool-call card lands seconds later, so the role
            // reads as "stuck thinking" even though it called a tool successfully.
            // `commitStreaming` runs BEFORE this iteration's `appendToolCalls`, so the
            // monotonic clock keeps this `createdAt` < the tool call's — preserving
            // `emitItems`' `assistant.createdAt <= call.createdAt` thinking lookups.
            task.runs[ri].steps[si].llmConversation[idx].createdAt = now
        }

        // Update or create StepMessage in step.messages (used by PromptBuilder and
        // extractLatestStepOutput). `lastIndex` for the same reason as the conversation
        // above: the target was appended by this very turn.
        if let idx = task.runs[ri].steps[si].messages.lastIndex(where: { $0.id == messageID }) {
            task.runs[ri].steps[si].messages[idx].content = content
        } else if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let stepMessage = StepMessage(id: messageID, createdAt: now, role: role, content: content)
            task.runs[ri].steps[si].messages.append(stepMessage)
        }

        task.runs[ri].steps[si].updatedAt = now
    }
}
