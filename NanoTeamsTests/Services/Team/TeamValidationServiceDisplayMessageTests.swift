import XCTest
@testable import NanoTeams

/// Coverage for `TeamValidationService.ValidationError.displayMessage(in:)` —
/// the human-readable bridge that surfaces validation issues (delegation +
/// dependency) in the Team Editor banner. Each message must resolve role IDs to
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

    // MARK: - Dependency cases

    func testMissingProducer_message_namesRequiringRole_andArtifact() {
        let team = makeTeam(roles: [role(id: "swe", name: "Engineer")])
        let msg = TeamValidationService.ValidationError
            .missingProducer(artifact: "Implementation Plan", requiredBy: "swe").displayMessage(in: team)

        XCTAssertTrue(msg.contains("Engineer"))
        XCTAssertTrue(msg.contains("Implementation Plan"))
    }

    func testDuplicateProducer_message_listsAllRoleNames() {
        let team = makeTeam(roles: [role(id: "a", name: "Alpha"), role(id: "b", name: "Beta")])
        let msg = TeamValidationService.ValidationError
            .duplicateProducer(artifact: "Design Spec", roleIDs: ["a", "b"]).displayMessage(in: team)

        XCTAssertTrue(msg.contains("Design Spec"))
        XCTAssertTrue(msg.contains("Alpha"))
        XCTAssertTrue(msg.contains("Beta"))
    }

    func testCircularDependency_message_joinsRoleNamesAsChain() {
        let team = makeTeam(roles: [role(id: "a", name: "Alpha"), role(id: "b", name: "Beta")])
        let msg = TeamValidationService.ValidationError
            .circularDependency(roleIDs: ["a", "b", "a"]).displayMessage(in: team)

        XCTAssertTrue(msg.contains("Alpha → Beta → Alpha"), "Chain must render resolved names joined by arrows. Got: \(msg)")
    }

    func testOrphanArtifact_message_namesProducer_andArtifact() {
        let team = makeTeam(roles: [role(id: "a", name: "Alpha")])
        let msg = TeamValidationService.ValidationError
            .orphanArtifact(artifact: "Engineering Notes", producedBy: "a").displayMessage(in: team)

        XCTAssertTrue(msg.contains("Alpha"))
        XCTAssertTrue(msg.contains("Engineering Notes"))
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
