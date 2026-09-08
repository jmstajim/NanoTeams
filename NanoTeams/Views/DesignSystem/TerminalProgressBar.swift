import SwiftUI

// MARK: - Progress Bar (block bar-metric)

/// The design system's determinate progress bar, drawn with real box characters on the mono
/// grid — a track of `█` in a dim colour, with the lit run (`█` plus an eighth-block partial at
/// its leading edge) drawn OVER it in the tint.
/// Port of `DesignSystem/components/data/ProgressBar.jsx` (`blocks` variant).
///
/// Replaces `ProgressView` + `.progressViewStyle(.linear)`, whose capsule track, system tint and
/// implicit animation belong to macOS rather than to this design language.
/// `NativeControlStylePinTests` keeps the native one from coming back.
///
/// **Two layers, one glyph, and both of those are load-bearing** (measured 2026-09-08, at both
/// fonts this bar is drawn with):
///
/// - *Layered*, because a partial glyph is left-aligned and covers only its own fraction of its
///   cell. Subtracting that WHOLE cell from the track — which is what this did until
///   2026-09-08 — leaves the remainder painted with nothing: 0.849pt behind `▉` up to 5.951pt
///   behind `▏` at 11pt. Drawing the track under the fill closes it by construction.
/// - *`█` for the track*, because it is the only glyph whose ink matches the fill's on BOTH
///   axes: `░` also carries a 0.569pt left side bearing, and `░`/`▒` alike sit ~0.12pt short of
///   `█` at the top and overhang it at the bottom. A shade track fixes nothing and leaves the
///   fill standing proud of its own groove. Pinned in `MonoCellReferenceGlyphTests`
///   (CLAUDE.md #227).
///
/// Determinate only, by design: `NTMSLoader` already owns the indeterminate case (rotating stick
/// + glitch bursts), so the JSX's marquee has no Swift consumer and would be a second thing to
/// keep in sync with the spec. The JSX's `label` slot is likewise absent — every call site here
/// already carries its own status row above the bar.
struct TerminalProgressBar: View {
    /// Fraction complete. Clamped to `0...1`; a non-finite value renders an empty track rather
    /// than a bar of `nan` cells.
    let value: Double
    /// Width of the bar in mono cells. The bar's rendered width is exactly this many characters,
    /// so it never depends on the container.
    var cells: Int = 24
    /// Trailing percent readout. The bar alone answers "roughly how far"; the number answers
    /// "how far", and a build that sits at 99% for a minute is a different thing to watch than
    /// one that sits at 4%.
    var showsValue: Bool = true
    var tint: Color = Colors.accent
    /// The cell size. A caller drawing the bar inside another control's frame — the composer's
    /// role chip — needs the bar on that control's grid, not on the settings card's.
    var font: Font = Typography.termMd
    /// The unlit run — `.clear` for a bar that must hold its width without showing a scale.
    ///
    /// The default suits THIS view's default seat, the settings card (`surfaceCard`), where it
    /// measures ΔE 11.0 at its worst. It is not a safe default anywhere else: on
    /// `surfaceElevated` — a composer chip — `borderStrong` is byte-identical to the ground in
    /// `umberDark` and `lilacDark`, so the track disappears. Measure a new seat before taking
    /// the default; `ContextFillBarPaletteTests` is the worked example and `Colors.textTertiary`
    /// the token that survives every chip ground.
    var trackTint: Color = Colors.borderStrong

    /// How far the block glyph's INK sits below the centre of the LINE BOX that lays it out,
    /// as a fraction of the line height.
    ///
    /// `█` is drawn from below the baseline to above the cap height, so it does not sit in the
    /// middle of its own line: measured on SF Mono at 11pt regular and 14pt medium, the ink
    /// centre is 1.1494pt and 1.4629pt below the box centre — 8.872% of the line height in BOTH
    /// cases, because this is a property of the face and not of the size. A parent centring the
    /// bar centres the box, so the painted bar lands that much low inside a chip.
    ///
    /// Applied with `.offset`, which moves paint and not layout: the same bar sits beside a
    /// percent label in the settings card, and a correction that changed the height would move
    /// the label with it. Pinned by `MonoCellReferenceGlyphTests`.
    static let blockInkCentringRatio: CGFloat = 0.08872

    /// The glyph layer's own height, i.e. the font's line height. Read rather than derived
    /// because `Font` does not expose its point size, and the correction above is a fraction of
    /// exactly this (View Conventions #19).
    @State private var glyphLineHeight: CGFloat = 0

