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
    /// normally that row is the live signal. When the thinking preview is
    /// still empty this flag makes the status row say "Generating…", ahead
    /// of any stale prompt-processing value. A provider that sends a call
    /// whole never raises it (native Ollama); the prose arm of
    /// `resolveStatusText` covers that window. Default `false` for surfaces
    /// without access to the streaming preview manager.
    var isStreamingToolCall: Bool = false

    /// This bubble belongs to a CONTEXT-COMPACTION epoch: the app asked the model to
    /// summarise its own conversation and is about to replace that conversation with the
    /// answer. Outranks every other status EXCEPT the disclosure, which carries the same
    /// wording and the animation once anything has streamed — see `resolveStatusText`.
    var isCompacting: Bool = false

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
            processingStatus: processingStatus,
            hasStreamActivity: hasStreamActivity,
            isStreamingToolCall: isStreamingToolCall,
            isCompacting: isCompacting
        )
    }

    /// Pure status-text resolver — extracted from `body` so tests can pin
    /// the priority order (an animating thinking row > tool call or visible
    /// prose → Generating > Processing > Generating > Waiting) without
    /// reaching into SwiftUI view internals. Returns nil for "no status row
    /// needed".
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
        isStreamingToolCall: Bool = false,
        isCompacting: Bool = false
    ) -> String? {
        // FIRST, above `isStreaming` — an epoch on a parked step has no live stream by that
        // definition and the row still has to say what is happening.
        //
        // The epoch writes NOTHING into the content preview (see
        // `LLMExecutionService.summarizeWithLiveBubble`): both channels go into the
        // disclosure, whose own row reads "Compacting…" and animates while it is the live
        // tail. So this row covers the window BEFORE the first delta, and yields afterwards —
        // returning a status there would stack a second, identical, animated row under the
        // first, which is what shipped in `ef8a1cc0`.
        //
        // The condition is "a disclosure row is ANIMATING", not "a disclosure exists": a
        // static row is not a live signal, and yielding to one would leave the bubble with
        // zero animation — the regression class `testStreamingBubble_alwaysHasLiveSignal`
        // exists to catch. Asked of the view helper that decides it
        // (`MessageBubbleView.thinkingRowAnimates`), so the rule cannot drift from the rows it
        // mirrors. Only the first arm is reachable for an epoch (no prose, no tool call); the
        // rest is what makes the rule total, since nothing at this seam states that.
        if isCompacting {
            let disclosureIsLive = MessageBubbleView.thinkingRowAnimates(
                isStreaming: isStreaming,
                hasMessageContent: hasMessageContent,
                hasThinkingContent: hasThinkingContent,
                isStreamingToolCall: isStreamingToolCall)
            return disclosureIsLive ? nil : "Compacting…"
        }
        if isStreaming {
            // Exactly one animated row while the request is open. An animating thinking row
            // is that row: the top one while reasoning is the live tail, the trailing one
            // while a tool-call envelope is typed into the thinking preview after prose.
            if MessageBubbleView.thinkingRowAnimates(
                isStreaming: isStreaming,
                hasMessageContent: hasMessageContent,
                hasThinkingContent: hasThinkingContent,
                isStreamingToolCall: isStreamingToolCall
            ) { return nil }
            if isStreamingToolCall || hasMessageContent {
                // Otherwise this row is. With a tool call assembling, or with prose on
                // screen, tokens ARE flowing — a stale progress value must not relabel that
                // as prompt processing. Visible prose is NOT a live signal by itself: it
                // grows only while the provider streams it. Native tool calling on Ollama
                // sends `message.tool_calls` whole and nothing while the arguments are
                // generated, and a `hasMessageContent → nil` arm here left the bubble with
                // zero animation for that whole window (MeditationApp task 111, 2026-09-13:
                // 118 s and 204 s).
                return "Generating…"
            }
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

    /// Whether this view renders a row at all — `body`'s one branch, derived
    /// from the same resolver the body switches on so the two cannot drift.
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
        isStreamingToolCall: Bool,
        isCompacting: Bool = false
    ) -> Bool {
        resolveStatusText(
            isStreaming: isStreaming,
            isImplicitStreamTarget: isImplicitStreamTarget,
            hasMessageContent: hasMessageContent,
            hasThinkingContent: hasThinkingContent,
            processingStatus: processingStatus,
            hasStreamActivity: hasStreamActivity,
            isStreamingToolCall: isStreamingToolCall,
            isCompacting: isCompacting
        ) != nil
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
