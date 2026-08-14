import Foundation

/// Pure, stateless orchestrator that sequences `MessageRepetitionDetector` calls
/// and owns the recency/cutoff filtering that was previously duplicated inline
/// across `DelegationLoopWatcher` and `AutovisorStuckEvaluator`. Both of those —
/// plus the new in-stream top-level scan — funnel through here so the detector
/// *threshold* parameters passed to `MessageRepetitionDetector`
/// (`repetitionMinSubstringChars`/`repetitionMinRepeats`) live in one place. (The
/// suffix-window sizing constant `repetitionMinIdenticalToolCalls` is still read
/// at the committed-scan call sites to size the slice they hand in.)
///
/// Two entry points by trigger:
///  - `scanStreaming` — live (uncommitted) buffer; **no recency** (inherently current).
///  - `scanCommitted` — finalized conversation + tool-call history, recency via `cutoffDate`.
nonisolated enum LoopScanner {

    /// Which text channels feed the substring scan. The split is live/abort-path vs
    /// committed, not top-level vs child: live/streaming scans (the abort path) use
    /// `.thinkingOnly` because partial visible content mid-abort false-positives on
    /// tables/code; committed-history scans use `.thinkingAndContent`.
    enum Scope {
        case thinkingOnly
        case thinkingAndContent
    }

    // MARK: - Streaming (live buffer)

    /// Runs the within-message detector on the live stream buffer. Callers throttle
    /// the call cadence themselves (the scan is O(n²)). `content` has no default so
    /// scope and channels are always specified together — a `.thinkingAndContent`
    /// caller can't silently degrade to thinking-only by forgetting it; pass `""`
    /// for a `.thinkingOnly` scan that has no visible-content channel.
    static func scanStreaming(thinking: String, content: String, scope: Scope) -> LoopSignal? {
        let haystack = combine(thinking: thinking, content: content, scope: scope)
        guard let match = detectWithin(haystack) else { return nil }
        return .withinMessage(diagnostic: match.diagnostic)
    }

    /// Single funnel for every within-message detection so all the tunables are
    /// sourced from `DelegationConstants` in exactly one place — the streaming and
    /// committed paths can't drift apart on the caps or the length-scaled repeat
    /// thresholds. Uses the tail-anchored `detectTailLoop`: an active loop always
    /// reaches the live tail, and the periodicity-relation scan is uniformly cheap
    /// (no per-start sweep, no comparison budget) regardless of period or buffer size.
    private static func detectWithin(_ haystack: String) -> MessageRepetitionDetector.Match? {
        MessageRepetitionDetector.detectTailLoop(
            haystack,
            minSubstringChars: DelegationConstants.repetitionMinSubstringChars,
            maxSubstringChars: DelegationConstants.repetitionMaxSubstringChars,
            minRepeats: DelegationConstants.repetitionMinRepeats,
            tailWindowChars: DelegationConstants.repetitionTailWindowChars,
            largeSubstringChars: DelegationConstants.repetitionLargeSubstringChars,
            largeBlockMinRepeats: DelegationConstants.repetitionLargeBlockMinRepeats,
            veryLargeSubstringChars: DelegationConstants.repetitionVeryLargeSubstringChars,
            veryLargeBlockMinRepeats: DelegationConstants.repetitionVeryLargeBlockMinRepeats
        )
    }

    // MARK: - Committed (history)

    /// Runs tool-call-sequence → within-message → across-messages against finalized
    /// history. Returns the first (strongest) signal. `cutoffDate` excludes entries
    /// `createdAt <= cutoffDate`: the watcher passes its per-task `lastTrigger`
    /// (revision-retained-history guard); the evaluator passes `now - recencyWindow`.
    ///
    /// `informationBoundary` is the timestamp of the last turn that brought the model
    /// outside information (`ConversationInformationBoundary.lastArrival`). It bounds the
    /// TOOL-CALL scan only, folded into that filter's cutoff — repeating a call after
    /// learning something is a workflow (the manager re-checks the task it was just told
    /// about), repeating it with nothing between is a loop. It is NOT immunity: the count
    /// restarts, so three identical calls AFTER the boundary still fire.
    ///
    /// Deliberately not applied to the two text detectors below. Those ask whether the
    /// model's OWN words are repeating verbatim, and news arriving is no excuse for
    /// emitting the same paragraph again — if anything it makes the repetition worse
    /// evidence. Bounding them would buy nothing and mask the reasoning-model thinking
    /// loop, which is the mode the text detectors exist for.
    ///
    /// **`informationBoundary` has no default; `cutoffDate` beside it does, and the
    /// asymmetry is the point.** A default may express a POLICY the caller owns —
    /// `.distantPast` means "don't filter", which is exactly what the watcher wants
    /// before its first fire. It must not assert a FACT about data only the caller
    /// holds: `nil` here claims "this conversation contains no unsolicited arrival",
    /// and a caller who simply forgot the argument silently restores the pre-fix false
    /// positive — the detector telling a model "the state isn't changing" one turn
    /// after it was told the state changed. This type takes flattened tuples precisely
    /// so more paths can feed it (`scanStreaming` already has three), so the next
    /// caller is the one at risk; the compiler asks it the question instead. Same rule,
    /// same wording, as the in-step half's `TrackedCall.informationEpoch`.
    static func scanCommitted(
        recentAssistant: [(thinking: String?, content: String, createdAt: Date)],
        toolCalls: [(name: String, argsJSON: String, createdAt: Date)],
        cutoffDate: Date = .distantPast,
        informationBoundary: Date?,
        scope: Scope
    ) -> LoopSignal? {
        // 1. Tool-call sequence — deterministic, strongest, cheapest.
        let toolCutoff = max(cutoffDate, informationBoundary ?? .distantPast)
        let freshTools = toolCalls.filter { $0.createdAt > toolCutoff }
        if let match = MessageRepetitionDetector.detectIdenticalToolCallSequence(
            freshTools.map { (name: $0.name, argsJSON: $0.argsJSON) },
            minRepeats: DelegationConstants.repetitionMinIdenticalToolCalls
        ) {
            return .identicalToolCallSequence(diagnostic: match.diagnostic)
        }

        let freshMsgs = recentAssistant.filter { $0.createdAt > cutoffDate }

        // 2. Within the most recent committed assistant turn.
        if let last = freshMsgs.last,
           let match = detectWithin(combine(thinking: last.thinking ?? "", content: last.content, scope: scope)) {
            return .withinMessage(diagnostic: match.diagnostic)
        }

        // 3. Strategic overlap across recent turns.
        let texts = freshMsgs.map { combine(thinking: $0.thinking ?? "", content: $0.content, scope: scope) }
        if let match = MessageRepetitionDetector.detectAcrossMessages(texts) {
            return .acrossMessages(diagnostic: match.diagnostic)
        }

        return nil
    }

    // MARK: - Helpers

    private static func combine(thinking: String, content: String, scope: Scope) -> String {
        switch scope {
        case .thinkingOnly: return thinking
        case .thinkingAndContent: return thinking + "\n" + content
        }
    }
}
