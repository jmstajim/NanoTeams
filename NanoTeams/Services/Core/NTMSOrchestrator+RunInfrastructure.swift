import Foundation

extension NTMSOrchestrator {

    // MARK: - Run Infrastructure

    /// Creates a fresh run and makes it the active run for a task.
    ///
    /// Persists through `mutateTask` rather than by hand. The hand-rolled version
    /// re-implemented that method's active/background branching, but wrote to disk
    /// with a SYNCHRONOUS `repository.updateTaskOnly` on the MainActor — the only
    /// blocking write left on the task-creation path, and the opposite of the shape
    /// CLAUDE.md invariant #6 prescribes (in-memory commit synchronously, JSON encode
    /// and atomic write detached).
    func createNewRun(taskID: Int) async {
        guard let task = loadedTask(taskID) else { return }
        // Resolved OUT here, not inside the closure: it copies a whole `Team` (roles,
        // artifacts, settings, layout, three prompt templates) and depends only on
        // fields the mutation below never touches.
        let team = resolvedTeam(for: task)

        // A new run is a fresh look: the `CACHE ×N` pill should count THIS run's misses, not
        // every miss since launch, and the banner latch must re-arm for it. Scoped to this task
        // so the Autovisor's once-a-minute run cannot zero the counts of the user's own tasks.
        prefixCacheReporter.resetCounters(forTaskID: taskID)

        await mutateTask(taskID: taskID) { task in
            // Clear closedAt so the new run goes through needsSupervisorAcceptance when it
            // finishes, rather than auto-resolving to .done from the previous closure.
            task.closedAt = nil
            // Same "a new run is a fresh look" rationale: a recovery latch left armed by an
            // earlier launch would make every all-`.pending` moment of THIS run render
            // "Paused". Clearing here (rather than in `startRun`) also covers
            // `ensureTaskHasInitialRunIfNeeded`, the other caller.
            task.clearRecoveryPauseLatch()

            _ = RunService.createTeamRun(task: &task, team: team)
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
            let team = snapshot.map { TeamResolution.team(for: task, in: $0.projection) } ?? nil
            if StatusRecoveryService.recoverStaleStatuses(in: &task, team: team) {
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
        runLogAvailability(taskID: taskID, runID: runID).conversation
    }

    /// Whether this run's two audit logs exist on disk — BOTH answers, ONE ancestor walk.
    ///
    /// Asked once per run selection, not once per body pass. The toolbar used to spell
    /// the pair as two `.disabled(…Exists…)` arguments inside a `Menu`'s `@ViewBuilder`,
    /// which SwiftUI builds EAGERLY — so on every `TeamBoardView` body pass, i.e. on
    /// every `mutateTask` (the view reads `store.activeTask`), it paid:
    ///
    ///  - **two** `ancestorIDs(of:)` calls, each of which builds `parentLinks()` — a
    ///    `[Int: Int]` PLUS a `Set<Int>` over every task the work folder has ever had,
    ///    an append-only index — and
    ///  - up to **four** `fileExists` calls, i.e. blocking `stat(2)` syscalls on the
    ///    MainActor (`networkLogURL` probes current-then-legacy, and `networkLogExists`
    ///    then stat'd the winner a third time).
    ///
    /// `ancestorIDs(of:links:)` exists precisely so a caller can build the hop map once;
    /// the reconcile sweeps use it and this path never got it (CLAUDE.md #51). Here one
    /// walk serves both logs.
    ///
    /// Deliberately NOT maintained on the write side. A log written by an EARLIER app
    /// session is on disk with nothing in memory to say so, so a write-side projection
    /// would report "no log" for every historical run until something re-wrote it —
    /// trading a cost bug for a correctness one. The disk is the source of truth; the
    /// fix is asking it once per selection instead of once per event.
    func runLogAvailability(taskID: Int, runID: Int) -> RunLogAvailability {
        guard let workFolderRoot = workFolderURL else { return RunLogAvailability() }
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let ancestors = snapshot?.tasksIndex.ancestorIDs(of: taskID) ?? []
        let conversation = fileManager.fileExists(
            atPath: paths.conversationLogURL(
                taskID: taskID, runID: runID, ancestors: ancestors).path)
        let network = fileManager.fileExists(
            atPath: paths.networkLogJSONL(
                taskID: taskID, runID: runID, ancestors: ancestors).path)
            || fileManager.fileExists(
                atPath: paths.legacyNetworkLogJSON(
                    taskID: taskID, runID: runID, ancestors: ancestors).path)
        return RunLogAvailability(conversation: conversation, network: network)
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
        runLogAvailability(taskID: taskID, runID: runID).network
    }

}
