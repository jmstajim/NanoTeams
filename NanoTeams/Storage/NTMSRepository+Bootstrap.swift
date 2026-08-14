import Foundation

// MARK: - Bootstrap & Migration

nonisolated extension NTMSRepository {

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

        // Empty teams array (from a corrupt-then-defaulted teams.json whose
        // defaults were themselves empty, or a future migration bug) is a
        // broken invariant: bootstrap fresh defaults so the app has something
        // to work with.
        if teamsFile.teams.isEmpty {
            teamsFile.teams = Team.defaultTeams
            try store.write(teamsFile, to: paths.teamsJSON)
        }

        // Cross-file consistency: activeTeamID must always resolve to a real
        // team when teams exist. `WorkFolderProjection.activeTeam` already
        // falls back to `teams.first` when activeTeamID is nil, and
        // `removeTeam` explicitly sets it to `teams.first?.id` when the active
        // team is removed — so the invariant "active = teams.first if not
        // chosen" lives elsewhere in the code, and stored state must agree.
        // Two repair cases collapsed into one write:
        //   a) Dangling ID → teams.json was recovered while workfolder.json
        //      still pointed at a pre-corruption team. Replace with first.
        //   b) Nil ID with non-empty teams → bootstrap default. Set to first
        //      so the stored state matches what the UI effectively shows.
        var repairedState = state
        let resolvable = repairedState.activeTeamID.map { id in
            teamsFile.teams.contains(where: { $0.id == id })
        } ?? false
        if !resolvable, let firstID = teamsFile.teams.first?.id {
            repairedState.activeTeamID = firstID
            try store.write(repairedState, to: paths.workFolderJSON)
        }

        return (repairedState, settings, teamsFile)
    }

    /// Loads a single JSON file, recovering from missing/corrupt states in place.
    /// See `loadOrRecoverFiles` for the policy.
    func loadOrRecoverFile<T: Codable>(
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

    /// Ensures all bootstrap teams are present, system role dependencies are synced,
    /// and bundled content is reconciled on app version bumps.
    ///
    /// Writes only the files that actually changed — `teams.json`, `tools.json`,
    /// `workfolder.json` — each at most once per invocation.
    ///
    /// Responsibilities:
    /// 1. Append any bundled template that is neither present in the stored teams
    ///    nor in `state.deletedTeamTemplateIDs` (tombstone respect).
    /// 2. Run the legacy `syncSystemRoleDependencies` pass (additive `requiredArtifacts`,
    ///    unconditional `producesArtifacts`) as a narrow safety net.
    /// 3. If `AppVersion.current > state.lastAppliedAppVersion`, run the
    ///    full reconcile via `applyBundledContentUpdates` (roles / prompt templates
    ///    / settings / team structure / tools). Teams with a live tool loop are
    ///    deferred and recorded in `state.pendingReconcileTeamIDs`.
    /// 4. If nothing bumped but the pending set is non-empty, run a pass SCOPED to
    ///    those teams — the retry is independent of the version compare.
    /// 5. `state.lastAppliedAppVersion` always advances. Holding it back for a
    ///    deferral (the old behaviour) re-ran the FULL reconcile on every launch,
    ///    re-clobbering every other team's stored prompts each time.
    @discardableResult
    func migrateIfNeeded(
        teamsFile: inout TeamsFile,
        state: inout WorkFolderState,
        tasksIndex: inout TasksIndex,
        paths: NTMSPaths
    ) throws -> BundledUpdateReport {
        var teamsNeedsWrite = false
        var tasksIndexNeedsWrite = false
        var report = BundledUpdateReport()

        // 1. Append bundled templates the user hasn't tombstoned.
        let existingTemplateIDs = Set(teamsFile.teams.compactMap(\.templateID))
        let tombstoned = Set(state.deletedTeamTemplateIDs)
        let missingBootstrap = Team.defaultTeams.filter { bootstrap in
            guard let tid = bootstrap.templateID else { return false }
            return !existingTemplateIDs.contains(tid) && !tombstoned.contains(tid)
        }
        if !missingBootstrap.isEmpty {
            teamsFile.teams.append(contentsOf: missingBootstrap)
            teamsNeedsWrite = true
        }

        // 2. Legacy additive sync (kept as a narrow safety net — full reconcile
        //    below covers the same ground but only fires on version bump).
        if syncSystemRoleDependencies(teams: &teamsFile.teams) {
            teamsNeedsWrite = true
        }

        // 2a. Structural invariant for delegation: any role with delegation
        // settings populated (`hasDelegationConfigured == true`) is peer-level with
        // Supervisor and MUST NOT have an upstream `reportsTo` entry. Enforced
        // at construction time in `TeamTemplateFactory.buildSettings` and
        // `GeneratedTeamBuilder`; legacy `teams.json` files predating that rule
        // still carry stale entries. Self-healing on every load. Idempotent.
        if normalizeDelegatorPeerStatus(teams: &teamsFile.teams) {
            teamsNeedsWrite = true
        }

        // 2b. Structural invariant for delegation toolset: delegation tools
        // (`delegate_to_team`, `cancel_delegation`, `resume_delegation`,
        // `forward_to_team`) are NEVER part of stored `toolIDs` — they
        // auto-inject into the LLM schema based on the role's delegation
        // settings (see `LLMExecutionService+ToolResolution`). The legacy
        // `list_teams` tool (removed; the catalog is now inline in
        // `delegate_to_team`'s description) is also stripped here for the same
        // reason — older `teams.json` files still carry it. Strip on every
        // load so the invariant is self-healing. Idempotent.
        if normalizeDelegationToolset(teams: &teamsFile.teams) {
            teamsNeedsWrite = true
        }

        // 2c. Structural invariant for chat mode: a task whose effective team is the
        // Generated Team placeholder is NEVER a chat task — the placeholder's
        // `isChatMode` is vacuous (no roles ⇒ no Supervisor deliverables). Enforced at
        // creation by `Team.seedChatModeForNewTask`; task files written before that
        // predicate existed still carry `isChatMode: true`, and nothing on the
        // generation-failure path ever rewrites it. Self-healing on every load,
        // idempotent, and index-filtered so a healthy folder does zero task reads.
        if normalizeGeneratedPlaceholderChatMode(
            tasksIndex: &tasksIndex,
            teams: teamsFile.teams,
            activeTeamID: state.activeTeamID,
            paths: paths
        ) {
            tasksIndexNeedsWrite = true
        }

        // 3. Version-bump reconcile — overwrites scalar role fields, prompt
        //    templates, team settings, additively adds missing system roles and
        //    system artifacts, and re-syncs built-in tools.
        let currentAppVersion = AppVersion.current
        var stateNeedsWrite = false
        let versionBumped = AppVersion.shouldReconcile(
            from: state.lastAppliedAppVersion, to: currentAppVersion
        )
        // Prune ids for teams that no longer exist. Without this a deferred team
        // the user later deletes keeps the retry gate open forever, re-running a
        // scoped pass that matches nothing.
        let liveTeamIDs = Set(teamsFile.teams.map(\.id))
        let pending = Set(state.pendingReconcileTeamIDs).intersection(liveTeamIDs)

        if versionBumped || !pending.isEmpty {
            var tools = try loadToolDefinitions(paths: paths)
            let result = applyBundledContentUpdates(
                teams: &teamsFile.teams,
                tools: &tools,
                tasksIndex: tasksIndex,
                activeTeamID: state.activeTeamID,
                // A version bump re-applies everything; a pure retry touches only
                // the teams that still owe a pass, so it can't re-clobber a team
                // that already reconciled (and whose prompts the user may have
                // edited since).
                scope: versionBumped ? .allTemplated : .only(pending),
                paths: paths
            )
            if result.touched { teamsNeedsWrite = true }
            if result.toolsTouched { try store.write(tools, to: paths.toolsJSON) }

            // The watermark ALWAYS advances. Outstanding work is carried in the
            // pending set, which the gate above retries independently of the
            // version compare — so one permanently-busy team can no longer force
            // a full reconcile (and a fresh clobber of every other team's stored
            // prompts) on every single launch.
            state.lastAppliedAppVersion = currentAppVersion
            state.pendingReconcileTeamIDs = result.deferredTeamIDs
            state.updatedAt = MonotonicClock.shared.now()
            stateNeedsWrite = true
            report = result.report
        } else if state.pendingReconcileTeamIDs.count != pending.count {
            // Nothing to reconcile, but the stored set named a deleted team —
            // persist the pruned version so the gate settles.
            state.pendingReconcileTeamIDs = state.pendingReconcileTeamIDs.filter { pending.contains($0) }
            state.updatedAt = MonotonicClock.shared.now()
            stateNeedsWrite = true
        }

        if teamsNeedsWrite {
            try store.write(teamsFile, to: paths.teamsJSON)
        }
        if stateNeedsWrite {
            try store.write(state, to: paths.workFolderJSON)
        }
        if tasksIndexNeedsWrite {
            try store.write(tasksIndex, to: paths.tasksIndexJSON)
        }

        return report
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

        // Sweep orphan AtomicJSONStore temp files left over from process-kill or
        // power-loss between `Data.write(to: tempURL)` and `replaceItemAt`. Per-call
        // UUID names mean each crash leaves a unique file that the next successful
        // write can't recycle (unlike the legacy shared-name pattern). Run BEFORE
        // any writeIfMissing below so we never touch a temp this process created.
        sweepOrphanTempFiles(under: paths.internalDir)

        let stateDefault = WorkFolderState(
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

    // MARK: - Orphan temp-file sweep

    /// Recursively removes every `.*.tmp` dotfile under `internalDir`. Targets the
    /// `dir/.<filename>.<uuid>.tmp` files `AtomicJSONStore.write` creates as its
    /// rename source — those should be consumed by `replaceItemAt`/`moveItem` on
    /// every successful or failed write, but a process kill / power loss between
    /// `Data.write(to: tempURL)` and the rename leaves a permanent orphan
    /// (unlike the legacy shared-name pattern, which self-healed via the next
    /// write recycling the slot). Caller must invoke this BEFORE any new writes
    /// in the same bootstrap pass so we don't accidentally consume a temp this
    /// process just created. Single-instance app + single-folder bootstrap means
    /// no other writers race us at this point.
    func sweepOrphanTempFiles(under internalDir: URL) {
        guard let enumerator = fileManager.enumerator(
            at: internalDir,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".tmp") else { continue }
            try? fileManager.removeItem(at: url)
        }
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

    /// Strips `reportsTo[role.id]` for every role with delegation settings populated
    /// (`hasDelegationConfigured == true`). The peer-with-Supervisor rule (see
    /// `Team.roleIsTopLevelDelegator`) requires a delegating role to have NO upstream
    /// entry; legacy `teams.json` files written before this invariant existed still
    /// wire delegating roles as Supervisor subordinates, which makes `delegate_to_team`
    /// always reject.
    ///
    /// Idempotent — once normalized, subsequent calls are no-ops. Returns true
    /// iff any team's hierarchy was mutated, so the caller knows to write.
    func normalizeDelegatorPeerStatus(teams: inout [Team]) -> Bool {
        var anyChanged = false
        for teamIndex in teams.indices {
            var teamChanged = false
            for role in teams[teamIndex].roles where role.hasDelegationConfigured {
                if teams[teamIndex].settings.hierarchy.reportsTo.removeValue(forKey: role.id) != nil {
                    teamChanged = true
                }
            }
            if teamChanged {
                teams[teamIndex].updatedAt = MonotonicClock.shared.now()
                anyChanged = true
            }
        }
        return anyChanged
    }

    /// Strips delegation tools from every role's `toolIDs`. Delegation tools
    /// (`delegate_to_team`, `cancel_delegation`, `resume_delegation`,
    /// `forward_to_team`) auto-inject into the LLM schema based on the role's
    /// delegation settings — they are NEVER part of stored `toolIDs`. The
    /// legacy `"list_teams"` literal (removed tool) is also stripped — older
    /// `teams.json` files may still carry it. Legacy `teams.json` files or
    /// hand-edited / imported team configs may carry any of these; this
    /// normalizer is the single self-healing pass that keeps the invariant
    /// true on every load.
    ///
    /// Idempotent — once normalized, subsequent calls are no-ops. Returns true
    /// iff any role's `toolIDs` was mutated, so the caller knows to write.
    func normalizeDelegationToolset(teams: inout [Team]) -> Bool {
        let delegationTools = ToolHandlerRegistry.delegationToolsExcludedFromToolIDs
        var anyChanged = false
        for teamIndex in teams.indices {
            var teamChanged = false
            for roleIndex in teams[teamIndex].roles.indices {
                let before = teams[teamIndex].roles[roleIndex].toolIDs.count
                teams[teamIndex].roles[roleIndex].toolIDs.removeAll { delegationTools.contains($0) }
                if teams[teamIndex].roles[roleIndex].toolIDs.count != before {
                    teamChanged = true
                }
            }
            if teamChanged {
                teams[teamIndex].updatedAt = MonotonicClock.shared.now()
                anyChanged = true
            }
        }
        return anyChanged
    }
}
