import Foundation
import Observation

/// Manages streaming message previews for real-time LLM response display.
/// Main-actor-isolated manager that accumulates streaming content and provides previews to the UI.
///
/// All per-step state is keyed by `TaskStepKey` (taskID + stepID) — NOT by stepID
/// alone. `StepExecution.id` equals the team role ID, so two concurrent tasks on
/// the same team share stepID strings; a stepID-only key let one task's
/// commit/clear wipe the other task's live indicator state (the June 2026
/// concurrent-task "lost Thinking/Processing indicator" bug).
@Observable @MainActor
final class StreamingPreviewManager {

    /// Structural version — incremented only when a preview is added or removed.
    /// Views observe this to know when to rebuild the timeline,
    /// without re-evaluating on every content append.
    private(set) var structuralVersion: UInt64 = 0

    /// Current streaming previews keyed by (taskID, stepID).
    /// @ObservationIgnored — content changes do not trigger view re-evaluation.
    /// Views poll content via `TimelineView` instead.
    @ObservationIgnored private(set) var previews: [TaskStepKey: StepMessage] = [:]

    /// Maps (taskID, stepID) → messageID for messages currently being streamed.
    /// @ObservationIgnored — used for polling only, not for view updates.
    @ObservationIgnored private(set) var streamingMessageIDs: [TaskStepKey: UUID] = [:]

    /// Reverse lookup set for O(1) `isStreaming(messageID:)` checks.
    @ObservationIgnored private var activeMessageIDs: Set<UUID> = []

    /// Accumulated thinking content keyed by (taskID, stepID).
    /// @ObservationIgnored — polled by TimelineView like content.
    @ObservationIgnored private(set) var thinkingPreviews: [TaskStepKey: String] = [:]

    /// Current prompt processing progress keyed by (taskID, stepID) (0.0–1.0).
    /// @ObservationIgnored — polled by TimelineView.
    @ObservationIgnored private(set) var processingProgress: [TaskStepKey: Double] = [:]

    /// Per-step flag: `true` once ANY stream delta (thinking, content,
    /// harmony tool-call buffered, OpenAI tool-call delta) has been
    /// observed for the step. Lets the UI distinguish "Waiting" (no
    /// activity yet — model still in prompt processing or hasn't started
    /// emitting) from "Generating" (tokens flowing but landing in
    /// harmony/tool-call buffer, invisible to content/thinking previews).
    /// Without this flag the bubble shows "Waiting" while the model
    /// actively emits a long tool-call argument JSON — confusing to the
    /// user (LM Studio's loaded-models panel shows token counts climbing
    /// but the activity feed appears stuck).
    /// @ObservationIgnored — polled by TimelineView.
    @ObservationIgnored private(set) var hasStreamActivity: [TaskStepKey: Bool] = [:]

    /// Per-step flag: `true` once the live stream has committed to
    /// tool-call emission — a Harmony envelope marker was detected
    /// (`<|call|>`/`<|start|>`/`<|channel|>`, i.e. strictly "harmony
    /// envelope streaming", which is almost always a tool call) or
    /// OpenAI tool-call deltas arrived. The envelope text streams into
    /// the THINKING preview (the user watches it being typed under the
    /// animated "Thinking…" row — `MessageBubbleView.isThinkingStreaming`
    /// includes this flag so the loader keeps spinning despite frozen
    /// prose). The flag additionally overrides the frozen-prose CONTENT
    /// suppression as the indicator's "Generating" fallback while the
    /// thinking preview is still empty; a non-empty thinking preview
    /// outranks it (`hasThinkingContent` is checked first).
    /// Reset by `beginStreaming` (a fresh stream carries no signal —
    /// covers the generic-error retry path that bypasses commit/clear),
    /// cleared by commit/clear/clearAll.
    /// @ObservationIgnored — polled by TimelineView.
    @ObservationIgnored private(set) var streamingToolCall: [TaskStepKey: Bool] = [:]

    /// Per-step wall-clock timestamp of the LAST observed stream activity. Read by
    /// the Autovisor stuck-detector to tell a genuinely stalled `.running` role
    /// (token silence) from one mid-(even long-)response — tokens keep refreshing
    /// this, so a flowing response never reads as "hung". Uses `Date()` (elapsed
    /// measurement, not a model-ordering timestamp). Cleared on commit/clear like
    /// `hasStreamActivity`.
    ///
    /// Refreshed directly by `beginStreaming` and `updateProcessingProgress`, and by
    /// `markStreamActivity`. Token-content deltas refresh it via the caller's PAIRED
    /// `markStreamActivity` call — `append`/`replaceContent`/`appendThinking` do NOT
    /// stamp it themselves (see `NTMSOrchestrator+Streaming`, which wraps each with
    /// `markStreamActivity`). A future direct caller of those must keep that pairing.
    /// @ObservationIgnored — polled, never drives view updates.
    @ObservationIgnored private(set) var lastStreamActivityAt: [TaskStepKey: Date] = [:]

    // MARK: - Inline Streaming

