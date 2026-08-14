import Foundation

/// When did information last reach the model that no tool call of its own produced?
///
/// The committed-history counterpart of `ToolCallTracker.TrackedCall.informationEpoch`.
/// The in-step tracker sees only tool calls, so it marks the boundary on the next call it
/// records; the committed scanners see the whole conversation, so they can read the
/// boundary straight off it as a timestamp and fold it into the cutoff they already apply
/// (`LoopScanner.scanCommitted`).
///
/// Split out of `LoopScanner` rather than folded into it because the scanner is
/// deliberately `LLMMessage`-free — it takes flattened `(thinking, content, createdAt)`
/// tuples so the in-stream, committed and evaluator paths can all feed it. This is the one
/// piece that must look at the Domain type, and both call sites already hold
/// `step.llmConversation` unfiltered.
nonisolated enum ConversationInformationBoundary {

    /// Timestamp of the most recent turn that PUSHED information at the model
    /// (`MessageSourceContext.carriesUnsolicitedInformation`), or `nil` when the
    /// conversation holds none.
    ///
    /// Classification is by CONTEXT alone, not by role. Every producer today writes
    /// `.user` (the queued-Supervisor pipeline, `forward_to_team` into a child), but the
    /// question this answers — "did something arrive that no tool call of this model's own
    /// asked for?" — is a property of where the content came from, and a role check would
    /// silently drop a future producer that files the same information differently.
    ///
    /// Deliberately narrow. A context the model's OWN tool call produces must never open a
    /// boundary: it is stamped after that call, so a model spinning on that very tool would
    /// refresh its own cutoff with every repeat and pin the trailing run at 1 forever. See
    /// `carriesUnsolicitedInformation`.
    ///
    /// Takes the MAX rather than the last match so the result cannot depend on the order
    /// of the array it is handed. `llmConversation` is append-ordered under a strictly
    /// increasing `MonotonicClock` (pinned by `ConversationAppendInvariantTests`), so the
    /// two agree today — but this helper accepts any `[LLMMessage]`, and a caller passing a
    /// filtered or re-sorted slice must not silently get an older boundary than the truth.
    static func lastArrival(in conversation: [LLMMessage]) -> Date? {
        conversation
            .lazy
            .filter { $0.sourceContext?.carriesUnsolicitedInformation == true }
            .map(\.createdAt)
            .max()
    }
}
