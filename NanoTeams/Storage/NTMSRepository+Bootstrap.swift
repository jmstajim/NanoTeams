import Foundation

// MARK: - Bootstrap & Migration

extension NTMSRepository {

    // MARK: - Composite load/recover

    /// Loads the three-file work folder state from disk with per-file recovery.
    ///
    /// For each of `workfolder.json` / `settings.json` / `teams.json`:
    /// - **File missing** → write a fresh default (expected first-run case, silent).
    /// - **File present but undecodable** → rename to `<name>.corrupt-<timestamp>.bak`,
    ///   log a diagnostic, write a fresh default for that one file only. The other
    ///   two files are left untouched so the user does not lose unrelated settings
    ///   when a single file is damaged.
    ///
    /// After per-file recovery, a cross-file consistency pass clears `activeTeamID`
    /// if it points to a team that no longer exists in `teams.json` (can happen if
    /// `teams.json` was recovered to defaults but `workfolder.json` still references
    /// a custom team from before).
    func loadOrRecoverFiles(
        paths: NTMSPaths,
        workFolderRoot: URL
    ) throws -> (WorkFolderState, ProjectSettings, TeamsFile) {
        let state: WorkFolderState = try loadOrRecoverFile(
            at: paths.workFolderJSON,
            default: WorkFolderState(
                schemaVersion: 5,
                id: UUID(),
                name: workFolderRoot.lastPathComponent
            )
        )
        let settings: ProjectSettings = try loadOrRecoverFile(
            at: paths.settingsJSON,
            default: ProjectSettings.defaults
        )
        var teamsFile: TeamsFile = try loadOrRecoverFile(
            at: paths.teamsJSON,
            default: TeamsFile(schemaVersion: 1, teams: Team.defaultTeams)
        )

        // Cross-file consistency: an activeTeamID that no longer resolves is
        // meaningless (UI would silently fall back to `teams.first`). Happens
        // when teams.json was recovered to defaults while workfolder.json was
        // intact. Clear it so the next state write persists a consistent pair.
        var repairedState = state
        if let activeID = repairedState.activeTeamID,
           !teamsFile.teams.contains(where: { $0.id == activeID })
        {
            repairedState.activeTeamID = nil
            try? store.write(repairedState, to: paths.workFolderJSON)
        }

        // Empty teams array (from a corrupt-then-defaulted teams.json whose
        // defaults were themselves empty, or a future migration bug) is a
        // broken invariant: bootstrap fresh defaults so the app has something
        // to work with.
        if teamsFile.teams.isEmpty {
            teamsFile.teams = Team.defaultTeams
            try? store.write(teamsFile, to: paths.teamsJSON)
        }

        return (repairedState, settings, teamsFile)
    }

    /// Loads a single JSON file, recovering from missing/corrupt states in place.
    /// See `loadOrRecoverFiles` for the policy.
    private func loadOrRecoverFile<T: Codable>(
        at url: URL,
        default defaultValue: @autoclosure () -> T
    ) throws -> T {
        if !fileManager.fileExists(atPath: url.path) {
            let value = defaultValue()
            try store.write(value, to: url)
            return value
        }
        do {
            return try store.read(T.self, from: url)
        } catch {
            // Preserve the damaged file as a .bak so the user (or support) can
            // recover forensically, then reset to defaults. Logging uses print
            // because the codebase has no dedicated logging infrastructure yet.
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp).bak", isDirectory: false)
            print("[NTMSRepository] CORRUPT: \(url.lastPathComponent) failed to decode (\(error)). "
                + "Backing up to \(backupURL.lastPathComponent) and resetting to defaults.")
            do {
                try fileManager.moveItem(at: url, to: backupURL)
            } catch {
                print("[NTMSRepository] WARNING: could not back up \(url.lastPathComponent): \(error). "
                    + "Overwriting with defaults.")
                try? fileManager.removeItem(at: url)
            }
            let value = defaultValue()
            try store.write(value, to: url)
            return value
        }
    }

    /// Ensures all bootstrap teams are present and system role dependencies are synced.
    /// Writes only `teams.json` when changes are made.
    func migrateIfNeeded(teamsFile: inout TeamsFile, paths: NTMSPaths) throws {
        var needsWrite = false

        let existingTemplateIDs = Set(teamsFile.teams.compactMap(\.templateID))
        let missingBootstrap = Team.defaultTeams.filter { bootstrap in
            guard let tid = bootstrap.templateID else { return false }
            return !existingTemplateIDs.contains(tid)
        }
        if !missingBootstrap.isEmpty {
            teamsFile.teams.append(contentsOf: missingBootstrap)
            needsWrite = true
        }

        if syncSystemRoleDependencies(teams: &teamsFile.teams) {
            needsWrite = true
        }

        if needsWrite {
            try store.write(teamsFile, to: paths.teamsJSON)
        }
    }

    func bootstrapIfNeeded(paths: NTMSPaths, workFolderRoot: URL) throws {
        // One-shot cleanup: remove legacy monolithic project.json orphaned from the
        // pre-split format. Idempotent — after first launch the file is gone. This
        // is NOT a migration (we don't read the old data); it's housekeeping to
        // avoid leaving a 100 KB stale file on disk.
        let legacyProjectJSON = paths.internalDir.appendingPathComponent("project.json", isDirectory: false)
        if fileManager.fileExists(atPath: legacyProjectJSON.path) {
            do {
                try fileManager.removeItem(at: legacyProjectJSON)
            } catch {
                // Non-fatal — the new readers don't touch project.json, so the
                // app still works with the orphan present. Surface so the user
                // (or support) can investigate permission/lock issues.
                print("[NTMSRepository] WARNING: could not remove legacy project.json "
                    + "at \(legacyProjectJSON.path): \(error)")
            }
        }

        let stateDefault = WorkFolderState(
            schemaVersion: 5,
            id: UUID(),
            name: workFolderRoot.lastPathComponent
        )
        try store.writeIfMissing(stateDefault, to: paths.workFolderJSON)

        try store.writeIfMissing(ProjectSettings.defaults, to: paths.settingsJSON)

        let teamsDefault = TeamsFile(schemaVersion: 1, teams: Team.defaultTeams)
        try store.writeIfMissing(teamsDefault, to: paths.teamsJSON)

        let toolsDefault = ToolDefinitionRecord.defaultDefinitions()
        try store.writeIfMissing(toolsDefault, to: paths.toolsJSON)

        let tasksIndexDefault = TasksIndex()
        try store.writeIfMissing(tasksIndexDefault, to: paths.tasksIndexJSON)
    }

    // MARK: - System Role Dependency Sync

    /// Syncs system role dependencies from current SystemTemplates.
    /// - producesArtifacts: synced unconditionally (never overridden by factory methods)
    /// - requiredArtifacts: only ADDS artifacts present in template but missing from stored,
    ///   AND whose producer exists in the team (prevents breaking teams with absent roles)
    /// - Skips Supervisor roles (their requiredArtifacts are set per-team, not from generic template)
    /// - Returns true if any changes were made
    func syncSystemRoleDependencies(teams: inout [Team]) -> Bool {
        var changed = false
        for teamIndex in teams.indices {
            let teamProducers = Set(
                teams[teamIndex].roles.flatMap { $0.dependencies.producesArtifacts }
            )
            if TeamManagementService.syncSystemRoleDependencies(
                team: &teams[teamIndex],
                templates: SystemTemplates.roles,
                teamProducers: teamProducers
            ) { changed = true }
        }
        return changed
    }
}
