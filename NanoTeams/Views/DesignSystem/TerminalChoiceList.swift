import SwiftUI

// MARK: - Terminal Choice List

/// A list of options the user picks from — one of them, or several.
///
/// The design system had a switch (`.toggleStyle(.terminal)`) and a menu picker
/// (`TerminalPicker`), and nothing between them: no way to lay several options out at once and
/// let a person read them side by side before choosing. So five surfaces built one each, and
/// three of the five invented their own mark — `checkmark.circle`/`circle`,
/// `checkmark.square`/`square`, `checkmark.circle.fill`/`circle` — none of them the `[x]`/`[ ]`
/// the switch draws two rows away. Nobody notices, because each screen is internally
/// consistent; that is exactly why it needs a component rather than a review comment.
/// `DEBTS.md` D-38 tracks converting the five.
///
/// **Marked is not chosen.** An option may carry a `badge` — "RECOMMENDED" is the reason this
/// exists — and the badge is deliberately NOT the accent colour the selection mark uses. A
/// recommendation the component pre-selected would collect agreement nobody gave, and a
/// recommendation drawn in the selection colour would look pre-selected, which is the same
/// thing one step later.
///
/// Selection is a `Set` in both modes: `.single` replaces its contents, `.multiple` toggles
/// within it. One binding shape means a call site that changes its mind changes one word, and
/// the ORDER of a multiple selection is not represented at all — deliberately, because the
/// only order that means anything is the order the options were written in, which the caller
/// already has.
struct TerminalChoiceList<ID: Hashable>: View {

    /// How many of the options may be chosen.
    ///
    /// `nonisolated` so `toggling` — the one testable part of this component — can be reached
    /// from a test that is not on the main actor. The enclosing `View` is implicitly
    /// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION`), and a nested type inherits that, which
    /// would make even `==` main-actor-isolated.
    nonisolated enum Mode: Equatable {
        case single
        case multiple

        var mark: (checked: String, unchecked: String) {
            switch self {
            case .single: (TerminalGlyph.checkedRadio, TerminalGlyph.uncheckedRadio)
            case .multiple: (TerminalGlyph.checkedBox, TerminalGlyph.uncheckedBox)
            }
        }
    }

    /// One row. `detail` is the reasoning a model or an author attached to the option, shown
    /// under the label; `badge` is the standing mark ("RECOMMENDED"), shown beside it.
    ///
    /// `nonisolated` for the same reason `Mode` is: a call site that BUILDS its rows from data
    /// — a questionnaire's options, say — puts that mapping where a test can reach it, and a
    /// nested type would otherwise inherit the view's implicit `@MainActor` right down to its
    /// memberwise init.
    nonisolated struct Option: Identifiable, Equatable {
        let id: ID
        let label: String
        var detail: String?
        var badge: String?

        init(id: ID, label: String, detail: String? = nil, badge: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
            self.badge = badge
        }
    }

