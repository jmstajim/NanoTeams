import SwiftUI
import XCTest

@testable import NanoTeams

/// Pins the 4-point grid snap that coalesces sub-pixel resize deltas in
/// `TeamGraphView.onGeometryChange`. Without snapping, every 0.5–1 px
/// `inLiveResize` tick triggers a body re-evaluation; with it, identical
/// snapped sizes early-exit via `guard snapped != snappedViewSize`.
///
/// `nonisolated` (no `@MainActor`) so each test pins the contract that
/// `snap` is pure math — independent of view isolation. A future
/// contributor reaching into SwiftUI state from `snap` would break this.
final class TeamGraphViewSnapTests: XCTestCase {

    // MARK: - Grid rounding

    func testSnap_alignedSize_isUnchanged() {
        XCTAssertEqual(TeamGraphView.snap(CGSize(width: 100, height: 200)),
                       CGSize(width: 100, height: 200))
    }

    func testSnap_subPixelJitterBelow2_roundsDown() {
        // 100.9 is closer to 100 than 104 — banker's rounding via `.rounded()`
        // breaks ties toward even, but 100.9 isn't a tie.
        XCTAssertEqual(TeamGraphView.snap(CGSize(width: 100.9, height: 200.7)),
                       CGSize(width: 100, height: 200))
    }

    func testSnap_subPixelJitterAbove2_roundsUp() {
        XCTAssertEqual(TeamGraphView.snap(CGSize(width: 102.1, height: 202.5)),
                       CGSize(width: 104, height: 204))
    }

    func testSnap_oddIntegers_snapToNearestGrid() {
        XCTAssertEqual(TeamGraphView.snap(CGSize(width: 101, height: 103)),
                       CGSize(width: 100, height: 104))
        XCTAssertEqual(TeamGraphView.snap(CGSize(width: 99, height: 97)),
                       CGSize(width: 100, height: 96))
    }

    // MARK: - Coalescing invariant

    /// The whole point of snap: many distinct sub-pixel sizes collapse to
    /// the same grid value, so the `guard snapped != snappedViewSize` in
    /// `onGeometryChange` short-circuits the body re-eval.
    func testSnap_coalescesNearbySizes_intoSameOutput() {
        let inputs: [CGSize] = [
            CGSize(width: 100.1, height: 200.2),
            CGSize(width: 100.4, height: 200.0),
            CGSize(width: 99.9,  height: 199.6),
            CGSize(width: 101.5, height: 200.4),
        ]
        let outputs = Set(inputs.map { TeamGraphView.snap($0) })
        XCTAssertEqual(outputs.count, 1,
                       "All four near-100×200 sizes must snap to the same grid value.")
        XCTAssertEqual(outputs.first, CGSize(width: 100, height: 200))
    }

    // MARK: - Boundary behavior

    func testSnap_zero_isZero() {
        XCTAssertEqual(TeamGraphView.snap(.zero), .zero)
    }

    func testSnap_negativeWidth_snapsToNegativeGrid() {
        // Defense-in-depth: SwiftUI doesn't pass negative sizes, but if a
        // future caller does, the result must still be deterministic
        // (not crash, not return NaN).
        XCTAssertEqual(TeamGraphView.snap(CGSize(width: -100, height: -200)),
                       CGSize(width: -100, height: -200))
    }

    /// Idempotence: snapping an already-snapped value is a no-op. This is
    /// what makes the `guard snapped != snappedViewSize` early-exit work.
    func testSnap_isIdempotent() {
        let raw = CGSize(width: 137.7, height: 421.3)
        let once = TeamGraphView.snap(raw)
        let twice = TeamGraphView.snap(once)
        XCTAssertEqual(once, twice)
    }
}
