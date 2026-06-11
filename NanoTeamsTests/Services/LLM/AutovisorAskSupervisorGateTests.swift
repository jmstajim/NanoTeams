import XCTest

@testable import NanoTeams

/// The Autovisor IS the top Supervisor — it must NOT get `ask_supervisor`
/// auto-injected into its LLM schema. Under autonomous mode the manager's own
/// `ask_supervisor` would just be auto-answered in a self-loop; the human steers
/// it by messaging it instead. Every other advisory/non-producing role still gets
/// `ask_supervisor` auto-injected.
///
/// Drives the pure `LLMExecutionService.resolveToolSchemas` (no delegate needed —
/// the instance `toolSchemas` shim early-returns `[]` without one).
final class AutovisorAskSupervisorGateTests: XCTestCase {

    func testManagerTeam_doesNotAutoInjectAskSupervisor() {
        let team = TeamTemplateFactory.autovisor()
        let managerName = team.nonSupervisorRoles.first?.name ?? "Manager"
        let schemas = LLMExecutionService.resolveToolSchemas(for: .custom(id: managerName), team: team)
        XCTAssertFalse(
            schemas.isEmpty,
            "sanity: the manager still resolves its management toolset"
        )
        XCTAssertFalse(
            schemas.contains { $0.name == ToolNames.askSupervisor },
            "the Autovisor must not get ask_supervisor auto-injected (it is the top Supervisor)"
        )
    }

    func testNormalAdvisoryRole_stillAutoInjectsAskSupervisor() {
        // Minimal non-manager chat team with an advisory role (input dep, no outputs).
        let advisory = TeamRoleDefinition(
            id: "assistant", name: "Assistant", prompt: "", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"], producesArtifacts: []),
            isSystemRole: true, systemRoleID: "assistant"
        )
        let team = Team(
            id: "t", name: "T", roles: [advisory], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        let schemas = LLMExecutionService.resolveToolSchemas(for: .custom(id: "Assistant"), team: team)
        XCTAssertTrue(
            schemas.contains { $0.name == ToolNames.askSupervisor },
            "a normal advisory role must still get ask_supervisor auto-injected"
        )
    }
}
