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
