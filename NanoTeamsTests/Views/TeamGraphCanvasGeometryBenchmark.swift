import CoreGraphics
import XCTest

@testable import NanoTeams

/// Performance pin for `TeamGraphCanvasGeometry`. The 4.41 s `inLiveResize` hang
/// was caused in part by these helpers running inside `TeamGraphCanvas.body`
/// (60-120 Hz during drag) with no caching. The fix wraps them in
/// `TeamGraphLayoutCache` so identical inputs hit cache, but the underlying
/// helpers also need to stay fast for the cache-miss path (first paint, after a
/// node drag, after team edits).
///
/// Both tests here used to be bare `measure {}` blocks, and neither could fail:
/// `measure` reds only against a stored XCTest baseline and this repository has
/// none, so their doc comments ("median < 0.5 ms", "cache hits negligible vs
/// misses") asserted things nothing checked — and the second never measured a
/// miss to compare against. They are now work-bound: a scaling ratio on a probe
/// counter here, and the cache's own hit/compute counters next door in
/// `TeamGraphLayoutCacheTests`.
@MainActor
final class TeamGraphCanvasGeometryBenchmark: XCTestCase {

    private func makeRole(id: String, requires: [String], produces: [String]) -> TeamRoleDefinition {
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

    /// Scaling pin on WORK, not wall-clock. `collectConnections` is
    /// Θ(N·A·R·P) by design — every quantity is team shape — and the regression
    /// this guards is the one its predecessor named and could not catch: an
    /// accidental extra nesting level in a future `controlX`-style change.
    ///
    /// It replaces a bare `measure {}` whose doc comment claimed "median < 0.5
    /// ms". `measure` fails only against a stored XCTest baseline, and this repo
    /// has none — so the block ran, printed a number, and passed unconditionally.
    /// The doctrine it should have followed is written at
    /// `SearchExecutorCounterTests`: express a performance pin as WORK DONE,
    /// because the test target runs parallel and CI hardware is thermally
    /// variable. The shape here is `TaskStreamSplitTests`': a ratio with a
    /// generous constant.
    ///
    /// Doubling the roster quadruples the probes (two of the three nested scans
    /// are Θ(R) inside a Θ(N) loop, and N == R here). A cubic regression would be
    /// ~8×. The ceiling sits at 6× — clear of 4, well under 8.
    func testCollectConnections_workGrowsQuadratically_notCubically() {
        func probes(roles: Int) -> Int {
            let (positions, defs, members) = makeTeam(producers: roles)
            TeamGraphCanvasGeometry._testResetProbes()
            _ = TeamGraphCanvasGeometry.collectConnections(
                nodePositions: positions, roleDefinitions: defs, teamMembers: members)
            return TeamGraphCanvasGeometry._testProbes()
        }

        let small = probes(roles: 10)
        let large = probes(roles: 20)
        XCTAssertGreaterThan(
            small, 0,
            "anti-vacuum: a counter that never increments satisfies any ceiling")
        XCTAssertLessThan(
            large, small * 6,
            "doubling the roster must cost ~4x (quadratic by design), not ~8x "
            + "(a new nesting level). got \(small) -> \(large)")
    }

    /// Builds a fan-out + fan-in graph: a root producing `A0`, `producers`
    /// consumers of it each producing `Ai`, and `producers - 1` consumers each
    /// requiring two adjacent `Ai`. Roster size is `2 * producers`.
    private func makeTeam(
        producers: Int
    ) -> ([TeamNodePosition], [TeamRoleDefinition], Set<String>) {
        var roles: [TeamRoleDefinition] = []
        var positions: [TeamNodePosition] = []

        roles.append(makeRole(id: "root", requires: [], produces: ["A0"]))
        positions.append(TeamNodePosition(roleID: "root", x: 0, y: 0))

        for i in 1...producers {
            let pid = "producer\(i)"
            roles.append(makeRole(id: pid, requires: ["A0"], produces: ["A\(i)"]))
            positions.append(TeamNodePosition(roleID: pid, x: CGFloat(i) * 100, y: 200))
        }

        for i in 1..<producers {
            let cid = "consumer\(i)"
            roles.append(makeRole(id: cid, requires: ["A\(i)", "A\(i + 1)"], produces: []))
            positions.append(TeamNodePosition(roleID: cid, x: CGFloat(i) * 100, y: 400))
        }

        return (positions, roles, Set(roles.map(\.id)))
    }
}
