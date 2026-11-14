import Foundation

/// What became of a create whose caller owns its lifecycle (`createTask(…, within:)`), for the
/// caller to report — or not — as the create is its business.
nonisolated enum TaskCreationOutcome: Hashable, Sendable {
    case created(Int)
    /// A folder open began after the caller's lifecycle did: nothing was created, in either
    /// folder, and nothing was surfaced.
    case folderChanged
    /// No folder is open (nothing surfaced), or the write failed (`lastErrorMessage` says why).
    case notCreated
}

/// What became of a removal whose caller owns its lifecycle (`removeTask(_:within:)`), for the
/// caller to report — or not.
nonisolated enum TaskRemovalOutcome: Hashable, Sendable {
    /// The task (and its delegation children) is gone from the folder it was asked from.
    case removed
    /// A folder transition began after the caller's lifecycle did — before the removal, or while
    /// it waited for the pending active-task write: nothing more was removed, in either folder,
    /// and nothing was surfaced.
    case folderChanged
    /// No folder is open (nothing surfaced), or the write failed (`lastErrorMessage` says why).
    case notRemoved
}

/// Task CRUD: create, switch, remove, close, update title.
extension NTMSOrchestrator {

    // MARK: - Task CRUD

    /// What `createTask` says to the person when the work folder changed while it was being
    /// created: nothing was created, in either folder.
    static let createTaskFolderChangedMessage =
        "The task was not created: the work folder changed while it was being created. Create it again here."

    /// What `switchTask` says to the person when the work folder changed before the switch could
    /// land: the task was not opened, and nothing of the folder it belongs to was applied.
    static let switchTaskFolderChangedMessage =
        "The task was not opened: the work folder changed while it was being opened."

    /// What a person's `removeTask` says when the work folder changed before the removal could
    /// land: nothing was deleted, in either folder.
    static let removeTaskFolderChangedMessage =
        "The task was not deleted: the work folder changed while it was being deleted."

    /// A create the PERSON asked for — the command palette, Quick Capture: creates a task in the
    /// open work folder and applies the folder's new snapshot, or answers `nil`, having surfaced
    /// why on `lastErrorMessage` (the no-folder exit alone is silent), which is how every such
    /// caller reads a refusal. A folder change during the create is refused as
    /// `createTaskFolderChangedMessage` — the person pressed create, so the person is told. The
    /// lifecycle is the folder described when the create began (`currentFolderLifecycle`).
    @discardableResult
    func createTask(title: String, supervisorTask: String, preferredTeamID: NTMSID? = nil, makeActive: Bool = true) async -> Int? {
        await createTask(
            title: title,
            supervisorTask: supervisorTask,
            preferredTeamID: preferredTeamID,
            makeActive: makeActive,
            origin: nil
        )
    }

    @discardableResult
    func createTask(
        title: String,
        supervisorTask: String,
        preferredTeamID: NTMSID? = nil,
        makeActive: Bool = true,
        origin: TaskOrigin?,
        requestKey: String? = nil
    ) async -> Int? {
        let lifecycle = currentFolderLifecycle
        let outcome = await createTask(
            title: title, supervisorTask: supervisorTask, preferredTeamID: preferredTeamID,
            makeActive: makeActive, origin: origin, requestKey: requestKey, within: lifecycle)
        switch outcome {
        case .created(let taskID):
            return taskID
        case .folderChanged:
            lastErrorMessage = Self.createTaskFolderChangedMessage
            return nil
        case .notCreated:
            return nil
        }
    }

    func createTask(
        title: String, supervisorTask: String, preferredTeamID: NTMSID? = nil, makeActive: Bool = true,
        within lifecycle: WorkFolderLifecycle
    ) async -> TaskCreationOutcome {
        await createTask(
            title: title,
            supervisorTask: supervisorTask,
            preferredTeamID: preferredTeamID,
            makeActive: makeActive,
            origin: nil,
            requestKey: nil,
            within: lifecycle
        )
    }

