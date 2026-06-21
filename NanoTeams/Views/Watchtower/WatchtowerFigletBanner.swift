import SwiftUI

// MARK: - Figlet data + pure decode logic (nonisolated, testable)

/// Pure data + decode-policy namespace for the «nanoteams» figlet masthead.
///
/// Split out of the `@MainActor` `WatchtowerFigletBanner` view so the glyph
/// table and the frame→state math are `nonisolated` and unit-testable without
/// constructing a SwiftUI view (Swift-6 isolation + the sync-test main-actor
/// abort gotcha). The view is a thin renderer over these helpers.
///
/// **Decode = a left→right wave with per-cell settle.** Each grid cell starts
/// decoding when the wave reaches it (`column + rowLag`, so rows are DESYNCED),
/// then cycles a RANDOM number of scramble symbols — `1...maxCellSettle`, some
/// cells settle in one flip, some in six — before locking to its real glyph.
/// Cells the wave hasn't reached yet are blank.
nonisolated enum WatchtowerFiglet {

    /// Per-letter 4-row glyphs (mirrors the JSX `FIG` dictionary). Each glyph is
    /// rectangular — all four of a letter's rows share one width — so the joined
    /// banner is a clean rectangular grid.
    static let fig: [Character: [String]] = [
        "N": [" _ __  ", "| '_ \\ ", "| | | |", "|_| |_|"],
        "A": ["  __ _ ", " / _` |", "| (_| |", " \\__,_|"],
        "O": ["  ___  ", " / _ \\ ", "| (_) |", " \\___/ "],
        "T": [" _   ", "| |_ ", "| __|", " \\__|"],
        "E": ["  ___ ", " / _ \\", "|  __/", " \\___|"],
        "M": [" _ __ ___  ", "| '_ ` _ \\ ", "| | | | | |", "|_| |_| |_|"],
        "S": [" ___ ", "/ __|", "\\__ \\", "|___/"],
    ]

    static let letters: [Character] = Array("NANOTEAMS")

    /// Fallback for any letter missing from `fig` — four blank rows so the
    /// banner degrades gracefully (and never traps) if the wordmark gains a
    /// character without a glyph entry, instead of force-unwrapping `fig[$0]!`.
    static let blankGlyph: [String] = Array(repeating: "", count: 4)

    /// The fully-resolved resting banner — identical to what the decode
    /// animation settles on once every cell is locked.
    static let banner: String = (0..<4)
        .map { row in letters.map { (fig[$0] ?? blankGlyph)[row] }.joined() }
        .joined(separator: "\n")

    /// The four real banner rows as character grids, for O(1) cell indexing.
    static let bannerRows: [[Character]] = banner.components(separatedBy: "\n").map { Array($0) }

    /// Grid width. Taken from row 0; every row shares it (rectangular glyphs).
    static let columnCount: Int = bannerRows.first?.count ?? 0

    /// Single-cell SF Mono glyphs for the scramble noise — the figlet's own
    /// character family plus block / box-drawing / digital-noise glyphs for a
    /// glitchier texture. Every entry is single advance width in SF Mono, so
    /// scrambling preserves the grid (the layout-stability invariant).
    static let scramblePool: [Character] = Array("_|/\\()[]{}<>=~:;.,01#%&$*+░▒▓╱╲╳┼≡╋╮╰")

    /// Number of topmost grid rows that "just appear" (plain type-in) instead of
    /// decoding. The top "cap" row is sparse (mostly `_` tops) and reads as noise
    /// when scrambled, so it pops in cleanly while the body rows decode.
    static let plainTopRowCount = 1

    /// Whether `row` is a plain (non-decoding) top row.
    static func isPlainRow(_ row: Int) -> Bool { row < plainTopRowCount }

    // MARK: Decode policy (pure)

    /// Per-cell render phase relative to its own start / lock thresholds.
    enum CellPhase: Equatable { case locked, active, ahead }

    /// Max per-group start lag (columns) — DESYNCs the decode groups so the wave
    /// isn't a single vertical line. Randomized per pass.
    static let maxRowLag = 8

    /// Which rows decode in lockstep. Rows sharing a group id share one decode
    /// clock + lag, so they appear synchronously. Rows 0 and 1 (the cap + upper
    /// body) are synced; rows 2 and 3 each decode independently.
    static let rowSyncGroups: [Int] = [0, 0, 1, 2]

    /// Group id for `row` (its own index as a singleton group if out of range).
    static func groupForRow(_ row: Int, rowSyncGroups: [Int]) -> Int {
        (row >= 0 && row < rowSyncGroups.count) ? rowSyncGroups[row] : row
    }
    /// Max scramble symbols a cell cycles through before locking. The actual
    /// count per cell is random in `1...maxCellSettle`, so some cells settle in
    /// a single flip and others take the full six. Randomized per pass.
    static let maxCellSettle = 6

    /// Per-row lag (columns) — one random lag PER GROUP, expanded to rows, so
    /// rows in the same sync group share a lag (and thus appear together).
    /// RNG injected for tests.
    static func makeRowLags(rowCount: Int, maxLag: Int, rowSyncGroups: [Int], using generator: inout some RandomNumberGenerator) -> [Int] {
        guard rowCount > 0 else { return [] }
        let m = max(0, maxLag)
        let groupCount = (0..<rowCount).map { groupForRow($0, rowSyncGroups: rowSyncGroups) }.max().map { $0 + 1 } ?? 0
        let groupLags = (0..<max(groupCount, 1)).map { _ in m == 0 ? 0 : Int.random(in: 0...m, using: &generator) }
        return (0..<rowCount).map { row in
            let g = groupForRow(row, rowSyncGroups: rowSyncGroups)
            return g < groupLags.count ? groupLags[g] : 0
        }
    }

    /// Random per-cell settle count (`1...maxSettle`), `rowCount × columnCount`.
    /// Always ≥ 1 — every cell flips at least once. RNG injected for tests.
    static func makeCellSettle(rowCount: Int, columnCount: Int, maxSettle: Int, using generator: inout some RandomNumberGenerator) -> [[Int]] {
        guard rowCount > 0, columnCount > 0 else { return [] }
        let m = max(1, maxSettle)
        return (0..<rowCount).map { _ in (0..<columnCount).map { _ in Int.random(in: 1...m, using: &generator) } }
    }

    /// Frame at which the wave reaches cell `(row, column)` and it begins
    /// cycling: the base left→right column index plus the row's desync lag.
    static func cellStart(row: Int, column: Int, rowLags: [Int]) -> Int {
        column + (rowLags.indices.contains(row) ? rowLags[row] : 0)
    }

    /// Frame at which the cell locks: its start plus its random settle count
    /// (so it shows `settle` scramble symbols in between). Missing settle → 1.
    static func cellThreshold(row: Int, column: Int, rowLags: [Int], cellSettle: [[Int]]) -> Int {
        let settle = (cellSettle.indices.contains(row) && cellSettle[row].indices.contains(column)) ? cellSettle[row][column] : 1
        return cellStart(row: row, column: column, rowLags: rowLags) + max(1, settle)
    }

    /// Frames a single row needs to fully resolve — the largest cell threshold
    /// in that row. Each row runs its own decode clock (independent rollback).
    static func rowDecodeLength(row: Int, columnCount: Int, rowLags: [Int], cellSettle: [[Int]]) -> Int {
        guard columnCount > 0 else { return 0 }
        var m = 0
        for c in 0..<columnCount {
            m = max(m, cellThreshold(row: row, column: c, rowLags: rowLags, cellSettle: cellSettle))
        }
        return m
    }

    /// Total frames the whole grid needs — the largest per-row length.
    static func decodeLength(rowCount: Int, columnCount: Int, rowLags: [Int], cellSettle: [[Int]]) -> Int {
        guard rowCount > 0, columnCount > 0 else { return 0 }
        return (0..<rowCount).reduce(0) { max($0, rowDecodeLength(row: $1, columnCount: columnCount, rowLags: rowLags, cellSettle: cellSettle)) }
    }

    /// Phase of a cell at `frame`: not yet reached (ahead), inside its
    /// `[start, threshold)` scramble window (active), or locked.
    static func cellPhase(frame: Int, start: Int, threshold: Int) -> CellPhase {
        if frame >= threshold { return .locked }
        if frame >= start { return .active }
        return .ahead
    }

    /// Chance per tick that the decode stutters BACKWARD instead of advancing —
    /// it "re-encrypts" for a glitchier feel.
    static let rollbackProbability = 0.15
    /// Max frames a backward stutter rewinds (1...maxRollback symbols).
    static let maxRollback = 3

    /// Next frame for the ticker: usually `+1` (clamped to `total`), but with
    /// `rollbackProbability` it rewinds `1...maxRollback` frames (clamped to 0),
    /// re-scrambling the cells it un-resolves — the decode glitches backward.
    /// Net drift stays forward (forward dominates) so a pass still converges.
    /// RNG injected so tests are deterministic.
    static func nextFrame(
        current: Int,
        total: Int,
        rollbackProbability: Double,
        maxRollback: Int,
        using generator: inout some RandomNumberGenerator
    ) -> Int {
        let p = min(max(rollbackProbability, 0), 1)
        if Double.random(in: 0..<1, using: &generator) < p {
            let back = Int.random(in: 1...max(1, maxRollback), using: &generator)
            return max(0, current - back)
        }
        return min(total, current + 1)
    }

    /// Steps each sync GROUP's frame independently through `nextFrame`, then
    /// broadcasts to every row in the group — so synced rows always share a frame
    /// (appear together) while different groups roll their own forward/rollback
    /// dice. A group's forward step is capped by its LARGEST member total (it runs
    /// until every member row resolves). One RNG draw per group ⇒ independent
    /// groups; deterministic for a given seed.
    static func stepGroupedFrames(
        _ frames: [Int],
        totals: [Int],
        rowSyncGroups: [Int],
        rollbackProbability: Double,
        maxRollback: Int,
        using generator: inout some RandomNumberGenerator
    ) -> [Int] {
        guard !frames.isEmpty else { return frames }
        var steppedByGroup: [Int: Int] = [:]
        var result = frames
        for row in frames.indices {
            let g = groupForRow(row, rowSyncGroups: rowSyncGroups)
            if steppedByGroup[g] == nil {
                let groupTotal = frames.indices
                    .filter { groupForRow($0, rowSyncGroups: rowSyncGroups) == g }
                    .map { $0 < totals.count ? totals[$0] : frames[$0] }
                    .max() ?? (row < totals.count ? totals[row] : frames[row])
                steppedByGroup[g] = nextFrame(current: frames[row], total: groupTotal, rollbackProbability: rollbackProbability, maxRollback: maxRollback, using: &generator)
            }
            result[row] = steppedByGroup[g] ?? frames[row]
        }
        return result
    }

    // MARK: Tap-to-decode gates (pure)

    /// Whether a tap should kick off a decode pass — only when motion is allowed
    /// and no pass is already running (re-taps mid-decode are ignored).
    static func shouldStartDecode(reduceMotion: Bool, isAnimating: Bool) -> Bool {
        !reduceMotion && !isAnimating
    }

    /// Whether a `.task(id:)` firing should actually decode. The initial
    /// on-appear run carries `trigger == 0` and must be a no-op — nothing
    /// decodes until the user taps the wordmark (taps bump the trigger above 0).
    static func shouldRunDecode(trigger: Int) -> Bool { trigger > 0 }

    /// Frame to render: the live frame while a pass runs, or `resolvedFrame`
    /// (≥ every threshold ⇒ all-locked static banner) at rest / under Reduce
    /// Motion.
    static func displayedFrame(reduceMotion: Bool, isAnimating: Bool, liveFrame: Int, resolvedFrame: Int) -> Int {
        (reduceMotion || !isAnimating) ? resolvedFrame : liveFrame
    }

    // MARK: Cell rendering (pure)

    /// Space-preserving scramble of one grid row: every non-space cell is
    /// replaced by a random `pool` glyph, spaces stay spaces. One char per cell
    /// every frame ⇒ identical intrinsic size ⇒ no layout churn under
    /// `minimumScaleFactor`. RNG injected so tests are deterministic.
    static func scramble(
        _ realRow: [Character],
        pool: [Character],
        using generator: inout some RandomNumberGenerator
    ) -> [Character] {
        guard !pool.isEmpty else { return realRow }
        return realRow.map { $0 == " " ? " " : (pool.randomElement(using: &generator) ?? $0) }
    }

    /// The single character shown for one grid cell, given its phase + mode.
    /// Shared by the view's `Text` builder and the test's `assembledBanner`.
    ///
    /// - ahead → blank (the wave hasn't reached it yet),
    /// - active → a cycling scramble glyph (or the real glyph in `quiet`/`plain`),
    /// - locked → the real glyph.
    ///
    /// `plain == true` (the top cap rows) forces the quiet path — the cell just
    /// appears with no scramble flips.
    static func cellChar(
        real: Character,
        scrambled: Character,
        phase: CellPhase,
        quiet: Bool,
        plain: Bool
    ) -> Character {
        switch phase {
        case .locked: return real
        case .active: return (quiet || plain) ? real : scrambled
        case .ahead:  return " "
        }
    }

    /// Fresh random scramble for every grid row. Seeds the view's initial state
    /// and refreshes the noise each tick (so active cells cycle glyphs).
    static func makeScrambledRows() -> [[Character]] {
        var rng = SystemRandomNumberGenerator()
        return bannerRows.map { scramble($0, pool: scramblePool, using: &rng) }
    }

    /// Assembles the plain (color-free) banner string at `frame`. With
    /// `frame == decodeLength(...)` every cell is locked, so this equals
    /// `banner` regardless of `scrambledRows`/`quiet` — the resting state is
    /// pixel-identical to the static banner. Used by tests to pin that
    /// equivalence and the per-frame dimensional stability.
    static func assembledBanner(
        frame: Int,
        scrambledRows: [[Character]],
        rowLags: [Int],
        cellSettle: [[Int]],
        quiet: Bool
    ) -> String {
        bannerRows.enumerated().map { r, row in
            let plain = isPlainRow(r)
            let scr = scrambledRows.indices.contains(r) ? scrambledRows[r] : []
            let chars: [Character] = row.indices.map { c in
                let start = cellStart(row: r, column: c, rowLags: rowLags)
                let threshold = cellThreshold(row: r, column: c, rowLags: rowLags, cellSettle: cellSettle)
                let p = cellPhase(frame: frame, start: start, threshold: threshold)
                let s = c < scr.count ? scr[c] : " "
                return cellChar(real: row[c], scrambled: s, phase: p, quiet: quiet, plain: plain)
            }
            return String(chars)
        }.joined(separator: "\n")
    }
}

