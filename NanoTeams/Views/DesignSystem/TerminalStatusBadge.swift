import SwiftUI

// MARK: - Terminal Status Badge

/// Status glyph + UPPERCASED tracked label in a status color, on a tint-filled
/// micro squircle — the shared chrome behind the Team Board run-state badge
/// (`TeamBoardTopBar`) and the Team Editor validation badge (`TeamEditorTopBar`).
/// Factored out so the padding / tint / typography can't drift per surface;
/// 1:1 with `DesignSystemByClaude/components/core/Badge.jsx`.
///
/// `bordered` adds the DS `Badge.jsx` 1px status-tinted hairline. The run-state
/// badge sits next to a bracket-outline secondary button and needs it to read as
/// a cell; the validation badge stands alone and omits it. Callers attach their
/// own `.accessibilityLabel` (e.g. "Status: …" vs "Validation: …").
///
/// **A TAG is not a status** — `tag(label:)` is the second form, and it takes neither a colour
/// nor a dot. RECOMMENDED marks an option; it reports nothing about it, and
/// `Badge.jsx` draws a badge with no status as the neutral trio (`--nt-text-2` on
/// `--nt-surface-2` inside `--nt-border`) with its `dot` left at its default `false` — the
/// dot is lit from the status colour, so a badge with no status has nothing to light. Both had been built out of `Colors.info` on the reasoning that the info blue
/// is "not the accent" — measured 2026-09-11 across `Theme.swift`, **`info == accent` in 20 of
/// the 24 palettes**, so on almost every theme a recommendation was drawn in the very colour of
/// the selection mark beside it. The default `terminalDark` is one of the four where the two
/// tokens happen to differ — which is why reading the code, and looking at the screen, both said
/// it was fine.
struct TerminalStatusBadge: View {
    /// The status dot. `nil` for a tag, which has no status to report — and that is the
    /// reference component's own default (`Badge.jsx` takes `dot = false` and lights it from the
    /// status colour). A tag drawn with one reads as a state the thing is IN.
    let glyph: String?
    let label: String
    /// Ink for both glyph and label. A status badge passes its status colour and derives the
    /// fill and hairline from it; a tag passes the neutral token and supplies the other two.
    let foreground: Color
    let fill: Color
    /// `nil` draws no hairline. A tag always has one: `neutralTint` on `surfaceElevated` is
    /// 1.11:1, so without the border the tag's cell is invisible on its most common host.
    let border: Color?

    /// A STATUS badge: one colour, tinted into the fill and the optional hairline.
    init(glyph: String, label: String, color: Color, bordered: Bool = true) {
        self.glyph = glyph
        self.label = label
        self.foreground = color
        self.fill = color.opacity(DynamicTintOpacity.background)
        self.border = bordered ? color.opacity(DynamicTintOpacity.stroke) : nil
    }

    private init(glyph: String?, label: String, foreground: Color, fill: Color, border: Color?) {
        self.glyph = glyph
        self.label = label
        self.foreground = foreground
        self.fill = fill
        self.border = border
    }

    /// A neutral TAG — a standing mark on the thing beside it, in no status colour.
    ///
    /// `Colors.textSecondary` rather than `Colors.neutral`: measured across all 24 palettes,
    /// `textSecondary` is the only ink token that differs from `accent` in every one of them
    /// (`neutral == accent` on `neonDark`), and "never the selection colour" is the whole
    /// property this form exists to hold. The fill/border pair is the one `ErrorBannerView`
    /// already wears for its neutral `.info` banner.
    static func tag(label: String) -> TerminalStatusBadge {
        TerminalStatusBadge(
            glyph: nil, label: label,
            foreground: Colors.textSecondary, fill: Colors.neutralTint,
            border: Colors.neutralBorder)
    }

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let glyph {
                Text(glyph)
                    .font(Typography.termSm)
                    .foregroundStyle(foreground)
            }
            Text(label.uppercased())
                .font(Typography.term2xs)
                .tracking(Typography.labelTracking)
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
            RoundedRectangle.squircle(CornerRadius.micro).fill(fill)
        )
        .overlay {
            if let border {
                // Stroke at the status color at `DynamicTintOpacity.stroke` (0.3)
                // ≈ DS's `color-mix(... 40%, transparent)` over the tint fill.
                RoundedRectangle.squircle(CornerRadius.micro)
                    .strokeBorder(border, lineWidth: 1)
            }
        }
        .fixedSize()
    }
}

#if DEBUG
#Preview("Status Badges") {
    VStack(alignment: .leading, spacing: Spacing.m) {
        TerminalStatusBadge(glyph: TerminalGlyph.working, label: "working", color: Colors.info)
        TerminalStatusBadge(glyph: TerminalGlyph.done, label: "graph valid", color: Colors.success, bordered: false)
        TerminalStatusBadge(glyph: TerminalGlyph.failed, label: "2 issues", color: Colors.error, bordered: false)
        // The tag form, beside a selection mark in the accent — the comparison the
        // `info == accent` defect was invisible without.
        HStack(spacing: Spacing.s) {
            Text(TerminalGlyph.checkedRadio)
                .font(Typography.choiceMark)
                .foregroundStyle(Colors.accent)
            TerminalStatusBadge.tag(label: "recommended")
        }
    }
    .padding(Spacing.l)
    .background(Colors.surfaceElevated)
}
#endif