    /// A create whose caller owns its lifecycle and reports its outcome itself — the Autovisor
    /// chain (the open's lifecycle, or the toggle's) and the Autovisor's own `create_task` (its
    /// action's). Nothing is surfaced for a folder change: a chain the next open superseded stops,
    /// and the Autovisor's tool answers its model; neither create was asked for by the person, so
    /// "Create it again here." in the next folder's session would be about a task they never saw.
    ///
    /// The one suspension is the flush below; after it, the create goes on only if `lifecycle` is
    /// still current — no folder open has begun since it did. That is the whole folder check, and
    /// it subsumes the URL check it replaced: `workFolderURL` changes only inside an open, after
    /// that open's first line has moved the generation, so a folder whose URL moved is a folder
    /// whose lifecycle ended; the converse does not hold — an open still reading has ended the
    /// lifecycle and not yet moved the URL — which is the stretch the URL check left open
    /// (a create resumed there wrote into the folder being left and applied its snapshot
    /// mid-open, and the palette then selected task N of the next folder). The URL captured at
    /// entry is therefore still the folder's when the lifecycle answers current.
    func createTask(
        title: String,
        supervisorTask: String,
        preferredTeamID: NTMSID? = nil,
        makeActive: Bool = true,
        origin: TaskOrigin?,
        requestKey: String? = nil,
        within lifecycle: WorkFolderLifecycle
    ) async -> TaskCreationOutcome {
        guard let url = workFolderURL else { return .notCreated }
        // Top-level `createTask` synchronously writes `activeTaskID` (repo
        // line 84-87). Without flushing the fast-path chain first, a still-
        // in-flight detached pointer write from a prior `switchTask` would
        // land AFTER our sync write and revert disk to the previous task.
        // (`makeActive: false` skips the active-pointer write, but flushing is
        // harmless and keeps the chain ordering invariant.)
        guard await flushPendingActiveTaskWrite(within: lifecycle) else { return .folderChanged }
        do {
            let (snapshot, taskID) = try taskService.createTask(
                at: url,
                title: title,
                supervisorTask: supervisorTask,
                preferredTeamID: preferredTeamID,
                makeActive: makeActive,
                origin: origin,
                requestKey: requestKey
            )
            // No event for the creation: only the agent that creates a task owns it, and it has
            // the id from its own call (`AutovisorEventKind.Moment`).
            apply(snapshot, settings: .keepInMemory)
            return .created(taskID)
        } catch {
            self.lastErrorMessage = error.localizedDescription
            return .notCreated
        }
    }

    func switchTask(to taskID: Int?) async {
        // Same-task re-entry is a no-op. Two MainLayoutView observers (`.task`
        // on the loader and `onChange(of: selectedItem)`) can race to this
        // method on the same id; the second one would otherwise re-read disk
        // and trigger a redundant `apply(snapshot)` cascade.
        if taskID != nil, taskID == self.activeTaskID { return }
        // The folder the switch is for — the one described now — asked before anything is
        // applied and after every suspension below: a switch that waited while the next folder
        // opened must not apply this folder's snapshot under that folder's URL (the two-folder
        // pairing `discardWorkFolderState` exists to prevent), write this folder's pointer, or
        // load this folder's delegation history into that session. Begun while a transition is
        // under way, it switches nothing: the folder it would act on is the one being left.
        let lifecycle = currentFolderLifecycle
        guard isCurrentFolderLifecycle(lifecycle) else {
            lastErrorMessage = Self.switchTaskFolderChangedMessage
            return
        }
        // DO NOT stop engines — just change UI focus
        guard let url = workFolderURL else { return }
        // A task the folder's index no longer lists was removed: there is nothing to switch to
        // and nothing went wrong. The board asks anyway — `MainLayoutView`'s loader switches to
        // the selected id once the removal moved the folder's active task to its fallback, and
        // it asks while the removal is still suspended in its residency reconcile. Surfacing
        // `taskNotFound` there put a banner on the person's own Delete and turned the agent's
        // `control_task delete` into `COMMAND_FAILED "Task not found"` for a task it had removed
        // (`reportingError` counts every error surfaced during its op; D-M18, 2026-11-12). A task
        // the index still lists whose file is missing is a fault, and the read below reports it.
        if let targetID = taskID,
           let index = snapshot?.tasksIndex,
           !index.tasks.contains(where: { $0.id == targetID }) {
            return
        }

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
            apply(snapshot, settings: .keepInMemory)
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
            var pointerError: Error?
            do {
                try await write.value
            } catch {
                pointerError = error
            }
            // The pointer write suspended. Its failure is this folder's to report, and the
            // delegation history belongs to this folder only.
            guard isCurrentFolderLifecycle(lifecycle) else { return }
            if let pointerError {
                self.lastErrorMessage = activeTaskPointerErrorMessage(for: pointerError)
            }
            await ensureDelegationDescendantsLoaded(of: targetID)
            return
        }

