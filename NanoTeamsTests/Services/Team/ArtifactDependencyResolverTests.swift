//
//  ArtifactDependencyResolverTests.swift
//  NanoTeamsTests
//
//  Tests for ArtifactDependencyResolver — artifact-based role readiness,
//  execution ordering, and downstream dependency resolution.
//

import XCTest
@testable import NanoTeams

final class ArtifactDependencyResolverTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Helper

    /// Creates a minimal TeamRoleDefinition for testing.
    private func makeRole(
        id: String,
        name: String? = nil,
        requiredArtifacts: [String] = [],
        producesArtifacts: [String] = []
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name ?? id,
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requiredArtifacts,
                producesArtifacts: producesArtifacts
            )
        )
    }

    // MARK: - findReadyRoles

    func testFindReadyRoles_noDependencies_allReady() {
        let roles = [
            makeRole(id: "supervisor"),
            makeRole(id: "pm"),
            makeRole(id: "engineer")
        ]

        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles,
            producedArtifacts: []
        )

        XCTAssertEqual(Set(ready), Set(["supervisor", "pm", "engineer"]))
    }

    func testFindReadyRoles_withSatisfiedDeps() {
        let roles = [
            makeRole(id: "supervisor", producesArtifacts: ["Supervisor Task"]),
            makeRole(id: "pm", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Product Requirements"]),
            makeRole(id: "engineer", requiredArtifacts: ["Product Requirements"], producesArtifacts: ["Engineering Notes"])
        ]
        let produced: Set<String> = ["Supervisor Task", "Product Requirements"]

        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles,
            producedArtifacts: produced
        )

        XCTAssertTrue(ready.contains("supervisor"))
        XCTAssertTrue(ready.contains("pm"))
        XCTAssertTrue(ready.contains("engineer"))
    }

    func testFindReadyRoles_withUnsatisfiedDeps() {
        let roles = [
            makeRole(id: "supervisor", producesArtifacts: ["Supervisor Task"]),
            makeRole(id: "pm", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Product Requirements"]),
            makeRole(id: "engineer", requiredArtifacts: ["Product Requirements"], producesArtifacts: ["Engineering Notes"])
        ]
        let produced: Set<String> = ["Supervisor Task"]

        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles,
            producedArtifacts: produced
        )

        XCTAssertTrue(ready.contains("supervisor"))
        XCTAssertTrue(ready.contains("pm"))
        XCTAssertFalse(ready.contains("engineer"), "Engineer should not be ready — Product Requirements not yet produced")
    }

    func testFindReadyRoles_excludeIDs() {
        let roles = [
            makeRole(id: "supervisor"),
            makeRole(id: "pm"),
            makeRole(id: "engineer")
        ]
        let excluded: Set<String> = ["supervisor", "pm"]

        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles,
            producedArtifacts: [],
            excludeRoleIDs: excluded
        )

        XCTAssertEqual(ready, ["engineer"])
    }

    func testFindReadyRoles_emptyRolesArray() {
        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: [],
            producedArtifacts: ["Supervisor Task"]
        )

        XCTAssertTrue(ready.isEmpty)
    }

    func testFindReadyRoles_partialSatisfaction() {
        let roles = [
            makeRole(id: "engineer", requiredArtifacts: ["Product Requirements", "Design Spec"]),
            makeRole(id: "reviewer", requiredArtifacts: ["Engineering Notes"])
        ]
        // Only one of the engineer's two dependencies is met
        let produced: Set<String> = ["Product Requirements"]

        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: roles,
            producedArtifacts: produced
        )

        XCTAssertFalse(ready.contains("engineer"), "Engineer needs both Product Requirements AND Design Spec")
        XCTAssertFalse(ready.contains("reviewer"), "Reviewer needs Engineering Notes which is not produced")
    }

    // MARK: - getRoleReadiness

    func testGetRoleReadiness_unknownRoleID() {
        let roles = [makeRole(id: "pm")]

        let readiness = ArtifactDependencyResolver.getRoleReadiness(
            roleID: "nonexistent",
            roles: roles,
            producedArtifacts: []
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertTrue(readiness.missingArtifacts.isEmpty)
        XCTAssertTrue(readiness.satisfiedArtifacts.isEmpty)
        XCTAssertEqual(readiness.roleID, "nonexistent")
    }

    func testGetRoleReadiness_fullyReady() {
        let roles = [
            makeRole(id: "engineer", requiredArtifacts: ["Product Requirements", "Design Spec"])
        ]
        let produced: Set<String> = ["Product Requirements", "Design Spec"]

        let readiness = ArtifactDependencyResolver.getRoleReadiness(
            roleID: "engineer",
            roles: roles,
            producedArtifacts: produced
        )

        XCTAssertTrue(readiness.isReady)
        XCTAssertTrue(readiness.missingArtifacts.isEmpty)
        XCTAssertEqual(Set(readiness.satisfiedArtifacts), Set(["Product Requirements", "Design Spec"]))
        XCTAssertNil(readiness.blockingReason)
    }

    func testGetRoleReadiness_partiallyReady() {
        let roles = [
            makeRole(id: "engineer", requiredArtifacts: ["Product Requirements", "Design Spec", "Research Report"])
        ]
        let produced: Set<String> = ["Product Requirements"]

        let readiness = ArtifactDependencyResolver.getRoleReadiness(
            roleID: "engineer",
            roles: roles,
            producedArtifacts: produced
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.satisfiedArtifacts, ["Product Requirements"])
        XCTAssertEqual(Set(readiness.missingArtifacts), Set(["Design Spec", "Research Report"]))
    }

    func testGetRoleReadiness_blockingReason() {
        let roles = [
            makeRole(id: "engineer", requiredArtifacts: ["Product Requirements", "Design Spec"])
        ]

        let readiness = ArtifactDependencyResolver.getRoleReadiness(
            roleID: "engineer",
            roles: roles,
            producedArtifacts: []
        )

        XCTAssertFalse(readiness.isReady)
        let reason = readiness.blockingReason
        XCTAssertNotNil(reason)
        // The blocking reason should mention both missing artifacts
        XCTAssertTrue(reason!.contains("Product Requirements"), "Blocking reason should mention Product Requirements")
        XCTAssertTrue(reason!.contains("Design Spec"), "Blocking reason should mention Design Spec")
        XCTAssertTrue(reason!.hasPrefix("Waiting for: "), "Blocking reason should start with 'Waiting for: '")
    }

    // MARK: - getBlockingArtifacts

    func testGetBlockingArtifacts_returnsOnlyMissing() {
        let roles = [
            makeRole(id: "engineer", requiredArtifacts: ["Product Requirements", "Design Spec", "Research Report"])
        ]
        let produced: Set<String> = ["Product Requirements", "Research Report"]

        let blocking = ArtifactDependencyResolver.getBlockingArtifacts(
            for: "engineer",
            roles: roles,
            producedArtifacts: produced
        )

        XCTAssertEqual(blocking, ["Design Spec"])
    }

    // MARK: - getAllReadinessStates

    func testGetAllReadinessStates_returnsAllRoles() {
        let roles = [
            makeRole(id: "supervisor", producesArtifacts: ["Supervisor Task"]),
            makeRole(id: "pm", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Product Requirements"]),
            makeRole(id: "engineer", requiredArtifacts: ["Product Requirements"])
        ]
        let produced: Set<String> = ["Supervisor Task"]

        let states = ArtifactDependencyResolver.getAllReadinessStates(
            roles: roles,
            producedArtifacts: produced
        )

        XCTAssertEqual(states.count, 3)

        // Supervisor has no required artifacts — always ready
        XCTAssertTrue(states["supervisor"]!.isReady)

        // PM requires Supervisor Task which is produced — ready
        XCTAssertTrue(states["pm"]!.isReady)
        XCTAssertEqual(states["pm"]!.satisfiedArtifacts, ["Supervisor Task"])

        // Engineer requires Product Requirements which is NOT produced — blocked
        XCTAssertFalse(states["engineer"]!.isReady)
        XCTAssertEqual(states["engineer"]!.missingArtifacts, ["Product Requirements"])
    }

    // MARK: - getExecutionOrder

    func testGetExecutionOrder_linearChain() {
        let roles = [
            makeRole(id: "A", producesArtifacts: ["X"]),
            makeRole(id: "B", requiredArtifacts: ["X"], producesArtifacts: ["Y"]),
            makeRole(id: "C", requiredArtifacts: ["Y"], producesArtifacts: ["Z"])
        ]

        let order = ArtifactDependencyResolver.getExecutionOrder(roles: roles)

        XCTAssertNotNil(order)
        guard let order = order else { return }
        XCTAssertEqual(order.count, 3)

        // A must come before B, B must come before C
        let indexA = order.firstIndex(of: "A")!
        let indexB = order.firstIndex(of: "B")!
        let indexC = order.firstIndex(of: "C")!
        XCTAssertLessThan(indexA, indexB, "A must execute before B")
        XCTAssertLessThan(indexB, indexC, "B must execute before C")
    }

    func testGetExecutionOrder_diamondDependency() {
        // Diamond: A -> B, A -> C, B -> D, C -> D
        let roles = [
            makeRole(id: "A", producesArtifacts: ["X"]),
            makeRole(id: "B", requiredArtifacts: ["X"], producesArtifacts: ["Y"]),
            makeRole(id: "C", requiredArtifacts: ["X"], producesArtifacts: ["Z"]),
            makeRole(id: "D", requiredArtifacts: ["Y", "Z"])
        ]

        let order = ArtifactDependencyResolver.getExecutionOrder(roles: roles)

        XCTAssertNotNil(order)
        guard let order = order else { return }
        XCTAssertEqual(order.count, 4)

        let indexA = order.firstIndex(of: "A")!
        let indexB = order.firstIndex(of: "B")!
        let indexC = order.firstIndex(of: "C")!
        let indexD = order.firstIndex(of: "D")!

        XCTAssertLessThan(indexA, indexB, "A must execute before B")
        XCTAssertLessThan(indexA, indexC, "A must execute before C")
        XCTAssertLessThan(indexB, indexD, "B must execute before D")
        XCTAssertLessThan(indexC, indexD, "C must execute before D")
    }

    func testGetExecutionOrder_circularDependency_returnsNil() {
        // A needs Z (produced by C), B needs X (produced by A), C needs Y (produced by B)
        let roles = [
            makeRole(id: "A", requiredArtifacts: ["Z"], producesArtifacts: ["X"]),
            makeRole(id: "B", requiredArtifacts: ["X"], producesArtifacts: ["Y"]),
            makeRole(id: "C", requiredArtifacts: ["Y"], producesArtifacts: ["Z"])
        ]

        let order = ArtifactDependencyResolver.getExecutionOrder(roles: roles)

        XCTAssertNil(order, "Circular dependency should return nil")
    }

    func testGetExecutionOrder_noDependencies() {
        let roles = [
            makeRole(id: "A"),
            makeRole(id: "B"),
            makeRole(id: "C")
        ]

        let order = ArtifactDependencyResolver.getExecutionOrder(roles: roles)

        XCTAssertNotNil(order)
        guard let order = order else { return }
        XCTAssertEqual(Set(order), Set(["A", "B", "C"]))
        XCTAssertEqual(order.count, 3)
    }

    // MARK: - getDownstreamRoles

    func testGetDownstreamRoles_directDependents() {
        let roles = [
            makeRole(id: "A", producesArtifacts: ["X"]),
            makeRole(id: "B", requiredArtifacts: ["X"]),
            makeRole(id: "C", requiredArtifacts: ["X"]),
            makeRole(id: "D")
        ]

        let downstream = ArtifactDependencyResolver.getDownstreamRoles(
            of: "A",
            roles: roles
        )

        XCTAssertEqual(downstream, Set(["B", "C"]))
        XCTAssertFalse(downstream.contains("D"), "D does not depend on A")
        XCTAssertFalse(downstream.contains("A"), "A should not be its own downstream")
    }

    func testGetDownstreamRoles_transitiveDependents() {
        // A produces X, B needs X and produces Y, C needs Y
        let roles = [
            makeRole(id: "A", producesArtifacts: ["X"]),
            makeRole(id: "B", requiredArtifacts: ["X"], producesArtifacts: ["Y"]),
            makeRole(id: "C", requiredArtifacts: ["Y"])
        ]

        let downstream = ArtifactDependencyResolver.getDownstreamRoles(
            of: "A",
            roles: roles
        )

        XCTAssertEqual(downstream, Set(["B", "C"]), "Downstream of A should include B (direct) and C (transitive)")
    }

    func testGetDownstreamRoles_noDownstream() {
        let roles = [
            makeRole(id: "A"),
            makeRole(id: "B", producesArtifacts: ["X"]),
            makeRole(id: "C", requiredArtifacts: ["X"])
        ]

        let downstream = ArtifactDependencyResolver.getDownstreamRoles(
            of: "A",
            roles: roles
        )

        XCTAssertTrue(downstream.isEmpty, "A produces no artifacts so has no downstream roles")
    }

    func testGetDownstreamRoles_cyclesSafe() {
        // Artificial cycle: A produces X, B needs X and produces Y, C needs Y and produces X
        // The visited set should prevent infinite looping
        let roles = [
            makeRole(id: "A", producesArtifacts: ["X"]),
            makeRole(id: "B", requiredArtifacts: ["X"], producesArtifacts: ["Y"]),
            makeRole(id: "C", requiredArtifacts: ["Y"], producesArtifacts: ["X"])
        ]

        // This should not hang — the visited set breaks the cycle
        let downstream = ArtifactDependencyResolver.getDownstreamRoles(
            of: "A",
            roles: roles
        )

        // B depends on A's artifact X (direct), C depends on B's artifact Y (transitive)
        XCTAssertEqual(downstream, Set(["B", "C"]))
    }

    func testGetDownstreamRoles_excludesSupervisor_preventsCascade() {
        // Reproduces Bug #54: FAANG team cascade through Supervisor
        // SWE→CR→TPM→Supervisor→PM→UXR = whole team cascaded
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Release Notes"],
                producesArtifacts: ["Supervisor Task"]
            ),
            systemRoleID: "supervisor"
        )
        let roles = [
            supervisor,
            makeRole(id: "pm", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["PRD"]),
            makeRole(id: "tl", requiredArtifacts: ["PRD"], producesArtifacts: ["Plan"]),
            makeRole(id: "swe", requiredArtifacts: ["Plan"], producesArtifacts: ["Notes"]),
            makeRole(id: "cr", requiredArtifacts: ["Notes"], producesArtifacts: ["Review"]),
            makeRole(id: "tpm", requiredArtifacts: ["Review"], producesArtifacts: ["Release Notes"])
        ]

        let downstream = ArtifactDependencyResolver.getDownstreamRoles(
            of: "swe",
            roles: roles
        )

        // Only CR and TPM are downstream of SWE.
        // Supervisor should be excluded — traversing through it would cascade to PM, TL
        XCTAssertEqual(downstream, Set(["cr", "tpm"]))
        XCTAssertFalse(downstream.contains("sup"))
        XCTAssertFalse(downstream.contains("pm"))
        XCTAssertFalse(downstream.contains("tl"))
    }
}
