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
                argumentsJSON: result.argumentsJSON,
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

    /// Persists a Supervisor question on the step and transitions it to
    /// `.needsSupervisorInput`. Returns `true` only when the mutation actually
    /// landed — i.e. delegate + step→task map + run/step indices all resolved
    /// AND `mutateTask` persisted. Per CLAUDE.md §7, `mutateTask`'s `Bool`
    /// alone only proves persistence; the closure can short-circuit and still
    /// return `true`. Without the capture flag, callers using this as the
    /// escape hatch from a retry loop (parse-failure cap, drift cap) can
    /// transition the engine to "needs Supervisor input" with NO question
    /// rendered — which is strictly worse than the loop they replaced.
    @discardableResult
    func setNeedsSupervisorInput(stepID: String, question: String, sessionID: String?) async -> Bool {
        guard let delegate, let tid = taskIDForStep(stepID) else { return false }
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)

        var didApply = false
        let mutated = await delegate.mutateTask(taskID: tid) { task in
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
            didApply = true
        }

        executionStates[stepID]?.runningTask = nil
        let success = mutated && didApply
        if success {
            // Backstop trigger: when a parallel role (CLAUDE.md "`TeamEngine`
            // runs ready roles in parallel, not serially") lands a question
            // while the engine is already `.needsSupervisorInput` (held there
            // by another step), `TeamEngine.transition(to:)` suppresses
            // same-state re-entry (CLAUDE.md "`TeamEngine.transition(to:)`
            // guards same-state re-entry"). The SwiftUI
            // `onChange(of: engineState.taskEngineStates)` trigger in
            // `MainLayoutView.handleEngineStateChanged` then doesn't fire and
            // queued messages stranded for this newly-waiting role would sit
            // until an unrelated state change surfaced them. Fire the backstop
            // directly from the mutation side.
            delegate.notifyQueuedMessageBackstop(taskID: tid)
        }
        return success
    }
}
