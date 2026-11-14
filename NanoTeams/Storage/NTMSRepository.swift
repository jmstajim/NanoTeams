import Foundation

/// No `missingSecurityAccess` case, on purpose (wave 32): security-scoped folder access is
/// owned by `FolderAccessManager`, which surfaces its own failures — the repository never
/// had a path that could throw it.
enum NTMSRepositoryError: LocalizedError {
    case invalidProjectFolder(URL)
    case taskNotFound(Int)
    case unableToEncodeReport
    case unableToWriteReport(URL, underlying: Error)
    /// A step's stream flush failed — the whole task write is refused so the
    /// blob and the log can never disagree about where the streams live.
    case stepLogWriteFailed(taskID: Int, stepID: String)
    /// A split task whose streams were never hydrated reached `updateTaskOnly`.
    /// Persisting it would diff empty arrays against the log and TRUNCATE a
    /// run's whole conversation — loud refusal, never silent data loss.
    case unhydratedTask(Int)

    var errorDescription: String? {
        switch self {
        case .invalidProjectFolder(let url):
            "Selected folder is not accessible: \(url.path)"
        case .taskNotFound(let id):
            "Task not found: \(id)"
        case .unableToEncodeReport:
            "Unable to encode report as UTF-8."
        case .unableToWriteReport(let url, let underlying):
            "Unable to write report to \(url.path): \(underlying.localizedDescription)"
        case .stepLogWriteFailed(let taskID, let stepID):
            "Unable to write the step log for task \(taskID), step '\(stepID)'."
        case .unhydratedTask(let id):
            "Refusing to persist task \(id): its conversation streams were never loaded."
        }
    }
}

