import XCTest

@testable import NanoTeams

/// The Runs table keys rows by run UUID; the leaderboard specializes the same generic by its
/// composite String id. These suites drive the UUID specialization — the logic is id-agnostic.
private typealias RowInteraction = BenchmarkRowInteractionState<UUID>

/// The pure geometry the benchmark tables' whole-row interaction stands on — where a row's band
/// is (`rowBand`), and which row a point belongs to (`rowID(at:)`). The WHY of the grid-level
/// design lives once, on `BenchmarkRowInteractionState`'s doc; these tests pin the WHAT.
final class BenchmarkRunRowInteractionTests: XCTestCase {

    // MARK: - rowBand

    func testRowBand_isNilBeforeTheFirstLayoutPassReports() {
        XCTAssertNil(RowInteraction.rowBand(around: nil))
    }

    /// A zero-height frame is what a cell reports while collapsing out of the hierarchy — a band
    /// built from it would be a 4 pt sliver claiming a row that is not on screen.
    func testRowBand_isNilForAZeroHeightCell() {
        let collapsed = CGRect(x: 0, y: 40, width: 120, height: 0)
        XCTAssertNil(RowInteraction.rowBand(around: collapsed))
    }

    func testRowBand_outsetsTheCellSymmetricallyByTheToken() throws {
        let cell = CGRect(x: 40, y: 100, width: 120, height: 20)
        let band = try XCTUnwrap(RowInteraction.rowBand(around: cell))
        XCTAssertEqual(band, (cell.minY - Spacing.xxs)..<(cell.maxY + Spacing.xxs))
    }

    /// Half the separation invariant: the outset must stay inside the Grid's `verticalSpacing`,
    /// or adjacent bands touch and two rows light as one. The other half — that the Grid really
    /// passes `Spacing.s` — is wiring, pinned by
    /// `BenchmarkRunRowInteractionPinTests.testTheRunsTableCarriesTheWholeRowInteraction`
    /// (CLAUDE.md #60: a property held by two mechanisms needs a pin on each).
    func testRowBand_outsetLeavesAdjacentBandsSeparated() {
        XCTAssertLessThan(Spacing.xxs * 2, Spacing.s)
    }

    // MARK: - runID(at:)

    private let rowA = UUID()
    private let rowB = UUID()

    /// Two rows as the Grid lays them out: 20 pt cells, `verticalSpacing` 8 pt apart —
    /// bands [98, 122) and [126, 150).
    private var frames: [UUID: CGRect] {
        [
            rowA: CGRect(x: 40, y: 100, width: 120, height: 20),
            rowB: CGRect(x: 40, y: 128, width: 120, height: 20),
        ]
    }

    private func hit(_ point: CGPoint) -> UUID? {
        RowInteraction.rowID(at: point, frames: frames, orderedIDs: [rowA, rowB])
    }

    func testRunID_findsTheRowWhoseBandHoldsThePoint() {
        XCTAssertEqual(hit(CGPoint(x: 60, y: 110)), rowA)
        XCTAssertEqual(hit(CGPoint(x: 60, y: 138)), rowB)
    }

    /// Bands span the Grid's full width, so only y decides — a click in the gap BETWEEN columns,
    /// or right of the last column, is still a click on the row.
    func testRunID_ignoresXEntirely() {
        XCTAssertEqual(hit(CGPoint(x: -50, y: 110)), rowA)
        XCTAssertEqual(hit(CGPoint(x: 9999, y: 110)), rowA)
    }

    /// The interval is half-open: a band's top line is its own (98), its bottom line already is
    /// not (122) — so a point on the boundary of two touching bands could never match both. The
    /// strip between two bands (124) belongs to neither, so the highlight goes out rather than
    /// jumping rows early.
    func testRunID_bandTopIsInsideBandBottomAndTheGapAreOutside() {
        XCTAssertEqual(hit(CGPoint(x: 60, y: 98)), rowA)
        XCTAssertNil(hit(CGPoint(x: 60, y: 122)))
        XCTAssertNil(hit(CGPoint(x: 60, y: 124)))
    }

    func testRunID_isNilAboveTheFirstAndBelowTheLastRow() {
        XCTAssertNil(hit(CGPoint(x: 60, y: 90)))
        XCTAssertNil(hit(CGPoint(x: 60, y: 160)))
    }

