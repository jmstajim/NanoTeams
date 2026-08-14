import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Team Editor Actions

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
        Task {
            await store.mutateWorkFolder { project in
                project.activeTeamID = teamID
            }
        }
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
        Task {
            await store.mutateWorkFolder { project in
                let newTeam = TeamTemplateFactory.makeTeam(templateID: templateID, name: name)
                // Through `addTeam`, and selecting the id it RETURNS: a team id is derived
                // from its name, so two teams named alike would share one — and the id the
                // team carries is then not the id it was added under.
                project.activeTeamID = project.addTeam(newTeam)
            }
        }
    }

    /// Generates a team via direct LLM call (no task/run). Returns nil on success,
    /// an error message on failure. Surface non-fatal build warnings (e.g. dropped
    /// tool names) via `lastInfoMessage`, and surface persistence failure (a stale
    /// `lastErrorMessage` after the workfolder mutate) as a sheet error.
    func handleGenerateTeam(taskDescription: String) async -> String? {
        do {
            let effectiveConfig = LLMExecutionService.buildEffectiveConfig(
                globalConfig: store.globalLLMConfig,
                roleOverride: store.configuration.teamGenLLMOverride
            )
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
            // Counted, not slot-compared: `mutateWorkFolder` surfaces its refusal into
            // `lastErrorMessage`, which the error banner nils on any render — and this
            // sheet is on screen for the whole generation. A consumed slot read back as
            // "no error", so a refused `teams.json` write reported the generated team as
            // installed while nothing had been persisted.
            let priorErrorCount = store.errorSurfaceCount
            await store.mutateWorkFolder { project in
                project.teams.append(team)
                project.activeTeamID = team.id
            }
            if let err = store.errorSurfaced(since: priorErrorCount) {
                return err
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
        guard let team = activeTeam, !team.isManagedSingleton else { return }

        editorSelectedTeamID = nil
        Task {
            await store.mutateWorkFolder { project in
                let duplicated = TeamManagementService.duplicateTeam(team, newName: "\(team.name) Copy")
                // The two-click case: duplicating twice names both copies `<team> Copy`.
                project.activeTeamID = project.addTeam(duplicated)
            }
        }
    }

    func handleDeleteTeam() {
        guard let snapshot = store.snapshot,
              let team = activeTeam,
              TeamManagementService.canDeleteTeam(in: snapshot.workFolder, teamID: team.id) else {
            return
        }

        // Block deletion of a team that backs a live run — removing it mid-run
        // would strand the run (the team can no longer resolve) and previously
        // caused a silent fallback that commingled a second roster into the run.
        // The user must pause/close the task first.
        if store.teamIsInUseByActiveRun(team.id) {
            store.lastErrorMessage = "Can't delete \"\(team.name)\" — a task is running on it or scheduled to re-run on it. Pause/close that task or turn off its schedule first."
            return
        }

        editorSelectedTeamID = nil
        Task {
            await store.mutateWorkFolder { project in
                // Routing through `removeTeam` records the template tombstone so
                // subsequent `migrateIfNeeded` passes don't resurrect this team
                // on the next open or on version bump.
                project.removeTeam(team.id)
            }
        }
    }

    func handleRestoreDefaults() {
        Task {
            await store.mutateWorkFolder { project in
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

    func handleResetLayout() {
        guard var team = activeTeam else { return }

        Task {
            await store.mutateWorkFolder { project in
                if let index = project.teams.firstIndex(where: { $0.id == team.id }) {
                    TeamManagementService.resetGraphLayout(&team)
                    project.teams[index] = team
                }
            }
        }
    }

    func handleSaveTeam() {
        validateCurrentTeam()
    }

    func handleExportTeam() {
        guard let team = activeTeam else { return }
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
            Task {
                await store.mutateWorkFolder { project in
                    // Importing the same file twice derives `<team> (Imported)` both times.
                    project.activeTeamID = project.addTeam(importedTeam)
                }
            }
        } catch let error as ImportExportError {
            importError = error
        } catch {
            importError = .invalidData
        }
    }
}
