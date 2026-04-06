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
@MainActor
enum TaskMutationService {

    // MARK: - In-Memory Mutations

    /// Applies a mutation to a task in-memory without persistence.
    /// - Parameters:
    ///   - task: The task to mutate.
    ///   - mutation: The mutation to apply.
    static func mutateInMemory(
        task: inout NTMSTask,
        mutation: (inout NTMSTask) -> Void
    ) {
        mutation(&task)
    }

    /// Updates a snapshot with the mutated task.
    /// - Parameters:
    ///   - snapshot: The snapshot to update.
    ///   - task: The updated task.
    ///   - updateIndex: Whether to update the tasks index.
    static func updateSnapshot(
        _ snapshot: inout WorkFolderContext,
        with task: NTMSTask,
        updateIndex: Bool = false
    ) {
        snapshot.activeTask = task
        snapshot.activeTaskID = task.id

        if updateIndex {
            var tasksIndex = snapshot.tasksIndex
            let summary = task.toSummary()
            if let idx = tasksIndex.tasks.firstIndex(where: { $0.id == summary.id }) {
                tasksIndex.tasks[idx] = summary
            } else {
                tasksIndex.tasks.append(summary)
            }
            tasksIndex.tasks.sort(by: { $0.updatedAt > $1.updatedAt })
            snapshot.tasksIndex = tasksIndex
        }
    }

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
        in task: inout NTMSTask
    ) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else {
            print("[TaskMutation] updateToolCallResult: step \(stepID) not found in latest run")
            return
        }
        guard
            let callIndex = task.runs[location.runIndex].steps[location.stepIndex].toolCalls
                .firstIndex(where: { $0.id == toolCallID })
        else {
            print("[TaskMutation] updateToolCallResult: tool call \(toolCallID) not found in step \(stepID)")
            return
        }
        task.runs[location.runIndex].steps[location.stepIndex].toolCalls[callIndex].resultJSON =
            resultJSON
        task.runs[location.runIndex].steps[location.stepIndex].toolCalls[callIndex].isError = isError
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
    ///   - task: The task to mutate.
    static func setSupervisorAnswer(_ answer: String, stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswer = answer
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerAttachmentPaths = []
        task.runs[location.runIndex].steps[location.stepIndex].needsSupervisorInput = false
        task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
    }

    /// Updates work notes for a step.
    /// - Parameters:
    ///   - notes: The work notes.
    ///   - stepID: The step ID.
    ///   - task: The task to mutate.
    static func updateWorkNotes(_ notes: String?, stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        task.runs[location.runIndex].steps[location.stepIndex].workNotes = notes
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

        // Update existing LLMMessage in llmConversation (pre-created by beginStreaming)
        if let idx = task.runs[ri].steps[si].llmConversation.firstIndex(where: { $0.id == messageID }) {
            task.runs[ri].steps[si].llmConversation[idx].content = content
            if let thinking, !thinking.isEmpty {
                task.runs[ri].steps[si].llmConversation[idx].thinking = thinking
            }
        }

        // Update or create StepMessage in step.messages (used by PromptBuilder and extractLatestStepOutput)
        if let idx = task.runs[ri].steps[si].messages.firstIndex(where: { $0.id == messageID }) {
            task.runs[ri].steps[si].messages[idx].content = content
        } else if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let stepMessage = StepMessage(id: messageID, createdAt: now, role: role, content: content)
            task.runs[ri].steps[si].messages.append(stepMessage)
        }

        task.runs[ri].steps[si].updatedAt = now
    }
}