    func testRunID_isNilWhenNoFramesHaveBeenReported() {
        XCTAssertNil(
            RowInteraction.rowID(
                at: CGPoint(x: 60, y: 110), frames: [:], orderedIDs: [rowA, rowB]))
    }

    /// A run the filter just admitted has an id in `orderedIDs` before its cell has reported a
    /// frame — it must be skipped, not crash and not shadow the rows that HAVE reported.
    func testRunID_skipsAnIDWithoutAReportedFrame() {
        let unreported = UUID()
        let id = RowInteraction.rowID(
            at: CGPoint(x: 60, y: 110),
            frames: [rowA: CGRect(x: 40, y: 100, width: 120, height: 20)],
            orderedIDs: [unreported, rowA])
        XCTAssertEqual(id, rowA)
    }

    /// If two bands ever overlap (a stale frame mid-relayout), the FIRST row in table order wins —
    /// deterministic, matching what the eye reads top-down.
    func testRunID_firstMatchInTableOrderWinsOnOverlap() {
        let shared = CGRect(x: 40, y: 100, width: 120, height: 20)
        let id = RowInteraction.rowID(
            at: CGPoint(x: 60, y: 110),
            frames: [rowA: shared, rowB: shared],
            orderedIDs: [rowB, rowA])
        XCTAssertEqual(id, rowB)
    }
}

/// The stateful half: how pointer events, frame reports and modal presentations drive
/// `hoveredRowID`. `@MainActor` + async tests because the state class is main-actor app code
/// (see the CI-abort convention in CLAUDE.md's testing notes).
@MainActor
final class BenchmarkRowInteractionStateTests: XCTestCase {

    fileprivate var sut: RowInteraction!
    private let rowA = UUID()
    private let rowB = UUID()

    private var ids: [UUID] { [rowA, rowB] }
    private let frameA = CGRect(x: 40, y: 100, width: 120, height: 20)   // band [98, 122)
    private let frameB = CGRect(x: 40, y: 128, width: 120, height: 20)   // band [126, 150)

    override func setUp() async throws {
        sut = RowInteraction()
        sut.reportFrame(frameA, for: rowA, orderedIDs: ids)
        sut.reportFrame(frameB, for: rowB, orderedIDs: ids)
    }

    override func tearDown() async throws {
        sut = nil
    }

    func testPointerMoveLightsTheRowUnderIt() async {
        sut.pointerMoved(to: CGPoint(x: 60, y: 110), orderedIDs: ids)
        XCTAssertEqual(sut.hoveredRowID, rowA)
    }

    func testPointerEndedPutsTheHighlightOut() async {
        sut.pointerMoved(to: CGPoint(x: 60, y: 110), orderedIDs: ids)
        sut.pointerEnded()
        XCTAssertNil(sut.hoveredRowID)
    }

    /// The reflow case: a confirmed delete removes a row (or a settling measurement prepends
    /// one) and a DIFFERENT row slides under a pointer that never moved. The lit row must follow
    /// the fresh frames, not wait for the next mouse move — otherwise the band promises a row a
    /// click would not open.
    func testRowReflowUnderAStationaryPointerRelightsTheRowNowUnderIt() async {
        sut.pointerMoved(to: CGPoint(x: 60, y: 110), orderedIDs: ids)
        XCTAssertEqual(sut.hoveredRowID, rowA)
        // rowA is deleted; rowB reflows up into its place. Same pointer, new frames.
        sut.prune(keeping: [rowB])
        sut.reportFrame(frameA, for: rowB, orderedIDs: [rowB])
        XCTAssertEqual(sut.hoveredRowID, rowB)
    }

    /// A modal (detail sheet, delete confirmation) swallows pointer-exit events, so presenting
    /// one must put the highlight out AND forget the pointer: a frame report arriving while the
    /// modal is up must not re-light a row from a position the pointer no longer holds.
    func testWillPresentModalPutsTheHighlightOutAndAFrameReportDoesNotRelightIt() async {
        sut.pointerMoved(to: CGPoint(x: 60, y: 110), orderedIDs: ids)
        sut.willPresentModal()
        XCTAssertNil(sut.hoveredRowID)
        sut.reportFrame(CGRect(x: 40, y: 104, width: 120, height: 20), for: rowA, orderedIDs: ids)
        XCTAssertNil(sut.hoveredRowID)
    }

