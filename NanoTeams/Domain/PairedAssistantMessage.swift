import Foundation

/// Snapshot of the assistant turn that emitted an active `ask_supervisor`.
/// Shared between `SupervisorQuestionInbox.PendingQuestion` (which decides
/// whether to suppress the bubble in the timeline) and
/// `TeamActivityActiveQuestion` (the composer's question card).
///
/// In `Domain/` rather than beside the feed builder because the producer of the
/// pending-question list moved to `Services/Step/`: a service reaching into a
/// SwiftUI file for a value type is a dependency pointing the wrong way, and this
/// type imports nothing but Foundation.
///
/// Pairs `id`, `thinking` and `content` atomically so they can't drift: the
/// outer `Optional<PairedAssistantMessage>` is the only "paired data is
/// missing" state. `id` identifies the feed bubble;
/// `isFullyRenderedByQuestionCard` decides whether that bubble may be dropped;
/// `thinking` feeds the card's thinking disclosure when it owns the turn.
///
/// Both `thinking` and `content` are trim-to-nil at construction: whitespace-
/// only input collapses to nil so `!= nil` reliably means "there is something
/// to render." Consumers don't need to re-trim before checking emptiness.
nonisolated struct PairedAssistantMessage: Equatable {
    let id: UUID
    let thinking: String?
    /// The turn's prose, trim-to-nil. Read only through
    /// `isFullyRenderedByQuestionCard` — stored rather than reduced to a `Bool`
    /// so the type stays a faithful snapshot of the turn.
    let content: String?

    /// Whether the composer's question card fully covers this turn. True when the
    /// turn carries no prose: the card's question plus this turn's `thinking` is
    /// then everything there is to render, and the feed may drop the bubble.
    /// False when the turn carries prose the card does not render (since
    /// `cfe23f5b` it renders none) — the bubble is that prose's only surface.
    var isFullyRenderedByQuestionCard: Bool { content == nil }

    /// `content` deliberately has NO default. A `nil` default reads as
    /// "suppressible", silently reproducing the pre-fix behaviour at any site
    /// that forgets to pass it — the wrong direction for the defect this type
    /// now guards against. Both production sites and every test pass it.
    init(id: UUID, thinking: String?, content: String?) {
        self.id = id
        let trimmedThinking = thinking?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.thinking = (trimmedThinking?.isEmpty == false) ? trimmedThinking : nil
        let trimmedContent = content?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.content = (trimmedContent?.isEmpty == false) ? trimmedContent : nil
    }
}
