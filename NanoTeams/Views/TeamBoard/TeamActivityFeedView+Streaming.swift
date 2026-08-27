import SwiftUI
#if DEBUG
import Synchronization
#endif

// MARK: - Streaming Bubble Logic (pure, unit-testable)
//
// Extracted from TeamActivityFeedView: the per-tick streaming-bubble
// resolvers and their value types (BubbleInputs / StreamingSnapshot /
// BubbleSchedule). All static + pure — no instance state — so the
// streaming/committed bubble state machine is testable without the view.
extension TeamActivityFeedView {

    /// The ONE message a `.running` step implicitly streams into: its latest
    /// VISIBLE turn. Nil when the step is not running or has no visible turn.
    ///
    /// One pass, nothing materialized. The `max(by: createdAt)` law is kept
    /// deliberately — `last` is NOT equivalent, because `commitStreamingContent`
    /// re-stamps a committed turn forward and a tool turn can carry a later
    /// timestamp than the assistant turn that produced it (pinned by
    /// `testReturnsTrue_whenLatestVisibleMessage_evenIfToolTurnHasLaterTimestamp`).
    /// Visible-message filter mirrors `ActivityFeedBuilder.emitItems`.
    static func implicitStreamTargetID(in step: StepExecution) -> UUID? {
        guard step.status == .running else { return nil }
        var latest: LLMMessage?
        for message in step.llmConversation
            where message.role != .system && message.role != .tool {
            #if DEBUG
            ImplicitStreamTargetProbe.noteExamined()
            #endif
            if latest == nil || message.createdAt > latest!.createdAt { latest = message }
        }
        return latest?.id
    }

    // MARK: - Bubble inputs (testable resolver)

    /// Per-tick inputs for `MessageBubbleView`. The two cases mirror the
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
            isStreamingToolCall: Bool
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
            case .streaming(let c, _, _, _, _): return c
            case .committed(let c, _, _, _): return c
            }
        }

        var thinkingForBubble: String? {
            switch self {
            case .streaming(_, let t, _, _, _): return t
            case .committed(_, let t, _, _): return t
            }
        }

        var processingStatus: PromptProcessingStatus? {
            switch self {
            case .streaming(_, _, let p, _, _): return p
            case .committed: return nil
            }
        }

        var hasStreamActivity: Bool {
            switch self {
            case .streaming(_, _, _, let a, _): return a
            case .committed: return false
            }
        }

        var isStreamingToolCall: Bool {
            switch self {
            case .streaming(_, _, _, _, let t): return t
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
            processingStatus: manager.processingStatus[
                TaskStepKey(taskID: taskID, stepID: stepID)],
            hasStreamActivity: manager.hasReceivedStreamActivity(
                stepID: stepID, taskID: taskID),
            isStreamingToolCall: manager.isStreamingToolCall(
                stepID: stepID, taskID: taskID)
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
    }

    /// Adaptive `TimelineSchedule`:
    /// - Streaming: emits at `streamingInterval` (3.3 Hz at 0.3s). Hot
    ///   path drives `MessageBubbleView` re-evaluation so token deltas
    ///   from `StreamingPreviewManager` (which is `@ObservationIgnored`)
    ///   propagate to the bubble.
    /// - Committed: emits exactly one entry, then terminates — no timer
    ///   heartbeat. Body re-evaluations come from parent state changes.
    ///
    /// Single concrete schedule type means a single `TimelineView` generic
    /// across both states, which preserves SwiftUI structural identity at
    /// the streaming → committed transition. `Equatable` synthesis lets
    /// SwiftUI's view diff fast-path skip TimelineView re-arming when
    /// neither field changed.
    struct BubbleSchedule: TimelineSchedule, Equatable {
        let isStreaming: Bool
        let streamingInterval: TimeInterval

        func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
            Entries(
                startDate: startDate,
                isStreaming: isStreaming,
                interval: streamingInterval
            )
        }

        nonisolated struct Entries: Sequence, IteratorProtocol {
            let startDate: Date
            let isStreaming: Bool
            let interval: TimeInterval
            var iteration: Int = 0

            mutating func next() -> Date? {
                guard isStreaming else {
                    // Committed bubbles emit exactly one entry, then end.
                    if iteration == 0 {
                        iteration = 1
                        return startDate
                    }
                    return nil
                }
                let entry = startDate.addingTimeInterval(Double(iteration) * interval)
                iteration += 1
                return entry
            }
        }
    }

    /// Streaming tick interval for `BubbleSchedule`. Three-way table:
    ///
    /// | isResizing | reduceMotion | interval                  | rationale |
    /// |------------|--------------|---------------------------|-----------|
    /// | true       | any          | `.greatestFiniteMagnitude`| Freeze: TimelineView arm preserved (structural identity invariant) but no new ticks fire while the user drags the window. |
    /// | false      | true         | 1.0                       | Slower tick (1 Hz) for users with Reduce Motion — visible streaming progress without churn. |
    /// | false      | false        | 0.3                       | Default 3.3 Hz heartbeat — fast enough that token deltas feel live, slow enough to avoid LazyVStack thrash. |
    ///
    /// `nonisolated` because the math is pure — tests pin the truth table
    /// without instantiating the view. Pinned by `StreamingIntervalResolverTests`.
    nonisolated static func resolveStreamingInterval(
        isResizing: Bool,
        reduceMotion: Bool
    ) -> TimeInterval {
        if isResizing { return .greatestFiniteMagnitude }
        return reduceMotion ? 1.0 : 0.3
    }

    /// Resolves a per-tick `BubbleInputs` from `(msg, streaming snapshot)`.
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
                isStreamingToolCall: streaming.isStreamingToolCall
            )
        }
        // `.supervisorAnswer` joins `.supervisorMessage`: unpaired answers
        // (escalation / Autovisor idle park) render as durable Supervisor
        // bubbles, and an answer embedding `## Attached Files` / clip markers
        // must surface thumbnail cards, not raw marker text. (Paired answers
        // never reach a bubble outside debug mode.)
        let isSupervisorMsg = msg.sourceContext == .supervisorMessage
            || msg.sourceContext == .supervisorAnswer
        let inputs = ActivityFeedBuilder.bubbleDisplayInputs(
            raw: msg.displayContent,
            isSupervisorMessage: isSupervisorMsg
        )
        return .committed(
            content: inputs.text,
            thinking: msg.thinking,
            attachmentPaths: inputs.paths,
            clippedTexts: inputs.clippedTexts
        )
    }
}

#if DEBUG
/// Work-bound seam for the implicit-stream-target scan: conversation messages
/// EXAMINED since the last reset.
///
/// The defect it pins is not a wrong answer but a wrong CADENCE — the scan used
/// to run once per rendered bubble instead of once per step per rebuild — so a
/// behavioural test cannot see it. Counter placed inside the scan, per
/// CLAUDE.md #62.
nonisolated enum ImplicitStreamTargetProbe {
    private static let _examined = Atomic<Int>(0)
    static func noteExamined() { _examined.wrappingAdd(1, ordering: .relaxed) }
    static func _testExamined() -> Int { _examined.load(ordering: .relaxed) }
    static func _testResetExamined() { _examined.store(0, ordering: .relaxed) }
}
#endif
