import XCTest
@testable import NanoTeams

/// Pins `Run.activeWorkRoleIDs` / `activeWorkRoles` — the shared "is this team finished"
/// predicate behind `TeamEngine.allRolesComplete` and the Autovisor's chat-task close.
final class RunActiveWorkRolesTests: XCTestCase {

    override func setUp() { super.setUp(); MonotonicClock.shared.reset() }
    override func tearDown() { MonotonicClock.shared.reset(); super.tearDown() }

    private func def(
        _ id: String,
        name: String? = nil,
        required: [String] = [],
        produces: [String] = [],
        systemRoleID: String? = nil
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name ?? id, prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: required, producesArtifacts: produces),
            systemRoleID: systemRoleID
        )
    }

    func testActiveWorkRoleIDs_excludesSupervisorAndObservers() {
        let defs = [
            def("sup", systemRoleID: "supervisor"),   // supervisor
            def("obs"),                                // observer (no in/out)
            def("worker", produces: ["A"]),            // producing
        ]
        let statuses: [String: RoleExecutionStatus] = ["sup": .idle, "obs": .idle, "worker": .working]
        XCTAssertEqual(Run.activeWorkRoleIDs(roleStatuses: statuses, definitions: defs), ["worker"])
    }

    func testActiveWorkRoleIDs_missingStatusCountsAsActive() {
        let defs = [def("worker", produces: ["A"])]
        XCTAssertEqual(
            Run.activeWorkRoleIDs(roleStatuses: [:], definitions: defs), ["worker"],
            "a role with no status entry defaults to .idle → active"
        )
    }

    func testActiveWorkRoleIDs_failedRoleCountsAsActive() {
        let defs = [def("worker", produces: ["A"])]
        XCTAssertEqual(
            Run.activeWorkRoleIDs(roleStatuses: ["worker": .failed], definitions: defs), ["worker"],
            ".failed is not isComplete → active (correctly blocks a chat close)"
        )
    }

    func testActiveWorkRoleIDs_allTerminalReturnsEmpty() {
        let defs = [def("a", produces: ["A"]), def("b", produces: ["B"]), def("c", produces: ["C"])]
        let statuses: [String: RoleExecutionStatus] = ["a": .done, "b": .accepted, "c": .skipped]
        XCTAssertTrue(Run.activeWorkRoleIDs(roleStatuses: statuses, definitions: defs).isEmpty)
    }

    func testActiveWorkRoles_sortedByRoleName() {
        // ids sort opposite to names — proves the sort key is the display name.
        let defs = [
            def("z-id", name: "Alpha", produces: ["A"]),
            def("a-id", name: "Zeta", produces: ["B"]),
        ]
        let run = Run(id: 0, steps: [], roleStatuses: ["z-id": .working, "a-id": .working])
        XCTAssertEqual(run.activeWorkRoles(definitions: defs).map(\.roleName), ["Alpha", "Zeta"])
    }
}
