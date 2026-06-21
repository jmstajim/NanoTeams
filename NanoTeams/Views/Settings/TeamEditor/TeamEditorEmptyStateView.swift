import SwiftUI

/// Reusable empty-state view for team editor lists (roles, artifacts).
/// Thin wrapper over `NTMSEmptyState` so title + description honor
/// Typography mono tokens instead of `ContentUnavailableView`'s SF Pro chrome.
struct TeamEditorEmptyStateView: View {
    let title: String
    let icon: String
    let description: String
    let actionTitle: String
    let onAction: () -> Void

    var body: some View {
        NTMSEmptyState(
            title: title,
            message: description,
            systemImage: icon,
            action: onAction,
            actionLabel: actionTitle
        )
    }
}

#Preview {
    TeamEditorEmptyStateView(
        title: "No Roles",
        icon: "person.3",
        description: "Add roles to define your team structure.",
        actionTitle: "Add Role",
        onAction: {}
    )
    .frame(width: 400, height: 300)
    .background(Colors.surfacePrimary)
}
