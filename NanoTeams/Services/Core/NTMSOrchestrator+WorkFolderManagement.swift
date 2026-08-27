import Foundation

/// Typed result of a work-folder-context generation pass. Lets the caller
/// route the generic "no usable context" info banner ONLY to a genuinely-empty
/// model response, while a real failure (e.g. a context-window overflow)
/// surfaces its own message. Defined next to its single consumer.
nonisolated enum WorkFolderContextGenerationOutcome: Equatable {
    case success(String)
    case emptyOutput
    case cancelled
    case failure(String)
}

/// Work folder lifecycle: open/close folders, update settings, manage teams and tools.
extension NTMSOrchestrator {

    // MARK: - Bootstrap

    /// Opens default storage if no project is loaded. Called once from MainLayoutView on launch.
    func bootstrapDefaultStorageIfNeeded() async {
        guard workFolderURL == nil else { return }
        // Try to restore last-opened folder first
        var unreachableRestoreTarget: String?
        if let path = configuration.lastOpenedWorkFolderPath {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                await openWorkFolder(url)
                try? repository.cleanupAllStagedDrafts(at: url)
                return
            }
            // Only a folder that ACTUALLY opened is ever recorded here (see `openWorkFolder`),
            // so a stored path that no longer resolves is a real signal, not a stale guess:
            // an unmounted volume, an evicted iCloud folder, a project moved between launches.
            // Silently booting into Application Support instead made that indistinguishable
            // from data loss, and invited the user to start creating tasks in the wrong place.
            unreachableRestoreTarget = url.lastPathComponent
        }
        // Fall back to default storage
        let defaultURL = Self.defaultStorageURL
        try? fileManager.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        await openWorkFolder(defaultURL)
        try? repository.cleanupAllStagedDrafts(at: defaultURL)
        if let unreachableRestoreTarget {
            lastInfoMessage = "Couldn't reopen “\(unreachableRestoreTarget)” — it isn't where it "
                + "was. Using internal storage; reopen the folder once it's available."
        }
    }

    // MARK: - Open / Close

    func openWorkFolder(_ url: URL) async {
        stopAllEngines()
        stopAutomationScheduler()
        // Clear the previous folder's auto-off deadline BEFORE the new poll loop
        // starts (below): its first tick sleeps only until the next minute boundary
        // and could fire `evaluateAutovisorAutoDisable` with a stale (possibly
        // expired) deadline against the NEW folder's snapshot — spuriously
        // disabling its Autovisor. Clear only — `rearmAutovisorAutoDisable()` here
        // would re-arm from the OLD folder's still-loaded snapshot; the fresh
        // re-arm for this folder happens after `ensureAutovisorTask()`.
        clearAutovisorAutoDisable()
        // The report describes the folder we are leaving; the open below either
        // replaces it or leaves it nil.
        bundledUpdateReport = nil
        llmExecutionService.cancelAllExecutions()
        await tearDownSearchIndexCoordinator()
        workFolderURL = url

        do {
            var snapshot = try workFolderManagementService.openOrCreateWorkFolder(at: url)

            // Recover stale statuses from a previous session where the app closed
            // while tasks were running. Steps in .running/.needsSupervisorInput → .paused,
            // roles whose step is genuinely mid-flight → .idle, and roles whose step
            // already reached a terminal status → settled (see StatusRecoveryService).
            //
            // Runs BEFORE `apply(snapshot)` deliberately: publishing first would flash the
            // un-recovered "Working" status in the sidebar, and `syncEngineStateFromRun`
            // below reads `self.activeTask` immediately after `apply` — it must see
            // recovered values. The team therefore resolves off the raw snapshot, whose
            // teams `openOrCreateWorkFolder` has already populated.
            if var activeTask = snapshot.activeTask {
                let team = TeamResolution.team(for: activeTask, in: snapshot.projection)
                if StatusRecoveryService.recoverStaleStatuses(in: &activeTask, team: team) {
                    snapshot.activeTask = activeTask
                    // NON-FATAL, and the `try` that used to be here was the whole defect: this
                    // persists a COSMETIC repair (a step left `.running` by a kill becomes
                    // `.paused`), and sharing the open's do/catch meant one failed write aborted
                    // the ENTIRE open — no `apply(snapshot)`, no scheduler, no Autovisor, an empty
                    // app over intact data. Both sibling implementations of this same recovery
                    // already treat the identical write as non-fatal: the sweep below collects
                    // into `failedIDs` and keeps going, and `ensureTaskLoaded` banners "may
                    // diverge from disk" and returns false.
                    //
                    // The banner is written inline rather than aggregated with the sweep's: a
                    // later, more specific failure overwriting it is acceptable (they all mean
                    // "this volume is refusing writes"), whereas holding it back to the end would
                    // clobber the sweep's own aggregate. In-memory recovery still stands, so the
                    // UI is honest; disk re-converges on the next `mutateTask` or the next open,
                    // both of which redo the identical idempotent repair.
                    do {
                        try repository.updateTaskOnly(at: url, task: activeTask)
                    } catch {
                        lastErrorMessage = "Couldn't save the recovered status for task "
                            + "#\(activeTask.id): \(error.localizedDescription). In-memory state "
                            + "may diverge from disk."
                    }
                    // Refresh in-memory index so sidebar shows recovered status
                    let refreshed = activeTask.toSummary()
                    if let idx = snapshot.tasksIndex.tasks.firstIndex(where: { $0.id == activeTask.id }) {
                        snapshot.tasksIndex.tasks[idx] = refreshed
                    }
                }
            }

            apply(snapshot)

            // Discover agent instruction files (CLAUDE.md, AGENTS.md, …) for the
            // freshly opened folder BEFORE the Autovisor open-time review so the
            // manager's first step already sees them in its system prompt. Runs
            // AGAIN outside the do/catch (cheap: TTL memo) so an open failure
            // can't strand the PREVIOUS folder's snapshot on the new URL.
            await refreshAgentInstructions()
            // Same reasoning for role-attached skills: the teams (and therefore
            // the attached ids) only exist once the folder is loaded.
            await refreshAgentSkills()

            // Pass the whole task so chat-mode awareness in
            // `derivedStatusFromActiveRun` participates.
            if let activeTask = self.activeTask {
                syncEngineStateFromRun(taskID: activeTask.id, task: activeTask)
            }

            // Restore delegation history of the active task: pull every
            // transitive descendant into `loadedTasks` so the parent's
            // activity feed (`allLoadedTasksIncludingChildren`) and the
            // graph stack (`GraphPanelView.resolveDelegationLayers`) render
            // immediately after restart. Without this, child tasks only
            // appear in memory when a fresh `delegate_to_team` runs.
            await ensureDelegationDescendantsLoaded(of: self.activeTaskID)

            // Sweep the REST of the index: the block above recovered only the
            // active task (+ its descendants via the load above), so every
            // other task that was running when the app quit still shows a
            // stale "Working" summary in the sidebar. Runs BEFORE the
            // scheduler and the Autovisor's open-time review — both read
            // statuses and must see honest values.
            await recoverStaleStatusesAcrossIndex(folderURL: url)

            // Start recurring-task scheduling + run-timeout watchdog for this
            // folder. Runs after descendants are loaded so the scheduler's
            // eviction never drops a task the active feed/graph still needs.
            await startAutomationScheduler()

            // Autovisor: ensure the team is always present in teams.json (regardless
            // of the enabled toggle) so it shows as a protected entry in Settings →
            // Teams. The manager *task/run* below stays gated by `autovisorEnabled`.
            await ensureAutovisorTeam()

            // Autovisor: ensure the hidden singleton manager task exists (lazily,
            // only when enabled) and kick off an open-time review pass. The open-time
            // run is mandatory (dive-deeper finding 11) — tasks left waiting for the
            // manager after restart would otherwise hang, since the event-wake is
            // edge-triggered (no transition on load) and missed recurrence slots are
            // skipped. Runs after the scheduler so the manager's recurrence is live.
            await ensureAutovisorTask()

            // Auto-off sleep timer: the deadline is in-memory by design, so every
            // launch / folder switch re-arms a fresh countdown from "now" (and
            // clears it when this folder has the feature off — including default
            // storage, which `closeProject`/`resetAllData` funnel into).
            rearmAutovisorAutoDisable()

            // Latch first: the snapshot's copy is wiped by the next
            // `mutateWorkFolder`, and the Work Folder settings row for the
            // permanent case has to outlive that.
            bundledUpdateReport = snapshot.bundledUpdate
            if let message = snapshot.bundledUpdate?.bannerMessage {
                // A scan failure blocks every team until the user repairs a file;
                // a deferral resolves itself next open. Same slot, different
                // severity — the old code reported both as neutral info.
                if snapshot.bundledUpdate?.bannerIsError == true {
                    lastErrorMessage = message
                } else {
                    lastInfoMessage = message
                }
            }

            // Spin up the search index coordinator if exploratory search is enabled.
            await setUpSearchIndexCoordinatorIfEnabled()

            // Only a folder that actually opened becomes the launch-time restore target.
            // This used to live in `SidebarView`'s `.onChange(of: store.workFolderURL)`,
            // which fires at the assignment above — i.e. BEFORE the outcome is known — so a
            // folder that failed to open replaced the working one as the thing the next
            // launch reopens, and re-failed every launch. The outcome is only knowable here.
            if hasRealWorkFolder {
                configuration.lastOpenedWorkFolderPath = url.path
            }
        } catch {
            self.lastErrorMessage = error.localizedDescription
            // The URL above is already committed and stays committed (`closeProject` /
            // `resetAllData` read it as their "no project open" signal). Drop everything that
            // describes the PREVIOUS folder's contents so the process describes exactly one
            // folder — this one, with nothing loaded — instead of pairing a new URL with an old
            // snapshot, which is how `mutateWorkFolder` came to write folder A's teams into
            // folder B's `teams.json`. See `discardWorkFolderState()`.
            discardWorkFolderState()
        }
        // Keep the instructions/skills snapshots honest on BOTH paths. After a failed open
        // the snapshot is empty and the URL is the new folder, so this rescans that folder
        // from scratch (or clears, for default storage) rather than leaving the previous
        // folder's files rendered against the new URL in Settings and the prompt previews.
        // On the happy path the TTL memo makes it a no-op.
        await refreshAgentInstructions()
        await refreshAgentSkills()
        // Sync the LM Studio embed-model state to whatever the coordinator
        // ended up at. Lives outside the do/catch so it runs on both happy
        // and error paths — if openOrCreateWorkFolder threw, the coordinator
        // is nil and reconcile will unload anything we had loaded for the
        // prior folder.
        await reconcileEmbeddingLifecycle()
        // Chat half of the same idea. Re-adopt instances a previous run of the
        // app left resident (the ownership ledger is in-memory), then reclaim
        // anything this folder's roster no longer references — per-role
        // overrides differ per work folder, so opening one can orphan a model.
        //
        // No arguments by design: both resolve against THIS orchestrator via
        // `resolvedChatLifecycleClient` / `resolvedEnsurer`. That seam is what
        // keeps these two lines off the network in tests — with a real client
        // and the process-global ensurer they would issue live HTTP to
        // `AppDefaults.llmBaseURL` from every one of the ~700 test call sites,
        // and a suite that adopted a real model could then unload it from the
        // developer's running LM Studio.
        await adoptResidentReferencedModels()
        await reconcileAndReportResidency()
    }

    // MARK: - Stale Status Sweep

    /// Startup sweep: recovers stale "active-looking" statuses for every task in
    /// the index that has no live engine, then evicts what the UI doesn't need.
    /// Error banners are aggregated into ONE summary message (same pattern as
    /// `ensureDelegationDescendantsLoaded` — a serial loop without aggregation
    /// would silently show only the last failure). Per-iteration restores go to
    /// the banner value captured just before that iteration's calls (not a
    /// pre-loop snapshot), so a banner set by a concurrent path during an
    /// earlier iteration's awaits isn't destroyed.
    func recoverStaleStatusesAcrossIndex(folderURL: URL) async {
        // `TaskSummary` is a value type, so `filter` already hands back a snapshot —
        // `mutateTask` re-sorts the live array mid-loop and must not be observed here.
        // The second clause is the one-time backfill for `hasPendingSupervisorInput`:
        // a `.paused` row can hide an unanswered question (recovery parks every waiting
        // step) and so can `.failed` (it outranks `.needsSupervisorInput` in
        // `Run.derivedTaskStatus`), while a row predating the field answers nothing at
        // all. Self-terminating — the convergence write below stamps the field, so the
        // row drops out of this filter on the next open.
        let staleEntries = (snapshot?.tasksIndex.tasks ?? [])
            .filter {
                $0.status == .running || $0.status == .needsSupervisorInput
                    || (!$0.supervisorInputStateIsKnown
                        && ($0.status == .paused || $0.status == .failed))
            }
        guard !staleEntries.isEmpty else { return }
        // The eviction guard's "active task's delegation subtree stays resident"
        // set, computed ONCE for the sweep — per-row recomputation was the
        // O(rows × index) half of this loop's cost on the MainActor.
        let protectedDescendants = activeTaskID.map {
            Set(snapshot?.tasksIndex.descendantIDs(of: $0) ?? [])
        } ?? []
        var failedIDs: [Int] = []
        for entry in staleEntries {
            let taskID = entry.id
            guard taskID != activeTaskID else { continue }     // recovered earlier in openWorkFolder
            guard taskEngines[taskID] == nil else { continue } // defensive: never touch a live engine
            // Folder-switch guard sits SYNCHRONOUSLY before every persist-capable
            // call — no suspension point between the check and the callee's
            // folder-URL capture (`mutateTask` / `ensureTaskLoaded` both bind
            // `workFolderURL` synchronously at entry; the detached disk write
            // targets that captured URL). Task IDs are per-folder sequential
            // ints — a stale ID from the old index must never resolve against
            // (and persist into) a different folder. `break`, not `return`:
            // failures collected so far still get their aggregate banner.
            guard workFolderURL == folderURL else { break }
            let bannerBefore = lastErrorMessage
            if var probe = loadedTask(taskID) {
                // In-process re-open: `apply` preserved `loadedTasks` (same folder),
                // so `ensureTaskLoaded` would short-circuit without recovering.
                // Probe first so chat-mode steady-state `.running` doesn't churn updatedAt.
                // Resolve the acceptance gate ONCE and hand the same value to both the
                // probe and the mutation — a second resolve could disagree if the
                // snapshot moved across the await, and the two passes must decide
                // identically or `persisted` would report on a different outcome.
                let team = snapshot.map { TeamResolution.team(for: probe, in: $0.projection) } ?? nil
                guard StatusRecoveryService.recoverStaleStatuses(in: &probe, team: team) else {
                    // Nothing to recover, but this row may be here only for the
                    // `hasPendingSupervisorInput` backfill — converge the index so the
                    // widened filter above does not re-select it on every open.
                    if probe.toSummary() != entry {
                        do {
                            try repository.updateTaskOnly(at: folderURL, task: probe)
                            // Disk alone is not convergence: the sidebar reads
                            // `snapshot.tasksIndex`, and without this the in-memory
                            // row keeps the stale/unknown summary until the NEXT
                            // launch — the whole session the backfill was for.
                            refreshBackgroundTaskInMemory(probe)
                        }
                        catch { failedIDs.append(taskID) }
                    }
                    continue
                }
                let persisted = await mutateTask(taskID: taskID) {
                    _ = StatusRecoveryService.recoverStaleStatuses(in: &$0, team: team)
                }
                if !persisted {
                    failedIDs.append(taskID)
                    lastErrorMessage = bannerBefore            // restore: aggregate banner below
                }
                // Parity with the ensureTaskLoaded branch (which seeds via
                // syncEngineStateFromRun): `stopAllEngines()` at open wiped the
                // engine entry and `switchTask` never re-seeds — neither its
                // fast path nor (after the eviction below forces a cold read)
                // its slow path — so TeamBoard would show Start instead of Resume.
                if let recovered = loadedTask(taskID) {
                    syncEngineStateFromRun(taskID: taskID, task: recovered)
                }
            } else {
                let persisted = await ensureTaskLoaded(taskID)
                guard let loaded = loadedTask(taskID) else {   // load failed (missing/corrupt task.json) — collect, keep sweeping
                    failedIDs.append(taskID)
                    lastErrorMessage = bannerBefore            // restore: aggregate banner below
                    continue
                }
                // The sweep owns reporting from here: restore any per-task banner
                // `ensureTaskLoaded` set (e.g. "may diverge from disk" after a
                // recovery whose persist failed) — the convergence write below
                // retries that exact write, so the banner is either about to be
                // healed or re-collected into the aggregate.
                lastErrorMessage = bannerBefore
                // Crash-window mismatch: index said .running but the task's steps
                // were already terminal → recovery was a no-op and nothing was
                // persisted, so the DISK index would stay stale and re-trigger
                // this sweep on every open. Converge it with one narrow write
                // (which doubles as the retry for a failed recovery persist).
                if !persisted, loaded.toSummary() != entry {
                    do { try repository.updateTaskOnly(at: folderURL, task: loaded) }
                    catch { failedIDs.append(taskID) }
                }
            }
            evictIfReclaimable(taskID, protectedDescendants: protectedDescendants)
        }
        if !failedIDs.isEmpty {
            lastErrorMessage = "Could not recover status for \(failedIDs.count) task(s): " +
                failedIDs.map { "#\($0)" }.joined(separator: ", ")
        }
    }

    // MARK: - Search Index Coordinator Lifecycle

    /// Creates a coordinator bound to the current work folder (if exploratory search
    /// is enabled) and kicks off an initial ensure-fresh pass.
    ///
    /// Skipped for default internal storage (Application Support) — that
    /// directory holds NanoTeams's own metadata for template/chat teams
    /// without a real project, and indexing it just surfaces bookkeeping
    /// files. Exploratory search only makes sense against a user-selected project.
    ///
    /// Idempotent: repeated calls with a coordinator already installed return
    /// early WITHOUT creating a second one. The install-after-await guard
    /// also protects against a concurrent caller entering during our
    /// `coordinator.start()` await — if someone else won the race, we tear
    /// down the one we built before returning so no FSEventStream is orphaned.
    func setUpSearchIndexCoordinatorIfEnabled() async {
        guard configuration.exploratorySearchEnabled,
              hasRealWorkFolder,
              let url = workFolderURL,
              searchIndexCoordinator == nil else { return }

        let paths = NTMSPaths(workFolderRoot: url)
        // MainActor-isolated provider: the closure runs on the same actor as
        // `configuration` (the orchestrator), so reads are safe. Snapshot
        // happens on each rebuild call — settings changes take effect on
        // the next build without re-creating the coordinator.
        let config = configuration
        let coordinator = SearchIndexCoordinator(
            workFolderRoot: url,
            internalDir: paths.internalDir,
            embeddingConfigProvider: { @MainActor [weak config] in
                config?.effectiveEmbeddingConfig ?? .defaultNomicLMStudio
            },
            embeddingClient: searchEmbeddingClient,
            fileManager: fileManager,
            makeWatcher: FileSystemWatcher.live,
            watcherDebounce: configuration.searchIndexWatcherDebounceSeconds
        )
        // `start()` awaits — a concurrent caller could install a coordinator
        // in the meantime. Install AFTER start so the observed ordering is
        // "create → start → publish", never "publish with a half-initialized
        // watcher".
        await coordinator.start()

        // Two ways to lose the race, and only the first used to be checked.
        //
        // (1) A concurrent caller installed one — tear ours down.
        // (2) The FOLDER moved. `start()` suspends into the vector-index actor, and a Close
        //     Project / Open Recent inside that window has already run its own
        //     `tearDownSearchIndexCoordinator` against a still-nil slot, so publishing here
        //     installs a coordinator bound to a folder that is no longer open and nothing
        //     will ever tear it down. Its FSEventStream, index walks and `search_index.json`
        //     writes keep running against the previous project; default storage — which this
        //     method's own doc says must never be indexed — ends up with an index; and
        //     `exploratory_search` resolves postings from the old folder while executing
        //     against the new root.
        guard searchIndexCoordinator == nil, workFolderURL == url else {
            await coordinator.stop()
            return
        }
        searchIndexCoordinator = coordinator
    }

    /// Shuts down the coordinator (stops the FS watcher, cancels in-flight
    /// builds). Does NOT delete the on-disk index so re-opening the folder
    /// reuses the cached build when the signature still matches.
    func tearDownSearchIndexCoordinator() async {
        guard let coordinator = searchIndexCoordinator else { return }
        await coordinator.stop()
        searchIndexCoordinator = nil
    }

    /// Hook: user toggled the "Exploratory Search" setting. Creates or destroys the
    /// coordinator and (on disable) deletes the on-disk `search_index.json`.
    ///
    /// When the user enables exploratory search while on default internal storage
    /// (no real project folder), `setUpSearchIndexCoordinatorIfEnabled` is a
    /// no-op — broadcast an info message so the toggle's "ON" state doesn't
    /// silently contradict the index-status card reading "disabled".
    ///
    /// Rapid toggle sequencing: `ExploratorySearchToggleCard.onChanged` spawns a
    /// detached `Task { await ... }` per click, so three rapid clicks race
    /// without inline awaits. We chain them through `pendingExploratorySearchToggle`
    /// so the effects apply in FIFO click order — otherwise the final state
    /// could disagree with the last click.
    func onExploratorySearchSettingChanged() async {
        let prior = pendingExploratorySearchToggle
        let myTask = Task { [weak self] in
            _ = await prior?.value
            guard let self else { return }
            await self.applyExploratorySearchSettingChange()
        }
        pendingExploratorySearchToggle = myTask
        _ = await myTask.value
        if pendingExploratorySearchToggle == myTask {
            pendingExploratorySearchToggle = nil
        }
    }

    private func applyExploratorySearchSettingChange() async {
        if configuration.exploratorySearchEnabled {
            searchIndexClearFailure = nil       // re-enabling supersedes any leftover warning
            if searchIndexCoordinator == nil {
                await setUpSearchIndexCoordinatorIfEnabled()
                if searchIndexCoordinator == nil, !hasRealWorkFolder {
                    lastInfoMessage = "Exploratory Search needs an open project folder — default storage isn't indexed."
                }
            }
        } else {
            if let coordinator = searchIndexCoordinator {
                await coordinator.clear()
                // Read the outcome BEFORE dropping the coordinator — it is the only object
                // that knows whether the on-disk index was actually deleted, and the next
                // line is the last moment it exists. `clear()` calls `stop()` first (which
                // nils `watcherError`) and then assigns `buildError` in all three of its
                // arms, so `lastError` here is the clear's own verdict and nothing else.
                searchIndexClearFailure = coordinator.lastError
                searchIndexCoordinator = nil
            }
        }
        await reconcileEmbeddingLifecycle()
    }

    /// User changed the embed-model URL or name in `ExploratorySearchEmbeddingsCard`.
    /// Chains on the same FIFO sequencer as toggle events so a rapid model swap
    /// can't interleave with a toggle ON/OFF and leave us with the wrong state.
    ///
    /// I7: the `exploratorySearchEnabled` guard runs INSIDE the queued task body,
    /// not before enqueueing — otherwise a config change observed while a
    /// toggle-OFF is still queued would read the not-yet-applied (stale) value
    /// and schedule a reconcile that fires after the toggle-OFF has already
    /// torn down the coordinator.
    func onExploratorySearchEmbeddingConfigChanged() async {
        let prior = pendingExploratorySearchToggle
        let myTask = Task { [weak self] in
            _ = await prior?.value
            guard let self else { return }
            // Read AFTER the prior task drained — this is now the post-FIFO
            // state, the only state the user actually committed to.
            guard self.configuration.exploratorySearchEnabled else { return }
            await self.reconcileEmbeddingLifecycle()
        }
        pendingExploratorySearchToggle = myTask
        _ = await myTask.value
        if pendingExploratorySearchToggle == myTask {
            pendingExploratorySearchToggle = nil
        }
    }

    /// Drives `embeddingLifecycle` toward the desired state: model loaded
    /// when a coordinator is active. Called from every public lifecycle hook.
    ///
    /// I4: this is a *target* state, not an enforced invariant — when
    /// `ensureLoaded` throws, the coordinator stays installed but
    /// `embeddingLifecycle.loaded == nil`. The next reconcile retries.
    ///
    /// Load failures are deliberately NOT surfaced as a global red banner.
    /// Settings → Exploratory Search → Semantic Query Expansion already shows
    /// the failure (model picker carries "Failed to load embedding models",
    /// vector-index state transitions to `.modelUnavailable`). A second
    /// surface across the entire app is noisy — keyword search keeps working
    /// and the user discovers the issue exactly where they enable the feature.
    /// I8: unload failures still surface via `lastInfoMessage` so the user
    /// knows VRAM may not have been reclaimed (server-side state, harder to
    /// inspect from the UI).
    ///
    /// No "Loading embedding model…" progress banner: the C1 adoption path
    /// (`listLoadedInstances` ahead of `loadModel`) makes the common case a
    /// near-instant adopt, and a banner that appears every reconcile is
    /// noise. If the user's actual first-time download is slow, LM Studio's
    /// own UI surfaces the download progress.
    private func reconcileEmbeddingLifecycle() async {
        if searchIndexCoordinator != nil {
            do {
                try await embeddingLifecycle.ensureLoaded(configuration.effectiveEmbeddingConfig)
            } catch {
                // Swallow — the Exploratory Search settings card surfaces it.
            }
        } else {
            do {
                try await embeddingLifecycle.ensureUnloaded()
            } catch {
                // I8: don't go fully silent — surface as info so the user
                // knows VRAM may not have been reclaimed. The native client
                // swallows the common 404/"no such instance" cases, so
                // anything reaching here is rare and worth a note.
                lastInfoMessage = "Couldn't unload previous embedding model: \(error.localizedDescription). It may still be loaded on the server; retry from settings or restart LM Studio."
            }
        }
    }

    /// Closes the current work folder and returns to default internal storage.
    func closeProject() async {
        stopAllEngines()
        llmExecutionService.cancelAllExecutions()
        // Cancel any in-flight active-task pointer write — its captured URL
        // is for the OLD workfolder, so letting it fire after we've opened
        // the default storage would write a ghost `activeTaskID` into the
        // old `workfolder.json` minutes after the user closed the project.
        pendingActiveTaskWrite?.cancel()
        pendingActiveTaskWrite = nil
        configuration.lastOpenedWorkFolderPath = nil
        let defaultURL = Self.defaultStorageURL
        try? fileManager.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        await openWorkFolder(defaultURL)
    }

    /// Deletes all data in Application Support and re-bootstraps from scratch.
    func resetAllData() async {
        stopAllEngines()
        llmExecutionService.cancelAllExecutions()
        // Cancel before the `.nanoteams/` delete below — otherwise the chain
        // task can fire mid-delete and `setActiveTaskID` will throw
        // `.fileNoSuchFile` once `workfolder.json` is gone, surfacing as a
        // spurious "Could not save active-task pointer" banner immediately
        // after the user hit "Reset All Data".
        pendingActiveTaskWrite?.cancel()
        pendingActiveTaskWrite = nil
        // Tear down BEFORE deleting the .nanoteams tree — otherwise the FS
        // watcher can fire against the half-deleted folder and kick off a
        // rebuild that races the re-bootstrap.
        await tearDownSearchIndexCoordinator()
        configuration.lastOpenedWorkFolderPath = nil

        let defaultURL = Self.defaultStorageURL
        let nanoteamsDir = defaultURL.appendingPathComponent(".nanoteams", isDirectory: true)
        // Reported, not swallowed. `try?` here meant a refused delete produced NO signal while
        // `openWorkFolder` below re-read the intact tree and `apply`d it — so every task and
        // team the user asked to destroy came back, silently, under a dialog that promised to
        // "restore the application to its initial state". A PARTIAL delete is worse: the
        // recovery wrappers regenerate whatever went missing, so the app boots on a mix of
        // surviving and freshly-defaulted data with nothing to indicate it.
        var deleteFailure: String?
        do {
            if fileManager.fileExists(atPath: nanoteamsDir.path) {
                try fileManager.removeItem(at: nanoteamsDir)
            }
        } catch {
            deleteFailure = error.localizedDescription
        }
        try? fileManager.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        await openWorkFolder(defaultURL)
        // After the re-open, so the open's own banner can't displace it.
        if let deleteFailure {
            lastErrorMessage = "Reset incomplete — couldn't delete the existing data: "
                + "\(deleteFailure). Some tasks or teams may still be present."
        }
    }

    // MARK: - Agent Instruction Files

    /// How long a DISCOVERY walk stays good — "which instruction files exist in
    /// this folder", not what they say.
    ///
    /// Sixty seconds, and the number is a statement about the CALLER's regime. The
    /// value was 5 s until 2026-08-27, chosen to collapse a recurrence tick that
    /// fires several tasks at once into one walk — true of that regime, and silently
    /// false of the one this actually runs in. A person composing a message takes
    /// longer than five seconds, so on the interactive path the memo could never hit
    /// and every single Send paid the walk (CLAUDE.md #82).
    ///
    /// Discovery is the only thing behind it: CONTENT is re-read on every call, so
    /// editing a `CLAUDE.md` still reaches the very next prompt. What the window
    /// delays is a NEWLY CREATED instruction file — and any Settings edit or folder
    /// re-open bypasses it, because those change the scan key.
    private static let agentInstructionsDiscoveryTTL: TimeInterval = 60

    /// Bring the in-memory `agentInstructions` snapshot up to date: re-read what the
    /// known instruction files say, and re-walk the folder for new ones when the
    /// discovery window has lapsed or the user's overrides changed. Both run off the
    /// main actor. In default storage / no folder there is nothing to scan →
    /// snapshot cleared to `nil`.
    ///
    /// Returns whether the published snapshot is AUTHORITATIVE for the inputs this call read —
    /// `false` only when a newer refresh superseded this one mid-flight. Callers that merely want
    /// the snapshot fresh ignore it; the one caller that draws a CONCLUSION from the absence of
    /// a path (`setAgentInstructionInjected`) must not treat a superseded pass as evidence, or
    /// it rolls back a setting that was persisted correctly and blames a file that is fine.
    @discardableResult
    func refreshAgentInstructions() async -> Bool {
        guard hasRealWorkFolder, let root = workFolderURL else {
            agentInstructionsScanGeneration += 1  // drop in-flight old-folder scans
            agentInstructionsLastScanKey = nil
            if agentInstructions != nil { agentInstructions = nil }
            return true
        }
        let extras = workFolder?.settings.agentInstructionExtraPaths ?? []
        let excluded = workFolder?.settings.agentInstructionExcludedPaths ?? []
        let injected = workFolder?.settings.agentInstructionInjectedPaths ?? []
        let key = AgentInstructionsScanKey(
            root: root, extraPaths: extras, excludedPaths: excluded, injectedPaths: injected)
        // A previous snapshot is what `reread` refreshes; with none there is nothing
        // to re-read and the walk is the only way to answer at all.
        let previous = agentInstructions
        let discoveryLapsed = agentInstructionsLastScanAt.map {
            Date().timeIntervalSince($0) >= Self.agentInstructionsDiscoveryTTL
        } ?? true
        let needsWalk = previous == nil || key != agentInstructionsLastScanKey || discoveryLapsed

        agentInstructionsScanGeneration += 1
        let expected = agentInstructionsScanGeneration
        // `.userInitiated`, not `.utility`: every caller AWAITS this, and awaiting from
        // the MainActor does not escalate a detached task's priority — so a throttled
        // QoS here is time the user spends waiting, with no thread of theirs blocked to
        // show for it. `.utility` would be right for a scan nobody is waiting on; there
        // is no such caller. Same reasoning as `mutateTask`'s detached write.
        let scanned = await Task.detached(priority: .userInitiated) {
            guard needsWalk else {
                return AgentInstructionsScanner.reread(previous ?? .empty, workFolderRoot: root)
            }
            return AgentInstructionsScanner.scan(
                workFolderRoot: root, manualPaths: extras,
                excludedPaths: excluded, injectedPaths: injected)
        }.value
        // CLAUDE.md #38: a newer refresh started during the await (or the folder
        // switched/closed, which also bumps the generation) supersedes this scan.
        guard agentInstructionsScanGeneration == expected else { return false }
        // Stamped only by a WALK: a content re-read says nothing about whether new
        // files appeared, so letting it renew the window would keep discovery from
        // ever running again on a folder someone sends to every minute.
        if needsWalk {
            agentInstructionsLastScanKey = key
            agentInstructionsLastScanAt = Date()
        }
        // Equality guard: @Observable fires on every write regardless of value;
        // skipping no-op writes keeps open preview sheets / Settings from
        // re-rendering on every run start (CLAUDE.md View Conventions #9/#11).
        if agentInstructions != scanned { agentInstructions = scanned }
        return true
    }

    // MARK: - Agent Skills

    /// Bring the in-memory `roleSkills` snapshot up to date: take the cached
    /// CATALOGUE and re-read the BODIES of every skill some role has attached.
    ///
    /// Cheap by construction — a JSON decode plus one read per attached id, and on a
    /// default install the attached set is empty, so this touches no file at all.
    /// That matters because `launchRun` awaits it: until 2026-08-27 this method
    /// walked every skill root on the machine (project, `~/.claude/skills`,
    /// `~/.codex/prompts`, every enabled plugin, 8 KB probed per file found) before
    /// each first prompt, to build a catalogue nothing on that path reads. See
    /// `AgentSkillsCatalogueStore` for where discovery lives now.
    ///
    /// **Deliberate divergence from `refreshAgentInstructionContents`: no
    /// `hasRealWorkFolder` bail.** Instruction files exist only inside a work folder,
    /// so clearing the snapshot there is right. Skills do not — `~/.claude/skills`,
    /// `~/.codex/prompts` and enabled plugin skills are available with no folder open
    /// at all, and the scanner takes an OPTIONAL root precisely for that case.
    /// Copying the bail would silently drop every attached global skill in the mode
    /// the app boots into.
    func refreshAgentSkills() async {
        await applySkillsSnapshot(rescanCatalogue: false)
    }

    /// Re-walk every skill root and republish. The user's own "I just installed a
    /// skill" verb, wired to the Refresh control beside both catalogue lists.
    ///
    /// The only caller-facing way to pay for discovery, and that is the point: a
    /// timer cannot know when a skill is installed, and staleness here is visible —
    /// the missing skill is absent from a list the user is looking at — so the honest
    /// control sits next to the list rather than behind a TTL.
    func rescanAgentSkillCatalogue() async {
        await applySkillsSnapshot(rescanCatalogue: true)
    }

    /// Shared body of both verbs: resolve a catalogue, read the attached bodies
    /// against it, publish.
    ///
    /// The catalogue is resolved a second time when an attached id does not resolve
    /// against the first one. Without it, a skill installed since the cache was
    /// taken and attached in Settings would read as "unresolved" forever — the cache
    /// would be wrong and nothing would ever ask it to look again.
    ///
    /// That retry is bounded to ONCE per attachment set (`roleSkillsRescanAttemptedFor`),
    /// and the bound is the load-bearing half: an id that dangles because its file
    /// was deleted is unresolvable, so an unbounded retry would walk every skill
    /// root on every run start — the exact cost this cache exists to remove, and
    /// invisible, because the outcome would look identical either way.
    private func applySkillsSnapshot(rescanCatalogue: Bool) async {
        let root = hasRealWorkFolder ? workFolderURL : nil
        // Union of every role's attachments across all teams: these are the only
        // ids whose bodies are worth reading. A typical install discovers 130+
        // skills totalling half a megabyte — reading them all would be waste.
        let attachedIDs = attachedSkillIDsAcrossTeams()

        roleSkillsScanGeneration += 1
        let expected = roleSkillsScanGeneration
        let store = skillsCatalogueStore
        // Asked BEFORE the await so a concurrent refresh cannot see a half-updated
        // answer, and recorded unconditionally: whether the retry runs or is
        // refused, this set has now had its one look.
        let mayRetry = !rescanCatalogue && roleSkillsRescanAttemptedFor != attachedIDs
        if mayRetry { roleSkillsRescanAttemptedFor = attachedIDs }
        if rescanCatalogue { roleSkillsRescanAttemptedFor = nil }
        // `.userInitiated`, not `.utility`: every caller AWAITS this, and awaiting
        // from the MainActor does not escalate a detached task's priority — so a
        // throttled QoS here is time the user spends waiting, with no thread of
        // theirs blocked to show for it (CLAUDE.md #136).
        let scanned = await Task.detached(priority: .userInitiated) {
            var items = rescanCatalogue
                ? store.rescan(projectRoot: root).items
                : store.loadOrScan(projectRoot: root).items
            var resolved = Self.readSkillBodies(attachedIDs: attachedIDs, catalogue: items)
            if mayRetry, !resolved.unresolved.isEmpty {
                items = store.rescan(projectRoot: root).items
                resolved = Self.readSkillBodies(attachedIDs: attachedIDs, catalogue: items)
            }
            return RoleSkillsSnapshot(items: items, bodies: resolved.bodies,
                                      unresolvedIDs: resolved.unresolved)
        }.value
        // CLAUDE.md #38: a newer refresh started during the await supersedes this one.
        guard roleSkillsScanGeneration == expected else { return }
        // Equality guard: @Observable fires on every write regardless of value;
        // skipping no-op writes keeps open preview sheets / Settings from
        // re-rendering on every run start (CLAUDE.md View Conventions #9/#11).
        if roleSkills != scanned { roleSkills = scanned }
    }

    /// Reads the body of each attached id against a catalogue. An id the catalogue
    /// does not carry, or whose file has been deleted, moved, emptied or made
    /// non-UTF-8, lands in `unresolved` — recorded, never silently dropped.
    private nonisolated static func readSkillBodies(
        attachedIDs: [String], catalogue: [AgentSkillsSnapshot.Item]
    ) -> (bodies: [String: String], unresolved: Set<String>) {
        guard !attachedIDs.isEmpty else { return ([:], []) }
        let byID = Dictionary(catalogue.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var bodies: [String: String] = [:]
        var unresolved: Set<String> = []
        for id in attachedIDs {
            guard let item = byID[id],
                  let body = AgentSkillsScanner.readFullContent(at: item.fileURL)
            else {
                unresolved.insert(id)
                continue
            }
            bodies[id] = body
        }
        return (bodies, unresolved)
    }

    /// Every skill id attached to any role of any team, de-duplicated and sorted
    /// so the memo key is order-stable. Sorting is safe here precisely because
    /// this feeds the body CACHE — per-role render order comes from
    /// `TeamRoleDefinition.attachedSkillIDs` and is never sorted.
    private func attachedSkillIDsAcrossTeams() -> [String] {
        var ids: Set<String> = []
        for team in workFolder?.teams ?? [] {
            for role in team.roles { ids.formUnion(role.attachedSkillIDs) }
        }
        // Generated teams live on tasks, not in `workFolder.teams`; the active
        // task is deliberately absent from `loadedTasks`, so check both.
        for task in ([activeTask] + Array(snapshot?.loadedTasks.values ?? [:].values)).compactMap({ $0 }) {
            for role in task.generatedTeam?.roles ?? [] {
                ids.formUnion(role.attachedSkillIDs)
            }
        }
        return ids.sorted()
    }

    /// Reads full bodies for `ids` that the current `roleSkills` snapshot does
    /// not already carry, resolved against the snapshot's catalogue.
    ///
    /// Exists because the snapshot deliberately caches bodies only for ids some
    /// role has **persisted** (`attachedSkillIDsAcrossTeams`) — which is exactly
    /// wrong for the Role editor. A skill the user just ticked is unsaved, so
    /// its body, and therefore its token cost, is absent from the one surface
    /// whose entire job is stating that cost *before* the user commits to it.
    /// Without this the cost banner silently under-reports the very skill being
    /// decided about, and an over-budget prompt is truncated from the HEAD with
    /// no error.
    ///
    /// Returns only what it managed to read; an id that resolves to nothing is
    /// omitted, matching `RoleSkillsSnapshot.unresolvedIDs` semantics. Reads run
    /// off the main actor.
    func skillBodies(forIDs ids: [String]) async -> [String: String] {
        let known = roleSkills ?? .empty
        let byID = Dictionary(known.items.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let targets: [(String, URL)] = ids
            .filter { known.bodies[$0] == nil }
            .compactMap { id in byID[id].map { (id, $0.fileURL) } }
        guard !targets.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            var out: [String: String] = [:]
            for (id, url) in targets {
                if let body = AgentSkillsScanner.readFullContent(at: url) { out[id] = body }
            }
            return out
        }.value
    }

    /// Attach files as agent instructions (Settings grid "+" / file picker).
    /// Only files INSIDE the work folder qualify — the sandbox refuses
    /// `read_file` outside it, so an outside path would be uninjectable dead
    /// weight; `internal/` is likewise rejected (hidden from LLM tools).
    /// Accepted paths persist to `settings.agentInstructionExtraPaths`.
    func addAgentInstructions(urls: [URL]) async {
        guard hasRealWorkFolder, let root = workFolderURL else { return }
        let paths = NTMSPaths(workFolderRoot: root)
        var accepted: [String] = []
        var rejected: [String] = []
        for url in urls {
            let rel = paths.relativePathFromProjectRoot(for: url)
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            if rel.isEmpty || paths.isInternalURL(url) || !exists || isDir.boolValue {
                rejected.append(url.lastPathComponent)
            } else {
                accepted.append(rel)
            }
        }
        var persistFailed = false
        if !accepted.isEmpty {
            await mutateWorkFolder { projection in
                var extras = projection.settings.agentInstructionExtraPaths
                for rel in accepted where !extras.contains(rel) { extras.append(rel) }
                projection.settings.agentInstructionExtraPaths = extras
                // Re-attaching a previously excluded file means "inject it again".
                projection.settings.agentInstructionExcludedPaths.removeAll { accepted.contains($0) }
            }
            // Same shape as `setAgentInstructionInjected`: `mutateWorkFolder` returns Void and
            // reverts memory from disk on a failed settings write, so "accepted" only means
            // "passed validation". Without this the rejection notice below overwrites the
            // write-failure banner in the single-shot slot and tells the user the OTHER files
            // were attached — which is exactly what did not happen.
            let stored = workFolder?.settings.agentInstructionExtraPaths ?? []
            persistFailed = !accepted.allSatisfy(stored.contains)
            if !persistFailed { await refreshAgentInstructions() }
        }
        if !rejected.isEmpty, !persistFailed {
            lastErrorMessage =
                "Only files inside the work folder can be attached — skipped: \(rejected.joined(separator: ", "))"
        }
    }

    /// Remove an instruction from CONTENT injection (Settings grid "×"). A
    /// manually attached file is dropped from the extras entirely; an
    /// auto-discovered file is added to the persisted exclusions — it stays in
    /// the grid (dimmed, restorable) AND in the prompt's path list, it just
    /// stops riding the system prompt as content.
    func removeAgentInstruction(relativePath: String) async {
        await mutateWorkFolder { projection in
            projection.settings.agentInstructionInjectedPaths.removeAll { $0 == relativePath }
            if let idx = projection.settings.agentInstructionExtraPaths.firstIndex(of: relativePath) {
                projection.settings.agentInstructionExtraPaths.remove(at: idx)
                projection.settings.agentInstructionExcludedPaths.removeAll { $0 == relativePath }
            } else if !projection.settings.agentInstructionExcludedPaths.contains(relativePath) {
                projection.settings.agentInstructionExcludedPaths.append(relativePath)
            }
        }
        await refreshAgentInstructions()
    }

    /// Quick injection toggle from the "All files" list. `injected: true`
    /// promotes a listed file into content injection (readable text only —
    /// a binary is reported and stays listed); `false` demotes it back to the
    /// path list.
    func setAgentInstructionInjected(relativePath: String, injected: Bool) async {
        await mutateWorkFolder { projection in
            if injected {
                projection.settings.agentInstructionExcludedPaths.removeAll { $0 == relativePath }
                if !projection.settings.agentInstructionInjectedPaths.contains(relativePath) {
                    projection.settings.agentInstructionInjectedPaths.append(relativePath)
                }
            } else {
                projection.settings.agentInstructionInjectedPaths.removeAll { $0 == relativePath }
                if !projection.settings.agentInstructionExcludedPaths.contains(relativePath) {
                    projection.settings.agentInstructionExcludedPaths.append(relativePath)
                }
            }
        }
        // Did the override actually land? `mutateWorkFolder` returns Void and, when the
        // settings.json write fails, RE-READS the folder from disk and applies that — so the
        // override is silently gone and the scan below would find the file un-injected for a
        // reason that has nothing to do with the file. Reporting that as "isn't readable text"
        // was a false diagnosis over a real disk failure, and its `lastInfoMessage` write
        // displaced the write-failure banner in the single banner slot.
        //
        // The durable state is checked rather than `errorSurfaceCount`: it is exact, needs no
        // baseline, and cannot be tripped by an unrelated error surfacing during the scan's
        // await (CLAUDE.md ranks a durable signal above the counter for this reason).
        let persisted = workFolder?.settings.agentInstructionInjectedPaths.contains(relativePath) ?? false
        guard !injected || persisted else { return }

        // …and is the scan we are about to read OURS? A concurrent refresh — a second grid tick,
        // or any `startRun` while the Settings window is open — bumps the generation and this
        // walk's result is discarded, leaving a snapshot that predates the write. Concluding
        // "no text to inject" from it would roll back a setting that persisted correctly and
        // blame a perfectly readable file. Superseded ⇒ conclude nothing; the superseding scan
        // reads the same settings and produces the right answer.
        let authoritative = await refreshAgentInstructions()
        if injected, authoritative,
           !(agentInstructions?.injectedFiles.contains { $0.relativePath == relativePath } ?? false) {
            // Drop the dangling override and say what happened — WITHOUT naming a cause the
            // scan cannot distinguish. The write succeeded, so the file itself did not yield
            // injectable text, and the reachable reasons are several: it is binary, it is
            // EMPTY or whitespace-only (a placeholder `AGENTS.md` is the commonest of all, and
            // "isn't readable text" is simply wrong about it), or it vanished / became
            // unreadable between the grid render and the click. The old wording asserted one
            // of them.
            await mutateWorkFolder { projection in
                projection.settings.agentInstructionInjectedPaths.removeAll { $0 == relativePath }
            }
            lastInfoMessage = "\(relativePath) yielded no text to inject — it may be empty, "
                + "binary, or unreadable. It stays listed for on-demand reading."
        }
    }

    /// Re-include a previously excluded auto-discovered instruction file.
    func restoreAgentInstruction(relativePath: String) async {
        await mutateWorkFolder { projection in
            projection.settings.agentInstructionExcludedPaths.removeAll { $0 == relativePath }
        }
        await refreshAgentInstructions()
    }

    // MARK: - Work Folder Settings

    func updateWorkFolderContext(_ context: String) async {
        guard let url = workFolderURL else { return }
        do {
            let snapshot = try workFolderManagementService.updateWorkFolderContext(context, at: url)
            apply(snapshot)
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    func updateSelectedScheme(_ scheme: String?) async {
        guard let url = workFolderURL else { return }
        do {
            let snapshot = try workFolderManagementService.updateSelectedScheme(scheme, at: url)
            apply(snapshot)
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    /// Runs one context-generation pass and reports a typed outcome so the
    /// caller can distinguish a genuinely-empty model response (generic info
    /// banner) from a real failure whose message — e.g. a context-window
    /// overflow — must reach the user verbatim. Does NOT set any banner itself;
    /// the caller owns that so the routing is in one place.
    func generateWorkFolderContext() async -> WorkFolderContextGenerationOutcome {
        guard let workFolderRoot = workFolderURL else {
            return .failure("No work folder is open.")
        }
        do {
            // Always the global model, and it sends a large one-shot prompt — a textbook
            // interleaver against whatever step is mid-run on the same model.
            await llmExecutionService.noteInterleavingCall(
                label: "work folder context", config: globalLLMConfig)
            if let context = try await workFolderManagementService.generateWorkFolderContext(
                workFolderRoot: workFolderRoot,
                config: globalLLMConfig,
                customPrompt: workFolder?.settings.contextPrompt
            ) {
                return .success(context)
            }
            return .emptyOutput
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Spawns a generation task whose lifecycle is owned by the orchestrator,
    /// so Settings and the Sidebar both observe a single shared
    /// `isGeneratingWorkFolderContext` flag. Idempotent — if a generation
    /// is already in flight, the call is a no-op.
    ///
    /// Cancel-then-restart safety: the lambda captures `workFolderContextGenerationGeneration`
    /// at spawn time. If the user cancels and starts a new generation while
    /// the prior LLM stream is still draining, the prior lambda's late tail
    /// finds its captured generation no longer matches and skips the
    /// flag/task-handle reset — otherwise the new run's state would be clobbered.
    func startGeneratingWorkFolderContext() {
        guard !isGeneratingWorkFolderContext else { return }
        guard workFolderURL != nil else { return }
        isGeneratingWorkFolderContext = true
        workFolderContextGenerationGeneration += 1
        let myGeneration = workFolderContextGenerationGeneration
        workFolderContextGenerationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.generateWorkFolderContext()
            // Only the lambda for the most recent start is allowed to write back.
            guard self.workFolderContextGenerationGeneration == myGeneration else { return }
            if !Task.isCancelled {
                switch outcome {
                case let .success(context):
                    await self.updateWorkFolderContext(context)
                case .emptyOutput:
                    // Reachable ONLY when the model legitimately returned
                    // empty/whitespace — otherwise the user sees a spinner
                    // disappear with no insertion and no explanation.
                    self.lastInfoMessage = "Model returned no usable context. Try a more descriptive prompt or check that your LLM is responding."
                case let .failure(message):
                    // Surface the real cause (e.g. a context-window overflow)
                    // instead of masking it behind the generic info banner.
                    self.lastErrorMessage = message
                case .cancelled:
                    // Silent — cancelWorkFolderContextGeneration already toasted.
                    break
                }
            }
            self.isGeneratingWorkFolderContext = false
            self.workFolderContextGenerationTask = nil
        }
    }

    /// Cancels an in-flight generation. Safe to call when nothing is running.
    /// Bumps `workFolderContextGenerationGeneration` so any lambda from the
    /// cancelled run that completes after this returns can detect it lost the
    /// race and skip its tail.
    func cancelWorkFolderContextGeneration() {
        guard isGeneratingWorkFolderContext else { return }
        workFolderContextGenerationTask?.cancel()
        workFolderContextGenerationTask = nil
        workFolderContextGenerationGeneration += 1
        isGeneratingWorkFolderContext = false
        lastInfoMessage = "Generation stopped"
    }

    func updateContextPrompt(_ prompt: String) async {
        await mutateWorkFolder { proj in
            proj.settings.contextPrompt = prompt
        }
    }

    // MARK: - Autovisor settings

    func updateAutovisorGoal(_ goal: String) async {
        await mutateWorkFolder { proj in
            proj.settings.autovisorGoal = goal
        }
        // The manager's brief (rendered as "## Supervisor Goal") IS its goal —
        // `syncAutovisorGoalToManagerBrief` keeps the task's `supervisorTask` (plus
        // goal clips + attachment paths) in lock-step. It owns the manager-loaded
        // guard and the `autovisorTaskID == nil` (pre-Enable) no-op.
        await syncAutovisorGoalToManagerBrief()
    }

    /// Persists the Autovisor's standing memory. Used by both the Settings
    /// editor and the manager's own `update_scratchpad` write-through.
    func updateAutovisorMemory(_ memory: String) async {
        await mutateWorkFolder { proj in
            proj.settings.autovisorMemory = memory
        }
    }

    /// Persists the Autovisor's event-wake triggers + auto-off timer.
    /// `clamped()` re-floors `autoDisableAfterSeconds` here because the editor's
    /// bindings mutate the fields directly, bypassing the init clamp (same rationale
    /// as `updateAutovisorTuning`).
    func updateAutovisorActivation(_ activation: AutovisorActivation) async {
        let oldAutoOff = snapshot?.workFolder.settings.autovisorActivation.effectiveAutoDisableAfterSeconds
        await mutateWorkFolder { proj in
            proj.settings.autovisorActivation = activation.clamped()
        }
        // Sleep timer: any persisted change to the EFFECTIVE duration (toggle or
        // value) re-arms from "now" — that's the sleep-timer contract. Compare
        // PERSISTED old vs new (post-clamp, post-write) so flipping an unrelated
        // wake trigger — the whole struct arrives via `.onChange(of: activation)` —
        // never resets a running timer, and a failed write re-arms nothing.
        let newAutoOff = snapshot?.workFolder.settings.autovisorActivation.effectiveAutoDisableAfterSeconds
        if oldAutoOff != newAutoOff {
            rearmAutovisorAutoDisable()
        }
    }

    /// Persists the Autovisor's numeric behaviour caps (throughput + stuck
    /// detection). Read live by `createManagedTask` and the stuck detector — no
    /// engine restart needed. `clamped()` re-applies the floors here because the
    /// editor's `$tuning.field` bindings mutate fields directly, bypassing the
    /// init clamps.
    func updateAutovisorTuning(_ tuning: AutovisorTuning) async {
        await mutateWorkFolder { proj in
            proj.settings.autovisorTuning = tuning.clamped()
        }
    }

    func fetchAvailableSchemes() async -> [String] {
        guard let workFolderRoot = workFolderURL else { return [] }
        return await workFolderManagementService.fetchAvailableSchemes(workFolderRoot: workFolderRoot)
    }

    func saveToolDefinitions(_ tools: [ToolDefinitionRecord]) async {
        guard let url = workFolderURL else { return }
        do {
            let snapshot = try settingsService.saveToolDefinitions(tools, at: url)
            apply(snapshot)
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    func resetWorkFolderSettings() async {
        guard let url = workFolderURL else { return }
        // Tip-dismissal state lives in UserDefaults (not in the work folder), and
        // clearing it cannot fail — so do it unconditionally regardless of whether
        // the disk reset succeeds. The user pressed "reset"; tips should reappear.
        configuration.dismissedFeatureTipIDs = []
        do {
            let snapshot = try settingsService.resetWorkFolderSettings(at: url)
            apply(snapshot)
            // Reset re-bootstraps the default templates (which exclude Autovisor) —
            // re-seed the always-present protected singleton so it survives a reset.
            await ensureAutovisorTeam()
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Team Management

    /// Switches to a different team and syncs roleStatuses in the current run.
    func switchTeam(to teamID: NTMSID) async {
        // Both mis-teaming guards (re-teaming the Autovisor manager itself, and
        // re-teaming a normal task ONTO the Autovisor team) are delegated to the pure
        // `TeamSwitchPlanner.canSwitchTeam`, which unwraps `activeTaskID` before the id
        // compare so two nil ids don't wrongly block the switch. The UI
        // (TeamActivityFeedView.teamHeaderMenu) renders a static label for the manager,
        // so this is defense-in-depth.
        guard let currentSnapshot = snapshot,
              let team = currentSnapshot.workFolder.teams.first(where: { $0.id == teamID }),
              TeamSwitchPlanner.canSwitchTeam(
                  activeTaskID: activeTaskID, autovisorTaskID: autovisorTaskID, target: team)
        else { return }

        // Writes only workfolder.json (activeTeamID diff).
        await mutateWorkFolder { proj in
            proj.setActiveTeam(teamID)
        }

        guard let taskID = activeTaskID, let folderURL = workFolderURL else { return }

        // If engine is running, pause it first to cancel in-flight LLM and role tasks
        if let state = taskEngineStates[taskID],
           state == .running || state == .needsAcceptance || state == .needsSupervisorInput {
            await pauseRun(taskID: taskID)
        }

        // `pauseRun` is a LONG suspension — it awaits the running step's cancellation handler
        // (up to `LLMConstants.cancelHandlerTimeoutSeconds`), a recursive child-pause cascade
        // and a disk write. One click on Open Recent inside that window switches folders, and
        // `mutateTask` below would then bind the NEW folder's URL while `teamID`/`taskID` came
        // from the old one. Task ids are per-folder sequential ints, so the collision is the
        // norm (see `apply(_:)`): folder A's team id gets pinned onto folder B's task, and
        // `TeamSwitchPlanner.filteredSteps` deletes every step whose role isn't in A's roster
        // — an unrelated task's run history, on disk. Same guard, same reasoning as
        // `recoverStaleStatusesAcrossIndex`; checked synchronously, with no suspension point
        // before `mutateTask` binds the URL.
        guard workFolderURL == folderURL else { return }

        await mutateTask(taskID: taskID) { task in
            // Update task's preferred team so engine resolves correctly
            task.preferredTeamID = teamID

            // Abandon any transient generated team. `TeamResolution` (and thus
            // `resolvedTeam(for:)` / `buildChatMessages` / `makeStep`) checks
            // `generatedTeam` FIRST, so leaving it set would keep the engine
            // resolving the OLD generated roster while the run is re-pinned to
            // `teamID` below — minting steps / building prompts against the wrong
            // team (a dead run). The switch target is always a real folder team
            // (the generated placeholder is hidden from the picker), so the
            // transient is unconditionally stale here. Also align the task's
            // chat mode to the switched-to team (the getter falls back to
            // `storedIsChatMode` once the generated team is cleared).
            task.clearGeneratedTeam()
            task.setStoredChatMode(team.isChatMode)

            guard let runIndex = task.runs.indices.last else { return }
            var run = task.runs[runIndex]

            let roleIDs = Set(team.roles.map(\.id))

            // Remove steps belonging to roles not in the new team
            run.steps = TeamSwitchPlanner.filteredSteps(run.steps, forTeamRoleIDs: roleIDs)

            run.roleStatuses = RunService.initialRoleStatuses(for: team.roles)
            run.teamID = teamID
            run.updatedAt = MonotonicClock.shared.now()
            task.runs[runIndex] = run
        }

        // `clearGeneratedTeam()` above de-referenced the transient roster's
        // per-role override models — and this path flows through `mutateTask`,
        // which the `teamsChanged` residency trigger (a `mutateWorkFolder`
        // diff) never sees. Sweep explicitly, silent (housekeeping) — see
        // `sweepResidencyAfterEngineTransition`.
        await reconcileChatModelResidency()
    }
}

// MARK: - Agent Instructions Scan Key

/// Inputs of one `AgentInstructionsScanner.scan` call — the memo key for
/// `refreshAgentInstructions`' short-TTL skip. Any change to the folder or the
/// user's instruction overrides produces a different key, bypassing the memo.
nonisolated struct AgentInstructionsScanKey: Equatable {
    let root: URL
    let extraPaths: [String]
    let excludedPaths: [String]
    let injectedPaths: [String]
}

