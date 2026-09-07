import Foundation

// MARK: - Meeting Availability

/// Whether a team can hold a meeting right now, and if not, why — `Team.meetingAvailability`.
/// The ONE answer the schema resolver (step 3.0c), the two dispatcher refusals, the role
/// badge and the Collaboration card read, so they cannot disagree about it.
nonisolated enum MeetingAvailability: Hashable, Sendable {
    /// Meetings are on and there is somebody to invite.
    case available
    /// `TeamSettings.meetingsEnabled == false` — the user's explicit choice, reported
    /// before the roster is looked at.
    case switchedOff
    /// Nobody to invite: fewer than two non-Supervisor roles (`Team.hasTeammatePartner`).
    /// A single-role team holds no meeting whatever its switch says — the Supervisor is
    /// the human and is never a meeting participant, so it cannot be the second role.
    case noPartner
}

// MARK: - Team Settings

nonisolated struct TeamSettings: Codable, Hashable {
    /// Hierarchy of subordination: role → its supervisor
    var hierarchy: TeamHierarchy

    /// Role ID (within team) that coordinates team meetings — always a non-Supervisor
    /// role, never "Auto". The coordinator opens every meeting, speaks after each round,
    /// holds `conclude_meeting` inside its meeting turns and is the only role that can
    /// end one. Stored optional so a `teams.json` written before 2026-09-06 (when `nil`
    /// meant "the initiator coordinates") still decodes; the VALUE is never read raw —
    /// `Team.meetingCoordinatorID` resolves it, and a `nil` or orphan id heals to
    /// `TeamSettings.defaultCoordinatorID(among:)` on open, on every role add / remove
    /// and on save, so the stored id is `nil` only for a team with no non-Supervisor
    /// role.
    var meetingCoordinatorRoleID: String?

    /// Whether this team holds meetings at all. `false` ⇒ `request_team_meeting` and
    /// `request_changes` (its vote IS a meeting) are withheld from every role's step
    /// schema and refused if called anyway; the coordinator keeps resolving so turning
    /// meetings back on needs no further setup. A user choice, like every field here: a
    /// version bump never rewrites team settings (`NTMSRepository+Reconcile`). `true` is
    /// necessary, not sufficient —
    /// `Team.meetingAvailability` also needs somebody to invite, so a single-role team
    /// holds no meeting with the switch on.
    var meetingsEnabled: Bool

    /// Roles that can be invited to meetings. Empty means every non-Supervisor role; the
    /// Supervisor is never in it — the human is not a meeting participant nor an
    /// `ask_teammate` target (`MeetingParticipantResolver`).
    var invitableRoles: Set<String>  // role IDs

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
        meetingsEnabled: Bool = true,
        invitableRoles: Set<String> = [],
        limits: TeamLimits = .default,
        defaultAcceptanceMode: AcceptanceMode = .afterEachRole,
        acceptanceCheckpoints: Set<String> = [],
        supervisorMode: SupervisorMode = .manual
    ) {
        self.hierarchy = hierarchy
        self.meetingCoordinatorRoleID = meetingCoordinatorRoleID
        self.meetingsEnabled = meetingsEnabled
        self.invitableRoles = invitableRoles
        self.limits = limits
        self.defaultAcceptanceMode = defaultAcceptanceMode
        self.acceptanceCheckpoints = acceptanceCheckpoints
        self.supervisorMode = supervisorMode
    }

    enum CodingKeys: String, CodingKey {
        case hierarchy
        case meetingCoordinatorRoleID
        case meetingsEnabled
        case invitableRoles
        case limits
        case defaultAcceptanceMode
        case acceptanceCheckpoints
        case supervisorMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hierarchy = try c.decodeIfPresent(TeamHierarchy.self, forKey: .hierarchy) ?? .init()
        self.meetingCoordinatorRoleID = try c.decodeIfPresent(String.self, forKey: .meetingCoordinatorRoleID)
        self.meetingsEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingsEnabled) ?? true
        self.invitableRoles = try c.decodeIfPresent(Set<String>.self, forKey: .invitableRoles) ?? []
        // `supervisorCanBeInvited` (removed 2026-09-07) is left unread: the Supervisor is
        // never a participant, and a keyed container ignores a key nobody asks for.
        self.limits = try c.decodeIfPresent(TeamLimits.self, forKey: .limits) ?? .default
        self.defaultAcceptanceMode = try c.decodeIfPresent(AcceptanceMode.self, forKey: .defaultAcceptanceMode) ?? .afterEachRole
        self.acceptanceCheckpoints = try c.decodeIfPresent(Set<String>.self, forKey: .acceptanceCheckpoints) ?? []
        self.supervisorMode = try c.decodeIfPresent(SupervisorMode.self, forKey: .supervisorMode) ?? .manual
    }

    // MARK: - Meeting Coordinator Rule

    /// The coordinator a team gets when its stored id is `nil` or names a role that no
    /// longer exists: the first non-Supervisor role that can START a meeting
    /// (`request_team_meeting` in `toolIDs`), else the first non-Supervisor role. `nil`
    /// only for a team with no non-Supervisor role — such a team cannot meet.
    /// Deterministic on roster order, so two opens of the same file agree, and the one
    /// rule every writer shares: bootstrap, `Team.addRole` / `removeRole`, the generated
    /// team builder and the Autovisor sync all resolve through here.
    static func defaultCoordinatorID(among roles: [TeamRoleDefinition]) -> String? {
        let candidates = roles.filter { !$0.isSupervisor }
        return candidates.first(where: { $0.toolIDs.contains(ToolNames.requestTeamMeeting) })?.id
            ?? candidates.first?.id
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

nonisolated enum AcceptanceMode: String, Codable, CaseIterable, Hashable {
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

/// How a team's roles reach the Supervisor. `allCases` order is the order of the
/// segments in Team Settings → Ask Supervisor.
///
/// Contract for `.off`: it differs from `.manual` in exactly one thing — no role holds
/// `ask_supervisor` (the step-schema resolver withholds the auto-injection and strips an
/// explicit `toolIDs` entry). Every safety valve the APP owns — the loop-cap escalations
/// that park a step at `.needsSupervisorInput`, the `bash` / computer-use approval cards,
/// the chat-advisory backstop — keeps the `.manual` behaviour: a human is present and is
/// waited for. Only `.autonomous` auto-answers. Chat-mode teams (`Team.isChatMode`) reply
/// THROUGH `ask_supervisor`, so `.off` is not offered there and is a validation error if
/// stored anyway (`TeamValidationService.validateSupervisorMode`).
nonisolated enum SupervisorMode: String, Codable, CaseIterable, Hashable {
    /// Supervisor questions wait for user answer
    case manual
    /// Supervisor questions are auto-answered by LLM
    case autonomous
    /// Roles cannot ask at all — `ask_supervisor` is withheld from every role.
    case off

    /// The modes an LLM-generated team may be given. `.off` is a per-team human choice
    /// that would strand a generated chat-mode team without a reply channel, so neither
    /// the generation prompt nor the forced-default picker offers it.
    static let generationModes: [SupervisorMode] = [.manual, .autonomous]

    private static let metadata: [SupervisorMode: (displayName: String, description: String)] = [
        .manual: ("Manual", "Roles can ask the Supervisor questions that wait for your answer"),
        .autonomous: ("Autonomous", "Supervisor questions are auto-answered by the LLM so work continues uninterrupted"),
        .off: ("Off", "Roles cannot ask the Supervisor: ask_supervisor is withheld from every role. Engine escalations still wait for you"),
    ]

    var displayName: String { Self.metadata[self]?.displayName ?? rawValue }
    var description: String { Self.metadata[self]?.description ?? "" }
}

// MARK: - Role Dependencies

nonisolated struct RoleDependencies: Codable, Hashable {
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
