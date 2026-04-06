//
//  TeamRoleDefinition.swift
//  NanoTeams
//
//  Team-specific role definition with prompt, tools, and artifact dependencies.
//

import Foundation

/// A role definition that belongs to a specific team.
/// Each team has its own set of roles with customized prompts, tools, and dependencies.
struct TeamRoleDefinition: Codable, Identifiable {
    /// Unique identifier within the team
    var id: String

    /// Display name of the role (e.g., "Backend Engineer", "Founder")
    var name: String

    /// SF Symbol name for the role icon (e.g., "hammer.fill", "crown.fill")
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
        icon: String = "person.fill",
        prompt: String,
        toolIDs: [String],
        usePlanningPhase: Bool,
        dependencies: RoleDependencies,
        llmOverride: LLMOverride? = nil,
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
        self.isSystemRole = isSystemRole
        self.systemRoleID = systemRoleID
        self.iconColor = iconColor
        self.iconBackground = iconBackground
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case prompt
        case toolIDs
        case usePlanningPhase
        case dependencies
        case llmOverride
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
            ?? SystemTemplates.roles[systemRoleIDForIcon ?? ""]?.icon ?? "person.fill"
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.toolIDs = try container.decodeIfPresent([String].self, forKey: .toolIDs) ?? []
        self.usePlanningPhase =
            try container.decodeIfPresent(Bool.self, forKey: .usePlanningPhase) ?? true
        self.dependencies =
            try container.decodeIfPresent(RoleDependencies.self, forKey: .dependencies)
            ?? RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        self.llmOverride = try container.decodeIfPresent(LLMOverride.self, forKey: .llmOverride)
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
enum RoleCompletionType {
    /// Role produces artifacts — auto-completes when all expected artifacts are submitted via create_artifact.
    case producing
    /// Role has required inputs but produces nothing — works until Supervisor explicitly finishes it.
    case advisory
    /// Role has no artifact inputs or outputs — engine skips it (participates via meetings only).
    case observer

    private static let displayLabelMap: [RoleCompletionType: String] = [
        .producing: "Producing",
        .advisory: "Advisory",
        .observer: "Observer",
    ]

    var displayLabel: String { Self.displayLabelMap[self] ?? "Unknown" }
}

// MARK: - Helper Methods

extension TeamRoleDefinition {
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

    /// Display label for the role's completion type (e.g. "Producing", "Advisory", "Observer").
    var completionTypeDisplayLabel: String { completionType.displayLabel }

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

extension TeamRoleDefinition: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TeamRoleDefinition, rhs: TeamRoleDefinition) -> Bool {
        lhs.id == rhs.id
    }
}
