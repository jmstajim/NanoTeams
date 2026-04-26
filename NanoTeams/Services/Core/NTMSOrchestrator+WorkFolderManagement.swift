import Foundation

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

            // Pass the whole task so chat-mode awareness in
            // `derivedStatusFromActiveRun` participates.
            if let activeTask = self.activeTask {
                syncEngineStateFromRun(taskID: activeTask.id, task: activeTask)
            }

            if !snapshot.deferredReconcileTeamIDs.isEmpty {
                let count = snapshot.deferredReconcileTeamIDs.count
                let noun = count == 1 ? "team" : "teams"
                lastInfoMessage = "Bundled updates deferred for \(count) \(noun) — will retry on next open."
            }

            // Spin up the search index coordinator if expanded search is enabled.
            await setUpSearchIndexCoordinatorIfEnabled()
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
        // Sync the LM Studio embed-model state to whatever the coordinator
        // ended up at. Lives outside the do/catch so it runs on both happy
        // and error paths — if openOrCreateWorkFolder threw, the coordinator
        // is nil and reconcile will unload anything we had loaded for the
        // prior folder.
        await reconcileEmbeddingLifecycle()
    }

    // MARK: - Search Index Coordinator Lifecycle

    /// Creates a coordinator bound to the current work folder (if expanded search
    /// is enabled) and kicks off an initial ensure-fresh pass.
    ///
    /// Skipped for default internal storage (Application Support) — that
    /// directory holds NanoTeams's own metadata for template/chat teams
    /// without a real project, and indexing it just surfaces bookkeeping
    /// files. Broad search only makes sense against a user-selected project.
    ///
    /// Idempotent: repeated calls with a coordinator already installed return
    /// early WITHOUT creating a second one. The install-after-await guard
    /// also protects against a concurrent caller entering during our
    /// `coordinator.start()` await — if someone else won the race, we tear
    /// down the one we built before returning so no FSEventStream is orphaned.
    func setUpSearchIndexCoordinatorIfEnabled() async {
        guard configuration.expandedSearchEnabled,
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
            fileManager: fileManager
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

    /// Hook: user toggled the "Expanded Search" setting. Creates or destroys the
    /// coordinator and (on disable) deletes the on-disk `search_index.json`.
    ///
    /// When the user enables expanded search while on default internal storage
    /// (no real project folder), `setUpSearchIndexCoordinatorIfEnabled` is a
    /// no-op — broadcast an info message so the toggle's "ON" state doesn't
    /// silently contradict the index-status card reading "disabled".
    ///
    /// Rapid toggle sequencing: `ExpandedSearchToggleCard.onChanged` spawns a
    /// detached `Task { await ... }` per click, so three rapid clicks race
    /// without inline awaits. We chain them through `pendingExpandedSearchToggle`
    /// so the effects apply in FIFO click order — otherwise the final state
    /// could disagree with the last click.
    func onExpandedSearchSettingChanged() async {
        let prior = pendingExpandedSearchToggle
        let myTask = Task { [weak self] in
            _ = await prior?.value
            guard let self else { return }
            await self.applyExpandedSearchSettingChange()
        }
        pendingExpandedSearchToggle = myTask
        _ = await myTask.value
        if pendingExpandedSearchToggle == myTask {
            pendingExpandedSearchToggle = nil
        }
    }

    private func applyExpandedSearchSettingChange() async {
        if configuration.expandedSearchEnabled {
            if searchIndexCoordinator == nil {
                await setUpSearchIndexCoordinatorIfEnabled()
                if searchIndexCoordinator == nil, !hasRealWorkFolder {
                    lastInfoMessage = "Expanded Search needs an open project folder — default storage isn't indexed."
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

    /// User changed the embed-model URL or name in `ExpandedSearchEmbeddingsCard`.
    /// Chains on the same FIFO sequencer as toggle events so a rapid model swap
    /// can't interleave with a toggle ON/OFF and leave us with the wrong state.
    ///
    /// I7: the `expandedSearchEnabled` guard runs INSIDE the queued task body,
    /// not before enqueueing — otherwise a config change observed while a
    /// toggle-OFF is still queued would read the not-yet-applied (stale) value
    /// and schedule a reconcile that fires after the toggle-OFF has already
    /// torn down the coordinator.
    func onExpandedSearchEmbeddingConfigChanged() async {
        let prior = pendingExpandedSearchToggle
        let myTask = Task { [weak self] in
            _ = await prior?.value
            guard let self else { return }
            // Read AFTER the prior task drained — this is now the post-FIFO
            // state, the only state the user actually committed to.
            guard self.configuration.expandedSearchEnabled else { return }
            await self.reconcileEmbeddingLifecycle()
        }
        pendingExpandedSearchToggle = myTask
        _ = await myTask.value
        if pendingExpandedSearchToggle == myTask {
            pendingExpandedSearchToggle = nil
        }
    }

    /// Drives `embeddingLifecycle` toward the desired state: model loaded
    /// when a coordinator is active. Called from every public lifecycle hook.
    ///
    /// I4: this is a *target* state, not an enforced invariant — when
    /// `ensureLoaded` throws, the coordinator stays installed but
    /// `embeddingLifecycle.loaded == nil`. The next reconcile retries.
    ///
    /// I3: load failures use `lastErrorMessage` (red banner) because the
    /// user enabled Expanded Search and the feature is now broken — info
    /// severity is wrong here. I8: unload failures (which `NativeLMStudioClient`
    /// already swallows for 404 / "no such instance") still surface via
    /// `lastInfoMessage` so the user knows VRAM may not have been reclaimed.
    ///
    /// No "Loading embedding model…" progress banner: the C1 adoption path
    /// (`listLoadedInstances` ahead of `loadModel`) makes the common case a
    /// near-instant adopt, and a banner that appears every reconcile is
    /// noise. If the user's actual first-time download is slow, LM Studio's
    /// own UI surfaces the download progress.
    private func reconcileEmbeddingLifecycle() async {
        if searchIndexCoordinator != nil {
            let modelName = configuration.effectiveEmbeddingConfig.modelName
            do {
                try await embeddingLifecycle.ensureLoaded(configuration.effectiveEmbeddingConfig)
            } catch {
                let url = configuration.effectiveEmbeddingConfig.baseURLString
                lastErrorMessage = "Couldn't load embedding model '\(modelName)': \(error.localizedDescription). Search will fall back to keyword-only matching. Check that LM Studio is running at \(url) and the model is downloaded."
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
        configuration.lastOpenedWorkFolderPath = nil
        let defaultURL = Self.defaultStorageURL
        try? fileManager.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        await openWorkFolder(defaultURL)
    }

    /// Deletes all data in Application Support and re-bootstraps from scratch.
    func resetAllData() async {
        stopAllEngines()
        llmExecutionService.cancelAllExecutions()
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

    // MARK: - Work Folder Settings

    func updateWorkFolderDescription(_ description: String) async {
        guard let url = workFolderURL else { return }
        do {
            let snapshot = try workFolderManagementService.updateWorkFolderDescription(description, at: url)
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

    func generateWorkFolderDescription() async -> String? {
        guard let workFolderRoot = workFolderURL else { return nil }
        do {
            return try await workFolderManagementService.generateWorkFolderDescription(
                workFolderRoot: workFolderRoot,
                config: globalLLMConfig,
                customPrompt: workFolder?.settings.descriptionPrompt
            )
        } catch is CancellationError {
            return nil
        } catch {
            self.lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func updateDescriptionPrompt(_ prompt: String) async {
        await mutateWorkFolder { proj in
            proj.settings.descriptionPrompt = prompt
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
        do {
            let snapshot = try settingsService.resetWorkFolderSettings(at: url)
            apply(snapshot)
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Team Management

    /// Switches to a different team and syncs roleStatuses in the current run.
    func switchTeam(to teamID: NTMSID) async {
        guard let currentSnapshot = snapshot else { return }
        guard let team = currentSnapshot.workFolder.teams.first(where: { $0.id == teamID }) else { return }

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

            guard let runIndex = task.runs.indices.last else { return }
            var run = task.runs[runIndex]

            let roleIDs = Set(team.roles.map(\.id))

            // Remove steps belonging to roles not in the new team
            run.steps = run.steps.filter { roleIDs.contains($0.effectiveRoleID) }

            run.roleStatuses = RunService.initialRoleStatuses(for: team.roles)
            run.teamID = teamID
            run.updatedAt = MonotonicClock.shared.now()
            task.runs[runIndex] = run
        }
    }
}
