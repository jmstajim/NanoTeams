import XCTest

@testable import NanoTeams

/// E2E tests for complex artifact dependency graphs:
/// diamond, chain, fan-out, orphan, and transitive downstream discovery.
@MainActor
final class EndToEndArtifactDependencyGraphTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Diamond graph readiness progression

    func testDiamond_readinessProgression() {
        // A → {B, C} → D
        // A produces "Goal", B requires "Goal" produces "Design",
        // C requires "Goal" produces "Plan", D requires "Design" AND "Plan"
        let roles = [
            makeRole(id: "A", required: [], produces: ["Goal"]),
            makeRole(id: "B", required: ["Goal"], produces: ["Design"]),
            makeRole(id: "C", required: ["Goal"], produces: ["Plan"]),
            makeRole(id: "D", required: ["Design", "Plan"], produces: ["Final"]),
        ]

        // Initially: only A is ready (no dependencies)
        var produced: Set<String> = []
        var ready = ArtifactDependencyResolver.findReadyRoles(roles: roles, producedArtifacts: produced)
        XCTAssertEqual(Set(ready), Set(["A"]), "Initially only A should be ready")

        // A completes → B and C both ready
        produced.insert("Goal")
        ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles, producedArtifacts: produced, excludeRoleIDs: ["A"]
        )
        XCTAssertEqual(Set(ready), Set(["B", "C"]), "After A, both B and C should be ready")

        // B completes → D still not ready (needs Plan from C)
        produced.insert("Design")
        ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles, producedArtifacts: produced, excludeRoleIDs: ["A", "B"]
        )
        XCTAssertEqual(Set(ready), Set(["C"]), "D should NOT be ready until C completes")

        // C completes → D now ready
        produced.insert("Plan")
        ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles, producedArtifacts: produced, excludeRoleIDs: ["A", "B", "C"]
        )
        XCTAssertEqual(Set(ready), Set(["D"]), "D should be ready after both B and C complete")
    }

    // MARK: - Test 2: Long chain — sequential only

    func testLongChain_sequential() {
        // A → B → C → D → E
        let roles = [
            makeRole(id: "A", required: [], produces: ["Art-A"]),
            makeRole(id: "B", required: ["Art-A"], produces: ["Art-B"]),
            makeRole(id: "C", required: ["Art-B"], produces: ["Art-C"]),
            makeRole(id: "D", required: ["Art-C"], produces: ["Art-D"]),
            makeRole(id: "E", required: ["Art-D"], produces: ["Art-E"]),
        ]

        var produced: Set<String> = []
        var done: Set<String> = []

        // Only one role ready at each stage
        for (i, role) in roles.enumerated() {
            let ready = ArtifactDependencyResolver.findReadyRoles(
                roles: roles, producedArtifacts: produced, excludeRoleIDs: done
            )
            XCTAssertEqual(ready.count, 1, "Stage \(i): exactly one role should be ready")
            XCTAssertEqual(ready.first, role.id, "Stage \(i): \(role.id) should be ready")

            done.insert(role.id)
            for artifact in role.dependencies.producesArtifacts {
                produced.insert(artifact)
            }
        }
    }

    // MARK: - Test 3: Fan-out — all parallel after root

    func testFanOut_allParallelAfterRoot() {
        // A → {B, C, D, E}
        let roles = [
            makeRole(id: "A", required: [], produces: ["Root"]),
            makeRole(id: "B", required: ["Root"], produces: ["B-Out"]),
            makeRole(id: "C", required: ["Root"], produces: ["C-Out"]),
            makeRole(id: "D", required: ["Root"], produces: ["D-Out"]),
            makeRole(id: "E", required: ["Root"], produces: ["E-Out"]),
        ]

        // Initially: only A
        var ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles, producedArtifacts: []
        )
        XCTAssertEqual(Set(ready), Set(["A"]))

        // A done: all 4 children ready in parallel
        ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles, producedArtifacts: ["Root"], excludeRoleIDs: ["A"]
        )
        XCTAssertEqual(Set(ready), Set(["B", "C", "D", "E"]),
                       "All children should be ready after root completes")
    }

    // MARK: - Test 4: Orphan role — always ready, never blocks

    func testOrphanRole_alwaysReady_neverBlocks() {
        let roles = [
            makeRole(id: "A", required: [], produces: ["Goal"]),
            makeRole(id: "B", required: ["Goal"], produces: ["Plan"]),
            makeRole(id: "Orphan", required: [], produces: ["Metrics"]), // nobody requires Metrics
        ]

        // Initially: both A and Orphan are ready (no deps)
        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles, producedArtifacts: []
        )
        XCTAssertTrue(ready.contains("A"))
        XCTAssertTrue(ready.contains("Orphan"),
                      "Orphan with no dependencies should always be ready")

        // Orphan should not block B
        let readyAfterA = ArtifactDependencyResolver.findReadyRoles(
            roles: roles, producedArtifacts: ["Goal"], excludeRoleIDs: ["A"]
        )
        XCTAssertTrue(readyAfterA.contains("B"),
                      "B should be ready after A, regardless of Orphan status")
    }

    // MARK: - Test 5: Transitive downstream discovery

    func testDownstreamRoles_transitiveDiscovery() {
        // A produces "X" → B requires "X" produces "Y" → C requires "Y" produces "Z" → D requires "Z"
        let roles = [
            makeRole(id: "A", required: [], produces: ["X"]),
            makeRole(id: "B", required: ["X"], produces: ["Y"]),
            makeRole(id: "C", required: ["Y"], produces: ["Z"]),
            makeRole(id: "D", required: ["Z"], produces: ["Final"]),
        ]

        let resolver = ArtifactDependencyResolver(roles: roles)

        // All downstream of A
        let downstreamA = resolver.getDownstreamRoles(of: "A")
        XCTAssertEqual(downstreamA, Set(["B", "C", "D"]),
                       "A's downstream should include all transitive dependents")

        // Downstream of C
        let downstreamC = resolver.getDownstreamRoles(of: "C")
        XCTAssertEqual(downstreamC, Set(["D"]),
                       "C's downstream should only include D")

        // Downstream of D (leaf node)
        let downstreamD = resolver.getDownstreamRoles(of: "D")
        XCTAssertTrue(downstreamD.isEmpty,
                      "Leaf node should have no downstream roles")
    }

    // MARK: - Test 6: Execution order (topological sort)

    func testExecutionOrder_validTopologicalSort() {
        let roles = [
            makeRole(id: "A", required: [], produces: ["X"]),
            makeRole(id: "B", required: ["X"], produces: ["Y"]),
            makeRole(id: "C", required: ["X"], produces: ["Z"]),
            makeRole(id: "D", required: ["Y", "Z"], produces: ["Final"]),
        ]

        let order = ArtifactDependencyResolver.getExecutionOrder(roles: roles)
        XCTAssertNotNil(order, "Should produce valid order for DAG")

        guard let order else { return }

        // A must come before B and C
        let posA = order.firstIndex(of: "A")!
        let posB = order.firstIndex(of: "B")!
        let posC = order.firstIndex(of: "C")!
        let posD = order.firstIndex(of: "D")!

        XCTAssertLessThan(posA, posB)
        XCTAssertLessThan(posA, posC)
        XCTAssertLessThan(posB, posD)
        XCTAssertLessThan(posC, posD)
    }

    // MARK: - Test 7: Circular dependency returns nil

    func testCircularDependency_returnsNilOrder() {
        // A requires B's output, B requires A's output — circular
        let roles = [
            makeRole(id: "A", required: ["B-Out"], produces: ["A-Out"]),
            makeRole(id: "B", required: ["A-Out"], produces: ["B-Out"]),
        ]

        let order = ArtifactDependencyResolver.getExecutionOrder(roles: roles)
        XCTAssertNil(order, "Circular dependency should return nil")
    }

    // MARK: - Helpers

    private func makeRole(
        id: String,
        required: [String],
        produces: [String]
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: "Role-\(id)",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: required,
                producesArtifacts: produces
            )
        )
    }
}
