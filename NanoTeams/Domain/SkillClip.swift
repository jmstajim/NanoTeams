import Foundation

/// Where a discovered agent skill lives. Project = inside the open work folder;
/// Global = under the user's home dir (`~/.claude/skills`, `~/.codex/prompts`, …).
/// Shared vocabulary across the scanner, the clip codec, and the picker badge.
nonisolated enum AgentSkillOrigin: String, Codable, Hashable, Sendable, CaseIterable {
    case project
    case global

    /// Short badge label for the picker / chip.
    var badgeLabel: String {
        switch self {
        case .project: return "project"
        case .global: return "global"
        }
    }
}

/// A picked agent skill snippet riding the `clippedTexts` pipe.
///
/// Sibling of `SourceContext` (`ClipboardCaptureService.swift`): both encode
/// metadata + body into a single clip string behind a zero-width-space sentinel,
/// discriminated by a distinct header prefix so parse order between the two never
/// matters. This lets skills reuse every clip path (answer drafts, the queued
/// message pipe, task-creation folding, the chip grid) for free, with the
/// encode/parse living in exactly this one type — single source of truth.
///
/// Two encoded shapes:
/// - **Staged** (picker → composer): carries `name`, `agentLabel`, `origin` so
///   the chip can render the agent + origin badge, plus the source item's opaque
///   `id` so the picker's staged-detection is exact (two distinct skills that
///   share a name/agent/origin — e.g. same-named skills from two plugins — don't
///   cross-mark). The id is composer-only metadata; it never reaches the prompt.
///   `"\u{200B}// Skill: <name>\u{200B}<agent>\u{200B}<origin>\u{200B}<id>\n<body>"`
/// - **Display** (feed re-extraction from a `## Skill:` prompt section, where
///   only the name survives): `"\u{200B}// Skill: <name>\n<body>"` — `parse`
///   tolerates the header line with no ZWSP field separators.
nonisolated struct SkillClip: Hashable, Sendable {
    let id: String?
    let name: String
    let agentLabel: String?
    let origin: AgentSkillOrigin?
    let body: String

    /// Distinct from `SourceContext.headerPrefix` (`"\u{200B}// Source: "`).
    private static let headerPrefix = "\u{200B}// Skill: "

    /// Zero-width space separating the header-line metadata fields. Skill names
    /// come from path components / frontmatter and never contain ZWSP, so
    /// splitting on it is unambiguous.
    private static let fieldSeparator = "\u{200B}"

    init(id: String? = nil, name: String, agentLabel: String? = nil, origin: AgentSkillOrigin? = nil, body: String) {
        self.id = id
        self.name = name
        self.agentLabel = agentLabel
        self.origin = origin
        self.body = body
    }

    /// Encodes into a sentinel clip string for the `clippedTexts` pipe.
    func encoded() -> String {
        var header: String
        if agentLabel == nil, origin == nil, id == nil {
            header = "\(Self.headerPrefix)\(name)"
        } else {
            header = "\(Self.headerPrefix)\(name)"
                + "\(Self.fieldSeparator)\(agentLabel ?? "")"
                + "\(Self.fieldSeparator)\(origin?.rawValue ?? "")"
            if let id { header += "\(Self.fieldSeparator)\(id)" }
        }
        return "\(header)\n\(body)"
    }

    /// Parses a clip string. Returns `nil` for `SourceContext`-enriched clips,
    /// plain clips, an empty name, or an empty body.
    static func parse(_ text: String) -> SkillClip? {
        guard text.hasPrefix(headerPrefix) else { return nil }
        guard let newlineIndex = text.firstIndex(of: "\n") else { return nil }
        let headerStart = text.index(text.startIndex, offsetBy: headerPrefix.count)
        let headerLine = String(text[headerStart..<newlineIndex])
        let body = String(text[text.index(after: newlineIndex)...])
        guard !body.isEmpty else { return nil }

        let fields = headerLine.components(separatedBy: fieldSeparator)
        let name = fields[0]
        guard !name.isEmpty else { return nil }
        let agentLabel = (fields.count > 1 && !fields[1].isEmpty) ? fields[1] : nil
        let origin = fields.count > 2 ? AgentSkillOrigin(rawValue: fields[2]) : nil
        let id = (fields.count > 3 && !fields[3].isEmpty) ? fields[3] : nil
        return SkillClip(id: id, name: name, agentLabel: agentLabel, origin: origin, body: body)
    }
}
