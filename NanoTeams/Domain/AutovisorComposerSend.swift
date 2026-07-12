import Foundation

/// Pure send state machine for the Watchtower Autovisor composer, extracted so the
/// clear-on-successful-queue gating is unit-testable instead of buried in the SwiftUI
/// view's `send()` (mirrors `MessageKeyPolicy`). It pre-gates empty payloads, invokes
/// `queue` only when there's something to send, and returns `.cleared` ONLY when the
/// orchestrator reports the message was actually enqueued.
///
/// The view maps `.cleared` → reset draft + confirm, and `.empty` / `.kept` → leave the
/// user's typed message and staged attachments intact. The `.kept` case is the
/// load-bearing guard: a send that wasn't queued (e.g. no manager task) must never
/// destroy the user's draft — the regression `sendMessageToAutovisor`'s `Bool` exists
/// to prevent.
///
/// Foundation-only: no SwiftUI, no `@MainActor`. The view feeds the current draft in
/// and actuates on the returned `Outcome`.
nonisolated enum AutovisorComposerSend {

    /// What the view should do after a Send press.
    enum Outcome: Equatable {
        /// Nothing to send (no text after trimming, no attachments) — no-op.
        case empty
        /// Send was attempted but not queued (e.g. no manager task) — preserve the
        /// draft + staged attachments so the user can retry.
        case kept
        /// Message was queued — safe to clear the draft and confirm.
        case cleared
    }

    /// - parameter text: the raw composer text (trimmed internally for the gate).
    /// - parameter hasAttachments: whether any staged attachments are present.
    /// - parameter hasClips: whether any clips / skills are staged.
    /// - parameter queue: performs the actual enqueue, returning `true` iff the message
    ///   was queued. Receives the trimmed text. Invoked only when the payload is non-empty.
    static func evaluate(
        text: String,
        hasAttachments: Bool,
        hasClips: Bool = false,
        queue: (_ trimmed: String) -> Bool
    ) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hasAttachments || hasClips else { return .empty }
        return queue(trimmed) ? .cleared : .kept
    }
}
