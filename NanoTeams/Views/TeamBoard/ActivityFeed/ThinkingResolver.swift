import Foundation

/// Resolves "the thinking of the LAST assistant turn at or before this anchor"
/// for one step's conversation — the lookup the Q&A card and the escalation card
/// used to answer with a fresh reverse scan of the WHOLE `llmConversation` per
/// ask call. Those scans run on the feed's 50 ms streaming rebuild cadence
/// (`scheduleStructuralRebuild` bypasses the fingerprint short-circuit), and in
/// chat-mode ask loops both factors — ask calls and conversation — grow together.
///
/// Exactly equivalent to
/// `conversation.last(where: { $0.role == .assistant && $0.thinking != nil && $0.createdAt <= anchor })?.thinking`
/// for EVERY input, including out-of-time-order conversations:
/// `last(where:)` selects the greatest ARRAY index among matching candidates,
/// not the greatest `createdAt` — and the array is not guaranteed time-ordered
/// (`TaskMutationService` re-stamps a pre-created message's `createdAt` forward
/// on commit, and repair/edit paths rewrite content in place). Sorting the
/// candidates by `(createdAt, idx)` makes "createdAt <= anchor" a PREFIX of the
/// sorted order, and a prefix running-max of the original index recovers the
/// array-order winner in O(log k) per query.
///
/// The filter is exactly `thinking != nil` — NOT non-empty: the field is
/// unnormalized, a persisted `""` matches today and renders, and silently
/// re-binding such a card to an OLDER turn's reasoning would change what is on
/// screen, not just an empty state.
///
/// Build is O(k log k); callers build LAZILY (only when a step actually has an
/// ask call or an escalation card to render) and PER STEP inside `emitItems` —
/// never cached across rebuilds or keyed to `cachedAllSteps`, because the
/// second `emitItems` invocation walks descendant-task steps that no view-model
/// cache ever sees.
nonisolated struct ThinkingResolver {

    private struct Candidate {
        let createdAt: Date
        let idx: Int
        let thinking: String
    }

    /// Candidates sorted by `(createdAt, idx)` ascending.
    private let sorted: [Candidate]
    /// `prefixBest[k]` = position `p ≤ k` in `sorted` whose candidate has the
    /// greatest original index — the array-order winner of the prefix.
    private let prefixBest: [Int]

    init(conversation: [LLMMessage]) {
        var candidates: [Candidate] = []
        for (idx, message) in conversation.enumerated() {
            guard message.role == .assistant, let thinking = message.thinking else { continue }
            candidates.append(Candidate(createdAt: message.createdAt, idx: idx, thinking: thinking))
        }
        candidates.sort {
            ($0.createdAt, $0.idx) < ($1.createdAt, $1.idx)
        }
        var best: [Int] = []
        best.reserveCapacity(candidates.count)
        for position in candidates.indices {
            if let previous = best.last, candidates[previous].idx > candidates[position].idx {
                best.append(previous)
            } else {
                best.append(position)
            }
        }
        self.sorted = candidates
        self.prefixBest = best
    }

    /// Array-order-last matching candidate with `createdAt <= anchor`, or nil.
    /// The anchor is a bare `Date` on purpose: the ask card anchors on the tool
    /// call's `createdAt`, the escalation card on
    /// `answerMessage?.createdAt ?? step.updatedAt` — a STEP timestamp with no
    /// message behind it.
    func thinking(atOrBefore anchor: Date) -> String? {
        // Rightmost sorted position with createdAt <= anchor.
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].createdAt <= anchor { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        return sorted[prefixBest[low - 1]].thinking
    }
}
