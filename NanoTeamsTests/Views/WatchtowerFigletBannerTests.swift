import XCTest
@testable import NanoTeams

/// Tests the pure decryption-wave policy of `WatchtowerFiglet`. Every helper is
/// `nonisolated static`, so this suite needs no `@MainActor` and constructs no
/// view — sidestepping the sync-test main-actor abort gotcha (CLAUDE.md).
final class WatchtowerFigletBannerTests: XCTestCase {

    private let columnCount = WatchtowerFiglet.columnCount
    private let rowCount = WatchtowerFiglet.bannerRows.count

    // MARK: - Data sanity

    func testLetters_areNanoteams() {
        XCTAssertEqual(WatchtowerFiglet.letters, Array("NANOTEAMS"))
    }

    func testBannerRows_areRectangular_allEqualColumnCount() {
        XCTAssertEqual(WatchtowerFiglet.bannerRows.count, 4)
        for (i, row) in WatchtowerFiglet.bannerRows.enumerated() {
            XCTAssertEqual(row.count, columnCount, "row \(i) width must equal columnCount")
        }
    }

    func testColumnCount_equalsSumOfLetterWidths() {
        let expected = WatchtowerFiglet.letters.reduce(0) { $0 + (WatchtowerFiglet.fig[$1]?.first?.count ?? 0) }
        XCTAssertEqual(columnCount, expected)
        XCTAssertEqual(columnCount, 62)   // concrete pin for "NANOTEAMS"
    }

    // MARK: - groupForRow / sync groups

    func testRowSyncGroups_rows0and1share_2and3independent() {
        let g = WatchtowerFiglet.rowSyncGroups
        XCTAssertEqual(WatchtowerFiglet.groupForRow(0, rowSyncGroups: g), WatchtowerFiglet.groupForRow(1, rowSyncGroups: g), "rows 0 and 1 are one group")
        XCTAssertNotEqual(WatchtowerFiglet.groupForRow(1, rowSyncGroups: g), WatchtowerFiglet.groupForRow(2, rowSyncGroups: g))
        XCTAssertNotEqual(WatchtowerFiglet.groupForRow(2, rowSyncGroups: g), WatchtowerFiglet.groupForRow(3, rowSyncGroups: g))
    }

    func testGroupForRow_outOfRange_isOwnGroup() {
        XCTAssertEqual(WatchtowerFiglet.groupForRow(9, rowSyncGroups: [0, 0, 1, 2]), 9)
    }

    // MARK: - makeRowLags (per-group; synced rows share a lag)

    func testMakeRowLags_syncedRowsShareLag() {
        var rng = SeededGenerator(seed: 3)
        let lags = WatchtowerFiglet.makeRowLags(rowCount: 4, maxLag: 8, rowSyncGroups: [0, 0, 1, 2], using: &rng)
        XCTAssertEqual(lags.count, 4)
        XCTAssertEqual(lags[0], lags[1], "rows 0 and 1 (one group) must share a lag → appear in sync")
        for lag in lags { XCTAssertTrue((0...8).contains(lag)) }
    }

    func testMakeRowLags_zeroRows_empty() {
        var rng = SeededGenerator(seed: 3)
        XCTAssertTrue(WatchtowerFiglet.makeRowLags(rowCount: 0, maxLag: 8, rowSyncGroups: [0, 0, 1, 2], using: &rng).isEmpty)
    }

    func testMakeRowLags_zeroMax_allZero() {
        var rng = SeededGenerator(seed: 3)
        XCTAssertEqual(WatchtowerFiglet.makeRowLags(rowCount: 4, maxLag: 0, rowSyncGroups: [0, 0, 1, 2], using: &rng), [0, 0, 0, 0])
    }

    func testMakeRowLags_deterministicForSameSeed() {
        var a = SeededGenerator(seed: 9); var b = SeededGenerator(seed: 9)
        XCTAssertEqual(
            WatchtowerFiglet.makeRowLags(rowCount: 4, maxLag: 8, rowSyncGroups: [0, 0, 1, 2], using: &a),
            WatchtowerFiglet.makeRowLags(rowCount: 4, maxLag: 8, rowSyncGroups: [0, 0, 1, 2], using: &b)
        )
    }

    // MARK: - makeCellSettle (the "1 to 6 symbols" knob)

