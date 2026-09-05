import Foundation
#if DEBUG
import Synchronization
#endif

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
/// ask call or an escalation card to render) and PER STEP inside `emitItems`.
/// The resolver itself is never cached across rebuilds. What IS memoized is the
/// ESCALATION CARD's resolved value, by `TeamActivityFeedViewModel` under
/// `(TaskStepKey, answerMessage.id)` — keyed per task so descendant steps that
/// share a `step.id` cannot collide. That memo is sound because every candidate
/// at or before the answer is frozen once the answer exists: appends are
/// stamped by `MonotonicClock.shared.now()`, which is strictly greater than
/// every prior stamp; the only in-place `thinking` writer,
/// `TaskMutationService.commitStreamingContent`, targets the tail turn that
/// `beginStreaming` pre-created after the resume and re-stamps it FORWARD past
/// the answer; `applyRetryNotice` removes or re-stamps only the tail turn (and a
/// `.serverError` turn carries no `thinking`, so it is never a candidate);
/// `removeLLMMessage` drops the pre-created empty turn. A new answer cycle
/// changes `answerMessage.id`, hence the key. `ThinkingResolverBuildProbe`
/// counts builds so the memo can be pinned as work not done.
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
        #if DEBUG
        ThinkingResolverBuildProbe.noteBuilt()
        #endif
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

#if DEBUG
/// Counts `ThinkingResolver` builds since the last reset — each one an O(k log k)
/// sort of the step's assistant turns. Inside the initializer (CLAUDE.md #62):
/// the escalation-card memo in `TeamActivityFeedViewModel` is a condition AROUND
/// this build, so a test comparing returned values cannot see whether the work
/// ran; the counter can.
nonisolated enum ThinkingResolverBuildProbe {
    private static let _builds = Atomic<Int>(0)
    static func noteBuilt() { _builds.wrappingAdd(1, ordering: .relaxed) }
    static func builds() -> Int { _builds.load(ordering: .relaxed) }
    static func reset() { _builds.store(0, ordering: .relaxed) }
}
#endif
