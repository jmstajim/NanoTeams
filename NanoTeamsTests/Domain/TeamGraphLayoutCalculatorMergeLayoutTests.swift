import XCTest
@testable import NanoTeams

/// Tests for `TeamGraphLayoutCalculator.mergeLayout` — the reconcile helper
/// used by version-bump migrations to add new system roles to an existing
/// team's graph without disturbing positions the user may have dragged.
///
/// Invariants pinned here:
/// - Fast path: when `roles` matches `existing.nodePositions` exactly (no
///   missing, no stale), the stored layout is returned verbatim (not re-
///   computed). This is important — `autoLayout` is not position-stable,
///   so re-running it would spuriously move every node.
/// - Stale positions (role no longer exists) are dropped.
/// - Missing positions (new role added) are auto-placed via `autoLayout`.
/// - Existing positions for unchanged roles are preserved bit-for-bit.
/// - Empty input edge cases don't crash or return malformed output.
final class TeamGraphLayoutCalculatorMergeLayoutTests: XCTestCase {

    // MARK: - Helpers

    private func makeRole(id: String, requires: [String] = [], produces: [String] = [])
        -> TeamRoleDefinition
    {
        TeamRoleDefinition(
            id: id,
            name: id,
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requires,
                producesArtifacts: produces
            )
        )
    }

    // MARK: - Fast path

    /// When every role in `roles` already has a position in `existing`, the
    /// layout must be returned VERBATIM. Any re-layout would jitter the graph.
    func testMergeLayout_fastPath_preservesExistingVerbatim() {
        let roles = [
            makeRole(id: "r1", produces: ["A"]),
            makeRole(id: "r2", requires: ["A"]),
        ]
        let existing = TeamGraphLayout(nodePositions: [
            TeamNodePosition(roleID: "r1", x: 999, y: 111),
            TeamNodePosition(roleID: "r2", x: 7, y: 42),
        ])

        let merged = TeamGraphLayoutCalculator.mergeLayout(existing: existing, roles: roles)

        XCTAssertEqual(merged.nodePositions.count, 2)
        // Order and exact coordinates preserved
        XCTAssertEqual(merged.nodePositions[0].roleID, "r1")
        XCTAssertEqual(merged.nodePositions[0].x, 999)
        XCTAssertEqual(merged.nodePositions[0].y, 111)
        XCTAssertEqual(merged.nodePositions[1].roleID, "r2")
        XCTAssertEqual(merged.nodePositions[1].x, 7)
        XCTAssertEqual(merged.nodePositions[1].y, 42)
    }

    // MARK: - Missing roles (auto-placed)

    func testMergeLayout_newRoleAdded_existingPositionsUnchanged_newRolePlaced() {
        let roles = [
            makeRole(id: "r1", produces: ["A"]),
            makeRole(id: "r2", requires: ["A"]),
            makeRole(id: "new_role", requires: ["A"]),  // newly added
        ]
        let existing = TeamGraphLayout(nodePositions: [
            TeamNodePosition(roleID: "r1", x: 500, y: 50),
            TeamNodePosition(roleID: "r2", x: 500, y: 200),
        ])

        let merged = TeamGraphLayoutCalculator.mergeLayout(existing: existing, roles: roles)

        XCTAssertEqual(merged.nodePositions.count, 3)

        let r1Pos = merged.nodePositions.first { $0.roleID == "r1" }
        let r2Pos = merged.nodePositions.first { $0.roleID == "r2" }
        let newPos = merged.nodePositions.first { $0.roleID == "new_role" }

        XCTAssertEqual(r1Pos?.x, 500, "User-dragged r1 position must be preserved bit-for-bit")
        XCTAssertEqual(r1Pos?.y, 50)
        XCTAssertEqual(r2Pos?.x, 500)
        XCTAssertEqual(r2Pos?.y, 200)
        XCTAssertNotNil(newPos, "New role must be assigned a position")
    }

    // MARK: - Stale roles (dropped)

    func testMergeLayout_staleRoleRemoved_positionDropped() {
        let roles = [
            makeRole(id: "r1", produces: ["A"]),
        ]
        let existing = TeamGraphLayout(nodePositions: [
            TeamNodePosition(roleID: "r1", x: 100, y: 50),
            TeamNodePosition(roleID: "removed_role", x: 999, y: 999), // no longer in roles
        ])

        let merged = TeamGraphLayoutCalculator.mergeLayout(existing: existing, roles: roles)

        XCTAssertEqual(merged.nodePositions.count, 1,
                       "Stale position for removed role must be dropped")
        XCTAssertEqual(merged.nodePositions[0].roleID, "r1")
    }

    func testMergeLayout_staleAndMissing_bothHandled() {
        let roles = [
            makeRole(id: "kept", produces: ["A"]),
            makeRole(id: "added", requires: ["A"]),
        ]
        let existing = TeamGraphLayout(nodePositions: [
            TeamNodePosition(roleID: "kept", x: 300, y: 40),
            TeamNodePosition(roleID: "gone", x: 999, y: 999),
        ])

        let merged = TeamGraphLayoutCalculator.mergeLayout(existing: existing, roles: roles)

        let ids = Set(merged.nodePositions.map(\.roleID))
        XCTAssertEqual(ids, Set(["kept", "added"]),
                       "Only roles in `roles` survive — stale dropped, missing added")

        let keptPos = merged.nodePositions.first { $0.roleID == "kept" }
        XCTAssertEqual(keptPos?.x, 300, "User-dragged kept position preserved")
        XCTAssertEqual(keptPos?.y, 40)
    }

    // MARK: - Empty inputs

    func testMergeLayout_emptyExistingAndEmptyRoles_returnsEmpty() {
        let merged = TeamGraphLayoutCalculator.mergeLayout(
            existing: TeamGraphLayout(), roles: []
        )
        XCTAssertTrue(merged.nodePositions.isEmpty)
    }

    func testMergeLayout_emptyExisting_missingRolesAutoPlaced() {
        let roles = [makeRole(id: "only", produces: ["A"])]
        let merged = TeamGraphLayoutCalculator.mergeLayout(
            existing: TeamGraphLayout(), roles: roles
        )
        XCTAssertEqual(merged.nodePositions.count, 1)
        XCTAssertEqual(merged.nodePositions[0].roleID, "only")
    }

    func testMergeLayout_rolesEmpty_dropsAllExisting() {
        let existing = TeamGraphLayout(nodePositions: [
            TeamNodePosition(roleID: "orphan1", x: 1, y: 2),
            TeamNodePosition(roleID: "orphan2", x: 3, y: 4),
        ])
        let merged = TeamGraphLayoutCalculator.mergeLayout(existing: existing, roles: [])
        XCTAssertTrue(merged.nodePositions.isEmpty,
                      "No roles → every stored position is stale")
    }

    // MARK: - No structural change but reorder

    /// If the role set is unchanged but the order within `roles` differs
    /// from `existing.nodePositions`, the fast path still applies (set-based
    /// equality, not array order) — stored positions stay as-is.
    func testMergeLayout_roleOrderChanged_butSameSet_stillFastPath() {
        let r1 = makeRole(id: "r1", produces: ["A"])
        let r2 = makeRole(id: "r2", requires: ["A"])

        let existing = TeamGraphLayout(nodePositions: [
            TeamNodePosition(roleID: "r1", x: 500, y: 50),
            TeamNodePosition(roleID: "r2", x: 500, y: 200),
        ])
        // Reverse the role order — still same set.
        let merged = TeamGraphLayoutCalculator.mergeLayout(existing: existing, roles: [r2, r1])

        // Positions untouched, including original ordering within the layout.
        XCTAssertEqual(merged.nodePositions[0].roleID, "r1")
        XCTAssertEqual(merged.nodePositions[0].x, 500)
        XCTAssertEqual(merged.nodePositions[1].roleID, "r2")
        XCTAssertEqual(merged.nodePositions[1].x, 500)
    }
}
