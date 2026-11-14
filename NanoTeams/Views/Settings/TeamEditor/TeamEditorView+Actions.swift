import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Team Editor Actions

/// The handlers are the view half: what is selected, what sheet is up. Each write is a static
/// function beside it (`selectTeam`, `createTeam`, `duplicateTeam`, `deleteTeam`,
/// `restoreDefaultTeams`, `importTeam`) taking the folder lifecycle the click captured, so the
/// write is tested apart from the view, refuses once that folder is no longer open, and reports a
/// refusal in this editor's banner through `TeamEditCommitQueue.perform`. Until 2026-11-08 these
/// handlers dropped `mutateWorkFolder`'s outcome: a refused Delete or Restore was a banner in the
/// MAIN window, behind Settings.
extension TeamEditorView {

    func handleSelectTeam(_ teamID: NTMSID) {
        // The managed singleton (Autovisor) must never become the work folder's
        // default team for new tasks — track it as a local editor selection only.
        if store.snapshot?.workFolder.teams.first(where: { $0.id == teamID })?.isManagedSingleton == true {
            editorSelectedTeamID = teamID
            return
        }
        // Normal teams update the global default (preserves prior behavior).
        editorSelectedTeamID = nil
        let lifecycle = store.currentFolderLifecycle
        Task { await Self.selectTeam(teamID, in: store, editedIn: lifecycle) }
    }

    /// Creates a team from the New Team sheet's picker selection. `templateID` is a
    /// `TeamTemplateFactory.templateMetadata` id — including the synthetic
    /// `emptyTemplateID` — never an optional sentinel.
    ///
    /// Resolution lives in `TeamTemplateFactory.makeTeam` rather than here because this
    /// call site needs a live orchestrator and `mutateWorkFolder`, which made the
    /// unresolved-id case untestable. "No template" used to be encoded as `nil`, and the
    /// nil branch fell through to `TeamManagementService.createTeam`, which cloned FAANG:
    /// picking "Empty Team" produced a full 9-role team.
    func handleCreateTeam(name: String, templateID: String) {
        editorSelectedTeamID = nil
        let lifecycle = store.currentFolderLifecycle
        Task { await Self.createTeam(name: name, templateID: templateID, in: store, editedIn: lifecycle) }
    }

    /// Generates a team via direct LLM call (no task/run). Returns nil on success,
    /// an error message on failure. Surface non-fatal build warnings (e.g. dropped
    /// tool names) via `lastInfoMessage`, and a refused install — the write's own
    /// outcome, or another folder opened while the team was generated — as a sheet error.
    func handleGenerateTeam(taskDescription: String) async -> String? {
        // Captured before the model is asked: a generation takes long enough for another folder
        // to be opened, and the team it builds belongs to this one.
        let lifecycle = store.currentFolderLifecycle
        do {
            var effectiveConfig = LLMExecutionService.buildEffectiveConfig(
                globalConfig: store.globalLLMConfig,
                roleOverride: store.configuration.teamGenLLMOverride
            )
            // The same memo the runtime path reads, for the model the override names.
            effectiveConfig.toolCallingMode = await store.resolveToolCallingMode(for: effectiveConfig)
            // Interleaves on the global model like the runtime team-gen path does.
            await store.recordPrefixChainForTasklessCall(
                owner: .oneShot(label: "team generation"),
                config: effectiveConfig,
                messages: [])
            let raw = try await TeamGenerationService.generate(
                taskDescription: taskDescription,
                config: effectiveConfig,
                systemPrompt: store.configuration.teamGenSystemPromptOrNil
            )
            // Skip the install if the sheet was cancelled while we were
            // awaiting the LLM. Without this, an in-flight generation that
            // completes after `cancel()` would mutate the work folder and
            // surface a team the user explicitly rejected.
            if Task.isCancelled { return nil }
            let buildResult = GeneratedTeamBuilder.applyForcedDefaults(
                to: raw,
                supervisorMode: store.configuration.teamGenForcedSupervisorMode,
                acceptanceMode: store.configuration.teamGenForcedAcceptanceMode
            )
            let team = buildResult.team
            // Read off the write's own outcome, never the `lastErrorMessage` slot: the error
            // banner nils that on any render — and this sheet is on screen for the whole
            // generation — so a consumed slot read back as "no error" and a refused
            // `teams.json` write reported the generated team as installed while nothing had
            // been persisted. (The `errorSurfaceCount` that replaced it could be tripped by any
            // unrelated error surfacing during the write's residency reconcile.)
            let outcome = await Self.write(in: store, editedIn: lifecycle) { project in
                project.teams.append(team)
                project.activeTeamID = team.id
            }
            if let reason = outcome.failureReason {
                return reason
            }
            if !buildResult.warnings.isEmpty {
                store.lastInfoMessage = buildResult.warnings.joined(separator: " ")
            }
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return message
        }
    }

