import XCTest
@testable import NanoTeams

/// Pins the dependency-gated revision cascade: a downstream role in `.revisionRequested`
/// must NOT start until the upstream role it depends on is no longer revising/working.
/// Regression for the bug where an approved `request_changes` started the Software
/// Engineer and the Code Reviewer concurrently (CR re-reviewed stale code).
final class RevisionRoleGatingTests: XCTestCase {

    private func role(_ id: String, requires: [String] = [], produces: [String] = []) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: id, prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: requires, producesArtifacts: produces)
        )
    }

    /// Engineering-style linear chain: SWE → CR → TPM.
    private func linearChainRoles() -> [TeamRoleDefinition] {
        [
            role("swe", produces: ["Notes"]),
            role("cr", requires: ["Notes"], produces: ["Review"]),
            role("tpm", requires: ["Review"], produces: ["Release"]),
        ]
    }

    // MARK: - startableRevisionRoleIDs

    func testOnlyChainRootStarts_whenTargetAndDownstreamBothRevision() {
        let statuses: [String: RoleExecutionStatus] = ["swe": .revisionRequested, "cr": .revisionRequested]
        let startable = Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: linearChainRoles()))
        XCTAssertEqual(startable, ["swe"], "Only SWE (chain root) may start; CR must wait for SWE's revision")
    }

    func testEntireChainSerializesToRootOnly() {
        let statuses: [String: RoleExecutionStatus] = [
            "swe": .revisionRequested, "cr": .revisionRequested, "tpm": .revisionRequested,
        ]
        let startable = Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: linearChainRoles()))
        XCTAssertEqual(startable, ["swe"])
    }

    func testDownstreamStarts_onceUpstreamDone() {
        let statuses: [String: RoleExecutionStatus] = ["swe": .done, "cr": .revisionRequested]
        let startable = Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: linearChainRoles()))
        XCTAssertEqual(startable, ["cr"], "CR is free to revise once SWE's revision is done")
    }

    func testDownstreamBlocked_whileUpstreamWorking() {
        let statuses: [String: RoleExecutionStatus] = ["swe": .working, "cr": .revisionRequested]
        XCTAssertTrue(
            TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: linearChainRoles()).isEmpty,
            "CR must not start while SWE is still working"
        )
    }

    func testIndependentRevisionRolesStartInParallel() {
        // PM done; UXR and UXD both depend only on PM's artifact and are independent of each other.
        let roles = [
            role("pm", produces: ["PRD"]),
            role("uxr", requires: ["PRD"], produces: ["Research"]),
            role("uxd", requires: ["PRD"], produces: ["Design"]),
        ]
        let statuses: [String: RoleExecutionStatus] = [
            "pm": .done, "uxr": .revisionRequested, "uxd": .revisionRequested,
        ]
        let startable = Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: roles))
        XCTAssertEqual(startable, ["uxr", "uxd"], "Independent revision roles still revise in parallel")
    }

    func testCyclicRevisionRolesYieldNothing() {
        // Defensive: a⇐b, b⇐a cycle; neither can start (signals deadlock to the run loop).
        let roles = [
            role("a", requires: ["B"], produces: ["A"]),
            role("b", requires: ["A"], produces: ["B"]),
        ]
        let statuses: [String: RoleExecutionStatus] = ["a": .revisionRequested, "b": .revisionRequested]
        XCTAssertTrue(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: roles).isEmpty)
    }

    func testNoRevisionRoles_returnsEmpty() {
        let statuses: [String: RoleExecutionStatus] = ["swe": .done, "cr": .done, "tpm": .done]
        XCTAssertTrue(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: linearChainRoles()).isEmpty)
    }

    func testRootWithNoDependenciesAlwaysStartable() {
        let roles = [role("swe", produces: ["Notes"])]
        let statuses: [String: RoleExecutionStatus] = ["swe": .revisionRequested]
        XCTAssertEqual(Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: roles)), ["swe"])
    }

    /// Diamond: C requires BOTH A's and B's artifacts. With A clear but B still revising,
    /// C must stay blocked — a downstream role waits for ALL upstreams, not just one.
    /// Guards against the gating predicate regressing to "any upstream clear".
    func testMultiUpstreamRole_blockedUntilAllUpstreamsClear() {
        let roles = [
            role("a", produces: ["Art A"]),
            role("b", produces: ["Art B"]),
            role("c", requires: ["Art A", "Art B"], produces: ["Art C"]),
        ]
        // A done, B still revising → C blocked by B; B is the only startable role.
        let statuses: [String: RoleExecutionStatus] = [
            "a": .done, "b": .revisionRequested, "c": .revisionRequested,
        ]
        XCTAssertEqual(Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: roles)), ["b"])
    }

    /// Progressive multi-hop un-gating: as each upstream finishes, the next hop becomes
    /// startable — modeling the run loop's per-iteration re-evaluation of SWE → CR → TPM.
    func testChainUngatesOneHopAtATime() {
        let roles = linearChainRoles()
        let s1: [String: RoleExecutionStatus] = ["swe": .revisionRequested, "cr": .revisionRequested, "tpm": .revisionRequested]
        XCTAssertEqual(Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: s1, roles: roles)), ["swe"])

        let s2: [String: RoleExecutionStatus] = ["swe": .done, "cr": .revisionRequested, "tpm": .revisionRequested]
        XCTAssertEqual(Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: s2, roles: roles)), ["cr"])

        let s3: [String: RoleExecutionStatus] = ["swe": .done, "cr": .done, "tpm": .revisionRequested]
        XCTAssertEqual(Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: s3, roles: roles)), ["tpm"])
    }

    /// Only `.revisionRequested` / `.working` upstreams block. Other non-revising terminal
    /// states (`.accepted`, `.skipped`, `.done`) leave the downstream free to revise.
    func testNonRevisingUpstreamDoesNotBlock() {
        let roles = linearChainRoles()
        for upstream in [RoleExecutionStatus.accepted, .skipped, .done] {
            let statuses: [String: RoleExecutionStatus] = ["swe": upstream, "cr": .revisionRequested]
            XCTAssertEqual(
                Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: roles)),
                ["cr"],
                "Upstream \(upstream) must not block CR's revision"
            )
        }
    }

    /// `.needsAcceptance` is intentionally NOT in the blocking set. In production the run
    /// loop returns early on pending acceptances before this branch runs, so a downstream
    /// role can't actually start against an unaccepted upstream — this pins the helper's
    /// narrow "only actively-revising/working blocks" contract.
    func testNeedsAcceptanceUpstreamNotBlockedByHelper() {
        let roles = linearChainRoles()
        let statuses: [String: RoleExecutionStatus] = ["swe": .needsAcceptance, "cr": .revisionRequested]
        XCTAssertEqual(Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: roles)), ["cr"])
    }

    /// Two independent revision chains: each chain's root starts; the downstream of each
    /// stays gated behind its own root.
    func testTwoDisjointChains_bothRootsStart() {
        let roles = [
            role("a", produces: ["Art A"]),
            role("b", requires: ["Art A"], produces: ["Art B"]),
            role("c", produces: ["Art C"]),
            role("d", requires: ["Art C"], produces: ["Art D"]),
        ]
        let statuses: [String: RoleExecutionStatus] = [
            "a": .revisionRequested, "b": .revisionRequested,
            "c": .revisionRequested, "d": .revisionRequested,
        ]
        XCTAssertEqual(Set(TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: roles)), ["a", "c"])
    }

    // MARK: - ArtifactDependencyResolver.dependencyRoleIDs

    func testDependencyRoleIDs_directUpstream() {
        let resolver = ArtifactDependencyResolver(roles: linearChainRoles())
        XCTAssertEqual(resolver.dependencyRoleIDs(of: "cr"), ["swe"])
        XCTAssertEqual(resolver.dependencyRoleIDs(of: "tpm"), ["cr"])
        XCTAssertTrue(resolver.dependencyRoleIDs(of: "swe").isEmpty, "Chain root has no upstream dependency")
    }

    func testDependencyRoleIDs_diamondHasBothUpstreams() {
        let roles = [
            role("a", produces: ["Art A"]),
            role("b", produces: ["Art B"]),
            role("c", requires: ["Art A", "Art B"], produces: ["Art C"]),
        ]
        XCTAssertEqual(ArtifactDependencyResolver(roles: roles).dependencyRoleIDs(of: "c"), ["a", "b"])
    }
}