        // Slow path's `setActiveTask` write goes through `writeActiveTaskID`
        // synchronously, bypassing the chain. Flush any in-flight fast-path
        // write first so a fast(A)→slow(B) sequence doesn't end with A on
        // disk because Q_A's detached body landed after the slow-path sync
        // write.
        guard await flushPendingActiveTaskWrite(within: lifecycle) else {
            lastErrorMessage = Self.switchTaskFolderChangedMessage
            return
        }
        do {
            let snapshot = try taskService.switchTask(at: url, to: taskID)
            apply(snapshot, settings: .keepInMemory)
            // Restore delegation history: descendants of the new active task
            // may not yet be in `loadedTasks` (the previous active task only
            // had its own descendants pulled in).
            await ensureDelegationDescendantsLoaded(of: taskID)
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    /// A removal the PERSON asked for — the sidebar, a board: removes the task from the folder
    /// described now, and says so on the banner when the folder changed before it could
    /// (`removeTaskFolderChangedMessage`), the way `createTask` does.
    func removeTask(_ taskID: Int) async {
        let lifecycle = currentFolderLifecycle
        if await removeTask(taskID, within: lifecycle, by: .person) == .folderChanged {
            lastErrorMessage = Self.removeTaskFolderChangedMessage
        }
    }

    /// A removal whose caller owns its lifecycle and reports its outcome itself — the
    /// Autovisor's `control_task delete` (its pass's), `deleteAutovisor` (its own): nothing is
    /// surfaced for a folder change. `actor` asked for it, and the agent that did is not told it
    /// back as an event. The removal flushes the pending active-task write before it
    /// writes, and that flush suspends; after it the removal goes on only while `lifecycle` is
    /// current — `NTMSTask.id` is per folder, and the folder that commits almost always has a
    /// task with the id this removal holds.
    @discardableResult
    func removeTask(_ taskID: Int, within lifecycle: WorkFolderLifecycle, by actor: ControlActor) async -> TaskRemovalOutcome {
        let outcome = await removeTask(taskID, visited: [], lifecycle: lifecycle, by: actor)
        guard outcome != .folderChanged else { return outcome }
        // Eviction just dropped the removed task (and its delegation children)
        // from `loadedTasks`, de-referencing any generated-team per-role
        // override models — no other trigger sees a task deletion. One sweep
        // after the whole cascade, not one per recursive child. Silent
        // (housekeeping, not a user "unload this" request) — see
        // `sweepResidencyAfterEngineTransition`.
        await reconcileChatModelResidency()
        return outcome
    }

    /// Internal recursive variant with a visited-set cycle guard. Defends
    /// against a corrupted `tasks_index.json` self-cycle that would
    /// otherwise stack-overflow when this recurses through `childTaskIDs`.
    private func removeTask(
        _ taskID: Int, visited: Set<Int>, lifecycle: WorkFolderLifecycle, by actor: ControlActor
    ) async -> TaskRemovalOutcome {
        if visited.contains(taskID) { return .removed }
        guard isCurrentFolderLifecycle(lifecycle) else { return .folderChanged }
        var nextVisited = visited
        nextVisited.insert(taskID)

        // Recursively remove delegated children FIRST so their orphaned engines/queues
        // don't outlive the parent's record. We snapshot childTaskIDs before any
        // mutation because each per-child `removeTask` call rewrites the tasks index.
        let children = childTaskIDs(of: taskID)
        for child in children {
            let childOutcome = await removeTask(child, visited: nextVisited, lifecycle: lifecycle, by: actor)
            // Asked after every child, removed or not: a removal suspends after its write too.
            guard childOutcome != .folderChanged, isCurrentFolderLifecycle(lifecycle) else { return .folderChanged }
        }

        // Stop engine for this task if running
        stopEngine(for: taskID, captureSnapshot: false)
        llmExecutionService.cancelExecutions(forTaskID: taskID)
        // Drop any queued chat messages for this task. `handleActiveTaskClosedAtChanged`
        // only catches active-task close (its onChange watches `activeTask?.closedAt`),
        // so without this a removed background task leaks orphan queue entries that the
        // wake-up branch in `tryFlushQueuedMessages` would then burn empty `Task { resumeRun }`s on.
        messageQueue.discardQueuedChatMessage(taskID: taskID)

        guard let url = workFolderURL else { return .notRemoved }
        // `deleteTask` for the active task synchronously picks a fallback and
        // writes `activeTaskID` (repo line 160-165), bypassing the chain.
        // Flush first so a still-in-flight fast-path write can't land after
        // and overwrite the fallback with the just-deleted task id.
        guard await flushPendingActiveTaskWrite(within: lifecycle) else { return .folderChanged }
        let existingTask = loadedTask(taskID)
        let existingSummary = taskFacts.summary(for: taskID)
        let removedParentTaskID = existingTask?.parentTaskID ?? existingSummary?.parentTaskID
        let removedOrigin = existingTask?.origin ?? existingSummary?.origin
        let removedTitle = existingTask?.title ?? existingSummary?.title
        do {
            let snapshot = try taskService.removeTask(at: url, taskID: taskID)
            apply(snapshot, settings: .keepInMemory)
            evictLoadedTask(taskID)
            // A deleted task takes the external agent's calls about it along — the calls that
            // targeted it and the ones whose response named it (an event, a row of a list): their
            // full bodies (its brief, answers, questions, artifact text) were on disk only because
            // the task was. A call about it still in flight records no body.
            externalActivityLog.forgetFullCalls(forTaskID: taskID)
            let snapshotService = self.taskSnapshotService
            Task {
                _ = try? await snapshotService.cleanupTask(workFolder: url, taskID: taskID)
            }
            guard isCurrentFolderLifecycle(lifecycle) else { return .removed }
            if removedParentTaskID == nil {
                autovisorEventFeed.recordDeleted(
                    taskID: taskID,
                    origin: removedOrigin,
                    title: removedTitle,
                    by: actor
                )
            }
            // If the removed task was active, the repository picked a fallback
            // top-level task as the new active. That fallback may have its own
            // delegation history on disk that wasn't loaded earlier — restore
            // it now so the activity feed/graph render correctly without
            // requiring another switchTask round-trip.
            await ensureDelegationDescendantsLoaded(of: self.activeTaskID)
            return .removed
        } catch {
            self.lastErrorMessage = error.localizedDescription
            return .notRemoved
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
    @discardableResult
    func closeTask(taskID: Int) async -> Bool {
        await closeTask(taskID: taskID, by: .person)
    }

    /// A close `actor` asked for. An external agent's is drawn in the task's feed as a timeline
    /// event signed with its label (§11); the agent that closed it is not told it back as an
    /// event.
    @discardableResult
    func closeTask(taskID: Int, by actor: ControlActor) async -> Bool {
        // The close belongs to the folder described now. Its write suspends, and once a folder
        // transition has ended this lifecycle the id names the next folder's task of the same
        // number: the close stands where it was asked, its folder's dismissals (keyed by the
        // folder's own id, taken here) are forgotten, and no engine is stopped — the transition
        // already stopped this folder's.
        let lifecycle = currentFolderLifecycle
        let workFolderID = snapshot?.projection.id
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
            RunService.mutateActiveRun(in: &task) { run in
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
                if case .externalAgent = actor {
                    run.supervisorEvents.append(SupervisorTimelineEvent(createdAt: now, kind: .taskClosed, by: actor))
                }
                run.updatedAt = now
            }
        }
        guard success else { return false }
        // A closed task produces no banners (WatchtowerInboxBuilder gates on closedAt),
        // so its stored dismissals can never match anything again — reclaim them now
        // instead of waiting for the sampling GC to load the task.
        if let workFolderID {
            configuration.forgetDismissals(workFolderID: workFolderID, taskID: taskID)
        }
        guard isCurrentFolderLifecycle(lifecycle) else { return true }

        // The engine stops BEFORE the close snapshot, so the tree recorded is the one the team
        // left; the snapshot is waited for at most the budget (N5) — the close is not held for
        // the store's lock queue.
        stopEngine(for: taskID, captureSnapshot: false)
        if let currentRun = loadedTask(taskID)?.runs.last {
            await captureTaskSnapshots(
                [TaskSnapshotRequest(round: currentRun.round, phase: .close)],
                taskID: taskID, runID: currentRun.id, within: lifecycle,
                waitBudget: taskSnapshotWaitBudget)
            guard isCurrentFolderLifecycle(lifecycle) else { return true }
        }

        autovisorEventFeed.recordClosed(taskID: taskID, by: actor)
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
    ///
    /// Answers whether the caller's `lifecycle` survived the wait — the decision every
    /// flush-then-write site has to make, which is why it is this method's result rather than a
    /// check each site may forget: the flush is a suspension, and a folder transition can begin
    /// inside it — `openWorkFolder` does not cancel the pending write — so a site that wrote on
    /// regardless applied the folder it captured under the URL of the one that committed since.
    func flushPendingActiveTaskWrite(within lifecycle: WorkFolderLifecycle) async -> Bool {
        _ = try? await pendingActiveTaskWrite?.value
        return isCurrentFolderLifecycle(lifecycle)
    }

}
