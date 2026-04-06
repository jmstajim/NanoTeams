import Foundation

/// Generic editor mode for create/edit sheets.
/// Replaces duplicate `EditorMode` enums in `RoleEditorSheet` and `ArtifactEditorSheet`.
enum EditorMode<T: Identifiable>: Identifiable where T.ID == String {
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