    /// Marks a message as actively streaming for a step.
    /// Creates an empty preview and registers the (taskID, stepID) → messageID mapping.
    func beginStreaming(stepID: String, taskID: Int, messageID: UUID, role: Role) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let isNew = previews[key] == nil
        // Remove old messageID if replacing an existing streaming session
        if let oldID = streamingMessageIDs[key] { activeMessageIDs.remove(oldID) }
        previews[key] = StepMessage(id: messageID, createdAt: MonotonicClock.shared.now(), role: role, content: "")
        streamingMessageIDs[key] = messageID
        activeMessageIDs.insert(messageID)
        // Reset per-stream transients: a fresh stream has received nothing —
        // no deltas, no tool-call signal, no thinking text, no progress.
        // Normally a no-op (commit/clear ran), but a generic mid-stream error
        // bypasses BOTH and the in-step retry re-enters here. Without the
        // reset, the retry inherits the failed attempt's state: stale flags
        // mislabel its prompt-processing as "Generating", and — worse —
        // stale `thinkingPreviews` (now carrying partial tool-call JSON from
        // the envelope pipe) prepends garbage to the retry's thinking row
        // AND suppresses its "Processing X%" status (`hasThinkingContent`
        // outranks everything in the resolver). The retry's sleep window
        // itself still shows the old animation — acceptable: the catch path
        // posts a visible "LLM server error … Retrying in Xs" bubble first.
        hasStreamActivity[key] = nil
        streamingToolCall[key] = nil
        thinkingPreviews[key] = nil
        processingProgress[key] = nil
        // The activity CLOCK is stamped, not cleared — stream begin is
        // server activity for the stuck-detector's hang heuristic.
        lastStreamActivityAt[key] = Date()
        if isNew { structuralVersion &+= 1 }
    }

    /// Checks if a specific message is currently being streamed.
    func isStreaming(messageID: UUID) -> Bool {
        activeMessageIDs.contains(messageID)
    }

    /// Returns streaming content for a step (polled by TimelineView).
    func streamingContent(stepID: String, taskID: Int) -> String? {
        previews[TaskStepKey(taskID: taskID, stepID: stepID)]?.content
    }

    /// Returns streaming thinking content for a step (polled by TimelineView).
    func streamingThinking(stepID: String, taskID: Int) -> String? {
        thinkingPreviews[TaskStepKey(taskID: taskID, stepID: stepID)]
    }

    // MARK: - Content Accumulation

    /// Appends content to the streaming preview for a step.
    /// - Parameters:
    ///   - stepID: The step receiving the streaming content.
    ///   - taskID: The task owning the step.
    ///   - messageID: The message ID for the preview (used to update existing messages).
    ///   - role: The role of the message sender.
    ///   - content: The content to append.
    func append(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String) {
        guard !content.isEmpty else { return }

        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let isNew = previews[key] == nil
        var message =
            previews[key]
            ?? StepMessage(id: messageID, createdAt: MonotonicClock.shared.now(), role: role, content: "")
        message.content += content
        if ModelTokenCleaner.containsModelTokens(message.content) {
            message.content = ModelTokenCleaner.stripTokens(message.content)
        }
        previews[key] = message
        if isNew { structuralVersion &+= 1 }
    }

    /// Replaces the preview content for a step in one shot.
    ///
    /// Used to rewind when a Harmony tool-call marker is detected mid-flush, so
    /// partial prefixes like `<` or `<|` don't linger on screen after the
    /// streaming service has already decided they belong to a tool-call envelope.
    func replaceContent(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if var message = previews[key] {
            message.content = content
            previews[key] = message
            return
        }
        // No preview yet — only create one if rewinding to non-empty content,
        // so a marker at position 0 doesn't materialize an empty bubble.
        guard !content.isEmpty else { return }
        previews[key] = StepMessage(
            id: messageID, createdAt: MonotonicClock.shared.now(),
            role: role, content: content)
        structuralVersion &+= 1
    }

    /// Appends thinking content to the streaming preview for a step.
    func appendThinking(stepID: String, taskID: Int, content: String) {
        guard !content.isEmpty else { return }
        thinkingPreviews[TaskStepKey(taskID: taskID, stepID: stepID), default: ""] += content
    }

    // MARK: - Processing Progress

    /// Updates the prompt processing progress for a step.
    func updateProcessingProgress(stepID: String, taskID: Int, progress: Double) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        processingProgress[key] = progress
        // Prompt-processing progress IS server activity — a long prompt-processing
        // phase (big context on a slow machine) emits these before the first
        // token, so it must refresh the activity clock or the stuck-detector would
        // mis-read the silent pre-token window as a hang.
        lastStreamActivityAt[key] = Date()
    }

    /// Clears the prompt processing progress for a step.
    func clearProcessingProgress(stepID: String, taskID: Int) {
        processingProgress[TaskStepKey(taskID: taskID, stepID: stepID)] = nil
    }

    /// Marks the step as having received at least one stream delta. Idempotent
    /// — caller fires this on every delta without checking, the manager
    /// short-circuits if the flag is already set. Call from any path that
    /// observes stream activity, including tool-call deltas and
    /// harmony-buffered content (where the delta produces no visible content
    /// in the preview).
    func markStreamActivity(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        hasStreamActivity[key] = true
        lastStreamActivityAt[key] = Date()
    }

    /// Polled by `MessageBubbleStreamingIndicator` to distinguish "Waiting"
    /// (no activity yet) from "Generating" (tokens flowing into invisible
    /// buffers like harmony tool-call args).
    func hasReceivedStreamActivity(stepID: String, taskID: Int) -> Bool {
        hasStreamActivity[TaskStepKey(taskID: taskID, stepID: stepID)] == true
    }

    /// Marks the step's live stream as having committed to tool-call
    /// emission (harmony envelope marker detected / OpenAI tool-call
    /// deltas arriving). Idempotent — the streaming loop fires it without
    /// checking. Callers pair it with `markStreamActivity` in the same
    /// delta iteration, which keeps `lastStreamActivityAt` fresh — this
    /// setter intentionally does NOT stamp the clock itself.
    func markStreamingToolCall(stepID: String, taskID: Int) {
        streamingToolCall[TaskStepKey(taskID: taskID, stepID: stepID)] = true
    }

    /// Polled per tick by `TeamActivityFeedView` — keeps the Thinking
    /// loader animating during tool-call assembly
    /// (`MessageBubbleView.isThinkingStreaming`) and surfaces the
    /// indicator's "Generating" fallback when the thinking preview is
    /// still empty (visible prose froze at the marker).
    func isStreamingToolCall(stepID: String, taskID: Int) -> Bool {
        streamingToolCall[TaskStepKey(taskID: taskID, stepID: stepID)] == true
    }

    /// Wall-clock time of the last observed stream activity for a step, or nil
    /// if the step has no live stream. Consumed by the Autovisor stuck-detector.
    func lastStreamActivity(stepID: String, taskID: Int) -> Date? {
        lastStreamActivityAt[TaskStepKey(taskID: taskID, stepID: stepID)]
    }

    // MARK: - Commit / Clear

    /// Commits the streaming preview for a step and returns it.
    /// This removes the preview, streaming mapping, thinking, and processing state.
    /// - Returns: The committed preview message, or nil if no preview exists.
    @discardableResult
    func commit(stepID: String, taskID: Int) -> StepMessage? {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        // Capture first, clear unconditionally: per-step transient state
        // (flags, progress, clock) must not survive a commit even when no
        // preview exists — the pre-fix early `guard let preview` return
        // skipped ALL removals, so flags set after an out-of-band clear
        // would leak into the next stream as a stale "Generating".
        let preview = previews[key]
        if let msgID = streamingMessageIDs[key] { activeMessageIDs.remove(msgID) }
        previews[key] = nil
        streamingMessageIDs[key] = nil
        thinkingPreviews[key] = nil
        processingProgress[key] = nil
        hasStreamActivity[key] = nil
        streamingToolCall[key] = nil
        lastStreamActivityAt[key] = nil
        // Structural change (preview removal) only happened if one existed.
        if preview != nil { structuralVersion &+= 1 }

        // Return nil if there was no preview, or its content is empty after trimming
        guard let preview,
              !preview.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return preview
    }

    /// Clears the streaming preview for a step without committing.
    func clear(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard previews[key] != nil || streamingMessageIDs[key] != nil
                || thinkingPreviews[key] != nil || processingProgress[key] != nil
                || hasStreamActivity[key] != nil || streamingToolCall[key] != nil
                || lastStreamActivityAt[key] != nil else { return }
        if let msgID = streamingMessageIDs[key] { activeMessageIDs.remove(msgID) }
        previews[key] = nil
        streamingMessageIDs[key] = nil
        thinkingPreviews[key] = nil
        processingProgress[key] = nil
        hasStreamActivity[key] = nil
        streamingToolCall[key] = nil
        lastStreamActivityAt[key] = nil
        structuralVersion &+= 1
    }

    /// Clears all streaming previews.
    func clearAll() {
        guard !previews.isEmpty || !streamingMessageIDs.isEmpty
                || !thinkingPreviews.isEmpty || !processingProgress.isEmpty
                || !hasStreamActivity.isEmpty || !streamingToolCall.isEmpty
                || !lastStreamActivityAt.isEmpty else { return }
        previews.removeAll()
        streamingMessageIDs.removeAll()
        activeMessageIDs.removeAll()
        thinkingPreviews.removeAll()
        processingProgress.removeAll()
        hasStreamActivity.removeAll()
        streamingToolCall.removeAll()
        lastStreamActivityAt.removeAll()
        structuralVersion &+= 1
    }

    // MARK: - Queries

    /// Gets the current preview for a step, if any.
    func preview(stepID: String, taskID: Int) -> StepMessage? {
        previews[TaskStepKey(taskID: taskID, stepID: stepID)]
    }

    /// Checks if there's an active preview for a step.
    func hasPreview(stepID: String, taskID: Int) -> Bool {
        previews[TaskStepKey(taskID: taskID, stepID: stepID)] != nil
    }
    nonisolated deinit {}
}
