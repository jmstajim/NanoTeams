import SwiftUI

/// Squircle accent send button with loading spinner and disabled state.
/// Used inside `MessageComposer` on every answer/message surface.
///
/// DS chrome — flat `arrow.up` glyph inside the shared composer cell so the send
/// affordance matches every other terminal icon button (Pass 30: no SF Symbol
/// `.circle` shapes — those render true circles). Accent fill when armed,
/// transparent over a hairline border when disabled.
///
/// The cell comes from `ComposerIconButtonStyle`, not from a local frame: the
/// spanning fill below is what made this the only button in the bar whose whole
/// rect was clickable, and the style is how the other six got the same. The
/// `ZStack` is proposed the style's frame, so the flexible shape takes it exactly.
struct MessageSendButton: View {
    let canSubmit: Bool
    let isSubmitting: Bool
    let onSubmit: () -> Void

    var body: some View {
        Button(action: onSubmit) {
            ZStack {
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(canSubmit ? Colors.accent : .clear)
                    .overlay(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .strokeBorder(canSubmit ? .clear : Colors.borderSubtle, lineWidth: 1)
                    )

                if isSubmitting {
                    // `.mini` (24×12), not `.small` (36×18): a ZStack sizes to the
                    // union of its children, so the larger preset widened the button
                    // from 28 to 36pt the instant you pressed send and jogged the
                    // whole action bar sideways.
                    NTMSLoader(.mini)
                } else {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(canSubmit ? Colors.textOnAccent : Colors.textTertiary)
                }
            }
        }
        .buttonStyle(.composerIcon)
        .disabled(!canSubmit || isSubmitting)
        .accessibilityLabel("Send")
    }
}
