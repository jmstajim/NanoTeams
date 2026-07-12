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
        if let path = configuration.lastOpenedWorkFolderPath {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                await openWorkFolder(url)
                try? repository.cleanupAllStagedDrafts(at: url)
                return
            }
        }
        // Fall back to default storage
        let defaultURL = Self.defaultStorageURL
        try? fileManager.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        await openWorkFolder(defaultURL)
        try? repository.cleanupAllStagedDrafts(at: defaultURL)
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
        llmExecutionService.cancelAllExecutions()
        await tearDownSearchIndexCoordinator()
        workFolderURL = url

        do {
            var snapshot = try workFolderManagementService.openOrCreateWorkFolder(at: url)

            // Recover stale statuses from a previous session where the app closed
            // while tasks were running. Steps in .running/.needsSupervisorInput → .paused,
            // roles in .working → .idle.
            if var activeTask = snapshot.activeTask {
                if StatusRecoveryService.recoverStaleStatuses(in: &activeTask) {
                    snapshot.activeTask = activeTask
                    try repository.updateTaskOnly(at: url, task: activeTask)
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

            if !snapshot.deferredReconcileTeamIDs.isEmpty {
                let count = snapshot.deferredReconcileTeamIDs.count
                let noun = count == 1 ? "team" : "teams"
                lastInfoMessage = "Bundled updates deferred for \(count) \(noun) — will retry on next open."
            }

            // Spin up the search index coordinator if exploratory search is enabled.
            await setUpSearchIndexCoordinatorIfEnabled()
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
        // Keep the instructions snapshot honest on BOTH paths: if the open threw
        // above, `workFolderURL` already points at the new folder while the
        // in-memory snapshot still belongs to the previous one — rescan (or
        // clear, for default storage) so Settings/previews can't render the old
        // folder's files against the new URL. On the happy path the TTL memo
        // makes this a no-op.
        await refreshAgentInstructions()
        // Sync the LM Studio embed-model state to whatever the coordinator
        // ended up at. Lives outside the do/catch so it runs on both happy
        // and error paths — if openOrCreateWorkFolder threw, the coordinator
        // is nil and reconcile will unload anything we had loaded for the
        // prior folder.
        await reconcileEmbeddingLifecycle()
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
        let staleEntries = (snapshot?.tasksIndex.tasks ?? [])
            .filter { $0.status == .running || $0.status == .needsSupervisorInput }
            .map { (id: $0.id, status: $0.status) }            // snapshot — mutateTask re-sorts the live array mid-loop
        guard !staleEntries.isEmpty else { return }
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
                guard StatusRecoveryService.recoverStaleStatuses(in: &probe) else { continue }
                let persisted = await mutateTask(taskID: taskID) {
                    _ = StatusRecoveryService.recoverStaleStatuses(in: &$0)
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
                if !persisted, loaded.toSummary().status != entry.status {
                    do { try repository.updateTaskOnly(at: folderURL, task: loaded) }
                    catch { failedIDs.append(taskID) }
                }
            }
            evictIfReclaimable(taskID)
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
            watcherDebounce: configuration.searchIndexWatcherDebounceSeconds
        )
        // `start()` awaits — a concurrent caller could install a coordinator
        // in the meantime. Install AFTER start so the observed ordering is
        // "create → start → publish", never "publish with a half-initialized
        // watcher".
        await coordinator.start()

        if searchIndexCoordinator != nil {
            // Lost the race — tear down the one we built before returning.
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
            if searchIndexCoordinator == nil {
                await setUpSearchIndexCoordinatorIfEnabled()
                if searchIndexCoordinator == nil, !hasRealWorkFolder {
                    lastInfoMessage = "Exploratory Search needs an open project folder — default storage isn't indexed."
                }
            }
        } else {
            if let coordinator = searchIndexCoordinator {
                await coordinator.clear()
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
        try? fileManager.removeItem(at: nanoteamsDir)
        try? fileManager.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        await openWorkFolder(defaultURL)
    }

    // MARK: - Agent Instruction Files

    /// Skip re-scanning when the last scan used identical inputs and finished
    /// this recently — collapses back-to-back run starts (a recurrence tick
    /// firing several tasks, Autovisor passes) into one walk. Any add/remove/
    /// restore edit changes the scan key, bypassing the memo automatically.
    private static let agentInstructionsScanTTL: TimeInterval = 5

    /// Rescan the open work folder for agent instruction files (auto-discovered
    /// CLAUDE.md/AGENTS.md/… + user-attached extras − exclusions) and refresh
    /// the in-memory `agentInstructions` snapshot. The walk runs off the main
    /// actor. Called on work-folder open, at each top-level `startRun`, on the
    /// Work Folder settings tab appear, before prompt-preview renders, and after
    /// instruction add/remove/restore. In default storage / no folder there is
    /// nothing to scan → snapshot cleared to `nil`.
    func refreshAgentInstructions() async {
        guard hasRealWorkFolder, let root = workFolderURL else {
            agentInstructionsScanGeneration += 1  // drop in-flight old-folder scans
            agentInstructionsLastScanKey = nil
            if agentInstructions != nil { agentInstructions = nil }
            return
        }
        let extras = workFolder?.settings.agentInstructionExtraPaths ?? []
        let excluded = workFolder?.settings.agentInstructionExcludedPaths ?? []
        let injected = workFolder?.settings.agentInstructionInjectedPaths ?? []
        let key = AgentInstructionsScanKey(
            root: root, extraPaths: extras, excludedPaths: excluded, injectedPaths: injected)
        if key == agentInstructionsLastScanKey,
           let lastScanAt = agentInstructionsLastScanAt,
           Date().timeIntervalSince(lastScanAt) < Self.agentInstructionsScanTTL {
            return
        }

        agentInstructionsScanGeneration += 1
        let expected = agentInstructionsScanGeneration
        let scanned = await Task.detached(priority: .utility) {
            AgentInstructionsScanner.scan(
                workFolderRoot: root, manualPaths: extras,
                excludedPaths: excluded, injectedPaths: injected)
        }.value
        // CLAUDE.md #38: a newer refresh started during the await (or the folder
        // switched/closed, which also bumps the generation) supersedes this scan.
        guard agentInstructionsScanGeneration == expected else { return }
        agentInstructionsLastScanKey = key
        agentInstructionsLastScanAt = Date()
        // Equality guard: @Observable fires on every write regardless of value;
        // skipping no-op writes keeps open preview sheets / Settings from
        // re-rendering on every run start (CLAUDE.md View Conventions #9/#11).
        if agentInstructions != scanned { agentInstructions = scanned }
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
        if !accepted.isEmpty {
            await mutateWorkFolder { projection in
                var extras = projection.settings.agentInstructionExtraPaths
                for rel in accepted where !extras.contains(rel) { extras.append(rel) }
                projection.settings.agentInstructionExtraPaths = extras
                // Re-attaching a previously excluded file means "inject it again".
                projection.settings.agentInstructionExcludedPaths.removeAll { accepted.contains($0) }
            }
            await refreshAgentInstructions()
        }
        if !rejected.isEmpty {
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
        await refreshAgentInstructions()
        if injected,
           !(agentInstructions?.injectedFiles.contains { $0.relativePath == relativePath } ?? false) {
            // The file didn't read as text — drop the dangling override and
            // tell the user why nothing visibly changed.
            await mutateWorkFolder { projection in
                projection.settings.agentInstructionInjectedPaths.removeAll { $0 == relativePath }
            }
            lastInfoMessage = "\(relativePath) isn't readable text — it stays listed for on-demand reading."
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

        guard let taskID = activeTaskID else { return }

        // If engine is running, pause it first to cancel in-flight LLM and role tasks
        if let state = taskEngineStates[taskID],
           state == .running || state == .needsAcceptance || state == .needsSupervisorInput {
            await pauseRun(taskID: taskID)
        }

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
