import Foundation

/// Extension containing step completion and artifact completeness methods.
extension LLMExecutionService {

    // MARK: - Step Completion

    func completeStepSuccess(stepID: String, taskID: Int) async {
        await completeStep(stepID: stepID, taskID: taskID, status: .done)
    }

    func completeStepWithWarning(stepID: String, taskID: Int, warning: String) async {
        await completeStep(stepID: stepID, taskID: taskID, status: .done, notes: warning, notePrefix: "LLM warning")
    }

    func completeStepFailure(stepID: String, taskID: Int, errorMessage: String) async {
        await completeStep(stepID: stepID, taskID: taskID, status: .failed, notes: errorMessage, notePrefix: StepExecution.llmErrorNotePrefix)
    }

    func completeStepNeedsAcceptance(stepID: String, taskID: Int) async {
        await completeStep(stepID: stepID, taskID: taskID, status: .needsApproval)
    }

    /// Unified step completion: record optional notes, finalize status, cleanup.
    private func completeStep(stepID: String, taskID: Int, status: StepStatus, notes: String? = nil, notePrefix: String = "") async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }
        delegate.clearStreamingPreview(stepID: stepID, taskID: taskID)

        if let notes {
            let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                await delegate.mutateTask(taskID: taskID) { task in
                    guard let runIndex = task.runs.indices.last else { return }
                    guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
                    else { return }

                    task.runs[runIndex].steps[stepIndex].messages.append(
                        StepMessage(
                            role: task.runs[runIndex].steps[stepIndex].role,
                            content: "\(notePrefix): \(clean)")
                    )
                }
            }
        }

        await finalizeStepCompletion(stepID: stepID, taskID: taskID, status: status)
        clearRunningTask(stepID: stepID, taskID: taskID)

        // Capture the fully-committed step (final tool calls + terminal status) in the
        // displayed-side audit log. The per-turn `commitStreaming` render runs BEFORE the
        // turn's tool calls are appended, so the final turn's calls land only here.
        delegate.renderConversationLog(taskID: taskID)
    }

    // MARK: - Step Finalization

    /// Sets the terminal status, so `completedAt` lands atomically with it and the window
    /// between step completion and next-step creation stays closed.
    ///
    /// This used to also attach a "Build Diagnostics" artifact. That machinery was removed
    /// on 2026-09-11: its real writer had been deleted in `cfbcf550` (2026-08-01) as dead,
    /// and what survived was a stub that wrote `{skipped: true, skipReason: "clean_build",
    /// errorCount: 0, issues: []}` — the SAME bytes whatever the step had done, including
    /// a step that never built anything. An artifact whose only possible content is
    /// "nothing was measured" is not an artifact, and `errorCount: 0` as evidence is the
    /// MeditationApp task 48 defect in persistent form.
    private func finalizeStepCompletion(stepID: String, taskID: Int, status: StepStatus) async {
        guard let delegate else { return }
        await delegate.mutateTask(taskID: taskID) { task in
            TaskMutationService.updateStepStatus(status, stepID: stepID, in: &task)
        }
    }

    // MARK: - Artifact Completeness Check

    /// Checks whether all expected artifacts have been created for a step.
    /// Returns `.completed` when all expected artifacts are present, `nil` otherwise.
    /// Returns `nil` for roles with no expected artifacts (they don't auto-complete this way).
    func checkArtifactCompleteness(stepID: String, taskID: Int) -> LLMStepStop? {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return nil }
        guard let task = delegate.loadedTask(taskID) else { return nil }
        guard let runIndex = task.runs.indices.last else { return nil }
        guard let step = task.runs[runIndex].steps.first(where: { $0.id == stepID })
        else { return nil }

        // Don't auto-complete during revision — old artifacts are preserved from prior execution.
        // Wait for LLM to create updated artifacts (which clears revisionComment).
        if step.revisionComment != nil { return nil }

        return step.isArtifactComplete ? .completed : nil
    }
}
