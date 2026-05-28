import XCTest
@testable import NanoTeams

/// Pins the gating contract on `LLMExecutionService+ToolResolution` step #7:
/// the 4-tool delegation pack (delegate_to_team + cancel/resume/forward)
/// auto-injects into the LLM schema iff `Team.delegationEnabled(for:)` is true —
/// settings populated AND role peer-level with Supervisor.
/// `delegate_to_team`'s schema is built per-role via
/// `DelegateToTeamTool.buildSchema(role:allTeams:)` so the team catalog is
/// embedded inline in the description (replaces the legacy `list_teams` tool).
///
/// Direct integration with `LLMExecutionService.toolSchemas(for:team:)` would
/// require a full stubbed delegate; we exercise the same predicate the auto-
/// injection guard uses. The role-level helper-level slice is covered by
/// `DelegationFollowupToolsTests`.
@MainActor
final class ToolSchemasDelegationGatingTests: XCTestCase {

    // MARK: - Test helpers

    private func makeSupervisor() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "supervisor"
        )
    }

    private func makeAgent(
        whitelist: [NTMSID] = [],
        generated: Bool = false,
        toolIDs: [String] = []
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "agent", name: "Agent", prompt: "",
            toolIDs: toolIDs,
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: whitelist,
            allowDelegationToGeneratedTeams: generated
        )
    }

    private func makeTeam(_ roles: [TeamRoleDefinition], reportsTo: [String: String] = [:]) -> Team {
        var settings = TeamSettings()
        settings.hierarchy.reportsTo = reportsTo
        return Team(
            id: "team", name: "Team",
            roles: roles,
            artifacts: [],
            settings: settings,
            graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - Gating

    /// Empty whitelist + generated off → the auto-injection guard must NOT fire.
    func testDelegationEnabled_falseWhenNoTargets() {
        let agent = makeAgent()
        let team = makeTeam([makeSupervisor(), agent])
        XCTAssertFalse(team.delegationEnabled(for: agent),
            "No whitelist + generated off → no auto-injection.")
    }

    /// One whitelist entry, generated off → predicate fires.
    func testDelegationEnabled_trueWithSingleWhitelistEntry() {
        let agent = makeAgent(whitelist: ["other-team"])
        let team = makeTeam([makeSupervisor(), agent])
        XCTAssertTrue(team.delegationEnabled(for: agent))
    }

    /// Empty whitelist + generated on → predicate fires.
    func testDelegationEnabled_trueWithGeneratedOnly() {
        let agent = makeAgent(generated: true)
        let team = makeTeam([makeSupervisor(), agent])
        XCTAssertTrue(team.delegationEnabled(for: agent))
    }

    /// Subordinate role with delegation settings → predicate must NOT fire.
    /// This is the regression that the role-editor save handler is designed
    /// to prevent (clears `reportsTo` when delegation is enabled), but the
    /// runtime gate must hold even if `reportsTo` somehow remains.
    func testDelegationEnabled_falseForSubordinateEvenWithSettings() {
        let agent = makeAgent(whitelist: ["other-team"], generated: true)
        let team = makeTeam(
            [makeSupervisor(), agent],
            reportsTo: ["agent": "sup"]
        )
        XCTAssertFalse(team.delegationEnabled(for: agent),
            "Subordinate role must not auto-inject delegation tools — peer status is the structural half.")
    }

    /// Legacy `delegate_to_team` in `toolIDs` with no settings → still no
    /// auto-injection. The settings drive, the toolset is irrelevant noise
    /// (and gets stripped by migration on next load).
    func testDelegationEnabled_falseEvenWithLegacyToolIDPresent() {
        let agent = makeAgent(toolIDs: [ToolNames.delegateToTeam])
        let team = makeTeam([makeSupervisor(), agent])
        XCTAssertFalse(team.delegationEnabled(for: agent),
            "Legacy toolID is no longer the trigger — settings are the single source of truth.")
    }

    // MARK: - Inline team catalog (replaces `list_teams`)

    /// Helper: builds a team that is NOT in chat mode — it has a Supervisor
    /// with a required artifact, so `supervisorRequiredArtifacts` is non-empty
    /// and the catalog filter (chat-mode-excluded) lets it through.
    private func makeNonChatTeam(id: NTMSID, name: String, description: String) -> Team {
        var supervisorDeps = RoleDependencies()
        supervisorDeps.requiredArtifacts = ["Final Deliverable"]
        let supervisor = TeamRoleDefinition(
            id: "sup-\(id)", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: supervisorDeps,
            isSystemRole: true, systemRoleID: "supervisor"
        )
        return Team(
            id: id, name: name, description: description,
            roles: [supervisor], artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
    }

    /// Whitelist intersection — `delegate_to_team`'s description must mention
    /// every whitelisted team that exists in `allTeams`. Replaces the catalog
    /// the deleted `list_teams` tool used to surface.
    func testBuildSchema_descriptionContainsAllowedTeamNames() {
        let alpha = makeNonChatTeam(id: "alpha-id", name: "Alpha Team", description: "A specialist team")
        let beta = makeNonChatTeam(id: "beta-id", name: "Beta Team", description: "")
        let gamma = makeNonChatTeam(id: "gamma-id", name: "Gamma Team", description: "Not in whitelist")
        let role = makeAgent(whitelist: ["alpha-id", "beta-id"])
        let schema = DelegateToTeamTool.buildSchema(role: role, allTeams: [alpha, beta, gamma])
        XCTAssertTrue(schema.description.contains("Alpha Team"),
                      "Whitelisted team must appear in the inline catalog")
        XCTAssertTrue(schema.description.contains("Beta Team"),
                      "Whitelisted team must appear (even with empty description)")
        XCTAssertFalse(schema.description.contains("Gamma Team"),
                       "Non-whitelisted team must NOT appear in the inline catalog")
    }

    /// Generated sentinel bullet appears iff `allowDelegationToGeneratedTeams` is true.
    /// Word "generated" appears in the base description regardless (as part of the
    /// "defaults to 'generated'" guidance), so the assertion must look for the
    /// bullet-line shape `` - `generated` `` to disambiguate.
    func testBuildSchema_generatedSentinelGatedByPolicy() {
        let sentinelBullet = "- `\(DelegationConstants.generatedTeamSentinel)`"
        let role = makeAgent(generated: true)
        let schemaWithGenerated = DelegateToTeamTool.buildSchema(role: role, allTeams: [])
        XCTAssertTrue(schemaWithGenerated.description.contains(sentinelBullet),
                      "Generated sentinel bullet must appear when allowDelegationToGeneratedTeams=true")

        let roleNoGenerated = makeAgent(whitelist: [])
        let schemaWithoutGenerated = DelegateToTeamTool.buildSchema(role: roleNoGenerated, allTeams: [])
        XCTAssertFalse(schemaWithoutGenerated.description.contains(sentinelBullet),
                       "Generated sentinel bullet must be absent when allowDelegationToGeneratedTeams=false")
    }

    /// Chat-mode teams are excluded from the catalog — they have no
    /// completion criterion (no required artifacts), so delegating to them
    /// would block forever. Same rule the deleted `list_teams` enforced.
    func testBuildSchema_chatModeTeamExcluded() {
        let chatTeam = Team(id: "chat-id", name: "Chat Team", description: "Chat-mode",
                            roles: [], artifacts: [],
                            settings: TeamSettings(),
                            graphLayout: TeamGraphLayout())
        // Chat mode is derived from supervisorRequiredArtifacts being empty;
        // verify before asserting.
        XCTAssertTrue(chatTeam.isChatMode)
        let role = makeAgent(whitelist: ["chat-id"])
        let schema = DelegateToTeamTool.buildSchema(role: role, allTeams: [chatTeam])
        XCTAssertFalse(schema.description.contains("Chat Team"),
                       "Chat-mode teams must be excluded from the inline catalog")
    }
}
