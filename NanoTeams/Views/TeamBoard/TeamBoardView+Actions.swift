import SwiftUI

// MARK: - Team Board View Actions

/// Action handlers for TeamBoardView (acceptance, revision, restart, review artifact lookup).
/// Extracted from TeamBoardView.swift to keep the main view file focused on layout + state.
extension TeamBoardView {

    func supervisorReviewArtifacts() -> [String] {
        resolvedTeam.supervisorRequiredArtifacts
    }

    func autoSelectAttentionRole(statuses: [String: RoleExecutionStatus]) {
        // Find first role that needs Supervisor attention (sorted for deterministic selection)
        if let roleID = statuses.keys.sorted().first(where: { statuses[$0] == .needsAcceptance }) {
            selectedRoleID = roleID
        }
    }

    func handleAcceptance(roleID: String) {
        guard let taskID = task?.id else { return }
        Task { _ = await store.acceptRole(taskID: taskID, roleID: roleID) }
    }

    func handleRevisionRequest(roleID: String, comment: String) {
        guard let taskID = task?.id else { return }
        Task { await store.requestRevision(taskID: taskID, roleID: roleID, comment: comment) }
    }

    func handleRestartRole(roleID: String, comment: String) {
        guard let taskID = task?.id else { return }
        Task {
            await store.restartRole(
                taskID: taskID,
                roleID: roleID,
                comment: comment.isEmpty ? nil : comment
            )
        }
    }
}
