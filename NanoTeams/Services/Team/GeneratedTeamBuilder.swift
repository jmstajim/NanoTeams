import Foundation

/// Builds a fully-configured `Team` from a `GeneratedTeamConfig` DTO produced by the LLM.
nonisolated enum GeneratedTeamBuilder {

    /// Outcome of a build: the team plus any non-fatal warnings (e.g. unknown tool
    /// names that were silently dropped — surfaced so the orchestrator can show them
    /// to the Supervisor).
    struct BuildResult {
        let team: Team
        let warnings: [String]
    }

    /// Builds a `Team` from the LLM-provided configuration. Filters out any LLM
    /// `Supervisor`-named role (added automatically) and unknown tool names; both
    /// are reported via `BuildResult.warnings`.
    /// The team ID gets a short random suffix so multiple generations with the same
    /// name don't collide.
    static func build(from config: GeneratedTeamConfig) -> BuildResult {
        let teamSeed = NTMSID.from(name: config.name)
        let uniqueSuffix = String(UUID().uuidString.prefix(8))
        var warnings: [String] = []

        // Drop file-shaped artifact names (see `stripFileShapedArtifactNames`).
        let cleanup = stripFileShapedArtifactNames(from: config)
        if !cleanup.warnings.isEmpty { warnings.append(contentsOf: cleanup.warnings) }
        // Shadow `config` so all subsequent references operate on the cleaned form.
        let config = cleanup.config

        let supervisorTemplate = SystemTemplates.roles["supervisor"]!
        var supervisorRole = SystemTemplates.createRole(from: supervisorTemplate, teamSeed: teamSeed)
        // A5 remaining-gap fix: drop supervisor requirements that no role produces.
        // Observed on gemma sessions 9–10 (`vague-short`, `multilingual-russian`,
        // `adversarial-json-bait`) — model declares an artifact in `supervisor_requires`
        // but forgets to assign it to any role's `produces_artifacts`. Left as-is the
        // Supervisor role never becomes ready and the task deadlocks silently. The
        // filtered names surface in warnings so the Supervisor can see what was
        // requested but undeliverable.
        let rolesProducing = Set(config.roles.flatMap(\.producesArtifacts))
        var filteredSupervisorRequires: [String] = []
        var unproducedSupervisorRequires: [String] = []
        for name in config.supervisorRequires {
            if rolesProducing.contains(name) || name == SystemTemplates.supervisorTaskArtifactName {
                filteredSupervisorRequires.append(name)
            } else {
                unproducedSupervisorRequires.append(name)
            }
        }
        supervisorRole.dependencies.requiredArtifacts = filteredSupervisorRequires
        if !unproducedSupervisorRequires.isEmpty {
            warnings.append(
                "Dropped \(unproducedSupervisorRequires.count) supervisor requirement(s) that no role produces: \(unproducedSupervisorRequires.joined(separator: ", "))."
            )
        }

        // Drop any LLM-emitted "Supervisor" role — we add it ourselves.
        let llmSupervisors = config.roles.filter { isSupervisorName($0.name) }
        if !llmSupervisors.isEmpty {
            warnings.append(
                "Ignored \(llmSupervisors.count) LLM-emitted Supervisor role(s) — Supervisor is added automatically."
            )
        }

        var roles: [TeamRoleDefinition] = [supervisorRole]
        for roleConfig in config.roles where !isSupervisorName(roleConfig.name) {
            let (validTools, dropped) = validateToolNames(roleConfig.tools)
            if !dropped.isEmpty {
                warnings.append(
                    "Role '\(roleConfig.name)': dropped unknown tool(s) \(dropped.joined(separator: ", "))."
                )
            }

            var role = TeamRoleDefinition(
                id: UUID().uuidString,
                name: roleConfig.name,
                prompt: roleConfig.prompt,
                toolIDs: validTools,
                usePlanningPhase: roleConfig.usePlanningPhase ?? false,
                dependencies: RoleDependencies(
                    requiredArtifacts: roleConfig.requiresArtifacts,
                    producesArtifacts: roleConfig.producesArtifacts
                )
            )
            if let icon = roleConfig.icon { role.icon = icon }
            if let bg = roleConfig.iconBackground { role.iconBackground = bg }
            roles.append(role)
        }

        var artifacts: [TeamArtifact] = []
        let supervisorTaskArtifactName = SystemTemplates.supervisorTaskArtifactName
        if let stTemplate = SystemTemplates.artifacts[supervisorTaskArtifactName] {
            artifacts.append(SystemTemplates.createArtifact(from: stTemplate, teamSeed: teamSeed))
        }
        for artifactConfig in config.artifacts {
            let artifact = TeamArtifact(
                id: TeamArtifact.slugify(artifactConfig.name),
                name: artifactConfig.name,
                icon: artifactConfig.icon ?? "doc.text",
                mimeType: "text/markdown",
                description: artifactConfig.description
            )
            artifacts.append(artifact)
        }

        // Flat hierarchy — every non-supervisor role reports to Supervisor,
        // EXCEPT roles configured for delegation (whitelist or generated). Those
        // are peer-level with Supervisor by the same rule `Team.roleIsTopLevelDelegator`
        // enforces. Generated teams typically have no delegation settings, so this
        // skip is rarely exercised here — but the predicate matches `buildSettings`
        // for symmetry.
        let nonSupervisorRoles = roles.filter { !$0.isSupervisor }
        var reportsTo: [String: String] = [:]
        for role in nonSupervisorRoles where !role.hasDelegationConfigured {
            reportsTo[role.id] = supervisorRole.id
        }
        let invitableRoles = Set(nonSupervisorRoles.map(\.id))

        // Auto mode by default: nil means the role that initiates each
        // meeting becomes its effective coordinator (see `TeamSettings`).
        // LLM-generated teams have no basis to pick a "good" designated
        // coordinator; Auto is the first-class user-facing option that
        // works without committing to a specific role.
        let settings = TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: reportsTo),
            meetingCoordinatorRoleID: nil,
            invitableRoles: invitableRoles,
            supervisorCanBeInvited: false,
            limits: .default,
            defaultAcceptanceMode: config.acceptanceMode ?? .finalOnly,
            supervisorMode: config.supervisorMode ?? .manual
        )

        let team = Team(
            id: NTMSID.from(name: "\(teamSeed)_gen_\(uniqueSuffix)"),
            name: config.name,
            description: config.description,
            roles: roles,
            artifacts: artifacts,
            settings: settings,
            graphLayout: TeamGraphLayout.autoLayout(for: roles)
        )

        return BuildResult(team: team, warnings: warnings)
    }

    /// Convenience for callers that don't care about warnings (notably tests).
    static func buildTeam(from config: GeneratedTeamConfig) -> Team {
        build(from: config).team
    }

    /// Applies user-forced generation defaults on top of a built team. Any `nil`
    /// argument means "Auto" — leave whatever value the LLM chose (or the builder
    /// fallback) intact. Used by settings-driven overrides in `Generate Team`.
    static func applyForcedDefaults(
        to result: BuildResult,
        supervisorMode: SupervisorMode?,
        acceptanceMode: AcceptanceMode?
    ) -> BuildResult {
        guard supervisorMode != nil || acceptanceMode != nil else { return result }
        var team = result.team
        if let sm = supervisorMode { team.settings.supervisorMode = sm }
        if let am = acceptanceMode { team.settings.defaultAcceptanceMode = am }
        team.updatedAt = MonotonicClock.shared.now()
        return BuildResult(team: team, warnings: result.warnings)
    }

    /// Seeds role statuses for a newly generated team into an existing run.
    /// Preserves existing entries (e.g. the Supervisor's pre-set `.done` status from
    /// `runTeamGeneration`).
    static func seedRoleStatuses(
        for team: Team,
        existingRun: inout Run,
        producedArtifacts: Set<String>
    ) {
        for role in team.roles {
            if existingRun.roleStatuses[role.id] != nil { continue }

            if role.isSupervisor {
                existingRun.roleStatuses[role.id] = .done
            } else if role.dependencies.requiredArtifacts.allSatisfy({ producedArtifacts.contains($0) }) {
                existingRun.roleStatuses[role.id] = .ready
            } else {
                existingRun.roleStatuses[role.id] = .idle
            }
        }
        existingRun.updatedAt = MonotonicClock.shared.now()
    }

    // MARK: - Private

    /// Validates tool names against the registry. Returns `(validNames, droppedNames)`.
    private static func validateToolNames(_ names: [String]) -> (valid: [String], dropped: [String]) {
        let validNames = Set(ToolHandlerRegistry.allTypes.map { $0.name })
        var valid: [String] = []
        var dropped: [String] = []
        for name in names {
            if validNames.contains(name) { valid.append(name) } else { dropped.append(name) }
        }
        return (valid, dropped)
    }

    private static func isSupervisorName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "supervisor"
    }

    // MARK: - File-shaped Artifact Cleanup

    private struct CleanupResult {
        let config: GeneratedTeamConfig
        let warnings: [String]
    }

    /// Filters file-shaped artifact names (e.g. `index.html`, `script.js`) out of
    /// every produces/requires/supervisor_requires list and the team-level
    /// `artifacts[]`. When a role's `produces_artifacts` is fully stripped, a
    /// synthetic `"\(roleName) Summary"` artifact is injected so the role still
    /// has a concrete deliverable to produce — otherwise it would silently fall
    /// through to advisory mode and loop forever in autonomous teams.
    ///
    /// Downstream `requires_artifacts` referencing stripped names are rewritten
    /// to point at the producing role's new Summary artifact (preserving the
    /// dependency edge). Names whose producer has NO Summary fallback (because
    /// the role kept other valid artifacts) are dropped from downstream lists.
    ///
    /// Per CORE_PRINCIPLES — covers the model's tendency to conflate "files to
    /// create" with "artifacts to produce" without trying to teach the model
    /// out of it (the prompt already warns against this anti-pattern; the model
    /// ignores it on briefs that mention specific filenames).
    private static func stripFileShapedArtifactNames(from config: GeneratedTeamConfig) -> CleanupResult {
        var warnings: [String] = []

        struct RoleSplit {
            var kept: [String]
            var stripped: [String]
            var fallback: String?
        }
        var splits: [RoleSplit] = []
        var rewriteMap: [String: String] = [:]   // strippedName → target (fallback, OR the role's first kept artifact)
        var droppedNames: Set<String> = []        // strippedName → drop downstream refs (only when neither fallback nor kept exists)

        for role in config.roles {
            var kept: [String] = []
            var stripped: [String] = []
            for name in role.producesArtifacts {
                if ArtifactConstants.isValidArtifactName(name) {
                    kept.append(name)
                } else {
                    stripped.append(name)
                }
            }
            let fallback: String? = (!stripped.isEmpty && kept.isEmpty)
                ? "\(role.name) Summary"
                : nil
            // Preserve dependency edges: when the role kept ≥1 valid artifact, redirect
            // every stripped name to its FIRST kept artifact instead of dropping the
            // downstream reference. Pre-fix, dropping the reference let downstream
            // roles become `.ready` immediately and advance out of dependency order
            // (the warning surfaced only as `lastInfoMessage`, easily missed).
            // The redirect target is the same producing role, so the edge still
            // forces the downstream wait — only the artifact NAME changes.
            for s in stripped {
                if let fb = fallback {
                    rewriteMap[s] = fb
                } else if let firstKept = kept.first {
                    rewriteMap[s] = firstKept
                } else {
                    // Truly orphan: role had zero valid produces (impossible reachable
                    // since `kept.isEmpty && !stripped.isEmpty` triggers the fallback
                    // branch above). Defensive only.
                    droppedNames.insert(s)
                }
            }
            splits.append(RoleSplit(kept: kept, stripped: stripped, fallback: fallback))
            if !stripped.isEmpty {
                let action: String
                if let fb = fallback {
                    action = "replaced with '\(fb)'"
                } else if let firstKept = kept.first {
                    action = "downstream references redirected to '\(firstKept)' (role's existing deliverable)"
                } else {
                    action = "dropped"
                }
                warnings.append(
                    "Role '\(role.name)': stripped \(stripped.count) file-shaped artifact name(s) [\(stripped.joined(separator: ", "))] — \(action). Use write_file for actual files; artifacts are conceptual deliverables."
                )
            }
        }

        // No file-shaped names → original config passes through unchanged.
        if rewriteMap.isEmpty && droppedNames.isEmpty {
            return CleanupResult(config: config, warnings: [])
        }

        // Rewrites a list of artifact names through `rewriteMap` / `droppedNames`,
        // de-duplicating the result. Self-loops (a role's own stripped output appearing
        // in its own requires_artifacts) are filtered out for the producing role —
        // the caller's `producingRole` parameter, when non-nil, suppresses any rewrite
        // target that points back at one of its own kept/fallback artifacts.
        func rewriteList(_ names: [String], excludingSelfFor selfArtifacts: Set<String> = []) -> [String] {
            var result: [String] = []
            var seen: Set<String> = []
            for name in names {
                let target: String?
                if let fb = rewriteMap[name] {
                    target = fb
                } else if droppedNames.contains(name) {
                    target = nil
                } else {
                    target = name
                }
                if let t = target, !seen.contains(t), !selfArtifacts.contains(t) {
                    result.append(t)
                    seen.insert(t)
                }
            }
            return result
        }

        let newRoles: [GeneratedTeamConfig.RoleConfig] = zip(config.roles, splits).map { role, split in
            var newProduces = split.kept
            if let fb = split.fallback { newProduces.append(fb) }
            // Self-loop guard: a role's own stripped output must NOT appear in its
            // own requires_artifacts after rewrite. Without this, a role whose
            // produces list and requires list both contain "calculator.html" would
            // be rewritten to require its own "Engineer Summary" — a self-edge that
            // makes the role never become `.ready`.
            let selfArtifacts = Set(newProduces)
            let originalRequiresCount = role.requiresArtifacts.count
            let newRequires = rewriteList(role.requiresArtifacts, excludingSelfFor: selfArtifacts)
            if originalRequiresCount > 0, newRequires.isEmpty {
                warnings.append(
                    "Role '\(role.name)': all requires_artifacts entries were stripped or filtered. The role will run immediately on team start — verify this is intended (advisory roles, no upstream dependencies)."
                )
            }
            return GeneratedTeamConfig.RoleConfig(
                name: role.name,
                prompt: role.prompt,
                producesArtifacts: newProduces,
                requiresArtifacts: newRequires,
                tools: role.tools,
                usePlanningPhase: role.usePlanningPhase,
                icon: role.icon,
                iconBackground: role.iconBackground
            )
        }

        var newArtifacts: [GeneratedTeamConfig.ArtifactConfig] = []
        var seenArtifactNames: Set<String> = []
        for art in config.artifacts where ArtifactConstants.isValidArtifactName(art.name) {
            if !seenArtifactNames.contains(art.name) {
                newArtifacts.append(art)
                seenArtifactNames.insert(art.name)
            }
        }
        for split in splits {
            guard let fb = split.fallback, !seenArtifactNames.contains(fb) else { continue }
            let desc = "Summary of work completed by this role (originally requested: \(split.stripped.joined(separator: ", "))). Files were written to disk via write_file; this artifact captures the role's notes/output for the Supervisor."
            newArtifacts.append(GeneratedTeamConfig.ArtifactConfig(
                name: fb,
                description: desc,
                icon: nil
            ))
            seenArtifactNames.insert(fb)
        }

        let newConfig = GeneratedTeamConfig(
            name: config.name,
            description: config.description,
            supervisorMode: config.supervisorMode,
            acceptanceMode: config.acceptanceMode,
            roles: newRoles,
            artifacts: newArtifacts,
            supervisorRequires: rewriteList(config.supervisorRequires)
        )
        return CleanupResult(config: newConfig, warnings: warnings)
    }
}
