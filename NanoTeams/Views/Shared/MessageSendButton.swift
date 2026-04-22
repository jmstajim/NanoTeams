import SwiftUI

/// Circular accent send button with loading spinner and disabled state.
/// Used inside `MessageComposer` on every answer/message surface.
struct MessageSendButton: View {
    let canSubmit: Bool
    let isSubmitting: Bool
    let onSubmit: () -> Void

    var body: some View {
        Button(action: onSubmit) {
            if isSubmitting {
                NTMSLoader(.small)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSubmit ? Colors.accent : Colors.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || isSubmitting)
        .accessibilityLabel("Send")
    }
}
