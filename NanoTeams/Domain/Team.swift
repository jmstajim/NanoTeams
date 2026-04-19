//
//  Team.swift
//  NanoTeams
//
//  Represents a team configuration with roles, artifacts, settings, and graph layout.
//

import Foundation

// MARK: - Team

/// Represents a team configuration with per-team roles, artifacts, settings, and graph layout
struct Team: Codable, Identifiable {
    var id: NTMSID
    var createdAt: Date
    var updatedAt: Date

    /// Name of the team
    var name: String

    /// Description of the team's purpose and workflow
    var description: String

    /// Template ID this team was created from (e.g., "faang", "questParty"). Nil for custom teams.
    var templateID: String?

    /// Template for the main system prompt sent to roles during step execution.
    /// Uses `{placeholder}` syntax resolved by PromptBuilder.
    var systemPromptTemplate: String

    /// Template for the system prompt sent to teammates during consultations.
    var consultationPromptTemplate: String

    /// Template for the system prompt sent to meeting participants.
    var meetingPromptTemplate: String

    /// Team-specific role definitions
    var roles: [TeamRoleDefinition]

    /// Team-specific artifacts
    var artifacts: [TeamArtifact]

    /// Settings for this team
    var settings: TeamSettings

    /// Visual layout of the team graph
    var graphLayout: TeamGraphLayout

    /// System role IDs (`TeamRoleDefinition.systemRoleID`) that the user has
    /// explicitly deleted from this team. Prevents version-bump reconcile from
    /// resurrecting them. Cleared by "Restore Default Teams".
    var deletedSystemRoleIDs: [String]

    /// System artifact IDs (`TeamArtifact.id`) that the user has explicitly deleted
    /// from this team. Prevents version-bump reconcile from resurrecting them.
    /// Cleared by "Restore Default Teams".
    var deletedSystemArtifactIDs: [String]

    // MARK: - Initialization

    init(
        id: NTMSID? = nil,
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now(),
        name: String,
        description: String = "",
        templateID: String? = nil,
        systemPromptTemplate: String = SystemTemplates.genericTemplate,
        consultationPromptTemplate: String = SystemTemplates.genericConsultationTemplate,
        meetingPromptTemplate: String = SystemTemplates.genericMeetingTemplate,
        roles: [TeamRoleDefinition],
        artifacts: [TeamArtifact],
        settings: TeamSettings,
        graphLayout: TeamGraphLayout,
        deletedSystemRoleIDs: [String] = [],
        deletedSystemArtifactIDs: [String] = []
    ) {
        self.id = id ?? NTMSID.from(name: name)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.name = name
        self.description = description
        self.templateID = templateID
        self.systemPromptTemplate = systemPromptTemplate
        self.consultationPromptTemplate = consultationPromptTemplate
        self.meetingPromptTemplate = meetingPromptTemplate
        self.roles = roles
        self.artifacts = artifacts
        self.settings = settings
        self.graphLayout = graphLayout
        self.deletedSystemRoleIDs = deletedSystemRoleIDs
        self.deletedSystemArtifactIDs = deletedSystemArtifactIDs
    }

