import SwiftUI
import XCTest

@testable import NanoTeams

/// The block-rendering half of `TerminalProgressBar` — the part that turns a fraction into
/// characters, ported from the design system's `ProgressBar.jsx`.
///
/// `@MainActor` because the statics live on a `@MainActor` view type, and every test is `async`:
/// a sync test method in a main-actor class is the shape that aborts on CI.
@MainActor
final class TerminalProgressBarTests: XCTestCase, @unchecked Sendable {

    private func bar(_ value: Double, cells: Int = 24) -> (fill: String, empty: String) {
        TerminalProgressBar.blocks(value: value, cells: cells)
    }

    // MARK: - The ends

    func testZero_isAllTrack() async {
        let bar = bar(0)
        XCTAssertEqual(bar.fill, "")
        XCTAssertEqual(bar.empty, String(repeating: "░", count: 24))
    }

    /// RED: emitting the `█` partial at a full bar → `full == cells` with a partial appended
    /// overflows the cell budget, and the bar renders one character wider than every other value.
    func testFull_isAllFillAndCarriesNoPartial() async {
        let bar = bar(1)
        XCTAssertEqual(bar.fill, String(repeating: "█", count: 24))
        XCTAssertEqual(bar.empty, "")
    }

    func testHalf_onACellBoundary_needsNoPartial() async {
        let bar = bar(0.5)
        XCTAssertEqual(bar.fill, String(repeating: "█", count: 12))
        XCTAssertEqual(bar.empty, String(repeating: "░", count: 12))
    }

    // MARK: - The partial cell

    /// The whole reason the bar is drawn with eighths rather than whole cells: at 24 cells a
    /// whole-cell bar only moves once every ~4%, so a build that is genuinely progressing looks
    /// frozen between steps.
    func testFractionOfACell_rendersAnEighthBlock() async {
        XCTAssertEqual(bar(0.5, cells: 1).fill, "▌")
        XCTAssertEqual(bar(0.125, cells: 1).fill, "▏")
        XCTAssertEqual(bar(0.875, cells: 1).fill, "▉")
    }

    /// RED: dropping the `partialIndex == 8` rollover → a value that rounds to a whole cell
    /// renders as index 8 of the partial table, which IS `█`, plus an unconsumed cell — the bar
    /// gains a character and the track loses none.
    func testAPartialThatRoundsToAWholeCell_becomesAWholeCell() async {
        let bar = bar(0.99, cells: 1)
        XCTAssertEqual(bar.fill, "█")
        XCTAssertEqual(bar.empty, "")
    }

    /// A zero-eighths partial contributes NO character — index 0 of the table is the empty
    /// string, not a space, so the cell stays available to the track.
    func testAZeroEighthPartial_contributesNothing() async {
        let bar = bar(2.0 / 24.0)
        XCTAssertEqual(bar.fill, "██")
        XCTAssertEqual(bar.empty.count, 22)
    }

    // MARK: - The invariant

    /// The bar occupies exactly `cells` columns at EVERY value. This is what makes it safe to put
    /// in a row beside other content: progress never changes the layout, only the paint.
    func testTheBarIsAlwaysExactlyCellsWide() async {
        for step in 0...200 {
            let value = Double(step) / 200
            let bar = bar(value)
            XCTAssertEqual(
                bar.fill.count + bar.empty.count, 24,
                "value \(value) rendered \(bar.fill.count) + \(bar.empty.count) columns")
        }
    }

    func testFillNeverShrinksAsValueGrows() async {
        var previous = 0
        for step in 0...200 {
            let width = bar(Double(step) / 200).fill.count
            XCTAssertGreaterThanOrEqual(width, previous, "went backwards at step \(step)")
            previous = width
        }
    }

    // MARK: - Degenerate input

    func testOutOfRangeValues_clampToTheEnds() async {
        XCTAssertEqual(bar(-1).fill, "")
        XCTAssertEqual(bar(-1).empty.count, 24)
        XCTAssertEqual(bar(7).fill.count, 24)
        XCTAssertEqual(bar(7).empty, "")
    }

    /// A non-finite fraction is an arithmetic accident upstream, and the bar must not report it
    /// as done: `nan` and `inf` both render an EMPTY track rather than a full one.
    func testNonFiniteValues_renderAnEmptyTrack() async {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(bar(value).fill, "", "\(value)")
            XCTAssertEqual(bar(value).empty.count, 24, "\(value)")
        }
    }

    /// RED: dropping the `max(1, cells)` floor → `String(repeating:count:)` with a negative count
    /// traps, so a zero-width bar crashes the app rather than drawing nothing.
    func testNonPositiveCellCounts_collapseToOneCell() async {
        XCTAssertEqual(bar(1, cells: 0).fill, "█")
        XCTAssertEqual(bar(1, cells: -5).fill, "█")
        XCTAssertEqual(bar(0, cells: 0).empty, "░")
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
}
