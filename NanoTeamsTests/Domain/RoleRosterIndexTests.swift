import XCTest
@testable import NanoTeams

/// `RoleRosterIndex` replaced two `first(where:)` scans per rendered timeline item with
/// one dictionary lookup. The scans encoded a PRECEDENCE that a naive dictionary silently
/// reverses, so every property below is checked against the original spelling rather than
/// against a restatement of it.
final class RoleRosterIndexTests: XCTestCase {

    private func role(
        id: String, name: String, systemRoleID: String? = nil
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, prompt: "", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            systemRoleID: systemRoleID)
    }

    /// The spelling this replaced, transcribed verbatim.
    private func linearScan(_ roster: [TeamRoleDefinition], _ baseID: String)
        -> TeamRoleDefinition? {
        if let def = roster.first(where: { $0.id == baseID }) { return def }
        return roster.first(where: { $0.systemRoleID == baseID || $0.name == baseID })
    }

    private func assertAgrees(
        _ roster: [TeamRoleDefinition], _ baseID: String, _ why: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(RoleRosterIndex(roster: roster).role(forBaseID: baseID)?.id,
                       linearScan(roster, baseID)?.id, why, file: file, line: line)
    }

    func testIDBeatsAFallbackThatComesFirstInTheRoster() {
        // `name` matches at index 0, `id` matches at index 1. The original ran the id
        // scan to completion FIRST, so index 1 wins. Two separate first-wins maps
        // merged in the wrong order would return index 0.
        let roster = [role(id: "a", name: "target"), role(id: "target", name: "b")]
        assertAgrees(roster, "target", "an `id` match must beat an earlier `name` match")
        XCTAssertEqual(RoleRosterIndex(roster: roster).role(forBaseID: "target")?.id, "target")
    }

    func testWithinTheFallbackTheEarlierRosterEntryWins_acrossKinds() {
        // `name` at index 0 vs `systemRoleID` at index 1: ONE scan in the original, so
        // index 0 wins. Building a systemRoleID map and consulting it before the name map
        // would return index 1.
        let roster = [role(id: "r0", name: "x"), role(id: "r1", name: "y", systemRoleID: "x")]
        assertAgrees(roster, "x", "the fallback is a single scan — earlier entry wins "
            + "regardless of WHICH key matched")
        XCTAssertEqual(RoleRosterIndex(roster: roster).role(forBaseID: "x")?.id, "r0")
    }

    func testDuplicateIDsResolveToTheFirst_notTheLast() {
        // Role ids are name-derived, so a team with two same-named roles has duplicate
        // ids. `first(where:)` takes the first; a plain dictionary assignment takes the
        // last.
        let roster = [role(id: "dup", name: "first"), role(id: "dup", name: "second")]
        assertAgrees(roster, "dup", "duplicate ids must resolve first-wins")
        XCTAssertEqual(RoleRosterIndex(roster: roster).role(forBaseID: "dup")?.name, "first")
    }

    func testDegenerateInputs() {
        XCTAssertNil(RoleRosterIndex(roster: []).role(forBaseID: "anything"))
        let roster = [role(id: "a", name: "A")]
        XCTAssertNil(RoleRosterIndex(roster: roster).role(forBaseID: "missing"))
        assertAgrees(roster, "missing", "a miss must be a miss in both spellings")
        // A role whose systemRoleID equals its own name must not shadow itself oddly.
        let selfKeyed = [role(id: "i", name: "same", systemRoleID: "same")]
        assertAgrees(selfKeyed, "same", "systemRoleID == name on one role")
    }

    /// Randomised agreement across the whole key space, because the precedence rules
    /// interact and hand-picked vectors are how a reversal slips through.
    func testAgreesWithTheLinearScan_onRandomisedRosters() {
        var rng = SystemRandomNumberGenerator()
        let pool = ["a", "b", "c", "d", "e"]
        for trial in 0..<2_000 {
            var roster: [TeamRoleDefinition] = []
            for _ in 0..<Int.random(in: 0...6, using: &rng) {
                let sys = Bool.random(using: &rng)
                    ? pool[Int.random(in: 0..<pool.count, using: &rng)] : nil
                roster.append(role(id: pool[Int.random(in: 0..<pool.count, using: &rng)],
                                   name: pool[Int.random(in: 0..<pool.count, using: &rng)],
                                   systemRoleID: sys))
            }
            let index = RoleRosterIndex(roster: roster)
            for key in pool {
                XCTAssertEqual(
                    index.role(forBaseID: key)?.id, linearScan(roster, key)?.id,
                    "trial \(trial), key \(key): index disagreed with the linear scan it "
                        + "replaced on roster \(roster.map { "\($0.id)/\($0.name)/\($0.systemRoleID ?? "-")" })")
            }
        }
    }
}