    func handleDuplicateTeam() {
        // The managed singleton (Autovisor) is not duplicable.
        guard let stored = activeTeam, !stored.isManagedSingleton else { return }
        // The team as the editor shows it — an edit still being written included.
        let team = binding(for: stored).wrappedValue

        editorSelectedTeamID = nil
        let lifecycle = store.currentFolderLifecycle
        Task { await Self.duplicateTeam(team, in: store, editedIn: lifecycle) }
    }

    func handleDeleteTeam() {
        guard let snapshot = store.snapshot,
              let team = activeTeam,
              TeamManagementService.canDeleteTeam(in: snapshot.workFolder, teamID: team.id) else {
            return
        }

        editorSelectedTeamID = nil
        let lifecycle = store.currentFolderLifecycle
        Task { await Self.deleteTeam(team, in: store, editedIn: lifecycle) }
    }

    func handleRestoreDefaults() {
        let lifecycle = store.currentFolderLifecycle
        Task { await Self.restoreDefaultTeams(in: store, editedIn: lifecycle) }
    }

    /// Through the team's binding like every other edit of it: a whole-team write of the
    /// snapshot copy beside the queue could land before or after an edit waiting there, and
    /// whichever went second would undo the other.
    func handleResetLayout() {
        guard let stored = activeTeam else { return }
        let team = binding(for: stored)
        var reset = team.wrappedValue
        TeamManagementService.resetGraphLayout(&reset)
        team.wrappedValue = reset
    }

    func handleSaveTeam() {
        validateCurrentTeam()
    }

    func handleExportTeam() {
        // The team as the editor shows it — an edit still being written included.
        guard let team = activeTeam.map({ binding(for: $0).wrappedValue }) else { return }
        do {
            let data = try TeamImportExportService.exportTeam(team)
            let fileName = TeamImportExportService.suggestedFileName(for: team)
            try ImportExportPanelHelper.presentExportPanel(data: data, fileName: fileName, message: "Export Team")
        } catch {
            importError = (error as? ImportExportError) ?? .invalidData
        }
    }

    func handleImportTeam() {
        guard let data = ImportExportPanelHelper.presentImportPanel(message: "Import Team") else { return }
        do {
            let importedTeam = try TeamImportExportService.importTeam(from: data)
            editorSelectedTeamID = nil
            let lifecycle = store.currentFolderLifecycle
            Task { await Self.importTeam(importedTeam, in: store, editedIn: lifecycle) }
        } catch let error as ImportExportError {
            importError = error
        } catch {
            importError = .invalidData
        }
    }

    // MARK: - The writes

    /// A team picked in the selector becomes the folder's default team for new tasks.
    @discardableResult
    static func selectTeam(
        _ teamID: NTMSID, in store: NTMSOrchestrator, editedIn lifecycle: WorkFolderLifecycle
    ) async -> WorkFolderMutationOutcome {
        await store.teamEdits.perform(editedIn: lifecycle) {
            await write(in: store, editedIn: lifecycle) { $0.activeTeamID = teamID }
        }
    }

    /// New Team: the picked template under the typed name, made the folder's default team.
    @discardableResult
    static func createTeam(
        name: String, templateID: String, in store: NTMSOrchestrator, editedIn lifecycle: WorkFolderLifecycle
    ) async -> WorkFolderMutationOutcome {
        await store.teamEdits.perform(editedIn: lifecycle) {
            await write(in: store, editedIn: lifecycle) { project in
                let newTeam = TeamTemplateFactory.makeTeam(templateID: templateID, name: name)
                // Through `addTeam`, and selecting the id it RETURNS: a team id is derived
                // from its name, so two teams named alike would share one — and the id the
                // team carries is then not the id it was added under.
                project.activeTeamID = project.addTeam(newTeam)
            }
        }
    }

