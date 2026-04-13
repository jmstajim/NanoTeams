import Foundation

/// DTO for LLM-provided team configuration via the `create_team` tool.
///
/// All fields are immutable (`let`) — once decoded, the config is a frozen blueprint
/// for `GeneratedTeamBuilder` to translate into a `Team`. Snake-case keys match the
/// LLM-friendly JSON contract documented in the tool schema.
///
/// Decode is validating: empty `name` or `roles` throw, and enum-shaped strings
/// (`supervisorMode`, `acceptanceMode`) are parsed into their typed enums so that
/// typos like `"autnomous"` fail loudly instead of silently mapping to a default.
struct GeneratedTeamConfig: Codable, Hashable {

    struct RoleConfig: Codable, Hashable {
        let name: String
        let prompt: String
        let producesArtifacts: [String]
        let requiresArtifacts: [String]
        let tools: [String]
        let usePlanningPhase: Bool?
        let icon: String?
        let iconBackground: String?

        enum CodingKeys: String, CodingKey {
            case name, prompt, tools, icon
            case producesArtifacts = "produces_artifacts"
            case requiresArtifacts = "requires_artifacts"
            case usePlanningPhase = "use_planning_phase"
            case iconBackground = "icon_background"
        }
    }

    struct ArtifactConfig: Codable, Hashable {
        let name: String
        let description: String
        let icon: String?
    }

    let name: String
    let description: String
    let supervisorMode: SupervisorMode?
    let acceptanceMode: AcceptanceMode?
    let roles: [RoleConfig]
    let artifacts: [ArtifactConfig]
    let supervisorRequires: [String]

    init(
        name: String,
        description: String,
        supervisorMode: SupervisorMode? = nil,
        acceptanceMode: AcceptanceMode? = nil,
        roles: [RoleConfig],
        artifacts: [ArtifactConfig],
        supervisorRequires: [String]
    ) {
        self.name = name
        self.description = description
        self.supervisorMode = supervisorMode
        self.acceptanceMode = acceptanceMode
        self.roles = roles
        self.artifacts = artifacts
        self.supervisorRequires = supervisorRequires
    }

    enum CodingKeys: String, CodingKey {
        case name, description, roles, artifacts
        case supervisorMode = "supervisor_mode"
        case acceptanceMode = "acceptance_mode"
        case supervisorRequires = "supervisor_requires"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = try c.decode(String.self, forKey: .name)
        guard !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: c,
                debugDescription: "Team name must not be empty."
            )
        }
        let rawRoles = try c.decode([RoleConfig].self, forKey: .roles)
        guard !rawRoles.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .roles, in: c,
                debugDescription: "Team must have at least one role."
            )
        }
        self.name = rawName
        self.description = try c.decode(String.self, forKey: .description)
        self.roles = rawRoles
        self.artifacts = try c.decode([ArtifactConfig].self, forKey: .artifacts)
        self.supervisorRequires = try c.decode([String].self, forKey: .supervisorRequires)

        if let s = try c.decodeIfPresent(String.self, forKey: .supervisorMode),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let mode = SupervisorMode(rawValue: s.lowercased()) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .supervisorMode, in: c,
                    debugDescription: "Unknown supervisor_mode '\(s)'. Allowed: manual, autonomous."
                )
            }
            self.supervisorMode = mode
        } else {
            self.supervisorMode = nil
        }

        if let s = try c.decodeIfPresent(String.self, forKey: .acceptanceMode),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let mode = AcceptanceMode.fromLooseString(s) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .acceptanceMode, in: c,
                    debugDescription: "Unknown acceptance_mode '\(s)'. Allowed: finalOnly, afterEachRole, afterEachArtifact."
                )
            }
            self.acceptanceMode = mode
        } else {
            self.acceptanceMode = nil
        }

        // Cross-validate artifact references — every name appearing in a role's
        // requires/produces or in supervisor_requires must either be in `artifacts`
        // or be the implicit "Supervisor Task". Catches LLMs that ship roles
        // depending on artifacts that nobody declared (the engine would otherwise
        // stall on "no roles ready").
        let declared = Set(artifacts.map(\.name) + [SystemTemplates.supervisorTaskArtifactName])
        var unknown = Set<String>()
        for role in roles {
            for name in role.requiresArtifacts where !declared.contains(name) { unknown.insert(name) }
            for name in role.producesArtifacts where !declared.contains(name) { unknown.insert(name) }
        }
        for name in supervisorRequires where !declared.contains(name) { unknown.insert(name) }
        if !unknown.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .artifacts, in: c,
                debugDescription: "Unknown artifact reference(s): \(unknown.sorted().joined(separator: ", ")). Add to artifacts[] or use \"Supervisor Task\"."
            )
        }
    }
}

private extension AcceptanceMode {
    /// Case-insensitive lookup so the LLM can return `finalOnly`, `FinalOnly`, or `finalonly`.
    static func fromLooseString(_ raw: String) -> AcceptanceMode? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AcceptanceMode.allCases.first { $0.rawValue.lowercased() == normalized }
    }
}
