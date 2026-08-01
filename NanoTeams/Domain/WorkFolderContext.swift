import Foundation

/// Complete project snapshot — work folder projection, task index, tool definitions,
/// and active/loaded tasks.
///
/// The `projection` field composites `WorkFolderState` + `ProjectSettings` + `[Team]`
/// from their respective files. The `workFolder` accessor is an alias for back-compat
/// with the large number of existing callsites that do `context.workFolder.teams`,
/// `context.workFolder.activeTeam`, etc.
nonisolated struct WorkFolderContext: Hashable {
    var projection: WorkFolderProjection
    var tasksIndex: TasksIndex
    var toolDefinitions: [ToolDefinitionRecord]
    var activeTaskID: Int?
    var activeTask: NTMSTask?
    /// Background running tasks loaded in memory (keyed by taskID).
    var loadedTasks: [Int: NTMSTask] = [:]
    /// What the version-bump reconcile could not apply this open, and why.
    ///
    /// Populated ONLY by `openOrCreateWorkFolder`. `assembleContext` — the path
    /// every `mutateWorkFolder` takes — rebuilds `WorkFolderContext` without it,
    /// so this field is wiped by the first unrelated edit. Anything that must
    /// outlive the open must read `NTMSOrchestrator.bundledUpdateReport`, which
    /// latches it.
    var bundledUpdate: BundledUpdateReport?

    /// Back-compat accessor: most callers expect `context.workFolder.teams` etc.
    /// The projection exposes a mimic surface (teams, activeTeamID, activeTeam, name, id)
    /// so existing code continues to work; only settings-scoped fields need rewriting
    /// to `context.workFolder.settings.*`.
    var workFolder: WorkFolderProjection {
        get { projection }
        set { projection = newValue }
    }
}
