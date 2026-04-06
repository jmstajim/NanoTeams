import Foundation

extension NTMSOrchestrator {

    // MARK: - Run Infrastructure

    /// Creates a fresh run and makes it the active run for a task.
    func createNewRun(taskID: Int) async {
        guard let url = workFolderURL else { return }
        guard var task = loadedTask(taskID) else { return }

        // Clear closedAt so the new run goes through needsSupervisorAcceptance when it finishes,
        // rather than auto-resolving to .done from the previous closure.
        task.closedAt = nil

        let team = resolvedTeam(for: task)
        _ = RunService.createTeamRun(task: &task, team: team)

        do {
            try repository.updateTaskOnly(at: url, task: task)
            if taskID == activeTaskID {
                applyTaskUpdate(task)
            } else {
                self.snapshot?.loadedTasks[taskID] = task
            }
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    /// Ensures a task is loaded into memory (for background execution).
    func ensureTaskLoaded(_ taskID: Int) async {
        if loadedTask(taskID) != nil { return }
        guard let url = workFolderURL else { return }
        do {
            var task = try repository.loadTask(at: url, taskID: taskID)
            if StatusRecoveryService.recoverStaleStatuses(in: &task) {
                try? repository.updateTaskOnly(at: url, task: task)
            }
            snapshot?.loadedTasks[taskID] = task
            if let lastRun = task.runs.last {
                syncEngineStateFromRun(taskID: taskID, run: lastRun)
            }
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    func taskSummaries(filter: TaskFilter) -> [TaskSummary] {
        taskService.taskSummaries(from: snapshot, filter: filter)
    }

    func conversationLogURL(taskID: Int, runID: Int) -> URL? {
        guard let workFolderRoot = workFolderURL else { return nil }
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        return paths.conversationLogURL(taskID: taskID, runID: runID)
    }

    func conversationLogExists(taskID: Int, runID: Int) -> Bool {
        guard let url = conversationLogURL(taskID: taskID, runID: runID) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func networkLogURL(taskID: Int, runID: Int) -> URL? {
        guard let workFolderRoot = workFolderURL else { return nil }
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        return paths.networkLogJSON(taskID: taskID, runID: runID)
    }

    func networkLogExists(taskID: Int, runID: Int) -> Bool {
        guard let url = networkLogURL(taskID: taskID, runID: runID) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

}
