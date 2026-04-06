import SwiftUI

// MARK: - ArtifactListView Actions

extension ArtifactListView {
    func handleSaveArtifact() {
        onSave()
    }

    func handleDuplicateArtifact(_ artifact: TeamArtifact) {
        var duplicated = artifact
        duplicated.name = "\(artifact.name) Copy"
        duplicated.id = TeamArtifact.slugify(duplicated.name)
        duplicated.isSystemArtifact = false
        duplicated.systemArtifactName = nil
        let now = MonotonicClock.shared.now()
        duplicated.createdAt = now
        duplicated.updatedAt = now

        team.addArtifact(duplicated)
        onSave()
    }

    func handleDeleteArtifact(_ artifact: TeamArtifact) {
        team.removeArtifact(artifact.id)
        onSave()
        showingDeleteConfirmation = nil

        if selectedArtifactID == artifact.id {
            selectedArtifactID = nil
        }
    }

    func handleExportArtifact(_ artifact: TeamArtifact) {
        do {
            let data = try TeamImportExportService.exportArtifact(artifact)
            let fileName = TeamImportExportService.suggestedFileName(for: artifact)
            try ImportExportPanelHelper.presentExportPanel(data: data, fileName: fileName, message: "Export Artifact")
        } catch {
            importError = (error as? ImportExportError) ?? .invalidData
        }
    }

    func handleImportArtifact() {
        guard let data = ImportExportPanelHelper.presentImportPanel(message: "Import Artifact") else { return }
        do {
            try TeamImportExportService.importArtifact(from: data, into: &team)
            onSave()
        } catch let error as ImportExportError {
            importError = error
        } catch {
            importError = .invalidData
        }
    }
}
