import Foundation

// In-memory + persisted state mutation core: mutateTask (the hot path),
// mutateWorkFolder (diff-driven writes), and the snapshot apply helpers.
// Extracted from the NTMSOrchestrator core.
extension NTMSOrchestrator {

    // MARK: - Task Mutation

    /// Mutates a task and persists it to disk. Returns `true` when the task was
    /// successfully persisted. Does NOT indicate whether the mutation closure made
    /// meaningful changes — callers that need that guarantee must check state first.
    @discardableResult
    func mutateTask(taskID: Int, _ mutate: (inout NTMSTask) -> Void) async -> Bool {
        guard let url = workFolderURL else {
            self.lastErrorMessage = "Cannot persist task \(taskID): no work folder is open."
            return false
        }

        // In-memory mutate + snapshot apply MUST run synchronously on
        // `@MainActor` so concurrent callers (parallel role engines per
        // CLAUDE.md invariant #45, streaming + tool-result writes on the
        // same task) cannot read a stale `activeTask` between our mutate
        // and apply. Only the JSON encode + atomic file write detaches —
        // that's where the main-thread cost is. Trade-off: in-memory may
        // be ahead of disk briefly; on disk failure we surface
        // `lastErrorMessage` but keep the in-memory mutation. See plan
        // C1 in `.claude/plans/snoopy-sprouting-tiger.md`.
        if taskID == activeTaskID {
            guard var task = activeTask else {
                self.lastErrorMessage = "Cannot persist active task \(taskID): task not loaded."
                return false
            }
            mutate(&task)
            task.updatedAt = MonotonicClock.shared.now()
            applyTaskUpdate(task)
            let repoCopy = repository
            let taskCopy = task
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repoCopy.updateTaskOnly(at: url, task: taskCopy)
                }.value
                return true
            } catch is CancellationError {
                return false
            } catch {
                self.lastErrorMessage = "Failed to save task: \(error.localizedDescription)"
                return false
            }
        } else {
            guard var task = loadedTask(taskID) else {
                self.lastErrorMessage = "Cannot persist task \(taskID): task not loaded."
                return false
            }
            mutate(&task)
            task.updatedAt = MonotonicClock.shared.now()
            // Update the in-memory snapshot synchronously on @MainActor (before the
            // detached disk write) — both `loadedTasks` AND the tasks index. See
            // `refreshBackgroundTaskInMemory` for why the index must move in lockstep.
            refreshBackgroundTaskInMemory(task)
            let repoCopy = repository
            let taskCopy = task
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repoCopy.updateTaskOnly(at: url, task: taskCopy)
                }.value
                return true
            } catch is CancellationError {
                return false
            } catch {
                self.lastErrorMessage = "Failed to save task: \(error.localizedDescription)"
                return false
            }
        }
    }

    /// Refreshes the in-memory snapshot for a **background** (non-active) task —
    /// both `loadedTasks` AND the tasks-index summary — synchronously on @MainActor.
    /// This is the background-branch mirror of what `applyTaskUpdate` does for the
    /// active task. Every background write path (`mutateTask`'s else branch,
    /// `createNewRun`) must route through here: the sidebar reads `taskSummaries`
    /// from `snapshot.tasksIndex`, so a path that updates `loadedTasks` alone leaves
    /// a stale status label for any non-active task mutating in the background —
    /// recurrence/timeout firing, delegation children, and parallel multi-task runs
    /// all hit this. Keeping it in one helper stops the two call sites from drifting.
    func refreshBackgroundTaskInMemory(_ task: NTMSTask) {
        guard var snap = snapshot else { return }
        snap.loadedTasks[task.id] = task
        let summary = task.toSummary()
        if let idx = snap.tasksIndex.tasks.firstIndex(where: { $0.id == summary.id }) {
            snap.tasksIndex.tasks[idx] = summary
        } else {
            snap.tasksIndex.tasks.append(summary)
        }
        snap.tasksIndex.tasks.sort(by: { $0.updatedAt > $1.updatedAt })
        snapshot = snap
    }

    // MARK: - Work Folder Mutation

    /// Atomic mutation entry point for the work folder projection.
    ///
    /// Closure bodies can freely mutate any combination of `state` (identity + active
    /// pointers), `settings` (user prefs), or `teams` (team configs). After the closure
    /// runs, the orchestrator diffs each sub-component and writes only the files that
    /// actually changed — giving you "one file per closure" granularity through
    /// runtime diff instead of through type-level API splits.
    ///
    /// Closure-body rename cheatsheet (vs the old `(inout WorkFolder)` signature):
    /// - `wf.description`        → `proj.settings.context`
    /// - `wf.descriptionPrompt`  → `proj.settings.contextPrompt`
    /// - `wf.selectedScheme`     → `proj.settings.selectedScheme`
    /// - `wf.teams.append(...)`  — unchanged (teams on top level of projection)
    /// - `wf.activeTeamID = ...` — unchanged (state.activeTeamID aliased on projection)
    func mutateWorkFolder(_ mutate: (inout WorkFolderProjection) -> Void) async {
        guard let url = workFolderURL else { return }
        guard var projection = snapshot?.projection else { return }

        let before = projection
        mutate(&projection)

        // Decide which sub-components changed.
        //
        // `state` and `settings` have clean structural `Hashable` — normal `!=`
        // works and is cheap.
        //
        // `teams` cannot use `!=` directly: `Team.==` is a custom shortcut that
        // only compares `id` + `updatedAt` (for @Observable performance), so
        // structural changes to roles/artifacts without a timestamp bump would
        // register as equal (CLAUDE.md pitfall #45). Fall back to a JSON-encoded
        // comparison for deep structural equality — and only for `teams`, where
        // the workaround is actually needed.
        let stateChanged = projection.state != before.state
        let settingsChanged = projection.settings != before.settings

        let teamsChanged: Bool
        do {
            let encoder = JSONCoderFactory.makePersistenceEncoder()
            teamsChanged = try encoder.encode(projection.teams) != encoder.encode(before.teams)
        } catch {
            // Encoding errors here (e.g. NaN/Infinity in Double fields) are
            // recoverable at the repository layer — the narrow writer will
            // throw with a file-specific error. Fail-safe to "assume changed"
            // so a transient encode hiccup does not silently drop user intent.
            print("[NTMSOrchestrator] WARNING: teams diff encoding failed (\(error)); "
                + "assuming teams changed.")
            teamsChanged = true
        }

        // No-op closure — nothing to write. This is the cheap path for
        // code that computes whether a change is needed inside the closure.
        if !stateChanged && !settingsChanged && !teamsChanged {
            return
        }

        // `updatedAt` on state is bumped by `repository.updateWorkFolderState`
        // directly. Settings/teams-only mutations intentionally do NOT touch
        // state.updatedAt — it tracks when the identity/pointers last changed,
        // not when any sub-file changed.

        // Sequential writes. `AtomicJSONStore.write` is per-file atomic, but
        // cross-file atomicity is not provided — if write #2 or #3 throws, the
        // first write is already on disk. We recover by re-reading the work
        // folder from disk and applying that to memory, so at least the
        // in-memory state matches what landed on disk (the user's partial
        // mutation is visible via lastErrorMessage and the UI reflects reality).
        do {
            var lastContext: WorkFolderContext?
            if stateChanged {
                lastContext = try repository.updateWorkFolderState(at: url) { $0 = projection.state }
            }
            if settingsChanged {
                lastContext = try repository.updateSettings(at: url) { $0 = projection.settings }
            }
            if teamsChanged {
                lastContext = try repository.updateTeams(at: url) { $0 = projection.teams }
            }
            if let ctx = lastContext {
                apply(ctx)
            }
        } catch {
            let fileHint = partialWriteFileHint(
                stateChanged: stateChanged,
                settingsChanged: settingsChanged,
                teamsChanged: teamsChanged
            )
            self.lastErrorMessage = "Failed to persist work folder changes\(fileHint): "
                + "\(error.localizedDescription)"
            // Re-sync memory with whatever actually landed on disk. If even
            // this fails, the in-memory snapshot stays as `before` (closure
            // mutation is discarded) and the user sees the error.
            if let ctx = try? repository.openOrCreateWorkFolder(at: url) {
                apply(ctx)
            }
        }
    }

    /// Produces a human-readable hint about which file(s) the mutation targeted,
    /// used in error messages so users can locate partial-write failures.
    private func partialWriteFileHint(
        stateChanged: Bool,
        settingsChanged: Bool,
        teamsChanged: Bool
    ) -> String {
        var files: [String] = []
        if stateChanged { files.append("workfolder.json") }
        if settingsChanged { files.append("settings.json") }
        if teamsChanged { files.append("teams.json") }
        guard !files.isEmpty else { return "" }
        return " (\(files.joined(separator: ", ")))"
    }

}
