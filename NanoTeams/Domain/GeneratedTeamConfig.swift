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
nonisolated struct GeneratedTeamConfig: Codable, Hashable {

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

        init(
            name: String,
            prompt: String,
            producesArtifacts: [String] = [],
            requiresArtifacts: [String] = [],
            tools: [String] = [],
            usePlanningPhase: Bool? = nil,
            icon: String? = nil,
            iconBackground: String? = nil
        ) {
            self.name = name
            self.prompt = prompt
            self.producesArtifacts = producesArtifacts
            self.requiresArtifacts = requiresArtifacts
            self.tools = tools
            self.usePlanningPhase = usePlanningPhase
            self.icon = icon
            self.iconBackground = iconBackground
        }

        // Default produces/requires/tools to [] when missing — tolerates LLMs that
        // typo a key (e.g. `producent_artifacts`) or legitimately omit outputs
        // for advisory/chat roles. A role with no outputs falls through to
        // `GeneratedTeamBuilder`, which classifies it by completion type.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.prompt = try c.decode(String.self, forKey: .prompt)
            self.producesArtifacts = try c.decodeIfPresent([String].self, forKey: .producesArtifacts) ?? []
            self.requiresArtifacts = try c.decodeIfPresent([String].self, forKey: .requiresArtifacts) ?? []
            self.tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
            self.usePlanningPhase = try c.decodeIfPresent(Bool.self, forKey: .usePlanningPhase)
            self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
            self.iconBackground = try c.decodeIfPresent(String.self, forKey: .iconBackground)
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
        let decoded = try Self.decode(from: decoder)
        self.name = decoded.name
        self.description = decoded.description
        self.supervisorMode = decoded.supervisorMode
        self.acceptanceMode = decoded.acceptanceMode
        self.roles = decoded.roles
        self.artifacts = decoded.artifacts
        self.supervisorRequires = decoded.supervisorRequires
    }

    /// Heavy decode body extracted from `init(from:)`. Returning a populated
    /// `GeneratedTeamConfig` from a static factory works around a Swift 6.3.1
    /// type-checker crash (`bad_optional_access`) that fires when the original
    /// 150-line init body was inlined inside the type — the crash reproduces
    /// in both Swift 5 and Swift 6 language modes once the type has any
    /// non-default isolation. Functionally identical to the prior init.
    private static func decode(from decoder: Decoder) throws -> GeneratedTeamConfig {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let rawDescription = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if !trimmedName.isEmpty {
            resolvedName = trimmedName
        } else if let synthesized = synthesizedTeamName(from: rawDescription) {
            resolvedName = synthesized
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: c,
                debugDescription: "Team name missing and no description to synthesize from."
            )
        }
        let rawRoles = try c.decode([RoleConfig].self, forKey: .roles)
        guard !rawRoles.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .roles, in: c,
                debugDescription: "Team must have at least one role."
            )
        }
        let rawArts = try c.decodeIfPresent([Failable<ArtifactConfig>].self, forKey: .artifacts) ?? []
        var decodedArtifacts: [ArtifactConfig] = rawArts.compactMap(\.value).filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var decodedSupervisorRequires = try c.decodeIfPresent([String].self, forKey: .supervisorRequires) ?? []

        let alreadyDeclared = Set(decodedArtifacts.map(\.name))
        var seen = alreadyDeclared
        for role in rawRoles {
            for name in role.producesArtifacts where !seen.contains(name) {
                decodedArtifacts.append(ArtifactConfig(
                    name: name,
                    description: derivedDescription(producedBy: role),
                    icon: nil
                ))
                seen.insert(name)
            }
        }

        let consumers = Set(rawRoles.flatMap(\.requiresArtifacts))
        let supReqSet = Set(decodedSupervisorRequires)
        for role in rawRoles {
            for produced in role.producesArtifacts {
                if !consumers.contains(produced)
                    && !supReqSet.contains(produced)
                    && produced != SystemTemplates.supervisorTaskArtifactName
                    && !decodedSupervisorRequires.contains(produced)
                {
                    decodedSupervisorRequires.append(produced)
                }
            }
        }

        let producers = Set(rawRoles.flatMap(\.producesArtifacts))
        let supervisorTask = SystemTemplates.supervisorTaskArtifactName
        let normalizedRoles: [RoleConfig] = rawRoles.map { role in
            let normalizedRequires = role.requiresArtifacts.map { name -> String in
                if name == supervisorTask { return name }
                if producers.contains(name) { return name }
                return supervisorTask
            }
            if normalizedRequires == role.requiresArtifacts { return role }
            return RoleConfig(
                name: role.name,
                prompt: role.prompt,
                producesArtifacts: role.producesArtifacts,
                requiresArtifacts: normalizedRequires,
                tools: role.tools,
                usePlanningPhase: role.usePlanningPhase,
                icon: role.icon,
                iconBackground: role.iconBackground
            )
        }

        let supervisorMode: SupervisorMode?
        if let s = try c.decodeIfPresent(String.self, forKey: .supervisorMode),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let mode = SupervisorMode(rawValue: s.lowercased()) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .supervisorMode, in: c,
                    debugDescription: "Unknown supervisor_mode '\(s)'. Allowed: manual, autonomous."
                )
            }
            supervisorMode = mode
        } else {
            supervisorMode = nil
        }

        let acceptanceMode: AcceptanceMode?
        if let s = try c.decodeIfPresent(String.self, forKey: .acceptanceMode),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let mode = AcceptanceMode.fromLooseString(s) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .acceptanceMode, in: c,
                    debugDescription: "Unknown acceptance_mode '\(s)'. Allowed: finalOnly, afterEachRole, afterEachArtifact."
                )
            }
            acceptanceMode = mode
        } else {
            acceptanceMode = nil
        }

        let declared = Set(decodedArtifacts.map(\.name) + [SystemTemplates.supervisorTaskArtifactName])
        var unknown = Set<String>()
        for role in normalizedRoles {
            for name in role.requiresArtifacts where !declared.contains(name) { unknown.insert(name) }
            for name in role.producesArtifacts where !declared.contains(name) { unknown.insert(name) }
        }
        for name in decodedSupervisorRequires where !declared.contains(name) { unknown.insert(name) }
        if !unknown.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .artifacts, in: c,
                debugDescription: "Unknown artifact reference(s): \(unknown.sorted().joined(separator: ", ")). Add to artifacts[] or use \"Supervisor Task\"."
            )
        }

        return GeneratedTeamConfig(
            name: resolvedName,
            description: rawDescription,
            supervisorMode: supervisorMode,
            acceptanceMode: acceptanceMode,
            roles: normalizedRoles,
            artifacts: decodedArtifacts,
            supervisorRequires: decodedSupervisorRequires
        )
    }

    /// Fallback team name when the LLM omitted the `name` field. Returns `nil`
    /// when the description is empty/whitespace so the caller still fails loudly
    /// on genuinely broken payloads. Trims to ~60 chars and stops at the first
    /// sentence terminator so a multi-sentence description doesn't become a
    /// paragraph-long name. Language-preserving: borrows whatever language the
    /// description is written in.
    static func synthesizedTeamName(from description: String) -> String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let head = String(trimmed.prefix(120))
        if let cut = head.firstIndex(where: { ".!?\n".contains($0) }) {
            let sentence = head[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { return String(sentence.prefix(60)) }
        }
        let clipped = String(trimmed.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.isEmpty ? nil : clipped
    }

    /// First sentence (or first 80 chars) of a producing role's prompt — used as
    /// a default description for auto-synthesized artifact stubs. Matches the
    /// language the role is written in.
    static func derivedDescription(producedBy role: RoleConfig) -> String {
        let prompt = role.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return "" }
        // Cut at first sentence terminator if present in the first 200 chars.
        let head = String(prompt.prefix(200))
        if let cutIndex = head.firstIndex(where: { ".!?\n".contains($0) }) {
            let sentence = head[..<cutIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= 20 { return sentence + "." }
        }
        // Fallback: first 80 chars + ellipsis if longer.
        if prompt.count <= 80 { return prompt }
        return String(prompt.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Decodes a `T` per array element, swallowing per-element failures. Lets us
/// drop malformed array entries (e.g. an artifact with `name: null` from a
/// truncated LLM stream) without rejecting the entire payload.
nonisolated private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

nonisolated private extension AcceptanceMode {
    /// Case-insensitive lookup so the LLM can return `finalOnly`, `FinalOnly`, or `finalonly`.
    static func fromLooseString(_ raw: String) -> AcceptanceMode? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AcceptanceMode.allCases.first { $0.rawValue.lowercased() == normalized }
    }
}