    func testMakeCellSettle_shapeAndRange_atLeastOne() {
        var rng = SeededGenerator(seed: 5)
        let settle = WatchtowerFiglet.makeCellSettle(rowCount: rowCount, columnCount: columnCount, maxSettle: 6, using: &rng)
        XCTAssertEqual(settle.count, rowCount)
        for row in settle {
            XCTAssertEqual(row.count, columnCount)
            for s in row { XCTAssertTrue((1...6).contains(s), "settle \(s) out of [1,6] — every cell flips at least once") }
        }
    }

    func testMakeCellSettle_spansTheRange() {
        // Over a full grid we expect both extremes (a 1-flip cell and a 6-flip
        // cell) to appear — "где-то 1 символ, где-то 6".
        var rng = SeededGenerator(seed: 5)
        let settle = WatchtowerFiglet.makeCellSettle(rowCount: rowCount, columnCount: columnCount, maxSettle: 6, using: &rng).flatMap { $0 }
        XCTAssertTrue(settle.contains(1), "some cell should settle in a single flip")
        XCTAssertTrue(settle.contains(6), "some cell should take the full six flips")
    }

    func testMakeCellSettle_maxClampedToOne() {
        var rng = SeededGenerator(seed: 5)
        let settle = WatchtowerFiglet.makeCellSettle(rowCount: 2, columnCount: 3, maxSettle: 0, using: &rng)
        XCTAssertEqual(settle, [[1, 1, 1], [1, 1, 1]], "maxSettle < 1 clamps to a single flip")
    }

    func testMakeCellSettle_deterministicForSameSeed() {
        var a = SeededGenerator(seed: 13)
        var b = SeededGenerator(seed: 13)
        XCTAssertEqual(
            WatchtowerFiglet.makeCellSettle(rowCount: 4, columnCount: 10, maxSettle: 6, using: &a),
            WatchtowerFiglet.makeCellSettle(rowCount: 4, columnCount: 10, maxSettle: 6, using: &b)
        )
    }

    // MARK: - cellStart / cellThreshold

    func testCellStart_columnPlusRowLag() {
        let lags = [0, 5, 2, 7]
        XCTAssertEqual(WatchtowerFiglet.cellStart(row: 0, column: 10, rowLags: lags), 10)
        XCTAssertEqual(WatchtowerFiglet.cellStart(row: 1, column: 10, rowLags: lags), 15)
        XCTAssertEqual(WatchtowerFiglet.cellStart(row: 3, column: 0, rowLags: lags), 7)
    }

    func testCellStart_missingLag_fallsBackToZero() {
        XCTAssertEqual(WatchtowerFiglet.cellStart(row: 9, column: 4, rowLags: [1, 2]), 4)
    }

    func testCellThreshold_startPlusSettle() {
        let lags = [3]
        let settle = [[1, 6, 4]]
        XCTAssertEqual(WatchtowerFiglet.cellThreshold(row: 0, column: 0, rowLags: lags, cellSettle: settle), 0 + 3 + 1)
        XCTAssertEqual(WatchtowerFiglet.cellThreshold(row: 0, column: 1, rowLags: lags, cellSettle: settle), 1 + 3 + 6)
        XCTAssertEqual(WatchtowerFiglet.cellThreshold(row: 0, column: 2, rowLags: lags, cellSettle: settle), 2 + 3 + 4)
    }

    func testCellThreshold_missingSettle_usesOne() {
        XCTAssertEqual(WatchtowerFiglet.cellThreshold(row: 0, column: 5, rowLags: [], cellSettle: []), 5 + 0 + 1)
    }

    // MARK: - cellPhase

    func testCellPhase_aheadActiveLocked() {
        // start 4, threshold 7 (settle 3): active window is frames [4, 7).
        XCTAssertEqual(WatchtowerFiglet.cellPhase(frame: 3, start: 4, threshold: 7), .ahead)
        XCTAssertEqual(WatchtowerFiglet.cellPhase(frame: 4, start: 4, threshold: 7), .active)
        XCTAssertEqual(WatchtowerFiglet.cellPhase(frame: 6, start: 4, threshold: 7), .active)
        XCTAssertEqual(WatchtowerFiglet.cellPhase(frame: 7, start: 4, threshold: 7), .locked)
    }

