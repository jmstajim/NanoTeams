import SwiftUI
import XCTest
@testable import NanoTeams

/// `EdgeFade` converts a fade length in POINTS into the relative gradient stop a mask needs.
///
/// The defect it was extracted to end: both fade sites wrote the stop by hand as a fraction
/// (`0.88` on the question preview, `0.92` on the chip row), so the band grew with its
/// container — 24pt in an unmeasured pane, 58pt in a tall one, where it dimmed the last three
/// and a half lines of the question a Supervisor was trying to read. A fraction cannot be
/// wrong at the size it was authored at, which is why nothing looked broken to its author.
/// `testFadeStart_isNotAConstantFraction` is the pin that fails if the arithmetic regresses
/// to one.
///
/// The other half is totality. A mask reads alpha, so a `NaN` stop location does not throw or
/// crash — `CGGradient` orders its stops by a comparison false in both directions and can come
/// back empty, which paints alpha 0 over the whole frame and makes the masked content
/// silently VANISH. Both call sites feed this from geometry that is `.infinity` on the first
/// frame, so the degenerate-input tests below are the live path, not hypotheticals.
@MainActor
final class EdgeFadeTests: XCTestCase {

    /// Frame lengths spanning both sites: the collapsed-pane floor, a chip row, a mid pane,
    /// the tall pane where the fraction did its damage, and an absurd one.
    private let frameLengths: [CGFloat] = [80, 120, 240, 480, 1000]

    // MARK: - The point of the type: a band measured in points

    func testFadeStart_bandIsTheRequestedPointLength_atEveryFrameLength() {
        for length in frameLengths {
            let start = EdgeFade.fadeStart(length: length, fade: EdgeFade.standard)
            let band = (1 - start) * length
            XCTAssertEqual(
                band, EdgeFade.standard, accuracy: 0.0001,
                "a \(EdgeFade.standard)pt band must stay \(EdgeFade.standard)pt at a \(length)pt frame, "
                    + "got \(band)pt — the fraction defect exactly")
        }
    }

    /// The regression pin. A constant fraction produces the SAME stop at every frame length;
    /// a fixed point band cannot. Also checks the two literals that were actually in the tree,
    /// so a copy-paste revival is named rather than merely implied.
    func testFadeStart_isNotAConstantFraction() {
        let short = EdgeFade.fadeStart(length: 120, fade: EdgeFade.standard)
        let tall = EdgeFade.fadeStart(length: 480, fade: EdgeFade.standard)
        XCTAssertNotEqual(short, tall, accuracy: 0.0001,
                          "equal stops at 120pt and 480pt mean the band is a fraction again")
        XCTAssertGreaterThan(tall, short, "a taller frame must fade a smaller SHARE of itself")
        XCTAssertNotEqual(tall, 0.88, accuracy: 0.001, "0.88 was the question card's old literal")
        XCTAssertNotEqual(tall, 0.92, accuracy: 0.001, "0.92 was the chip row's old literal")
    }

    func testFadeStart_tallerFrameFadesASmallerShare_monotonically() {
        let stops = frameLengths.map { EdgeFade.fadeStart(length: $0, fade: EdgeFade.standard) }
        for (a, b) in zip(stops, stops.dropFirst()) {
            XCTAssertLessThan(a, b, "fadeStart must rise monotonically with frame length")
        }
    }

    // MARK: - Degenerate lengths (the live first-frame path)

    func testFadeStart_zeroLength_isFullyOpaque() {
        XCTAssertEqual(EdgeFade.fadeStart(length: 0, fade: EdgeFade.standard), 1)
    }

    func testFadeStart_negativeLength_isFullyOpaque() {
        XCTAssertEqual(EdgeFade.fadeStart(length: -240, fade: EdgeFade.standard), 1)
    }

    /// `TeamActivityFeedView` seeds its measured pane height with `.infinity` and
    /// `TeamActivityComposer` seeds `questionContentHeight` the same way, so this is the first
    /// frame of every panel, not a contrived input.
    func testFadeStart_infiniteLength_isFullyOpaque() {
        XCTAssertEqual(EdgeFade.fadeStart(length: .infinity, fade: EdgeFade.standard), 1)
    }

    func testFadeStart_nanLength_isFullyOpaque() {
        XCTAssertEqual(EdgeFade.fadeStart(length: .nan, fade: EdgeFade.standard), 1)
    }

    // MARK: - Degenerate bands

    func testFadeStart_zeroOrNegativeFade_isFullyOpaque() {
        XCTAssertEqual(EdgeFade.fadeStart(length: 480, fade: 0), 1)
        XCTAssertEqual(EdgeFade.fadeStart(length: 480, fade: -20), 1)
    }

    func testFadeStart_nonFiniteFade_isFullyOpaque() {
        XCTAssertEqual(EdgeFade.fadeStart(length: 480, fade: .infinity), 1)
        XCTAssertEqual(EdgeFade.fadeStart(length: 480, fade: .nan), 1)
    }

    func testFadeStart_fadeEqualToLength_fadesTheWholeFrame() {
        XCTAssertEqual(EdgeFade.fadeStart(length: 20, fade: 20), 0)
    }

    func testFadeStart_fadeLongerThanLength_clampsToZeroNotNegative() {
        let start = EdgeFade.fadeStart(length: 10, fade: EdgeFade.standard)
        XCTAssertEqual(start, 0, "a band longer than the frame fades all of it")
        XCTAssertGreaterThanOrEqual(start, 0, "a negative location is outside the gradient contract")
    }

