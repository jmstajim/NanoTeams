import SwiftUI

/// A benchmark table's whole-row hover state: which row is under the pointer, and where each
/// row's band is. Generic over the row id — the Runs table keys rows by `GenerationBenchmarkRun`
/// UUIDs, the leaderboard by `BenchmarkLeaderboard.Row`'s composite String — and each table owns
/// its OWN instance, because "the row under the pointer" is a fact about one Grid.
///
/// Split off `BenchmarkResultsCard` per CLAUDE.md view convention #11 — hover crossings arrive at
/// pointer-move frequency and cell frames re-report on every layout pass, and as card `@State`
/// each write re-evaluated the card's whole `body`, which re-derives `historyEntries` (a sample
/// grouping, a sort, and five medians per run) to answer a question whose only consumer is the
/// band layer. As an `@Observable`, only `BenchmarkRowBandLayer` reads these properties, so that
/// leaf re-renders alone.
///
/// The interaction itself lives at the GRID level, not on the cells: a `GridRow` is not a view,
/// so per-cell handlers would leave every 12 pt column gap hover-dead and click-dead and flicker
/// the band on each crossing. One measured cell per row is enough for geometry — the Grid centers
/// cells vertically and the measured cell is stretched to the row's height (`.frame(maxHeight:
/// .infinity)`), so its frame IS the row's.
@Observable
final class BenchmarkRowInteractionState<ID: Hashable & Sendable> {

    /// Compiler-crash workaround, load-bearing for Archive: with the project's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the implicit deinit of a GENERIC class is
    /// MainActor-isolated, and Xcode 26.6's (17F113) Release optimizer segfaults on exactly that
    /// shape — EarlyPerfInliner → `isCallerAndCalleeLayoutConstraintsCompatible` null-derefs a
    /// generic signature while examining the isolation thunk's callees (`SILFunction
    /// "@$s…BenchmarkRowInteractionStateCfD"`). Debug never sees it: the perf inliner only runs
    /// at `-O`, so deleting this line stays green everywhere until the next Archive. Bisected
    /// 2026-08-22 on a single-file repro: baseline rc=139 (SIGSEGV), with this line rc=0; the
    /// crash also needs `-default-isolation=MainActor` — this declaration removes precisely the
    /// triggering ingredient, and nothing here needs the main actor to be torn down (value-type
    /// stored properties only). Remove when the toolchain's inliner no longer crashes on the
    /// repro (`BenchmarkRunRowInteractionTests` pins the presence until then).
    nonisolated deinit {}

    /// One frame per visible row: its stretched model cell, in the Grid's named space.
    /// Stale keys are pruned when the visible set changes WHILE the table is on screen — a prune
    /// cannot fire for a set change that removes the whole Grid (filter-to-empty, tab switch), so
    /// the dictionary is bounded by the union of the visible sets this table has shown, not
    /// strictly by the current row count. Orphaned keys are unreachable either way: the band
    /// layer and `rowID(at:)` iterate the visible ids, so an id that left the table draws
    /// nothing and matches nothing.
    private(set) var frames: [ID: CGRect] = [:]

    /// The row the band lights. By id rather than by value for the same reason as the card's
    /// `detailRunID` (CLAUDE.md #22).
    private(set) var hoveredRowID: ID?

    /// The last pointer location in the Grid's space, kept so a row REFLOW under a stationary
    /// pointer — a confirmed delete removing a row, a settling measurement prepending one —
    /// re-derives the lit row from the fresh frames instead of waiting for the next mouse move.
    /// A SCROLL under a stationary pointer still goes stale until the pointer moves: scrolling
    /// changes no cell's Grid-space frame, so nothing here fires. That staleness is cosmetic and
    /// self-healing on the first pixel of movement — a click always hit-tests fresh frames.
    @ObservationIgnored private var lastPointer: CGPoint?

    func pointerMoved(to point: CGPoint, orderedIDs: [ID]) {
        lastPointer = point
        rehitTest(orderedIDs)
    }

    func pointerEnded() {
        lastPointer = nil
        setHovered(nil)
    }

    func reportFrame(_ frame: CGRect, for id: ID, orderedIDs: [ID]) {
        guard frames[id] != frame else { return }
        frames[id] = frame
        rehitTest(orderedIDs)
    }

    /// Called before anything modal covers the table — the detail sheet, the delete confirmation.
    /// Both swallow pointer-exit events, and a band still lit behind a dismissed modal claims a
    /// hover that ended. Forgetting the pointer too is deliberate: a frame report arriving while
    /// the modal is up must not re-light a row from a position the pointer no longer holds.
    func willPresentModal() {
        lastPointer = nil
        setHovered(nil)
    }