    func testPruneDropsRowsThatLeftTheTableAndKeepsTheRest() async {
        sut.prune(keeping: [rowB])
        XCTAssertNil(sut.frames[rowA])
        XCTAssertEqual(sut.frames[rowB], frameB)
    }

    /// Pruning the hovered row's own frame must also put the highlight out — its band no longer
    /// exists, so keeping it lit would claim a row that left the table.
    func testPruningTheHoveredRowPutsTheHighlightOut() async {
        sut.pointerMoved(to: CGPoint(x: 60, y: 110), orderedIDs: ids)
        sut.prune(keeping: [rowB])
        XCTAssertNil(sut.hoveredRowID)
    }
}

/// Source pins for the wiring the logic tests above cannot see: that the Runs table actually
/// CARRIES the row interaction, that the leaderboard actually does not, and that the band is the
/// house hover fill rather than a lookalike (CLAUDE.md #57 — the change is wiring, so the pin is
/// on the wiring). Scanning primitives come from `RatchetSourceScan` — never copy them locally
/// (CLAUDE.md #51; the two Benchmark suites used to hold byte-identical copies).
final class BenchmarkRunRowInteractionPinTests: XCTestCase {

    /// RED: delete the `SpatialTapGesture` from `historyTable` → fails.
    /// RED: change the Grid's `verticalSpacing:` token → fails (the wiring half of the
    /// band-separation invariant; the arithmetic half lives in the logic suite).
    func testTheRunsTableCarriesTheWholeRowInteraction() throws {
        let code = try Self.strippedSource("BenchmarkResultsCard.swift")
        let table = try XCTUnwrap(
            RatchetSourceScan.functionBody(after: "private func historyTable(", in: code))
        XCTAssertTrue(
            table.contains("historyHeader(Self.dateColumn)"),
            "the scanner did not find the Runs table at all")
        XCTAssertTrue(
            table.contains("verticalSpacing: Spacing.s"),
            "the Grid's row gap moved off Spacing.s — rowBand's outset math assumes it, "
                + "so re-check testRowBand_outsetLeavesAdjacentBandsSeparated before changing it")
        XCTAssertTrue(
            table.contains("onGeometryChange"),
            "no cell reports its frame — the bands have nothing to draw or hit-test against")
        XCTAssertTrue(
            table.contains("maxHeight: .infinity"),
            "the measured cell is no longer stretched to the row's height — the band now "
                + "under-covers any row whose tallest cell is a different one")
        XCTAssertTrue(
            table.contains("maxWidth: .infinity, alignment: .leading"),
            "the Grid hugs its columns again — the band, hover and click stop at the last "
                + "column instead of running the row edge to edge")
        XCTAssertTrue(
            table.contains("horizontalOutset: Spacing.standard"),
            "the band no longer bleeds under the card's padding — the lit row stops 16 pt "
                + "short of the card's edges")
        XCTAssertTrue(
            table.contains("onContinuousHover"),
            "the Runs table no longer tracks hover — rows cannot light")
        XCTAssertTrue(
            table.contains("SpatialTapGesture"),
            "the Runs table no longer opens a row's detail from a click on the row")
    }

    /// The whole-row tap is an accelerator, not a replacement: a tap gesture is invisible to
    /// accessibility, so the chevron Button IS the accessible path to the detail sheet, and it
    /// carries the row's `.help`. RED: delete the chevron cell from `historyTable` → fails.
    func testTheChevronSurvivesTheRowBecomingTappable() throws {
        let code = try Self.strippedSource("BenchmarkResultsCard.swift")
        let table = try XCTUnwrap(
            RatchetSourceScan.functionBody(after: "private func historyTable(", in: code))
        XCTAssertTrue(
            table.contains("detailButton(for: entry.run)"),
            "the chevron is gone — the detail sheet has no accessible, visible affordance left")
    }

