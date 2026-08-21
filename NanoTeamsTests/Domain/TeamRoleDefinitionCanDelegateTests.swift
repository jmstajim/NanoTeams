import XCTest
@testable import NanoTeams

/// Truth table for `TeamRoleDefinition.hasDelegationConfigured` after the flip from
/// "delegate_to_team in toolIDs" to "any whitelist entry OR generated permission".
/// Pins the new semantics so a regression to the toolID-driven form is caught
/// at build time.
@MainActor
final class TeamRoleDefinitionCanDelegateTests: XCTestCase {

    private func makeRole(
        whitelist: [NTMSID] = [],
        generated: Bool = false,
        toolIDs: [String] = []
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "r", name: "R", prompt: "",
            toolIDs: toolIDs,
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: whitelist,
            allowDelegationToGeneratedTeams: generated
        )
    }

    func testEmptyWhitelist_generatedOff_isFalse() {
        XCTAssertFalse(makeRole().hasDelegationConfigured)
    }

    func testEmptyWhitelist_generatedOn_isTrue() {
        XCTAssertTrue(makeRole(generated: true).hasDelegationConfigured)
    }

    func testWhitelistPopulated_generatedOff_isTrue() {
        XCTAssertTrue(makeRole(whitelist: ["t1"]).hasDelegationConfigured)
    }

    func testWhitelistPopulated_generatedOn_isTrue() {
        XCTAssertTrue(makeRole(whitelist: ["t1"], generated: true).hasDelegationConfigured)
    }

    /// Regression: under the OLD semantics, this was the trigger. Under the
    /// new semantics, toolIDs membership is irrelevant — only settings matter.
    func testToolIDsContainsDelegateToTeam_butNoSettings_isFalse() {
        let role = makeRole(toolIDs: [ToolNames.delegateToTeam])
        XCTAssertFalse(role.hasDelegationConfigured,
                       "Old toolID-driven trigger must no longer apply.")
    }

    /// Whitelist + delegate_to_team in toolIDs (defensive double-config) still
    /// flips true via the settings half — the old toolID is irrelevant noise
    /// (and gets stripped by the migration on next load anyway).
    func testToolIDsContainsDelegateToTeam_andWhitelistPopulated_isTrue() {
        let role = makeRole(whitelist: ["t1"], toolIDs: [ToolNames.delegateToTeam])
        XCTAssertTrue(role.hasDelegationConfigured)
    }

    /// `Team.delegationEnabled(for:)` combines peer-status with settings.
    /// Without peer status, the predicate must return false even when settings
    /// are populated — gates the auto-injection so a subordinate role doesn't
    /// receive delegation tools.
    func testDelegationEnabled_requiresBothPeerStatusAndSettings() {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "S", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "supervisor"
        )
        let subordinate = TeamRoleDefinition(
            id: "sub", name: "Sub", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["t"]
        )
        let peer = TeamRoleDefinition(
            id: "peer", name: "Peer", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["t"]
        )
        var settings = TeamSettings()
        settings.hierarchy.reportsTo = ["sub": "sup"] // sub is subordinate; peer is unwired
        let team = Team(
            id: "t", name: "T",
            roles: [supervisor, subordinate, peer],
            artifacts: [],
            settings: settings,
            graphLayout: TeamGraphLayout()
        )
        XCTAssertFalse(team.delegationEnabled(for: subordinate),
                       "Subordinate role must not delegate even with settings — peer-status is the gate.")
        XCTAssertTrue(team.delegationEnabled(for: peer),
                      "Peer role with settings populated → delegation enabled.")
    }
}
