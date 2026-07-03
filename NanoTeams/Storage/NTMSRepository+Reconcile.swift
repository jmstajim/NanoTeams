import Foundation

// MARK: - Bundled Content Reconcile
//
// Version-bump-triggered pass that brings a work folder's stored teams / roles /
// prompt templates / settings / tools back in line with the bundled definitions
// shipped in the current app binary. Called from `migrateIfNeeded` whenever
// `AppVersion.current > state.lastAppliedAppVersion`.
//
// Design invariants:
//  * Scalar fields of system roles (`prompt`, `toolIDs`, `dependencies`,
//    `icon`, `iconColor`, `iconBackground`) are overwritten unconditionally.
//    User customizations to system-role fields are a known trade-off, documented
//    in the plan — inline apply without preview.
//  * Structural changes are **additive only**: missing system roles and missing
//    system artifacts are added; existing entries (including roles no longer
//    present in the bundled template) are never removed.
//  * Tombstones (`team.deletedSystemRoleIDs` / `team.deletedSystemArtifactIDs`)
//    suppress additive resurrection of roles/artifacts the user explicitly
//    removed via the editor.
//  * Teams whose roles are actively executing (any `roleStatus` in
//    `.working`/`.needsAcceptance`/`.revisionRequested`) are deferred so
//    mid-run changes to `role.toolIDs` can't break tool-call authorization.
//    The watermark (`state.lastAppliedAppVersion`) is NOT advanced when any
//    team is deferred — next open retries.

