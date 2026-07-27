//
//  TeamRoleDefinition.swift
//  NanoTeams
//
//  Team-specific role definition with prompt, tools, and artifact dependencies.
//

import Foundation

/// A role definition that belongs to a specific team.
/// Each team has its own set of roles with customized prompts, tools, and dependencies.
nonisolated struct TeamRoleDefinition: Codable, Identifiable {
    /// Unique identifier within the team
    var id: String

    /// Display name of the role (e.g., "Backend Engineer", "Founder")
    var name: String

    /// SF Symbol name for the role icon (e.g., "hammer", "crown")
    var icon: String

    /// System prompt for the LLM when executing this role
    var prompt: String

    /// Array of tool IDs available to this role
    var toolIDs: [String]

    /// Whether this role uses two-phase execution (planning + execution)
    var usePlanningPhase: Bool

    /// Artifact dependencies: what artifacts are required and produced
    var dependencies: RoleDependencies

    /// Optional per-role LLM configuration override
    var llmOverride: LLMOverride?

    /// Whitelist of team IDs this role may delegate to via `delegate_to_team`.
    /// Empty array = no existing teams allowed. Enforced at `delegate_to_team`
    /// schema-build time (catalog embedded in the tool description omits
    /// disallowed teams) and at delegation time (defense-in-depth against
    /// hallucinated `team_id`).
    ///
    /// Together with `allowDelegationToGeneratedTeams`, this drives `hasDelegationConfigured` —
    /// the single source of truth for whether the 4-tool delegation pack auto-injects
    /// into the role's LLM schema.
    var allowedDelegationTeamIDs: [NTMSID]

    /// When true, the role may pass `team_id == DelegationConstants.generatedTeamSentinel`
    /// to `delegate_to_team` to generate a fresh team on the fly via `TeamGenerationService`.
    /// Also controls whether the synthetic "generated" entry appears in the catalog
    /// embedded in `delegate_to_team`'s description.
    ///
    /// Together with `allowedDelegationTeamIDs`, this drives `hasDelegationConfigured`.
    var allowDelegationToGeneratedTeams: Bool

    /// True if this role was created from a built-in template
    var isSystemRole: Bool

    /// Reference to the system role template ID (e.g., "softwareEngineer")
    /// Only used for roles created from templates, nil for custom roles
    var systemRoleID: String?

    /// Icon foreground color as hex string (#RRGGBB).
    var iconColor: String

    /// Icon background color as hex string (#RRGGBB).
    var iconBackground: String

    /// Creation timestamp
    var createdAt: Date

    /// Last update timestamp
    var updatedAt: Date

    // MARK: - Initialization

    init(
        id: String,
        name: String,
        icon: String = "person",
        prompt: String,
        toolIDs: [String],
        usePlanningPhase: Bool,
        dependencies: RoleDependencies,
        llmOverride: LLMOverride? = nil,
        allowedDelegationTeamIDs: [NTMSID] = [],
        allowDelegationToGeneratedTeams: Bool = false,
        isSystemRole: Bool = false,
        systemRoleID: String? = nil,
        iconColor: String = "#FFFFFF",
        iconBackground: String = "#007AFF",
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.prompt = prompt
        self.toolIDs = toolIDs
        self.usePlanningPhase = usePlanningPhase
        self.dependencies = dependencies
        self.llmOverride = llmOverride
        self.allowedDelegationTeamIDs = allowedDelegationTeamIDs
        self.allowDelegationToGeneratedTeams = allowDelegationToGeneratedTeams
        self.isSystemRole = isSystemRole
        self.systemRoleID = systemRoleID
        self.iconColor = iconColor
        self.iconBackground = iconBackground
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Codable

    /// Read-only view of `useResearchPhase`, the spelling this flag briefly
    /// carried in 1.7.3–1.7.5. Kept out of `CodingKeys` so `Encodable` stays
    /// synthesized and the legacy key is never written back.
    private enum LegacyCodingKeys: String, CodingKey {
        case useResearchPhase
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case prompt
        case toolIDs
        case usePlanningPhase
        case dependencies
        case llmOverride
        case allowedDelegationTeamIDs
        case allowDelegationToGeneratedTeams
        case isSystemRole
        case systemRoleID
        case iconColor
        case iconBackground
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        let systemRoleIDForIcon = try container.decodeIfPresent(String.self, forKey: .systemRoleID)
        self.icon =
            try container.decodeIfPresent(String.self, forKey: .icon)
            ?? SystemTemplates.roles[systemRoleIDForIcon ?? ""]?.icon ?? "person"
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.toolIDs = try container.decodeIfPresent([String].self, forKey: .toolIDs) ?? []
        // Default FALSE. The phase used to be a single `update_scratchpad` call
        // and was on for everyone; it is now a multi-turn read-and-plan stretch,
        // which only the Software Engineer gets by default. Anyone else turns it
        // on per role in the role editor.
        //
        // The 1.7.3–1.7.5 spelling is read from a SEPARATE container rather than
        // as an extra `CodingKeys` case: an unencoded case breaks `Encodable`
        // synthesis, and re-encoding writes only `usePlanningPhase`, so a role
        // the user customised in one of those builds keeps its choice and the
        // file migrates in place. Reconcile overwrites SYSTEM roles from the
        // bundled template anyway — custom roles are the ones that ride this
        // fallback, and an exported team JSON is the one carrier reconcile can
        // never repair.
        let legacyFlag = try? decoder.container(keyedBy: LegacyCodingKeys.self)
            .decodeIfPresent(Bool.self, forKey: .useResearchPhase)
        self.usePlanningPhase =
            try container.decodeIfPresent(Bool.self, forKey: .usePlanningPhase)
            ?? legacyFlag.flatMap { $0 }
            ?? false
        self.dependencies =
            try container.decodeIfPresent(RoleDependencies.self, forKey: .dependencies)
            ?? RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        self.llmOverride = try container.decodeIfPresent(LLMOverride.self, forKey: .llmOverride)
        self.allowedDelegationTeamIDs =
            try container.decodeIfPresent([NTMSID].self, forKey: .allowedDelegationTeamIDs) ?? []
        self.allowDelegationToGeneratedTeams =
            try container.decodeIfPresent(Bool.self, forKey: .allowDelegationToGeneratedTeams) ?? false
        self.isSystemRole = try container.decodeIfPresent(Bool.self, forKey: .isSystemRole) ?? false
        self.systemRoleID = try container.decodeIfPresent(String.self, forKey: .systemRoleID)
        self.iconColor =
            try container.decodeIfPresent(String.self, forKey: .iconColor) ?? "#FFFFFF"
        self.iconBackground =
            try container.decodeIfPresent(String.self, forKey: .iconBackground)
            ?? RoleColorDefaults.defaultBackgroundHex(for: systemRoleIDForIcon)
        self.createdAt =
            try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? MonotonicClock.shared.now()
        self.updatedAt =
            try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? MonotonicClock.shared.now()
    }
}

// MARK: - Role Completion Type

/// Describes how a role completes its work. Derived from artifact dependencies.
nonisolated enum RoleCompletionType: String, Codable {
    /// Role produces artifacts — auto-completes when all expected artifacts are submitted via create_artifact.
    case producing
    /// Role has required inputs but produces nothing — works until Supervisor explicitly finishes it.
    case advisory
    /// Role has no artifact inputs or outputs — engine skips it (participates via meetings only).
    case observer

    // Display label: `.advisory` is rendered as "Chat" in the UI — the "advisory"
    // concept was internal jargon; externally these roles are just continuously-responding
    // chat participants with no deliverables. The enum case name stays for backward-
    // compat with persisted team JSON and callers that switch on it.
    private static let displayLabelMap: [RoleCompletionType: String] = [
        .producing: "Producing",
        .advisory: "Chat",
        .observer: "Observer",
    ]

    var displayLabel: String { Self.displayLabelMap[self] ?? "Unknown" }
}

// MARK: - Helper Methods

nonisolated extension TeamRoleDefinition {
    /// Returns a copy of this role with updated timestamp
    func withUpdatedTimestamp() -> TeamRoleDefinition {
        var copy = self
        copy.updatedAt = MonotonicClock.shared.now()
        return copy
    }

    /// True if this role represents the Supervisor (user-controlled, not LLM-driven).
    var isSupervisor: Bool {
        systemRoleID == "supervisor"
    }

    /// Returns true if this role has no artifact dependencies
    var isIndependent: Bool {
        return dependencies.requiredArtifacts.isEmpty
    }

    /// Returns true if this role produces any artifacts
    var producesArtifacts: Bool {
        return !dependencies.producesArtifacts.isEmpty
    }

    /// Completion type derived from artifact dependencies.
    /// Use this as the single source of truth for role completion behaviour.
    var completionType: RoleCompletionType {
        guard !isSupervisor else { return .producing }
        if !dependencies.producesArtifacts.isEmpty { return .producing }
        if !dependencies.requiredArtifacts.isEmpty { return .advisory }
        return .observer
    }

    /// A role is an observer if it has no input or output artifacts and isn't Supervisor.
    /// Observers participate in meetings/consultations but don't execute steps.
    var isObserver: Bool { completionType == .observer }

    /// Advisory role: consumes artifacts but produces none. Works until Supervisor finishes it.
    var isAdvisory: Bool { completionType == .advisory }

    /// Whether ask_supervisor is auto-injected for this role (non-producing, non-observer, non-supervisor).
    var shouldAutoInjectAskSupervisor: Bool {
        dependencies.producesArtifacts.isEmpty && !isObserver && !isSupervisor
    }

    /// Display label for the role's completion type (e.g. "Producing", "Chat", "Observer").
    /// Note: the underlying enum case for "Chat" is `.advisory` (see `RoleCompletionType`).
    var completionTypeDisplayLabel: String { completionType.displayLabel }

    /// True iff the user has configured at least one delegation target —
    /// a whitelisted team OR generated-team permission. Single source of truth
    /// for "is this role configured for delegation"; replaces the legacy
    /// "delegate_to_team in toolIDs" coupling.
    ///
    /// Drives auto-injection of the 4-tool delegation pack
    /// (`delegate_to_team`, `cancel_delegation`, `resume_delegation`,
    /// `forward_to_team`) into the role's LLM schema —
    /// see `LLMExecutionService+ToolResolution.toolSchemas`. Also drives
    /// peer-status auto-derivation in `TeamTemplateFactory.buildSettings`
    /// and `GeneratedTeamBuilder` (delegating roles skip `reportsTo` wiring).
    var hasDelegationConfigured: Bool {
        !allowedDelegationTeamIDs.isEmpty || allowDelegationToGeneratedTeams
    }

    /// Human-readable summary of artifact dependencies (e.g. "Needs: Plan → produces: Code").
    var artifactSummary: String {
        var parts: [String] = []
        if !dependencies.requiredArtifacts.isEmpty {
            parts.append("Needs: \(dependencies.requiredArtifacts.joined(separator: ", "))")
        }
        if !dependencies.producesArtifacts.isEmpty {
            let prefix = parts.isEmpty ? "Produces" : "produces"
            parts.append("\(prefix): \(dependencies.producesArtifacts.joined(separator: ", "))")
        }
        return parts.joined(separator: " \u{2192} ")
    }

}

// MARK: - Hashable

nonisolated extension TeamRoleDefinition: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TeamRoleDefinition, rhs: TeamRoleDefinition) -> Bool {
        lhs.id == rhs.id
    }
}
