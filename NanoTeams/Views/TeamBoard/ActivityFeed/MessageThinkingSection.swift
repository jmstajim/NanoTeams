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
                // `isVisible:` rather than `if isStreaming` — the hidden branch
                // is the same `MonoCell`, so the label keeps its column when the
                // row settles from `Thinking…` to `Thinking`. Inserting the
                // loader conditionally slid the label sideways by the cell's
                // advance plus `Spacing.xs` (≈10.8pt at 11pt) on every commit.
                NTMSLoader(font: Typography.termXs, isVisible: isStreaming, color: Colors.accent)
                Text(isStreaming ? "Thinking…" : "Thinking")
                    .font(Typography.termXs.weight(.medium))
                    .foregroundStyle(Colors.textTertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
