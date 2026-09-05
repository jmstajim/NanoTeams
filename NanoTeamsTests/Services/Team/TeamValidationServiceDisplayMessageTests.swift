import XCTest
@testable import NanoTeams

/// Coverage for `TeamValidationService.ValidationError.displayMessage(in:)` —
/// the human-readable bridge that surfaces validation issues (delegation policy +
/// attached skills) in the Team Editor banner. Each message must resolve role IDs to
/// display names and fall back to the raw ID for unresolved roles, never render
/// blank, and include the salient artifact / team identifiers.
@MainActor
final class TeamValidationServiceDisplayMessageTests: XCTestCase {

    // MARK: - Fixtures

    private func role(id: String, name: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, prompt: "p",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
    }

    private func supervisor() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "supervisor"
        )
    }

    private func makeTeam(id: NTMSID = "team-A", roles: [TeamRoleDefinition]) -> Team {
        Team(
            id: id, name: "T",
            roles: roles, artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - Role-name resolution

    func testDisplayMessage_resolvesRoleIDToDisplayName() {
        let team = makeTeam(roles: [role(id: "pm", name: "Product Manager")])
        let msg = TeamValidationService.ValidationError
            .noDelegationTargets(roleID: "pm").displayMessage(in: team)

        XCTAssertTrue(msg.contains("Product Manager"), "Message must use the role's display name. Got: \(msg)")
        XCTAssertFalse(msg.isEmpty)
    }

    func testDisplayMessage_unknownRoleID_fallsBackToRawID() {
        let team = makeTeam(roles: [role(id: "pm", name: "Product Manager")])
        let msg = TeamValidationService.ValidationError
            .noDelegationTargets(roleID: "ghost-role").displayMessage(in: team)

        XCTAssertTrue(msg.contains("ghost-role"), "Unresolved role id must fall back to the raw id, not render blank. Got: \(msg)")
    }

    // MARK: - Delegation cases

    func testNonTopLevelDelegator_message_namesRole_andMentionsDelegation() {
        let team = makeTeam(roles: [role(id: "pm", name: "Product Manager")])
        let msg = TeamValidationService.ValidationError
            .nonTopLevelDelegator(roleID: "pm").displayMessage(in: team)

        XCTAssertTrue(msg.contains("Product Manager"))
        XCTAssertTrue(msg.lowercased().contains("delegate"))
    }

    func testDelegationToSelf_message_namesRole() {
        let team = makeTeam(roles: [role(id: "pm", name: "Product Manager")])
        let msg = TeamValidationService.ValidationError
            .delegationToSelf(roleID: "pm", teamID: "team-A").displayMessage(in: team)

        XCTAssertTrue(msg.contains("Product Manager"))
        XCTAssertTrue(msg.lowercased().contains("own team"))
    }

    func testUnknownDelegationTeam_message_namesRole_andIncludesTeamID() {
        let team = makeTeam(roles: [role(id: "pm", name: "Product Manager")])
        let msg = TeamValidationService.ValidationError
            .unknownDelegationTeam(roleID: "pm", teamID: "team-zzz").displayMessage(in: team)

        XCTAssertTrue(msg.contains("Product Manager"))
        XCTAssertTrue(msg.contains("team-zzz"), "Must surface the dangling team id so the user can find/remove it. Got: \(msg)")
    }

    func testNoDelegationTargets_message_namesRole() {
        let team = makeTeam(roles: [role(id: "pm", name: "Product Manager")])
        let msg = TeamValidationService.ValidationError
            .noDelegationTargets(roleID: "pm").displayMessage(in: team)

        XCTAssertTrue(msg.contains("Product Manager"))
        XCTAssertTrue(msg.lowercased().contains("target"))
    }

    // MARK: - Attached-skill case

    /// The one attached-skill case must name the role and surface the dangling skill id — the
    /// id is the only handle the user has to find and detach the attachment.
    func testUnknownAttachedSkill_message_namesRole_andIncludesSkillID() {
        let team = makeTeam(roles: [role(id: "pm", name: "Product Manager")])
        let msg = TeamValidationService.ValidationError
            .unknownAttachedSkill(roleID: "pm", skillID: "skills/ghost-skill").displayMessage(in: team)

        XCTAssertTrue(msg.contains("Product Manager"))
        XCTAssertTrue(msg.contains("skills/ghost-skill"), "Must surface the dangling skill id so the user can find/detach it. Got: \(msg)")
        XCTAssertTrue(msg.lowercased().contains("skill"))
    }

    // MARK: - Integration: every emitted policy issue renders a role-named message

    /// Guards the bridge against the real validator output: a delegator that is
    /// non-top-level AND self-delegating AND points at an unknown team produces
    /// several `ValidationError`s — every one must render a non-empty message
    /// that names the offending role, so the banner never shows a blank row.
    func testValidateDelegationPolicy_everyEmittedIssue_rendersRoleNamedMessage() {
        let agent = TeamRoleDefinition(
            id: "agent", name: "Coding Agent", prompt: "a",
            toolIDs: [ToolNames.delegateToTeam], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["team-A", "team-zzz"],  // self + unknown
            allowDelegationToGeneratedTeams: false
        )
        var settings = TeamSettings()
        settings.hierarchy.reportsTo = ["agent": "sup"]  // non-top-level
        let team = Team(
            id: "team-A", name: "T",
            roles: [supervisor(), agent], artifacts: [],
            settings: settings, graphLayout: TeamGraphLayout()
        )

        let issues = TeamValidationService.validateDelegationPolicy(team: team, allTeams: [team])
        XCTAssertFalse(issues.isEmpty, "This misconfiguration must produce validation issues.")
        for issue in issues {
            let msg = issue.displayMessage(in: team)
            XCTAssertFalse(msg.isEmpty, "Issue \(issue) rendered a blank banner message.")
            XCTAssertTrue(msg.contains("Coding Agent"), "Issue \(issue) message must name the role. Got: \(msg)")
        }
    }
}
