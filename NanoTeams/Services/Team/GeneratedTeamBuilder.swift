import Foundation

/// Builds a fully-configured `Team` from a `GeneratedTeamConfig` DTO produced by the LLM.
enum GeneratedTeamBuilder {

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

        let supervisorTemplate = SystemTemplates.roles["supervisor"]!
        var supervisorRole = SystemTemplates.createRole(from: supervisorTemplate, teamSeed: teamSeed)
        supervisorRole.dependencies.requiredArtifacts = config.supervisorRequires

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

        // Flat hierarchy — every non-supervisor role reports to Supervisor.
        let nonSupervisorRoles = roles.filter { !$0.isSupervisor }
        var reportsTo: [String: String] = [:]
        for role in nonSupervisorRoles {
            reportsTo[role.id] = supervisorRole.id
        }
        let invitableRoles = Set(nonSupervisorRoles.map(\.id))

        // Coordinator = first non-supervisor role (or supervisor if none).
        let coordinatorID = nonSupervisorRoles.first?.id ?? supervisorRole.id

        let settings = TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: reportsTo),
            meetingCoordinatorRoleID: coordinatorID,
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
}
