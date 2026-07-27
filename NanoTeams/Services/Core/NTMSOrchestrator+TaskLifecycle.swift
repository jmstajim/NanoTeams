import Foundation

/// Task CRUD: create, switch, remove, close, update title.
extension NTMSOrchestrator {

    // MARK: - Task CRUD

    @discardableResult
    func createTask(title: String, supervisorTask: String, preferredTeamID: NTMSID? = nil, makeActive: Bool = true) async -> Int? {
        guard let url = workFolderURL else { return nil }
        // Top-level `createTask` synchronously writes `activeTaskID` (repo
        // line 84-87). Without flushing the fast-path chain first, a still-
        // in-flight detached pointer write from a prior `switchTask` would
        // land AFTER our sync write and revert disk to the previous task.
        // (`makeActive: false` skips the active-pointer write, but flushing is
        // harmless and keeps the chain ordering invariant.)
        await flushPendingActiveTaskWrite()
        do {
            let (snapshot, taskID) = try taskService.createTask(at: url, title: title, supervisorTask: supervisorTask, preferredTeamID: preferredTeamID, makeActive: makeActive)
            apply(snapshot)
            return taskID
        } catch {
            self.lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func switchTask(to taskID: Int?) async {
        // Same-task re-entry is a no-op. Two MainLayoutView observers (`.task`
        // on the loader and `onChange(of: selectedItem)`) can race to this
        // method on the same id; the second one would otherwise re-read disk
        // and trigger a redundant `apply(snapshot)` cascade.
        if taskID != nil, taskID == self.activeTaskID { return }
        // DO NOT stop engines — just change UI focus
        guard let url = workFolderURL else { return }

        // Fast path: the target task is already in `loadedTasks`. Promote it
        // to active in memory and skip the cold-path disk reads — the cached
        // snapshot is authoritative. The `activeTaskID` pointer is then
        // persisted off-MainActor for app-restart restoration; on a real
        // disk error the user is told their selection won't survive a restart.
        if let targetID = taskID,
           var snapshot = self.snapshot,
           let cachedTask = snapshot.loadedTasks[targetID] {
            if let oldTaskID = activeTaskID, let oldTask = activeTask, oldTaskID != targetID {
                snapshot.loadedTasks[oldTaskID] = oldTask
            }
            snapshot.activeTaskID = targetID
            snapshot.activeTask = cachedTask
            snapshot.loadedTasks.removeValue(forKey: targetID)
            apply(snapshot)
            // Persist the active-task pointer before returning, chained through
            // `pendingActiveTaskWrite` so two fast-path switches issued in
            // rapid succession commit their disk writes in MainActor-invocation
            // order. The new Task captures `previous` by closure — that
            // capture (not the orchestrator slot) is what extends the chain.
            // The detached body runs `setActiveTaskID` off MainActor (skips
            // the `assembleContext` rebuild that `setActiveTask` would do,
            // since the in-memory snapshot we just `apply`-ed is already
            // authoritative). `try?` on the predecessor's `.value` so a
            // previous failure surfaces via its own banner without throwing
            // through and stopping our own write — but our caller still
            // blocks on `await write.value` below, so latency compounds
            // across rapid clicks against a slow disk. Other writers of
            // `activeTaskID` (slow-path `switchTask`, `createTask`,
            // `removeTask`) must call `flushPendingActiveTaskWrite()` first,
            // otherwise their sync write races the chain's detached body.
            let repo = repository
            let previous = pendingActiveTaskWrite
            let write = Task<Void, Error> {
                _ = try? await previous?.value
                try await Task.detached(priority: .userInitiated) {
                    try repo.setActiveTaskID(at: url, taskID: targetID)
                }.value
            }
            pendingActiveTaskWrite = write
            do {
                try await write.value
            } catch {
                self.lastErrorMessage = activeTaskPointerErrorMessage(for: error)
            }
            await ensureDelegationDescendantsLoaded(of: targetID)
            return
        }

        // Slow path's `setActiveTask` write goes through `writeActiveTaskID`
        // synchronously, bypassing the chain. Flush any in-flight fast-path
        // write first so a fast(A)→slow(B) sequence doesn't end with A on
        // disk because Q_A's detached body landed after the slow-path sync
        // write.
        await flushPendingActiveTaskWrite()
        do {
            let snapshot = try taskService.switchTask(at: url, to: taskID)
            apply(snapshot)
            // Restore delegation history: descendants of the new active task
            // may not yet be in `loadedTasks` (the previous active task only
            // had its own descendants pulled in).
            await ensureDelegationDescendantsLoaded(of: taskID)
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    func removeTask(_ taskID: Int) async {
        await removeTask(taskID, visited: [])
        // Eviction just dropped the removed task (and its delegation children)
        // from `loadedTasks`, de-referencing any generated-team per-role
        // override models — no other trigger sees a task deletion. One sweep
        // after the whole cascade, not one per recursive child. Silent
        // (housekeeping, not a user "unload this" request) — see
        // `sweepResidencyAfterEngineTransition`.
        await reconcileChatModelResidency()
    }

    /// Internal recursive variant with a visited-set cycle guard. Defends
    /// against a corrupted `tasks_index.json` self-cycle that would
    /// otherwise stack-overflow when this recurses through `childTaskIDs`.
    private func removeTask(_ taskID: Int, visited: Set<Int>) async {
        if visited.contains(taskID) { return }
        var nextVisited = visited
        nextVisited.insert(taskID)

        // Recursively remove delegated children FIRST so their orphaned engines/queues
        // don't outlive the parent's record. We snapshot childTaskIDs before any
        // mutation because each per-child `removeTask` call rewrites the tasks index.
        let children = childTaskIDs(of: taskID)
        for child in children {
            await removeTask(child, visited: nextVisited)
        }

        // Stop engine for this task if running
        stopEngine(for: taskID)
        llmExecutionService.cancelExecutions(forTaskID: taskID)
        // Drop any queued chat messages for this task. `handleActiveTaskClosedAtChanged`
        // only catches active-task close (its onChange watches `activeTask?.closedAt`),
        // so without this a removed background task leaks orphan queue entries that the
        // wake-up branch in `tryFlushQueuedMessages` would then burn empty `Task { resumeRun }`s on.
        quickCaptureFormState?.clearQueuedMessages(for: taskID)

        guard let url = workFolderURL else { return }
        // `deleteTask` for the active task synchronously picks a fallback and
        // writes `activeTaskID` (repo line 160-165), bypassing the chain.
        // Flush first so a still-in-flight fast-path write can't land after
        // and overwrite the fallback with the just-deleted task id.
        await flushPendingActiveTaskWrite()
        do {
            let snapshot = try taskService.removeTask(at: url, taskID: taskID)
            apply(snapshot)
            evictLoadedTask(taskID)
            // If the removed task was active, the repository picked a fallback
            // top-level task as the new active. That fallback may have its own
            // delegation history on disk that wasn't loaded earlier — restore
            // it now so the activity feed/graph render correctly without
            // requiring another switchTask round-trip.
            await ensureDelegationDescendantsLoaded(of: self.activeTaskID)
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    func updateTaskTitle(id: Int, title: String) async {
        // Sidebar context-menu can target a task evicted since app restart.
        await ensureTaskLoaded(id)
        // If the load itself failed (corrupt / missing task.json), `lastErrorMessage`
        // already carries the actionable disk error — bail out so `mutateTask`'s
        // background-branch guard doesn't overwrite it with the generic
        // "Cannot persist task N: task not loaded." message.
        guard loadedTask(id) != nil else { return }
        await mutateTask(taskID: id) { $0.title = title }
    }

    /// Supervisor explicitly closes/accepts a completed task, transitioning it to `.done`.
    /// Returns `true` if the mutation persisted successfully.
    // Deliberately NO residency sweep on close: `closeTask` keeps
    // `generatedTeam` and the task stays in `loadedTasks`, so its per-role
    // override models remain referenced — correct, because the task can be
    // reopened (`restartRole` clears `closedAt`). The engine-transition sweep
    // (`sweepResidencyAfterEngineTransition`) already covers the moment this
    // task's streams end; deletion/eviction sweeps cover the de-reference.
    func closeTask(taskID: Int) async -> Bool {
        // Cancel all in-flight LLM executions (bulk API, matches pauseRun/removeTask pattern)
        llmExecutionService.cancelExecutions(forTaskID: taskID)

        // Sidebar → right-click → "Close Chat" / "Accept & Close" can target a
        // task that hasn't been re-loaded since app restart (only the active
        // task is hydrated by `openWorkFolder`). Without this load,
        // `mutateTask`'s background branch surfaces "Cannot persist task N:
        // task not loaded." and the close silently drops. Matches the
        // convention in `startRun` / `restartRole` / `resumeRun` of loading
        // at the orchestrator entry point. `stopEngine` below cleans up any
        // engine state that `ensureTaskLoaded`'s `syncEngineStateFromRun`
        // briefly seeds.
        await ensureTaskLoaded(taskID)
        // If the load itself failed (corrupt / missing task.json), bail out so
        // `mutateTask`'s background-branch guard doesn't overwrite the actionable
        // disk error in `lastErrorMessage` with the generic "task not loaded"
        // message — same defensive pattern used in `ensureDelegationDescendantsLoaded`.
        guard loadedTask(taskID) != nil else { return false }

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
            // Finalize every remaining non-terminal role to `.done` — closing is an
            // implicit acceptance of completed work AND a finalization of roles that
            // never ran (idle / ready / revisionRequested / needsAcceptance, plus a
            // .working role whose step is still .pending). `.failed` is preserved.
            // Supersedes the old needsAcceptance-only pass; without it the team graph
            // keeps rendering non-terminal pills on the closed task (it reads
            // `roleStatuses` raw).
            run.finalizeRoleStatusesForClose()
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

    /// User-facing message for an active-task pointer write failure. Classifies
    /// the two recoverable Cocoa-error categories — disk full and permission
    /// denied — into actionable hints so the user knows what to do next, falls
    /// back to the underlying `localizedDescription` otherwise. The recoverable
    /// hints PREPEND the OS-level `localizedDescription` (which typically names
    /// the volume / file path) so external-volume failures stay diagnosable.
    ///
    /// `.fileNoSuchFile` deliberately falls through — it's raised when an
    /// intermediate directory was deleted, the volume unmounted, or the path
    /// renamed, none of which are fixed by "re-grant folder access" and the
    /// most common cause is the user just hitting `resetAllData` (which
    /// removes the `.nanoteams/` tree mid-flight while the chain is still
    /// firing). The OS-level message there is more informative than any
    /// hint we can synthesize.
    func activeTaskPointerErrorMessage(for error: Error) -> String {
        let detail: String
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteOutOfSpace:
                detail = "Your disk may be full — free up space and try again. (\(error.localizedDescription))"
            case .fileWriteNoPermission, .fileLocking, .fileWriteVolumeReadOnly:
                detail = "You may need to re-grant folder access in Settings. (\(error.localizedDescription))"
            default:
                detail = error.localizedDescription
            }
        } else {
            detail = error.localizedDescription
        }
        return "Could not save active-task pointer: \(detail) Your task switch will not persist across app restarts."
    }

    /// Awaits any in-flight active-task pointer write so a subsequent
    /// synchronous repository write (top-level `createTask`, `deleteTask`
    /// active-task fallback, slow-path `switchTask`) lands strictly AFTER
    /// the chain's detached body completes its disk write. Without this
    /// guard only the fast-path-to-fast-path ordering is serialized; mixing
    /// in any unchained writer reintroduces the race the chain was meant
    /// to fix. `try?` so a prior failure (logged via its own banner)
    /// doesn't propagate into the caller's flow.
    func flushPendingActiveTaskWrite() async {
        _ = try? await pendingActiveTaskWrite?.value
    }

}