nonisolated extension NTMSRepository {

    struct BundledReconcileResult {
        /// True if any team was mutated (roles/templates/settings/structure).
        /// Caller writes `teams.json` iff this is `true`.
        var touched: Bool
        /// True if the bundled tool merge produced a change.
        /// Caller writes `tools.json` iff this is `true`.
        var toolsTouched: Bool
        /// Team IDs whose reconcile was deferred because at least one of their
        /// roles is currently executing. If non-empty, the caller MUST NOT
        /// advance `state.lastAppliedAppVersion` — deferred teams retry next open.
        var deferred: [NTMSID]
    }

    /// Apply all bundled-content updates to teams and tools.
    ///
    /// - Parameters:
    ///   - teams: inout — scalar fields, prompt templates, settings, and
    ///     additive structure are updated in place.
    ///   - tools: inout — merged with `ToolDefinitionRecord.defaultDefinitions()`.
    ///   - paths: used for the running-role scan (`internalTasksDir`).
    func applyBundledContentUpdates(
        teams: inout [Team],
        tools: inout [ToolDefinitionRecord],
        paths: NTMSPaths
    ) -> BundledReconcileResult {
        var touched = false
        var deferred: [NTMSID] = []

        // Fail-closed: if the running-role scan can't complete (corrupt
        // tasks_index.json / task.json), defer every templated team. Changing
        // `role.toolIDs` on a running role silently breaks tool authorization.
        let scan = scanRunningTeamRoles(paths: paths)
        switch scan {
        case .inconclusive:
            for i in teams.indices {
                guard let tid = teams[i].templateID, tid != "generated" else { continue }
                deferred.append(teams[i].id)
            }
            return BundledReconcileResult(touched: false, toolsTouched: false, deferred: deferred)
        case .clean:
            break
        }
        let runningByTeam: Set<NTMSID>
        if case .clean(let set) = scan { runningByTeam = set } else { runningByTeam = [] }

        // Index bundled defaults by templateID once.
        var bundledByTemplateID: [String: Team] = [:]
        for t in Team.defaultTeams {
            if let tid = t.templateID { bundledByTemplateID[tid] = t }
        }
        // The Autovisor team is bundled but hidden (not in `Team.defaultTeams`) —
        // index it explicitly so its manager role's prompt reconciles on version
        // bumps like every other system role. Without this, prompt improvements
        // never reach work folders whose Autovisor team was seeded by an older build.
        bundledByTemplateID[AutovisorConstants.teamTemplateID] = TeamTemplateFactory.autovisor()

        for i in teams.indices {
            guard let tid = teams[i].templateID, tid != "generated" else { continue }

            if runningByTeam.contains(teams[i].id) {
                // The Autovisor manager parks at `.needsSupervisorInput` at the
                // end of every review pass while its role status stays `.working`,
                // so an enabled Autovisor would defer reconcile — and hold the
                // watermark — on EVERY open, and bundled updates would never land.
                // Deferral exists to protect `role.toolIDs` under a live tool
                // loop, and the autovisor branch below never rewrites toolIDs, so
                // reconciling this team is safe: the refreshed prompt/template
                // are only read at the next pass start.
                if tid != AutovisorConstants.teamTemplateID {
                    deferred.append(teams[i].id)
                    continue
                }
            }

            var teamChanged = false

            // 1. System roles — scalar field overwrite.
            //
            // Uses per-team bundled values (`Team.defaultTeams`), not the
            // generic `SystemTemplates.roles`: FAANG's Supervisor requires
            // "Release Notes" while the generic template is empty, and
            // Engineering's TechLead must not pick up PM-dependent artifacts
            // since PM isn't in the team.
            let bundledRolesBySystemID: [String: TeamRoleDefinition]? = bundledByTemplateID[tid]
                .map { Dictionary(uniqueKeysWithValues: $0.roles.compactMap { r in
                    r.systemRoleID.map { ($0, r) }
                }) }
            for r in teams[i].roles.indices where teams[i].roles[r].isSystemRole {
                guard let systemID = teams[i].roles[r].systemRoleID,
                      let bundled = bundledRolesBySystemID?[systemID]
                else { continue }

                let role = teams[i].roles[r]
                let nextPrompt = bundled.prompt
                // The Autovisor manager's tool policy is owned by
                // `syncAutovisorTeamToTemplate` (runs on every open): it union-enforces the
                // mandatory tools, preserves the user's choices among the allowed-optional
                // tools, and strips any tool outside the allowed set (mandatory ∪ optional).
                // The reconcile therefore does NOT overwrite the manager's toolIDs — but it
                // IS the delivery path for optional-tool GROUPS newly bundled in this app
                // version (e.g. computer-use): a group entirely absent from the stored
                // toolset predates its introduction and is added whole; a partially-present
                // group means the user has seen it and pruned — their per-tool toggles are
                // preserved (pinned by `testVersionBump_..._preservingToolToggles`).
                let nextToolIDs: [String]
                if tid == AutovisorConstants.teamTemplateID {
                    let stored = Set(role.toolIDs)
                    let bundledSet = Set(bundled.toolIDs)
                    var toolIDs = role.toolIDs
                    for group in AutovisorConstants.managerOptionalToolGroups
                        where stored.isDisjoint(with: group) {
                        toolIDs.append(contentsOf: group.filter { bundledSet.contains($0) })
                    }
                    nextToolIDs = toolIDs
                } else {
                    nextToolIDs = bundled.toolIDs
                }
                let nextDeps = bundled.dependencies
                let nextIcon = bundled.icon
                let nextIconColor = bundled.iconColor
                let nextIconBG = bundled.iconBackground

                let changed = role.prompt != nextPrompt
                    || role.toolIDs != nextToolIDs
                    || role.dependencies != nextDeps
                    || role.icon != nextIcon
                    || role.iconColor != nextIconColor
                    || role.iconBackground != nextIconBG

                if changed {
                    teams[i].roles[r].prompt = nextPrompt
                    teams[i].roles[r].toolIDs = nextToolIDs
                    teams[i].roles[r].dependencies = nextDeps
                    teams[i].roles[r].icon = nextIcon
                    teams[i].roles[r].iconColor = nextIconColor
                    teams[i].roles[r].iconBackground = nextIconBG
                    teams[i].roles[r].updatedAt = MonotonicClock.shared.now()
                    teamChanged = true
                }
            }

            // 2. Prompt templates (system/consultation/meeting).
            if let cfg = SystemTemplates.templateConfigs[tid] {
                if teams[i].systemPromptTemplate != cfg.system {
                    teams[i].systemPromptTemplate = cfg.system
                    teamChanged = true
                }
                if teams[i].consultationPromptTemplate != cfg.consultation {
                    teams[i].consultationPromptTemplate = cfg.consultation
                    teamChanged = true
                }
                if teams[i].meetingPromptTemplate != cfg.meeting {
                    teams[i].meetingPromptTemplate = cfg.meeting
                    teamChanged = true
                }
            }

            // 3. Team settings defaults.
            if let bundledTeam = bundledByTemplateID[tid] {
                let bundledSettings = bundledTeam.settings
                if teams[i].settings != bundledSettings {
                    teams[i].settings = bundledSettings
                    teamChanged = true
                }
            }

            // 4. Team structure — additive: add missing system roles/artifacts,
            //    never remove stored entries the user may be using. Respects
            //    tombstones.
            if let bundledTeam = bundledByTemplateID[tid] {
                let storedSystemRoleIDs = Set(teams[i].roles.compactMap(\.systemRoleID))
                let tombstonedRoles = Set(teams[i].deletedSystemRoleIDs)

                for bundledRole in bundledTeam.roles where bundledRole.isSystemRole {
                    guard let sid = bundledRole.systemRoleID else { continue }
                    if storedSystemRoleIDs.contains(sid) { continue }
                    if tombstonedRoles.contains(sid) { continue }
                    teams[i].roles.append(bundledRole)
                    if let supervisorID = bundledTeam.settings.hierarchy.reportsTo[bundledRole.id] {
                        teams[i].settings.hierarchy.reportsTo[bundledRole.id] = supervisorID
                    }
                    teamChanged = true
                }

                let storedArtifactIDs = Set(teams[i].artifacts.map(\.id))
                let tombstonedArtifacts = Set(teams[i].deletedSystemArtifactIDs)
                for bundledArt in bundledTeam.artifacts where bundledArt.isSystemArtifact {
                    if storedArtifactIDs.contains(bundledArt.id) { continue }
                    if tombstonedArtifacts.contains(bundledArt.id) { continue }
                    teams[i].artifacts.append(bundledArt)
                    teamChanged = true
                }

                // Prune orphan system artifacts — see helper for safety
                // contract. Without this, a bundled rename ("Code Review" →
                // "Code Review Summary") leaves the legacy artifact in the
                // team editor's list as a selectable but unproduced ghost.
                if Self.pruneOrphanSystemArtifacts(in: &teams[i], bundled: bundledTeam) {
                    teamChanged = true
                }

                // Refresh layout — keeps user-dragged positions for existing
                // nodes, auto-positions any newly-added role.
                let nextLayout = TeamGraphLayoutCalculator.mergeLayout(
                    existing: teams[i].graphLayout,
                    roles: teams[i].roles
                )
                if nextLayout != teams[i].graphLayout {
                    teams[i].graphLayout = nextLayout
                    teamChanged = true
                }
            }

            if teamChanged {
                teams[i].updatedAt = MonotonicClock.shared.now()
                touched = true
            }
        }

        // 5. Tools — unified version-bump merge, replaces the old launch-level
        //    call in `loadToolDefinitions`.
        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: tools)
        var toolsTouched = false
        if merged != tools {
            tools = merged
            toolsTouched = true
        }

        return BundledReconcileResult(
            touched: touched,
            toolsTouched: toolsTouched,
            deferred: deferred
        )
    }

    // MARK: - Orphan system artifact prune

    /// Removes system artifacts (`isSystemArtifact == true`) whose name is no
    /// longer in the bundled team AND that no role / setting references.
    /// Custom (`isSystemArtifact == false`) artifacts and any artifact still
    /// referenced by a role's dependencies or by `supervisorRequiredArtifacts`
    /// are preserved. Returns `true` iff at least one artifact was removed.
    ///
    /// Safety: this runs AFTER the role-dependency reconcile (step 1) inside
    /// `applyBundledContentUpdates`, so the reference scan reflects
    /// post-reconcile dependencies — orphans here are truly dead. Custom roles
    /// the user added that still depend on the legacy name are protected via
    /// the reference scan.
    static func pruneOrphanSystemArtifacts(in team: inout Team, bundled: Team) -> Bool {
        let bundledArtifactNames = Set(bundled.artifacts.map(\.name))
        // `supervisorRequiredArtifacts` is a computed property on `Team`
        // (derived from the Supervisor role's `requiredArtifacts`). The role
        // loop below already covers it via `dependencies.requiredArtifacts`,
        // but reading it explicitly here documents the intent.
        var referencedNames = Set(team.supervisorRequiredArtifacts)
        for r in team.roles {
            referencedNames.formUnion(r.dependencies.requiredArtifacts)
            referencedNames.formUnion(r.dependencies.producesArtifacts)
        }
        let prePruneCount = team.artifacts.count
        team.artifacts.removeAll { art in
            art.isSystemArtifact
                && !bundledArtifactNames.contains(art.name)
                && !referencedNames.contains(art.name)
        }
        return team.artifacts.count != prePruneCount
    }

    // MARK: - Running-role scan

    enum RunningTeamsScanResult {
        /// Scan completed cleanly. Empty set means "no active roles anywhere".
        case clean(Set<NTMSID>)
        /// Scan could not complete (index or task file corrupt). Caller must
        /// fail-closed and defer every templated team — reconcile must not
        /// overwrite `role.toolIDs` while we cannot prove the role is idle.
        case inconclusive
    }

    /// Identifies team IDs that have at least one role currently executing. A
    /// role is "executing" if any task's most recent run has its
    /// `roleStatuses[roleID]` in `.working`, `.needsAcceptance`, or
    /// `.revisionRequested`.
    ///
    /// Missing `tasks_index.json` is treated as "no tasks yet" (clean). A file
    /// that exists but fails to decode returns `.inconclusive`.
    func scanRunningTeamRoles(paths: NTMSPaths) -> RunningTeamsScanResult {
        guard fileManager.fileExists(atPath: paths.tasksIndexJSON.path) else {
            return .clean([])
        }
        let index: TasksIndex
        do {
            index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        } catch {
            print("[NTMSRepository] WARNING: tasks_index.json unreadable during "
                + "reconcile scan — deferring all team updates (\(error))")
            return .inconclusive
        }

        var running: Set<NTMSID> = []
        for entry in index.tasks {
            let ancestors = index.ancestorIDs(of: entry.id)
            let taskURL = paths.taskJSON(taskID: entry.id, ancestors: ancestors)
            guard fileManager.fileExists(atPath: taskURL.path) else { continue }
            let task: NTMSTask
            do {
                task = try store.read(NTMSTask.self, from: taskURL)
            } catch {
                print("[NTMSRepository] WARNING: task.json for task \(entry.id) "
                    + "unreadable during reconcile scan — deferring all team updates (\(error))")
                return .inconclusive
            }
            guard let run = task.runs.last else { continue }

            let hasActiveRole = run.roleStatuses.values.contains { status in
                switch status {
                case .working, .needsAcceptance, .revisionRequested: return true
                default: return false
                }
            }
            guard hasActiveRole else { continue }

            if let generated = task.generatedTeam {
                running.insert(generated.id)
            } else if let preferred = task.preferredTeamID {
                running.insert(preferred)
            }
        }

        return .clean(running)
    }
}
