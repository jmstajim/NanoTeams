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
struct TerminalStatusBadge: View {
    let glyph: String
    let label: String
    let color: Color
    var bordered: Bool = true

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Text(glyph)
                .font(Typography.termSm)
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(Typography.term2xs)
                .tracking(Typography.labelTracking)
                .foregroundStyle(color)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
            RoundedRectangle.squircle(CornerRadius.micro)
                .fill(color.opacity(DynamicTintOpacity.background))
        )
        .overlay {
            if bordered {
                // Stroke at the status color at `DynamicTintOpacity.stroke` (0.3)
                // ≈ DS's `color-mix(... 40%, transparent)` over the tint fill.
                RoundedRectangle.squircle(CornerRadius.micro)
                    .strokeBorder(color.opacity(DynamicTintOpacity.stroke), lineWidth: 1)
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
    }
    .padding(Spacing.l)
    .background(Colors.surfacePrimary)
}
#endif