    var body: some View {
        let bar = Self.blocks(value: value, cells: cells)
        HStack(spacing: Spacing.s) {
            // `ZStack`, not `.overlay`: an overlay proposes the BASE's size to its content and a
            // wider `Text` truncates to `…` rather than overflowing — the trap `MonoCell`
            // documents. Both layers are the same width here, but the failure mode is silent,
            // so the shape that cannot produce it is the one to use.
            ZStack(alignment: .topLeading) {
                Text(bar.track)
                    .foregroundStyle(trackTint)
                    .lineLimit(1)
                    .fixedSize()
                Text(bar.fill)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(font)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { glyphLineHeight = $0 }
            .offset(y: -glyphLineHeight * Self.blockInkCentringRatio)

            if showsValue {
                Spacer(minLength: Spacing.xs)
                Text(Self.percentLabel(value))
                    .font(Typography.termXs)
                    .monospacedDigit()
                    .foregroundStyle(Colors.textPrimary)
            }
        }
        // The glyphs are decoration; the value is the content. Represented as a native
        // ProgressView so VoiceOver reads a progress indicator rather than a run of box
        // characters (the shape `TerminalSlider` uses for the same reason).
        .accessibilityRepresentation {
            ProgressView(value: Self.clamped(value))
        }
    }

    // MARK: - Pure presentation (unit-tested)

    /// Eighth-block partials, indexed 0...8 exactly as the JSX's `PARTIALS` table — index 0 is
    /// the empty string, so a cell that is 0/8 full contributes no character at all.
    ///
    /// Internal rather than private because `MonoCellReferenceGlyphTests` pins the METRICS of
    /// this exact table: every entry has to share `█`'s advance, its zero left side bearing and
    /// its ink height, or the two layers stop lining up.
    static let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]

    /// The glyph both layers are drawn with. See the type's doc comment for why the track is
    /// not a shade character.
    static let block = "█"

    /// `value` mapped onto the `0...1` line. Non-finite reads as 0: a `nan` progress is an
    /// arithmetic accident upstream, and showing a full bar for it would report success.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// The bar as two strings — the track and the lit run drawn over it — so the caller can
    /// paint them in two colours while they stay on one mono grid.
    ///
    /// `track.count == cells` at EVERY value, and `fill.count <= cells` at every value. The
    /// track is what establishes the bar's width; the fill never widens it.
    ///
    /// Two rules at the ends exist because the glyphs quantise and the value does not:
    ///
    /// - the fill reaches `cells` whole blocks only at `value == 1`. Without this, 99% of four
    ///   cells (`3.96`, whose partial rounds up) renders a COMPLETE bar — on the context-fill
    ///   indicator that is "no room left" lighting up while there is still room. This is the
    ///   same refusal `percentLabel` already makes for the number;
    /// - the fill is empty only at `value == 0`. Without this, 1% of four cells rounds to zero
    ///   eighths and a role that has started filling its context shows what a role that has
    ///   sent nothing shows.
    static func blocks(value: Double, cells: Int) -> (fill: String, track: String) {
        let cellCount = max(1, cells)
        let fraction = clamped(value)
        let total = fraction * Double(cellCount)
        var full = Int(total.rounded(.down))
        var partialIndex = Int(((total - Double(full)) * 8).rounded())
        // An eighth-index that rounds up to a whole cell IS a whole cell.
        if partialIndex == 8 {
            full += 1
            partialIndex = 0
        }
        full = min(full, cellCount)
        if fraction < 1, full == cellCount {
            // Complete only at 1: back off to seven eighths of the last cell. Same rendered
            // width, so the bar still does not move — only the last cell's paint changes.
            full = cellCount - 1
            partialIndex = 7
        } else if fraction > 0, full == 0, partialIndex == 0 {
            // Above zero, show the smallest mark the grid has rather than nothing.
            partialIndex = 1
        }
        let partial = full < cellCount ? partials[partialIndex] : ""
        return (String(repeating: block, count: full) + partial,
                String(repeating: block, count: cellCount))
    }

    /// Whole percent — the bar is 24 cells wide, so a decimal would claim a resolution the glyphs
    /// cannot show.
    ///
    /// One deliberate departure from the JSX, which is a plain `Math.round`: 99.6% rounds to 100,
    /// and a readout that says "100%" while the work is still running is the one number a
    /// progress bar must never print. Only a genuinely complete value gets it.
    static func percentLabel(_ value: Double) -> String {
        let fraction = clamped(value)
        let percent = Int((fraction * 100).rounded())
        return "\(fraction < 1 ? min(percent, 99) : percent)%"
    }
}

// MARK: - Previews

#Preview("Terminal Progress Bar") {
    VStack(alignment: .leading, spacing: Spacing.l) {
        TerminalPane(title: "Progress") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                TerminalProgressBar(value: 0)
                TerminalProgressBar(value: 0.07)
                TerminalProgressBar(value: 0.53)
                TerminalProgressBar(value: 1)
                TerminalProgressBar(value: 0.42, cells: 12)
                TerminalProgressBar(value: 0.42, showsValue: false)
                TerminalProgressBar(value: 0.42, tint: Colors.success)
                TerminalProgressBar(
                    value: 0.42, cells: 4, showsValue: false, font: Typography.termXs)
            }
        }
    }
    .padding(Spacing.xl)
    .frame(width: 480)
    .background(Colors.surfacePrimary)
}
