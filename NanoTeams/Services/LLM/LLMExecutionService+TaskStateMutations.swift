import Foundation

/// Extension containing tool call recording, scratchpad management,
/// Supervisor auto-answer, and learning insights.
extension LLMExecutionService {

    // MARK: - Token Usage

    func persistTokenUsage(stepID: String, taskID: Int, usage: TokenUsage) async {
        guard usage.inputTokens > 0 || usage.outputTokens > 0,
              let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }
        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }
            task.runs[runIndex].steps[stepIndex].tokenUsage = usage
        }
    }

    // MARK: - Tool Call Recording

    func appendToolCalls(stepID: String, taskID: Int, toolCalls: [StepToolCall]) async {
        guard !toolCalls.isEmpty, let delegate,
              isExecutionLive(stepID: stepID, taskID: taskID) else { return }

        await delegate.mutateTask(taskID: taskID) { task in
            for toolCall in toolCalls {
                TaskMutationService.appendToolCall(toolCall, to: stepID, in: &task)
            }
        }
    }

    func updateToolCallResult(
        stepID: String,
        taskID: Int,
        toolCallID: UUID,
        result: ToolExecutionResult
    ) async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }
        await delegate.mutateTask(taskID: taskID) { task in
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

    func updateScratchpad(stepID: String, taskID: Int, content: String) async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        await delegate.mutateTask(taskID: taskID) { task in
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
        await noteInterleavingCall(label: "supervisor auto-answer", config: config)
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

    func recordAutoSupervisorAnswer(stepID: String, taskID: Int, question: String, answer: String) async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)

        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            task.runs[runIndex].steps[stepIndex].supervisorQuestion =
                cleanQuestion.isEmpty ? nil : cleanQuestion
            task.runs[runIndex].steps[stepIndex].supervisorAnswer = cleanAnswer.isEmpty ? nil : cleanAnswer
            task.runs[runIndex].steps[stepIndex].supervisorAnswerAttachmentPaths = []
            task.runs[runIndex].steps[stepIndex].supervisorAnswerWasAuto = true
            // Deliberately NOT armed. This path answers INSIDE the live tool loop —
            // `handleSupervisorAutoAnswer` puts the answer into `conversationMessages`
            // itself and returns `.continueLoop`, so the step never suspends and the
            // re-entry seam has nothing to deliver. Arming it would make a later
            // pause/resume of the same step append the answer a SECOND time, which is
            // the defect this flag closes on the parked path.
            task.runs[runIndex].steps[stepIndex].supervisorAnswerPendingDelivery = false
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
    /// landed — i.e. delegate attached + the (taskID, stepID) execution still live
    /// + run/step indices resolved AND `mutateTask` persisted. Per CLAUDE.md §7, `mutateTask`'s `Bool`
    /// alone only proves persistence; the closure can short-circuit and still
    /// return `true`. Without the capture flag, callers using this as the
    /// escape hatch from a retry loop (parse-failure cap, drift cap) can
    /// transition the engine to "needs Supervisor input" with NO question
    /// rendered — which is strictly worse than the loop they replaced.
    @discardableResult
    func setNeedsSupervisorInput(stepID: String, taskID: Int, question: String) async -> Bool {
        // The liveness gate matters doubly here: a post-teardown call would not just
        // mis-write — it would flip a closed/paused task back to `.needsSupervisorInput`
        // and fire the queued-message backstop, which auto-resumes the run.
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return false }
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)

        var didApply = false
        let mutated = await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            task.runs[runIndex].steps[stepIndex].supervisorQuestion = clean.isEmpty ? nil : clean
            task.runs[runIndex].steps[stepIndex].supervisorAnswer = nil  // Clear stale answer from previous Q&A
            task.runs[runIndex].steps[stepIndex].supervisorAnswerAttachmentPaths = []
            task.runs[runIndex].steps[stepIndex].supervisorAnswerWasAuto = false
            task.runs[runIndex].steps[stepIndex].supervisorAnswerPendingDelivery = false
            task.runs[runIndex].steps[stepIndex].needsSupervisorInput = true
            task.runs[runIndex].steps[stepIndex].status = .needsSupervisorInput

            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
            didApply = true
        }

        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.runningTask = nil
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
            delegate.notifyQueuedMessageBackstop(taskID: taskID)
        }
        return success
    }
}
