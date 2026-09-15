import SwiftUI

// MARK: - LiveMessageBubble

/// One LLM-message row of the activity feed: resolves the bubble's inputs from a live streaming
/// snapshot and renders `MessageBubbleView` in ONE unconditional structural slot.
///
/// **Why it polls.** `StreamingPreviewManager` keeps per-token content `@ObservationIgnored` —
/// an observed write per chunk would re-evaluate the feed per chunk — so a streaming bubble has
/// to look for itself. It does, from a `.task` loop that runs ONLY while its message streams and
/// writes view state only when the snapshot actually moved.
///
/// **Why not `TimelineView`.** Until 2026-09-15 every bubble, committed ones included, sat inside
/// `TimelineView(BubbleSchedule)`. A committed schedule emits one entry, but the view is still a
/// timeline: on a trace of an idle run (no tokens arriving) `ViewGraph.beginNextUpdate(at:)` —
/// the graph advancing its clock at the start of every transaction — accounted for 775 ms of
/// dirty-propagation in 10 s, with a non-lazy feed of timelines under it. A committed bubble now
/// has no clock to follow; what the change bought is recorded in the engineering-lessons entry
/// of that date.
///
/// **Structural identity.** `MessageBubbleView` is constructed exactly once, outside any `if` /
/// `switch`, so the streaming → committed flip changes inputs and the poll's task id, never the
/// view's shape — `SelectableMessageText`'s `NSTextView` is not remounted and keeps its
/// append-only layout. Pinned by `TeamActivityFeedContainerInvariantTests`.
struct LiveMessageBubble: View {
    let message: LLMMessage
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let stepID: String
    let originTaskID: Int
    let isImplicitStreamTarget: Bool
    let showHeader: Bool
    let onAvatarTap: (() -> Void)?
    let roleLabelOverride: String?
    let roleTeamSuffix: String?
    let workFolderURL: URL?
    /// Seconds between looks at the preview; nil when nothing may change under this bubble
    /// (committed message) or nothing should churn (live resize). See `pollInterval`.
    let pollInterval: TimeInterval?

    @Environment(StreamingPreviewManager.self) private var streamingManager

    /// The last snapshot the poll saw. The body renders from a FRESH read, never from this —
    /// the state exists so that a moved snapshot re-evaluates the body.
    @State private var polledSnapshot: TeamActivityFeedView.StreamingSnapshot?

    /// When a bubble polls, and how often. `nil` = no poll.
    ///
    /// | isStreaming | isResizing | reduceMotion | interval |
    /// |-------------|------------|--------------|----------|
    /// | false       | any        | any          | nil — nothing streams into a committed row |
    /// | true        | true       | any          | nil — no streaming churn on top of the per-width re-measure while dragging |
    /// | true        | false      | true         | 1.0 — visible progress without churn |
    /// | true        | false      | false        | 0.3 — fast enough that token deltas feel live |
    ///
    /// Pinned by `LiveMessageBubblePollIntervalTests`.
    nonisolated static func pollInterval(isStreaming: Bool, isResizing: Bool, reduceMotion: Bool) -> TimeInterval? {
        guard isStreaming, !isResizing else { return nil }
        return reduceMotion ? 1.0 : 0.3
    }

    var body: some View {
        // Reading the state registers the dependency the poll's writes rely on.
        let _ = polledSnapshot
        let inputs = TeamActivityFeedView.resolveBubbleInputs(msg: message, streaming: liveSnapshot)
        // `.equatable()` unconditionally: for a committed bubble `==` is true and SwiftUI skips the
        // whole subtree; gating it on `inputs.isStreaming` would need a conditional branch, which
        // is exactly the remount the single slot exists to avoid.
        MessageBubbleView(
            message: message, role: role,
            roleDefinition: roleDefinition,
            content: inputs.contentForBubble,
            thinking: inputs.thinkingForBubble,
            processingStatus: inputs.processingStatus,
            hasStreamActivity: inputs.hasStreamActivity,
            isStreamingToolCall: inputs.isStreamingToolCall,
            isCompacting: inputs.isCompacting,
            isStreaming: inputs.isStreaming,
            isImplicitStreamTarget: isImplicitStreamTarget,
            showHeader: showHeader,
            onAvatarTap: onAvatarTap,
            roleLabelOverride: roleLabelOverride,
            roleTeamSuffix: roleTeamSuffix,
            attachmentPaths: inputs.attachmentPaths,
            clippedTexts: inputs.clippedTexts,
            workFolderURL: workFolderURL
        )
        .equatable()
        // A new id — the stream starting or ending, a resize beginning or ending — cancels the old
        // loop and starts the new one; a `nil` id runs once and returns.
        .task(id: pollInterval) {
            await poll(every: pollInterval)
        }
    }

    private var liveSnapshot: TeamActivityFeedView.StreamingSnapshot {
        TeamActivityFeedView.makeStreamingSnapshot(
            manager: streamingManager,
            messageID: message.id,
            stepID: stepID,
            taskID: originTaskID
        )
    }

    private func poll(every interval: TimeInterval?) async {
        guard let interval else { return }
        while !Task.isCancelled {
            let fresh = liveSnapshot
            if fresh != polledSnapshot {
                polledSnapshot = fresh
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}