    /// Convenience initializer for tests: creates minimal team with empty roles/artifacts and default settings
    init(name: String) {
        self.init(
            name: name,
            roles: [],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case name
        case description
        case templateID
        case systemPromptTemplate
        case consultationPromptTemplate
        case meetingPromptTemplate
        case roles
        case artifacts
        case settings
        case graphLayout
        case deletedSystemRoleIDs
        case deletedSystemArtifactIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(NTMSID.self, forKey: .id)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.templateID = try c.decodeIfPresent(String.self, forKey: .templateID)
        self.systemPromptTemplate = try c.decodeIfPresent(String.self, forKey: .systemPromptTemplate)
            ?? SystemTemplates.genericTemplate
        self.consultationPromptTemplate = try c.decodeIfPresent(String.self, forKey: .consultationPromptTemplate)
            ?? SystemTemplates.genericConsultationTemplate
        self.meetingPromptTemplate = try c.decodeIfPresent(String.self, forKey: .meetingPromptTemplate)
            ?? SystemTemplates.genericMeetingTemplate
        self.roles = try c.decode([TeamRoleDefinition].self, forKey: .roles)
        self.artifacts = try c.decode([TeamArtifact].self, forKey: .artifacts)
        self.settings = try c.decodeIfPresent(TeamSettings.self, forKey: .settings) ?? .default
        self.graphLayout = try c.decodeIfPresent(TeamGraphLayout.self, forKey: .graphLayout) ?? .default
        self.deletedSystemRoleIDs = try c.decodeIfPresent([String].self, forKey: .deletedSystemRoleIDs) ?? []
        self.deletedSystemArtifactIDs = try c.decodeIfPresent([String].self, forKey: .deletedSystemArtifactIDs) ?? []
    }

    // MARK: - Computed Properties

    /// Number of roles in the team
    var memberCount: Int {
        roles.count
    }

    /// Check if a role exists in this team by ID
    func hasRole(_ roleID: String) -> Bool {
        roles.contains(where: { $0.id == roleID })
    }

    /// Find a role by ID
    func role(withID roleID: String) -> TeamRoleDefinition? {
        roles.first(where: { $0.id == roleID })
    }

    /// Find an artifact by name
    func artifact(withName name: String) -> TeamArtifact? {
        artifacts.first(where: { $0.name == name })
    }

    /// All artifact display names in this team.
    var artifactNames: [String] {
        artifacts.map(\.name)
    }

    /// Roles that produce the given artifact (have it in `producesArtifacts`).
    func rolesProducing(artifactName: String) -> [TeamRoleDefinition] {
        roles.filter { $0.dependencies.producesArtifacts.contains(artifactName) }
    }

    /// Roles that require the given artifact (have it in `requiredArtifacts`).
    func rolesRequiring(artifactName: String) -> [TeamRoleDefinition] {
        roles.filter { $0.dependencies.requiredArtifacts.contains(artifactName) }
    }

    /// Artifacts that the Supervisor requires before the task can be accepted.
    /// Derived from the Supervisor role's `requiredArtifacts` dependency list.
    var supervisorRequiredArtifacts: [String] {
        let deps = roles.first(where: \.isSupervisor)?.dependencies ?? RoleDependencies()
        let cleaned = deps.requiredArtifacts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(cleaned))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// True when the Supervisor must review specific artifacts before accepting the task.
    var requiresSupervisorFinalReview: Bool {
        !supervisorRequiredArtifacts.isEmpty
    }

    /// True when this team operates in open-ended chat mode (no supervisor deliverables).
    /// Chat-mode tasks have no acceptance flow, no Finish button, and run until paused or closed.
    var isChatMode: Bool {
        supervisorRequiredArtifacts.isEmpty
    }

    /// Creates a new pending `StepExecution` for the given role ID.
    /// Returns `nil` if no role with that ID exists in this team.
    func makeStep(forRoleID roleID: String) -> StepExecution? {
        guard let roleDef = roles.first(where: { $0.id == roleID }) else { return nil }
        return StepExecution.make(for: roleDef)
    }

    // MARK: - Mutations

    /// Add a role to the team
    mutating func addRole(_ role: TeamRoleDefinition) {
        roles.append(role)

        // Add node position if missing
        if !graphLayout.nodePositions.contains(where: { $0.roleID == role.id }) {
            let pos = graphLayout.nextNodePosition()
            graphLayout.nodePositions.append(TeamNodePosition(roleID: role.id, x: pos.x, y: pos.y))
        }

        updatedAt = MonotonicClock.shared.now()
    }

    /// Remove a role from the team, cleaning up all references.
    ///
    /// If the removed role is a system role (`isSystemRole == true` with a non-nil
    /// `systemRoleID`), its `systemRoleID` is appended to `deletedSystemRoleIDs`
    /// so subsequent version-bump reconciles won't resurrect it.
    mutating func removeRole(_ roleID: String) {
        if let removed = roles.first(where: { $0.id == roleID }),
           removed.isSystemRole,
           let sid = removed.systemRoleID,
           !deletedSystemRoleIDs.contains(sid)
        {
            deletedSystemRoleIDs.append(sid)
        }
        roles.removeAll(where: { $0.id == roleID })
        graphLayout.hiddenRoleIDs.remove(roleID)
        graphLayout.nodePositions.removeAll(where: { $0.roleID == roleID })
        // Clean hierarchy: remove as subordinate and re-parent any of its subordinates
        settings.hierarchy.reportsTo.removeValue(forKey: roleID)
        for (sub, sup) in settings.hierarchy.reportsTo where sup == roleID {
            settings.hierarchy.reportsTo.removeValue(forKey: sub)
        }
        if settings.meetingCoordinatorRoleID == roleID {
            settings.meetingCoordinatorRoleID = nil
        }
        settings.invitableRoles.remove(roleID)
        settings.acceptanceCheckpoints.remove(roleID)
        updatedAt = MonotonicClock.shared.now()
    }

    /// Find a role by any identifier: TeamRoleDefinition.id (UUID), systemRoleID (built-in ID), or name (display name).
    func findRole(byIdentifier identifier: String) -> TeamRoleDefinition? {
        if let role = roles.first(where: { $0.id == identifier }) { return role }
        if let role = roles.first(where: { $0.systemRoleID == identifier }) { return role }
        if let role = roles.first(where: { $0.name.caseInsensitiveCompare(identifier) == .orderedSame }) { return role }
        return nil
    }

    /// Update a role in the team
    mutating func updateRole(_ updatedRole: TeamRoleDefinition) {
        if let index = roles.firstIndex(where: { $0.id == updatedRole.id }) {
            roles[index] = updatedRole.withUpdatedTimestamp()
            updatedAt = MonotonicClock.shared.now()
        }
    }

    /// Add an artifact to the team
    mutating func addArtifact(_ artifact: TeamArtifact) {
        artifacts.append(artifact)
        updatedAt = MonotonicClock.shared.now()
    }

    /// Remove an artifact from the team.
    ///
    /// If the removed artifact is a system artifact (`isSystemArtifact == true`),
    /// its `id` is appended to `deletedSystemArtifactIDs` so subsequent
    /// version-bump reconciles won't resurrect it.
    mutating func removeArtifact(_ artifactID: String) {
        if let removed = artifacts.first(where: { $0.id == artifactID }),
           removed.isSystemArtifact,
           !deletedSystemArtifactIDs.contains(removed.id)
        {
            deletedSystemArtifactIDs.append(removed.id)
        }
        artifacts.removeAll(where: { $0.id == artifactID })
        updatedAt = MonotonicClock.shared.now()
    }

    /// Update an artifact in the team
    mutating func updateArtifact(_ updatedArtifact: TeamArtifact) {
        if let index = artifacts.firstIndex(where: { $0.id == updatedArtifact.id }) {
            artifacts[index] = updatedArtifact.withUpdatedTimestamp()
            updatedAt = MonotonicClock.shared.now()
        }
    }

    /// Update team name
    mutating func rename(to newName: String) {
        name = newName
        updatedAt = MonotonicClock.shared.now()
    }

    /// Create a duplicate of this team with a new ID derived from the new name.
    func duplicate(withName newName: String? = nil) -> Team {
        let resolvedName = newName ?? "\(name) Copy"

        // Generate deterministic IDs for roles and artifacts from the new team name
        let newRoles = roles.map { role in
            TeamRoleDefinition(
                id: NTMSID.from(name: "\(resolvedName):\(role.name)"),
                name: role.name,
                prompt: role.prompt,
                toolIDs: role.toolIDs,
                usePlanningPhase: role.usePlanningPhase,
                dependencies: role.dependencies,
                llmOverride: role.llmOverride,
                isSystemRole: false,  // Duplicated roles are custom
                systemRoleID: role.systemRoleID
            )
        }

        let newArtifacts = artifacts.map { artifact in
            TeamArtifact(
                id: NTMSID.from(name: "\(resolvedName):artifact:\(artifact.name)"),
                name: artifact.name,
                icon: artifact.icon,
                mimeType: artifact.mimeType,
                description: artifact.description,
                isSystemArtifact: false,  // Duplicated artifacts are custom
                systemArtifactName: artifact.systemArtifactName
            )
        }

        // Build old → new role ID mapping
        var roleIDMapping: [String: String] = [:]
        for (index, originalRole) in roles.enumerated() {
            if index < newRoles.count {
                roleIDMapping[originalRole.id] = newRoles[index].id
            }
        }

        // Update graph layout with new role IDs
        var newGraphLayout = graphLayout
        for i in 0..<newGraphLayout.nodePositions.count {
            let oldRoleID = newGraphLayout.nodePositions[i].roleID
            if let newID = roleIDMapping[oldRoleID] {
                newGraphLayout.nodePositions[i].roleID = newID
            }
        }
        newGraphLayout.hiddenRoleIDs = Set(
            graphLayout.hiddenRoleIDs.compactMap { roleIDMapping[$0] }
        )

        let newSettings = settings.remappingRoleIDs(roleIDMapping)

        return Team(
            name: resolvedName,
            description: description,
            roles: newRoles,
            artifacts: newArtifacts,
            settings: newSettings,
            graphLayout: newGraphLayout
        )
    }

    // MARK: - Bootstrap Defaults

    /// Roles excluding Supervisor (the user-controlled role).
    var nonSupervisorRoles: [TeamRoleDefinition] {
        roles.filter { !$0.isSupervisor }
    }

    /// All built-in team templates.
    static var defaultTeams: [Team] { TeamTemplateFactory.allTemplates }

    /// Default team (FAANG configuration).
    static var `default`: Team { TeamTemplateFactory.faang() }
}

// MARK: - Hashable

extension Team: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(updatedAt)
    }

    static func == (lhs: Team, rhs: Team) -> Bool {
        lhs.id == rhs.id &&
        lhs.updatedAt == rhs.updatedAt
    }
}
