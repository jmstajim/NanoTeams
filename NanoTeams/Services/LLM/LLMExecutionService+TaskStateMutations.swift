import Foundation

/// Extension containing tool call recording, scratchpad management,
/// Supervisor auto-answer, and learning insights.
extension LLMExecutionService {

    // MARK: - Token Usage

    func persistTokenUsage(stepID: String, usage: TokenUsage) async {
        guard usage.inputTokens > 0 || usage.outputTokens > 0,
              let delegate, let tid = taskIDForStep(stepID) else { return }
        await delegate.mutateTask(taskID: tid) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }
            task.runs[runIndex].steps[stepIndex].tokenUsage = usage
        }
    }

    // MARK: - Session Persistence

    /// Saves the LLM session ID so the step can resume via stateful continuation (e.g. after revision).
    func persistSessionID(stepID: String, sessionID: String?) async {
        guard let delegate, let tid = taskIDForStep(stepID) else { return }
        await delegate.mutateTask(taskID: tid) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }
            task.runs[runIndex].steps[stepIndex].llmSessionID = sessionID
        }
    }

    // MARK: - Tool Call Recording

    func appendToolCalls(stepID: String, toolCalls: [StepToolCall]) async {
        guard !toolCalls.isEmpty, let delegate, let tid = taskIDForStep(stepID) else { return }

        await delegate.mutateTask(taskID: tid) { task in
            for toolCall in toolCalls {
                TaskMutationService.appendToolCall(toolCall, to: stepID, in: &task)
            }
        }
    }

    func updateToolCallResult(
        stepID: String,
        toolCallID: UUID,
        result: ToolExecutionResult
    ) async {
        guard let delegate, let tid = taskIDForStep(stepID) else { return }
        await delegate.mutateTask(taskID: tid) { task in
            TaskMutationService.updateToolCallResult(
                toolCallID: toolCallID,
                resultJSON: result.outputJSON,
                isError: result.isError,
                stepID: stepID,
                in: &task
            )
        }
    }

    // MARK: - Scratchpad

    func updateScratchpad(stepID: String, content: String) async {
        guard let delegate, let tid = taskIDForStep(stepID) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        await delegate.mutateTask(taskID: tid) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            task.runs[runIndex].steps[stepIndex].scratchpad = trimmed.isEmpty ? nil : trimmed
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
        }
    }

    // MARK: - Supervisor Auto-Answer

    func generateAutoSupervisorAnswer(
        question: String,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        client: any LLMClient,
        config: LLMConfig
    ) async -> String {
        guard delegate != nil else { return "Approved." }
        return await SupervisorAutoAnswerService.generateAnswer(
            question: question,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            client: client,
            config: config,
            artifactReader: { [weak self] artifact in
                guard let workFolderRoot = self?.delegate?.workFolderURL else { return nil }
                return ArtifactService.readContent(artifact: artifact, workFolderRoot: workFolderRoot)
            }
        )
    }

    func recordAutoSupervisorAnswer(stepID: String, question: String, answer: String) async {
        guard let delegate, let tid = taskIDForStep(stepID) else { return }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)

        await delegate.mutateTask(taskID: tid) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            task.runs[runIndex].steps[stepIndex].supervisorQuestion =
                cleanQuestion.isEmpty ? nil : cleanQuestion
            task.runs[runIndex].steps[stepIndex].supervisorAnswer = cleanAnswer.isEmpty ? nil : cleanAnswer
            task.runs[runIndex].steps[stepIndex].supervisorAnswerAttachmentPaths = []
            task.runs[runIndex].steps[stepIndex].needsSupervisorInput = false

            if task.runs[runIndex].steps[stepIndex].status == .needsSupervisorInput {
                task.runs[runIndex].steps[stepIndex].status = .pending
            }

            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
        }
    }

    // MARK: - Supervisor Input Handling

    func setNeedsSupervisorInput(stepID: String, question: String, sessionID: String?) async {
        guard let delegate, let tid = taskIDForStep(stepID) else { return }
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)

        await delegate.mutateTask(taskID: tid) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            task.runs[runIndex].steps[stepIndex].supervisorQuestion = clean.isEmpty ? nil : clean
            task.runs[runIndex].steps[stepIndex].supervisorAnswer = nil  // Clear stale answer from previous Q&A
            task.runs[runIndex].steps[stepIndex].supervisorAnswerAttachmentPaths = []
            task.runs[runIndex].steps[stepIndex].llmSessionID = sessionID
            task.runs[runIndex].steps[stepIndex].needsSupervisorInput = true
            task.runs[runIndex].steps[stepIndex].status = .needsSupervisorInput

            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
        }

        executionStates[stepID]?.runningTask = nil
    }
}
