import Foundation

// MARK: - Team Validation Service

/// Validates team configuration for artifact uniqueness and dependency chains.
nonisolated enum TeamValidationService {

    // MARK: - Validation Errors

    /// Errors found during team validation
    enum ValidationError: Equatable, Hashable {
        /// Multiple roles produce the same artifact type
        case duplicateProducer(artifact: String, roleIDs: [String])

        /// A role requires an artifact that no other role produces
        case missingProducer(artifact: String, requiredBy: String)

        /// Circular dependency detected in artifact chain
        case circularDependency(roleIDs: [String])

        /// An artifact is produced but never consumed
        case orphanArtifact(artifact: String, producedBy: String)

        /// A role is configured for delegation (`hasDelegationConfigured == true`)
        /// but is not peer-level with the team's Supervisor — i.e. has an
        /// upstream `reportsTo` entry. Only peer-level roles (autonomous, no
        /// upstream) may delegate.
        case nonTopLevelDelegator(roleID: String)

        /// A role's `allowedDelegationTeamIDs` includes a team that no longer
        /// exists in the project (e.g. it was deleted after configuration).
        case unknownDelegationTeam(roleID: String, teamID: NTMSID)

        /// A role's `allowedDelegationTeamIDs` includes the team it belongs to —
        /// trivially circular delegation. Reject at config time.
        case delegationToSelf(roleID: String, teamID: NTMSID)

        /// A role is configured for delegation (`hasDelegationConfigured == true`)
        /// but every whitelist entry references a team that no longer exists
        /// AND generated permission is off. `delegate_to_team`'s embedded
        /// catalog will be empty — the role can never delegate. Narrow under
        /// the new settings-driven model: a fully-empty config can't reach
        /// this rule because `hasDelegationConfigured` would be false.
        case noDelegationTargets(roleID: String)

        var isError: Bool {
            switch self {
            case .duplicateProducer, .missingProducer, .circularDependency,
                 .nonTopLevelDelegator, .delegationToSelf:
                return true
            case .orphanArtifact, .unknownDelegationTeam, .noDelegationTargets:
                return false  // Warning, not error
            }
        }

        /// Human-readable, role-name-resolved message for surfacing in the
        /// team-editor validation banner. `team` resolves role IDs to display
        /// names; an ID with no matching role (e.g. a deleted role still
        /// referenced) falls back to the raw ID rather than rendering blank.
        func displayMessage(in team: Team) -> String {
            func roleName(_ id: String) -> String {
                team.roles.first { $0.id == id }?.name ?? id
            }
            switch self {
            case .duplicateProducer(let artifact, let roleIDs):
                let names = roleIDs.map(roleName).joined(separator: ", ")
                return "Multiple roles produce “\(artifact)”: \(names)."
            case .missingProducer(let artifact, let requiredBy):
                return "\(roleName(requiredBy)) requires “\(artifact)”, but no role produces it."
            case .circularDependency(let roleIDs):
                let chain = roleIDs.map(roleName).joined(separator: " → ")
                return "Circular dependency between roles: \(chain)."
            case .orphanArtifact(let artifact, let producedBy):
                return "“\(artifact)” is produced by \(roleName(producedBy)) but never used by another role."
            case .nonTopLevelDelegator(let roleID):
                return "\(roleName(roleID)) is set to delegate but reports to another role. Only roles that are peer-level with the Supervisor can delegate — remove its “reports to” link."
            case .unknownDelegationTeam(let roleID, let teamID):
                return "\(roleName(roleID)) is set to delegate to a team that no longer exists (\(teamID))."
            case .delegationToSelf(let roleID, _):
                return "\(roleName(roleID)) is set to delegate to its own team, which isn’t allowed."
            case .noDelegationTargets(let roleID):
                return "\(roleName(roleID)) is set to delegate but has no valid target team. Pick an existing team or allow generating new teams."
            }
        }
    }

    // MARK: - Validation Result

    struct ValidationResult {
        let errors: [ValidationError]
        let warnings: [ValidationError]

        var isValid: Bool { errors.isEmpty }
    }

    // MARK: - Validate Team Configuration

    /// Validates the complete team configuration.
    /// - Parameters:
    ///   - roleDefinitions: All role definitions in the project
    /// - Returns: Validation result with errors and warnings
    static func validate(
        roleDefinitions: [TeamRoleDefinition]
    ) -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [ValidationError] = []

        // 1. Check artifact uniqueness
        let uniquenessIssues = validateArtifactUniqueness(roleDefinitions: roleDefinitions)
        errors.append(contentsOf: uniquenessIssues)

        // 2. Check dependency chain
        let chainIssues = validateDependencyChain(roleDefinitions: roleDefinitions)
        errors.append(contentsOf: chainIssues)

        // 3. Check for circular dependencies
        let circularIssues = validateNoCircularDependencies(roleDefinitions: roleDefinitions)
        errors.append(contentsOf: circularIssues)

        // 4. Find orphan artifacts (warning only)
        let orphanIssues = findOrphanArtifacts(roleDefinitions: roleDefinitions)
        warnings.append(contentsOf: orphanIssues)

        return ValidationResult(errors: errors, warnings: warnings)
    }

    /// Validates the team configuration including delegation policy.
    /// Used by the orchestrator's team-save flow to catch role-level delegation
    /// misconfiguration in addition to artifact dependency issues.
    /// - Parameters:
    ///   - team: The team being validated.
    ///   - allTeams: All teams in the project, used to verify whitelist references resolve.
    static func validate(team: Team, allTeams: [Team]) -> ValidationResult {
        let result = validate(roleDefinitions: team.roles)
        var errors = result.errors
        var warnings = result.warnings

        let delegationIssues = validateDelegationPolicy(team: team, allTeams: allTeams)
        for issue in delegationIssues {
            if issue.isError { errors.append(issue) } else { warnings.append(issue) }
        }
        return ValidationResult(errors: errors, warnings: warnings)
    }

    // MARK: - Delegation Policy

    /// Validates per-role delegation configuration:
    /// - Roles configured for delegation (`hasDelegationConfigured == true`, i.e. any
    ///   whitelist entry OR generated permission) must be peer-level with
    ///   Supervisor (no upstream `reportsTo` entry). The role-editor save handler
    ///   normally clears `reportsTo` when delegation is enabled — this rule
    ///   catches stale state from imported teams or hand-edited JSON.
    /// - `allowedDelegationTeamIDs` must reference existing teams.
    /// - A role cannot delegate to its own team (trivially circular).
    /// - `noDelegationTargets`: fires when no whitelist entry resolves to a
    ///   *delegatable* team (different from self, exists, and not chat-mode —
    ///   chat-mode teams are filtered from the runtime catalog so a whitelist of
    ///   only chat-mode teams leaves the role with no effective target) AND
    ///   generated permission is off. Catches both stale/unknown ids and targets
    ///   that were converted to chat-mode after being whitelisted.
    static func validateDelegationPolicy(team: Team, allTeams: [Team]) -> [ValidationError] {
        var issues: [ValidationError] = []
        let teamsByID = Dictionary(allTeams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for role in team.roles where role.hasDelegationConfigured {
            // Eligibility: only peer-level (autonomous) roles may delegate.
            if !team.roleIsTopLevelDelegator(role) {
                issues.append(.nonTopLevelDelegator(roleID: role.id))
            }

            // Self-delegation guard.
            if role.allowedDelegationTeamIDs.contains(team.id) {
                issues.append(.delegationToSelf(roleID: role.id, teamID: team.id))
            }

            // Whitelist references must resolve to known project teams. Dedup so a
            // repeated id (imported / hand-edited JSON) emits the warning once.
            var seenWhitelist = Set<NTMSID>()
            for whitelistedID in role.allowedDelegationTeamIDs where whitelistedID != team.id {
                guard seenWhitelist.insert(whitelistedID).inserted else { continue }
                if teamsByID[whitelistedID] == nil {
                    issues.append(.unknownDelegationTeam(roleID: role.id, teamID: whitelistedID))
                }
            }

            // Must have at least one *delegatable* target (a different, existing,
            // non-chat-mode team) or generated permission.
            let hasValidTarget = role.allowedDelegationTeamIDs.contains { id in
                id != team.id && (teamsByID[id]?.isValidDelegationTarget ?? false)
            }
            if !hasValidTarget && !role.allowDelegationToGeneratedTeams {
                issues.append(.noDelegationTargets(roleID: role.id))
            }
        }
        return issues
    }

    // MARK: - Artifact Uniqueness

    /// Validates that each artifact type is produced by at most one role.
    static func validateArtifactUniqueness(roleDefinitions: [TeamRoleDefinition]) -> [ValidationError] {
        var producersByArtifact: [String: [String]] = [:]

        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies

            for artifact in deps.producesArtifacts {
                producersByArtifact[artifact, default: []].append(roleDef.id)
            }
        }

        var errors: [ValidationError] = []
        for (artifact, producers) in producersByArtifact {
            if producers.count > 1 {
                errors.append(.duplicateProducer(artifact: artifact, roleIDs: producers))
            }
        }

        return errors
    }

    // MARK: - Dependency Chain

    /// Validates that every required artifact has a producer.
    static func validateDependencyChain(roleDefinitions: [TeamRoleDefinition]) -> [ValidationError] {
        // Collect all produced artifacts
        var producedArtifacts = Set<String>()
        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies
            producedArtifacts.formUnion(deps.producesArtifacts)
        }

        // Check each role's requirements
        var errors: [ValidationError] = []
        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies

            for required in deps.requiredArtifacts {
                if !producedArtifacts.contains(required) {
                    errors.append(.missingProducer(artifact: required, requiredBy: roleDef.id))
                }
            }
        }

        return errors
    }

    // MARK: - Circular Dependencies

    /// Validates that there are no circular dependencies in the artifact chain.
    static func validateNoCircularDependencies(roleDefinitions: [TeamRoleDefinition]) -> [ValidationError] {
        // Build dependency graph: roleID → [roleIDs it depends on]
        var dependsOn: [String: Set<String>] = [:]
        var producerOf: [String: String] = [:]

        // First pass: map artifacts to producers
        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies
            for artifact in deps.producesArtifacts {
                producerOf[artifact] = roleDef.id
            }
        }

        // Second pass: build dependency edges
        for roleDef in roleDefinitions {
            // Supervisor required artifacts are review requirements, not execution edges.
            if roleDef.isSupervisor {
                dependsOn[roleDef.id] = []
                continue
            }

            let deps = roleDef.dependencies
            var dependencies = Set<String>()

            for required in deps.requiredArtifacts {
                if let producer = producerOf[required] {
                    dependencies.insert(producer)
                }
            }

            dependsOn[roleDef.id] = dependencies
        }

        // Detect cycles using DFS
        var visited = Set<String>()
        var inStack = Set<String>()
        var errors: [ValidationError] = []

        func dfs(_ nodeID: String, path: [String]) -> [String]? {
            if inStack.contains(nodeID) {
                // Found cycle - return path from cycle start
                if let cycleStart = path.firstIndex(of: nodeID) {
                    return Array(path[cycleStart...]) + [nodeID]
                }
                return path + [nodeID]
            }

            if visited.contains(nodeID) {
                return nil
            }

            visited.insert(nodeID)
            inStack.insert(nodeID)

            for dep in dependsOn[nodeID] ?? [] {
                if let cycle = dfs(dep, path: path + [nodeID]) {
                    return cycle
                }
            }

            inStack.remove(nodeID)
            return nil
        }

        for roleDef in roleDefinitions {
            if !visited.contains(roleDef.id) {
                if let cycle = dfs(roleDef.id, path: []) {
                    errors.append(.circularDependency(roleIDs: cycle))
                    break  // Report only first cycle
                }
            }
        }

        return errors
    }

    // MARK: - Orphan Artifacts

    /// Finds artifacts that are produced but never consumed.
    static func findOrphanArtifacts(roleDefinitions: [TeamRoleDefinition]) -> [ValidationError] {
        var producedBy: [String: String] = [:]
        var requiredArtifacts = Set<String>()

        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies

            for artifact in deps.producesArtifacts {
                producedBy[artifact] = roleDef.id
            }

            requiredArtifacts.formUnion(deps.requiredArtifacts)
        }

        var warnings: [ValidationError] = []
        for (artifact, producer) in producedBy {
            if !requiredArtifacts.contains(artifact) {
                warnings.append(.orphanArtifact(artifact: artifact, producedBy: producer))
            }
        }

        return warnings
    }
}
