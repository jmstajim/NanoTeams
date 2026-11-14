import Foundation

/// What `mutateWorkFolder` did with a closure's changes — the durable answer to "did it land?",
/// which the single-shot `lastErrorMessage` slot cannot give (CLAUDE.md Swift Style #5): the banner consumes
/// it on render, and a repeated message never differs from the one before.
nonisolated enum WorkFolderMutationOutcome: Equatable, Sendable {
    /// Every file the changes touched was written.
    case persisted
    /// The closure changed nothing, so nothing was written.
    case unchanged
    /// Nothing was written, or not all of it. `reason` is also what `lastErrorMessage` showed.
    case failed(reason: String)

    /// `nil` when the changes are on disk, or there were none.
    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

/// Whose `ProjectSettings` a context handed to `NTMSOrchestrator.apply(_:settings:)` carries.
///
/// Every repository writer returns a whole `WorkFolderContext`, and the ones that write
/// `workfolder.json`, `teams.json`, `tools.json` or `tasks/` fill its settings by reading
/// `settings.json` — a copy of the file, not of this process's settings. Until 2026-11-12 `apply`
/// took that copy into memory whatever wrote it; on 8 November the file held what another
/// NanoTeams process had just written (its auto-off timer turned the Autovisor off), and the
/// agent's task, created a fraction of a second after its readiness gate passed, ran as if a
/// person were present (F6 C1). The folder lock (`WorkFolderInstanceLock`) keeps a second process
/// out; this keeps a copy read back by a writer that did not own the file out of memory.
nonisolated enum AppliedSettings: Equatable, Sendable {
    /// The write did not own `settings.json`: the copy it read back is discarded and the settings
    /// in memory stay. A context of another folder, or the first one, still brings its own.
    case keepInMemory
    /// The context's settings are the folder's: an open or a reset read them, or this write is the
    /// one that wrote them.
    case adopt
    /// Re-read from disk after a write failed partway: adopted, and what it changes about the
    /// Autovisor goes through the seam a switch takes (`adoptAutovisorSettingsResynced`).
    case resyncFromDisk
}

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
        upsertTaskSummary(task.toSummary(), in: &snap)
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
    ///
    /// Every refusal is surfaced in `lastErrorMessage` AND returned, the no-folder guards
    /// included: until 2026-11-08 those two returned in silence, so a caller that waited on a
    /// write it could not make — the Team Editor's Save — read the silence as success.
    @discardableResult
    func mutateWorkFolder(_ mutate: (inout WorkFolderProjection) -> Void) async -> WorkFolderMutationOutcome {
        let write = persistWorkFolderMutation(mutate)
        if let teams = write.teamsWritten {
            // A team this write replaced no longer has a failed edit as its newest write: the
            // Team Editor's banner stops reporting one (`TeamEditCommitQueue.teamsWereWritten`).
            teamEdits.teamsWereWritten(
                replacing: teams.before, with: teams.after, editedIn: currentFolderLifecycle)
            // Per-role `llmOverride`s are settings slots too — clearing one
            // in the Role Editor, or deleting a team, orphans whatever
            // model it pinned. Nothing else observes team state, and
            // per-role overrides are exactly the multiplier that let
            // several chat models pile up resident at once.
            await reconcileAndReportResidency()
        }
        return write.outcome
    }

    /// The write behind the Team Editor's commit queue (`teamEdits`): one team replaced whole by
    /// the copy the editor holds.
    ///
    /// Refused, with the reason surfaced, when that copy was read in a folder lifecycle that is
    /// no longer current — template teams share ids across folders, so it would replace the next
    /// folder's team of the same id — or when the folder no longer has the team: replacing
    /// nothing is not a save.
    ///
    /// Synchronous, unlike `mutateWorkFolder`: the residency reconcile a teams write calls for is
    /// not run here but owed by the queue after the write (`reconcileAfterTeamWrites`), so a Save
    /// waits for `teams.json` and not for a model server's listing.
    func commitEditedTeam(_ team: Team, editedIn lifecycle: WorkFolderLifecycle) -> WorkFolderMutationOutcome {
        guard isCurrentFolderLifecycle(lifecycle) else {
            return refuseWorkFolderWrite(
                "Could not save “\(team.name)”: the work folder changed before the edit was written.")
        }
        var replaced = false
        let write = persistWorkFolderMutation { projection in
            guard let index = projection.teams.firstIndex(where: { $0.id == team.id }) else { return }
            projection.teams[index] = team
            replaced = true
        }
        guard replaced || write.outcome.failureReason != nil else {
            return refuseWorkFolderWrite(
                "Could not save “\(team.name)”: the team is no longer in this work folder. "
                    + "It may have been deleted in another view.")
        }
        return write.outcome
    }

    /// The teams a write of `teams.json` replaced and the teams it wrote — what such a write
    /// leaves owed: the Team Editor's banner rows (`TeamEditCommitQueue.teamsWereWritten`) and
    /// the residency reconcile. Carried out of the write by the projection it unwrapped, so the
    /// caller never re-reads the snapshot as an optional it has to default.
    private struct TeamsWritten {
        let before: [Team]
        let after: [Team]
    }

    /// `mutateWorkFolder` up to its residency reconcile: the closure applied, the changed files
    /// written, memory re-synced. `teamsWritten` is set when `teams.json` was among the files
    /// written — the caller owes what a teams write owes.
    private func persistWorkFolderMutation(
        _ mutate: (inout WorkFolderProjection) -> Void
    ) -> (outcome: WorkFolderMutationOutcome, teamsWritten: TeamsWritten?) {
        guard let url = workFolderURL else {
            return (refuseWorkFolderWrite("Cannot save work folder changes: no work folder is open."), nil)
        }
        guard var projection = snapshot?.projection else {
            return (refuseWorkFolderWrite(
                "Cannot save work folder changes: the work folder's contents are not loaded."), nil)
        }

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
            return (.unchanged, nil)
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
            // The in-memory active task, handed to every writer instead of letting each
            // one re-read and re-hydrate it. None of these three writes can change the
            // task's CONTENT — they write workfolder.json / settings.json / teams.json —
            // so re-reading it cost O(entire conversation history) on the MainActor per
            // call and, worse, could hand `apply(_:)` a disk copy older than this one
            // (`mutateTask` commits in memory first and detaches the write — invariant
            // #6). `assembleContext` still re-reads when the id no longer matches, which
            // is the only case where the caller's copy is not the active task.
            let cachedActiveTask = activeTask
            var lastContext: WorkFolderContext?
            if stateChanged {
                lastContext = try repository.updateWorkFolderState(
                    at: url, activeTask: cachedActiveTask) { $0 = projection.state }
            }
            if settingsChanged {
                lastContext = try repository.updateSettings(
                    at: url, activeTask: cachedActiveTask) { $0 = projection.settings }
            }
            if teamsChanged {
                lastContext = try repository.updateTeams(
                    at: url, activeTask: cachedActiveTask) { $0 = projection.teams }
            }
            // When `settings.json` was among the files written, the context's settings are this
            // closure's (`updateSettings` wrote them and any writer after it read them back);
            // otherwise they are a copy of the file and the settings in memory stand.
            if let ctx = lastContext {
                apply(ctx, settings: settingsChanged ? .adopt : .keepInMemory)
            }
            // `after` is the array the writer was handed — what `apply(ctx)` has just made the
            // snapshot's teams.
            return (.persisted, teamsChanged ? TeamsWritten(before: before.teams, after: projection.teams) : nil)
        } catch {
            let fileHint = partialWriteFileHint(
                stateChanged: stateChanged,
                settingsChanged: settingsChanged,
                teamsChanged: teamsChanged
            )
            let reason = "Failed to persist work folder changes\(fileHint): "
                + "\(error.localizedDescription)"
            self.lastErrorMessage = reason
            // Re-sync memory with whatever actually landed on disk. If even
            // this fails, the in-memory snapshot stays as `before` (closure
            // mutation is discarded) and the user sees the error.
            if let ctx = try? repository.openOrCreateWorkFolder(at: url) {
                apply(ctx, settings: .resyncFromDisk)
            }
            return (.failed(reason: reason), nil)
        }
    }

    /// Surfaces `reason` and answers with it — every refusal on the work-folder write path, so
    /// the person and the caller that waited hear the same words.
    private func refuseWorkFolderWrite(_ reason: String) -> WorkFolderMutationOutcome {
        lastErrorMessage = reason
        return .failed(reason: reason)
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

// MARK: - The Team Editor's folder

/// The orchestrator is the folder `teamEdits` writes into. `isCurrentFolderLifecycle` is the one
/// in `NTMSOrchestrator+WorkFolderManagement`.
extension NTMSOrchestrator: TeamEditCommitQueue.Folder {
    func writeEditedTeam(_ team: Team, editedIn lifecycle: WorkFolderLifecycle) async -> WorkFolderMutationOutcome {
        commitEditedTeam(team, editedIn: lifecycle)
    }

    /// Per-role `llmOverride`s are settings slots too: clearing one in the Role Editor orphans the
    /// model it pinned — the reason `mutateWorkFolder` reconciles after every teams write.
    func reconcileAfterTeamWrites() async {
        await reconcileAndReportResidency()
    }

    /// The team of `teamID` as the open folder stores it — what the Team Editor's binding reads once
    /// no staged value covers it. `nil` once `lifecycle` has ended: a binding that outlived a folder
    /// switch keeps the copy it was rendered with rather than read the next folder's team of the
    /// same id.
    func storedTeam(_ teamID: NTMSID, editedIn lifecycle: WorkFolderLifecycle) -> Team? {
        guard isCurrentFolderLifecycle(lifecycle) else { return nil }
        return workFolder?.teams.first { $0.id == teamID }
    }
}
