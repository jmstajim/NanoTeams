import SwiftUI

// MARK: - Previews

#Preview("New Artifact") {
    @Previewable @State var store = PreviewStore.make()
    let team = Team.default
    let lifecycle = store.currentFolderLifecycle
    ArtifactEditorSheet(
        team: .constant(team),
        session: TeamEditCommitQueue.Session(team: team, lifecycle: lifecycle),
        mode: .create,
        onSave: { _ in }
    )
    .environment(store)
}

#Preview("Save Refused") {
    @Previewable @State var store = PreviewStore.make()
    let (team, artifact) = ArtifactEditorSheetPreview.teamWithItsOwnArtifact()
    let lifecycle = store.currentFolderLifecycle
    ArtifactEditorSheet(
        team: .constant(team),
        session: TeamEditCommitQueue.Session(team: team, lifecycle: lifecycle),
        mode: .edit(artifact),
        onSave: { _ in },
        saveError: "Failed to persist work folder changes (teams.json): You don’t have permission to save the file “teams.json”."
    )
    .environment(store)
}

/// The mocked facts the previews above show.
// periphery:ignore - used in #Preview macros above
private enum ArtifactEditorSheetPreview {
    /// A bundled team plus one artifact of the person's own — bundled artifacts keep their names
    /// locked, and the refused Save is shown on the form that can be edited.
    static func teamWithItsOwnArtifact() -> (Team, TeamArtifact) {
        var team = Team.default
        let draft = ArtifactEditorMutations.Draft(
            name: "Threat Model", description: "Attack surface, trust boundaries and the mitigations chosen.",
            icon: "shield", mimeType: "text/markdown")
        guard let artifact = ArtifactEditorMutations.applyCreate(to: &team, draft: draft) else {
            preconditionFailure("the preview's artifact name collides with a bundled one")
        }
        return (team, artifact)
    }
}