    /// Drops frames of rows that left the table (filtered out or deleted), so the dictionary is
    /// bounded while the table is on screen.
    func prune(keeping ids: [ID]) {
        let keep = Set(ids)
        guard frames.keys.contains(where: { !keep.contains($0) }) else { return }
        frames = frames.filter { keep.contains($0.key) }
        rehitTest(ids)
    }

    /// Every write is change-guarded because `@Observable` does not coalesce same-value writes
    /// the way `@State` does — an unguarded assignment per pointer-move event would re-render the
    /// band layer at event rate for a value that did not change.
    private func setHovered(_ id: ID?) {
        guard hoveredRowID != id else { return }
        hoveredRowID = id
    }

    private func rehitTest(_ orderedIDs: [ID]) {
        setHovered(lastPointer.flatMap {
            Self.rowID(at: $0, frames: frames, orderedIDs: orderedIDs)
        })
    }

    // MARK: - Pure geometry (unit-tested)

    /// The y-interval a row's highlight and its hit-testing share, from the frame its stretched
    /// model cell reported, outset by `Spacing.xxs` a side — which stays inside the Grid's
    /// `Spacing.s` of `verticalSpacing`, so adjacent bands never touch. A `Range` rather than an
    /// origin/height pair because the half-open semantics ARE the contract: a band's top line is
    /// its own, its bottom line already is not, so a point on the boundary of two touching bands
    /// cannot match both. `nil` — not an empty range at the origin, which is a drawable claim —
    /// until the first layout pass reports, and for a cell collapsing out of the hierarchy.
    nonisolated static func rowBand(around cell: CGRect?) -> Range<CGFloat>? {
        guard let cell, cell.height > 0 else { return nil }
        return (cell.minY - Spacing.xxs)..<(cell.maxY + Spacing.xxs)
    }

    /// Which visible row a point in the Grid's space belongs to. Only y decides — the bands span
    /// the Grid's full width, so a click in a column gap is still a click on the row. First match
    /// in table order wins, deterministically, if stale frames ever overlap mid-relayout; an id
    /// whose cell has not reported yet is skipped, not matched.
    nonisolated static func rowID(
        at point: CGPoint, frames: [ID: CGRect], orderedIDs: [ID]
    ) -> ID? {
        orderedIDs.first { id in
            rowBand(around: frames[id])?.contains(point.y) ?? false
        }
    }
}

/// The hover bands behind a benchmark Grid, one per visible row. Full Grid width on purpose — the
/// column gaps are part of the row, so the highlight must not stripe. The shapes are persistent
/// and only the FILL toggles, the house hover idiom (`DownloadedModelsCard`): entering a row is a
/// color ease, not an insertion. This leaf is the ONLY view that reads the interaction state —
/// see `BenchmarkRowInteractionState` for why that isolation is the point.
struct BenchmarkRowBandLayer<ID: Hashable & Sendable>: View {
    let ids: [ID]
    let interaction: BenchmarkRowInteractionState<ID>
    /// Horizontal bleed past the Grid's frame, per side — the card that hosts the table passes
    /// its own `contentPadding` here so the band runs edge to edge of the CARD and stops only at
    /// its border, not at the padding. The value is the CALLER's knowledge on purpose: this layer
    /// has no business knowing which container it decorates. Zero (the default) means the band
    /// stops at the Grid's frame.
    var horizontalOutset: CGFloat = 0

    var body: some View {
        // The explicit ZStack is load-bearing, not style: sibling views handed to
        // `.background(alignment:) { }` are grouped by an implicit stack that sizes to the
        // TALLEST of them and centers the others against it — the `alignment:` parameter places
        // only the composite. `.offset(y:)` then applies from that centered origin, so with rows
        // of unequal heights (one wrapped model name) every shorter band drew (maxH − h)/2 pt
        // below its own hit-test range. Measured at 8 pt with a 3-line row beside 2-line rows;
        // `BenchmarkRowBandGeometryHarnessTests` pins the drawn pixels against the hit-test
        // range, so removing this ZStack goes red.
        ZStack(alignment: .topLeading) {
            ForEach(ids, id: \.self) { id in
                if let band = BenchmarkRowInteractionState<ID>.rowBand(
                    around: interaction.frames[id]) {
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(interaction.hoveredRowID == id ? Colors.surfaceHover : Color.clear)
                        .frame(maxWidth: .infinity)
                        .frame(height: band.upperBound - band.lowerBound)
                        // Negative padding BLEEDS the shape symmetrically past its slot — the
                        // wrapper keeps the slot's size, so the ZStack's topLeading placement
                        // and the y-offset below are unaffected.
                        .padding(.horizontal, -horizontalOutset)
                        .offset(y: band.lowerBound)
                }
            }
        }
        .animationWithReduceMotion(Animations.quick, value: interaction.hoveredRowID)
    }
}
