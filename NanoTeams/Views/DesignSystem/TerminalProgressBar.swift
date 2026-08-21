import SwiftUI

// MARK: - Progress Bar (block bar-metric)

/// The design system's determinate progress bar, drawn with real box characters on the mono
/// grid — `█` filled, an eighth-block partial at the leading edge, `░` for the remainder.
/// Port of `DesignSystem/components/data/ProgressBar.jsx` (`blocks` variant).
///
/// Replaces `ProgressView` + `.progressViewStyle(.linear)`, whose capsule track, system tint and
/// implicit animation belong to macOS rather than to this design language. The app carried
/// exactly one such bar (the vector-index build in `ExploratorySearchEmbeddingsCard`); this is
/// what it renders with now, and `NativeControlStylePinTests` keeps the native one from coming
/// back.
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

    var body: some View {
        let bar = Self.blocks(value: value, cells: cells)
        HStack(spacing: Spacing.s) {
            (Text(bar.fill).foregroundStyle(tint)
                + Text(bar.empty).foregroundStyle(Colors.borderStrong))
                .font(Typography.termMd)
                .lineLimit(1)
                .fixedSize()

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
    private static let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]

    /// `value` mapped onto the `0...1` line. Non-finite reads as 0: a `nan` progress is an
    /// arithmetic accident upstream, and showing a full bar for it would report success.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// The bar as two strings — the lit run and the dark run — so the caller can paint them in
    /// two colors while they stay on one mono grid.
    ///
    /// `fill.count + empty.count == cells` at every value EXCEPT a full bar, where the partial
    /// glyph is suppressed (a `█` at the leading edge is indistinguishable from a filled cell,
    /// and emitting it would make a finished bar one cell wide).
    static func blocks(value: Double, cells: Int) -> (fill: String, empty: String) {
        let cellCount = max(1, cells)
        let total = clamped(value) * Double(cellCount)
        var full = Int(total.rounded(.down))
        var partialIndex = Int(((total - Double(full)) * 8).rounded())
        // An eighth-index that rounds up to a whole cell IS a whole cell.
        if partialIndex == 8 {
            full += 1
            partialIndex = 0
        }
        full = min(full, cellCount)
        let partial = full < cellCount ? partials[partialIndex] : ""
        let empty = max(0, cellCount - full - (partial.isEmpty ? 0 : 1))
        return (String(repeating: "█", count: full) + partial,
                String(repeating: "░", count: empty))
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
            }
        }
    }
    .padding(Spacing.xl)
    .frame(width: 480)
    .background(Colors.surfacePrimary)
}
