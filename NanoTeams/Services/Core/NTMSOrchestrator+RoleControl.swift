import Foundation

/// Role-level control: restart, finish advisory, accept, request revision.
extension NTMSOrchestrator {

    // MARK: - Role Control

    /// Restarts a role and cascades the reset to all downstream dependents.
    func restartRole(taskID: Int, roleID: String, comment: String?) async {
        await ensureTaskLoaded(taskID)

        let task = loadedTask(taskID)
        let team = resolvedTeam(for: task)
        let roles = team.roles

        let downstreamRoles = ArtifactDependencyResolver.getDownstreamRoles(
            of: roleID,
            roles: roles
        )
        var rolesToReset = Set([roleID])
        rolesToReset.formUnion(downstreamRoles)

        // Cancel LLM for steps being reset
        if let task = loadedTask(taskID), let run = task.runs.last {
            for step in run.steps where rolesToReset.contains(step.effectiveRoleID) {
                llmExecutionService.cancelStepExecution(stepID: step.id)
            }
        }

        // Reset roles and steps
        await mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            let now = MonotonicClock.shared.now()

            // Clear closedAt so derived status won't stay .done
            task.closedAt = nil

            for resetRoleID in rolesToReset {
                if let stepIndex = task.runs[runIndex].steps.firstIndex(
                    where: { $0.effectiveRoleID == resetRoleID }
                ) {
                    // Primary role gets the Supervisor comment; downstream roles reset clean
                    let supervisorComment: String? =
                        (resetRoleID == roleID && !(comment ?? "").isEmpty)
                        ? "Supervisor: \(comment!)"
                        : nil
                    task.runs[runIndex].steps[stepIndex].reset(supervisorComment: supervisorComment)
                }

                task.runs[runIndex].roleStatuses[resetRoleID] = .idle
            }
            task.runs[runIndex].updatedAt = now
        }

