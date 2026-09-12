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

        /// The stored `meetingCoordinatorRoleID` is `nil` or names a role that is gone
        /// (or the Supervisor), so `Team.meetingCoordinatorID` answers with the default
        /// rule instead. A warning: the team runs, with `to` in the chair; saving the
        /// team writes that id back (`Team.healMeetingCoordinator`).
        case meetingCoordinatorHealed(from: String?, to: String)

        /// `supervisorMode == .off` on a chat-mode team. Such a team's only reply channel
        /// IS `ask_supervisor` (its Final reminder says so), so Off leaves the role with
        /// no way to answer. An error; the picker never offers Off there, so this is
        /// reachable only through import or hand-edited JSON — and deliberately NOT
        /// normalised at runtime, which would hide the defect the banner names.
        case askSupervisorOffInChatMode

        /// A role holds `ask_supervisor_form` without `ask_supervisor`. A warning, not an
        /// error: the resolver pairs them before the schema ships (step 4-bis), so the run is
        /// fine — but the stored toolset then differs from what runs, and a Tools tab showing
        /// only the questionnaire reads as "this role cannot ask a plain question".
        case supervisorFormWithoutPlainAsk(roleID: String)

        var isError: Bool {
            switch self {
            case .nonTopLevelDelegator, .delegationToSelf, .askSupervisorOffInChatMode:
                return true
            case .unknownDelegationTeam, .noDelegationTargets, .unknownAttachedSkill,
                 .meetingCoordinatorHealed, .supervisorFormWithoutPlainAsk:
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
            case .meetingCoordinatorHealed(let from, let to):
                let was = from.map { " (was \($0))" } ?? ""
                return "\(roleName(to)) coordinates this team’s meetings — the stored coordinator\(was) no longer names a role. Pick another one in Settings → Collaboration if that isn’t the right choice."
            case .askSupervisorOffInChatMode:
                return "Ask Supervisor is Off, but this chat-mode team replies through ask_supervisor — its role would have no way to answer. Switch the mode to Manual or Autonomous."
            case .supervisorFormWithoutPlainAsk(let roleID):
                return "\(roleName(roleID)) can send a questionnaire but has no plain \(ToolNames.askSupervisor) — the run adds one beside it, because every escalation reminder names that tool. Check it in the role’s Tools tab to make the toolset say what actually runs."
            }
        }
    }

    // MARK: - Meeting Coordinator

    /// Flags a stored coordinator id that the default rule will replace — see
    /// `Team.meetingCoordinatorNeedsHealing`. Nothing to flag for a team with no
    /// non-Supervisor role (`TeamManagementService.validate` already reports `.noRoles`).
    static func validateMeetingCoordinator(team: Team) -> [ValidationError] {
        guard team.meetingCoordinatorNeedsHealing, let healed = team.meetingCoordinatorID else { return [] }
        return [.meetingCoordinatorHealed(from: team.settings.meetingCoordinatorRoleID, to: healed)]
    }

    // MARK: - Supervisor Mode

    /// Flags `.off` on a chat-mode team — the one combination that leaves a role
    /// without a reply channel (see `SupervisorMode`).
    static func validateSupervisorMode(team: Team) -> [ValidationError] {
        guard team.settings.supervisorMode == .off, team.isChatMode else { return [] }
        return [.askSupervisorOffInChatMode]
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

    // MARK: - Supervisor Ask Tools

    /// Flags a role granted `ask_supervisor_form` without `ask_supervisor`.
    ///
    /// The questionnaire is a companion, never a replacement: the escalation texts each name
    /// one channel and it is the plain tool (`LoopRecoveryPolicy.escalationChannel`,
    /// `SystemTemplates.stepEnding`). The resolver therefore pairs the two before the schema
    /// ships, which is why this is a warning rather than an error — nothing is broken, but
    /// the stored toolset no longer describes the run, and the person reading the Tools tab
    /// is the one who would be misled.
    ///
    /// Deliberately NOT symmetric, though the resolver's pairing is (step 4-bis pairs in both
    /// directions since 2026-09-10). The plain ask alone is the shape the app itself writes —
    /// `TeamGenerationService` teaches the model that one name, and every team stored before
    /// the form existed carries it — so warning on it would put a row under nearly every
    /// non-bundled role and turn the banner into wallpaper. It is also the harmless half: the
    /// role keeps a channel every text names, it just cannot batch its questions. The
    /// form-alone half is the one no app path produces and the one where three texts
    /// contradict the shipped schema.
    ///
    /// Either way the Tools tab is not silent — it lists the paired-in tool under
    /// "Auto-injected", because `RoleToolBadgePolicy` resolves through this same resolver.
    ///
    /// The Supervisor row is skipped for free: it is a human and holds no tools.
    static func validateSupervisorAskTools(team: Team) -> [ValidationError] {
        team.roles.compactMap { role in
            let held = Set(role.toolIDs)
            guard held.contains(ToolNames.askSupervisorForm),
                  !held.contains(ToolNames.askSupervisor) else { return nil }
            return .supervisorFormWithoutPlainAsk(roleID: role.id)
        }
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
