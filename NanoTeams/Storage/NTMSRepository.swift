import Foundation

enum NTMSRepositoryError: LocalizedError {
    case invalidProjectFolder(URL)
    case missingSecurityAccess(URL)
    case taskNotFound(Int)
    case unableToEncodeReport
    case unableToWriteReport(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidProjectFolder(let url):
            "Selected folder is not accessible: \(url.path)"
        case .missingSecurityAccess(let url):
            "No permission to access the selected folder: \(url.path)"
        case .taskNotFound(let id):
            "Task not found: \(id)"
        case .unableToEncodeReport:
            "Unable to encode report as UTF-8."
        case .unableToWriteReport(let url, let underlying):
            "Unable to write report to \(url.path): \(underlying.localizedDescription)"
        }
    }
}

struct NTMSRepository {
    let store: AtomicJSONStore
    let fileManager: FileManager

    init(fileManager: FileManager = .default, store: AtomicJSONStore = AtomicJSONStore()) {
        self.fileManager = fileManager
        self.store = store
    }

    func openOrCreateWorkFolder(at workFolderRoot: URL) throws -> WorkFolderContext {
        guard fileManager.fileExists(atPath: workFolderRoot.path) else {
            throw NTMSRepositoryError.invalidProjectFolder(workFolderRoot)
        }

        let paths = try preparePaths(at: workFolderRoot)

        var (state, settings, teamsFile) = try loadOrRecoverFiles(paths: paths, workFolderRoot: workFolderRoot)
        try migrateIfNeeded(teamsFile: &teamsFile, paths: paths)

        let toolDefinitions = try loadToolDefinitions(paths: paths)
        var tasksIndex = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)

        var activeTask: NTMSTask?
        if let activeID = state.activeTaskID {
            if fileManager.fileExists(atPath: paths.taskJSON(taskID: activeID).path) {
                activeTask = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: activeID))

