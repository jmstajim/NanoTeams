import SwiftUI

// MARK: - Composer Icon Button Style

/// The icon cell for the composer action bar — `+`, `/`, gear, improve, revert,
/// dictate and send. Owns the three things that must not be re-decided per site:
/// the cell size (`MessageComposerLayout.actionButtonSize`), the **hit area**, and
/// the pressed feedback.
///
/// The hit area is the reason this type exists. Every one of those seven buttons
/// declared the same `28×24` frame and `.buttonStyle(.plain)`, but six put a bare
/// `Image`/`Text` inside it, and SwiftUI hit-tests a frame's *drawn child*, not the
/// frame: the live target was the ~13pt glyph box, roughly a quarter of the cell.
/// The send button felt right only by accident — its label is a `ZStack` over a
/// `RoundedRectangle…fill(…)` that spans the frame, and a filled shape (`.clear`
/// included) takes hits across its whole rect. So the row read as one set of
/// identical icons while one of them was three times easier to click.
/// `.contentShape` below is what makes that accident the rule.
///
/// 1:1 with `DesignSystem/components/core/IconButton.jsx`:
/// `.nt-iconbtn { background: transparent; border-radius: var(--nt-radius-sm); }`
/// `.nt-iconbtn:hover { background: var(--nt-hover); }`
///
/// **Three deliberate divergences from `NavbarIconButtonStyle`**, which is otherwise
/// this type's model. Each is a case where the navbar's rationale is true of the
/// navbar and false of this member (CLAUDE.md #119):
///
///  1. **It does not own `foregroundStyle`.** Three sites carry a live tint —
///     `ImprovePromptButton`'s main button and `DictationMicButton` swing
///     accent/error/tertiary off their own state, and `MessageSendButton` swings
///     `textOnAccent`/`textTertiary` off `canSubmit`; the remaining four set a fixed
///     colour. `NavbarIconCellChrome` owns the colour because that cluster is
///     monochrome by design; here it would flatten state the user reads.
///  2. **No hairline border at rest.** The navbar's is justified by the
///     `[ bracket ]` buttons and bordered badges in the same row. The composer bar
///     has neither, six boxes under a text field visibly weigh the resting state
///     down, and they would double-draw against `MessageSendButton`'s own disabled
///     border.
///  3. **No disabled opacity.** Every disabled-capable site encodes disabled in its
///     own tint, so a style-level `0.4` double-dims them — and send is disabled
///     whenever the field is empty, i.e. the composer's most common resting state.
///     This rationale has to hold per MEMBER, and it did not until 2026-08-25:
///     `DictationMicButton`'s tint read only its own `isAvailable`, while
///     `MessageComposer` disables it from the OUTSIDE for the length of a prompt
///     improvement — so the mic sat inert in full accent. Its tint now reads
///     `\.isEnabled`. A shared rationale is a per-member obligation (CLAUDE.md #119);
///     re-check it before adding an eighth button.
///
/// The font is applied OUTSIDE `configuration.label`, so it is a default any site
/// overrides with one inner `.font` — innermost application wins. Six of the seven
/// sites already spelled `Typography.termBase.weight(.medium)`; the gear alone spelled
/// plain `termBase` with nothing recording why, so adopting the style deliberately
/// normalises it to medium. It stays the row's only permanently-`textTertiary` glyph,
/// which is where its subordinate reading actually lives.
///
/// Pinned by `Ratchet/IconButtonHitAreaPinTests`. Note what is deliberately NOT
/// pinned: the hover fill. It is an affordance, not an invariant, and a test
/// asserting `Colors.surfaceHover` appears here would be a pin on a proxy
/// (CLAUDE.md #115).
struct ComposerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let cell = MessageComposerLayout.actionButtonSize
            configuration.label
                .font(Typography.termBase.weight(.medium))
                .frame(width: cell.width, height: cell.height)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(isHovered && isEnabled ? Colors.surfaceHover : .clear)
                )
                // The fix: without this the transparent remainder of the cell is dead
                // and only the glyph is clickable. Must stay AFTER `.frame` — the
                // other spelling compiles, reads fine, and restores the defect.
                .contentShape(RoundedRectangle.squircle(CornerRadius.small))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animationWithReduceMotion(Animations.quick, value: isHovered)
                // Hover is gated on `isEnabled` explicitly rather than trusting
                // `.disabled` to block it: three of these buttons are routinely
                // disabled (improve with an empty field, dictate below macOS 26,
                // send with nothing to send), and "should not fire" is worth less
                // than a condition you can read.
                .trackHover($isHovered)
        }
    }
}

extension ButtonStyle where Self == ComposerIconButtonStyle {
    static var composerIcon: ComposerIconButtonStyle { ComposerIconButtonStyle() }
}

#Preview("Composer Icon Cells") {
    VStack(alignment: .leading, spacing: Spacing.m) {
        HStack {
            Button {} label: { Image(systemName: "plus").foregroundStyle(Colors.accent) }
            Button {} label: { Text("/").foregroundStyle(Colors.accent) }
            Button {} label: { Image(systemName: "gearshape").foregroundStyle(Colors.textTertiary) }
            Button {} label: { Image(systemName: "sparkles").foregroundStyle(Colors.accent) }
            Button {} label: { Image(systemName: "mic").foregroundStyle(Colors.accent) }
        }
        .buttonStyle(.composerIcon)

        HStack {
            Button {} label: { Image(systemName: "sparkles").foregroundStyle(Colors.textTertiary) }
            Button {} label: { Image(systemName: "mic").foregroundStyle(Colors.textTertiary) }
        }
        .buttonStyle(.composerIcon)
        .disabled(true)
    }
    .padding()
    .background(Colors.surfaceCard)
}
