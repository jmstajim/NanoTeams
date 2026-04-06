import Foundation

/// Extension containing step completion and artifact completeness methods.
extension LLMExecutionService {

    // MARK: - Step Completion

    func completeStepSuccess(stepID: String) async {
        await completeStep(stepID: stepID, status: .done)
    }

    func completeStepWithWarning(stepID: String, warning: String) async {
        await completeStep(stepID: stepID, status: .done, notes: warning, notePrefix: "LLM warning")
    }

    func completeStepFailure(stepID: String, errorMessage: String) async {
        await completeStep(stepID: stepID, status: .failed, notes: errorMessage, notePrefix: "LLM error")
    }

    func completeStepNeedsAcceptance(stepID: String) async {
        await completeStep(stepID: stepID, status: .needsApproval)
    }

    /// Unified step completion: record optional notes, finalize status, cleanup.
    private func completeStep(stepID: String, status: StepStatus, notes: String? = nil, notePrefix: String = "") async {
        guard let delegate else { return }
        delegate.clearStreamingPreview(stepID: stepID)

        if let notes, let tid = taskIDForStep(stepID) {
            let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                await delegate.mutateTask(taskID: tid) { task in
                    guard let runIndex = task.runs.indices.last else { return }
                    guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
                    else { return }

                    if status == .done {
                        task.runs[runIndex].steps[stepIndex].workNotes = clean
                    }
                    task.runs[runIndex].steps[stepIndex].messages.append(
                        StepMessage(
                            role: task.runs[runIndex].steps[stepIndex].role,
                            content: "\(notePrefix): \(clean)")
                    )
                }
            }
        }

        await finalizeStepCompletion(stepID: stepID, status: status)
        clearRunningTask(stepID: stepID)
    }

    // MARK: - Step Finalization

    /// Combines build diagnostics attachment and final status update into a single mutation.
    /// This ensures `completedAt` is set atomically with the terminal status, minimizing
    /// the window between step completion and next step creation.
    private func finalizeStepCompletion(stepID: String, status: StepStatus) async {
        guard let delegate, let tid = taskIDForStep(stepID) else { return }

        // Build Diagnostics only if role has "Build Diagnostics" in producesArtifacts
        var diagPath: String?
        if let workFolderRoot = delegate.workFolderURL,
           let task = delegate.loadedTask(tid),
           let run = task.runs.last,
           let step = run.steps.first(where: { $0.id == stepID }),
           let projectContext = delegate.snapshot,
           let activeTeam = projectContext.workFolder.activeTeam,
           let roleDefinition = activeTeam.findRole(byIdentifier: step.effectiveRoleID),
           roleDefinition.dependencies.producesArtifacts.contains(ArtifactConstants.buildDiagnosticsName) {
            diagPath = artifactService.buildDiagnosticsRelativePath(
                taskID: task.id, runID: run.id, roleID: step.effectiveRoleID, workFolderRoot: workFolderRoot
            )
            // If no diagnostics path (successful build), create a summary artifact
            if diagPath == nil {
                diagPath = try? artifactService.persistEmptyBuildDiagnostics(
                    taskID: task.id, runID: run.id, roleID: step.effectiveRoleID, workFolderRoot: workFolderRoot
                )
            }
        }

        await delegate.mutateTask(taskID: tid) { task in
            if let rel = diagPath {
                TaskMutationService.attachBuildDiagnosticsArtifact(
                    relativePath: rel, stepID: stepID, in: &task
                )
            }
            TaskMutationService.updateStepStatus(status, stepID: stepID, in: &task)
        }
    }

    // MARK: - Artifact Completeness Check

    /// Checks whether all expected artifacts have been created for a step.
    /// Returns `.completed` when all expected artifacts are present, `nil` otherwise.
    /// Returns `nil` for roles with no expected artifacts (they don't auto-complete this way).
    func checkArtifactCompleteness(stepID: String) -> LLMStepStop? {
        guard let delegate, let tid = taskIDForStep(stepID) else { return nil }
        guard let task = delegate.loadedTask(tid) else { return nil }
        guard let runIndex = task.runs.indices.last else { return nil }
        guard let step = task.runs[runIndex].steps.first(where: { $0.id == stepID })
        else { return nil }

        // Don't auto-complete during revision — old artifacts are preserved from prior execution.
        // Wait for LLM to create updated artifacts (which clears revisionComment).
        if step.revisionComment != nil { return nil }

        return step.isArtifactComplete ? .completed : nil
    }
}
