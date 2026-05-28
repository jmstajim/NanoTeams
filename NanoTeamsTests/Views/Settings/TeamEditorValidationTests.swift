import XCTest
@testable import NanoTeams

/// Coverage for `TeamEditorValidation.issues(team:allTeams:)` — the pure builder
/// behind the Team Editor's validation banner. Pins the severity mapping
/// (structural → error, delegation → forwarded severity) and the deliberate
/// scope (delegation + structural only; dependency/orphan checks excluded).
final class TeamEditorValidationTests: XCTestCase {

    // MARK: - Fixtures

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
        name: String = "Team",
        roles: [TeamRoleDefinition],
        reportsTo: [String: String] = [:]
    ) -> Team {
        var settings = TeamSettings()
        settings.hierarchy.reportsTo = reportsTo
        return Team(
            id: id, name: name,
            roles: roles, artifacts: [],
            settings: settings, graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - Structural issues render as errors

    func testStructuralIssues_renderAsErrors() {
        // No roles + blank name → both structural checks fire, both as errors.
        let team = makeTeam(name: "   ", roles: [])
        let issues = TeamEditorValidation.issues(team: team, allTeams: [team])

        XCTAssertEqual(issues.count, 2, "Expected noRoles + emptyName.")
        XCTAssertTrue(issues.allSatisfy(\.isError), "Structural issues must render as errors.")
        XCTAssertTrue(issues.allSatisfy { !$0.message.isEmpty })
    }

    // MARK: - Delegation severity is forwarded

    func testDelegationError_rendersAsErrorIssue_namingRole() {
        // Non-peer delegator (reports to Supervisor) → nonTopLevelDelegator (error).
        let agent = TeamRoleDefinition(
            id: "agent", name: "Coding Agent", prompt: "a",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowDelegationToGeneratedTeams: true  // configured → enters validation
        )
        let team = makeTeam(roles: [supervisor(), agent], reportsTo: ["agent": "sup"])
        let issues = TeamEditorValidation.issues(team: team, allTeams: [team])

        let errors = issues.filter(\.isError)
        XCTAssertTrue(errors.contains { $0.message.contains("Coding Agent") },
            "A non-peer delegator must surface an error-severity issue naming the role.")
    }

    func testDelegationWarning_rendersAsWarningIssue() {
        // Peer-level delegator whose only whitelist entry is unknown, generated off
        // → unknownDelegationTeam + noDelegationTargets, both warnings, no errors.
        let agent = TeamRoleDefinition(
            id: "agent", name: "Coding Agent", prompt: "a",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["ghost-team"],
            allowDelegationToGeneratedTeams: false
        )
        let team = makeTeam(roles: [supervisor(), agent], reportsTo: [:])
        let issues = TeamEditorValidation.issues(team: team, allTeams: [team])

        XCTAssertFalse(issues.isEmpty, "An unknown delegation target must surface something.")
        XCTAssertTrue(issues.allSatisfy { !$0.isError },
            "unknownDelegationTeam / noDelegationTargets are warnings — severity must be forwarded, not forced to error.")
    }

    // MARK: - Scope: dependency/orphan checks are NOT surfaced

    func testDependencyIssues_areNotSurfacedInBanner() {
        // A role requiring an artifact no one produces is a genuine dependency
        // error — but the editor banner intentionally only shows structural +
        // delegation issues, never dependency/orphan ones.
        let engineer = TeamRoleDefinition(
            id: "swe", name: "Engineer", prompt: "p",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Nonexistent Plan"], producesArtifacts: ["Notes"])
        )
        let team = makeTeam(roles: [engineer])  // non-empty name + role → no structural; not a delegator

        let bannerIssues = TeamEditorValidation.issues(team: team, allTeams: [team])
        XCTAssertTrue(bannerIssues.isEmpty,
            "Dependency/orphan issues must NOT appear in the editor banner.")

        // Sanity: the dependency issue genuinely exists — it's deliberately excluded,
        // not absent. (missingProducer is an error in the full validator.)
        let full = TeamValidationService.validate(roleDefinitions: team.roles)
        XCTAssertFalse(full.errors.isEmpty,
            "Precondition: the team really does have a dependency error that the banner suppresses.")
    }
}
