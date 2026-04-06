import Foundation

/// Task CRUD: create, switch, remove, close, update title.
extension NTMSOrchestrator {

    // MARK: - Task CRUD

    @discardableResult
    func createTask(title: String, supervisorTask: String, preferredTeamID: NTMSID? = nil) async -> Int? {
        guard let url = workFolderURL else { return nil }
        do {
            let snapshot = try taskService.createTask(at: url, title: title, supervisorTask: supervisorTask, preferredTeamID: preferredTeamID)
            apply(snapshot)
            return snapshot.activeTaskID
        } catch {
            self.lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func switchTask(to taskID: Int?) async {
        // DO NOT stop engines — just change UI focus
        guard let url = workFolderURL else { return }
        do {
            let snapshot = try taskService.switchTask(at: url, to: taskID)
            apply(snapshot)
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    func removeTask(_ taskID: Int) async {
        // Stop engine for this task if running
        stopEngine(for: taskID)
        llmExecutionService.cancelExecutions(forTaskID: taskID)

        guard let url = workFolderURL else { return }
        do {
            let snapshot = try taskService.removeTask(at: url, taskID: taskID)
            apply(snapshot)
            evictLoadedTask(taskID)
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    func updateTaskTitle(id: Int, title: String) async {
        await mutateTask(taskID: id) { $0.title = title }
    }

    /// Supervisor explicitly closes/accepts a completed task, transitioning it to `.done`.
    /// Returns `true` if the mutation persisted successfully.
    func closeTask(taskID: Int) async -> Bool {
        // Cancel all in-flight LLM executions (bulk API, matches pauseRun/removeTask pattern)
        llmExecutionService.cancelExecutions(forTaskID: taskID)

        let success = await mutateTask(taskID: taskID) { task in
            task.closedAt = MonotonicClock.shared.now()
            task.updatedAt = MonotonicClock.shared.now()

            // Finalize any non-done steps and their roles.
            // Critical for chat mode where advisory roles run indefinitely.
            // No-op for non-chat tasks (all steps already .done at acceptance time).
            guard var run = task.runs.last else { return }
            let now = MonotonicClock.shared.now()
            for i in run.steps.indices {
                let status = run.steps[i].status
                if status == .running || status == .paused || status == .needsSupervisorInput {
                    run.steps[i].status = .done
                    run.steps[i].completedAt = now
                    run.roleStatuses[run.steps[i].effectiveRoleID] = .done
                }
            }
            run.updatedAt = now
            task.runs[task.runs.count - 1] = run
        }
        guard success else { return false }
        stopEngine(for: taskID)
        return true
    }

    func ensureTaskHasInitialRunIfNeeded(taskID: Int) async {
        guard let task = loadedTask(taskID), task.runs.isEmpty else { return }
        await createNewRun(taskID: taskID)
    }

}
