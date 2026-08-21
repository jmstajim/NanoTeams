import XCTest
@testable import NanoTeams

/// Codable round-trip + helper-derivation guards for the delegation fields added
/// to `TeamRoleDefinition` (`allowedDelegationTeamIDs`, `allowDelegationToGeneratedTeams`)
/// and the matching `Team.roleIsTopLevelDelegator(_:)` helper.
@MainActor
final class TeamRoleDefinitionDelegationTests: XCTestCase {

    // MARK: - Codable round-trip

    func testRoundTrip_preservesDelegationFields() throws {
        // Note: delegate_to_team is no longer part of toolIDs — it auto-injects.
        // hasDelegationConfigured flips true via the whitelist (`allowedDelegationTeamIDs`).
        let role = TeamRoleDefinition(
            id: "pm",
            name: "Product Manager",
            prompt: "You are PM.",
            toolIDs: [ToolNames.askTeammate],
            usePlanningPhase: true,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Plan"]),
            allowedDelegationTeamIDs: ["team-A", "team-B"],
            allowDelegationToGeneratedTeams: true
        )
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let decoder = JSONCoderFactory.makeDateDecoder()
        let data = try encoder.encode(role)
        let decoded = try decoder.decode(TeamRoleDefinition.self, from: data)
        XCTAssertEqual(decoded.allowedDelegationTeamIDs, ["team-A", "team-B"])
        XCTAssertTrue(decoded.allowDelegationToGeneratedTeams)
        XCTAssertTrue(decoded.hasDelegationConfigured)
    }

    func testDecode_legacyJSON_defaultsToEmptyAndFalse() throws {
        let legacyJSON = """
        {
            "id": "pm",
            "name": "Product Manager",
            "icon": "person.fill",
            "prompt": "PM prompt",
            "toolIDs": [],
            "usePlanningPhase": true,
            "isSystemRole": false,
            "iconColor": "#FFFFFF",
            "iconBackground": "#007AFF",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONCoderFactory.makeDateDecoder()
        let role = try decoder.decode(TeamRoleDefinition.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(role.allowedDelegationTeamIDs, [])
        XCTAssertFalse(role.allowDelegationToGeneratedTeams)
        XCTAssertFalse(role.hasDelegationConfigured)
    }

    // MARK: - hasDelegationConfigured predicate

    /// Settings-driven: any whitelist entry OR generated permission flips it true.
    /// Adding `delegate_to_team` to `toolIDs` does NOT affect the predicate
    /// (those tools auto-inject from the same settings).
    func testCanDelegateToTeams_isSettingsDriven() {
        var role = TeamRoleDefinition(
            id: "x", name: "X", prompt: "P",
            toolIDs: [ToolNames.askSupervisor],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        XCTAssertFalse(role.hasDelegationConfigured)

        // Adding the tool to toolIDs does NOT affect the predicate any more.
        role.toolIDs.append(ToolNames.delegateToTeam)
        XCTAssertFalse(role.hasDelegationConfigured,
                       "Settings-driven: toolIDs membership is no longer the trigger.")

        // Adding a whitelist entry flips it true.
        role.allowedDelegationTeamIDs = ["team-A"]
        XCTAssertTrue(role.hasDelegationConfigured)

        // Removing the whitelist but keeping generated permission still flips true.
        role.allowedDelegationTeamIDs = []
        role.allowDelegationToGeneratedTeams = true
        XCTAssertTrue(role.hasDelegationConfigured)

        // Both off → false.
        role.allowDelegationToGeneratedTeams = false
        XCTAssertFalse(role.hasDelegationConfigured)
    }

    // MARK: - Team.roleIsTopLevelDelegator

    /// Peer-level rule: only roles with NO upstream `reportsTo` entry are
    /// delegation-eligible. A role wired to Supervisor (or anyone else) is
    /// subordinate, not peer, and must be rejected.
    func testRoleIsTopLevelDelegator_trueOnlyWhenPeerWithSupervisor() {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "supervisor"
        )
        // Peer with Supervisor — no reportsTo entry below. Delegation enabled
        // via settings (whitelist), since toolIDs no longer drives hasDelegationConfigured.
        let agent = TeamRoleDefinition(
            id: "agent", name: "Agent", prompt: "A",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["t"]
        )
        // Subordinate of Supervisor.
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "P",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["t"]
        )
        // Subordinate of PM (transitively under Supervisor).
        let engineer = TeamRoleDefinition(
            id: "eng", name: "Engineer", prompt: "E",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        var settings = TeamSettings()
        settings.hierarchy.reportsTo = ["pm": "sup", "eng": "pm"]
        let team = Team(
            id: "t", name: "T",
            roles: [supervisor, agent, pm, engineer],
            artifacts: [],
            settings: settings,
            graphLayout: TeamGraphLayout()
        )
        XCTAssertTrue(team.roleIsTopLevelDelegator(agent),
                      "Agent has no reportsTo entry — peer with Supervisor — eligible.")
        XCTAssertFalse(team.roleIsTopLevelDelegator(pm),
                       "PM reports to Supervisor — subordinate, not peer — must not be eligible.")
        XCTAssertFalse(team.roleIsTopLevelDelegator(engineer),
                       "Engineer reports to PM — must not be eligible.")
        XCTAssertFalse(team.roleIsTopLevelDelegator(supervisor),
                       "Supervisor itself is never a delegator.")
    }
}