    func testCellPhase_activeFrameCount_equalsSettle() {
        // The cell is active for exactly `settle` frames — it shows exactly that
        // many scramble symbols before locking ("1 symbol here, 6 there").
        for settle in 1...6 {
            let start = 10
            let threshold = start + settle
            let activeFrames = (0...(threshold + 5)).filter {
                WatchtowerFiglet.cellPhase(frame: $0, start: start, threshold: threshold) == .active
            }.count
            XCTAssertEqual(activeFrames, settle, "a settle-\(settle) cell must show exactly \(settle) scramble symbols")
        }
    }

    // MARK: - decodeLength

    func testRowDecodeLength_perRowMaxThreshold() {
        let lags = [0, 4]
        let settle = [[1, 1, 1], [1, 1, 6]]   // 2×3 grid
        XCTAssertEqual(WatchtowerFiglet.rowDecodeLength(row: 0, columnCount: 3, rowLags: lags, cellSettle: settle), 3)   // col2: 2+0+1
        XCTAssertEqual(WatchtowerFiglet.rowDecodeLength(row: 1, columnCount: 3, rowLags: lags, cellSettle: settle), 12)  // col2: 2+4+6
    }

    func testDecodeLength_isMaxOfRowLengths() {
        let lags = [0, 4]
        let settle = [[1, 1, 1], [1, 1, 6]]   // 2×3 grid
        XCTAssertEqual(WatchtowerFiglet.decodeLength(rowCount: 2, columnCount: 3, rowLags: lags, cellSettle: settle), 12)
    }

    func testDecodeLength_emptyGrid_isZero() {
        XCTAssertEqual(WatchtowerFiglet.decodeLength(rowCount: 0, columnCount: 0, rowLags: [], cellSettle: []), 0)
    }

    // MARK: - stepGroupedFrames (synced rows together, groups independent)

    private let groups = [0, 0, 1, 2]   // rows 0,1 synced; 2 and 3 independent

    func testStepGroupedFrames_syncedRowsAlwaysShareFrame() {
        // Across many ticks, rows 0 and 1 stay equal → synchronous appearance.
        for seed in UInt64(0)..<30 {
            var rng = SeededGenerator(seed: seed)
            var frames = [0, 0, 0, 0]
            for _ in 0..<40 {
                frames = WatchtowerFiglet.stepGroupedFrames(frames, totals: [50, 50, 50, 50], rowSyncGroups: groups, rollbackProbability: 0.3, maxRollback: 3, using: &rng)
                XCTAssertEqual(frames[0], frames[1], "seed \(seed): rows 0 and 1 must always share a frame")
            }
        }
    }

    func testStepGroupedFrames_noRollback_eachGroupAdvancesOnce() {
        var rng = SeededGenerator(seed: 1)
        let out = WatchtowerFiglet.stepGroupedFrames([5, 5, 3, 7], totals: [50, 50, 50, 50], rowSyncGroups: groups, rollbackProbability: 0, maxRollback: 3, using: &rng)
        XCTAssertEqual(out, [6, 6, 4, 8], "group {0,1} steps once together; groups {2},{3} each +1")
    }

    func testStepGroupedFrames_alwaysRollback_syncedRowsRewindTogether() {
        var rng = SeededGenerator(seed: 1)
        let after = WatchtowerFiglet.stepGroupedFrames([20, 20, 20, 20], totals: [50, 50, 50, 50], rowSyncGroups: groups, rollbackProbability: 1, maxRollback: 3, using: &rng)
        XCTAssertEqual(after[0], after[1], "synced rows rewind together")
        for a in after { XCTAssertTrue((17...19).contains(a)) }
    }

    func testStepGroupedFrames_groupRunsToMaxMemberTotal() {
        // Group {0,1} with member totals [5, 12]: a forward step at frame 5 must
        // advance to 6 (capped by the LARGER member total 12), not clamp at 5.
        var rng = SeededGenerator(seed: 1)
        let out = WatchtowerFiglet.stepGroupedFrames([5, 5, 0, 0], totals: [5, 12, 50, 50], rowSyncGroups: groups, rollbackProbability: 0, maxRollback: 3, using: &rng)
        XCTAssertEqual(out[0], 6)
        XCTAssertEqual(out[1], 6)
    }

