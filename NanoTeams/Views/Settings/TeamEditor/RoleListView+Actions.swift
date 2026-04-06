import SwiftUI

// MARK: - RoleListView Actions

extension RoleListView {
    func handleSaveRole() {
        onSave()
    }

    func handleDuplicateRole(_ role: TeamRoleDefinition) {
        var duplicated = role
        duplicated.name = "\(role.name) Copy"
        duplicated.id = NTMSID.from(name: "\(team.id):\(duplicated.name)")
        let now = MonotonicClock.shared.now()
        duplicated.createdAt = now
        duplicated.updatedAt = now

        TeamManagementService.addRole(to: &team, role: duplicated)
        onSave()
    }

    func handleDeleteRole(_ role: TeamRoleDefinition) {
        TeamManagementService.removeRole(from: &team, roleID: role.id)
        onSave()
        showingDeleteConfirmation = nil

        if selectedRoleID == role.id {
            selectedRoleID = nil
        }
    }

    func handleExportRole(_ role: TeamRoleDefinition) {
        do {
            let data = try TeamImportExportService.exportRole(role)
            let fileName = TeamImportExportService.suggestedFileName(for: role)
            try ImportExportPanelHelper.presentExportPanel(data: data, fileName: fileName, message: "Export Role")
        } catch {
            importError = (error as? ImportExportError) ?? .invalidData
        }
    }

    func handleAddToGraph(_ role: TeamRoleDefinition) {
        let positions = team.graphLayout.nodePositions
        let avgX: CGFloat
        let newY: CGFloat
        if positions.isEmpty {
            avgX = 300
            newY = 100
        } else {
            avgX = positions.map { $0.x }.reduce(0, +) / CGFloat(positions.count)
            newY = (positions.map { $0.y }.max() ?? 400) + 120
        }
        team.graphLayout.showRole(role.id, at: CGPoint(x: avgX, y: newY))
        onSave()
    }

    func handleImportRole() {
        guard let data = ImportExportPanelHelper.presentImportPanel(message: "Import Role") else { return }
        do {
            try TeamImportExportService.importRole(from: data, into: &team)
            onSave()
        } catch let error as ImportExportError {
            importError = error
        } catch {
            importError = .invalidData
        }
    }
}
