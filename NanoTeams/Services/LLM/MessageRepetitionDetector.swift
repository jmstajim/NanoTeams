import Foundation

/// Stateless detector for pathologically repetitive LLM output. Used by
/// `DelegationLoopWatcher` to auto-trigger Pause-and-Decide on a delegated
/// child team that's stuck in a loop ("Oh wait Oh wait Oh wait...", same
/// strategic message regenerated each iteration, same tool spammed every
/// turn, etc.).
///
/// Four detection modes:
///  - `detectWithinMessage(_:)` — finds the longest substring that repeats
///    `minRepeats+` times consecutively in the message content. Catches
///    single-message loops both in finalized content and in mid-stream
///    thinking buffers (since reasoning models can loop in their thinking
///    phase without ever committing to disk).
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

    // MARK: - Within-message

    /// Scans the tail of `text` for any non-trivial substring that repeats
    /// `minRepeats+` times consecutively. Returns the longest such substring's
    /// match (longer matches are higher-signal — a 30-char block repeated
    /// 5× is a much stronger loop indicator than a 5-char run).
    ///
    /// Performance: O(tailLen² / minRepeats) per call. Throttle this from
    /// `DelegationLoopWatcher` to once every few seconds during streaming.
    static func detectWithinMessage(
        _ text: String,
        minSubstringChars: Int = 8,
        maxSubstringChars: Int = 200,
        minRepeats: Int = 5,
        tailWindowChars: Int = 2_000
    ) -> Match? {
        // Trim leading/trailing whitespace so the window analysis isn't
        // dominated by padding. Operate on a tail window because loops grow
        // from the end — the head is usually fine prefix content.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minSubstringChars * minRepeats else { return nil }

        let chars = Array(trimmed.suffix(tailWindowChars))
        let n = chars.count
        let upperLen = min(maxSubstringChars, n / minRepeats)
        guard upperLen >= minSubstringChars else { return nil }

        // Try lengths from longest to shortest — first match wins, biased
        // toward higher-signal detections.
        for L in stride(from: upperLen, through: minSubstringChars, by: -1) {
            // The candidate window must end at or before n - L*minRepeats.
            // We sweep starting offsets right-to-left so we land on the
            // most recent loop (the "live" tail), which is what surfaced
            // the issue to the user.
            let lastStart = n - L * minRepeats
            guard lastStart >= 0 else { continue }
            for start in stride(from: lastStart, through: 0, by: -1) {
                if matchesSubstantive(chars: chars, start: start, length: L, repeats: minRepeats) {
                    let substring = String(chars[start..<(start + L)])
                    let count = countConsecutiveRepeats(chars: chars, start: start, length: L)
                    return Match(
                        substring: substring,
                        repeatCount: count,
                        diagnostic: makeDiagnostic(substring: substring, repeats: count)
                    )
                }
            }
        }
        return nil
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
    /// the caller (typically `DelegationLoopWatcher.considerToolCallSequence`)
    /// is responsible for filtering out tool calls already accounted for by
    /// a prior fire (`createdAt` cutoff against the watcher's last-trigger
    /// timestamp), so the same persisted history doesn't re-fire after
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

    /// Verifies that the substring [start, start+L) repeats exactly the
    /// next (repeats-1) blocks consecutively. Also rejects substrings that
    /// are entirely whitespace / punctuation / single-char (those generate
    /// noise — e.g. a long run of `"-"` or `". "` is not a useful loop signal).
    private static func matchesSubstantive(
        chars: [Character],
        start: Int,
        length L: Int,
        repeats: Int
    ) -> Bool {
        for r in 1..<repeats {
            for offset in 0..<L {
                let a = chars[start + offset]
                let b = chars[start + r * L + offset]
                if a != b { return false }
            }
        }
        // Reject substantively empty (all same char or all whitespace).
        var seenDistinctNonWhitespace = 0
        var firstChar: Character? = nil
        var allSame = true
        for offset in 0..<L {
            let c = chars[start + offset]
            if !c.isWhitespace && !c.isPunctuation { seenDistinctNonWhitespace += 1 }
            if firstChar == nil { firstChar = c } else if c != firstChar { allSame = false }
        }
        if allSame { return false }
        if seenDistinctNonWhitespace < 2 { return false }
        return true
    }

    private static func countConsecutiveRepeats(chars: [Character], start: Int, length L: Int) -> Int {
        var count = 1
        var idx = start + L
        while idx + L <= chars.count {
            for offset in 0..<L {
                if chars[start + offset] != chars[idx + offset] { return count }
            }
            count += 1
            idx += L
        }
        return count
    }

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