        // Ensure engine exists and is running — creates if missing (e.g. after app restart)
        let engine = engineForTask(taskID)
        if engine.state == .pending {
            engine.start()
        } else {
            engine.notifyExternalEvent()
        }
    }

    /// Finishes an advisory role immediately — sets step and role to `.done`.
    /// Can be called at any point once the role is ready or working.
    func finishAdvisoryRole(taskID: Int, roleID: String) {
        Task {
            // 1. Cancel running LLM task if step is active
            if let step = loadedTask(taskID)?.runs.last?.stepsByRoleBaseID()[roleID] {
                llmExecutionService.cancelStepExecution(stepID: step.id)
                clearStreamingPreview(stepID: step.id)
            }

            // 2. Mutate: step → .done, role → .done
            await self.mutateTask(taskID: taskID) { task in
                guard var run = task.runs.last else { return }
                if let s = run.steps.firstIndex(where: { $0.effectiveRoleID == roleID }) {
                    run.steps[s].status = .done
                    run.steps[s].completedAt = MonotonicClock.shared.now()
                }
                run.roleStatuses[roleID] = .done
                run.updatedAt = MonotonicClock.shared.now()
                task.runs[task.runs.count - 1] = run
            }

            // 3. Wake engine to check completion / start dependents
            taskEngines[taskID]?.notifyExternalEvent()
        }
    }

    /// Supervisor accepts a role's work, advancing it to `.accepted`.
    /// Returns `true` if the role was accepted and persisted successfully.
    func acceptRole(taskID: Int, roleID: String) async -> Bool {
        guard let task = loadedTask(taskID), task.runs.last != nil else {
            lastErrorMessage = "Cannot accept role: task \(taskID) has no active run."
            return false
        }
        let success = await mutateTask(taskID: taskID) { task in
            guard var run = task.runs.last else { return }
            run.roleStatuses[roleID] = .accepted
            run.updatedAt = MonotonicClock.shared.now()
            task.runs[task.runs.count - 1] = run
        }
        guard success else { return false }
        notifyEngineExternalEvent(taskID: taskID)
        return true
    }

    /// Supervisor corrects an active role while the task is paused.
    /// Two branches distinguished by `step.needsSupervisorInput` (set before pause):
    /// - **Branch A** — step was waiting for Supervisor input when paused. `llmSessionID`
    ///   was persisted by `setNeedsSupervisorInput`. Route through `answerSupervisorQuestion`
    ///   with a "Supervisor Feedback: …" prefix so the existing stateful supervisor-
    ///   continuation path sends the answer via `previous_response_id`. `answerSupervisorQuestion`
    ///   auto-resumes.
    /// - **Branch B** — step was mid-stream (`.running`) when paused. Cancellation did
    ///   not persist the session (`StepLifecycle` only persists on completion paths), so
    ///   `runStep` will rebuild `fullConversation` from `step.messages` on resume. Append
    ///   the feedback there and set `revisionComment` as the artifact-completion gate.
    ///
    /// In both branches the step's current `status` is `.paused` (set by `pauseStep`).
    /// The needsSupervisorInput flag disambiguates what it was doing pre-pause.
    func correctRole(taskID: Int, roleID: String, comment: String) async {
        guard let state = taskEngineStates[taskID], state == .paused else {
            lastErrorMessage = "Correct Role requires the task to be paused."
            return
        }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastErrorMessage = "Correction text cannot be empty."
            return
        }

        guard let task = loadedTask(taskID),
              let run = task.runs.last,
              let step = run.steps.first(where: {
                  $0.effectiveRoleID == roleID && $0.status == .paused
              })
        else {
            lastErrorMessage = "Could not apply correction — role is no longer paused or step is missing."
            return
        }

        // Branch A: was waiting for Supervisor input. answerSupervisorQuestion handles
        // the stateful supervisor-continuation path and auto-resumes the run.
        // We pass no attachments here (the CorrectRoleSheet is text-only), and
        // `answerSupervisorQuestion` only returns `false` on attachment-finalize
        // failure — so delivery is effectively infallible on this path. If the
        // sheet ever grows attachment support, the `@discardableResult` return is
        // already surfaced via `lastErrorMessage` by `answerSupervisorQuestion`
        // itself — don't clobber that specific error with a generic message here.
        if step.needsSupervisorInput {
            _ = await answerSupervisorQuestion(
                stepID: step.id, taskID: taskID,
                answer: "Supervisor Feedback: \(trimmed)"
            )
            return
        }

        // Branch B: mid-stream before pause. Append feedback message + set revisionComment gate.
        // Re-verify status inside the closure — mutateTask runs async and the step could
        // have transitioned out of `.paused` between the outer guard and this mutation
        // (e.g. if resumeRun fired concurrently). `mutateTask` returning true means
        // "persisted" — NOT "mutation did something" — so we pre-check and fail loudly.
        let stepIDToMutate = step.id
        let applied = await mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(
                      where: { $0.id == stepIDToMutate && $0.status == .paused }
                  )
            else { return }
            task.runs[runIndex].steps[stepIndex].messages.append(StepMessage(
                role: .supervisor,
                content: "Supervisor Feedback: \(trimmed)"
            ))
            task.runs[runIndex].steps[stepIndex].revisionComment = trimmed
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
            task.runs[runIndex].updatedAt = MonotonicClock.shared.now()
        }
        // Verify the mutation actually landed — re-read and look for the appended message.
        if applied,
           let updated = loadedTask(taskID)?.runs.last?.steps.first(where: { $0.id == stepIDToMutate }),
           updated.revisionComment == trimmed {
            await resumeRun(taskID: taskID)
        } else {
            lastErrorMessage = "Correction could not be applied — step state changed."
        }
    }

    /// Supervisor requests changes for a role, appending feedback and transitioning to `.revisionRequested`.
    func requestRevision(taskID: Int, roleID: String, comment: String) async {
        await mutateTask(taskID: taskID) { task in
            guard var run = task.runs.last else { return }
            run.roleStatuses[roleID] = .revisionRequested
            if let stepIndex = run.steps.firstIndex(where: { $0.effectiveRoleID == roleID }) {
                var step = run.steps[stepIndex]
                step.messages.append(StepMessage(
                    role: .supervisor,
                    content: "Supervisor Feedback: \(comment)"
                ))
                run.steps[stepIndex] = step
            }
            run.updatedAt = MonotonicClock.shared.now()
            task.runs[task.runs.count - 1] = run
        }
        notifyEngineExternalEvent(taskID: taskID)
    }
}
