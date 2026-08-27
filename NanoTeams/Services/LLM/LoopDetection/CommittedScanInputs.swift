import Foundation
#if DEBUG
import Synchronization
#endif

/// Turns a `StepExecution` into the flattened tuples the committed loop scan takes.
///
/// `LoopScanner` is deliberately `LLMMessage`-free — it accepts
/// `(thinking, content, createdAt)` so the in-stream, committed and evaluator paths can
/// all feed it. Both committed callers therefore had to do the Domain→tuple conversion
/// themselves, and both spelled it the same wrong way:
///
/// ```swift
/// step.llmConversation
///     .filter { $0.role == .assistant }   // Θ(N), MATERIALISES every assistant turn…
///     .suffix(5)                          // …to take the last five
/// ```
///
/// `filter` on an `Array` is eager, so that allocated an array of the whole assistant
/// history to answer a question about its tail. `llmConversation` has no ceiling
/// (`LLMConstants.maxToolIterations == 0`; nothing prunes it), and the caller in
/// `NTMSOrchestrator.commitStreaming` runs once per committed assistant turn — so the
/// cost was Θ(N) per turn, i.e. Θ(N²) across a chat session, on the MainActor.
///
/// The tail walk below is Θ(Δ): it stops as soon as it has `limit` assistant turns, and
/// every turn appends one, so in the steady state it examines about `limit` messages
/// regardless of how long the conversation has grown.
///
/// One home for both callers, so the next path that feeds the committed scanner cannot
/// re-derive the eager spelling (CLAUDE.md #51).
nonisolated enum CommittedScanInputs {

    /// The last `limit` ASSISTANT turns, oldest-first — the order `LoopScanner` expects.
    ///
    /// Walks from the tail and stops, rather than filtering the whole array. Equivalent
    /// to `filter { $0.role == .assistant }.suffix(limit)` for any input, including an
    /// out-of-order one: neither spelling looks at `createdAt`, both preserve array
    /// order, and both return the last `limit` matches.
    static func recentAssistantTurns(
        in conversation: [LLMMessage], limit: Int
    ) -> [(thinking: String?, content: String, createdAt: Date)] {
        guard limit > 0 else { return [] }
        var tail: [(thinking: String?, content: String, createdAt: Date)] = []
        tail.reserveCapacity(limit)
        for message in conversation.reversed() {
            #if DEBUG
            CommittedScanInputProbe.noteExamined()
            #endif
            guard message.role == .assistant else { continue }
            tail.append((thinking: message.thinking,
                         content: message.content,
                         createdAt: message.createdAt))
            if tail.count == limit { break }
        }
        return tail.reversed()
    }

    /// The last `limit` tool calls, oldest-first. `suffix` on an `Array` is already a
    /// slice, so this is O(limit) — it lives here for the same reason the walk above
    /// does: both callers need the pair, and a pair split across two files drifts.
    static func recentToolCalls(
        in toolCalls: [StepToolCall], limit: Int
    ) -> [(name: String, argsJSON: String, createdAt: Date)] {
        guard limit > 0 else { return [] }
        return toolCalls.suffix(limit).map {
            (name: $0.name, argsJSON: $0.argumentsJSON, createdAt: $0.createdAt)
        }
    }
}

#if DEBUG
/// Work-bound seam: how many conversation messages the tail walk EXAMINED since the
/// last reset.
///
/// It lives inside the walk, not beside a call site, for the reason CLAUDE.md #62
/// records: the defect being pinned is work paid BEFORE a guard that discards it, and a
/// counter placed outside would report the conversation's length whether or not the walk
/// ever ran. A regression here is invisible in OUTPUT — the eager spelling returns
/// exactly the same tuples.
nonisolated enum CommittedScanInputProbe {
    private static let _examined = Atomic<Int>(0)
    static func noteExamined() { _examined.wrappingAdd(1, ordering: .relaxed) }
    static func examined() -> Int { _examined.load(ordering: .relaxed) }
    static func reset() { _examined.store(0, ordering: .relaxed) }
}
#endif