    /// Duplicate: a copy of `team` — the team as the editor shows it — made the default team.
    @discardableResult
    static func duplicateTeam(
        _ team: Team, in store: NTMSOrchestrator, editedIn lifecycle: WorkFolderLifecycle
    ) async -> WorkFolderMutationOutcome {
        await store.teamEdits.perform(editedIn: lifecycle) {
            await write(in: store, editedIn: lifecycle) { project in
                let duplicated = TeamManagementService.duplicateTeam(team, newName: "\(team.name) Copy")
                // The two-click case: duplicating twice names both copies `<team> Copy`.
                project.activeTeamID = project.addTeam(duplicated)
            }
        }
    }

    /// Delete. An edit of the team still waiting to be written goes first, so it cannot land
    /// after the delete as a refusal ("no longer in this work folder").
    @discardableResult
    static func deleteTeam(
        _ team: Team, in store: NTMSOrchestrator, editedIn lifecycle: WorkFolderLifecycle
    ) async -> WorkFolderMutationOutcome {
        await store.teamEdits.perform(editedIn: lifecycle) {
            // Block deletion of a team that backs a live run — removing it mid-run
            // would strand the run (the team can no longer resolve) and previously
            // caused a silent fallback that commingled a second roster into the run.
            // The user must pause/close the task first. Said in the main window's banner
            // too, like every refused write, and — through `perform` — in this editor's.
            if store.teamIsInUseByActiveRun(team.id) {
                let reason = "Can't delete \"\(team.name)\" — a task is running on it or scheduled to re-run on it. "
                    + "Pause/close that task or turn off its schedule first."
                store.lastErrorMessage = reason
                return .failed(reason: reason)
            }
            _ = await store.teamEdits.settle(teamID: team.id)
            return await write(in: store, editedIn: lifecycle) { project in
                // Routing through `removeTeam` records the template tombstone so
                // subsequent `migrateIfNeeded` passes don't resurrect this team
                // on the next open or on version bump.
                project.removeTeam(team.id)
            }
        }
    }

    /// Restore Default Teams. Waiting edits go first: the restore replaces template teams
    /// wholesale, and an edit written after it would put the replaced team back.
    @discardableResult
    static func restoreDefaultTeams(
        in store: NTMSOrchestrator, editedIn lifecycle: WorkFolderLifecycle
    ) async -> WorkFolderMutationOutcome {
        await store.teamEdits.perform(editedIn: lifecycle) {
            await store.teamEdits.settleAll()
            return await write(in: store, editedIn: lifecycle) { project in
                // Template teams have deterministic IDs (from NTMSID.from(name:)),
                // so defaultTeams always produces the same team/role/artifact IDs.
                for defaultTeam in Team.defaultTeams {
                    guard let tid = defaultTeam.templateID else { continue }
                    if let idx = project.teams.firstIndex(where: { $0.templateID == tid }) {
                        project.teams[idx] = defaultTeam
                    } else {
                        project.teams.append(defaultTeam)
                    }
                }
                // Restore erases all tombstones so users can explicitly undo any
                // prior deletions (team/role/artifact) they may have made.
                project.state.deletedTeamTemplateIDs = []
                for i in project.teams.indices {
                    project.teams[i].deletedSystemRoleIDs = []
                    project.teams[i].deletedSystemArtifactIDs = []
                }
            }
        }
    }

    /// Import: the decoded team added and made the default team.
    @discardableResult
    static func importTeam(
        _ team: Team, in store: NTMSOrchestrator, editedIn lifecycle: WorkFolderLifecycle
    ) async -> WorkFolderMutationOutcome {
        await store.teamEdits.perform(editedIn: lifecycle) {
            await write(in: store, editedIn: lifecycle) { project in
                // Importing the same file twice derives `<team> (Imported)` both times.
                project.activeTeamID = project.addTeam(team)
            }
        }
    }

    /// `mutateWorkFolder` for an action that began in `lifecycle`, asked right before the write —
    /// after whatever the action awaited first: once another folder is open nothing is written,
    /// since template teams share ids across folders and a Delete begun in one folder would
    /// otherwise remove the next folder's team of the same id.
    static func write(
        in store: NTMSOrchestrator,
        editedIn lifecycle: WorkFolderLifecycle,
        _ change: (inout WorkFolderProjection) -> Void
    ) async -> WorkFolderMutationOutcome {
        guard store.isCurrentFolderLifecycle(lifecycle) else {
            return .failed(reason: TeamEditCommitQueue.actionFolderChangedReason)
        }
        return await store.mutateWorkFolder(change)
    }
}
