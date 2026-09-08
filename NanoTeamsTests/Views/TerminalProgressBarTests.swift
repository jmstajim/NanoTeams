import SwiftUI
import XCTest

@testable import NanoTeams

/// The block-rendering half of `TerminalProgressBar` — the part that turns a fraction into
/// characters, ported from the design system's `ProgressBar.jsx`.
///
/// The bar is drawn as two LAYERS on one mono grid: a track of `cells` whole blocks, and the
/// fill on top of it. That is what these tests describe, and it is not a stylistic choice —
/// the previous shape subtracted the partial glyph's whole cell from the track while the glyph
/// covers only its own fraction of it, leaving bare background between the lit run and the
/// dark one (measured: 0.849pt behind `▉`, 5.951pt behind `▏` at 11pt).
///
/// `@MainActor` because the statics live on a `@MainActor` view type, and every test is `async`:
/// a sync test method in a main-actor class is the shape that aborts on CI.
@MainActor
final class TerminalProgressBarTests: XCTestCase, @unchecked Sendable {

    private func bar(_ value: Double, cells: Int = 24) -> (fill: String, track: String) {
        TerminalProgressBar.blocks(value: value, cells: cells)
    }

    // MARK: - The ends

    func testZero_isAllTrackAndNoFill() async {
        let bar = bar(0)
        XCTAssertEqual(bar.fill, "")
        XCTAssertEqual(bar.track, String(repeating: "█", count: 24))
    }

    /// RED: emitting the `█` partial at a full bar → `full == cells` with a partial appended
    /// overflows the cell budget, and the fill renders one character wider than the track.
    func testFull_isAllFillAndCarriesNoPartial() async {
        let bar = bar(1)
        XCTAssertEqual(bar.fill, String(repeating: "█", count: 24))
        XCTAssertEqual(bar.track, String(repeating: "█", count: 24))
    }

    func testHalf_onACellBoundary_needsNoPartial() async {
        let bar = bar(0.5)
        XCTAssertEqual(bar.fill, String(repeating: "█", count: 12))
    }

    // MARK: - The gap

    /// RED: the pre-2026-09-08 arithmetic (`empty = cells - full - 1`) → this fails, and the
    /// visible symptom is a hole in the bar. The partial glyph is left-aligned inside its cell
    /// and covers only its own fraction; subtracting the WHOLE cell from the track leaves the
    /// remainder painted with nothing at all.
    ///
    /// At `cells: 4` / 42% the old shape produced `█▋░░`: 2.551pt of bare background behind
    /// `▋` plus `░`'s own 0.569pt left side bearing — 3.12pt of hole in a 27pt bar.
    func testThePartialCell_doesNotEatTheTrackUnderneathIt() async {
        let bar = bar(0.42, cells: 4)
        XCTAssertEqual(bar.fill, "█▋", "one whole cell plus five eighths")
        XCTAssertEqual(
            bar.track, "████",
            "the track spans every cell — the partial is drawn OVER it, not instead of it")
    }

    /// The track is the layer that establishes width, so it is `cells` glyphs at every value —
    /// including the ends, where the fill is empty or complete.
    func testTheTrackIsAlwaysExactlyCellsWide() async {
        for step in 0...200 {
            let value = Double(step) / 200
            for cells in [1, 4, 24] {
                let bar = bar(value, cells: cells)
                XCTAssertEqual(
                    bar.track.count, cells,
                    "value \(value) at \(cells) cells rendered a \(bar.track.count)-glyph track")
            }
        }
    }

    /// The fill is drawn on top of the track and must never outrun it, or it would widen the
    /// `ZStack` and the bar would change size with its value.
    func testTheFillNeverOutrunsTheTrack() async {
        for step in 0...200 {
            let value = Double(step) / 200
            for cells in [1, 4, 24] {
                let bar = bar(value, cells: cells)
                XCTAssertLessThanOrEqual(
                    bar.fill.count, cells,
                    "value \(value) at \(cells) cells overflowed with \(bar.fill)")
            }
        }
    }

