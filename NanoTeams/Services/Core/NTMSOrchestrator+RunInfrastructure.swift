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
        // Same "a new run is a fresh look" rationale: a recovery latch left armed by an
        // earlier launch would make every all-`.pending` moment of THIS run render
        // "Paused". Clearing here (rather than in `startRun`) also covers
        // `ensureTaskHasInitialRunIfNeeded`, the other caller.
        task.clearRecoveryPauseLatch()

        let team = resolvedTeam(for: task)
        _ = RunService.createTeamRun(task: &task, team: team)

        // A new run is a fresh look: the `CACHE ×N` pill should count THIS run's misses, not
        // every miss since launch, and the banner latch must re-arm for it. Scoped to this task
        // so the Autovisor's once-a-minute run cannot zero the counts of the user's own tasks.
        prefixCacheReporter.resetCounters(forTaskID: taskID)

        do {
            try repository.updateTaskOnly(at: url, task: task)
            if taskID == activeTaskID {
                applyTaskUpdate(task)
            } else {
                // Background branch: refresh BOTH loadedTasks and the tasks-index
                // summary so the sidebar status label for a just-restarted background
                // task isn't stale (same lockstep rule as `mutateTask`'s else branch).
                refreshBackgroundTaskInMemory(task)
            }
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    /// Ensures a task is loaded into memory (for background execution).
    ///
    /// Loading is a background write path when recovery fires: `updateTaskOnly`
    /// refreshes the DISK index, so the in-memory snapshot must move in lockstep
    /// via `refreshBackgroundTaskInMemory` — a bare `loadedTasks[taskID] = task`
    /// would leave a stale sidebar status label until the next mutation.
    ///
    /// - Returns: `true` when stale-status recovery fired AND was persisted to
    ///   disk; `false` for a clean load, a short-circuit, a load failure, or a
    ///   recovery whose persist failed. The startup sweep
    ///   (`recoverStaleStatusesAcrossIndex`) uses this to decide whether the
    ///   disk index still needs a convergence write.
    @discardableResult
    func ensureTaskLoaded(_ taskID: Int) async -> Bool {
        if loadedTask(taskID) != nil { return false }
        guard let url = workFolderURL else { return false }
        do {
            var task = try repository.loadTask(at: url, taskID: taskID)
            var recoveryPersisted = false
            let teamSettings = snapshot.map { TeamResolution.teamSettings(for: task, in: $0.projection) } ?? nil
            if StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: teamSettings) {
                // Persist recovered status. If this fails, memory and disk
                // diverge — pause/resume cascades that re-read disk later see
                // a different task than the in-memory snapshot. Surface the
                // failure rather than silently swallowing via `try?`.
                do {
                    try repository.updateTaskOnly(at: url, task: task)
                    recoveryPersisted = true
                } catch {
                    self.lastErrorMessage = "Could not persist recovered status for task #\(taskID): \(error.localizedDescription). In-memory state may diverge from disk."
                }
            }
            refreshBackgroundTaskInMemory(task)
            syncEngineStateFromRun(taskID: taskID, task: task)
            return recoveryPersisted
        } catch {
            self.lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func taskSummaries(filter: TaskFilter) -> [TaskSummary] {
        taskService.taskSummaries(from: snapshot, filter: filter)
    }

    func conversationLogURL(taskID: Int, runID: Int) -> URL? {
        guard let workFolderRoot = workFolderURL else { return nil }
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let ancestors = snapshot?.tasksIndex.ancestorIDs(of: taskID) ?? []
        return paths.conversationLogURL(taskID: taskID, runID: runID, ancestors: ancestors)
    }

    func conversationLogExists(taskID: Int, runID: Int) -> Bool {
        guard let url = conversationLogURL(taskID: taskID, runID: runID) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func networkLogURL(taskID: Int, runID: Int) -> URL? {
        guard let workFolderRoot = workFolderURL else { return nil }
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let ancestors = snapshot?.tasksIndex.ancestorIDs(of: taskID) ?? []
        let current = paths.networkLogJSONL(taskID: taskID, runID: runID, ancestors: ancestors)
        if fileManager.fileExists(atPath: current.path) { return current }
        // Pre-JSONL runs wrote a JSON array; their logs are still worth revealing.
        let legacy = paths.legacyNetworkLogJSON(taskID: taskID, runID: runID, ancestors: ancestors)
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        return current
    }

    func networkLogExists(taskID: Int, runID: Int) -> Bool {
        guard let url = networkLogURL(taskID: taskID, runID: runID) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

}