    /// The leaderboard lights the row under the pointer — the same feedback as the Runs tab,
    /// added at the user's explicit request — but deliberately opens NOTHING: a leaderboard row
    /// aggregates many runs and has no detail sheet, so a tap gesture there would be a promise
    /// with nothing behind it, and a chevron would be its visible twin.
    /// RED: delete `.onContinuousHover` from `leaderboardTable` → fails.
    /// RED: paste a `SpatialTapGesture` onto the leaderboard Grid → fails.
    func testTheLeaderboardHighlightsOnHoverButOpensNothing() throws {
        let code = try Self.strippedSource("BenchmarkResultsCard.swift")
        let table = try XCTUnwrap(
            RatchetSourceScan.functionBody(after: "private func leaderboardTable(", in: code))
        XCTAssertTrue(
            table.contains("deleteButton("),
            "the scanner did not find the leaderboard table at all")
        for marker in ["onContinuousHover", "onGeometryChange", "BenchmarkRowBandLayer",
                       "maxWidth: .infinity, alignment: .leading",
                       "horizontalOutset: Spacing.standard"] {
            XCTAssertTrue(
                table.contains(marker),
                "the leaderboard lost '\(marker)' — its rows no longer light edge to edge")
        }
        for marker in ["SpatialTapGesture", "onTapGesture", "detailButton("] {
            XCTAssertFalse(
                table.contains(marker),
                "the leaderboard grew '\(marker)' — a click affordance with no sheet behind it")
        }
    }

    /// The band must be the design system's hover row, not a hand-mixed one. RED: swap the fill
    /// to a hard-coded color, or `animationWithReduceMotion` to a raw `.animation(` → fails.
    func testTheHighlightIsTheHouseHoverBand() throws {
        let code = try Self.strippedSource("BenchmarkRowInteraction.swift")
        let layer = try XCTUnwrap(
            RatchetSourceScan.functionBody(after: "struct BenchmarkRowBandLayer", in: code),
            "BenchmarkRowBandLayer is gone — re-aim this pin at whatever draws the hover band now")
        XCTAssertTrue(
            layer.contains("Colors.surfaceHover"),
            "the band's fill is not the design-system hover color")
        XCTAssertTrue(
            layer.contains("RoundedRectangle.squircle"),
            "the band is not the house squircle shape")
        XCTAssertTrue(
            layer.contains("animationWithReduceMotion(Animations.quick"),
            "the band ignores Reduce Motion or the house hover animation")
    }

    /// Xcode 26.6's (17F113) Release optimizer segfaults on the implicitly MainActor-isolated
    /// deinit of this GENERIC class (EarlyPerfInliner →
    /// `isCallerAndCalleeLayoutConstraintsCompatible`, null generic signature) — the explicit
    /// `nonisolated deinit` is the bisected workaround, and deleting it stays green in every
    /// Debug build while breaking the next Archive, which is exactly the invisible-until-release
    /// failure this pin exists to catch. Retire the pin TOGETHER with the workaround once the
    /// toolchain compiles the class's implicit deinit at `-O` without crashing (the deinit's doc
    /// comment carries the single-file repro recipe).
    /// RED: delete `nonisolated deinit {}` from `BenchmarkRowInteractionState` → fails.
    func testTheStateClassKeepsItsCompilerCrashWorkaroundDeinit() throws {
        let code = try Self.strippedSource("BenchmarkRowInteraction.swift")
        let state = try XCTUnwrap(
            RatchetSourceScan.functionBody(
                after: "final class BenchmarkRowInteractionState", in: code),
            "BenchmarkRowInteractionState is gone — if the generic @Observable class was "
                + "restructured, re-check that a Release archive still compiles before "
                + "retiring this pin")
        XCTAssertTrue(
            state.contains("nonisolated deinit"),
            "the compiler-crash workaround deinit is gone — Debug stays green but the next "
                + "Release archive segfaults swift-frontend (EarlyPerfInliner) unless the "
                + "toolchain has been fixed; verify with the repro in the deinit's doc comment")
    }

    /// Comments stripped so prose describing the wrong shape cannot satisfy a pin (CLAUDE.md #89).
    private static func strippedSource(_ name: String) throws -> String {
        let url = RatchetSourceScan.repoRoot
            .appendingPathComponent("NanoTeams/Views/Settings/Benchmark/\(name)")
        return RatchetSourceScan.strippingLineComments(
            try String(contentsOf: url, encoding: .utf8))
    }
}
