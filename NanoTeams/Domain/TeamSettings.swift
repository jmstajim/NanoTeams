import Foundation

// MARK: - Team Settings

struct TeamSettings: Codable, Hashable {
    /// Hierarchy of subordination: role → its supervisor
    var hierarchy: TeamHierarchy

    /// Role ID (within team) that coordinates team meetings. Nil = first non-Supervisor role.
    var meetingCoordinatorRoleID: String?

    /// Roles that can be invited to meetings
    var invitableRoles: Set<String>  // role IDs

    /// Whether Supervisor can be invited to meetings (special case, default false)
    var supervisorCanBeInvited: Bool

    /// Limits for team collaboration
    var limits: TeamLimits

    /// Default acceptance mode for work review
    var defaultAcceptanceMode: AcceptanceMode

    /// Roles that require acceptance checkpoint (for customCheckpoints mode)
    var acceptanceCheckpoints: Set<String>  // role IDs

    /// How the team handles Supervisor questions (ask_supervisor tool)
    var supervisorMode: SupervisorMode

    /// Minimal defaults — actual role IDs are set by Team factory methods
    static let `default` = TeamSettings()

    init(
        hierarchy: TeamHierarchy = .init(),
        meetingCoordinatorRoleID: String? = nil,
        invitableRoles: Set<String> = [],
        supervisorCanBeInvited: Bool = false,
        limits: TeamLimits = .default,
        defaultAcceptanceMode: AcceptanceMode = .afterEachRole,
        acceptanceCheckpoints: Set<String> = [],
        supervisorMode: SupervisorMode = .manual
    ) {
        self.hierarchy = hierarchy
        self.meetingCoordinatorRoleID = meetingCoordinatorRoleID
        self.invitableRoles = invitableRoles
        self.supervisorCanBeInvited = supervisorCanBeInvited
        self.limits = limits
        self.defaultAcceptanceMode = defaultAcceptanceMode
        self.acceptanceCheckpoints = acceptanceCheckpoints
        self.supervisorMode = supervisorMode
    }

    enum CodingKeys: String, CodingKey {
        case hierarchy
        case meetingCoordinatorRoleID
        case invitableRoles
        case supervisorCanBeInvited
        case limits
        case defaultAcceptanceMode
        case acceptanceCheckpoints
        case supervisorMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hierarchy = try c.decodeIfPresent(TeamHierarchy.self, forKey: .hierarchy) ?? .init()
        self.meetingCoordinatorRoleID = try c.decodeIfPresent(String.self, forKey: .meetingCoordinatorRoleID)
        self.invitableRoles = try c.decodeIfPresent(Set<String>.self, forKey: .invitableRoles) ?? []
        self.supervisorCanBeInvited = try c.decodeIfPresent(Bool.self, forKey: .supervisorCanBeInvited) ?? false
        self.limits = try c.decodeIfPresent(TeamLimits.self, forKey: .limits) ?? .default
        self.defaultAcceptanceMode = try c.decodeIfPresent(AcceptanceMode.self, forKey: .defaultAcceptanceMode) ?? .afterEachRole
        self.acceptanceCheckpoints = try c.decodeIfPresent(Set<String>.self, forKey: .acceptanceCheckpoints) ?? []
        self.supervisorMode = try c.decodeIfPresent(SupervisorMode.self, forKey: .supervisorMode) ?? .manual
    }

    // MARK: - Role ID Remapping

    /// Returns a copy with all role ID references remapped via the given mapping.
    /// Keys not present in `mapping` are left unchanged.
    func remappingRoleIDs(_ mapping: [String: String]) -> TeamSettings {
        guard !mapping.isEmpty else { return self }
        var result = self
        var newReportsTo: [String: String] = [:]
        for (child, parent) in result.hierarchy.reportsTo {
            newReportsTo[mapping[child] ?? child] = mapping[parent] ?? parent
        }
        result.hierarchy.reportsTo = newReportsTo
        if let coord = result.meetingCoordinatorRoleID {
            result.meetingCoordinatorRoleID = mapping[coord] ?? coord
        }
        result.invitableRoles = Set(result.invitableRoles.map { mapping[$0] ?? $0 })
        result.acceptanceCheckpoints = Set(result.acceptanceCheckpoints.map { mapping[$0] ?? $0 })
        return result
    }
}

// MARK: - Acceptance Mode

enum AcceptanceMode: String, Codable, CaseIterable, Hashable {
    /// Supervisor approves each artifact before it's passed to the next role
    case afterEachArtifact

    /// Supervisor approves the entire role's work when completed
    case afterEachRole

    /// Supervisor approves only the final result when all roles are done
    case finalOnly

    /// Supervisor chooses which roles require acceptance checkpoint
    case customCheckpoints

    private static let metadata: [AcceptanceMode: (displayName: String, description: String)] = [
        .afterEachArtifact: ("After Each Artifact", "Supervisor approves each artifact before passing to next role"),
        .afterEachRole: ("After Each Role", "Supervisor approves the complete work of each role"),
        .finalOnly: ("Final Result Only", "Supervisor approves only when all roles complete"),
        .customCheckpoints: ("Custom Checkpoints", "Supervisor selects which roles require approval"),
    ]

    var displayName: String { Self.metadata[self]?.displayName ?? rawValue }
    var description: String { Self.metadata[self]?.description ?? "" }
}

// MARK: - Supervisor Mode

enum SupervisorMode: String, Codable, CaseIterable, Hashable {
    /// Supervisor questions wait for user answer
    case manual
    /// Supervisor questions are auto-answered by LLM
    case autonomous

    private static let metadata: [SupervisorMode: (displayName: String, description: String)] = [
        .manual: ("Manual", "Roles can ask the Supervisor questions that wait for your answer"),
        .autonomous: ("Autonomous", "Supervisor questions are auto-answered by the LLM so work continues uninterrupted"),
    ]

    var displayName: String { Self.metadata[self]?.displayName ?? rawValue }
    var description: String { Self.metadata[self]?.description ?? "" }
}

// MARK: - Role Dependencies

struct RoleDependencies: Codable, Hashable {
    /// Artifact names required for the role to start working
    var requiredArtifacts: [String]

    /// Artifact names that the role produces
    var producesArtifacts: [String]

    init(requiredArtifacts: [String] = [], producesArtifacts: [String] = []) {
        self.requiredArtifacts = requiredArtifacts
        self.producesArtifacts = producesArtifacts
    }

    enum CodingKeys: String, CodingKey {
        case requiredArtifacts
        case producesArtifacts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.requiredArtifacts =
            try c.decodeIfPresent([String].self, forKey: .requiredArtifacts) ?? []
        self.producesArtifacts =
            try c.decodeIfPresent([String].self, forKey: .producesArtifacts) ?? []
    }
}
