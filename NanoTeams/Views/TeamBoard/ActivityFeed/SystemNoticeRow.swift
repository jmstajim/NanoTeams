import SwiftUI

/// Collapsed one-line form of a system-authored notice inside a message bubble
/// — a retry nudge, a loop-break correction, or a server-error retry note.
/// Tapping opens the full untruncated text in a standalone window; there is no
/// inline expansion, matching `MessageThinkingSection` and every other feed
/// disclosure.
///
/// Shape borrows the terminal command line of `ToolCallItemView`'s card: a dim
/// sigil, a label, then a truncating one-line summary. `#` is the comment sigil
/// to that view's `$` — these rows are the app talking to the model, not work
/// being done.
struct SystemNoticeRow: View {
    let notice: SystemNoticePresentation.Notice
    /// `LLMMessage.id` — the window's dedup key, so repeated taps focus one
    /// window and a server-error note rewritten in place reuses it.
    let messageID: UUID
    /// Untruncated content for the window payload.
    let fullText: String

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(value: ActivityDetailWindow.systemNotice(
                id: messageID,
                label: notice.windowTitle,
                text: fullText
            ))
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("#")
                    .font(Typography.termXs)
                    .foregroundStyle(Colors.textQuaternary)
                Text(notice.rowLabel)
                    .font(Typography.termXs.weight(.medium))
                    .foregroundStyle(notice.isError ? Colors.error : Colors.textTertiary)
                    .lineLimit(1)
                if !notice.preview.isEmpty {
                    Text(notice.preview)
                        .font(Typography.termXs)
                        .foregroundStyle(Colors.textQuaternary)
                        .lineLimit(1)
                        // Tail, not middle: the opening of a nudge carries the
                        // reason. `.middle` is the idiom for paths, where the
                        // filename at the end is what identifies the target.
                        .truncationMode(.tail)
                }
                Spacer(minLength: Spacing.xs)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview("System notices") {
    VStack(alignment: .leading, spacing: 12) {
        systemNoticeRowPreviewLabel("retry — long nudge, preview truncates")
        SystemNoticeRow(
            notice: SystemNoticePresentation.resolve(
                context: .retryNudge,
                content: "Your previous tool call had malformed JSON and could not be parsed "
                    + "(parser error: No string key for value in object around line 1, column 1.). "
                    + "Retry with valid JSON."
            )!,
            messageID: UUID(),
            fullText: "…"
        )

        systemNoticeRowPreviewLabel("retry — short nudge, preview fits")
        SystemNoticeRow(
            notice: SystemNoticePresentation.resolve(
                context: .retryNudge,
                content: "You replied with text but did not call a tool."
            )!,
            messageID: UUID(),
            fullText: "…"
        )

        systemNoticeRowPreviewLabel("loop correction")
        SystemNoticeRow(
            notice: SystemNoticePresentation.resolve(
                context: .loopCorrection,
                content: "Your previous response repeated the same block and was discarded."
            )!,
            messageID: UUID(),
            fullText: "…"
        )

        systemNoticeRowPreviewLabel("server error — red label")
        SystemNoticeRow(
            notice: SystemNoticePresentation.resolve(
                context: .serverError,
                content: "LLM server error (attempt 2/3): The request timed out. Retrying in 10s…"
            )!,
            messageID: UUID(),
            fullText: "…"
        )

        systemNoticeRowPreviewLabel("empty body — label only")
        SystemNoticeRow(
            notice: SystemNoticePresentation.resolve(context: .serverError, content: "")!,
            messageID: UUID(),
            fullText: ""
        )
    }
    .padding()
    .frame(width: 520)
    .background(Colors.surfacePrimary)
}

// periphery:ignore - used in #Preview macros
@ViewBuilder
private func systemNoticeRowPreviewLabel(_ text: String) -> some View {
    Text(text)
        .font(Typography.caption2.weight(.bold))
        .foregroundStyle(Colors.textTertiary)
}
