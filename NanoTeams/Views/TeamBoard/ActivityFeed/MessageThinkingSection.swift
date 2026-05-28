import SwiftUI

/// Compact "Thinking" row inside a message bubble.
/// Tapping opens the full untruncated text in a standalone window
/// (`ActivityDetailWindow.thinking`). The streaming loader and label stay
/// inline; there is no inline expansion anymore.
struct MessageThinkingSection: View {
    let thinking: String
    let messageID: UUID
    let roleName: String
    let isStreaming: Bool

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(value: ActivityDetailWindow.thinking(
                id: messageID,
                roleName: roleName,
                text: thinking
            ))
        } label: {
            HStack(spacing: Spacing.xs) {
                if isStreaming {
                    NTMSLoader(.mini)
                        .frame(width: 14, height: 12)
                }
                Text(isStreaming ? "Thinking..." : "Thinking")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
