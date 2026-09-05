import Foundation

// MARK: - Team Validation Service

/// Validates the parts of a team configuration that the Team Editor banner surfaces:
/// per-role delegation policy and attached-skill resolution. Pure functions over the
/// team value — the banner (`TeamEditorValidation.issues`) is the one production caller.
///
/// The artifact-chain validators that used to live here (duplicate producer, missing
/// producer, circular dependency, orphan artifact) were deleted on 2026-09-04: no production
/// surface ever called them, and the editor banner deliberately never showed their output.
nonisolated enum TeamValidationService {

    // MARK: - Validation Errors

    /// Errors found during team validation
    enum ValidationError: Equatable, Hashable {
        /// A role is configured for delegation (`hasDelegationConfigured == true`)
        /// but is not peer-level with the team's Supervisor — i.e. has an
        /// upstream `reportsTo` entry. Only peer-level roles (autonomous, no
        /// upstream) may delegate.
        case nonTopLevelDelegator(roleID: String)

        /// A role's `allowedDelegationTeamIDs` includes a team that no longer
        /// exists in the project (e.g. it was deleted after configuration).
        case unknownDelegationTeam(roleID: String, teamID: NTMSID)

        /// A role's `allowedDelegationTeamIDs` includes the team it belongs to —
        /// trivially circular delegation. Reject at config time.
        case delegationToSelf(roleID: String, teamID: NTMSID)

        /// A role is configured for delegation (`hasDelegationConfigured == true`)
        /// but every whitelist entry references a team that no longer exists
        /// AND generated permission is off. `delegate_to_team`'s embedded
        /// catalog will be empty — the role can never delegate. Narrow under
        /// the new settings-driven model: a fully-empty config can't reach
        /// this rule because `hasDelegationConfigured` would be false.
        case noDelegationTargets(roleID: String)

        /// A role's `attachedSkillIDs` references an agent skill that the scanner
        /// cannot find — the `SKILL.md` was deleted or renamed, or it lives in a
        /// work folder that isn't open. A warning, not an error: the run proceeds
        /// with that skill simply absent from the system prompt, and the id may
        /// resolve again once the right folder is opened. Silence would be the
        /// wrong call though — the user configured a role expecting that text to
        /// be there.
        case unknownAttachedSkill(roleID: String, skillID: String)

        var isError: Bool {
            switch self {
            case .nonTopLevelDelegator, .delegationToSelf:
                return true
            case .unknownDelegationTeam, .noDelegationTargets, .unknownAttachedSkill:
                return false  // Warning, not error
            }
        }

        /// Human-readable, role-name-resolved message for surfacing in the
        /// team-editor validation banner. `team` resolves role IDs to display
        /// names; an ID with no matching role (e.g. a deleted role still
        /// referenced) falls back to the raw ID rather than rendering blank.
        func displayMessage(in team: Team) -> String {
            func roleName(_ id: String) -> String {
                team.roles.first { $0.id == id }?.name ?? id
            }
            switch self {
            case .nonTopLevelDelegator(let roleID):
                return "\(roleName(roleID)) is set to delegate but reports to another role. Only roles that are peer-level with the Supervisor can delegate — remove its “reports to” link."
            case .unknownDelegationTeam(let roleID, let teamID):
                return "\(roleName(roleID)) is set to delegate to a team that no longer exists (\(teamID))."
            case .delegationToSelf(let roleID, _):
                return "\(roleName(roleID)) is set to delegate to its own team, which isn’t allowed."
            case .noDelegationTargets(let roleID):
                return "\(roleName(roleID)) is set to delegate but has no valid target team. Pick an existing team or allow generating new teams."
            case .unknownAttachedSkill(let roleID, let skillID):
                return "\(roleName(roleID)) has an attached skill that can’t be found (\(skillID)). Its text won’t reach the prompt — detach it in the role’s Skills tab, or open the work folder it lives in."
            }
        }
    }

    // MARK: - Attached Skills

    /// Flags every `attachedSkillIDs` entry that the scanner did not discover.
    ///
    /// `knownSkillIDs` is passed in rather than scanned here so this stays a pure
    /// function: the catalogue is orchestrator state (`NTMSOrchestrator.roleSkills`),
    /// refreshed off the main actor on a TTL. Passing an EMPTY set means "we have
    /// no catalogue", which is not the same as "nothing resolves" — callers must
    /// skip the check rather than flag every attachment, or a folder opened before
    /// the first scan lands would light up warnings on every skilled role.
    static func validateAttachedSkills(
        team: Team,
        knownSkillIDs: Set<String>
    ) -> [ValidationError] {
        guard !knownSkillIDs.isEmpty else { return [] }
        var issues: [ValidationError] = []
        for role in team.roles {
            for skillID in role.attachedSkillIDs where !knownSkillIDs.contains(skillID) {
                issues.append(.unknownAttachedSkill(roleID: role.id, skillID: skillID))
            }
        }
        return issues
    }

    // MARK: - Delegation Policy

    /// Validates per-role delegation configuration:
    /// - Roles configured for delegation (`hasDelegationConfigured == true`, i.e. any
    ///   whitelist entry OR generated permission) must be peer-level with
    ///   Supervisor (no upstream `reportsTo` entry). The role-editor save handler
    ///   normally clears `reportsTo` when delegation is enabled — this rule
    ///   catches stale state from imported teams or hand-edited JSON.
    /// - `allowedDelegationTeamIDs` must reference existing teams.
    /// - A role cannot delegate to its own team (trivially circular).
    /// - `noDelegationTargets`: fires when no whitelist entry resolves to a
    ///   *delegatable* team (different from self, exists, and not chat-mode —
    ///   chat-mode teams are filtered from the runtime catalog so a whitelist of
    ///   only chat-mode teams leaves the role with no effective target) AND
    ///   generated permission is off. Catches both stale/unknown ids and targets
    ///   that were converted to chat-mode after being whitelisted.
    static func validateDelegationPolicy(team: Team, allTeams: [Team]) -> [ValidationError] {
        var issues: [ValidationError] = []
        let teamsByID = Dictionary(allTeams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for role in team.roles where role.hasDelegationConfigured {
            // Eligibility: only peer-level (autonomous) roles may delegate.
            if !team.roleIsTopLevelDelegator(role) {
                issues.append(.nonTopLevelDelegator(roleID: role.id))
            }

            // Self-delegation guard.
            if role.allowedDelegationTeamIDs.contains(team.id) {
                issues.append(.delegationToSelf(roleID: role.id, teamID: team.id))
            }

            // Whitelist references must resolve to known project teams. Dedup so a
            // repeated id (imported / hand-edited JSON) emits the warning once.
            var seenWhitelist = Set<NTMSID>()
            for whitelistedID in role.allowedDelegationTeamIDs where whitelistedID != team.id {
                guard seenWhitelist.insert(whitelistedID).inserted else { continue }
                if teamsByID[whitelistedID] == nil {
                    issues.append(.unknownDelegationTeam(roleID: role.id, teamID: whitelistedID))
                }
            }

            // Must have at least one *delegatable* target (a different, existing,
            // non-chat-mode team) or generated permission.
            let hasValidTarget = role.allowedDelegationTeamIDs.contains { id in
                id != team.id && (teamsByID[id]?.isValidDelegationTarget ?? false)
            }
            if !hasValidTarget && !role.allowDelegationToGeneratedTeams {
                issues.append(.noDelegationTargets(roleID: role.id))
            }
        }
        return issues
    }
}
