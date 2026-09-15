import SwiftUI

// MARK: - Streaming Bubble Logic (pure, unit-testable)
//
// Extracted from TeamActivityFeedView: the streaming-bubble resolvers and their
// value types (BubbleInputs / StreamingSnapshot). All static + pure — no
// instance state — so the streaming/committed bubble state machine is testable
// without the view. `LiveMessageBubble` is the view that polls them.
//
// The implicit-stream-target law ("the ONE message a `.running` step streams
// into: its latest VISIBLE turn by `createdAt`") no longer lives here — it is
// folded into `ActivityFeedBuilder.emitItems`' message walk and surfaces as
// `TimelineBuild.implicitStreamTargetIDs`. The verbatim expression survives
// only as the oracle in `TeamActivityFeedImplicitStreamTargetTests`.
extension TeamActivityFeedView {

    // MARK: - Bubble inputs (testable resolver)

    /// Per-poll inputs for `MessageBubbleView`. The two cases mirror the
    /// two states the dispatcher resolves:
    /// - `.streaming` carries content/thinking + status/activity/tool-call
    ///   indicators; never carries attachments (those belong to the
    ///   committed turn only).
    /// - `.committed` carries content/thinking + attachments/clips; never
    ///   carries `processingStatus`, `hasStreamActivity`, or
    ///   `isStreamingToolCall`.
    /// The discriminated union prevents illegal cross-mode field leakage
    /// at compile time (no "streaming bubble with attachments", no stale
    /// "Generating" on a committed bubble).
    enum BubbleInputs: Equatable {
        case streaming(
            content: String,
            thinking: String?,
            processingStatus: PromptProcessingStatus?,
            hasStreamActivity: Bool,
            isStreamingToolCall: Bool,
            /// The live bubble belongs to a CONTEXT-COMPACTION epoch, not to the model
            /// taking a turn. Outranks every other status: while the app is discarding the
            /// conversation behind it, "Thinking…" is the one thing the row must not say.
            isCompacting: Bool
        )
        case committed(
            content: String,
            thinking: String?,
            attachmentPaths: [String],
            clippedTexts: [String]
        )

        var isStreaming: Bool {
            if case .streaming = self { return true }
            return false
        }

        // Case-derived accessors so `MessageBubbleView` has one call site.
        // Streaming-only fields return their genuine empty value when the
        // committed case is asked, and vice versa — never a sentinel.
        var contentForBubble: String {
            switch self {
            case .streaming(let c, _, _, _, _, _): return c
            case .committed(let c, _, _, _): return c
            }
        }

        var thinkingForBubble: String? {
            switch self {
            case .streaming(_, let t, _, _, _, _): return t
            case .committed(_, let t, _, _): return t
            }
        }

        var processingStatus: PromptProcessingStatus? {
            switch self {
            case .streaming(_, _, let p, _, _, _): return p
            case .committed: return nil
            }
        }

        var hasStreamActivity: Bool {
            switch self {
            case .streaming(_, _, _, let a, _, _): return a
            case .committed: return false
            }
        }

        var isStreamingToolCall: Bool {
            switch self {
            case .streaming(_, _, _, _, let t, _): return t
            case .committed: return false
            }
        }

        var isCompacting: Bool {
            switch self {
            case .streaming(_, _, _, _, _, let c): return c
            case .committed: return false
            }
        }

        var attachmentPaths: [String] {
            switch self {
            case .streaming: return []
            case .committed(_, _, let p, _): return p
            }
        }

        var clippedTexts: [String] {
            switch self {
            case .streaming: return []
            case .committed(_, _, _, let c): return c
            }
        }
    }

    /// Reads one bubble's streaming state out of the manager under the item's
    /// OWNING task id. Static + extracted so the keying is unit-testable: in the
    /// merged delegation timeline, a child task's bubble must read under the
    /// child's `originTaskID` — substituting the active task's id here would
    /// compile, pass the suite, and silently blank out (or cross-wire) child-team
    /// streaming bubbles. Pinned by `StreamingSnapshotKeyingTests`.
    static func makeStreamingSnapshot(
        manager: StreamingPreviewManager,
        messageID: UUID,
        stepID: String,
        taskID: Int
    ) -> StreamingSnapshot {
        StreamingSnapshot(
            isStreaming: manager.isStreaming(messageID: messageID),
            content: manager.streamingContent(stepID: stepID, taskID: taskID),
            thinking: manager.streamingThinking(stepID: stepID, taskID: taskID),
            processingStatus: manager.promptProcessingStatus(stepID: stepID, taskID: taskID),
            hasStreamActivity: manager.hasReceivedStreamActivity(
                stepID: stepID, taskID: taskID),
            isStreamingToolCall: manager.isStreamingToolCall(
                stepID: stepID, taskID: taskID),
            isCompacting: manager.isCompacting(stepID: stepID, taskID: taskID)
        )
    }

    /// Pure snapshot of streaming state passed into the static resolver,
    /// so tests don't need to touch `StreamingPreviewManager`.
    struct StreamingSnapshot: Equatable {
        let isStreaming: Bool
        let content: String?
        let thinking: String?
        let processingStatus: PromptProcessingStatus?
        let hasStreamActivity: Bool
        let isStreamingToolCall: Bool
        let isCompacting: Bool
    }

    /// Resolves a `BubbleInputs` from `(msg, streaming snapshot)`.
    /// Static + injectable snapshot so it's callable from XCTest.
    ///
    /// For `.supervisorMessage` turns (queued chat delivery +
    /// `forward_to_team` injections — both producers tag with the same
    /// context), strips the embedded `## Attached Files` /
    /// `## Clipped Text` markers and surfaces their payloads as
    /// thumbnail cards via the same `ReadOnlyAttachmentGrid` used by
    /// `SupervisorTaskItemView` and `SupervisorInputCard`. Order
    /// matters: `displayContent` first strips the leading
    /// `Supervisor:\n` attribution prefix, then `stripAttachedFiles`
    /// scans the remainder for marker sections.
    static func resolveBubbleInputs(msg: LLMMessage, streaming: StreamingSnapshot) -> BubbleInputs {
        if streaming.isStreaming {
            return .streaming(
                content: streaming.content ?? "",
                thinking: streaming.thinking,
                processingStatus: streaming.processingStatus,
                hasStreamActivity: streaming.hasStreamActivity,
                isStreamingToolCall: streaming.isStreamingToolCall,
                isCompacting: streaming.isCompacting
            )
        }
        // Which contexts can carry marker sections is stated on the value
        // (`mayEmbedAttachmentMarkers`) rather than re-listed here — the same
        // question is asked by `ConversationTranscriptRenderer`, and the two
        // lists had already drifted apart.
        let inputs = ActivityFeedBuilder.bubbleDisplayInputs(
            raw: msg.displayContent,
            isSupervisorMessage: msg.sourceContext?.mayEmbedAttachmentMarkers == true
        )
        return .committed(
            content: inputs.text,
            thinking: msg.thinking,
            attachmentPaths: inputs.paths,
            clippedTexts: inputs.clippedTexts
        )
    }
}
