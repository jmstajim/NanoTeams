import Foundation

/// A team roster keyed for O(1) role lookup, preserving the exact precedence the linear
/// scan it replaces expressed.
///
/// The scan was:
///
/// ```swift
/// if let def = roster.first(where: { $0.id == baseID }) { return def }
/// return roster.first(where: { $0.systemRoleID == baseID || $0.name == baseID })
/// ```
///
/// Two properties have to survive the change, and neither is obvious:
///
///  - **`id` beats the fallbacks outright.** A role whose `id` matches wins over one
///    whose `name` matches even if the name-match comes first in the roster, because the
///    original ran the id scan to completion before starting the second.
///  - **Within the fallback, FIRST in roster order wins**, and `systemRoleID` and `name`
///    are a single scan, not two — a role at index 0 matching on `name` beats a role at
///    index 3 matching on `systemRoleID`. Building two separate maps would silently
///    reverse that.
///
/// Roles are looked up once or twice per rendered timeline item in a deliberately
/// non-lazy `VStack`, so the scan was Θ(items × roles) on every body pass of a view that
/// reads `store.snapshot`.
nonisolated struct RoleRosterIndex: Equatable {
    private var byID: [String: TeamRoleDefinition] = [:]
    private var byFallback: [String: TeamRoleDefinition] = [:]

    init(roster: [TeamRoleDefinition]) {
        byID.reserveCapacity(roster.count)
        byFallback.reserveCapacity(roster.count * 2)
        for def in roster {
            // First-wins, matching `first(where:)`. `updateValue` would make the LAST
            // duplicate win, which is a different answer on a team with two same-id roles
            // (ids are name-derived, so that is reachable — `Run.stepsByRoleBaseID` calls
            // out the same hazard).
            if byID[def.id] == nil { byID[def.id] = def }
        }
        for def in roster {
            if let system = def.systemRoleID, byFallback[system] == nil {
                byFallback[system] = def
            }
            if byFallback[def.name] == nil { byFallback[def.name] = def }
        }
    }

    /// The role a `Role.baseID` resolves to, or nil.
    func role(forBaseID baseID: String) -> TeamRoleDefinition? {
        byID[baseID] ?? byFallback[baseID]
    }

    /// The role whose `id` is exactly `id`, with NO `systemRoleID`/`name` fallback —
    /// the O(1) twin of `roster.first { $0.id == id }`.
    ///
    /// Deliberately separate from `role(forBaseID:)` rather than folded into it, and the
    /// difference is not cosmetic: a graph node is keyed by `TeamNodePosition.roleID`, so
    /// falling back to `name` would resolve a node against an unrelated role and flip the
    /// `isSupervisor` test that decides whether the node is drawn at all. Callers that
    /// hold a `Role.baseID` want the fallback; callers that hold a role's own `id` want
    /// this. `byID` is built first-wins, so the answer is byte-identical to the scan.
    func role(forExactID id: String) -> TeamRoleDefinition? {
        byID[id]
    }
}