    let options: [Option]
    var mode: Mode = .single
    @Binding var selection: Set<ID>

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(options) { option in
                Row(
                    option: option,
                    mode: mode,
                    isSelected: selection.contains(option.id),
                    onTap: { selection = Self.toggling(option.id, in: selection, mode: mode) }
                )
            }
        }
    }

    // MARK: - The rule, pure

    /// The selection after `id` is tapped.
    ///
    /// `nonisolated static` rather than a method on the view: `Views/` is outside the coverage
    /// denominator and a `let` inside `some View` is unreachable from XCTest, so the one part
    /// of this component that can be WRONG lives where a test can reach it.
    ///
    /// A second tap on the sole single-choice selection CLEARS it. That is not an oversight:
    /// a questionnaire lets the Supervisor submit without deciding, and an answer that cannot
    /// be un-given would turn a mis-click into a decision they never get to take back. The
    /// unanswered state is a real state here, and it is reported as one.
    nonisolated static func toggling(_ id: ID, in selection: Set<ID>, mode: Mode) -> Set<ID> {
        if selection.contains(id) {
            return mode == .single ? [] : selection.subtracting([id])
        }
        return mode == .single ? [id] : selection.union([id])
    }

    // MARK: - Row

    private struct Row: View {
        let option: Option
        let mode: Mode
        let isSelected: Bool
        let onTap: () -> Void

        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                // The column is the MARK's own three cells, measured from the font — not a
                // hand-picked 26pt, which was right for one size of one token and silently
                // wrong for the next. `MonoCell` holds the width open so the column does not
                // shimmer when a mark swaps: `(•)` and `( )` are the same advance in SF Mono,
                // but the bold weight is not applied to whitespace identically at every size.
                MonoCell(font: Typography.choiceMark, reference: mode.mark.unchecked) {
                    Text(isSelected ? mode.mark.checked : mode.mark.unchecked)
                        .font(Typography.choiceMark)
                        .foregroundStyle(isSelected ? Colors.accent : Colors.textTertiary)
                        .contentTransition(.identity)
                }

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    // `.center`, not `.firstTextBaseline`: a trailing tag marks the WHOLE label,
                    // so it centres on the block rather than hanging off the first line of a
                    // label that wrapped. On a one-line label the two spellings differ by 0.33pt
                    // (measured: SF Mono 13 line box 15.311 against the tag's 15.777) — this
                    // alignment is for the wrapped case, which is the common one at composer
                    // width. The MARK column outside stays first-baseline: it points at where
                    // the option STARTS.
                    HStack(alignment: .center, spacing: Spacing.s) {
                        Text(option.label)
                            .font(Typography.termBase)
                            .foregroundStyle(isSelected ? Colors.textPrimary : Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            // The GREEDY half of the row, so the tag lands on the row's trailing
                            // edge and the same column every option's tag lands in. A `Spacer`
                            // between the two would read the same and lay out worse: `Spacer` is
                            // infinitely flexible while a wrapping `Text` is not, so the stack
                            // splits the slack between them and squeezes the label into an early
                            // wrap. Making the label greedy sizes the FIXED child (the tag, which
                            // is `.fixedSize` inside) first and hands the label everything left.
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let badge = option.badge {
                            // The neutral TAG form, which carries no status colour at all. It
                            // said `Colors.info` until 2026-09-11 on the reasoning that info is
                            // "not the accent" — and `info == accent` in 20 of the 24 palettes,
                            // so on almost every theme the recommendation wore the exact colour
                            // of the selection mark two columns left and read as already chosen.
                            TerminalStatusBadge.tag(label: badge)
                        }
                    }
                    if let detail = option.detail, !detail.isEmpty {
                        // 12/secondary, not 10/tertiary: this is the option's REASONING, a
                        // sentence that wraps, and the tag scale it used to wear measured
                        // 3.08:1 against the composer's `surfaceElevated` — below the 4.5:1
                        // WCAG AA floor at any size (`MicroTypeNeverWrapsPinTests`).
                        Text(detail)
                            .font(Typography.termSm)
                            .foregroundStyle(Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Fills the row, which is what puts the tag on its trailing edge. The
                // `Spacer(minLength: 0)` that stood here instead cannot: a spacer beside a
                // greedy stack splits the slack with it, and a spacer INSTEAD of greed leaves
                // the label sized to its ideal width with the tag hung off its end. The row's
                // own `.frame(maxWidth: .infinity)` below is unchanged and still owns the hit
                // area (CLAUDE.md #12).
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(isHovered ? Colors.surfaceHover : Color.clear)
            )
            .opacity(isEnabled ? 1 : 0.5)
            // AFTER the frame, so the row's whole width is the target and not just the text
            // that happens to be in it (CLAUDE.md #12).
            .contentShape(RoundedRectangle.squircle(CornerRadius.small))
            .onTapGesture(perform: onTap)
            .trackHover($isHovered)
            .animationWithReduceMotion(Animations.quick, value: isHovered)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, onTap)
        }
    }
}

#if DEBUG
#Preview("Choice List") {
    @Previewable @State var one: Set<String> = []
    @Previewable @State var many: Set<String> = ["unit"]

    return VStack(alignment: .leading, spacing: Spacing.l) {
        TerminalChoiceList(
            options: [
                .init(id: "debug", label: "Debug", detail: "what CI uses", badge: "recommended"),
                .init(id: "release", label: "Release"),
            ],
            mode: .single,
            selection: $one)

        TerminalChoiceList(
            options: [
                .init(id: "unit", label: "Unit tests", badge: "recommended"),
                .init(id: "ui", label: "UI tests", detail: "slow, and flaky on CI"),
                .init(id: "perf", label: "Performance tests"),
            ],
            mode: .multiple,
            selection: $many)
    }
    .padding(Spacing.l)
    .frame(width: 420)
    .background(Colors.surfaceCard)
}
#endif
