import XCTest
@testable import NanoTeams

/// Tests for the team graph auto-layout zigzag algorithm and connection port distribution.
@MainActor
final class TeamGraphAutoLayoutTests: XCTestCase {

    // MARK: - Helpers

    /// Create a minimal TeamRoleDefinition for testing.
    private func makeRole(
        id: String,
        name: String,
        isSupervisor: Bool = false,
        requires: [String] = [],
        produces: [String] = []
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: requires, producesArtifacts: produces),
            isSystemRole: isSupervisor,
            systemRoleID: isSupervisor ? "supervisor" : nil
        )
    }

    /// Get X position for role in layout.
    private func xPos(_ layout: TeamGraphLayout, _ roleID: String) -> CGFloat? {
        layout.position(for: roleID)?.x
    }

    /// Get Y position for role in layout.
    private func yPos(_ layout: TeamGraphLayout, _ roleID: String) -> CGFloat? {
        layout.position(for: roleID)?.y
    }

    // MARK: - Zigzag Auto-Layout Tests

    func testAutoLayout_QuestPartyLike_HasZigzag() {
        // Simulates Quest Party: linear chain with skip-level connections
        let roles = [
            makeRole(id: "supervisor", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "lore", name: "Lore Master", requires: ["Goal"], produces: ["World"]),
            makeRole(id: "npc", name: "NPC Creator", requires: ["World"], produces: ["NPC"]),
            makeRole(id: "encounter", name: "Encounter Architect", requires: ["World", "NPC"], produces: ["Encounter"]),
            makeRole(id: "rules", name: "Rules Arbiter", requires: ["NPC", "Encounter"], produces: ["Balance"]),
            makeRole(id: "quest", name: "Quest Master", requires: ["World", "NPC", "Encounter", "Balance"], produces: ["Log"]),
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        // Supervisor (level 0) and Quest Master (last level) should stay at centerX=300
        XCTAssertEqual(xPos(layout, "supervisor"), 300)
        XCTAssertEqual(xPos(layout, "quest"), 300)

        // Intermediate single-node levels with skip connections should zigzag
        let loreX = xPos(layout, "lore")!
        let npcX = xPos(layout, "npc")!
        let encounterX = xPos(layout, "encounter")!
        let rulesX = xPos(layout, "rules")!

        // Lore Master has skip-level connection to Encounter (depth 1→3) → should be offset
        XCTAssertNotEqual(loreX, 300, "Lore Master should be zigzag-offset")

        // Adjacent single-node levels should alternate
        XCTAssertNotEqual(loreX, npcX, "Lore/NPC should alternate left/right")
        XCTAssertNotEqual(npcX, encounterX, "NPC/Encounter should alternate")
        XCTAssertNotEqual(encounterX, rulesX, "Encounter/Rules should alternate")

        // Zigzag should alternate direction
        let loreOffset = loreX - 300
        let npcOffset = npcX - 300
        XCTAssertTrue(loreOffset * npcOffset < 0, "Lore and NPC should be on opposite sides of center")
    }

    func testAutoLayout_LinearChain_NoSkipLevel_NoZigzag() {
        // A→B→C→D with no skip-level connections
        let roles = [
            makeRole(id: "supervisor", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "a", name: "A", requires: ["Goal"], produces: ["ArtA"]),
            makeRole(id: "b", name: "B", requires: ["ArtA"], produces: ["ArtB"]),
            makeRole(id: "c", name: "C", requires: ["ArtB"], produces: ["ArtC"]),
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        // No skip-level connections, so all should stay at centerX=300
        XCTAssertEqual(xPos(layout, "supervisor"), 300)
        XCTAssertEqual(xPos(layout, "a"), 300)
        XCTAssertEqual(xPos(layout, "b"), 300)
        XCTAssertEqual(xPos(layout, "c"), 300)
    }

    func testAutoLayout_LinearChainWithOneSkip_NoZigzag() {
        // Linear chain with 1 skip connection (like FAANG 5-role).
        // Only 1 skip pair (a→c) — below threshold of 3, so no zigzag.
        let roles = [
            makeRole(id: "supervisor", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "a", name: "A", requires: ["Goal"], produces: ["ArtA"]),
            makeRole(id: "b", name: "B", requires: ["ArtA"], produces: ["ArtB"]),
            makeRole(id: "c", name: "C", requires: ["ArtA", "ArtB"], produces: ["ArtC"]),
            makeRole(id: "d", name: "D", requires: ["ArtC"], produces: ["ArtD"]),
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        // All single-node levels should stay at centerX=300 (< 3 skip pairs)
        XCTAssertEqual(xPos(layout, "supervisor"), 300)
        XCTAssertEqual(xPos(layout, "a"), 300)
        XCTAssertEqual(xPos(layout, "b"), 300)
        XCTAssertEqual(xPos(layout, "c"), 300)
        XCTAssertEqual(xPos(layout, "d"), 300)
    }

    func testAutoLayout_Startup_NoZigzag() {
        // Startup: Supervisor → SWE (2 levels only)
        let roles = [
            makeRole(id: "supervisor", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "swe", name: "SWE", requires: ["Goal"], produces: ["Notes"]),
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        // 2 levels, SWE is last level → stays centered
        XCTAssertEqual(xPos(layout, "supervisor"), 300)
        XCTAssertEqual(xPos(layout, "swe"), 300)
    }

    func testAutoLayout_MultiNodeLevels_StaySpread() {
        // Two roles at same depth should spread horizontally, not zigzag
        let roles = [
            makeRole(id: "supervisor", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "a", name: "A", requires: ["Goal"], produces: ["ArtA"]),
            makeRole(id: "b", name: "B", requires: ["Goal"], produces: ["ArtB"]),
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        let ax = xPos(layout, "a")!
        let bx = xPos(layout, "b")!
        // Multi-node level: spread horizontally (not zigzag)
        XCTAssertNotEqual(ax, bx, "Two roles at same depth should have different X")
        // They should be symmetrically spread around center
        XCTAssertEqual((ax + bx) / 2, 300, accuracy: 0.1, "Should be centered")
    }

    func testAutoLayout_LastLevelAlwaysCentered() {
        // Last level should stay centered even if it has skip-level connections upstream
        let roles = [
            makeRole(id: "supervisor", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "a", name: "A", requires: ["Goal"], produces: ["X"]),
            makeRole(id: "b", name: "B", requires: ["X"], produces: ["Y"]),
            makeRole(id: "c", name: "C", requires: ["Goal", "Y"], produces: ["Z"]),
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        // C is last level → should stay at centerX
        XCTAssertEqual(xPos(layout, "c"), 300)
    }

    func testAutoLayout_BootstrapQuestPartyTeam_HasZigzag() {
        // Verify the actual Quest Party bootstrap uses zigzag
        let questParty = Team.defaultTeams.first { $0.templateID == "questParty" }!
        let positions = questParty.graphLayout.nodePositions

        // Should have positions for all roles
        XCTAssertEqual(positions.count, questParty.roles.count)

        // Not all non-Supervisor roles should be at the same X
        let nonSupervisorXs = questParty.roles
            .filter { !$0.isSupervisor }
            .compactMap { role in positions.first { $0.roleID == role.id }?.x }

        let uniqueXs = Set(nonSupervisorXs)
        XCTAssertTrue(uniqueXs.count > 1, "Quest Party should have zigzag — not all at same X")
    }

    func testAutoLayout_DepthOrder_YPositionsIncreasing() {
        let roles = [
            makeRole(id: "supervisor", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "a", name: "A", requires: ["Goal"], produces: ["X"]),
            makeRole(id: "b", name: "B", requires: ["X"], produces: ["Y"]),
            makeRole(id: "c", name: "C", requires: ["Goal", "Y"], produces: ["Z"]),
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        let supY = yPos(layout, "supervisor")!
        let aY = yPos(layout, "a")!
        let bY = yPos(layout, "b")!
        let cY = yPos(layout, "c")!

        // Y should increase with depth
        XCTAssertLessThan(supY, aY)
        XCTAssertLessThan(aY, bY)
        XCTAssertLessThan(bY, cY)
    }

    // MARK: - Port Distribution Tests

    func testPortDistribution_SingleConnection_CenteredPort() {
        let connections = [
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "a",
                consumerID: "b",
                artifactName: "X",
                fromPos: TeamNodePosition(roleID: "a", x: 300, y: 100),
                toPos: TeamNodePosition(roleID: "b", x: 300, y: 200)
            ),
        ]

        let (source, target) = TeamGraphCanvasGeometry.computePortOffsets(
            connections: connections,
            nodeSizes: [:],
            fallbackNodeWidth: 130
        )

        XCTAssertEqual(source[0], 0, "Single outgoing connection should have 0 offset")
        XCTAssertEqual(target[0], 0, "Single incoming connection should have 0 offset")
    }

    func testPortDistribution_MultipleOutgoing_SpreadPorts() {
        let connections = [
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "a",
                consumerID: "b",
                artifactName: "X",
                fromPos: TeamNodePosition(roleID: "a", x: 300, y: 100),
                toPos: TeamNodePosition(roleID: "b", x: 300, y: 200)
            ),
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "a",
                consumerID: "c",
                artifactName: "X",
                fromPos: TeamNodePosition(roleID: "a", x: 300, y: 100),
                toPos: TeamNodePosition(roleID: "c", x: 300, y: 400)
            ),
        ]

        let (source, _) = TeamGraphCanvasGeometry.computePortOffsets(
            connections: connections,
            nodeSizes: [:],
            fallbackNodeWidth: 130
        )

        // Two outgoing ports should be spread (different offsets)
        XCTAssertNotEqual(source[0], source[1], "Multiple outgoing should have different offsets")
        // Should be symmetric around 0
        XCTAssertEqual((source[0]! + source[1]!), 0, accuracy: 0.1, "Should be symmetric")
    }

    func testPortDistribution_MultipleIncoming_SpreadPorts() {
        let connections = [
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "a",
                consumerID: "c",
                artifactName: "X",
                fromPos: TeamNodePosition(roleID: "a", x: 300, y: 100),
                toPos: TeamNodePosition(roleID: "c", x: 300, y: 400)
            ),
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "b",
                consumerID: "c",
                artifactName: "Y",
                fromPos: TeamNodePosition(roleID: "b", x: 300, y: 200),
                toPos: TeamNodePosition(roleID: "c", x: 300, y: 400)
            ),
        ]

        let (_, target) = TeamGraphCanvasGeometry.computePortOffsets(
            connections: connections,
            nodeSizes: [:],
            fallbackNodeWidth: 130
        )

        // Two incoming ports should be spread
        XCTAssertNotEqual(target[0], target[1], "Multiple incoming should have different offsets")
        XCTAssertEqual((target[0]! + target[1]!), 0, accuracy: 0.1, "Should be symmetric")
    }

    func testPortDistribution_SortedByTargetX() {
        // Source "a" has 3 outgoing to targets at different X positions.
        // Ports should match curve direction: leftward target → left port, rightward → right port.
        let connections = [
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "a", consumerID: "d", artifactName: "X",
                fromPos: TeamNodePosition(roleID: "a", x: 300, y: 100),
                toPos: TeamNodePosition(roleID: "d", x: 360, y: 400)
            ),
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "a", consumerID: "b", artifactName: "X",
                fromPos: TeamNodePosition(roleID: "a", x: 300, y: 100),
                toPos: TeamNodePosition(roleID: "b", x: 240, y: 200)
            ),
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "a", consumerID: "c", artifactName: "X",
                fromPos: TeamNodePosition(roleID: "a", x: 300, y: 100),
                toPos: TeamNodePosition(roleID: "c", x: 300, y: 300)
            ),
        ]

        let (source, _) = TeamGraphCanvasGeometry.computePortOffsets(
            connections: connections,
            nodeSizes: [:],
            fallbackNodeWidth: 130
        )

        // Connection 1 (to b, x=240) should get the leftmost port
        // Connection 2 (to c, x=300) should get center
        // Connection 0 (to d, x=360) should get the rightmost port
        XCTAssertLessThan(source[1]!, source[2]!, "To b (left target) should use left port")
        XCTAssertLessThan(source[2]!, source[0]!, "To d (right target) should use right port")
    }

    func testPortDistribution_RespectsNodeSizes() {
        let connections = [
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "a", consumerID: "b", artifactName: "X",
                fromPos: TeamNodePosition(roleID: "a", x: 300, y: 100),
                toPos: TeamNodePosition(roleID: "b", x: 300, y: 200)
            ),
            TeamGraphCanvasGeometry.ConnectionInfo(
                producerID: "a", consumerID: "c", artifactName: "X",
                fromPos: TeamNodePosition(roleID: "a", x: 300, y: 100),
                toPos: TeamNodePosition(roleID: "c", x: 300, y: 300)
            ),
        ]

        let wideOffsets = TeamGraphCanvasGeometry.computePortOffsets(
            connections: connections,
            nodeSizes: ["a": CGSize(width: 200, height: 80)],
            fallbackNodeWidth: 130
        )

        let narrowOffsets = TeamGraphCanvasGeometry.computePortOffsets(
            connections: connections,
            nodeSizes: ["a": CGSize(width: 100, height: 80)],
            fallbackNodeWidth: 130
        )

        // Wider node should produce larger spread
        let wideSpread = abs(wideOffsets.source[0]! - wideOffsets.source[1]!)
        let narrowSpread = abs(narrowOffsets.source[0]! - narrowOffsets.source[1]!)
        XCTAssertGreaterThan(wideSpread, narrowSpread, "Wider node should spread ports further apart")
    }

    // MARK: - Observer Positioning Tests

    func testAutoLayout_ObserversAtBottom() {
        // 2 active roles + 2 observers → observers below active roles
        let roles = [
            makeRole(id: "sup", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "worker", name: "Worker", requires: ["Goal"], produces: ["Output"]),
            makeRole(id: "obs1", name: "Observer 1"),  // no produces → observer
            makeRole(id: "obs2", name: "Observer 2"),  // no produces → observer
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        let workerY = yPos(layout, "worker")!
        let obs1Y = yPos(layout, "obs1")!
        let obs2Y = yPos(layout, "obs2")!

        // Observers should be below all active roles
        XCTAssertGreaterThan(obs1Y, workerY, "Observer 1 should be below active roles")
        XCTAssertGreaterThan(obs2Y, workerY, "Observer 2 should be below active roles")
        // Both observers in same row
        XCTAssertEqual(obs1Y, obs2Y, "Both observers should be on the same row")
    }

    func testAutoLayout_SingleObserverCentered() {
        let roles = [
            makeRole(id: "sup", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "worker", name: "Worker", requires: ["Goal"], produces: ["Output"]),
            makeRole(id: "obs1", name: "Solo Observer"),  // no produces → observer
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        // Single observer should be centered (same X as centerX=300)
        XCTAssertEqual(xPos(layout, "obs1"), 300, "Single observer should be centered")
        XCTAssertGreaterThan(yPos(layout, "obs1")!, yPos(layout, "worker")!)
    }

    func testAutoLayout_ThreeObservers_TwoRowsSecondCentered() {
        let roles = [
            makeRole(id: "sup", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "worker", name: "Worker", requires: ["Goal"], produces: ["Output"]),
            makeRole(id: "obs1", name: "Observer 1"),
            makeRole(id: "obs2", name: "Observer 2"),
            makeRole(id: "obs3", name: "Observer 3"),
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        let obs1Y = yPos(layout, "obs1")!
        let obs2Y = yPos(layout, "obs2")!
        let obs3Y = yPos(layout, "obs3")!

        // First row: obs1, obs2 (same Y)
        XCTAssertEqual(obs1Y, obs2Y, "First row should have 2 observers")
        // Second row: obs3 (different Y, centered)
        XCTAssertGreaterThan(obs3Y, obs1Y, "Third observer should be on a second row")
        XCTAssertEqual(xPos(layout, "obs3"), 300, "Single observer in last row should be centered")
    }

    func testAutoLayout_ObserversExcludedFromDepthComputation() {
        // Observers should not participate in depth levels (they have no artifacts)
        let roles = [
            makeRole(id: "sup", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "pm", name: "PM", requires: ["Goal"], produces: ["Req"]),
            makeRole(id: "eng", name: "Engineer", requires: ["Req"], produces: ["Code"]),
            makeRole(id: "obs1", name: "Watcher 1"),
            makeRole(id: "obs2", name: "Watcher 2"),
            makeRole(id: "obs3", name: "Watcher 3"),
            makeRole(id: "obs4", name: "Watcher 4"),
        ]

        let layout = TeamGraphLayout.autoLayout(for: roles)

        // Active roles should be at depths 0, 1, 2
        let supY = yPos(layout, "sup")!
        let pmY = yPos(layout, "pm")!
        let engY = yPos(layout, "eng")!

        XCTAssertLessThan(supY, pmY)
        XCTAssertLessThan(pmY, engY)

        // 4 observers → 2 rows of 2
        let obs1Y = yPos(layout, "obs1")!
        let obs2Y = yPos(layout, "obs2")!
        let obs3Y = yPos(layout, "obs3")!
        let obs4Y = yPos(layout, "obs4")!

        XCTAssertGreaterThan(obs1Y, engY, "Observers below active roles")
        XCTAssertEqual(obs1Y, obs2Y, "Row 1: two observers")
        XCTAssertEqual(obs3Y, obs4Y, "Row 2: two observers")
        XCTAssertGreaterThan(obs3Y, obs1Y, "Row 2 below row 1")
    }

    // MARK: - Edge Cases

    func testAutoLayout_emptyRoles_returnsEmptyLayout() {
        let layout = TeamGraphLayout.autoLayout(for: [])
        XCTAssertTrue(layout.nodePositions.isEmpty)
    }

    func testAutoLayout_singleRole_positionedAtOrigin() {
        let roles = [
            makeRole(id: "sup", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
        ]
        let layout = TeamGraphLayout.autoLayout(for: roles)
        XCTAssertEqual(layout.nodePositions.count, 1)
        XCTAssertEqual(xPos(layout, "sup"), 300)
    }

    func testAutoLayout_roleWithMultipleProducers_depthIsMaxPlusOne() {
        // Role C requires artifacts from both A (depth 1) and B (depth 2)
        // → C should be at depth 3 (max producer depth + 1)
        let roles = [
            makeRole(id: "sup", name: "Supervisor", isSupervisor: true, produces: ["Goal"]),
            makeRole(id: "a", name: "A", requires: ["Goal"], produces: ["ArtA"]),
            makeRole(id: "b", name: "B", requires: ["ArtA"], produces: ["ArtB"]),
            makeRole(id: "c", name: "C", requires: ["ArtA", "ArtB"], produces: ["ArtC"]),
        ]
        let layout = TeamGraphLayout.autoLayout(for: roles)

        // Depths: sup=0, a=1, b=2, c=3 (max of depth(a)=1, depth(b)=2 → +1 = 3)
        let aY = yPos(layout, "a")!
        let bY = yPos(layout, "b")!
        let cY = yPos(layout, "c")!
        XCTAssertLessThan(aY, bY)
        XCTAssertLessThan(bY, cY)
    }

    func testAutoLayout_allObservers_noActiveRoles() {
        let roles = [
            makeRole(id: "obs1", name: "Observer 1"),
            makeRole(id: "obs2", name: "Observer 2"),
        ]
        let layout = TeamGraphLayout.autoLayout(for: roles)
        // Observers only — should still get positions
        XCTAssertEqual(layout.nodePositions.count, 2)
    }
}
