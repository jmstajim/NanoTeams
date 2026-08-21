import Foundation

/// Stateless detector for pathologically repetitive LLM output. Consumed via
/// `LoopScanner` (which `DelegationLoopWatcher`, `AutovisorStuckEvaluator`, and the
/// in-stream top-level scan all route through) to auto-trigger Pause-and-Decide /
/// stuck-role recovery on a team stuck in a loop ("Oh wait Oh wait Oh wait...", same
/// strategic message regenerated each iteration, same tool spammed every turn, etc.).
///
/// Three detection modes:
///  - `detectTailLoop(_:)` — finds the longest period for which the END of the
///    text is periodic for `required` reps (tail-anchored). Catches single-message
///    loops both in finalized content and in mid-stream thinking buffers (reasoning
///    models can loop in their thinking phase without ever committing to disk), at
///    any period up to `maxSubstringChars`, and tolerates a partial final rep.
///  - `detectAcrossMessages(_:)` — finds high pairwise substring overlap
///    across the last N child-role outputs. Catches strategic looping where
///    the role keeps regenerating similar content without progress.
///  - `detectIdenticalToolCallSequence(_:)` — finds N consecutive identical
///    `(toolName, argumentsJSON)` pairs in a step's tool-call history. The
///    most precise signal for tool-spam loops: deterministic, no fuzzy
///    metric. Particularly important for tool-only assistant turns where
///    `content` is empty (the across-messages mode can't see them) and the
///    only loop signal is the structurally identical tool-call payload.
///
/// All modes return `nil` for clean output and a structured `Match` with a
/// short human-readable diagnostic when something fires — the diagnostic is
/// what surfaces to the parent role's tool result via the paused-by-supervisor
/// envelope.
nonisolated enum MessageRepetitionDetector {

    struct Match: Equatable {
        /// The repeated substring (truncated to first 80 chars in the
        /// human-readable description so a 5×-repeat of a 200-char paragraph
        /// doesn't blow up the diagnostic envelope).
        let substring: String
        /// Number of consecutive repetitions detected.
        let repeatCount: Int
        /// One-line diagnostic suitable for the paused envelope's
        /// `supervisor_message`.
        let diagnostic: String
    }

    // MARK: - Within-message (tail-anchored)

    /// Tail-anchored loop detector. Finds the longest period `P` (in
    /// `[minSubstringChars, maxSubstringChars]`) for which the END of the (trimmed,
    /// tail-windowed) text is `P`-periodic for at least the required number of reps —
    /// i.e. an *active* loop ending at the live tail, tolerating a partial final rep.
    ///
    /// Checks the periodicity *relation* `chars[i] == chars[i-P]` walking back from
    /// the tail — ONE pass per `P`, no per-start sweep. That makes it O(maxLen²)
    /// worst-case but ~O(maxLen · repsOfTruePeriod) in practice (non-divisor periods
    /// bail on the first comparison), uniformly cheap regardless of buffer length or
    /// loop period and with no per-pair prefix-comparison blow-up (so no comparison
    /// budget is needed). It is also semantically tighter: it fires only
    /// when the loop is *current* (reaches the tail), not on a loop the model already
    /// escaped. Used for the live streaming / committed scans via `LoopScanner`.
    /// Large periods need `largeBlockMinRepeats` (scaffolding stamps a big block a few
    /// times; a loop re-emits it indefinitely).
    static func detectTailLoop(
        _ text: String,
        minSubstringChars: Int,
        maxSubstringChars: Int,
        minRepeats: Int,
        tailWindowChars: Int,
        largeSubstringChars: Int,
        largeBlockMinRepeats: Int,
        veryLargeSubstringChars: Int = .max,
        veryLargeBlockMinRepeats: Int = 5
    ) -> Match? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minSubstringChars * minRepeats else { return nil }
        let chars = Array(trimmed.suffix(tailWindowChars))
        let n = chars.count
        // Divide by the SMALLEST per-tier rep requirement so a very-large block (which
        // needs only `veryLargeBlockMinRepeats`) can still be tested at its true period;
        // the per-P run check below enforces the actual tier requirement.
        let minTierReps = max(1, min(minRepeats, min(largeBlockMinRepeats, veryLargeBlockMinRepeats)))
        let upperLen = min(maxSubstringChars, n / minTierReps)
        guard upperLen >= minSubstringChars else { return nil }

        // Required reps scale UP with block size (a big block stamped a few times is
        // scaffolding) but back DOWN for very-large multi-paragraph cycles (4 verbatim
        // reps of a 500+ char block is unambiguously a loop, and demanding 8 would need
        // an impractical window).
        func requiredReps(forPeriod P: Int) -> Int {
            if P > veryLargeSubstringChars { return veryLargeBlockMinRepeats }
            if P > largeSubstringChars { return largeBlockMinRepeats }
            return minRepeats
        }

        // Longest period first — higher signal. A non-divisor P bails after one
        // comparison (chars[n-1] != chars[n-1-P]); only true-period multiples extend.
        for P in stride(from: upperLen, through: minSubstringChars, by: -1) {
            let required = requiredReps(forPeriod: P)
            // Maximal tail run satisfying chars[i] == chars[i-P]. A run of `r` means
            // the trailing `r + P` chars form `(r + P) / P` consecutive reps of a
            // P-block (the +P accounts for the block the run points back into).
            var run = 0
            var i = n - 1
            while i - P >= 0 && chars[i] == chars[i - P] {
                run += 1
                i -= 1
            }
            // Need `required` reps → run ≥ (required - 1) · P.
            guard run >= (required - 1) * P else { continue }
            guard isSubstantiveBlock(chars: chars, start: n - P, length: P) else { continue }
            let substring = String(chars[(n - P)..<n])
            let reps = run / P + 1
            return Match(
                substring: substring,
                repeatCount: reps,
                diagnostic: makeDiagnostic(substring: substring, repeats: reps)
            )
        }
        return nil
    }

    /// True unless the block is substantively empty — all the same character, or
    /// fewer than two non-whitespace, non-punctuation chars (a run of `-----` or
    /// `". "` is not a useful loop signal). Shared by the tail-anchored detector.
    private static func isSubstantiveBlock(chars: [Character], start: Int, length L: Int) -> Bool {
        var substantive = 0
        var firstChar: Character? = nil
        var allSame = true
        for offset in 0..<L {
            let c = chars[start + offset]
            if !c.isWhitespace && !c.isPunctuation { substantive += 1 }
            if firstChar == nil { firstChar = c } else if c != firstChar { allSame = false }
        }
        return !allSame && substantive >= 2
    }

    // MARK: - Across-messages

    /// Compares the last N messages pairwise. Fires when the most recent
    /// message has substring overlap with `≥ minMatchingPriors` of the
    /// previous messages exceeding `minOverlap`. Catches strategic loops:
    /// role keeps regenerating "Reading file X… file too large… let me try
    /// again" each iteration without progress.
    ///
    /// Overlap metric: longest-common-substring length / shorter message
    /// length. Bounded by `compareTailChars` to keep the LCS computation
    /// affordable on long messages.
    static func detectAcrossMessages(
        _ messages: [String],
        minMessages: Int = 3,
        minMatchingPriors: Int = 2,
        minOverlap: Double = 0.7,
        compareTailChars: Int = 1_500,
        minMessageChars: Int = 60
    ) -> Match? {
        guard messages.count >= minMessages else { return nil }
        let recent = messages.suffix(minMessages).map { tail($0, max: compareTailChars) }
        guard let last = recent.last,
              last.count >= minMessageChars
        else { return nil }
        var matchingPriors = 0
        var bestOverlap: (substring: String, ratio: Double)? = nil
        for prior in recent.dropLast() {
            guard prior.count >= minMessageChars else { continue }
            let overlap = longestCommonSubstring(last, prior)
            let ratio = Double(overlap.count) / Double(min(last.count, prior.count))
            if ratio >= minOverlap {
                matchingPriors += 1
                if bestOverlap.map({ $0.ratio < ratio }) ?? true {
                    bestOverlap = (overlap, ratio)
                }
            }
        }
        guard matchingPriors >= minMatchingPriors, let best = bestOverlap else { return nil }
        return Match(
            substring: best.substring,
            repeatCount: matchingPriors + 1,
            diagnostic: """
            last message has \(Int(best.ratio * 100))% substring overlap with \(matchingPriors) of \(recent.count - 1) prior messages — strategic loop suspected. Common content: "\(truncate(best.substring, max: 80))"
            """
        )
    }

    // MARK: - Identical tool-call sequence

    /// Returns a `Match` if the **last `minRepeats`** entries in `calls` are
    /// all the same `(name, argsJSON)` pair, otherwise `nil`. Stateless —
    /// the caller (`LoopScanner.scanCommitted`) is responsible for filtering out
    /// tool calls already accounted for by a prior fire (`createdAt` cutoff
    /// against the watcher's last-trigger timestamp), so the same persisted
    /// history doesn't re-fire after
    /// `resetStepForRevision` (which intentionally retains `step.toolCalls`
    /// for audit, see TaskEngineStoreAdapter.resetStepForRevision).
    ///
    /// Operates on labeled tuples instead of `StepToolCall` values to keep
    /// the detector free of `Domain` dependencies (Domain → Services
    /// direction only) and to make tests trivial to write — no need to build
    /// `StepToolCall` fixtures with all their unrelated fields.
    static func detectIdenticalToolCallSequence(
        _ calls: [(name: String, argsJSON: String)],
        minRepeats: Int
    ) -> Match? {
        guard minRepeats >= 2, calls.count >= minRepeats else { return nil }
        let tail = Array(calls.suffix(minRepeats))
        guard let first = tail.first else { return nil }
        guard tail.allSatisfy({ $0 == first }) else { return nil }
        let argsHead = truncate(first.argsJSON, max: 80)
        return Match(
            substring: "\(first.name)(\(first.argsJSON))",
            repeatCount: minRepeats,
            diagnostic: "called \(first.name)(\(argsHead)) \(minRepeats) times in a row with identical arguments"
        )
    }

    // MARK: - Within-message helpers

    private static func makeDiagnostic(substring: String, repeats: Int) -> String {
        let truncated = truncate(substring, max: 80)
        return "substring \"\(truncated)\" repeated \(repeats) times consecutively"
    }

    // MARK: - Across-messages helpers

    private static func tail(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.suffix(max))
    }

    /// Computes longest common substring via DP. O(|a| · |b|) time, O(min(|a|,|b|))
    /// space. Bounded by `compareTailChars` cap on the caller side so this
    /// stays cheap even for long messages.
    private static func longestCommonSubstring(_ a: String, _ b: String) -> String {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if n == 0 || m == 0 { return "" }
        var prev = [Int](repeating: 0, count: m + 1)
        var curr = [Int](repeating: 0, count: m + 1)
        var bestLen = 0
        var bestEndA = 0
        for i in 1...n {
            for j in 1...m {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1] + 1
                    if curr[j] > bestLen {
                        bestLen = curr[j]
                        bestEndA = i
                    }
                } else {
                    curr[j] = 0
                }
            }
            swap(&prev, &curr)
            for k in 0...m { curr[k] = 0 }
        }
        guard bestLen > 0 else { return "" }
        let start = bestEndA - bestLen
        return String(aChars[start..<(start + bestLen)])
    }

    private static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s.replacingOccurrences(of: "\n", with: " ") }
        return String(s.prefix(max - 1)).replacingOccurrences(of: "\n", with: " ") + "…"
    }
}