    /// The track is one glyph — the same `█` the fill uses — because that is the only character
    /// whose ink matches the fill's on BOTH axes. `░` and `▒` are each ~0.12pt shorter than `█`
    /// at the top and the bottom (measured at 11pt regular and 14pt medium), so a shade track
    /// leaves the fill standing proud of its own groove.
    func testTheTrackIsDrawnWithTheSameGlyphAsTheFill() async {
        XCTAssertEqual(Set(bar(0.42, cells: 4).track), ["█"])
        XCTAssertEqual(Set(bar(0, cells: 4).track), ["█"])
    }

    // MARK: - The partial cell

    /// The whole reason the bar is drawn with eighths rather than whole cells: at four cells a
    /// whole-cell bar only moves once every 25%, which is coarser than the fill indicator's
    /// question can tolerate. One eighth of one cell is 3.125%.
    func testFractionOfACell_rendersAnEighthBlock() async {
        XCTAssertEqual(bar(0.5, cells: 1).fill, "▌")
        XCTAssertEqual(bar(0.125, cells: 1).fill, "▏")
        XCTAssertEqual(bar(0.875, cells: 1).fill, "▉")
    }

    /// The eighth-index rollover survives: a partial that rounds up to a whole cell IS a whole
    /// cell, as long as doing so does not complete the bar.
    func testAPartialThatRoundsToAWholeCell_becomesAWholeCell() async {
        XCTAssertEqual(bar(1.99 / 4, cells: 4).fill, "██", "7.92 eighths rounds to a whole cell")
    }

    /// A zero-eighths partial contributes NO character — index 0 of the table is the empty
    /// string, not a space.
    func testAZeroEighthPartial_contributesNothing() async {
        XCTAssertEqual(bar(2.0 / 24.0).fill, "██")
    }

    // MARK: - The two ends the glyphs get wrong

    /// RED: without the "complete only at 1" rule → `0.99 × 4 = 3.96` rolls over to four whole
    /// cells and the bar reads FULL at 99%. On the context-fill indicator that is a false
    /// alarm: "no room left" lights up while there is still room. `percentLabel` already
    /// refuses to print 100% early — for the NUMBER; this is the same rule for the GLYPHS.
    func testAlmostComplete_doesNotRenderAsComplete() async {
        for cells in [1, 4, 24] {
            let bar = bar(0.99, cells: cells)
            XCTAssertNotEqual(
                bar.fill, String(repeating: "█", count: cells),
                "99% rendered a complete \(cells)-cell bar")
        }
        // Where the rollover WOULD have completed the bar, the fill backs off to seven eighths
        // of the last cell — the same rendered width, one cell's paint short of done.
        XCTAssertEqual(bar(0.99, cells: 1).fill, "▉")
        XCTAssertEqual(bar(0.99, cells: 4).fill, "███▉")
    }

    /// The back-off costs no width: a bar one paint-step from complete occupies exactly as many
    /// columns as a complete one, so nothing beside it moves on the last step.
    func testTheBackOffAtTheTop_doesNotChangeTheRenderedWidth() async {
        for cells in [1, 4, 24] {
            XCTAssertEqual(bar(0.99, cells: cells).fill.count, bar(1, cells: cells).fill.count)
        }
    }

    /// RED: without the "never empty above zero" rule → `round(0.04 × 8) == 0` at 1% of four
    /// cells, so a role that has started filling its context shows exactly what a role that has
    /// sent nothing shows.
    func testAlmostEmpty_doesNotRenderAsEmpty() async {
        for cells in [1, 4, 24] {
            XCTAssertEqual(bar(0.01, cells: cells).fill.isEmpty, false, "1% at \(cells) cells")
        }
        XCTAssertEqual(bar(0.01, cells: 4).fill, "▏", "the smallest mark the grid has")
    }

    /// Exactly zero is the one value that draws nothing: an empty bar claims "nothing yet",
    /// which is true only there.
    func testExactlyZero_isTheOnlyEmptyFill() async {
        XCTAssertTrue(bar(0, cells: 4).fill.isEmpty)
        XCTAssertFalse(bar(0.0001, cells: 4).fill.isEmpty)
    }

