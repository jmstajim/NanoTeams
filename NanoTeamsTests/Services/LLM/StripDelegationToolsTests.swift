import XCTest
@testable import NanoTeams

/// User-reported V1 bug: teams synthesized via `delegate_to_team(team_id: "generated", ...)`
/// were ending up with `delegate_to_team` (and the legacy `list_teams`) in
/// role toolsets, allowing them to spawn grandchildren and pushing depth past
/// the practical 1-level the user expects. The fix strips delegation-related
/// tools (and per-role delegation whitelist + generated-team allowance) from
/// generated teams at the source — `LLMExecutionService.stripDelegationTools(from:)` —
/// so the team is structurally terminal regardless of what the team-generator
/// LLM emitted in `tools`. The legacy `"list_teams"` literal is also scrubbed
/// (the tool was removed; the catalog is now embedded inline in
/// `delegate_to_team`'s description).
@MainActor
final class StripDelegationToolsTests: XCTestCase {

    private func makeService() -> LLMExecutionService {
        LLMExecutionService(repository: NTMSRepository())
    }

    private func makeRole(id: String, name: String, tools: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, icon: "person", prompt: "", toolIDs: tools,
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
    }

    private func makeTeam(roles: [TeamRoleDefinition]) -> Team {
        Team(
            id: "test_team", name: "Test", description: "",
            roles: roles, artifacts: [],
            settings: .default, graphLayout: .default
        )
    }

    func testStripDelegationTools_removesDelegateToTeam() {
        let role = makeRole(id: "r1", name: "Engineer", tools: [
            ToolNames.readFile, ToolNames.delegateToTeam, ToolNames.writeFile
        ])
        let stripped = makeService().stripDelegationTools(from: makeTeam(roles: [role]))
        XCTAssertEqual(stripped.roles.count, 1)
        XCTAssertFalse(stripped.roles[0].toolIDs.contains(ToolNames.delegateToTeam),
                       "delegate_to_team must be removed from generated team roles")
        XCTAssertTrue(stripped.roles[0].toolIDs.contains(ToolNames.readFile),
                      "Non-delegation tools must be preserved")
    }

    func testStripDelegationTools_removesLegacyListTeamsLiteral() {
        // `list_teams` was removed (catalog now inline in delegate_to_team
        // description) but legacy `teams.json` and small-model emissions may
        // still carry the name. Hardcoded literal — the constant is gone.
        let role = makeRole(id: "r1", name: "Engineer", tools: [
            "list_teams", ToolNames.search
        ])
        let stripped = makeService().stripDelegationTools(from: makeTeam(roles: [role]))
        XCTAssertFalse(stripped.roles[0].toolIDs.contains("list_teams"),
                       "Legacy list_teams literal must be scrubbed from generated team toolsets")
        XCTAssertTrue(stripped.roles[0].toolIDs.contains(ToolNames.search))
    }

    func testStripDelegationTools_clearsAllowedDelegationTeamIDs() {
        var role = makeRole(id: "r1", name: "Engineer", tools: [ToolNames.readFile])
        role.allowedDelegationTeamIDs = ["someTeam"]
        role.allowDelegationToGeneratedTeams = true
        let stripped = makeService().stripDelegationTools(from: makeTeam(roles: [role]))
        XCTAssertTrue(stripped.roles[0].allowedDelegationTeamIDs.isEmpty,
                       "Generated team must not carry per-role delegation whitelists")
        XCTAssertFalse(stripped.roles[0].allowDelegationToGeneratedTeams,
                       "Generated team must not be allowed to chain-generate further teams")
    }

