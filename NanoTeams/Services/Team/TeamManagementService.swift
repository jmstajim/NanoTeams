import Foundation

// MARK: - Team Management Service

/// Service for managing teams within a project
nonisolated enum TeamManagementService {

    // MARK: - Team CRUD

    /// Create a new team with default FAANG configuration
    static func createTeam(
        name: String,
        settings: TeamSettings = .default
    ) -> Team {
        // Create from FAANG template by default
        var team = Team.default
        team.id = NTMSID.from(name: name)
        team.name = name
        team.templateID = nil
        team.settings = settings
        team.createdAt = MonotonicClock.shared.now()
        team.updatedAt = MonotonicClock.shared.now()
        return team
    }

    /// Duplicate an existing team with a new name
    static func duplicateTeam(
        _ team: Team,
        newName: String? = nil
    ) -> Team {
        team.duplicate(withName: newName)
    }

    /// Check if a team can be deleted. The managed singleton (Autovisor) is never
    /// deletable, and deletion must leave at least one user-deletable (non-singleton)
    /// team behind so the folder always retains a usable working team.
    static func canDeleteTeam(in workFolder: WorkFolderProjection, teamID: NTMSID) -> Bool {
        guard let team = workFolder.teams.first(where: { $0.id == teamID }),
              !team.isManagedSingleton else { return false }
        return workFolder.teams.filter { !$0.isManagedSingleton }.count > 1
    }

    // MARK: - Role Management

    /// Add a role to a team
    static func addRole(
        to team: inout Team,
        role: TeamRoleDefinition
    ) {
        team.addRole(role)
    }

    /// Remove a role from a team
    static func removeRole(
        from team: inout Team,
        roleID: String
    ) {
        team.removeRole(roleID)
    }

    /// Get role by ID
    static func role(
        in team: Team,
        roleID: String
    ) -> TeamRoleDefinition? {
        team.role(withID: roleID)
    }

    // MARK: - Artifact Management

    /// Add an artifact to a team
    static func addArtifact(
        to team: inout Team,
        artifact: TeamArtifact
    ) {
        team.addArtifact(artifact)
    }

    /// Remove an artifact from a team
    static func removeArtifact(
        from team: inout Team,
        artifactID: String
    ) {
        team.removeArtifact(artifactID)
    }

    /// Get artifact by name
    static func artifact(
        in team: Team,
        name: String
    ) -> TeamArtifact? {
        team.artifact(withName: name)
    }

    // MARK: - Validation

    /// Validate team configuration
    static func validate(_ team: Team) -> [TeamValidationError] {
        var errors: [TeamValidationError] = []

        // Must have at least one role
        if team.roles.isEmpty {
            errors.append(.noRoles)
        }

        // Name must not be empty
        if team.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptyName)
        }

        return errors
    }

    /// Check if two teams have the same name
    static func hasDuplicateName(
        _ name: String,
        in teams: [Team],
        excludingID: NTMSID? = nil
    ) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return teams.contains { team in
            guard team.id != excludingID else { return false }
            return team.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
        }
    }

    // MARK: - Graph Layout

    /// Reset graph layout to auto-computed positions based on artifact dependencies
    static func resetGraphLayout(_ team: inout Team) {
        team.graphLayout = TeamGraphLayout.autoLayout(for: team.roles)
        team.updatedAt = MonotonicClock.shared.now()
    }

    /// Update node position in the graph
    static func updateNodePosition(
        _ team: inout Team,
        roleID: String,
        x: CGFloat,
        y: CGFloat
    ) {
        team.graphLayout.setPosition(for: roleID, x: x, y: y)
        team.updatedAt = MonotonicClock.shared.now()
    }

    /// Update graph transform (pan/zoom)
    static func updateGraphTransform(
        _ team: inout Team,
        transform: TeamGraphTransform
    ) {
        team.graphLayout.transform = transform
        team.updatedAt = MonotonicClock.shared.now()
    }

    // MARK: - Dependency Sync

    /// Sync system role artifact dependencies with their templates.
    ///
    /// - producesArtifacts: synced unconditionally.
    /// - requiredArtifacts: only adds artifacts present in template but missing from stored,
    ///   AND whose producer exists in the team (prevents breaking teams with absent roles).
    /// - Skips Supervisor roles (their requiredArtifacts are set per-team, not from generic template).
    /// - Returns true if any changes were made.
    @discardableResult
    nonisolated static func syncSystemRoleDependencies(
        team: inout Team,
        templates: [String: SystemRoleTemplate],
        teamProducers: Set<String>
    ) -> Bool {
        var teamChanged = false
        for roleIndex in team.roles.indices {
            let role = team.roles[roleIndex]
            guard role.isSystemRole, !role.isSupervisor,
                  let systemRoleID = role.systemRoleID,
                  let template = templates[systemRoleID] else { continue }

            var roleChanged = false

            if Set(role.dependencies.producesArtifacts) != Set(template.dependencies.producesArtifacts) {
                team.roles[roleIndex].dependencies.producesArtifacts = template.dependencies.producesArtifacts
                roleChanged = true
            }

            let currentRequired = Set(role.dependencies.requiredArtifacts)
            let templateRequired = Set(template.dependencies.requiredArtifacts)
            let addable = templateRequired.subtracting(currentRequired).filter { teamProducers.contains($0) }
            if !addable.isEmpty {
                team.roles[roleIndex].dependencies.requiredArtifacts.append(contentsOf: addable.sorted())
                roleChanged = true
            }

            if roleChanged {
                team.roles[roleIndex].updatedAt = MonotonicClock.shared.now()
                teamChanged = true
            }
        }

        if teamChanged {
            team.updatedAt = MonotonicClock.shared.now()
        }
        return teamChanged
    }

    /// Keeps the hidden Autovisor team in sync with template invariants the user
    /// never customizes — the "Manager" role icon, the **mandatory** management tools,
    /// and the Auto (nil) meeting coordinator. Icon + coordinator are overwritten; the
    /// mandatory tools are **union-enforced** (additive) so they can never be lost, while
    /// the user's optional-tool choices (toggled in the role editor) are preserved.
    /// Pure + idempotent: returns true only when something actually changed, so a
    /// caller running it inside `mutateWorkFolder` persists nothing on a no-op.
    @discardableResult
    nonisolated static func syncAutovisorTeamToTemplate(teams: inout [Team]) -> Bool {
        guard let teamIndex = teams.firstIndex(where: { $0.templateID == AutovisorConstants.teamTemplateID })
        else { return false }

        var changed = false

        // Manager role icon → template, and mandatory tools union-enforced (additive —
        // does NOT remove user-toggled optional tools). The icon is template-owned (its
        // General tab is hidden in the editor); the management tools define the manager.
        if let template = SystemTemplates.roles[AutovisorConstants.managerRoleSystemID],
           let roleIndex = teams[teamIndex].roles.firstIndex(where: {
               $0.systemRoleID == AutovisorConstants.managerRoleSystemID
           }) {
            if teams[teamIndex].roles[roleIndex].icon != template.icon {
                teams[teamIndex].roles[roleIndex].icon = template.icon
                teams[teamIndex].roles[roleIndex].updatedAt = MonotonicClock.shared.now()
                changed = true
            }
            let missingMandatory = AutovisorConstants.managerMandatoryToolIDs.filter {
                !teams[teamIndex].roles[roleIndex].toolIDs.contains($0)
            }
            if !missingMandatory.isEmpty {
                teams[teamIndex].roles[roleIndex].toolIDs.append(contentsOf: missingMandatory)
                teams[teamIndex].roles[roleIndex].updatedAt = MonotonicClock.shared.now()
                changed = true
            }
        }

        // Meeting coordinator → Auto (nil). The lone Manager role is the only
        // possible coordinator anyway; Auto reads correctly in the settings UI.
        if teams[teamIndex].settings.meetingCoordinatorRoleID != nil {
            teams[teamIndex].settings.meetingCoordinatorRoleID = nil
            changed = true
        }

        if changed {
            teams[teamIndex].updatedAt = MonotonicClock.shared.now()
        }
        return changed
    }
}

// MARK: - Validation Errors

nonisolated enum TeamValidationError: Error, Equatable {
    case noRoles
    case emptyName
    case duplicateName

    var localizedDescription: String {
        switch self {
        case .noRoles:
            return "Team must have at least one role"
        case .emptyName:
            return "Team name cannot be empty"
        case .duplicateName:
            return "A team with this name already exists"
        }
    }
}
