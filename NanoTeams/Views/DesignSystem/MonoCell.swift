import SwiftUI

// MARK: - Mono Cell

/// One terminal cell: a box whose width and height come from the FONT's own
/// metrics, never from whichever glyph happens to be drawn inside it.
///
/// The design language is "one font on a fixed grid" (`Typography`), and the
/// grid only holds if the CELL is sized by the grid. Two things in this app
/// routinely put an off-grid glyph in a cell, because SF Mono does not cover
/// every character they use and CoreText silently substitutes a fallback face
/// with different metrics:
///
/// - `NTMSLoader`'s glitch pool. Measured at `Typography.termXs` (SF Mono 11pt
///   — line height 12.955, advance 6.800), **16 of its 35 glyphs change a
///   metric**: `≀` and `⁊` resolve to Monaco (line height 14.668, +1.713pt
///   taller), `／` and `＼` to PingFang SC (advance 10.936, +4.136pt wider),
///   the half-width katakana to CJKSymbolsFallback (advance 5.280, −1.520pt).
///   A burst fires roughly every three seconds for 3–6 frames at 80ms, so any
///   caption row carrying a spinner twitched several times a minute — and
///   because those rows sit inside a message bubble's `VStack`, the bubble and
///   everything below it twitched with them.
/// - `TerminalGlyph`'s status set. Measured at the same size: `‖` (paused)
///   resolves to Monaco at 14.668 (+1.713pt), `◆` (review) and `↻` (revision)
///   to Menlo at 12.805. So a role changing status changed its row's metrics.
///   Its other glyphs — `● ▸ ✓ ✗ · › █` — are all genuinely SF Mono.
///
/// The cell holds the grid: a hidden reference glyph supplies the layout, and
/// the real content is drawn OVER it at its own ideal size. A wide glyph spills
/// a couple of points into the gutter — which is what a torn signal should look
/// like — and moves nothing.
///
/// Measurements are pinned by `MonoCellReferenceGlyphTests`, which fails if the
/// reference glyph ever stops being covered by SF Mono.
struct MonoCell<Content: View>: View {
    private let font: Font
    private let content: Content

    init(font: Font, @ViewBuilder content: () -> Content) {
        self.font = font
        self.content = content()
    }

    var body: some View {
        Text(TerminalGlyph.cellReference)
            .font(font)
            .hidden()
            // Load-bearing. `.overlay` proposes the BASE's size to its content,
            // and a `Text` wider than the proposal TRUNCATES to `…` rather than
            // overflowing — so without this the spinner renders as an ellipsis
            // on exactly the wide fallback glyphs this cell exists to contain.
            .overlay { content.fixedSize() }
    }
}

extension MonoCell where Content == EmptyView {
    /// An inkless cell — the height and width of any `MonoCell` in the same
    /// font, because it is the same cell. Used to hold a column or a row open
    /// while its content is absent, so the arrival or departure of a marker is
    /// a paint change rather than a layout change.
    init(font: Font) {
        self.init(font: font) { EmptyView() }
    }
}

#Preview("MonoCell — every NTMSLoader glitch glyph in a cell") {
    // The review artifact for the cell: every glyph the loader can draw, each
    // in a cell, beside a caption. A regression in the cell shows up here as a
    // row whose caption sits at a different height from its neighbours — or,
    // if `.fixedSize()` were dropped, as an `…` in place of a wide glyph.
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(NTMSLoader.rotationFrames + NTMSLoader.glitchGlyphs, id: \.self) { glyph in
                HStack(spacing: Spacing.xs) {
                    MonoCell(font: Typography.termXs) {
                        Text(glyph)
                            .font(Typography.termXs)
                            .foregroundStyle(Colors.accent)
                    }
                    Text("Processing 42%")
                        .font(Typography.termXs.weight(.medium))
                        .foregroundStyle(Colors.textTertiary)
                }
                .background(Colors.surfaceElevated)
            }
        }
        .padding(Spacing.standard)
    }
    .frame(width: 240, height: 560)
    .background(Colors.surfacePrimary)
}