    func testStepGroupedFrames_groupsStepIndependently() {
        // Some tick: one group advances while another rolls back.
        var found = false
        for seed in UInt64(0)..<300 {
            var rng = SeededGenerator(seed: seed)
            let before = [20, 20, 20, 20]
            let after = WatchtowerFiglet.stepGroupedFrames(before, totals: [50, 50, 50, 50], rowSyncGroups: groups, rollbackProbability: 0.5, maxRollback: 3, using: &rng)
            let advanced = zip(before, after).contains { $1 > $0 }
            let rolledBack = zip(before, after).contains { $1 < $0 }
            if advanced && rolledBack { found = true; break }
        }
        XCTAssertTrue(found, "groups must step independently — one advances while another rolls back")
    }

    func testStepGroupedFrames_deterministicForSameSeed() {
        var a = SeededGenerator(seed: 31); var b = SeededGenerator(seed: 31)
        XCTAssertEqual(
            WatchtowerFiglet.stepGroupedFrames([3, 3, 1, 9], totals: [40, 40, 40, 40], rowSyncGroups: groups, rollbackProbability: 0.2, maxRollback: 3, using: &a),
            WatchtowerFiglet.stepGroupedFrames([3, 3, 1, 9], totals: [40, 40, 40, 40], rowSyncGroups: groups, rollbackProbability: 0.2, maxRollback: 3, using: &b)
        )
    }

    // MARK: - nextFrame (backward-stutter ticker step)

    func testNextFrame_noRollback_advancesByOne() {
        var rng = SeededGenerator(seed: 1)
        XCTAssertEqual(WatchtowerFiglet.nextFrame(current: 10, total: 50, rollbackProbability: 0, maxRollback: 3, using: &rng), 11)
    }

    func testNextFrame_forwardClampsAtTotal() {
        var rng = SeededGenerator(seed: 1)
        XCTAssertEqual(WatchtowerFiglet.nextFrame(current: 50, total: 50, rollbackProbability: 0, maxRollback: 3, using: &rng), 50)
    }

    func testNextFrame_alwaysRollback_rewinds1to3() {
        for seed in UInt64(0)..<60 {
            var rng = SeededGenerator(seed: seed)
            let next = WatchtowerFiglet.nextFrame(current: 20, total: 50, rollbackProbability: 1, maxRollback: 3, using: &rng)
            XCTAssertTrue((17...19).contains(next), "rollback must rewind 1...3 (20→17..19), got \(next)")
        }
    }

    func testNextFrame_rollbackClampsAtZero() {
        var rng = SeededGenerator(seed: 1)
        XCTAssertEqual(WatchtowerFiglet.nextFrame(current: 1, total: 50, rollbackProbability: 1, maxRollback: 3, using: &rng), 0)
    }

    func testNextFrame_deterministicForSameSeed() {
        var a = SeededGenerator(seed: 42); var b = SeededGenerator(seed: 42)
        XCTAssertEqual(
            WatchtowerFiglet.nextFrame(current: 30, total: 80, rollbackProbability: 0.15, maxRollback: 3, using: &a),
            WatchtowerFiglet.nextFrame(current: 30, total: 80, rollbackProbability: 0.15, maxRollback: 3, using: &b)
        )
    }

    func testNextFrame_overManyTicks_convergesToTotal_despiteRollbacks() {
        // Forward drift dominates → the pass always reaches `total` even with
        // 15% backward stutters, and well within the view's safety cap.
        for seed in UInt64(0)..<20 {
            var rng = SeededGenerator(seed: seed)
            var frame = 0
            let total = 60
            var ticks = 0
            let cap = total * 3 + 30
            var sawRollback = false
            while frame < total && ticks < cap {
                let next = WatchtowerFiglet.nextFrame(current: frame, total: total, rollbackProbability: 0.15, maxRollback: 3, using: &rng)
                if next < frame { sawRollback = true }
                frame = next
                ticks += 1
            }
            XCTAssertEqual(frame, total, "seed \(seed): decode must converge to total")
            XCTAssertLessThan(ticks, cap, "seed \(seed): converges within the safety cap")
            _ = sawRollback   // (rollbacks are probabilistic; convergence is the invariant)
        }
    }

    // MARK: - Tap-to-decode gates

