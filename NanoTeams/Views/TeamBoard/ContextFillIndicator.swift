import SwiftUI

/// How full one role's context is, drawn INSIDE its chip in the composer's "To" row — and the
/// one place a human can compact that role's conversation.
///
/// Inside the chip because that is the only surface where the role is named at the moment the
/// user is about to add to its conversation. The wire is append-only and resent whole on every
/// request, so a chat-mode role walks toward its window with no symptom until the server either
/// truncates the head silently or refuses the prompt; both arrive with the conversation already
/// too big to save.
///
/// **No number here.** The bar answers "roughly how full" at a glance; the exact count, its
/// source (server or estimator), the budget and the window are all one hover away in the
/// tooltip, which is where a number that can be off by 2.2× belongs.
///
/// **The two readings the bar has to keep apart**, now that the percentage is gone:
///
/// - *no proportion* — either the role has not sent a request yet, or it has and the window was
///   never probed. Both draw the track with nothing lit, and they are deliberately the same
///   picture: to a reader they make the same statement, "there is no proportion to show yet".
///   The empty bar is drawn from the first frame, so a role's first answer changes the chip's
///   PAINT and not its LAYOUT.
/// - *measured* — at least one eighth is lit, always: `TerminalProgressBar.blocks` never renders
///   an empty fill above zero. So a lit bar is never ambiguous, and an unlit one means exactly
///   the case above.
///
/// A leaf view with its own `@Environment(ContextFillProjection.self)`, per View Conventions
/// #11: the fill changes once per REQUEST, and reading it from the composer body would tie the
/// whole chip row to that observation for no benefit. It reads the orchestrator only to call
/// the action.
struct ContextFillIndicator: View {

    let taskID: Int
    let roleID: String
    let roleName: String
    /// True when the chip underneath is filled — the selected recipient. The chip keeps ONE
    /// ground; what this switches is the bar's INK, because the filled ground admits no tier
    /// hue at all. Measured over every theme in both schemes plus the fourteen editable role
    /// tints an Answer chip can carry: `accent`, `gold` and `error` each collapse to ΔE 0
    /// against some ground a chip can actually have, and an unlit bar is the one reading the
    /// indicator must never fake — it means "the window was never probed".
    let isOnAccent: Bool

    @Environment(ContextFillProjection.self) private var contextFill
    @Environment(NTMSOrchestrator.self) private var store

    /// Cells of the mini bar. Four, not the design system's 24: this sits inside a chip row
    /// that already scrolls horizontally, and the width is paid on EVERY chip, always — 27.2pt
    /// of glyphs plus 10pt of gutters, so ~300pt across the eight FAANG roles. Four cells of
    /// eighths still quantise at 3.125%, which is finer than the eye reads off a 27pt bar.
    private static let cells = 4

    var body: some View {
        let fill = contextFill.fill(stepID: roleID, taskID: taskID)
        let isCompacting = contextFill.isCompacting(stepID: roleID, taskID: taskID)
        if let fill {
            indicator(fill: fill, isCompacting: isCompacting)
        } else if isCompacting {
            indicator(fill: ContextFill(promptTokens: 0), isCompacting: true)
        } else {
            emptyBar
        }
    }

    /// The role has not sent a request yet: nothing to compact and no button — but the bar is
    /// there, empty, from the first frame. Drawing it only once a measurement exists made the
    /// chip look like it had a ragged gutter until the role answered, and made the arrival of
    /// the first fill a new ELEMENT rather than a change of paint.
    private var emptyBar: some View {
        inlay(bar(value: 0, tint: .clear, trackTint: trackTint))
            .accessibilityHidden(true)
    }

