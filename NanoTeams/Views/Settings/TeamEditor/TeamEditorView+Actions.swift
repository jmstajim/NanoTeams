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
                project.teams.removeAll { $0.id == team.id }
                if let firstTeam = project.teams.first {
                    project.activeTeamID = firstTeam.id
                }
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
