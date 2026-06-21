import SwiftUI

/// Loader + caption for the indicator's Waiting / Processing / Generating
/// statuses — the inline DS pattern shared with `MessageThinkingSection`.
///
/// Spinner: `NTMSLoader(font: Typography.termXs, color: Colors.accent)`
/// — matches the caption's line-height (termXs = 11pt) so glyph and text
/// sit on the same baseline. The accent color is the design's "alive"
/// signal; the caption stays muted (`textTertiary`) so the spinner reads
/// as the activity tell.
///
/// Typography: `termXs.medium` + `textTertiary`, identical to
/// `MessageThinkingSection`'s label (both are the same concept — a
/// transient status row under a spinner). Italic is intentionally
/// excluded — in SF Mono italic is a pseudo-slant that breaks the
/// terminal grid; the "process is live" signal lives entirely in the
/// spinner + trailing `…` on verbs (`Waiting…`/`Generating…`); the %
/// counter itself ticks for `Processing 42%`.
struct MessageLoaderLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            NTMSLoader(font: Typography.termXs, color: Colors.accent)
            Text(text)
                .font(Typography.termXs.weight(.medium))
                .foregroundStyle(Colors.textTertiary)
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
/// of the stored inputs changed across a streaming tick. `NTMSLoader`'s
/// internal `.task` ticker still drives rotation + glitch on its own
/// schedule, decoupled from outer body re-eval — that's the point.
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
    /// True once the live stream has committed to tool-call emission —
    /// a Harmony envelope marker was detected (`<|call|>`/`<|start|>`/
    /// `<|channel|>`, so strictly "harmony envelope streaming", which is
    /// almost always a tool call) or OpenAI tool-call deltas arrived.
    /// The envelope text streams into the THINKING preview (the user
    /// watches it being typed under the animated "Thinking…" row), so
    /// normally the `hasThinkingContent` suppression handles this state.
    /// This flag is the FALLBACK: when the thinking preview is still
    /// empty, it overrides the content suppression — prose rendered
    /// before the marker froze the moment the envelope started, so "the
    /// growing text is the indicator" no longer holds and the bubble
    /// would otherwise show zero animation. Default `false` for surfaces
    /// without access to the streaming preview manager.
    var isStreamingToolCall: Bool = false

    var body: some View {
        if let text = statusText {
            HStack(spacing: 0) {
                MessageLoaderLabel(text)
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
            hasStreamActivity: hasStreamActivity,
            isStreamingToolCall: isStreamingToolCall
        )
    }

    /// Pure status-text resolver — extracted from `body` so tests can pin
    /// the priority order (thinking-preview suppression > tool-call
    /// Generating > content suppression > Processing > Generating >
    /// Waiting) without reaching into SwiftUI view internals. Returns
    /// nil for "no status row needed".
    ///
    /// Output strings are ready-to-render (no caller-side suffixing):
    /// `"Processing 42%"` (ticking %), `"Generating…"` / `"Waiting…"`
    /// (trailing `…` carries the "in progress" signal — same convention
    /// as `MessageThinkingSection`'s `Thinking…` / `Thinking` toggle).
    /// The verbs `Generating`/`Waiting` only exist in the streaming-live
    /// branch — there is no settled form to render, so `…` is unambiguous.
    static func resolveStatusText(
        isStreaming: Bool,
        isImplicitStreamTarget: Bool,
        hasMessageContent: Bool,
        hasThinkingContent: Bool,
        processingProgress: Double?,
        hasStreamActivity: Bool,
        isStreamingToolCall: Bool = false
    ) -> String? {
        if isStreaming {
            // Thinking row is the indicator whenever a thinking preview
            // exists — during tool-call assembly the streaming loop pipes
            // the envelope text into it and `MessageBubbleView` keeps its
            // "Thinking…" loader animating (`isThinkingStreaming` includes
            // `isStreamingToolCall`), so no separate status row is needed.
            if hasThinkingContent { return nil }
            if isStreamingToolCall {
                // Fallback: the stream committed to a tool-call envelope but
                // nothing has landed in the thinking preview yet (or a future
                // invisible-buffer path skips the pipe). Without this, frozen
                // prose would suppress every status below and the bubble
                // would show zero animation for the whole argument assembly.
                // Checked before Processing too: tokens ARE flowing, so a
                // stale progress value must not relabel this as prompt
                // processing.
                return "Generating…"
            }
            if hasMessageContent { return nil } // content is visible — no status row needed
            if let progress = processingProgress {
                return "Processing \(Int(progress * 100))%"
            }
            if hasStreamActivity {
                // Tokens are flowing but not landing in content/thinking buffers
                // — the model is emitting a tool call, harmony envelope, or
                // similar. Show that work is happening so the user doesn't
                // assume the system is hung.
                return "Generating…"
            }
            return "Waiting…"
        }
        if isImplicitStreamTarget {
            if let progress = processingProgress {
                return "Processing \(Int(progress * 100))%"
            }
            if hasStreamActivity {
                return "Generating…"
            }
            return nil
        }
        return nil
    }
}
