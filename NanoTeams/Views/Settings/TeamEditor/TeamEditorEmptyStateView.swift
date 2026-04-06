import SwiftUI

/// Reusable empty-state view for team editor lists (roles, artifacts).
/// Uses ContentUnavailableView with a title, icon, description, and a single action button.
struct TeamEditorEmptyStateView: View {
    let title: String
    let icon: String
    let description: String
    let actionTitle: String
    let onAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(description)
        } actions: {
            Button(actionTitle, action: onAction)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
