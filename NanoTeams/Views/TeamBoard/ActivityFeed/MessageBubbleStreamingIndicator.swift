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
    let processingStatus: PromptProcessingStatus?
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
        } else if Self.reservesStatusSlot(
            isStreaming: isStreaming,
            hasMessageContent: hasMessageContent,
            hasThinkingContent: hasThinkingContent,
            isStreamingToolCall: isStreamingToolCall
        ) {
            // Height keeper — see `reservesStatusSlot`. The SAME `MonoCell` the
            // real row's loader uses, so the reserved row is exactly the height
            // the caption will occupy when it returns. Not a hidden
            // `MessageLoaderLabel`: that would spin an 80ms ticker for a row
            // nobody can see. `else if` (rather than a `ZStack` of conditions)
            // is what makes the negative case a true `EmptyView`, which the
            // enclosing `VStack` elides along with its `Spacing.xs` gap.
            MonoCell(font: Typography.termXs)
                .accessibilityHidden(true)
        }
    }

    /// Returns the status text for streaming states, or nil when not streaming / no status needed.
    private var statusText: String? {
        Self.resolveStatusText(
            isStreaming: isStreaming,
            isImplicitStreamTarget: isImplicitStreamTarget,
            hasMessageContent: hasMessageContent,
            hasThinkingContent: hasThinkingContent,
            processingStatus: processingStatus,
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
    /// `"Processing 42%"` (ticking %), `"Processing…"`, `"Generating…"` /
    /// `"Waiting…"` (trailing `…` carries the "in progress" signal — same
    /// convention as `MessageThinkingSection`'s `Thinking…` / `Thinking`
    /// toggle). The verbs `Generating`/`Waiting` only exist in the
    /// streaming-live branch — there is no settled form to render, so `…` is
    /// unambiguous. `Processing` takes the `…` in its indeterminate form for
    /// the same reason and drops it when a percentage is present, because
    /// there the ticking number already carries the motion.
    static func resolveStatusText(
        isStreaming: Bool,
        isImplicitStreamTarget: Bool,
        hasMessageContent: Bool,
        hasThinkingContent: Bool,
        processingStatus: PromptProcessingStatus?,
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
            if let status = processingStatus {
                return Self.processingText(for: status)
            }
            if hasStreamActivity {
                // Tokens are flowing but not landing in content/thinking buffers
                // — the model is emitting a tool call, harmony envelope, or
                // similar. Show that work is happening so the user doesn't
                // assume the system is hung.
                return "Generating…"
            }
            // Nothing is in flight: the pre-send instant, or the sleep between a
            // failed attempt and its retry (the streaming service clears the
            // status when the stream throws, precisely so this window reads as
            // waiting rather than as a frozen "Processing").
            return "Waiting…"
        }
        if isImplicitStreamTarget {
            if let status = processingStatus {
                return Self.processingText(for: status)
            }
            if hasStreamActivity {
                return "Generating…"
            }
            return nil
        }
        return nil
    }

    /// Whether this view renders a row at all — the union of `body`'s two
    /// branches, derived from the same two functions the body switches on so
    /// the two cannot drift.
    ///
    /// Exposed because the row's TOP SPACING is a property of the bubble's
    /// structure, not of this view: the status row and `MessageThinkingSection`
    /// swap places in the same slot as a turn progresses, so the spacing rule
    /// has to live in one place that can see both (`MessageBubbleView`). It
    /// cannot simply pad this view from outside unconditionally — this
    /// indicator is instantiated on every bubble and renders nothing most of
    /// the time, and padding wrapped around that `EmptyView` would leave a
    /// permanent strip under every quiet message in the feed.
    static func rendersRow(
        isStreaming: Bool,
        isImplicitStreamTarget: Bool,
        hasMessageContent: Bool,
        hasThinkingContent: Bool,
        processingStatus: PromptProcessingStatus?,
        hasStreamActivity: Bool,
        isStreamingToolCall: Bool
    ) -> Bool {
        let hasStatus = resolveStatusText(
            isStreaming: isStreaming,
            isImplicitStreamTarget: isImplicitStreamTarget,
            hasMessageContent: hasMessageContent,
            hasThinkingContent: hasThinkingContent,
            processingStatus: processingStatus,
            hasStreamActivity: hasStreamActivity,
            isStreamingToolCall: isStreamingToolCall
        ) != nil
        return hasStatus || reservesStatusSlot(
            isStreaming: isStreaming,
            hasMessageContent: hasMessageContent,
            hasThinkingContent: hasThinkingContent,
            isStreamingToolCall: isStreamingToolCall
        )
    }

    /// Whether an INVISIBLE one-line slot must be held open where the status
    /// row would go.
    ///
    /// Once prose exists, the bubble's tail region churns: the status row
    /// vanishes the instant content lands (the `hasMessageContent` suppression
    /// in `resolveStatusText`), and the trailing `Thinking…` row appears when a
    /// tool-call envelope starts streaming into the thinking preview. Each of
    /// those is a whole row (11pt line + `Spacing.xs` ≈ 17pt) appearing or
    /// vanishing under a feed pinned to the bottom. Holding ONE row open for
    /// the live window turns them into pure swaps: the slot opens once when
    /// prose first lands and closes once at commit, both times alongside a
    /// larger legitimate change.
    ///
    /// Three gates, each stopping the reservation from reading as dead space:
    ///
    /// - `isStreaming` — deliberately NOT `isStreaming || isImplicitStreamTarget`.
    ///   That branch of `resolveStatusText` is unreachable in production:
    ///   `resolveBubbleInputs` returns `.committed` for any non-streaming
    ///   bubble, and `.committed` hard-returns nil/false for the three fields
    ///   the branch reads. Its silent window is not an instant but the WHOLE
    ///   tool execution, so reserving there would park a blank row between a
    ///   turn's `Thinking` row and the tool-call card it produced — undoing the
    ///   turn grouping in `TeamActivityFeedView.rowTopPadding`.
    /// - `hasMessageContent` — gates the reservation ON content, the opposite
    ///   of how `resolveStatusText` reads the same flag. Before prose, the
    ///   status row and the top `Thinking…` row occupy the SAME slot (the
    ///   bubble's only child under the header) and already swap in place at
    ///   constant height; reserving there would add a blank row under a live
    ///   `Thinking…`.
    /// - `!showsTrailingThinkingRow` — that row IS this slot's occupant.
    ///   Derived from this view's own stored properties rather than threaded in
    ///   as a flag, so `==` (and therefore `.equatable()`) needs no new member
    ///   and cannot drift from the row it mirrors.
    static func reservesStatusSlot(
        isStreaming: Bool,
        hasMessageContent: Bool,
        hasThinkingContent: Bool,
        isStreamingToolCall: Bool
    ) -> Bool {
        isStreaming
            && hasMessageContent
            && !MessageBubbleView.showsTrailingThinkingRow(
                isStreaming: isStreaming,
                hasMessageContent: hasMessageContent,
                isStreamingToolCall: isStreamingToolCall,
                hasThinkingContent: hasThinkingContent
            )
    }

    /// Renders the prompt-processing window at the precision the provider
    /// actually supplied. A server-reported fraction becomes a percentage; the
    /// app's own "a request is in flight" claim stays a verb, because the only
    /// number available to synthesize one would be an estimate whose measured
    /// error runs 2–6× (see `PromptProcessingStatus` for the two estimators and
    /// their calibration).
    private static func processingText(for status: PromptProcessingStatus) -> String {
        switch status {
        case .fraction(let progress): return "Processing \(Int(progress * 100))%"
        case .indeterminate: return "Processing…"
        }
    }
}
