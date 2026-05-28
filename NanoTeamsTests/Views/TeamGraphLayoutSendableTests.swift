import XCTest

@testable import NanoTeams

/// Compile-time Sendability pin for `TeamGraphLayoutCache.Layout` and its
/// nested `[TeamGraphCanvasGeometry.ConnectionInfo]` payload.
///
/// Pre-fix both types inherit `@MainActor` from `SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor` (the app target default). That makes them Sendable *only via*
/// global-actor isolation — calling `Layout.empty` from a nonisolated context
/// fails. The post-fix changes:
///
/// 1. Mark `TeamGraphCanvasGeometry.ConnectionInfo: Sendable` and `nonisolated`.
/// 2. Mark `TeamGraphLayoutCache.Layout: Sendable` and `nonisolated`.
///
/// `Sendable` conformance becomes source-visible and isolation-independent;
/// a cache hit can be propagated across actors without an `assumeIsolated` /
/// `MainActor.run` hop. These tests live in a `nonisolated` (XCTestCase
/// default) class so the compile-time isolation check is meaningful — a
/// `@MainActor` test class would mask the bug.
final class TeamGraphLayoutSendableTests: XCTestCase {

    /// The load-bearing assertion: `Layout` is constructable AND its
    /// `.empty` static is reachable from a nonisolated context. If `Layout`
    /// were `@MainActor`-isolated (the pre-fix state), this method would
    /// fail to compile with
    /// "main actor-isolated static property 'empty' can not be referenced
    /// from a nonisolated context".
    func testLayout_emptyIsReachableFromNonisolatedContext() {
        let layout = TeamGraphLayoutCache.Layout.empty
        XCTAssertTrue(layout.connections.isEmpty)
        XCTAssertTrue(layout.sourceOffsets.isEmpty)
        XCTAssertTrue(layout.targetOffsets.isEmpty)
    }

    /// `ConnectionInfo` must be constructable from a nonisolated context so
    /// it can flow inside `Layout.connections` without dragging an isolation
    /// requirement.
    func testConnectionInfo_isConstructableFromNonisolatedContext() {
        let info = TeamGraphCanvasGeometry.ConnectionInfo(
            producerID: "a",
            consumerID: "b",
            artifactName: "Spec",
            fromPos: TeamNodePosition(roleID: "a", x: 0, y: 0),
            toPos: TeamNodePosition(roleID: "b", x: 100, y: 100)
        )
        XCTAssertEqual(info.producerID, "a")
        XCTAssertEqual(info.consumerID, "b")
    }

    /// Type-level Sendable conformance pin: `Layout` and `ConnectionInfo`
    /// must satisfy a `Sendable` generic constraint. A generic helper that
    /// requires `T: Sendable` won't compile if the constraint is unmet —
    /// the call site is the assertion.
    func testLayoutAndConnectionInfo_conformToSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(TeamGraphLayoutCache.Layout.self)
        requireSendable(TeamGraphCanvasGeometry.ConnectionInfo.self)
    }

    /// End-to-end: a `Layout` instance can cross an actor boundary into a
    /// detached Task. Pre-fix this fails the Swift 6 strict-concurrency
    /// check because the value carries `@MainActor` isolation; post-fix the
    /// value is `nonisolated Sendable` and crosses freely.
    func testLayout_crossesActorBoundary_inDetachedTask() async {
        let layout = TeamGraphLayoutCache.Layout(
            connections: [],
            sourceOffsets: [0: 10],
            targetOffsets: [1: 20]
        )
        let sourceCount = await Task.detached {
            layout.sourceOffsets.count
        }.value
        XCTAssertEqual(sourceCount, 1)
    }
}