    func testShouldStartDecode_onlyWhenMotionAllowedAndIdle() {
        XCTAssertTrue(WatchtowerFiglet.shouldStartDecode(reduceMotion: false, isAnimating: false))
        XCTAssertFalse(WatchtowerFiglet.shouldStartDecode(reduceMotion: true, isAnimating: false))
        XCTAssertFalse(WatchtowerFiglet.shouldStartDecode(reduceMotion: false, isAnimating: true))
        XCTAssertFalse(WatchtowerFiglet.shouldStartDecode(reduceMotion: true, isAnimating: true))
    }

    func testShouldRunDecode_skipsInitialAppear() {
        XCTAssertFalse(WatchtowerFiglet.shouldRunDecode(trigger: 0), "on-appear (trigger 0) must NOT decode")
        XCTAssertTrue(WatchtowerFiglet.shouldRunDecode(trigger: 1))
        XCTAssertFalse(WatchtowerFiglet.shouldRunDecode(trigger: -1))
    }

    func testDisplayedFrame_restAndReduceMotion_showResolved() {
        XCTAssertEqual(WatchtowerFiglet.displayedFrame(reduceMotion: false, isAnimating: false, liveFrame: 3, resolvedFrame: 99), 99)
        XCTAssertEqual(WatchtowerFiglet.displayedFrame(reduceMotion: true, isAnimating: true, liveFrame: 3, resolvedFrame: 99), 99)
    }

    func testDisplayedFrame_whileAnimating_showsLive() {
        XCTAssertEqual(WatchtowerFiglet.displayedFrame(reduceMotion: false, isAnimating: true, liveFrame: 7, resolvedFrame: 99), 7)
    }

    // MARK: - scramble

    func testScramble_preservesLengthAndSpaces_replacesInk() {
        let row = Array("| (_| |")
        var rng = SeededGenerator(seed: 7)
        let out = WatchtowerFiglet.scramble(row, pool: WatchtowerFiglet.scramblePool, using: &rng)
        XCTAssertEqual(out.count, row.count)
        let pool = Set(WatchtowerFiglet.scramblePool)
        for (original, scrambled) in zip(row, out) {
            if original == " " { XCTAssertEqual(scrambled, " ") }
            else { XCTAssertTrue(pool.contains(scrambled)) }
        }
    }

    func testScramble_emptyPool_returnsInputUnchanged() {
        let row = Array("| __|")
        var rng = SeededGenerator(seed: 3)
        XCTAssertEqual(WatchtowerFiglet.scramble(row, pool: [], using: &rng), row)
    }

    func testScramble_deterministicForSameSeed() {
        let row = Array("|_| |_|")
        var a = SeededGenerator(seed: 99); var b = SeededGenerator(seed: 99)
        XCTAssertEqual(
            WatchtowerFiglet.scramble(row, pool: WatchtowerFiglet.scramblePool, using: &a),
            WatchtowerFiglet.scramble(row, pool: WatchtowerFiglet.scramblePool, using: &b)
        )
    }

    // MARK: - cellChar

    func testCellChar_locked_isReal() {
        XCTAssertEqual(WatchtowerFiglet.cellChar(real: "A", scrambled: "#", phase: .locked, quiet: false, plain: false), "A")
    }

    func testCellChar_active_scrambleVsRealInQuietOrPlain() {
        XCTAssertEqual(WatchtowerFiglet.cellChar(real: "A", scrambled: "#", phase: .active, quiet: false, plain: false), "#")
        XCTAssertEqual(WatchtowerFiglet.cellChar(real: "A", scrambled: "#", phase: .active, quiet: true, plain: false), "A")
        XCTAssertEqual(WatchtowerFiglet.cellChar(real: "A", scrambled: "#", phase: .active, quiet: false, plain: true), "A")
    }

    func testCellChar_ahead_isAlwaysBlank() {
        XCTAssertEqual(WatchtowerFiglet.cellChar(real: "A", scrambled: "#", phase: .ahead, quiet: false, plain: false), " ")
        XCTAssertEqual(WatchtowerFiglet.cellChar(real: "A", scrambled: "#", phase: .ahead, quiet: true, plain: true), " ")
    }

    // MARK: - assembledBanner (resting equivalence, dimensional stability, plain top, desync)