    /// The blanket guarantee the mask depends on: whatever geometry arrives, the location is a
    /// real number inside the unit interval. A single NaN escaping here empties a card.
    func testFadeStart_isAlwaysFiniteInsideTheUnitInterval() {
        let inputs: [CGFloat] = [-1000, -1, 0, 0.5, 1, 19, 20, 21, 80, 480, 1e6, .infinity, -.infinity, .nan]
        for length in inputs {
            for fade in inputs {
                let start = EdgeFade.fadeStart(length: length, fade: fade)
                XCTAssertTrue(start.isFinite, "length=\(length) fade=\(fade) produced \(start)")
                XCTAssertTrue((0...1).contains(start), "length=\(length) fade=\(fade) produced \(start)")
            }
        }
    }

    // MARK: - Stops

    func testStops_runFromOpaqueToClearWithMonotonicLocations() {
        for length in frameLengths {
            let stops = EdgeFade.stops(length: length, fade: EdgeFade.standard)
            XCTAssertEqual(stops.count, 3)
            XCTAssertEqual(stops[0].location, 0)
            XCTAssertEqual(stops[2].location, 1)
            XCTAssertEqual(stops[0].color, .black)
            XCTAssertEqual(stops[1].color, .black)
            XCTAssertEqual(stops[2].color, .clear)
            XCTAssertLessThanOrEqual(stops[0].location, stops[1].location)
            XCTAssertLessThanOrEqual(stops[1].location, stops[2].location)
        }
    }

    func testStops_middleStopIsFadeStart() {
        let stops = EdgeFade.stops(length: 480, fade: EdgeFade.standard)
        XCTAssertEqual(stops[1].location,
                       EdgeFade.fadeStart(length: 480, fade: EdgeFade.standard),
                       accuracy: 0.0001)
    }

    func testStops_degenerateLength_producesNoVisibleFade() {
        for length in [CGFloat(0), .infinity, .nan] {
            let stops = EdgeFade.stops(length: length, fade: EdgeFade.standard)
            XCTAssertEqual(stops[1].location, 1,
                           "length=\(length) must collapse the fade, not produce a NaN location")
        }
    }

    // MARK: - Orientation

    func testPoints_locationOneLandsOnTheFadedEdge() {
        XCTAssertEqual(EdgeFade.points(for: .bottom).start, .top)
        XCTAssertEqual(EdgeFade.points(for: .bottom).end, .bottom)
        XCTAssertEqual(EdgeFade.points(for: .top).start, .bottom)
        XCTAssertEqual(EdgeFade.points(for: .top).end, .top)
        XCTAssertEqual(EdgeFade.points(for: .trailing).start, .leading)
        XCTAssertEqual(EdgeFade.points(for: .trailing).end, .trailing)
        XCTAssertEqual(EdgeFade.points(for: .leading).start, .trailing)
        XCTAssertEqual(EdgeFade.points(for: .leading).end, .leading)
    }

    func testEdgeIsVertical_matchesTheAxisTheLengthIsReadAlong() {
        XCTAssertTrue(EdgeFade.Edge.top.isVertical)
        XCTAssertTrue(EdgeFade.Edge.bottom.isVertical)
        XCTAssertFalse(EdgeFade.Edge.leading.isVertical)
        XCTAssertFalse(EdgeFade.Edge.trailing.isVertical)
    }

    // MARK: - Overflow gate

    func testIsOverflowing_contentPastContainer_isTrue() {
        XCTAssertTrue(EdgeFade.isOverflowing(contentLength: 420, containerLength: 300))
    }

    /// The chip row's defect: an exact fit must NOT fade, or the row promises a scroll that
    /// does nothing and dims the last chip's label for it.
    func testIsOverflowing_exactFit_isFalse() {
        XCTAssertFalse(EdgeFade.isOverflowing(contentLength: 300, containerLength: 300))
    }

    func testIsOverflowing_subPixelOverflow_isAbsorbedBySlack() {
        XCTAssertFalse(EdgeFade.isOverflowing(contentLength: 300.3, containerLength: 300))
        XCTAssertTrue(EdgeFade.isOverflowing(contentLength: 301, containerLength: 300))
    }

    func testIsOverflowing_nonFiniteGeometry_isFalse() {
        XCTAssertFalse(EdgeFade.isOverflowing(contentLength: .infinity, containerLength: 300))
        XCTAssertFalse(EdgeFade.isOverflowing(contentLength: 300, containerLength: .nan))
        XCTAssertFalse(EdgeFade.isOverflowing(contentLength: .nan, containerLength: .nan))
    }

    func testAxisGeometry_zero_readsAsNotOverflowing() {
        XCTAssertFalse(EdgeFade.AxisGeometry.zero.isOverflowing,
                       "the pre-measurement seed must not draw a fade")
    }

    func testAxisGeometry_delegatesToTheSamePredicate() {
        let geometry = EdgeFade.AxisGeometry(container: 300, content: 420)
        XCTAssertEqual(geometry.isOverflowing,
                       EdgeFade.isOverflowing(contentLength: 420, containerLength: 300))
        XCTAssertTrue(geometry.isOverflowing)
    }

    // MARK: - The token

    /// Asserted as a RELATION and a kind, not an equality restating the constant: the band is a
    /// LENGTH. Anything at or below 1 would be a fraction wearing a point label — the exact
    /// confusion this type exists to end.
    func testStandardBand_isAPointLength_notAFraction() {
        XCTAssertGreaterThan(EdgeFade.standard, 1)
        XCTAssertEqual(EdgeFade.standard, Spacing.l,
                       "the band matches the timeline fade in TeamActivityFeedView")
    }

    func testOverflowSlack_isSubPixel() {
        XCTAssertGreaterThan(EdgeFade.overflowSlack, 0)
        XCTAssertLessThan(EdgeFade.overflowSlack, 1,
                          "slack past a point would hide a real one-point overflow")
    }
}
