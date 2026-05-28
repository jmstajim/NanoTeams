import SwiftUI

// MARK: - TeamGraphLayoutCache

/// Memoizes the structural geometry of a team graph — the work done by
/// `TeamGraphCanvasGeometry.collectConnections` + `computePortOffsets`. Held
/// via `@State` on the owning view; the wrapped `Storage` class persists
/// across body re-evaluations so cache hits skip both algorithms.
///
/// Why this matters: `TeamGraphCanvas.body` re-runs on every geometry change
/// during `NSWindow inLiveResize` (60-120 Hz). Without the cache, the same
/// `[ConnectionInfo]` array + offset dictionaries are reallocated each tick,
/// burning main-thread cycles on identical results. The cache key folds the
/// inputs `collectConnections` + `computePortOffsets` actually read, so a
/// pure resize (no team / position / size change) is a cache hit.
///
/// The cache key intentionally does NOT include `selectedRoleID` or
/// `drawingOffset` — neither affects `connections` / `sourceOffsets` /
/// `targetOffsets`. Selection only changes per-connection color resolution
/// (handled inside the Canvas body, not by the cache). `drawingOffset` is
/// applied at draw time per frame.
///
/// Drag flow: the editor's drag handler mutates `nodePositions`, which
/// invalidates the cache by design. Drag tick = cache miss = recompute = no
/// benefit during drag — by intent. The cache exists for resize, where
/// inputs are stable.
///
/// Isolation: explicitly `@MainActor`. The cache is accessed from SwiftUI
/// body evaluation (main-isolated by contract); the inner `Storage`'s
/// mutable `cachedKey`/`cachedLayout` are unsynchronized, so any off-main
/// access would race. Explicit annotation prevents the contract from
/// silently degrading if `SWIFT_DEFAULT_ACTOR_ISOLATION` is ever changed.
@MainActor
struct TeamGraphLayoutCache {

    // MARK: - Layout

    /// The cached layout result. Consumers iterate `connections` and read
    /// matching `sourceOffsets[i]` / `targetOffsets[i]` to position
    /// connection endpoints.
    ///
    /// `nonisolated Sendable`: pure value type composed of `Sendable` parts
    /// (`[ConnectionInfo]`, `[Int: CGFloat]` × 2). Independent of the parent
    /// `TeamGraphLayoutCache`'s `@MainActor` isolation so cache results can
    /// be propagated across actor boundaries without `assumeIsolated` hops.
    /// Pinned by `TeamGraphLayoutSendableTests`.
    nonisolated struct Layout: Sendable {
        let connections: [TeamGraphCanvasGeometry.ConnectionInfo]
        let sourceOffsets: [Int: CGFloat]
        let targetOffsets: [Int: CGFloat]

        static let empty = Layout(connections: [], sourceOffsets: [:], targetOffsets: [:])
    }

    // MARK: - Storage

    /// Internal reference holder so the cache survives `@State` value
    /// copies. SwiftUI snapshots the `@State` value on init and shares the
    /// reference across body re-evaluations; we lean on that to keep one
    /// `Storage` instance per view identity.
    private final class Storage {
        var cachedKey: Int?
        var cachedLayout: Layout?
        #if DEBUG
        var computeCount: Int = 0
        var hitCount: Int = 0
        #endif
    }

    private let storage = Storage()

    // MARK: - Public API

    /// Returns the layout for the given inputs, either from cache or by
    /// invoking `TeamGraphCanvasGeometry`.
    func layout(
        nodePositions: [TeamNodePosition],
        roleDefinitions: [TeamRoleDefinition],
        teamMembers: Set<String>,
        nodeSizes: [String: CGSize],
        fallbackNodeWidth: CGFloat
    ) -> Layout {
        let key = Self.fingerprint(
            nodePositions: nodePositions,
            roleDefinitions: roleDefinitions,
            teamMembers: teamMembers,
            nodeSizes: nodeSizes,
            fallbackNodeWidth: fallbackNodeWidth
        )
        if storage.cachedKey == key, let cached = storage.cachedLayout {
            #if DEBUG
            storage.hitCount += 1
            #endif
            return cached
        }
        #if DEBUG
        storage.computeCount += 1
        #endif
        let connections = TeamGraphCanvasGeometry.collectConnections(
            nodePositions: nodePositions,
            roleDefinitions: roleDefinitions,
            teamMembers: teamMembers
        )
        let offsets = TeamGraphCanvasGeometry.computePortOffsets(
            connections: connections,
            nodeSizes: nodeSizes,
            fallbackNodeWidth: fallbackNodeWidth
        )
        let result = Layout(
            connections: connections,
            sourceOffsets: offsets.source,
            targetOffsets: offsets.target
        )
        storage.cachedKey = key
        storage.cachedLayout = result
        return result
    }

    // MARK: - Test introspection

    #if DEBUG
    /// Test-only: hit/miss counters. Reset at the start of each unit test
    /// by constructing a fresh cache.
    var _test_computeCount: Int { storage.computeCount }
    var _test_hitCount: Int { storage.hitCount }
    #endif

    // MARK: - Fingerprint

    /// Hashes the inputs that `collectConnections` + `computePortOffsets`
    /// actually read. Coordinates are rounded to the nearest integer so
    /// floating-point jitter (sub-pixel layout passes) doesn't invalidate
    /// the cache when nothing visible changed.
    private static func fingerprint(
        nodePositions: [TeamNodePosition],
        roleDefinitions: [TeamRoleDefinition],
        teamMembers: Set<String>,
        nodeSizes: [String: CGSize],
        fallbackNodeWidth: CGFloat
    ) -> Int {
        var hasher = Hasher()

        // nodePositions — collectConnections reads roleID + x + y per entry.
        hasher.combine(nodePositions.count)
        for pos in nodePositions {
            hasher.combine(pos.roleID)
            hasher.combine(Int(pos.x.rounded()))
            hasher.combine(Int(pos.y.rounded()))
        }

        // roleDefinitions — only id, isSupervisor, dependencies are read.
        // Sort by id for deterministic hashing (input order shouldn't
        // invalidate the cache).
        hasher.combine(roleDefinitions.count)
        for role in roleDefinitions.sorted(by: { $0.id < $1.id }) {
            hasher.combine(role.id)
            hasher.combine(role.isSupervisor)
            hasher.combine(role.dependencies.requiredArtifacts.sorted())
            hasher.combine(role.dependencies.producesArtifacts.sorted())
        }

        // teamMembers — hash sorted IDs (Set hash is not stable across
        // launches; sorted-array hash is).
        hasher.combine(teamMembers.sorted())

        // nodeSizes — width drives port spread.
        hasher.combine(nodeSizes.count)
        for (id, size) in nodeSizes.sorted(by: { $0.key < $1.key }) {
            hasher.combine(id)
            hasher.combine(Int(size.width.rounded()))
            hasher.combine(Int(size.height.rounded()))
        }

        // fallbackNodeWidth — used when nodeSizes lacks an entry.
        hasher.combine(Int(fallbackNodeWidth.rounded()))

        return hasher.finalize()
    }
}
