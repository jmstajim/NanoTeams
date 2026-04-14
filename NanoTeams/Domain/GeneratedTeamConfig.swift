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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `name` missing/empty is recoverable when the model provided a meaningful
        // description: some models (e.g. gemma-4-26b-a4b) emit a valid `team_config`
        // object but forget the top-level `name` field. Synthesize from description
        // rather than rejecting the whole team — matches the decode-time
        // normalization pattern used for orphan artifacts and phantom inputs.
        let rawName = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let rawDescription = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if !trimmedName.isEmpty {
            resolvedName = trimmedName
        } else if let synthesized = Self.synthesizedTeamName(from: rawDescription) {
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
        self.name = resolvedName
        self.description = rawDescription
        // Tolerant per-element decode: skip artifacts that fail to decode
        // (e.g. `name: null` from a truncated stream) instead of failing the
        // entire team. `Failable` swallows decode errors per-element.
        let rawArts = try c.decodeIfPresent([Failable<ArtifactConfig>].self, forKey: .artifacts) ?? []
        var decodedArtifacts: [ArtifactConfig] = rawArts.compactMap(\.value).filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var decodedSupervisorRequires = try c.decodeIfPresent([String].self, forKey: .supervisorRequires) ?? []

        // Auto-synthesize artifacts from role outputs when the top-level list is
        // missing/incomplete. Some models (qwen3.5-9b-mlx) drop the `artifacts`
        // field entirely, leaving every `produces_artifacts` entry as an orphan.
        // Stub description borrows the first sentence of the producing role's
        // prompt — keeps the language matched to the rest of the team and gives
        // the supervisor at least some context about what the artifact contains.
        let alreadyDeclared = Set(decodedArtifacts.map(\.name))
        var seen = alreadyDeclared
        for role in rawRoles {
            for name in role.producesArtifacts where !seen.contains(name) {
                decodedArtifacts.append(ArtifactConfig(
                    name: name,
                    description: Self.derivedDescription(producedBy: role, artifactName: name),
                    icon: nil
                ))
                seen.insert(name)
            }
        }
        self.artifacts = decodedArtifacts

        // Auto-promote orphan produced artifacts (no consumer, not in
        // supervisor_requires) to supervisor_requires. An orphan produced
        // artifact means a role does work that flows nowhere — the model
        // intent is almost always "the supervisor sees this," so surface it
        // rather than silently waste the role's output.
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
        self.supervisorRequires = decodedSupervisorRequires

        // Auto-rewrite phantom inputs to the implicit Supervisor Task. Two variants:
        //   1. Translation aliasing — non-English models emit a translated
        //      `"Supervisor Task"` (e.g. Russian → "Задача Супервизора") which
        //      isn't declared in `artifacts[]`. Captured on qwen session 5.
        //   2. Declared-but-unproduced artifact — the model declares `Workflow
        //      Audit` in `artifacts[]` AND as a consumer's `requires_artifacts`,
        //      but NO role produces it. Previously slipped past the rewrite
        //      because the artifact WAS declared; at runtime the consuming role
        //      would stall forever. Observed on `vague-short` (gemma session 8)
        //      and `non-engineering-production` (session 9).
        // Narrowing `producers` to "roles only" (not declared artifacts) catches
        // both cases with the same rule: if no role actually produces this name,
        // the consumer can't wait for it, so redirect to the Supervisor brief.
        let producers = Set(rawRoles.flatMap(\.producesArtifacts))
        let supervisorTask = SystemTemplates.supervisorTaskArtifactName
        self.roles = rawRoles.map { role in
            let normalizedRequires = role.requiresArtifacts.map { name -> String in
                if name == supervisorTask { return name }
                if producers.contains(name) { return name }
                // Phantom dependency — assume the model translated/aliased the brief.
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
    static func derivedDescription(producedBy role: RoleConfig, artifactName: String) -> String {
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
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private extension AcceptanceMode {
    /// Case-insensitive lookup so the LLM can return `finalOnly`, `FinalOnly`, or `finalonly`.
    static func fromLooseString(_ raw: String) -> AcceptanceMode? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AcceptanceMode.allCases.first { $0.rawValue.lowercased() == normalized }
    }
}
