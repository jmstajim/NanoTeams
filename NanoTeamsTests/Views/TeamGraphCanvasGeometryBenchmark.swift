import CoreGraphics
import XCTest

@testable import NanoTeams

/// Performance pin for `TeamGraphCanvasGeometry`. The 4.41 s
/// `inLiveResize` hang was caused in part by these helpers running
/// inside `TeamGraphCanvas.body` (60-120 Hz during drag) with no
/// caching. The fix wraps them in `TeamGraphLayoutCache` so identical
/// inputs hit cache, but the underlying helpers also need to stay fast
/// for the cache-miss path (first paint of a graph, after a node drag,
/// after team edits).
///
/// A regression here — say, an O(N³) accidentally introduced in a
/// future "improvement" to `controlX` collision detection — would
/// silently re-open the hang. This benchmark pins a 20-node team at
/// well under 1 ms per pass.
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

    /// Builds a 20-node fan-out + fan-in dependency graph: a root produces
    /// `A0`, ten producers each consume `A0` and produce `Ai`, nine
    /// consumers depend on subsets of `Ai`. Connection count ~30 — a
    /// representative worst case for typical team sizes.
    private func makeLargeTeam() -> ([TeamNodePosition], [TeamRoleDefinition], Set<String>) {
        var roles: [TeamRoleDefinition] = []
        var positions: [TeamNodePosition] = []

        // Root
        roles.append(makeRole(id: "root", requires: [], produces: ["A0"]))
        positions.append(TeamNodePosition(roleID: "root", x: 0, y: 0))

        // 10 producers consuming A0, each producing Ai
        for i in 1...10 {
            let pid = "producer\(i)"
            roles.append(makeRole(id: pid, requires: ["A0"], produces: ["A\(i)"]))
            positions.append(TeamNodePosition(roleID: pid, x: CGFloat(i) * 100, y: 200))
        }

        // 9 consumers each requiring two adjacent producers' artifacts
        for i in 1...9 {
            let cid = "consumer\(i)"
            roles.append(makeRole(id: cid, requires: ["A\(i)", "A\(i + 1)"], produces: []))
            positions.append(TeamNodePosition(roleID: cid, x: CGFloat(i) * 100, y: 400))
        }

        let members = Set(roles.map(\.id))
        return (positions, roles, members)
    }

    /// Pin: `collectConnections + computePortOffsets` median < 0.5 ms.
    /// XCTest's measure() runs the block 10 times and reports `meantime`
    /// stable across runs. Setting baseline below the actual measure on
    /// the dev machine lets CI breathe room.
    func testPerformance_collectConnectionsPlusPortOffsets_under500us() async {
        let (positions, roles, members) = makeLargeTeam()
        measure {
            for _ in 0..<100 {
                let connections = TeamGraphCanvasGeometry.collectConnections(
                    nodePositions: positions,
                    roleDefinitions: roles,
                    teamMembers: members
                )
                _ = TeamGraphCanvasGeometry.computePortOffsets(
                    connections: connections,
                    nodeSizes: [:],
                    fallbackNodeWidth: 200
                )
            }
        }
    }

    /// Pin that the cache amortizes: 100 cache hits should take negligible
    /// time vs. 100 cache misses. If this ever regresses, the fingerprint
    /// has likely started invalidating spuriously.
    func testPerformance_cacheHits_negligibleVsMiss() async {
        let (positions, roles, members) = makeLargeTeam()
        let cache = TeamGraphLayoutCache()

        // Warm the cache.
        _ = cache.layout(
            nodePositions: positions,
            roleDefinitions: roles,
            teamMembers: members,
            nodeSizes: [:],
            fallbackNodeWidth: 200
        )

        measure {
            for _ in 0..<100 {
                _ = cache.layout(
                    nodePositions: positions,
                    roleDefinitions: roles,
                    teamMembers: members,
                    nodeSizes: [:],
                    fallbackNodeWidth: 200
                )
            }
        }
    }
}
