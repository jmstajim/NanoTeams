import CoreGraphics
import XCTest

@testable import NanoTeams

/// Pins the `TeamGraphLayoutCache` contract: identical inputs hit, structural
/// changes miss, selection / drawingOffset / unrelated jitter stays a hit.
///
/// The cache exists to make `NSWindow inLiveResize` cheap — the resize
/// gesture re-runs `TeamGraphCanvas.body` 60–120 Hz with structurally
/// identical inputs. If the cache key ever invalidates on every body
/// re-eval (e.g. a future contributor adds `Date.now` to the fingerprint),
/// the 4.41 s hang regression returns silently. These tests are the only
/// guard against that.
@MainActor
final class TeamGraphLayoutCacheTests: XCTestCase {

    private var cache: TeamGraphLayoutCache!

    override func setUp() {
        super.setUp()
        cache = TeamGraphLayoutCache()
    }

    override func tearDown() {
        cache = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeRole(
        id: String,
        requiredArtifacts: [String] = [],
        producesArtifacts: [String] = [],
        isSystemRole: Bool = false,
        systemRoleID: String? = nil
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: id.capitalized,
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requiredArtifacts,
                producesArtifacts: producesArtifacts
            ),
            isSystemRole: isSystemRole,
            systemRoleID: systemRoleID
        )
    }

    private func defaultRoles() -> [TeamRoleDefinition] {
        [
            makeRole(id: "supervisor", producesArtifacts: ["Supervisor Task"], isSystemRole: true, systemRoleID: "supervisor"),
            makeRole(id: "pm", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Requirements"]),
            makeRole(id: "eng", requiredArtifacts: ["Requirements"], producesArtifacts: ["Notes"]),
        ]
    }

    private func defaultPositions() -> [TeamNodePosition] {
        [
            TeamNodePosition(roleID: "supervisor", x: 0, y: 0),
            TeamNodePosition(roleID: "pm", x: 100, y: 100),
            TeamNodePosition(roleID: "eng", x: 200, y: 200),
        ]
    }

    private func defaultMembers() -> Set<String> {
        ["supervisor", "pm", "eng"]
    }

    // MARK: - Cache hit / miss

    func testIdenticalInputs_areCacheHit() async {
        let roles = defaultRoles()
        let positions = defaultPositions()
        let members = defaultMembers()

        let first = cache.layout(
            nodePositions: positions,
            roleDefinitions: roles,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )
        let second = cache.layout(
            nodePositions: positions,
            roleDefinitions: roles,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        XCTAssertEqual(first.connections.count, second.connections.count)
        XCTAssertEqual(cache._test_computeCount, 1, "Second call with identical inputs must hit cache.")
        XCTAssertEqual(cache._test_hitCount, 1)
    }

    func testNodePositionChange_invalidatesCache() async {
        let roles = defaultRoles()
        let members = defaultMembers()

        _ = cache.layout(
            nodePositions: defaultPositions(),
            roleDefinitions: roles,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        // Move pm to a different position — drag scenario.
        let movedPositions: [TeamNodePosition] = [
            TeamNodePosition(roleID: "supervisor", x: 0, y: 0),
            TeamNodePosition(roleID: "pm", x: 150, y: 150),
            TeamNodePosition(roleID: "eng", x: 200, y: 200),
        ]
        _ = cache.layout(
            nodePositions: movedPositions,
            roleDefinitions: roles,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        XCTAssertEqual(cache._test_computeCount, 2, "Position change must miss cache.")
        XCTAssertEqual(cache._test_hitCount, 0)
    }

    func testSubPixelJitter_doesNotInvalidate() async {
        let roles = defaultRoles()
        let members = defaultMembers()

        _ = cache.layout(
            nodePositions: defaultPositions(),
            roleDefinitions: roles,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        // Sub-pixel jitter (< 0.5 from rounding).
        let jittered: [TeamNodePosition] = [
            TeamNodePosition(roleID: "supervisor", x: 0.1, y: 0.2),
            TeamNodePosition(roleID: "pm", x: 100.3, y: 100.4),
            TeamNodePosition(roleID: "eng", x: 199.6, y: 199.8),
        ]
        _ = cache.layout(
            nodePositions: jittered,
            roleDefinitions: roles,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        // Coordinates round to the same integers — same fingerprint.
        XCTAssertEqual(cache._test_computeCount, 1, "Sub-pixel jitter that rounds to the same integers must not invalidate.")
        XCTAssertEqual(cache._test_hitCount, 1)
    }

    func testRoleOrderingChange_doesNotInvalidate() async {
        let members = defaultMembers()
        let positions = defaultPositions()

        let unsorted: [TeamRoleDefinition] = [
            makeRole(id: "pm", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Requirements"]),
            makeRole(id: "supervisor", producesArtifacts: ["Supervisor Task"], isSystemRole: true, systemRoleID: "supervisor"),
            makeRole(id: "eng", requiredArtifacts: ["Requirements"], producesArtifacts: ["Notes"]),
        ]
        _ = cache.layout(
            nodePositions: positions,
            roleDefinitions: unsorted,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        // Same roles, different array order.
        let reversed = Array(unsorted.reversed())
        _ = cache.layout(
            nodePositions: positions,
            roleDefinitions: reversed,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        XCTAssertEqual(cache._test_computeCount, 1, "Role ordering must not affect fingerprint.")
        XCTAssertEqual(cache._test_hitCount, 1)
    }

    func testTeamMembersChange_invalidatesCache() async {
        let roles = defaultRoles()
        let positions = defaultPositions()

        _ = cache.layout(
            nodePositions: positions,
            roleDefinitions: roles,
            teamMembers: defaultMembers(),
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        // Remove a member — visible-set changed.
        _ = cache.layout(
            nodePositions: positions,
            roleDefinitions: roles,
            teamMembers: ["supervisor", "pm"],
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        XCTAssertEqual(cache._test_computeCount, 2)
    }

    func testNodeSizesChange_invalidatesCache() async {
        let roles = defaultRoles()
        let positions = defaultPositions()
        let members = defaultMembers()

        _ = cache.layout(
            nodePositions: positions,
            roleDefinitions: roles,
            teamMembers: members,
            nodeSizes: ["pm": CGSize(width: 200, height: 90)],
            fallbackNodeWidth: 200
        )
        _ = cache.layout(
            nodePositions: positions,
            roleDefinitions: roles,
            teamMembers: members,
            nodeSizes: ["pm": CGSize(width: 220, height: 90)],
            fallbackNodeWidth: 200
        )

        XCTAssertEqual(cache._test_computeCount, 2, "nodeSizes width change must invalidate (drives port spread).")
    }

    func testDependencyChange_invalidatesCache() async {
        let positions = defaultPositions()
        let members = defaultMembers()

        _ = cache.layout(
            nodePositions: positions,
            roleDefinitions: defaultRoles(),
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        // Change PM's produced artifact — affects collectConnections.
        let modifiedRoles: [TeamRoleDefinition] = [
            makeRole(id: "supervisor", producesArtifacts: ["Supervisor Task"], isSystemRole: true, systemRoleID: "supervisor"),
            makeRole(id: "pm", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["DifferentArtifact"]),
            makeRole(id: "eng", requiredArtifacts: ["Requirements"], producesArtifacts: ["Notes"]),
        ]
        _ = cache.layout(
            nodePositions: positions,
            roleDefinitions: modifiedRoles,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        XCTAssertEqual(cache._test_computeCount, 2)
    }

    // MARK: - Result correctness

    func testLayout_producesExpectedConnections() async {
        let layout = cache.layout(
            nodePositions: defaultPositions(),
            roleDefinitions: defaultRoles(),
            teamMembers: defaultMembers(),
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        // PM requires Supervisor Task (supervisor produces it),
        // ENG requires Requirements (PM produces it).
        // Supervisor is skipped as a consumer (isSupervisor guard in
        // collectConnections). So we get 2 connections: supervisor→pm, pm→eng.
        XCTAssertEqual(layout.connections.count, 2)
        let connections = layout.connections
        XCTAssertTrue(connections.contains(where: { $0.producerID == "supervisor" && $0.consumerID == "pm" }))
        XCTAssertTrue(connections.contains(where: { $0.producerID == "pm" && $0.consumerID == "eng" }))
    }
}
