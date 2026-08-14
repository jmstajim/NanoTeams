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

    /// Combines build diagnostics attachment and final status update into a single mutation.
    /// This ensures `completedAt` is set atomically with the terminal status, minimizing
    /// the window between step completion and next step creation.
    private func finalizeStepCompletion(stepID: String, taskID: Int, status: StepStatus) async {
        guard let delegate else { return }

        // Build Diagnostics only if role has "Build Diagnostics" in producesArtifacts
        var diagPath: String?
        if let workFolderRoot = delegate.workFolderURL,
           let task = delegate.loadedTask(taskID),
           let run = task.runs.last,
           let step = run.steps.first(where: { $0.id == stepID }),
           let projectContext = delegate.snapshot,
           // The TASK's team, not the folder's active one. A delegation child, a run
           // pinned to `run.teamID`, or a task-owned generated team all resolve to a
           // different roster — and this decides whether Build Diagnostics is persisted
           // for the role at all. `TeamResolution` is the documented single source of
           // truth for that order.
           let resolvedTeam = resolveTeam(task: task),
           let roleDefinition = resolvedTeam.findRole(byIdentifier: step.effectiveRoleID),
           roleDefinition.dependencies.producesArtifacts.contains(ArtifactConstants.buildDiagnosticsName) {
            let ancestors = projectContext.tasksIndex.ancestorIDs(of: task.id)
            diagPath = artifactService.buildDiagnosticsRelativePath(
                taskID: task.id, runID: run.id, roleID: step.effectiveRoleID,
                workFolderRoot: workFolderRoot, ancestors: ancestors
            )
            // If no diagnostics path (successful build), create a summary artifact
            if diagPath == nil {
                diagPath = try? artifactService.persistEmptyBuildDiagnostics(
                    taskID: task.id, runID: run.id, roleID: step.effectiveRoleID,
                    workFolderRoot: workFolderRoot, ancestors: ancestors
                )
            }
        }

        await delegate.mutateTask(taskID: taskID) { task in
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