                // Update index entry for the active task only (derived status, title, updatedAt).
                if let activeTask {
                    let refreshed = activeTask.toSummary()
                    if let idx = tasksIndex.tasks.firstIndex(where: { $0.id == refreshed.id }) {
                        if tasksIndex.tasks[idx] != refreshed {
                            tasksIndex.tasks[idx] = refreshed
                            try store.write(tasksIndex, to: paths.tasksIndexJSON)
                        }
                    }
                }
            } else {
                // Stale active ID; clear it.
                state.activeTaskID = nil
                try store.write(state, to: paths.workFolderJSON)
            }
        }

        let projection = WorkFolderProjection(
            state: state,
            settings: settings,
            teams: teamsFile.teams
        )

        return WorkFolderContext(
            projection: projection,
            tasksIndex: tasksIndex,
            toolDefinitions: toolDefinitions,
            activeTaskID: state.activeTaskID,
            activeTask: activeTask
        )
    }

    // MARK: - Narrow update methods (one file per method)

    /// Update just the user-editable project settings. Writes **only** `settings.json`.
    func updateWorkFolderDescription(at workFolderRoot: URL, description: String) throws
        -> WorkFolderContext
    {
        let paths = try preparePaths(at: workFolderRoot)

        var settings = try store.read(ProjectSettings.self, from: paths.settingsJSON)
        settings.description = description
        try store.write(settings, to: paths.settingsJSON)

        return try assembleContext(paths: paths, settings: settings)
    }

    func updateSelectedScheme(at workFolderRoot: URL, scheme: String?) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)

        var settings = try store.read(ProjectSettings.self, from: paths.settingsJSON)
        settings.selectedScheme = scheme
        try store.write(settings, to: paths.settingsJSON)

        return try assembleContext(paths: paths, settings: settings)
    }

    /// Applies a mutation to `WorkFolderState` and writes **only** `workfolder.json`.
    @discardableResult
    func updateWorkFolderState(
        at workFolderRoot: URL,
        mutate: (inout WorkFolderState) -> Void
    ) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        mutate(&state)
        state.updatedAt = MonotonicClock.shared.now()
        try store.write(state, to: paths.workFolderJSON)
        return try assembleContext(paths: paths, workFolderState: state)
    }

    /// Applies a mutation to `ProjectSettings` and writes **only** `settings.json`.
    @discardableResult
    func updateSettings(
        at workFolderRoot: URL,
        mutate: (inout ProjectSettings) -> Void
    ) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)
        var settings = try store.read(ProjectSettings.self, from: paths.settingsJSON)
        mutate(&settings)
        try store.write(settings, to: paths.settingsJSON)

        return try assembleContext(paths: paths, settings: settings)
    }

    /// Applies a mutation to the teams array and writes **only** `teams.json`.
    @discardableResult
    func updateTeams(
        at workFolderRoot: URL,
        mutate: (inout [Team]) -> Void
    ) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        mutate(&teamsFile.teams)
        try store.write(teamsFile, to: paths.teamsJSON)

        return try assembleContext(paths: paths, teamsFile: teamsFile)
    }

    /// Build a `WorkFolderContext` from provided data, reading from disk only for
    /// components not supplied. Unlike `openOrCreateWorkFolder`, this does NOT
    /// bootstrap/migrate — it assumes the work folder has already been opened and
    /// only assembles the context from current state.
    func assembleContext(
        paths: NTMSPaths,
        workFolderState: WorkFolderState? = nil,
        settings: ProjectSettings? = nil,
        teamsFile: TeamsFile? = nil,
        tasksIndex: TasksIndex? = nil,
        toolDefinitions: [ToolDefinitionRecord]? = nil,
        activeTask: NTMSTask? = nil,
        activeTaskProvided: Bool = false
    ) throws -> WorkFolderContext {
        let state = try workFolderState ?? store.read(WorkFolderState.self, from: paths.workFolderJSON)
        let resolvedSettings = try settings ?? store.read(ProjectSettings.self, from: paths.settingsJSON)
        let resolvedTeamsFile = try teamsFile ?? store.read(TeamsFile.self, from: paths.teamsJSON)
        let tools = try toolDefinitions ?? loadToolDefinitions(paths: paths)
        let index = try tasksIndex ?? store.read(TasksIndex.self, from: paths.tasksIndexJSON)

        var resolvedActiveTask: NTMSTask?
        if activeTaskProvided {
            resolvedActiveTask = activeTask
        } else if let activeID = state.activeTaskID,
                  fileManager.fileExists(atPath: paths.taskJSON(taskID: activeID).path)
        {
            resolvedActiveTask = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: activeID))
        }

        let projection = WorkFolderProjection(
            state: state,
            settings: resolvedSettings,
            teams: resolvedTeamsFile.teams
        )

        return WorkFolderContext(
            projection: projection,
            tasksIndex: index,
            toolDefinitions: tools,
            activeTaskID: state.activeTaskID,
            activeTask: resolvedActiveTask
        )
    }

    func pickFallbackActiveTaskID(from index: TasksIndex) -> Int? {
        if let inProgress = index.tasks.first(where: { $0.status != .done }) {
            return inProgress.id
        }
        return index.tasks.first?.id
    }

    func loadToolDefinitions(paths: NTMSPaths) throws -> [ToolDefinitionRecord] {
        if !fileManager.fileExists(atPath: paths.toolsJSON.path) {
            let defaults = ToolDefinitionRecord.defaultDefinitions()
            try store.write(defaults, to: paths.toolsJSON)
            return defaults
        }

        let stored = try store.read([ToolDefinitionRecord].self, from: paths.toolsJSON)
        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: stored)
        if merged != stored {
            try store.write(merged, to: paths.toolsJSON)
        }
        return merged
    }

    func resetWorkFolderSettings(at workFolderRoot: URL) throws -> WorkFolderContext {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)

        // Remove entire .nanoteams directory
        if fileManager.fileExists(atPath: paths.nanoteamsDir.path) {
            try fileManager.removeItem(at: paths.nanoteamsDir)
        }

        // Reload/Bootstrap (will recreate .nanoteams with defaults)
        return try openOrCreateWorkFolder(at: workFolderRoot)
    }

    @discardableResult
    func preparePaths(at workFolderRoot: URL) throws -> NTMSPaths {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try ensureLayout(paths: paths)
        try bootstrapIfNeeded(paths: paths, workFolderRoot: workFolderRoot)
        return paths
    }

    /// Attributes applied to directories under `.nanoteams/internal/` to restrict access to the current user.
    static let internalDirAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]

    func ensureLayout(paths: NTMSPaths) throws {
        if !fileManager.fileExists(atPath: paths.nanoteamsDir.path) {
            try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        }
        // LLM-accessible directories
        if !fileManager.fileExists(atPath: paths.tasksDir.path) {
            try fileManager.createDirectory(at: paths.tasksDir, withIntermediateDirectories: true)
        }
        // Internal directories (hidden from LLM) — owner-only access
        if !fileManager.fileExists(atPath: paths.internalDir.path) {
            try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true,
                                             attributes: Self.internalDirAttributes)
        }
        if !fileManager.fileExists(atPath: paths.internalTasksDir.path) {
            try fileManager.createDirectory(at: paths.internalTasksDir, withIntermediateDirectories: true,
                                             attributes: Self.internalDirAttributes)
        }
        // Fix existing installations (idempotent)
        try? fileManager.setAttributes(Self.internalDirAttributes, ofItemAtPath: paths.internalDir.path)
        try? fileManager.setAttributes(Self.internalDirAttributes, ofItemAtPath: paths.internalTasksDir.path)

        ensureGitignore(paths: paths)
        ensureSpotlightExclusion(paths: paths)
        applyBackupExclusion(paths: paths)
    }

    // MARK: - Security Helpers

    /// Creates `.nanoteams/.gitignore` excluding `internal/` from git — only in real project folders.
    private func ensureGitignore(paths: NTMSPaths) {
        let url = paths.nanoteamsDir.appendingPathComponent(".gitignore")
        guard !fileManager.fileExists(atPath: url.path) else { return }
        // Skip for default storage (Application Support)
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           paths.workFolderRoot.standardizedFileURL.path
               .hasPrefix(appSupport.standardizedFileURL.path) { return }
        let content = "# NanoTeams internal data (logs, conversations, network traces)\ninternal/\n"
        try? content.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Writes a `.metadata_never_index` marker inside `internal/` to hint Spotlight to skip indexing.
    private func ensureSpotlightExclusion(paths: NTMSPaths) {
        let marker = paths.internalDir.appendingPathComponent(".metadata_never_index")
        if !fileManager.fileExists(atPath: marker.path) {
            _ = fileManager.createFile(atPath: marker.path, contents: nil)
        }
    }

    /// Excludes `internal/` from Time Machine backups via URL resource values.
    private func applyBackupExclusion(paths: NTMSPaths) {
        var url = paths.internalDir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
