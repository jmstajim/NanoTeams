import XCTest

@testable import NanoTeams

/// `TeamGraphView`'s layout arithmetic, extracted from computed properties by the
/// 2026-08-25 hoist. The hoist (five evaluations → one) is pinned as wiring in
/// `Ratchet/BodyPassHoistPinTests`; this file pins what the functions ANSWER.
@MainActor
final class TeamGraphViewGeometryTests: XCTestCase {

    private func pos(_ id: String, _ x: CGFloat, _ y: CGFloat) -> TeamNodePosition {
        TeamNodePosition(roleID: id, x: x, y: y)
    }

    /// `isSupervisor` is DERIVED from `systemRoleID == "supervisor"`, not stored, so the
    /// fixture has to say it that way — a stored flag would test a field the view never reads.
    private func role(id: String, isSupervisor: Bool = false) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: id, prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Notes"]),
            systemRoleID: isSupervisor ? "supervisor" : nil
        )
    }

    // MARK: - visibleNodePositions

    func testVisibleNodes_keepSupervisorAndTeamMembers_dropTheRest() {
        let roster = [role(id: "sup", isSupervisor: true), role(id: "eng"), role(id: "ghost")]
        let index = RoleRosterIndex(roster: roster)
        let visible = TeamGraphView.visibleNodePositions(
            [pos("sup", 0, 0), pos("eng", 10, 0), pos("ghost", 20, 0)],
            index: index, teamMembers: ["eng"])
        XCTAssertEqual(visible.map(\.roleID), ["sup", "eng"],
                       "Supervisor is kept by its own flag, members by the set; a node "
                           + "belonging to neither is not part of this team's graph")
    }

    func testVisibleNodes_unknownRoleID_isNotSupervisorByAccident() {
        // The reason `role(forExactID:)` exists: a name-matching fallback would resolve
        // this node against an unrelated role and could flip `isSupervisor`.
        let index = RoleRosterIndex(roster: [role(id: "sup", isSupervisor: true)])
        XCTAssertTrue(TeamGraphView.visibleNodePositions(
            [pos("orphan", 0, 0)], index: index, teamMembers: []).isEmpty)
    }

    // MARK: - nodeBounds

    func testNodeBounds_nilOnEmpty_andSpansNegativeCoordinates() {
        XCTAssertNil(TeamGraphView.nodeBounds(of: []))
        let single = TeamGraphView.nodeBounds(of: [pos("a", 5, 7)])
        XCTAssertEqual(single, TeamGraphView.Bounds(minX: 5, maxX: 5, minY: 7, maxY: 7))
        let spread = TeamGraphView.nodeBounds(of: [pos("a", -30, 4), pos("b", 12, -9)])
        XCTAssertEqual(spread, TeamGraphView.Bounds(minX: -30, maxX: 12, minY: -9, maxY: 4))
    }

    // MARK: - fitScale

    func testFitScale_isOneBelowTwoVisibleNodes_regardlessOfBounds() {
        let bounds = TeamGraphView.Bounds(minX: 0, maxX: 10_000, minY: 0, maxY: 10_000)
        XCTAssertEqual(
            TeamGraphView.fitScale(viewSize: CGSize(width: 100, height: 100),
                                   bounds: bounds, visibleCount: 1), 1.0,
            "a single node needs no fitting; scaling it down would shrink a lone card")
        XCTAssertEqual(
            TeamGraphView.fitScale(viewSize: CGSize(width: 100, height: 100),
                                   bounds: nil, visibleCount: 5), 1.0)
    }

    func testFitScale_clampsToTheDocumentedFloorAndCeiling() {
        let huge = TeamGraphView.Bounds(minX: 0, maxX: 100_000, minY: 0, maxY: 100_000)
        XCTAssertEqual(
            TeamGraphView.fitScale(viewSize: CGSize(width: 200, height: 200),
                                   bounds: huge, visibleCount: 4), 0.3,
            "never below 0.3 — past that the node labels are unreadable")
        let tiny = TeamGraphView.Bounds(minX: 0, maxX: 1, minY: 0, maxY: 1)
        XCTAssertEqual(
            TeamGraphView.fitScale(viewSize: CGSize(width: 5_000, height: 5_000),
                                   bounds: tiny, visibleCount: 2), 1.0,
            "never above 1.0 — the graph is fitted, not magnified")
        XCTAssertEqual(
            TeamGraphView.fitScale(viewSize: .zero, bounds: tiny, visibleCount: 2), 1.0,
            "a zero-size view is a layout pass before geometry lands, not a reason to scale")
    }

    // MARK: - frame + offset

    func testFrameAndOffset_haveDefaultsWithNoBounds_andTranslateToPositiveSpace() {
        XCTAssertEqual(TeamGraphView.graphFrameSize(bounds: nil), CGSize(width: 100, height: 100))
        XCTAssertEqual(TeamGraphView.graphLocalOffset(bounds: nil), .zero)
        let b = TeamGraphView.Bounds(minX: -40, maxX: 60, minY: -25, maxY: 75)
        let offset = TeamGraphView.graphLocalOffset(bounds: b)
        XCTAssertGreaterThan(offset.x, 40, "translating by more than -minX is what keeps "
            + "the leftmost node off the Canvas clip edge")
        XCTAssertGreaterThan(offset.y, 25)
        let size = TeamGraphView.graphFrameSize(bounds: b)
        XCTAssertGreaterThan(size.width, b.maxX - b.minX)
        XCTAssertGreaterThan(size.height, b.maxY - b.minY)
    }
}

/// `RoleRosterIndex.role(forExactID:)` — the O(1) twin of `roster.first { $0.id == id }`,
/// added for `TeamGraphView` and deliberately WITHOUT the `systemRoleID`/`name` fallback
/// that `role(forBaseID:)` carries.
final class RoleRosterIndexExactIDTests: XCTestCase {

    private func role(id: String, name: String, systemRoleID: String? = nil) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            systemRoleID: systemRoleID)
    }

    func testExactID_resolvesByIDOnly() {
        let index = RoleRosterIndex(roster: [role(id: "u1", name: "Engineer")])
        XCTAssertEqual(index.role(forExactID: "u1")?.name, "Engineer")
    }

    /// The whole point of the separate accessor, and the assertion that stops a future
    /// "simplification" from collapsing it into `role(forBaseID:)`: a NAME match must not
    /// resolve. A graph node is keyed by `TeamNodePosition.roleID`, so a name fallback
    /// would attach it to an unrelated role and flip the `isSupervisor` test that decides
    /// whether the node is drawn at all.
    func testExactID_doesNOTFallBackToNameOrSystemRoleID() {
        let index = RoleRosterIndex(roster: [role(id: "u1", name: "Engineer",
                                                  systemRoleID: "engineer")])
        XCTAssertNil(index.role(forExactID: "Engineer"))
        XCTAssertNil(index.role(forExactID: "engineer"))
        XCTAssertNotNil(index.role(forBaseID: "Engineer"),
                        "anti-vacuum: the fallback accessor DOES resolve both, so the nils "
                            + "above are a property of `forExactID`, not of the fixture")
        XCTAssertNotNil(index.role(forBaseID: "engineer"))
    }

    func testExactID_isFirstWins_matchingTheScanItReplaced() {
        let index = RoleRosterIndex(roster: [role(id: "dup", name: "First"),
                                             role(id: "dup", name: "Second")])
        XCTAssertEqual(index.role(forExactID: "dup")?.name, "First",
                       "`first(where:)` semantics; last-wins would be a different answer "
                           + "on a team with two same-id roles, which is reachable because "
                           + "ids are name-derived")
    }
}