nonisolated struct NTMSRepository: WorkFolderRepository, TaskRepository, ToolRepository, ArtifactRepository, AttachmentRepository, @unchecked Sendable {
    let store: AtomicJSONStore
    let fileManager: FileManager
    /// Where each folder's lock lives (`WorkFolderInstanceLocking`) — read by the write gate in
    /// `preparePaths`, so a write into a folder another NanoTeams process holds is refused.
    let instanceLocking: WorkFolderInstanceLocking

    init(
        fileManager: FileManager = .default,
        store: AtomicJSONStore = AtomicJSONStore(),
        instanceLocking: WorkFolderInstanceLocking = .system
    ) {
        self.fileManager = fileManager
        self.store = store
        self.instanceLocking = instanceLocking
    }

    func openOrCreateWorkFolder(at workFolderRoot: URL) throws -> WorkFolderContext {
        guard fileManager.fileExists(atPath: workFolderRoot.path) else {
            throw NTMSRepositoryError.invalidProjectFolder(workFolderRoot)
        }

        let paths = try preparePaths(at: workFolderRoot)

        var (state, settings, teamsFile) = try loadOrRecoverFiles(paths: paths, workFolderRoot: workFolderRoot)

        // Loaded BEFORE `migrateIfNeeded` on purpose: the reconcile's running-role
        // scan needs the index, and `loadOrRecoverFile` backs up + resets a corrupt
        // one. Reading it inside the scan instead (as it used to) meant a corrupt
        // index fail-closed the entire pass for one whole open, even though this
        // very open was about to recover it a few lines later.
        var tasksIndex: TasksIndex = try loadOrRecoverFile(
            at: paths.tasksIndexJSON,
            default: TasksIndex()
        )

        // `inout`: step 2c heals the vacuous chat mode a Generated-Team task inherited
        // from the placeholder, in `task.json` AND in its index row. The active task is
        // read BELOW this line, so it lands in memory already healed and the
        // `toSummary()` reconciliation a few lines down no-ops.
        let bundledUpdate = try migrateIfNeeded(
            teamsFile: &teamsFile, state: &state, tasksIndex: &tasksIndex, paths: paths
        )

        let toolDefinitions = try loadToolDefinitions(paths: paths)

        var activeTask: NTMSTask?
        if let activeID = state.activeTaskID {
            let ancestors = tasksIndex.ancestorIDs(of: activeID)
            if fileManager.fileExists(atPath: paths.taskJSON(taskID: activeID, ancestors: ancestors).path) {
                var loaded = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: activeID, ancestors: ancestors))
                hydrateStreams(&loaded, paths: paths, ancestors: ancestors)
                activeTask = loaded

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
            activeTask: activeTask,
            bundledUpdate: bundledUpdate
        )
    }

    // MARK: - Narrow update methods (one file per method)

    /// Applies a mutation to `WorkFolderState` and writes **only** `workfolder.json`.
    @discardableResult
    func updateWorkFolderState(
        at workFolderRoot: URL,
        activeTask: NTMSTask?,
        mutate: (inout WorkFolderState) -> Void
    ) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        mutate(&state)
        state.updatedAt = MonotonicClock.shared.now()
        try store.write(state, to: paths.workFolderJSON)
        return try assembleContext(paths: paths, workFolderState: state,
                                   activeTask: activeTask, activeTaskProvided: true)
    }

    /// Applies a mutation to `ProjectSettings` and writes **only** `settings.json`.
    @discardableResult
    func updateSettings(
        at workFolderRoot: URL,
        activeTask: NTMSTask?,
        mutate: (inout ProjectSettings) -> Void
    ) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)
        var settings = try store.read(ProjectSettings.self, from: paths.settingsJSON)
        mutate(&settings)
        try store.write(settings, to: paths.settingsJSON)

        return try assembleContext(paths: paths, settings: settings,
                                   activeTask: activeTask, activeTaskProvided: true)
    }

    /// Applies a mutation to the teams array and writes **only** `teams.json`.
    @discardableResult
    func updateTeams(
        at workFolderRoot: URL,
        activeTask: NTMSTask?,
        mutate: (inout [Team]) -> Void
    ) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        mutate(&teamsFile.teams)
        try store.write(teamsFile, to: paths.teamsJSON)

        return try assembleContext(paths: paths, teamsFile: teamsFile,
                                   activeTask: activeTask, activeTaskProvided: true)
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
        // The id guard is what lets the narrow writers hand their in-memory copy in.
        // Skipping the read is the smaller half of why: `mutateTask` commits the task in
        // memory on `@MainActor` and only THEN detaches the disk write (invariant #6), so
        // a copy read from disk inside that window is OLDER than the one the caller holds
        // — and `apply(_:)` assigns it straight onto `activeTask`, silently reverting the
        // newest mutation. Trusting the caller closes that window; the guard makes it safe
        // when the same write moved `activeTaskID` somewhere else.
        // `nil == nil` is the no-active-task case and takes the same branch: no read.
        if activeTaskProvided, activeTask?.id == state.activeTaskID {
            resolvedActiveTask = activeTask
        } else if let activeID = state.activeTaskID {
            let ancestors = index.ancestorIDs(of: activeID)
            if fileManager.fileExists(atPath: paths.taskJSON(taskID: activeID, ancestors: ancestors).path) {
                var loaded = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: activeID, ancestors: ancestors))
                hydrateStreams(&loaded, paths: paths, ancestors: ancestors)
                resolvedActiveTask = loaded
            }
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

    /// Picks the next active task after the current one is deleted. `excluding`
    /// (the Autovisor task ID) is never chosen — the manager is hidden from
    /// the task list, so landing the user on it would strand them on an invisible task.
    func pickFallbackActiveTaskID(from index: TasksIndex, excluding: Int? = nil) -> Int? {
        let candidates = index.tasks.filter { $0.parentTaskID == nil && $0.id != excluding }
        if let inProgress = candidates.first(where: { $0.status != .done }) {
            return inProgress.id
        }
        return candidates.first?.id
    }

    /// Loads tool definitions from `tools.json`. Does NOT merge with bundled
    /// defaults — that reconcile happens in `migrateIfNeeded` (on version bump)
    /// and in `updateTools` (explicit user save). Seeds defaults only when the
    /// file is missing (fresh bootstrap).
    func loadToolDefinitions(paths: NTMSPaths) throws -> [ToolDefinitionRecord] {
        try loadOrRecoverFile(
            at: paths.toolsJSON,
            default: ToolDefinitionRecord.defaultDefinitions()
        )
    }

    func resetWorkFolderSettings(at workFolderRoot: URL) throws -> WorkFolderContext {
        try removeWorkFolderData(at: workFolderRoot)
        // Reload/Bootstrap (will recreate .nanoteams with defaults)
        return try openOrCreateWorkFolder(at: workFolderRoot)
    }

    /// Deletes everything the folder's `.nanoteams/` holds except its lock file.
    ///
    /// Gated first: a folder another process holds keeps its `.nanoteams/`. The lock file stays
    /// because the lock is on it (`WorkFolderInstanceLock` — "the file is never deleted"): until
    /// 2026-11-12 a reset removed it with the rest, so the lock this process held sat on a file no
    /// other process could open, a second NanoTeams could create and lock a new one before this
    /// one took it again, and this one's bootstrap then wrote into a folder that process held
    /// (D-M18 R7). A lock file kept elsewhere (`WorkFolderInstanceLocking.isolatingDefaultStorage`)
    /// is not in the tree, which then goes whole.
    func removeWorkFolderData(at workFolderRoot: URL) throws {
        try instanceLocking.refuseIfHeldByAnotherProcess(workFolderRoot)
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        guard fileManager.fileExists(atPath: paths.nanoteamsDir.path) else { return }
        let lockFile = instanceLocking.lockFile(workFolderRoot).standardizedFileURL
        guard lockFile.deletingLastPathComponent() == paths.internalDir.standardizedFileURL,
              fileManager.fileExists(atPath: lockFile.path)
        else {
            try fileManager.removeItem(at: paths.nanoteamsDir)
            return
        }
        for name in try fileManager.contentsOfDirectory(atPath: paths.nanoteamsDir.path)
        where name != paths.internalDir.lastPathComponent {
            try fileManager.removeItem(at: paths.nanoteamsDir.appendingPathComponent(name))
        }
        for name in try fileManager.contentsOfDirectory(atPath: paths.internalDir.path)
        where name != lockFile.lastPathComponent {
            try fileManager.removeItem(at: paths.internalDir.appendingPathComponent(name))
        }
    }

    /// The gate every writer passes. First: no write into a folder another NanoTeams process holds
    /// (`WorkFolderInstanceLock`). A process whose open was refused keeps the folder's URL with
    /// nothing loaded, and the writers that ask only for the URL — a create, a settings or tool
    /// save, a reset — would otherwise still reach the folder (F6 C1, 2026-11-12). A lock this
    /// process holds answers from memory; a folder nobody holds, or one never opened by a NanoTeams
    /// with the lock, passes.
    @discardableResult
    func preparePaths(at workFolderRoot: URL) throws -> NTMSPaths {
        try instanceLocking.refuseIfHeldByAnotherProcess(workFolderRoot)
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try ensureLayout(paths: paths)
        try bootstrapIfNeeded(paths: paths, workFolderRoot: workFolderRoot)
        return paths
    }

    /// Attributes applied to directories under `.nanoteams/internal/` to restrict access to the current user.
    nonisolated(unsafe) static let internalDirAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]

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
        // Component-wise containment, not `hasPrefix`: the string form matches
        // `…/Application Supportive` against `…/Application Support`.
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           SandboxPathResolver.isWithin(candidate: paths.workFolderRoot, container: appSupport) { return }
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
