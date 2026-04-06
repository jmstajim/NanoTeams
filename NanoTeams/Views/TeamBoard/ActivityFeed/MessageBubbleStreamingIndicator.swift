import SwiftUI

/// Loader + italic caption shown for Thinking / Waiting / Processing states.
/// Reserves loader space so text doesn't shift when the loader hides.
struct MessageLoaderLabel: View {
    let text: String
    let showLoader: Bool

    init(_ text: String, showLoader: Bool) {
        self.text = text
        self.showLoader = showLoader
    }

    var body: some View {
        HStack(spacing: 0) {
            NTMSLoader(.mini)
                .frame(width: 18, height: 12)
                .opacity(showLoader ? 1 : 0)
            Text(text)
                .font(.caption.weight(.medium).monospaced())
                .italic()
                .foregroundStyle(.secondary)
        }
    }
}

/// Streaming status row for a message bubble — "Waiting" or "Processing 42%".
/// Returns nil (empty view) when no status should be displayed.
struct MessageBubbleStreamingIndicator: View {
    let isStreaming: Bool
    let hasMessageContent: Bool
    let hasThinkingContent: Bool
    let processingProgress: Double?

    var body: some View {
        if let text = statusText {
            HStack(spacing: 0) {
                MessageLoaderLabel(text, showLoader: true)
                if let progress = processingProgress {
                    Text(" \(Int(progress * 100))%")
                        .font(.caption.weight(.medium).monospaced())
                        .italic()
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.trailing, ActivityCardTokens.cardPadding)
        }
    }

    /// Returns the status text for streaming states, or nil when not streaming / no status needed.
    private var statusText: String? {
        guard isStreaming else { return nil }
        if hasMessageContent { return nil } // content is visible — no status row needed
        if hasThinkingContent { return nil } // thinking section is visible — no status row needed
        if processingProgress != nil {
            return "Processing"
        }
        return "Waiting"
    }
}