    // MARK: - The invariant

    func testFillNeverShrinksAsValueGrows() async {
        for cells in [1, 4, 24] {
            var previous = 0
            for step in 0...200 {
                let width = bar(Double(step) / 200, cells: cells).fill.count
                XCTAssertGreaterThanOrEqual(
                    width, previous, "went backwards at step \(step) of \(cells) cells")
                previous = width
            }
        }
    }

    // MARK: - Degenerate input

    func testOutOfRangeValues_clampToTheEnds() async {
        XCTAssertEqual(bar(-1).fill, "")
        XCTAssertEqual(bar(-1).track.count, 24)
        XCTAssertEqual(bar(7).fill, String(repeating: "█", count: 24), "clamped, then complete")
    }

    /// A non-finite fraction is an arithmetic accident upstream, and the bar must not report it
    /// as done: `nan` and `inf` both render an EMPTY fill rather than a full one.
    func testNonFiniteValues_renderAnEmptyFill() async {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(bar(value).fill, "", "\(value)")
            XCTAssertEqual(bar(value).track.count, 24, "\(value)")
        }
    }

    /// RED: dropping the `max(1, cells)` floor → `String(repeating:count:)` with a negative count
    /// traps, so a zero-width bar crashes the app rather than drawing nothing.
    func testNonPositiveCellCounts_collapseToOneCell() async {
        XCTAssertEqual(bar(1, cells: 0).fill, "█")
        XCTAssertEqual(bar(1, cells: -5).fill, "█")
        XCTAssertEqual(bar(0, cells: 0).track, "█")
    }

    // MARK: - Clamp + label

    func testClamped_mapsOntoTheUnitInterval() async {
        XCTAssertEqual(TerminalProgressBar.clamped(-3), 0)
        XCTAssertEqual(TerminalProgressBar.clamped(0.25), 0.25)
        XCTAssertEqual(TerminalProgressBar.clamped(3), 1)
        XCTAssertEqual(TerminalProgressBar.clamped(.nan), 0)
    }

    /// Whole percent only — 24 cells cannot show a tenth of a percent, and printing one would
    /// claim a resolution the bar does not have.
    func testPercentLabel_isWholePercent() async {
        XCTAssertEqual(TerminalProgressBar.percentLabel(0), "0%")
        XCTAssertEqual(TerminalProgressBar.percentLabel(1), "100%")
        XCTAssertEqual(TerminalProgressBar.percentLabel(0.535), "54%")
        XCTAssertEqual(TerminalProgressBar.percentLabel(0.004), "0%")
        XCTAssertEqual(TerminalProgressBar.percentLabel(.nan), "0%")
    }

    /// RED: the plain `Math.round` the JSX uses → 99.6% prints "100%" while the work is still
    /// running, which is the one number a progress readout must never show. Only a value that is
    /// genuinely 1 reaches 100.
    func testPercentLabel_reaches100OnlyWhenActuallyComplete() async {
        XCTAssertEqual(TerminalProgressBar.percentLabel(0.996), "99%")
        XCTAssertEqual(TerminalProgressBar.percentLabel(0.9999), "99%")
        XCTAssertEqual(TerminalProgressBar.percentLabel(1), "100%")
        XCTAssertEqual(TerminalProgressBar.percentLabel(1.5), "100%", "clamped, then complete")
    }

    /// The glyphs and the number must agree at the ends, since they sit side by side in the
    /// settings card: neither reaches "complete" before the value genuinely does.
    func testTheGlyphsAndTheNumberAgreeAtTheTop() async {
        XCTAssertEqual(TerminalProgressBar.percentLabel(0.996), "99%")
        XCTAssertNotEqual(bar(0.996, cells: 24).fill, String(repeating: "█", count: 24))
        XCTAssertEqual(TerminalProgressBar.percentLabel(1), "100%")
        XCTAssertEqual(bar(1, cells: 24).fill, String(repeating: "█", count: 24))
    }
}
