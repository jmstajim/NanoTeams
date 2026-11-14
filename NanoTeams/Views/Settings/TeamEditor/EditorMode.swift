import Foundation

/// Generic editor mode for create/edit sheets.
/// Replaces duplicate `EditorMode` enums in `RoleEditorSheet` and `ArtifactEditorSheet`.
nonisolated enum EditorMode<T: Identifiable>: Identifiable where T.ID == String {
    case create
    case edit(T)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let item): return item.id
        }
    }

    var isCreate: Bool {
        if case .create = self { return true }
        return false
    }
}

/// A Team Editor sheet a click asked for: create or edit, and the session that click captured —
/// the team and the folder lifecycle the person was looking at (`TeamEditCommitQueue.Session`).
///
/// The click is where opening a sheet begins, so it is where the lifecycle is captured
/// (`WorkFolderLifecycle`). Captured any later — from the render that presents the sheet — a click
/// handled in the same update as a folder switch would pair the clicked role of one folder with
/// the next folder's team, and the sheet's Save would write the one into the other.
nonisolated struct TeamEditSheetRequest<Edited: Identifiable>: Identifiable where Edited.ID == String {
    let mode: EditorMode<Edited>
    let session: TeamEditCommitQueue.Session

    var id: String { mode.id }
}