    private func indicator(fill: ContextFill, isCompacting: Bool) -> some View {
        let tier = ContextFillPresentation.tier(fill)
        return Button {
            Task { await store.compactRoleContext(taskID: taskID, roleID: roleID) }
        } label: {
            inlay(
                bar(
                    value: ContextFillPresentation.fraction(fill) ?? 0,
                    tint: fillTint(for: tier, isCompacting: isCompacting),
                    trackTint: trackTint)
            )
            // AFTER the padding and the frame, so the hit area is the whole inlay rather than
            // the glyphs (CLAUDE.md #12 — an icon-only control's hit area is its cell).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCompacting)
        .help(ContextFillPresentation.tooltip(fill, isCompacting: isCompacting))
        .accessibilityLabel("\(roleName) context")
        .accessibilityValue(
            ContextFillPresentation.accessibilityValue(fill, isCompacting: isCompacting))
        .accessibilityHint("Compacts this role's conversation into a summary")
    }

    /// The bar's seat in the chip: its own gutters and the chip's full height, so the click
    /// zone is the whole cell. No ground of its own — the chip is one colour, and the bar is
    /// drawn in ink that survives whichever colour that is.
    private func inlay(_ content: some View) -> some View {
        content
            .padding(.leading, Spacing.xs)
            .padding(.trailing, Spacing.s - 2)
            .frame(maxHeight: .infinity)
    }

    private func bar(value: Double, tint: Color, trackTint: Color) -> some View {
        TerminalProgressBar(
            value: value,
            cells: Self.cells,
            showsValue: false,
            tint: tint,
            font: Typography.termXs,
            trackTint: trackTint)
            // The bar carries its own `ProgressView` representation; inside a button that
            // already declares a label, a value and a hint, a second element with its own role
            // would be read out twice and neither reading would be the control.
            .accessibilityHidden(true)
    }

    /// The groove. `Colors.textTertiary`, not the primitive's default `Colors.borderStrong`:
    /// that one is BYTE-IDENTICAL to `surfaceElevated` — the unselected chip's own fill — in
    /// `umberDark` and `lilacDark`, and ΔE 1.1 from it in `forestDark`, so the track vanished
    /// in three themes. `textTertiary` measures ΔE ≥ 13.9 from every ground a chip can have
    /// and ≥ 15.4 from every ink below, on both grounds.
    private var trackTint: Color { Colors.textTertiary }

    /// The lit run.
    ///
    /// Off an accent fill the tier is a hue: `accent` → `gold` → `error`. `error` separates from
    /// both others in every palette (ΔE ≥ 25.9) — it is the one colour this Monochrome+1 system
    /// reserves besides the accent. `gold` separates only in the THEMED palettes: in the base
    /// three (`terminalDark`, `oledDark`, `lightPaper`) every warm token is the accent, so
    /// `comfortable` and `approaching` share a colour there and the length separates them.
    ///
    /// `Colors.warning` — the semantically obvious pick, and what this drew until 2026-09-08 — is
    /// the accent in 34 of the 46 theme-and-scheme combinations against `gold`'s 15, a strict
    /// subset. That is why the old bar showed one colour where it promised two.
    ///
    /// ON an accent fill there is no hue left: see `isOnAccent`. The proportion is carried by
    /// the length, and the exact figure by the tooltip.
    private func fillTint(for tier: ContextFillPresentation.Tier, isCompacting: Bool) -> Color {
        // A uniform quiet grey — near the track on an unselected chip by design: while the
        // conversation is being rewritten there is no proportion to report.
        if isCompacting { return Colors.textSecondary }
        switch tier {
        // No budget, no proportion — the track is drawn and nothing is lit, which is a
        // different statement from "the context is empty".
        case .unknown: return .clear
        case .comfortable: return isOnAccent ? Colors.textOnAccent : Colors.accent
        case .approaching: return isOnAccent ? Colors.textOnAccent : Colors.gold
        case .atBudget: return isOnAccent ? Colors.textOnAccent : Colors.error
        }
    }
}

#Preview("Context fill") {
    // The states the chip inlay can be in, on BOTH grounds it has to survive, at the size and
    // cell count it actually renders. Not the indicator itself: that reads two `@Observable`
    // objects out of the environment, and a preview standing one up would exercise the wiring
    // rather than the drawing.
    let cells = 4
    let steps: [(String, Double, Color)] = [
        ("  ?", 0, .clear),
        ("  0", 0, Colors.accent),
        ("  3", 0.03, Colors.accent),
        (" 28", 0.28, Colors.accent),
        (" 42", 0.42, Colors.accent),
        (" 62", 0.62, Colors.gold),
        (" 95", 0.95, Colors.error),
        ("100", 1.0, Colors.error),
    ]
    return HStack(alignment: .top, spacing: Spacing.l) {
        ForEach([false, true], id: \.self) { onAccent in
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(onAccent ? "selected" : "unselected")
                    .font(Typography.termXs)
                    .foregroundStyle(onAccent ? Colors.textOnAccent : Colors.textTertiary)
                ForEach(steps, id: \.0) { label, fraction, tint in
                    HStack(spacing: Spacing.s) {
                        Text(label)
                            .font(Typography.termXs)
                            .monospacedDigit()
                            .foregroundStyle(onAccent ? Colors.textOnAccent : Colors.textTertiary)
                        TerminalProgressBar(
                            value: fraction, cells: cells, showsValue: false,
                            tint: onAccent && tint != .clear ? Colors.textOnAccent : tint,
                            font: Typography.termXs,
                            trackTint: Colors.textTertiary)
                    }
                }
            }
            .padding()
            .background(onAccent ? Colors.accent : Colors.surfaceElevated)
            .clipShape(RoundedRectangle.squircle(CornerRadius.small))
        }
    }
    .padding()
    .background(Colors.surfaceCard)
}
