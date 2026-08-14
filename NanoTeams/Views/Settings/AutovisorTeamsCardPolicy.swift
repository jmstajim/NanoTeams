import Foundation

/// Pure backing for the Settings → Autovisor → Teams card: which rows to draw, and which
/// warning (if any) the current configuration earns.
///
/// Split out so the copy and the row/warning selection are assertable without rendering a
/// view — same shape as `RoleEditorDelegationPolicy`. Every question it answers is delegated
/// to `AutovisorTeamPolicy`, so the card and the tool schema can never disagree about which
/// teams are usable.
nonisolated enum AutovisorTeamsCardPolicy {

    /// One checkbox row. `isAllowed` is the INVERSE of the stored block list — the view
    /// speaks only "allowed" and never sees the inversion.
    nonisolated struct Row: Identifiable, Hashable {
        let id: NTMSID
        let name: String
        let description: String
        let isChatMode: Bool
        let isAllowed: Bool
        /// A blocked id whose team no longer exists. Rendered dimmed and clearable rather
        /// than pruned — see `AutovisorTeamPolicy.orphanBlockedTeamIDs` for why a block list
        /// must never self-prune.
        let isOrphan: Bool
    }

    /// The single warning worth showing, most severe first. Blocking everything is a legal
    /// configuration, so these inform rather than forbid.
    nonisolated enum Warning: Hashable {
        /// Nothing left to create tasks on, and generation is off.
        case cannotCreateAnyTask
        /// Every existing team is blocked, but generation is still available.
        case generatedTeamsOnly
        /// The folder's active team is blocked, so `create_managed_task` without an explicit
        /// `team_id` now fails.
        case activeTeamBlocked(String)
    }

    /// Rows for every team the manager could conceivably use, plus one per orphan block entry.
    /// Uses the same `!isHiddenFromPickers` filter the tool schema uses, so a row exists
    /// exactly when the catalog could list it.
    static func rows(allTeams: [Team], policy: AutovisorTeamPolicy) -> [Row] {
        var rows = allTeams
            .filter { !$0.isHiddenFromPickers }
            .map {
                Row(id: $0.id, name: $0.name, description: $0.description,
                    isChatMode: $0.isChatMode, isAllowed: !policy.blocks(id: $0.id),
                    isOrphan: false)
            }
        rows += policy.orphanBlockedTeamIDs(in: allTeams).map {
            Row(id: $0, name: $0, description: "", isChatMode: false,
                isAllowed: false, isOrphan: true)
        }
        return rows
    }

    static func warning(allTeams: [Team], policy: AutovisorTeamPolicy, activeTeam: Team?) -> Warning? {
        if policy.hasNoSelectableTeam(in: allTeams) {
            return policy.allowGeneration ? .generatedTeamsOnly : .cannotCreateAnyTask
        }
        if let active = activeTeam, policy.blocks(id: active.id) {
            return .activeTeamBlocked(active.name)
        }
        return nil
    }
}

// Extension members do NOT inherit the enum's `nonisolated` under the app target's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so the copy would otherwise be @MainActor and
// unassertable from a plain `XCTestCase`.
nonisolated extension AutovisorTeamsCardPolicy.Warning {
    /// Human-facing copy — naming a Settings surface here is fine; the reader can click it.
    var message: String {
        switch self {
        case .cannotCreateAnyTask:
            return "No team is available. The Autovisor cannot create any task until you allow a team above or turn team generation back on."
        case .generatedTeamsOnly:
            return "Every existing team is blocked, so the Autovisor can only work through teams it generates itself."
        case .activeTeamBlocked(let name):
            return "This folder's active team (\(name)) is blocked, so the Autovisor must name a team explicitly for every task it creates."
        }
    }
}
