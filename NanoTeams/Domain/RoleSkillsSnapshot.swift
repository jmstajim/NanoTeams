import Foundation

/// One agent skill attached to a role, already resolved to the bytes that go on
/// the wire.
///
/// The body is read ONCE per snapshot refresh and never re-read at prompt-build
/// time, so the bytes a role sees are pinned for the whole run — the same
/// contract `AgentInstructionsSnapshot` holds, and what keeps the system prompt
/// (segment 0, where the prompt-prefix cache keys) byte-stable while a step
/// runs.
nonisolated struct ResolvedRoleSkill: Hashable, Sendable {
    /// The `AgentSkillsSnapshot.Item.id` this was resolved from — the value
    /// persisted in `TeamRoleDefinition.attachedSkillIDs`.
    let id: String
    /// Display name, used verbatim in the `## Skill: <name>` prompt header.
    let name: String
    /// Full trimmed `SKILL.md` content. Never truncated.
    let body: String
}

/// Snapshot of every discoverable agent skill plus the bodies of the ones some
/// role actually attached.
///
/// Deliberately NOT a copy of `AgentInstructionsSnapshot`'s shape. Two things
/// differ, both load-bearing:
///
/// 1. **`items` covers everything discoverable**, not just what is attached —
///    the Role editor's Skills tab needs the full catalogue to pick from, and
///    scanning is cheap next to reading bodies.
/// 2. **`bodies` is keyed by id and populated only for attached ids.** A role
///    can attach a 27 KB skill; reading every discovered skill (527 KB across
///    136 plugin skills on a typical machine) would be pure waste.
///
/// `unresolvedIDs` is the no-silent-drops half: an attached id whose file has
/// been deleted, moved, or become unreadable lands here instead of quietly
/// vanishing from the prompt, so the editor and the team validator can say so.
nonisolated struct RoleSkillsSnapshot: Hashable, Sendable {
    /// Everything the scanner found, in its deterministic order.
    let items: [AgentSkillsSnapshot.Item]
    /// Full body per attached skill id.
    let bodies: [String: String]
    /// Attached ids that did not resolve to readable content.
    let unresolvedIDs: Set<String>

    static let empty = RoleSkillsSnapshot(items: [], bodies: [:], unresolvedIDs: [])

    var isEmpty: Bool { items.isEmpty }

    /// Resolves a role's attached ids into prompt-ready values, **preserving the
    /// role's order** — that order is the order of `## Skill:` sections in the
    /// system prompt, so it must never be re-sorted here.
    ///
    /// Ids that did not resolve are skipped rather than rendered empty; they are
    /// reported through `unresolvedIDs` instead.
    func resolve(_ attachedIDs: [String]) -> [ResolvedRoleSkill] {
        var seen: Set<String> = []
        return attachedIDs.compactMap { id in
            // A duplicate id would render the same skill twice, wasting the
            // context it costs. First occurrence wins so the role's ordering
            // intent is preserved.
            guard seen.insert(id).inserted else { return nil }
            guard let body = bodies[id], !body.isEmpty else { return nil }
            guard let item = items.first(where: { $0.id == id }) else { return nil }
            return ResolvedRoleSkill(id: id, name: item.name, body: body)
        }
    }
}