    func testStripDelegationTools_appliesToAllRoles() {
        let r1 = makeRole(id: "r1", name: "A", tools: [ToolNames.delegateToTeam, ToolNames.readFile])
        let r2 = makeRole(id: "r2", name: "B", tools: ["list_teams", ToolNames.writeFile])
        let r3 = makeRole(id: "r3", name: "C", tools: [ToolNames.search])
        let stripped = makeService().stripDelegationTools(from: makeTeam(roles: [r1, r2, r3]))
        for role in stripped.roles {
            XCTAssertFalse(role.toolIDs.contains(ToolNames.delegateToTeam))
            XCTAssertFalse(role.toolIDs.contains("list_teams"))
        }
        XCTAssertEqual(stripped.roles[0].toolIDs, [ToolNames.readFile])
        XCTAssertEqual(stripped.roles[1].toolIDs, [ToolNames.writeFile])
        XCTAssertEqual(stripped.roles[2].toolIDs, [ToolNames.search])
    }

    func testStripDelegationTools_noOpWhenNoDelegationTools() {
        let role = makeRole(id: "r1", name: "Engineer", tools: [
            ToolNames.readFile, ToolNames.writeFile
        ])
        let original = makeTeam(roles: [role])
        let stripped = makeService().stripDelegationTools(from: original)
        XCTAssertEqual(stripped.roles[0].toolIDs.sorted(), original.roles[0].toolIDs.sorted(),
                       "Tool list must be unchanged when no delegation tools are present")
    }

    // MARK: - Property: a stripped team can never delegate

    /// Whatever combination of role tools the team-generator LLM emits, the
    /// stripped result must satisfy: NO role in the team can pass
    /// `Team.roleIsTopLevelDelegator` (the predicate that gates `delegate_to_team`).
    /// This is the structural invariant that prevents depth-2+ chains —
    /// Bug 2 in the user report.
    func testStripDelegationTools_invariant_noRoleCanPassRoleIsTopLevelDelegator() {
        // Synthesize a team in the worst-case shape: every role has every
        // delegation-related capability turned on.
        var roles: [TeamRoleDefinition] = []
        for i in 0..<5 {
            var role = makeRole(id: "r\(i)", name: "Role\(i)", tools: [
                ToolNames.delegateToTeam, "list_teams", ToolNames.readFile
            ])
            role.allowedDelegationTeamIDs = ["someTeam"]
            role.allowDelegationToGeneratedTeams = true
            roles.append(role)
        }
        let team = makeTeam(roles: roles)
        let stripped = makeService().stripDelegationTools(from: team)

        for role in stripped.roles {
            XCTAssertFalse(
                role.toolIDs.contains(ToolNames.delegateToTeam),
                "Role \(role.name) still has delegate_to_team — would pass hasDelegationConfigured check"
            )
            XCTAssertFalse(
                role.hasDelegationConfigured,
                "Role \(role.name) still reports hasDelegationConfigured==true after strip"
            )
        }
    }

    /// User-curated existing teams (the non-generated branch of `delegate_to_team`)
    /// must NOT be stripped — only teams synthesized inside the delegation
    /// call are touched. This test pins the boundary: `stripDelegationTools`
    /// is a pure function the caller invokes only for the generated branch.
    func testStripDelegationTools_doesNotMutateInputTeam() {
        var role = makeRole(id: "r1", name: "Engineer", tools: [
            ToolNames.delegateToTeam, ToolNames.readFile
        ])
        role.allowedDelegationTeamIDs = ["a", "b"]
        role.allowDelegationToGeneratedTeams = true
        let team = makeTeam(roles: [role])
        let originalToolIDs = team.roles[0].toolIDs
        let originalAllowedIDs = team.roles[0].allowedDelegationTeamIDs
        let originalAllowGenerated = team.roles[0].allowDelegationToGeneratedTeams

        _ = makeService().stripDelegationTools(from: team)

        XCTAssertEqual(team.roles[0].toolIDs, originalToolIDs,
                       "Source team must not be mutated (Team is a value type — but verify defensively)")
        XCTAssertEqual(team.roles[0].allowedDelegationTeamIDs, originalAllowedIDs)
        XCTAssertEqual(team.roles[0].allowDelegationToGeneratedTeams, originalAllowGenerated)
    }
}
