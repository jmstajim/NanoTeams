import SwiftUI

/// Compact "Thinking" — or, during a context-compaction epoch, "Compacting" — row inside a
/// message bubble. Tapping opens the full untruncated text in a standalone window
/// (`ActivityDetailWindow.thinking` / `.compaction`). The streaming loader and label stay
/// inline; there is no inline expansion anymore.
struct MessageThinkingSection: View {
    let thinking: String
    let messageID: UUID
    let roleName: String
    let isStreaming: Bool
    /// The bubble belongs to a context-compaction epoch: what is under this row is the model
    /// reading its OWN transcript to summarise it — reasoning AND the summary itself, because
    /// the epoch prints no prose and this row is its only visible output. Naming that
    /// "Thinking" would misname both the text and the window it opens.
    var isCompacting: Bool = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(value: Self.detailWindow(
                isCompacting: isCompacting,
                messageID: messageID,
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
                Text(Self.label(isStreaming: isStreaming, isCompacting: isCompacting))
                    .font(Typography.termXs.weight(.medium))
                    .foregroundStyle(Colors.textTertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Pure so the wording is testable without standing up a view.
    static func label(isStreaming: Bool, isCompacting: Bool) -> String {
        if isCompacting { return isStreaming ? "Compacting…" : "Compacting" }
        return isStreaming ? "Thinking…" : "Thinking"
    }

    /// The window this row opens. Pure, and beside `label` for the same reason: the row and
    /// the window it opens must name the same thing, and the pair is testable without
    /// standing up a view or a `WindowGroup`.
    static func detailWindow(
        isCompacting: Bool, messageID: UUID, roleName: String, text: String
    ) -> ActivityDetailWindow {
        isCompacting
            ? .compaction(id: messageID, roleName: roleName, text: text)
            : .thinking(id: messageID, roleName: roleName, text: text)
    }
}
