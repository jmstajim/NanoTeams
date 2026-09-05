import Foundation
#if DEBUG
import Synchronization
#endif

/// Utility for cleaning model-specific tokens that appear in LLM responses.
///
/// Some models (gpt-oss in LM Studio, DeepSeek) emit internal tokens like `<|channel|>`,
/// `<|constrain|>`, `<|message|>` as plain text when their tool calling mechanism fails
/// or in edge cases. This utility strips those tokens from content.
nonisolated enum ModelTokenCleaner {
    /// Strip model-specific tokens (e.g. `<|channel|>`, `<|constrain|>`) from content.
    ///
    /// Removes all `<|...|>` style tokens, which are internal to the model and
    /// should never appear in the final output to the user or in tool arguments.
    ///
    /// - Parameter content: The raw LLM response content
    /// - Returns: Content with all `<|...|>` tokens removed, trimmed of whitespace
    static func clean(_ content: String) -> String {
        var c = content
        stripTokensInPlace(&c)
        return c.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip `<|...|>` tokens without trimming whitespace.
    ///
    /// Use during streaming where trailing whitespace must be preserved
    /// because more content is still arriving.
    static func stripTokens(_ content: String) -> String {
        var c = content
        stripTokensInPlace(&c)
        return c
    }

    /// The PER-DELTA counterpart of `stripTokens`, for a buffer an incremental writer grows:
    /// a thin wrapper — `tailMayCompleteToken` decides in `O(delta)` whether the last
    /// `newDeltaCount` characters could have completed a token, and only then the whole
    /// buffer pays `stripTokensInPlace`. Byte-identical to stripping the whole buffer after
    /// every delta; the window sizing and why it is the GATE and not the EDIT live on the gate.
    static func stripTokensInTail(_ content: inout String, newDeltaCount: Int) {
        guard tailMayCompleteToken(content, newDeltaCount: newDeltaCount) else { return }
        stripTokensInPlace(&content)
    }

    /// The gate of `stripTokensInTail`, exposed for a caller that keeps the RAW buffer and a buffer
    /// DERIVED from it (`PromptImprovementDisplay`). Decides in `O(delta)` whether the last
    /// `newDeltaCount` characters could have completed a token at all. Stripping the whole buffer
    /// after every delta is `Θ(N²/delta)` across a stream, because the DECISION alone cost two
    /// whole-buffer searches every time.
    ///
    /// **The window is the GATE, not the edit.** A span this cleaner will delete is at most
    /// `maxTokenSpan` characters (`isTokenSpan` refuses anything longer, or anything carrying `{`
    /// / a newline). A span COMPLETED by this delta has its closing `>` inside the delta, so its
    /// first character sits at distance `≤ newDeltaCount + maxTokenSpan - 2` from the end —
    /// inside a window of `newDeltaCount + maxTokenSpan - 1`. Same sizing argument
    /// `StreamMarkerWindow` makes for the Harmony needle (`Services/LLM/StreamMarkerWindow.swift`);
    /// one rule, two implementations, because `Utilities` may not depend on `Services`.
    ///
    /// Two contracts, both O(delta):
    /// 1. On an incrementally-stripped buffer (the `stripTokensInTail` contract): `false` proves
    ///    a whole-buffer strip would change nothing.
    /// 2. On a RAW buffer: `false` proves `stripTokens(raw) == stripTokens(rawBeforeDelta) + delta`.
    ///    Every opener outside the window either already had its first `|>` before the delta (same
    ///    decision) or now pairs with one that makes its span > `maxTokenSpan` — KEPT verbatim,
    ///    exactly how the unresolved opener was rendered before the delta. Pinned by
    ///    `ModelTokenCleanerTailTests.testTailMayCompleteToken_false_provesAppendOnlyStrip_onRawBuffer`.
    ///
    /// **Stripping only the window would NOT be equivalent, and this is why the gate is all the
    /// window does.** `stripTokensInPlace` is a single forward pass whose cursor position decides
    /// which opener pairs with which closer, so a pass started mid-buffer can pair differently;
    /// and a deletion can pull two previously-distant tokens within `maxTokenSpan` of each other,
    /// creating a pair no tail window contains. Measured: a windowed EDIT diverged from the
    /// whole-buffer behaviour on 3 of 40 009 randomized token-dense inputs. So the window only
    /// decides WHETHER to strip; the strip itself stays whole-buffer and byte-identical to what
    /// ran before. Re-measured after that change: **0 divergences in 400 009 cases**, generated
    /// from an alphabet of sentinels, partial sentinels, braces, newlines and multi-scalar
    /// graphemes.
    ///
    /// Cost: `O(delta)` per call; the caller pays one whole-buffer pass only on the calls where a
    /// token boundary actually lands in the tail — units of times per stream instead of every
    /// time. The buffer-long `<|` this cleaner deliberately KEEPS (a mangled `<|tool_call{`)
    /// leaves the window as soon as the reply grows past it, which is what stops it re-firing the
    /// strip forever.
    static func tailMayCompleteToken(_ content: String, newDeltaCount: Int) -> Bool {
        let windowLength = max(newDeltaCount, 0) + maxTokenSpan - 1
        let start = content.index(
            content.endIndex, offsetBy: -windowLength, limitedBy: content.startIndex
        ) ?? content.startIndex
        // Tested on the Substring so the common (no-token) delta allocates nothing.
        return containsModelTokens(content[start...])
    }

    // MARK: - Private

    /// Longest span a `<|…|>` token may occupy. A sentinel is a short label; the longest
    /// this app has seen is `<|channel|>` at 11. The cap only ever declines to delete.
    /// Read by `tailMayCompleteToken` to size its window — the two must move together.
    private static let maxTokenSpan = 32

    /// Single forward pass building a fresh string — deliberately NOT in-place
    /// `removeSubrange`: skipping a non-token `<|` requires carrying a cursor across the
    /// mutation, and `String.Index` is invalidated by it.
    private static func stripTokensInPlace(_ content: inout String) {
        #if DEBUG
        _stripWork.wrappingAdd(content.count, ordering: .relaxed)
        #endif
        guard content.contains("<|") else { return }

        var result = ""
        result.reserveCapacity(content.count)
        var cursor = content.startIndex

        while let start = content.range(of: "<|", range: cursor..<content.endIndex) {
            // No closer at all from here on: the original behaviour is to leave the
            // remainder untouched, and a partially-arrived token mid-stream is exactly
            // that case.
            guard let end = content.range(of: "|>", range: start.upperBound..<content.endIndex)
            else { break }

            // An opening `<|` whose own `|>` is missing (observed: gemma-4-e4b's
            // `<|tool_call>`) otherwise pairs with the NEXT token's closer and deletes
            // everything in between — which is how a whole `create_artifact` payload
            // vanished from a turn, leaving the model told it had submitted nothing.
            // A real sentinel is one short token: no payload brace, no line break.
            if isTokenSpan(content, from: start.lowerBound, to: end.upperBound) {
                result.append(contentsOf: content[cursor..<start.lowerBound])
                cursor = end.upperBound
            } else {
                // Keep the `<|` verbatim and resume after it, so a later genuine token in
                // the same string is still stripped — and so `HarmonySentinelNormalizer`
                // can still recognise the mangled sentinel it leaves behind.
                result.append(contentsOf: content[cursor..<start.upperBound])
                cursor = start.upperBound
            }
        }

        result.append(contentsOf: content[cursor...])
        content = result
    }

    /// Whether `[from, to)` is short enough and clean enough to be a sentinel, decided in
    /// at most `maxTokenSpan + 1` steps.
    ///
    /// `Substring.count` is O(length), and the length being compared against a 32-char
    /// bound is unbounded: an opening `<|` with no closer nearby spans the rest of the
    /// buffer, so answering a question decided within the first 33 characters cost a walk
    /// of the whole remainder, once per opener.
    ///
    /// This bounds the ANSWER, not the search. The `range(of: "|>")` above is still an
    /// unbounded forward scan per iteration, so a buffer of k openers sharing one distant
    /// closer remains O(k·n) — measurably cheaper, not asymptotically better. Left as is:
    /// the observed defect is k≈1 per reply (2 of 30, one mangled opener each), and closing
    /// it means bounding that search too, which changes which spans pair with which closer.
    private static func isTokenSpan(
        _ content: String, from: String.Index, to: String.Index
    ) -> Bool {
        var index = from
        var scanned = 0
        while index < to {
            if scanned >= maxTokenSpan { return false }
            let character = content[index]
            if character == "{" || character.isNewline { return false }
            index = content.index(after: index)
            scanned += 1
        }
        return true
    }

    /// Check if content contains model tokens that should be cleaned.
    ///
    /// - Parameter content: The raw LLM response content
    /// - Returns: True if the content contains `<|...|>` style tokens
    ///
    /// Generic over `StringProtocol` so `tailMayCompleteToken` can ask about its window
    /// WITHOUT materializing it — the gate must not cost what it gates (CLAUDE.md #106).
    static func containsModelTokens(_ content: some StringProtocol) -> Bool {
        #if DEBUG
        _gateWork.wrappingAdd(content.count, ordering: .relaxed)
        #endif
        return content.contains("<|") && content.contains("|>")
    }

    #if DEBUG
    /// Work-bound seam for `ModelTokenCleanerTailTests` and `PromptImprovementDisplayTests`:
    /// characters this GATE has been asked about since the last reset. Same shape as
    /// `WorkFolderContextPromptPlanner._testScalarWork`.
    ///
    /// It lives inside the gate, not beside its call site, and that placement is the whole
    /// point: the defect being pinned is the gate being handed the WHOLE BUFFER instead of
    /// a delta-sized window, and a counter next to the call would keep reporting the
    /// window's length no matter what the call was actually given. (Measured: with the
    /// counter outside, reverting the gate to `containsModelTokens(content)` left every
    /// assertion green — CLAUDE.md #62, a pin on a consequence.)
    ///
    /// A regression here is invisible in OUTPUT — the whole-buffer gate returns exactly
    /// the same answers, just Θ(N²/delta) slower — which is why the bound is asserted at
    /// all rather than left to a behavioural test.
    private static let _gateWork = Atomic<Int>(0)
    static func _testGateWork() -> Int { _gateWork.load(ordering: .relaxed) }
    static func _testResetGateWork() { _gateWork.store(0, ordering: .relaxed) }

    /// Work-bound seam for the STRIP: characters handed to `stripTokensInPlace` since the last
    /// reset, counted BEFORE its `contains("<|")` guard — that guard is itself an O(buffer) pass
    /// and is what a per-delta caller pays on every recompute, whether or not a token is found.
    /// Same placement as `_gateWork`: inside the work, not beside a call site — a counter next
    /// to the call would pin a consequence, not the decision (CLAUDE.md #62; measured on
    /// `_gateWork`) — so a caller that hands the whole buffer to the strip on every delta is
    /// reported as exactly that. Read by `PromptImprovementDisplayTests`.
    private static let _stripWork = Atomic<Int>(0)
    static func _testStripWork() -> Int { _stripWork.load(ordering: .relaxed) }
    static func _testResetStripWork() { _stripWork.store(0, ordering: .relaxed) }
    #endif
}
