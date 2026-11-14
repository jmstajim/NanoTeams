import SwiftUI

// MARK: - Previews

#Preview("New Role") {
    @Previewable @State var store = PreviewStore.make()
    let team = Team.default
    let lifecycle = store.currentFolderLifecycle
    RoleEditorSheet(
        team: .constant(team),
        session: TeamEditCommitQueue.Session(team: team, lifecycle: lifecycle),
        mode: .create,
        onSave: {}
    )
    .environment(store)
    .environment(store.configuration)
}

#Preview("Save Refused") {
    @Previewable @State var store = PreviewStore.make()
    let team = Team.default
    let role = team.roles.first { !$0.isSupervisor } ?? team.roles[0]
    let lifecycle = store.currentFolderLifecycle
    RoleEditorSheet(
        team: .constant(team),
        session: TeamEditCommitQueue.Session(team: team, lifecycle: lifecycle),
        mode: .edit(role),
        onSave: {},
        saveError: "Failed to persist work folder changes (teams.json): You don’t have permission to save the file “teams.json”."
    )
    .environment(store)
    .environment(store.configuration)
}