// MARK: - WatchtowerFigletBanner (view)

/// The «nanoteams» figlet masthead with a **glitch decryption wave**: a
/// left→right front sweeps the grid; rows are desynced by a random lag and each
/// cell cycles a random `1...maxCellSettle` scramble symbols before locking to
/// its real glyph. Rows decode in sync GROUPS (`WatchtowerFiglet.rowSyncGroups`)
/// — rows 0 and 1 share one clock + lag (they appear together), rows 2 and 3 run
/// independently. Each group also (`rollbackProbability`) stutters BACKWARD 1–3
/// frames, re-scrambling the cells it un-resolves — so one group can glitch back
/// while others advance. The top cap row (`WatchtowerFiglet.plainTopRowCount`)
/// just appears (no flips). At rest it's the static banner.
///
/// Renders a **single** `Text` (built via per-run concatenation so cells can
/// carry their own color) so SwiftUI's native `minimumScaleFactor` shrinks it
/// uniformly to fit narrow windows. `lineLimit(4)` pins the row structure so
/// SwiftUI scales the font instead of wrapping monospace lines on internal
/// whitespace. Because every cell renders exactly one character every frame,
/// the figlet's intrinsic size never changes mid-decode — the window resizes
/// freely and the banner never jitters.
///
/// Why not `fixedSize(horizontal:)`: it would propagate the figlet's natural
/// width up the chain as a hard min-width and the whole window would stop
/// shrinking at that boundary. `minimumScaleFactor` accepts whatever width the
/// parent gives, so nothing is pushed upstream.
///
/// Driver: a `.task` loop mutating `@State` in the ticker (house style, mirrors
/// `NTMSLoader`) — random is generated only in the ticker / on tap and stored,
/// so `body` is a pure function of state and never re-randomizes on an
/// unrelated re-render. The loop exits at completion (no forever-ticking).
///
/// **Trigger: tap.** At rest the wordmark is the fully-resolved static banner —
/// it does NOT decode on appear. Tapping it kicks off one decode pass (fresh
/// random lags + settle counts), via a `.task(id: decodeTrigger)` keyed on a
/// tap counter; the initial appear run carries `trigger == 0` and no-ops.
/// Re-tapping after it settles replays it with new randomness.
///
/// Fallbacks: Reduce Motion → static banner, taps are inert. The
/// `spinnerGlitchEnabled` effects toggle OFF → quiet "type-in" (cells appear
/// with no scramble flips, the wave still sweeps + rows still desync).
struct WatchtowerFigletBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// User toggle (Settings → Theme → Effects). `false` swaps the scramble
    /// flips for a quiet appear. `@AppStorage` (not `StoreConfiguration`) so
    /// this design-system primitive works in previews without an injected
    /// environment, matching `NTMSLoader`. Default on.
    @AppStorage(UserDefaultsKeys.spinnerGlitchEnabled) private var glitchEnabled: Bool = true

    /// One decode clock PER ROW — rows advance / roll back independently.
    @State private var frames: [Int] = []
    @State private var scrambledRows: [[Character]] = WatchtowerFiglet.makeScrambledRows()
    /// Per-row decode lag (columns) — desyncs the rows. Regenerated per pass.
    @State private var rowLags: [Int] = []
    /// Per-cell settle count (`1...maxCellSettle` scramble flips). Per pass.
    @State private var cellSettle: [[Int]] = []
    /// Whether a decode pass is currently running. At rest the banner is the
    /// fully-resolved static wordmark; a tap flips this on for one pass.
    @State private var isAnimating: Bool = false
    /// Bumped on each tap to (re)launch the `.task(id:)` ticker. Starts at 0 so
    /// the initial on-appear run is a no-op (no decode on Watchtower open).
    @State private var decodeTrigger: Int = 0

    /// Tick cadence. The wave length is data-driven (`decodeLength`) and the
    /// ~15% backward stutters stretch it, so a pass runs ~4.5–5.5 s.
    private static let tickInterval: Duration = .milliseconds(38)

    var body: some View {
        bannerText(frames: displayedFrames)
            .font(Typography.termSm)
            .lineLimit(4)
            .minimumScaleFactor(0.1)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())          // tap target = the wordmark's bounds
            .onTapGesture { startDecode() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: decodeTrigger) { await runDecode() }
            .accessibilityLabel("nanoteams")
            .accessibilityAddTraits(.isHeader)
    }

    /// Per-row frame to render: the row's live clock while a pass runs, or its
    /// fully-resolved length (all that row's cells locked) at rest / Reduce Motion.
    private var displayedFrames: [Int] {
        (0..<WatchtowerFiglet.bannerRows.count).map { r in
            WatchtowerFiglet.displayedFrame(
                reduceMotion: reduceMotion,
                isAnimating: isAnimating,
                liveFrame: r < frames.count ? frames[r] : 0,
                resolvedFrame: rowTotal(r)
            )
        }
    }

    private func rowTotal(_ r: Int) -> Int {
        WatchtowerFiglet.rowDecodeLength(
            row: r,
            columnCount: WatchtowerFiglet.columnCount,
            rowLags: rowLags,
            cellSettle: cellSettle
        )
    }

    // MARK: Text builder

    /// Builds the 4-row banner as one concatenated `Text`, grouping consecutive
    /// same-phase cells into colored runs. `verbatim:` so the glyph chars
    /// (`_ | / \`) are never interpreted as markdown.
    private func bannerText(frames: [Int]) -> Text {
        let rows = WatchtowerFiglet.bannerRows
        var out = Text(verbatim: "")
        for r in rows.indices {
            out = out + rowText(rowIndex: r, frame: r < frames.count ? frames[r] : 0)
            if r < rows.count - 1 { out = out + Text(verbatim: "\n") }
        }
        return out
    }

    private func rowText(rowIndex r: Int, frame: Int) -> Text {
        let real = WatchtowerFiglet.bannerRows[r]
        let scrambled = scrambledRow(r)
        let plain = WatchtowerFiglet.isPlainRow(r)

        var out = Text(verbatim: "")
        var runChars: [Character] = []
        var runPhase: WatchtowerFiglet.CellPhase = .locked

        for c in real.indices {
            let start = WatchtowerFiglet.cellStart(row: r, column: c, rowLags: rowLags)
            let threshold = WatchtowerFiglet.cellThreshold(row: r, column: c, rowLags: rowLags, cellSettle: cellSettle)
            let phase = WatchtowerFiglet.cellPhase(frame: frame, start: start, threshold: threshold)
            let ch = WatchtowerFiglet.cellChar(
                real: real[c],
                scrambled: c < scrambled.count ? scrambled[c] : " ",
                phase: phase,
                quiet: !glitchEnabled,
                plain: plain
            )
            if !runChars.isEmpty && phase != runPhase {
                out = out + Text(verbatim: String(runChars)).foregroundStyle(color(for: runPhase))
                runChars.removeAll(keepingCapacity: true)
            }
            runPhase = phase
            runChars.append(ch)
        }
        if !runChars.isEmpty {
            out = out + Text(verbatim: String(runChars)).foregroundStyle(color(for: runPhase))
        }
        return out
    }

    private func scrambledRow(_ r: Int) -> [Character] {
        scrambledRows.indices.contains(r) ? scrambledRows[r] : []
    }

    private func color(for phase: WatchtowerFiglet.CellPhase) -> Color {
        switch phase {
        case .locked: return Colors.textTertiary   // resolved — resting color
        case .active: return Colors.accent          // the cycling decrypt glyph
        case .ahead:  return Colors.textQuaternary  // blank (color unused)
        }
    }

    // MARK: Tap → decode

    private func freshRowLags() -> [Int] {
        var rng = SystemRandomNumberGenerator()
        return WatchtowerFiglet.makeRowLags(
            rowCount: WatchtowerFiglet.bannerRows.count,
            maxLag: WatchtowerFiglet.maxRowLag,
            rowSyncGroups: WatchtowerFiglet.rowSyncGroups,
            using: &rng
        )
    }

    private func freshCellSettle() -> [[Int]] {
        var rng = SystemRandomNumberGenerator()
        return WatchtowerFiglet.makeCellSettle(
            rowCount: WatchtowerFiglet.bannerRows.count,
            columnCount: WatchtowerFiglet.columnCount,
            maxSettle: WatchtowerFiglet.maxCellSettle,
            using: &rng
        )
    }

    /// Tap handler: kick off one decode pass from the start with fresh random
    /// lags + settle counts. Ignored under Reduce Motion or while a pass runs.
    private func startDecode() {
        guard WatchtowerFiglet.shouldStartDecode(reduceMotion: reduceMotion, isAnimating: isAnimating) else { return }
        rowLags = freshRowLags()
        cellSettle = freshCellSettle()
        scrambledRows = WatchtowerFiglet.makeScrambledRows()
        frames = Array(repeating: 0, count: WatchtowerFiglet.bannerRows.count)
        isAnimating = true
        decodeTrigger += 1
    }

    /// Ticker for one decode pass — runs only when launched by a tap (the
    /// on-appear firing carries `trigger == 0` and bails). Random lives here
    /// (not in `body`) so re-renders never re-scramble. Each sync GROUP steps its
    /// own clock (synced rows together, independent rollback per group); the pass
    /// ends once EVERY row resolves.
    private func runDecode() async {
        guard WatchtowerFiglet.shouldRunDecode(trigger: decodeTrigger) else { return }
        let rowCount = WatchtowerFiglet.bannerRows.count
        let totals = (0..<rowCount).map { rowTotal($0) }
        let maxTotal = totals.max() ?? 0
        guard maxTotal > 0 else { isAnimating = false; return }
        if frames.count != rowCount { frames = Array(repeating: 0, count: rowCount) }
        var rng = SystemRandomNumberGenerator()
        var ticks = 0
        // Forward drift dominates so each group converges, but bound the ticks in
        // case of an unlucky rollback streak — then snap to the resolved state.
        let maxTicks = maxTotal * 3 + 30
        while !Task.isCancelled && frames.indices.contains(where: { frames[$0] < totals[$0] }) && ticks < maxTicks {
            try? await Task.sleep(for: Self.tickInterval)
            if Task.isCancelled { return }
            ticks += 1
            frames = WatchtowerFiglet.stepGroupedFrames(
                frames,
                totals: totals,
                rowSyncGroups: WatchtowerFiglet.rowSyncGroups,
                rollbackProbability: WatchtowerFiglet.rollbackProbability,
                maxRollback: WatchtowerFiglet.maxRollback,
                using: &rng
            )
            scrambledRows = WatchtowerFiglet.makeScrambledRows()
        }
        if !Task.isCancelled { frames = totals }   // ensure the wordmark fully resolves
        isAnimating = false
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: Spacing.l) {
        WatchtowerFigletBanner()
        Spacer()
    }
    .padding(Spacing.l)
    .frame(width: 760, height: 200)
    .background(Colors.surfacePrimary)
}
