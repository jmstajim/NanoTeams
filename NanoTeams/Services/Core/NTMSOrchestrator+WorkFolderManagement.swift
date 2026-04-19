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

            // Sync engine state from the run so UI shows Resume button after restart
            if let activeTask = self.activeTask, let lastRun = activeTask.runs.last {
                syncEngineStateFromRun(taskID: activeTask.id, run: lastRun)
            }

            if !snapshot.deferredReconcileTeamIDs.isEmpty {
                let count = snapshot.deferredReconcileTeamIDs.count
                let noun = count == 1 ? "team" : "teams"
                lastInfoMessage = "Bundled updates deferred for \(count) \(noun) — will retry on next open."
            }
        } catch {
            self.lastErrorMessage = error.localizedDescription
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
