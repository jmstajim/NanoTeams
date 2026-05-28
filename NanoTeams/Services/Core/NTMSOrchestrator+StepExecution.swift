import Foundation

/// Step execution: run, pause, answer Supervisor questions, find/create steps.
extension NTMSOrchestrator {

    // MARK: - Step Execution

    /// Synchronous variant for `LLMStateDelegate.setLastErrorMessageForUI`.
    /// Surfaces a user-visible error banner (auto-dismissing, red).
    func setLastErrorMessageForUI(_ message: String) {
        lastErrorMessage = message
    }

    /// Synchronous variant for `LLMStateDelegate.setLastInfoMessageForUI`.
    /// Surfaces a user-visible info banner (auto-dismissing, neutral style).
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func setLastInfoMessageForUI(_ message: String) {
        lastInfoMessage = message
    }

    /// Notify the engine for a specific task that an external event occurred.
    func notifyEngineExternalEvent(taskID: Int) {
        taskEngines[taskID]?.notifyExternalEvent()
    }

    func runStep(stepID: String, taskID: Int) async {
        guard let task = loadedTask(taskID) else { return }
        guard let runIndex = task.runs.indices.last else { return }
        guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }

        await mutateTask(taskID: taskID) { task in
            StepExecutionService.markStepRunning(stepID: stepID, in: &task)
        }

        if let updatedTask = loadedTask(taskID) {
            llmExecutionService.startStepExecution(
                stepID: stepID,
                taskID: taskID,
                task: updatedTask,
                runIndex: runIndex,
                stepIndex: stepIndex
            )
        }
    }

    func pauseStep(stepID: String, taskID: Int) async {
        await llmExecutionService.cancelStepExecution(stepID: stepID)

        await mutateTask(taskID: taskID) { task in
            StepExecutionService.pauseStep(stepID: stepID, in: &task)
        }
    }

    /// Submits a Supervisor answer. Returns `true` on success, `false` if attachment finalization failed.
    @discardableResult
    func answerSupervisorQuestion(
        stepID: String,
        taskID: Int,
        answer: String,
        attachments: [StagedAttachment] = [],
        draftID: UUID? = nil
    ) async -> Bool {
        // Finalize staged attachments and clean up draft directory
        var finalPaths: [String] = []
        if let workFolderRoot = workFolderURL {
            if !attachments.isEmpty {
                do {
                    finalPaths = try repository.finalizeAttachments(
                        at: workFolderRoot,
                        taskID: taskID,
                        stagedEntries: attachments.map {
                            (path: $0.stagedRelativePath, isProjectReference: $0.isProjectReference)
                        }
                    )
                } catch {
                    lastErrorMessage = "Failed to finalize attachments: \(error.localizedDescription)"
                    return false  // Do not submit answer without the attachments the user expects
                }
            }
            // Clean up the staging directory used for this answer's attachments.
            if let draftID {
                try? repository.cleanupStagedDraft(at: workFolderRoot, draftID: draftID)
            }
        }

        // Capture whether the closure actually located the step. `mutateTask` itself
        // returns `true` for "persisted" even when the closure short-circuits
        // (CLAUDE.md §7), so we relay applied-state via this captured flag.
        var applied = false
        await mutateTask(taskID: taskID) { task in
            applied = StepMessagingService.answerSupervisorQuestion(
                stepID: stepID,
                answer: answer,
                attachmentPaths: finalPaths,
                in: &task
            )
        }
        guard applied else {
            // Race scenario: the step was restarted, removed, or rebuilt between
            // when the composer rendered the Answer chip and when the user
            // submitted. Set a specific `lastErrorMessage` so the Supervisor
            // sees the cause instead of a generic "submission failed". The
            // composer's `.answer` branch clears its draft synchronously on
            // submit and restores it from snapshots when this returns `false`
            // (see `TeamActivityComposer.performAnswerSubmit`), so the user
            // can pick another recipient and retry without retyping.
            lastErrorMessage = "This question is no longer active — the role may have been restarted. Please pick another recipient and try again."
            return false
        }

        let engineState = taskEngineStates[taskID] ?? .pending
        if engineState == .paused || engineState == .needsSupervisorInput {
            await resumeRun(taskID: taskID)
        } else if engineState != .done && engineState != .failed {
            taskEngines[taskID]?.notifyExternalEvent()
        }
        return true
    }

    // MARK: - Step Creation (used by TaskEngineStoreAdapter)

    func findOrCreateStep(taskID: Int, roleID: String) async -> String? {
        guard let task = loadedTask(taskID) else { return nil }
        guard let runIndex = task.runs.indices.last else { return nil }

        if let step = task.runs[runIndex].steps.first(where: { $0.effectiveRoleID == roleID }) {
            return step.id
        }

        let taskTeam = resolvedTeam(for: task)
        guard let step = taskTeam.makeStep(forRoleID: roleID) else { return nil }

        // Supervisor task is injected by PromptBuilder.buildSupervisorTaskSection() — no need to duplicate here

        let stepID = step.id

        await mutateTask(taskID: taskID) { task in
            task.runs[task.runs.count - 1].steps.append(step)
        }

        return stepID
    }

}
