import XCTest
@testable import NanoTeams

/// Coverage for the four delegation-policy validation cases added to
/// `TeamValidationService.validate(team:allTeams:)`.
@MainActor
final class TeamValidationServiceDelegationTests: XCTestCase {

    private func supervisor() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "supervisor"
        )
    }

    private func makeTeam(
        id: NTMSID = "team-A",
        roles: [TeamRoleDefinition],
        reportsTo: [String: String] = [:]
    ) -> Team {
        var settings = TeamSettings()
        settings.hierarchy.reportsTo = reportsTo
        return Team(
            id: id, name: "T",
            roles: roles, artifacts: [],
            settings: settings, graphLayout: TeamGraphLayout()
        )
    }

    /// A delegatable (non-chat) team: its Supervisor requires a deliverable, so
    /// `supervisorRequiredArtifacts` is non-empty → `isChatMode == false`.
    private func makeProducingTeam(id: NTMSID) -> Team {
        let sup = TeamRoleDefinition(
            id: "\(id)-sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Deliverable"], producesArtifacts: []),
            isSystemRole: true, systemRoleID: "supervisor"
        )
        return Team(
            id: id, name: "Producer",
            roles: [sup], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - nonTopLevelDelegator

    /// Under the peer-level rule, a role with `delegate_to_team` is eligible only
    /// when it has NO upstream `reportsTo` entry. Both Engineer (reports to PM)
    /// and PM (reports to Supervisor) are subordinates, so both must fail.
    func testNonTopLevelDelegator_isReportedAsError() {
        // Settings-driven `hasDelegationConfigured`: any whitelist entry OR generated
        // permission flips it true, which enters the validation loop.
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowDelegationToGeneratedTeams: true
        )
        let eng = TeamRoleDefinition(
            id: "eng", name: "Engineer", prompt: "E",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowDelegationToGeneratedTeams: true
        )
        let team = makeTeam(
            roles: [supervisor(), pm, eng],
            reportsTo: ["pm": "sup", "eng": "pm"]
        )
        let result = TeamValidationService.validate(team: team, allTeams: [team])
        XCTAssertTrue(result.errors.contains(.nonTopLevelDelegator(roleID: "pm")),
                      "PM reports to Supervisor → subordinate, not peer → must fail eligibility.")
        XCTAssertTrue(result.errors.contains(.nonTopLevelDelegator(roleID: "eng")),
                      "Engineer reports to PM → subordinate → must fail eligibility.")
    }

    /// A role peer-level with Supervisor (no upstream `reportsTo`) passes eligibility.
    func testNonTopLevelDelegator_silent_whenRoleIsPeerWithSupervisor() {
        let agent = TeamRoleDefinition(
            id: "agent", name: "Agent", prompt: "A",
            toolIDs: [ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: [],
            allowDelegationToGeneratedTeams: true  // give it a valid target
        )
        // Empty reportsTo — agent is peer with Supervisor.
        let team = makeTeam(roles: [supervisor(), agent], reportsTo: [:])
        let result = TeamValidationService.validate(team: team, allTeams: [team])
        XCTAssertFalse(result.errors.contains { issue in
            if case .nonTopLevelDelegator = issue { return true }
            return false
        })
    }

    // MARK: - delegationToSelf

    func testDelegationToSelf_isError() {
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["team-A"],  // self-reference
            allowDelegationToGeneratedTeams: false
        )
        // pm is peer-level with Supervisor (no reportsTo) so the only policy
        // exercised by this test is the one under check, not the eligibility rule.
        let team = makeTeam(roles: [supervisor(), pm], reportsTo: [:])
        let result = TeamValidationService.validate(team: team, allTeams: [team])
        XCTAssertTrue(result.errors.contains(.delegationToSelf(roleID: "pm", teamID: "team-A")))
    }

    // MARK: - unknownDelegationTeam (warning)

    func testUnknownDelegationTeam_isWarning() {
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["team-zzz"],  // doesn't exist in `allTeams`
            allowDelegationToGeneratedTeams: false
        )
        // pm is peer-level with Supervisor (no reportsTo) so the only policy
        // exercised by this test is the one under check, not the eligibility rule.
        let team = makeTeam(roles: [supervisor(), pm], reportsTo: [:])
        let result = TeamValidationService.validate(team: team, allTeams: [team])
        XCTAssertTrue(result.warnings.contains(.unknownDelegationTeam(roleID: "pm", teamID: "team-zzz")),
                      "Should be warning, not error — team may have been deleted post-config.")
        XCTAssertFalse(result.errors.contains(.unknownDelegationTeam(roleID: "pm", teamID: "team-zzz")))
    }

    // MARK: - noDelegationTargets (warning)

    /// Under the settings-driven model `hasDelegationConfigured` is false when both
    /// whitelist and generated are empty, so the loop guard skips the role and
    /// `.noDelegationTargets` cannot fire from a fully-empty config. The narrow
    /// trigger that remains: whitelist references only stale (unknown) teams
    /// AND generated permission off — the role passes `hasDelegationConfigured` but
    /// has no live targets. Pin that case.
    func testNoDelegationTargets_emitsWarning_whenAllWhitelistEntriesAreStale() {
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["team-zzz"],  // stale: not in `allTeams`
            allowDelegationToGeneratedTeams: false
        )
        // pm is peer-level with Supervisor (no reportsTo) so the only policy
        // exercised by this test is the one under check, not the eligibility rule.
        let team = makeTeam(roles: [supervisor(), pm], reportsTo: [:])
        let result = TeamValidationService.validate(team: team, allTeams: [team])
        XCTAssertTrue(result.warnings.contains(.noDelegationTargets(roleID: "pm")))
    }

    /// A role with no delegation settings at all is silently skipped — under
    /// the settings-driven model `hasDelegationConfigured == false` so the loop
    /// guard never enters the body. The user simply hasn't configured
    /// delegation; nothing to validate.
    func testNoDelegationTargets_silent_whenSettingsEmpty() {
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: [],
            allowDelegationToGeneratedTeams: false
        )
        let team = makeTeam(roles: [supervisor(), pm], reportsTo: [:])
        let result = TeamValidationService.validate(team: team, allTeams: [team])
        XCTAssertFalse(result.warnings.contains(.noDelegationTargets(roleID: "pm")),
                       "Empty settings → hasDelegationConfigured=false → loop guard skips the rule.")
    }

    func testNoDelegationTargets_silent_whenGeneratedAllowed() {
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: [],
            allowDelegationToGeneratedTeams: true
        )
        // pm is peer-level with Supervisor (no reportsTo) so the only policy
        // exercised by this test is the one under check, not the eligibility rule.
        let team = makeTeam(roles: [supervisor(), pm], reportsTo: [:])
        let result = TeamValidationService.validate(team: team, allTeams: [team])
        XCTAssertFalse(result.warnings.contains(.noDelegationTargets(roleID: "pm")),
                       "Generated-team permission means delegate_to_team's catalog will have at least the sentinel.")
    }

    // MARK: - Roles without delegation settings are ignored

    /// Under the settings-driven model the loop guard is `hasDelegationConfigured`.
    /// A role with no whitelist entry AND no generated permission is skipped
    /// regardless of what's in `toolIDs` — the new gate is settings, not tools.
    func testRolesWithoutDelegationSettings_areNotValidated() {
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [ToolNames.delegateToTeam],  // legacy noise, no longer the trigger
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: [],
            allowDelegationToGeneratedTeams: false
        )
        // pm is wired as Supervisor subordinate. Under the OLD model
        // (toolID-driven) this would fire `nonTopLevelDelegator`. Under the
        // NEW model `hasDelegationConfigured=false` (settings empty), so the loop
        // guard skips and no error fires.
        let team = makeTeam(roles: [supervisor(), pm], reportsTo: ["pm": "sup"])
        let result = TeamValidationService.validate(team: team, allTeams: [team])
        XCTAssertFalse(result.errors.contains { issue in
            if case .nonTopLevelDelegator = issue { return true }
            return false
        }, "No delegation settings → loop guard skips → no eligibility validation runs.")
    }

    // MARK: - Chat-mode targets are not valid (closes the silent-target gap)

    /// A whitelist that resolves only to a KNOWN team which is chat-mode (e.g. a
    /// non-chat target later converted to chat-mode) leaves the role with no
    /// effective target — chat-mode teams are filtered from the runtime catalog.
    /// `noDelegationTargets` must fire; `unknownDelegationTeam` must NOT (it exists).
    func testNoDelegationTargets_emitsWarning_whenOnlyTargetIsChatMode() {
        let chatTarget = makeTeam(id: "chat-team", roles: [supervisor()])  // empty supervisor deps → chat-mode
        XCTAssertTrue(chatTarget.isChatMode, "Fixture precondition: target must be chat-mode.")
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["chat-team"],
            allowDelegationToGeneratedTeams: false
        )
        let home = makeTeam(id: "team-A", roles: [supervisor(), pm], reportsTo: [:])
        let result = TeamValidationService.validate(team: home, allTeams: [home, chatTarget])

        XCTAssertTrue(result.warnings.contains(.noDelegationTargets(roleID: "pm")),
                      "A whitelist of only chat-mode (non-delegatable) teams leaves no valid target.")
        XCTAssertFalse(result.warnings.contains(.unknownDelegationTeam(roleID: "pm", teamID: "chat-team")),
                       "The team exists — it must NOT be reported as unknown, only as a non-target.")
    }

    /// Contrast: a whitelist resolving to a KNOWN delegatable (non-chat) team is
    /// fine — no `noDelegationTargets`.
    func testNoDelegationTargets_silent_whenTargetIsDelegatable() {
        let realTarget = makeProducingTeam(id: "eng-team")
        XCTAssertFalse(realTarget.isChatMode, "Fixture precondition: target must be delegatable.")
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["eng-team"],
            allowDelegationToGeneratedTeams: false
        )
        let home = makeTeam(id: "team-A", roles: [supervisor(), pm], reportsTo: [:])
        let result = TeamValidationService.validate(team: home, allTeams: [home, realTarget])

        XCTAssertFalse(result.warnings.contains(.noDelegationTargets(roleID: "pm")),
                       "A known, delegatable target must satisfy the valid-target check.")
    }

    // MARK: - Whitelist dedup

    /// A repeated unknown id (imported / hand-edited JSON) must warn exactly once,
    /// not once per occurrence — otherwise the banner renders duplicate rows.
    func testUnknownDelegationTeam_dedupesRepeatedWhitelistID() {
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["ghost", "ghost"],  // duplicate stale id
            allowDelegationToGeneratedTeams: false
        )
        let team = makeTeam(roles: [supervisor(), pm], reportsTo: [:])
        let issues = TeamValidationService.validateDelegationPolicy(team: team, allTeams: [team])

        let ghostWarnings = issues.filter {
            if case .unknownDelegationTeam(_, let teamID) = $0 { return teamID == "ghost" }
            return false
        }
        XCTAssertEqual(ghostWarnings.count, 1, "A duplicated unknown whitelist id must warn exactly once.")
    }
}
