import SwiftUI

/// Squircle accent send button with loading spinner and disabled state.
/// Used inside `MessageComposer` on every answer/message surface.
///
/// DS chrome — flat `arrow.up` glyph inside a 28×24pt squircle so the send
/// affordance matches every other terminal icon button (Pass 30: no SF Symbol
/// `.circle` shapes — those render true circles). Accent fill when armed,
/// transparent over a hairline border when disabled.
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
                    .frame(width: 28, height: 24)

                if isSubmitting {
                    NTMSLoader(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(Typography.termBase.weight(.medium))
                        .foregroundStyle(canSubmit ? Colors.textOnAccent : Colors.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || isSubmitting)
        .accessibilityLabel("Send")
    }
}
