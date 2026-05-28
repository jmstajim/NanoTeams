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
            // `isVisible: showLoader` short-circuits the TimelineView when
            // logically hidden. Pre-fix this used `.opacity(0)`, which left
            // the loader rotating at 30 Hz behind invisibility — wasted
            // main-thread cycles during streaming and a contributor to the
            // 4.41 s inLiveResize hang.
            NTMSLoader(.mini, isVisible: showLoader)
                .frame(width: 18, height: 12)
            Text(text)
                .font(.caption.weight(.medium).monospaced())
                .italic()
                .foregroundStyle(.secondary)
        }
    }
}

/// Streaming status row for a message bubble — "Waiting", "Processing X%",
/// or "Generating". Returns nil (empty view) when no status should be
/// displayed.
///
/// `Equatable` is synthesized so the call site in `MessageBubbleView` can
/// wrap us with `.equatable()` — SwiftUI then skips re-evaluating this
/// subtree (and the embedded `NTMSLoader`'s view-value rebuild) when none
/// of the five inputs changed across a streaming tick. The internal
/// `TimelineView` inside `NTMSLoader` still ticks on its own schedule,
/// decoupled from outer body re-eval — that's the point.
///
/// Drift-guard: `MessageBubbleStreamingIndicatorEquatableTests` pins each
/// stored prop's contribution. Adding a new prop without extending the
/// suite means `.equatable()` would silently drop updates to it.
struct MessageBubbleStreamingIndicator: View, Equatable {
    let isStreaming: Bool
    /// Surfaces "Processing"/"Generating" — never "Waiting" — on a committed
    /// bubble. "Waiting" on a committed bubble would imply hang.
    var isImplicitStreamTarget: Bool = false
    let hasMessageContent: Bool
    let hasThinkingContent: Bool
    let processingProgress: Double?
    /// True if the streaming pipeline has received at least one delta of
    /// any kind (thinking, content, tool-call) for this step. Lets the
    /// indicator distinguish "Waiting" (nothing arrived yet) from
    /// "Generating" (tokens flowing into invisible buffers — harmony
    /// tool-call args, OpenAI tool-call deltas, etc.). Default `false`
    /// preserves the prior behavior for surfaces that don't have access
    /// to the streaming preview manager.
    var hasStreamActivity: Bool = false

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
        Self.resolveStatusText(
            isStreaming: isStreaming,
            isImplicitStreamTarget: isImplicitStreamTarget,
            hasMessageContent: hasMessageContent,
            hasThinkingContent: hasThinkingContent,
            processingProgress: processingProgress,
            hasStreamActivity: hasStreamActivity
        )
    }

    /// Pure status-text resolver — extracted from `body` so tests can pin
    /// the priority order (Processing > Generating > Waiting) without
    /// reaching into SwiftUI view internals. Returns nil for "no status
    /// row needed".
    static func resolveStatusText(
        isStreaming: Bool,
        isImplicitStreamTarget: Bool,
        hasMessageContent: Bool,
        hasThinkingContent: Bool,
        processingProgress: Double?,
        hasStreamActivity: Bool
    ) -> String? {
        if isStreaming {
            if hasMessageContent { return nil } // content is visible — no status row needed
            if hasThinkingContent { return nil } // thinking section is visible — no status row needed
            if processingProgress != nil {
                return "Processing"
            }
            if hasStreamActivity {
                // Tokens are flowing but not landing in content/thinking buffers
                // — the model is emitting a tool call, harmony envelope, or
                // similar. Show that work is happening so the user doesn't
                // assume the system is hung.
                return "Generating"
            }
            return "Waiting"
        }
        if isImplicitStreamTarget {
            if processingProgress != nil {
                return "Processing"
            }
            if hasStreamActivity {
                return "Generating"
            }
            return nil
        }
        return nil
    }
}
