import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Team Editor Actions

extension TeamEditorView {

    func handleSelectTeam(_ teamID: NTMSID) {
        Task {
            await store.mutateWorkFolder { project in
                project.activeTeamID = teamID
            }
        }
    }

    func handleCreateTeam(name: String, templateID: String?) {
        Task {
            await store.mutateWorkFolder { project in
                let newTeam: Team

                if let templateID = templateID,
                   let template = Team.defaultTeams.first(where: { $0.templateID == templateID }) {
                    newTeam = template.duplicate(withName: name)
                } else {
                    newTeam = TeamManagementService.createTeam(name: name)
                }

                project.teams.append(newTeam)
                project.activeTeamID = newTeam.id
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
            let raw = try await TeamGenerationService.generate(
                taskDescription: taskDescription,
                config: effectiveConfig,
                systemPrompt: store.configuration.teamGenSystemPromptOrNil
            )
            let buildResult = GeneratedTeamBuilder.applyForcedDefaults(
                to: raw,
                supervisorMode: store.configuration.teamGenForcedSupervisorMode,
                acceptanceMode: store.configuration.teamGenForcedAcceptanceMode
            )
            let team = buildResult.team
            let priorError = store.lastErrorMessage
            await store.mutateWorkFolder { project in
                project.teams.append(team)
                project.activeTeamID = team.id
            }
            if store.lastErrorMessage != priorError, let err = store.lastErrorMessage {
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
        guard let team = activeTeam else { return }

        Task {
            await store.mutateWorkFolder { project in
                let duplicated = TeamManagementService.duplicateTeam(team, newName: "\(team.name) Copy")
                project.teams.append(duplicated)
                project.activeTeamID = duplicated.id
            }
        }
    }

    func handleDeleteTeam() {
        guard let snapshot = store.snapshot,
              let team = activeTeam,
              TeamManagementService.canDeleteTeam(in: snapshot.workFolder, teamID: team.id) else {
            return
        }

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
            Task {
                await store.mutateWorkFolder { project in
                    project.teams.append(importedTeam)
                    project.activeTeamID = importedTeam.id
                }
            }
        } catch let error as ImportExportError {
            importError = error
        } catch {
            importError = .invalidData
        }
    }
}
