import Foundation
import Observation

/// Manages streaming message previews for real-time LLM response display.
/// Thread-safe manager that accumulates streaming content and provides previews to the UI.
@Observable @MainActor
final class StreamingPreviewManager {

    /// Structural version — incremented only when a preview is added or removed.
    /// Views observe this to know when to rebuild the timeline,
    /// without re-evaluating on every content append.
    private(set) var structuralVersion: UInt64 = 0

    /// Current streaming previews keyed by step ID.
    /// @ObservationIgnored — content changes do not trigger view re-evaluation.
    /// Views poll content via `TimelineView` instead.
    @ObservationIgnored private(set) var previews: [String: StepMessage] = [:]

    /// Maps stepID → messageID for messages currently being streamed.
    /// @ObservationIgnored — used for polling only, not for view updates.
    @ObservationIgnored private(set) var streamingMessageIDs: [String: UUID] = [:]

    /// Reverse lookup set for O(1) `isStreaming(messageID:)` checks.
    @ObservationIgnored private var activeMessageIDs: Set<UUID> = []

    /// Accumulated thinking content keyed by step ID.
    /// @ObservationIgnored — polled by TimelineView like content.
    @ObservationIgnored private(set) var thinkingPreviews: [String: String] = [:]

    /// Current prompt processing progress keyed by step ID (0.0–1.0).
    /// @ObservationIgnored — polled by TimelineView.
    @ObservationIgnored private(set) var processingProgress: [String: Double] = [:]

    // MARK: - Inline Streaming

    /// Marks a message as actively streaming for a step.
    /// Creates an empty preview and registers the stepID → messageID mapping.
    func beginStreaming(stepID: String, messageID: UUID, role: Role) {
        let isNew = previews[stepID] == nil
        // Remove old messageID if replacing an existing streaming session
        if let oldID = streamingMessageIDs[stepID] { activeMessageIDs.remove(oldID) }
        previews[stepID] = StepMessage(id: messageID, createdAt: MonotonicClock.shared.now(), role: role, content: "")
        streamingMessageIDs[stepID] = messageID
        activeMessageIDs.insert(messageID)
        if isNew { structuralVersion &+= 1 }
    }

    /// Checks if a specific message is currently being streamed.
    func isStreaming(messageID: UUID) -> Bool {
        activeMessageIDs.contains(messageID)
    }

    /// Returns streaming content for a step (polled by TimelineView).
    func streamingContent(for stepID: String) -> String? {
        previews[stepID]?.content
    }

    /// Returns streaming thinking content for a step (polled by TimelineView).
    func streamingThinking(for stepID: String) -> String? {
        thinkingPreviews[stepID]
    }

    // MARK: - Content Accumulation

    /// Appends content to the streaming preview for a step.
    /// - Parameters:
    ///   - stepID: The step receiving the streaming content.
    ///   - messageID: The message ID for the preview (used to update existing messages).
    ///   - role: The role of the message sender.
    ///   - content: The content to append.
    func append(stepID: String, messageID: UUID, role: Role, content: String) {
        guard !content.isEmpty else { return }

        let isNew = previews[stepID] == nil
        var message =
            previews[stepID]
            ?? StepMessage(id: messageID, createdAt: MonotonicClock.shared.now(), role: role, content: "")
        message.content += content
        if ModelTokenCleaner.containsModelTokens(message.content) {
            message.content = ModelTokenCleaner.stripTokens(message.content)
        }
        previews[stepID] = message
        if isNew { structuralVersion &+= 1 }
    }

    /// Appends thinking content to the streaming preview for a step.
    func appendThinking(stepID: String, content: String) {
        guard !content.isEmpty else { return }
        thinkingPreviews[stepID, default: ""] += content
    }

    // MARK: - Processing Progress

    /// Updates the prompt processing progress for a step.
    func updateProcessingProgress(stepID: String, progress: Double) {
        processingProgress[stepID] = progress
    }

    /// Clears the prompt processing progress for a step.
    func clearProcessingProgress(stepID: String) {
        processingProgress[stepID] = nil
    }

    // MARK: - Commit / Clear

    /// Commits the streaming preview for a step and returns it.
    /// This removes the preview, streaming mapping, thinking, and processing state.
    /// - Parameter stepID: The step whose preview to commit.
    /// - Returns: The committed preview message, or nil if no preview exists.
    @discardableResult
    func commit(stepID: String) -> StepMessage? {
        guard let preview = previews[stepID] else { return nil }
        if let msgID = streamingMessageIDs[stepID] { activeMessageIDs.remove(msgID) }
        previews[stepID] = nil
        streamingMessageIDs[stepID] = nil
        thinkingPreviews[stepID] = nil
        processingProgress[stepID] = nil
        structuralVersion &+= 1

        // Return nil if the preview content is empty after trimming
        guard !preview.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return preview
    }

    /// Clears the streaming preview for a step without committing.
    /// - Parameter stepID: The step whose preview to clear.
    func clear(stepID: String) {
        guard previews[stepID] != nil || streamingMessageIDs[stepID] != nil
                || thinkingPreviews[stepID] != nil || processingProgress[stepID] != nil else { return }
        if let msgID = streamingMessageIDs[stepID] { activeMessageIDs.remove(msgID) }
        previews[stepID] = nil
        streamingMessageIDs[stepID] = nil
        thinkingPreviews[stepID] = nil
        processingProgress[stepID] = nil
        structuralVersion &+= 1
    }

    /// Clears all streaming previews.
    func clearAll() {
        guard !previews.isEmpty || !streamingMessageIDs.isEmpty
                || !thinkingPreviews.isEmpty || !processingProgress.isEmpty else { return }
        previews.removeAll()
        streamingMessageIDs.removeAll()
        activeMessageIDs.removeAll()
        thinkingPreviews.removeAll()
        processingProgress.removeAll()
        structuralVersion &+= 1
    }

    // MARK: - Queries

    /// Gets the current preview for a step, if any.
    /// - Parameter stepID: The step to get the preview for.
    /// - Returns: The current preview, or nil if none exists.
    func preview(for stepID: String) -> StepMessage? {
        previews[stepID]
    }

    /// Checks if there's an active preview for a step.
    /// - Parameter stepID: The step to check.
    /// - Returns: True if a preview exists for the step.
    func hasPreview(for stepID: String) -> Bool {
        previews[stepID] != nil
    }
    nonisolated deinit {}
}
