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
    ///
    /// **Allocation-free.** This runs BEFORE the cache-hit check, so it is paid on
    /// every call including every hit — and it used to allocate `2R+3` fresh
    /// arrays getting there (`roleDefinitions.sorted`, two `sorted()` per role,
    /// `teamMembers.sorted()`, `nodeSizes.sorted()`). The sorts existed only to
    /// make the hash independent of iteration order, which a commutative fold
    /// gives for free — see `unorderedHash`. The memo itself stays: its gate is
    /// Θ(R·logR) against guarded work that nests four deep (Θ(N·a·R·p)), so the
    /// margin widens with team size rather than closing; the defect was the
    /// allocation, not the memo.
    private static func fingerprint(
        nodePositions: [TeamNodePosition],
        roleDefinitions: [TeamRoleDefinition],
        teamMembers: Set<String>,
        nodeSizes: [String: CGSize],
        fallbackNodeWidth: CGFloat
    ) -> Int {
        var hasher = Hasher()

        // nodePositions — collectConnections reads roleID + x + y per entry.
        // Array order is itself an input here, so this stays positional.
        hasher.combine(nodePositions.count)
        for pos in nodePositions {
            hasher.combine(pos.roleID)
            hasher.combine(Int(pos.x.rounded()))
            hasher.combine(Int(pos.y.rounded()))
        }

        // roleDefinitions — only id, isSupervisor, dependencies are read, and the
        // ORDER they arrive in must not invalidate the cache.
        hasher.combine(roleDefinitions.count)
        var rolesFold = 0
        for role in roleDefinitions {
            var roleHasher = Hasher()
            roleHasher.combine(role.id)
            roleHasher.combine(role.isSupervisor)
            roleHasher.combine(unorderedHash(role.dependencies.requiredArtifacts))
            roleHasher.combine(unorderedHash(role.dependencies.producesArtifacts))
            rolesFold = rolesFold &+ roleHasher.finalize()
        }
        hasher.combine(rolesFold)

        // teamMembers — a `Set`'s iteration order is not a function of its
        // contents, which is exactly what the fold neutralizes.
        hasher.combine(teamMembers.count)
        hasher.combine(unorderedHash(teamMembers))

        // nodeSizes — width drives port spread.
        hasher.combine(nodeSizes.count)
        var sizesFold = 0
        for (id, size) in nodeSizes {
            var sizeHasher = Hasher()
            sizeHasher.combine(id)
            sizeHasher.combine(Int(size.width.rounded()))
            sizeHasher.combine(Int(size.height.rounded()))
            sizesFold = sizesFold &+ sizeHasher.finalize()
        }
        hasher.combine(sizesFold)

        // fallbackNodeWidth — used when nodeSizes lacks an entry.
        hasher.combine(Int(fallbackNodeWidth.rounded()))

        return hasher.finalize()
    }

    /// Commutative combination of per-element hashes: equal collections agree
    /// regardless of iteration order, with no intermediate array.
    ///
    /// Wrapping ADDITION, not XOR: xor cancels duplicates, so `["a", "a"]` and
    /// `[]` would collide, and an artifact list is not a set.
    private static func unorderedHash<S: Sequence>(_ elements: S) -> Int
        where S.Element: Hashable {
        var accumulator = 0
        for element in elements {
            var hasher = Hasher()
            hasher.combine(element)
            accumulator = accumulator &+ hasher.finalize()
        }
        return accumulator
    }
}