    private func makeRandomPass(seed: UInt64) -> (lags: [Int], settle: [[Int]], scramble: [[Character]]) {
        var rng = SeededGenerator(seed: seed)
        let lags = WatchtowerFiglet.makeRowLags(rowCount: rowCount, maxLag: WatchtowerFiglet.maxRowLag, rowSyncGroups: WatchtowerFiglet.rowSyncGroups, using: &rng)
        let settle = WatchtowerFiglet.makeCellSettle(rowCount: rowCount, columnCount: columnCount, maxSettle: WatchtowerFiglet.maxCellSettle, using: &rng)
        let scramble = WatchtowerFiglet.makeScrambledRows()
        return (lags, settle, scramble)
    }

    func testAssembledBanner_atResolvedFrame_equalsStaticBanner() {
        let p = makeRandomPass(seed: 21)
        let total = WatchtowerFiglet.decodeLength(rowCount: rowCount, columnCount: columnCount, rowLags: p.lags, cellSettle: p.settle)
        XCTAssertEqual(
            WatchtowerFiglet.assembledBanner(frame: total, scrambledRows: p.scramble, rowLags: p.lags, cellSettle: p.settle, quiet: false),
            WatchtowerFiglet.banner
        )
        // With no lag/settle the resolved frame is `columnCount`.
        XCTAssertEqual(
            WatchtowerFiglet.assembledBanner(frame: columnCount, scrambledRows: [], rowLags: [], cellSettle: [], quiet: true),
            WatchtowerFiglet.banner
        )
    }

    func testAssembledBanner_everyFrame_matchesBannerDimensions() {
        let bannerLines = WatchtowerFiglet.banner.components(separatedBy: "\n").map { $0.count }
        let p = makeRandomPass(seed: 22)
        let total = WatchtowerFiglet.decodeLength(rowCount: rowCount, columnCount: columnCount, rowLags: p.lags, cellSettle: p.settle)
        for f in 0...total {
            for quiet in [false, true] {
                let lines = WatchtowerFiglet
                    .assembledBanner(frame: f, scrambledRows: p.scramble, rowLags: p.lags, cellSettle: p.settle, quiet: quiet)
                    .components(separatedBy: "\n")
                    .map { $0.count }
                XCTAssertEqual(lines, bannerLines, "line widths must stay constant at frame=\(f) quiet=\(quiet)")
            }
        }
    }

    func testAssembledBanner_topRow_isPlainRealOrBlank_everyFrame() {
        // The top cap row never scrambles: real once the wave has reached it
        // (frame >= start), blank before. Deterministic — independent of noise.
        let top = WatchtowerFiglet.bannerRows[0]
        let p = makeRandomPass(seed: 23)
        let total = WatchtowerFiglet.decodeLength(rowCount: rowCount, columnCount: columnCount, rowLags: p.lags, cellSettle: p.settle)
        for f in 0...total {
            let expected: [Character] = top.indices.map { c in
                let start = WatchtowerFiglet.cellStart(row: 0, column: c, rowLags: p.lags)
                return f >= start ? top[c] : " "
            }
            let actual = Array(
                WatchtowerFiglet
                    .assembledBanner(frame: f, scrambledRows: p.scramble, rowLags: p.lags, cellSettle: p.settle, quiet: false)
                    .components(separatedBy: "\n")[0]
            )
            XCTAssertEqual(actual, expected, "top row must just appear (real-or-blank), never scramble, at frame=\(f)")
        }
    }

    func testRowsDesync_differentLags_resolveAtDifferentFrames() {
        // Two rows with different lags and the same settle resolve a shared
        // column at different frames — the rows are NOT synchronous.
        let lags = [0, 5]
        let settle = [Array(repeating: 1, count: columnCount), Array(repeating: 1, count: columnCount)]
        let col = 10
        let r0 = WatchtowerFiglet.cellThreshold(row: 0, column: col, rowLags: lags, cellSettle: settle)
        let r1 = WatchtowerFiglet.cellThreshold(row: 1, column: col, rowLags: lags, cellSettle: settle)
        XCTAssertNotEqual(r0, r1, "rows with different lag must resolve the same column at different frames")
        XCTAssertEqual(r1 - r0, 5, "the lag difference (5) shows up directly in resolve timing")
    }
}
