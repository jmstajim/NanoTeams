import Foundation
#if DEBUG
import Synchronization
#endif

/// Utility for cleaning model-specific tokens that appear in LLM responses.
///
/// Some models (gpt-oss in LM Studio, DeepSeek) emit internal tokens like `<|channel|>`,
/// `<|constrain|>`, `<|message|>` as plain text when their tool calling mechanism fails
/// or in edge cases. This utility strips those tokens from content.
///
/// **The unit is the Unicode scalar, and the markers are matched byte for byte.** `<|`, `|>`,
/// `{` and every line break are ASCII, so a byte scan finds each one wherever it sits — inside a
/// grapheme cluster included — and cannot start or end inside a multi-byte scalar. Foundation's
/// `range(of:)` / `contains` match composed character SEQUENCES instead, and until 2026-09-14 the
/// strip used them: a combining mark right after a token (`<|x|>` + U+0301) fused with the `>` into
/// one cluster, the closer became unfindable and the sentinel stayed in the turn — while the
/// incremental gate, reading bytes, had proven the mark could not matter and the preview had already
/// dropped the token. The span cap and the gate's window count scalars for the same reason:
/// `String.distance` rounds a mid-cluster index down, so a span measured in characters and a window
/// measured in scalars disagree on exactly the input that straddles the cap. One unit for the
/// search, the cap and the window, or the gate's proof is about a different string than the strip's.
/// Pinned by `ModelTokenCleanerTailTests`.
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
        return c.trimmingCharacters(in: edgeWhitespace)
    }

    /// The whitespace `clean` trims off both ends — and therefore the ONE set every seam that
    /// must agree with commit reads: `StreamingPreviewManager` holds a delta's trailing run and
    /// drops a leading one by it, `LLMExecutionService.stripLeadingWhitespace` /
    /// `stripSurroundingWhitespace` trim `assistantCollected` by it. Foundation's set, not
    /// Unicode's `White_Space`: it contains U+200B ZERO WIDTH SPACE (a `Cf`) and not U+200D or
    /// U+FEFF. Until 2026-09-14 the service trimmed by `Character.isWhitespace`, which differs
    /// on exactly those scalars, so a reply consisting of one U+200B was "content" to the
    /// service and nothing to `clean` — and the tokens-only nudge fired with no token in sight.
    static let edgeWhitespace = CharacterSet.whitespacesAndNewlines

    /// Strip `<|...|>` tokens without trimming whitespace.
    ///
    /// Use during streaming where trailing whitespace must be preserved
    /// because more content is still arriving.
    static func stripTokens(_ content: String) -> String {
        var c = content
        stripTokensInPlace(&c)
        return c
    }

    /// The gate in front of every incremental strip: decides in `O(delta)` whether the last
    /// `newDeltaCount` SCALARS could have completed a token at all. Stripping the whole buffer
    /// after every delta is `Θ(N²/delta)` across a stream, because the DECISION alone cost two
    /// whole-buffer searches every time.
    ///
    /// **The contract, on a RAW (never-stripped) buffer** — the shape `IncrementalStrip` owns for
    /// both of its callers: `false` proves `stripTokens(raw) == stripTokens(rawBeforeDelta) + delta`,
    /// so a value derived from the buffer grows by the delta verbatim. Two facts prove it, checked
    /// in order:
    /// 1. A delta without the byte `>` cannot end a closer. `stripTokensInPlace` pairs each opener
    ///    with the first `|>` after it; every `|>` then lies before the delta and the bytes between
    ///    any opener and its closer are what they were — so every pairing, every span verdict and
    ///    the no-closer `break` stand, and the delta rides through verbatim. One byte scan of the
    ///    delta, silent for whitespace and for most prose. It is what keeps a span the cleaner KEEPS
    ///    in the last window (`<|tool_call{…|>`) from re-running the whole-buffer strip on the
    ///    inter-call `\n`s of a native tool-call turn; a prose delta that does carry a `>` (`a -> b`)
    ///    goes on to fact 2, and there the WINDOW bounds the re-fire — the kept span leaves it
    ///    `maxTokenSpan` scalars on.
    /// 2. Otherwise the window. A span this cleaner will delete is at most `maxTokenSpan` scalars
    ///    (`isTokenSpan` refuses anything longer, or anything carrying `{` / a line break). A span
    ///    COMPLETED by this delta has its closing `>` inside the delta, so its first scalar sits at
    ///    distance `≤ newDeltaCount + maxTokenSpan - 2` from the end — inside a window of
    ///    `newDeltaCount + maxTokenSpan - 1`. Every opener outside the window either had its first
    ///    `|>` before the delta (same decision) or now pairs with one that makes its span >
    ///    `maxTokenSpan` — KEPT verbatim, exactly how the unresolved opener was rendered before the
    ///    delta. Same sizing argument `StreamMarkerWindow` makes for the Harmony needle
    ///    (`Services/LLM/StreamMarkerWindow.swift`); one rule, two implementations, because
    ///    `Utilities` may not depend on `Services`.
    /// Pinned by `ModelTokenCleanerTailTests.testTailMayCompleteToken_false_provesAppendOnlyStrip_onRawBuffer`.
    ///
    /// **The window is the GATE, not the edit.** `stripTokensInPlace` is a single forward pass whose
    /// cursor position decides which opener pairs with which closer, so a pass started mid-buffer
    /// can pair differently (`<|<|` + `>|<|tool_call>|>` + `<|tool_call>` + `>`: the whole pass
    /// gives the closer at scalar 3 to the opener at 0 and deletes `<|<|>`; a pass from the
    /// window's edge at 1 cannot see that `<`, pairs the opener at 2 with the closer at 18, and —
    /// spliced back onto the raw prefix — returns the `<` at 0 the stream deletes); and a deletion can
    /// pull two previously-distant tokens within `maxTokenSpan` of each other, creating a pair no
    /// tail window contains. Measured: a windowed EDIT diverged from the whole-buffer behaviour on
    /// 3 of 40 009 randomized token-dense inputs. So the window only decides WHETHER to strip; the
    /// strip itself is the whole RAW buffer.
    ///
    /// Cost: `O(delta)` per call — fact 1 reads the delta once, fact 2 the delta plus a fixed
    /// overlap; the caller pays one whole-buffer pass only on the calls where a token boundary
    /// actually lands in the tail, units of times per stream instead of every time.
    /// `newDeltaCount ≤ 0` is no new scalars and answers `false`; a count past the buffer's
    /// start clamps to the whole buffer.
    static func tailMayCompleteToken(_ content: String, newDeltaCount: Int) -> Bool {
        guard newDeltaCount > 0 else { return false }
        let scalars = content.unicodeScalars
        let deltaStart = scalars.index(
            scalars.endIndex, offsetBy: -newDeltaCount, limitedBy: scalars.startIndex
        ) ?? scalars.startIndex
        // Fact 1.
        guard carriesCloserByte(content.utf8[deltaStart...]) else { return false }
        // Fact 2.
        let windowLength = newDeltaCount + maxTokenSpan - 1
        let start = scalars.index(
            scalars.endIndex, offsetBy: -windowLength, limitedBy: scalars.startIndex
        ) ?? scalars.startIndex
        // Asked on a slice of the buffer's byte view so the common (no-token) delta allocates nothing.
        return containsTokenPair(content.utf8[start...])
    }

    // MARK: - The incremental shape

    /// A raw stream and the ONE incremental way to keep its token-stripped value: re-strip the RAW
    /// bytes when a delta may have completed a token, extend the derived value by the delta when
    /// the gate proves it could not. Owned here because both incremental writers — the streaming
    /// preview (`StreamingPreviewManager`, one per live step) and the improve field
    /// (`PromptImprovementDisplay`) — need exactly this, and the shape that re-strips its OWN OUTPUT
    /// instead is wrong: `stripTokensInPlace` is one forward pass, and a pass over an
    /// already-stripped buffer plus a delta is not a pass over the stream. A deletion pulls a `<`
    /// and a `|` together into a token the next pass removes (`<<|x|>` then `|y|>`: the stream
    /// strips to `<|y|>`, the re-stripped buffer to nothing), and a kept opener's next closer moves
    /// within a span once the token between them is gone (`<|tool_call><|` + 25 a + `|>`, then
    /// ` ok|>`: the stream keeps `<|tool_call> ok|>`, the re-stripped buffer deletes it). Commit
    /// persists `clean(stream)`, so the re-stripping preview put one value on screen and another
    /// in the turn on exactly those streams; until the evening of 2026-09-14 the divergence was
    /// documented in its tests rather than closed.
    ///
    /// Invariant after every `append`: the caller's derived value equals `stripTokens(raw)`. Cost:
    /// `O(delta)` on the common path (the gate), one whole-buffer pass on the delta that completes
    /// a token — units of times per stream — and the raw copy, the reply's length once.
    nonisolated struct IncrementalStrip {
        /// Every delta since the last reset, verbatim — after a replace, the replaced value and
        /// every delta since.
        private(set) var raw = ""

        init() {}

        /// A replacement: `raw` becomes `content`, the stream's new truth (the Harmony rewind).
        /// Seed it with the RAW value, never with a stripped copy: `stripTokens` is not idempotent
        /// (`<<|x|>|y|>` strips to `<|y|>`, which strips to nothing), so a pre-stripped seed is a
        /// different stream than the one commit strips.
        init(raw: String) { self.raw = raw }

        /// Appends `delta`. Returns `stripTokens(raw)` when the delta may have completed a token —
        /// the caller REPLACES its derived value with it — and `nil` when the gate proves
        /// `stripTokens(raw) == previous + delta`, so the caller appends the delta verbatim.
        mutating func append(_ delta: String) -> String? {
            raw += delta
            guard tailMayCompleteToken(raw, newDeltaCount: delta.unicodeScalars.count) else { return nil }
            return stripTokens(raw)
        }
    }

    // MARK: - Private

    /// Longest span a `<|…|>` token may occupy, in Unicode scalars. A sentinel is a short label;
    /// the longest this app has seen is `<|channel|>` at 11. The cap only ever declines to delete.
    /// Read by `tailMayCompleteToken` to size its window — the two must move together, and they
    /// must count the same unit.
    private static let maxTokenSpan = 32

    /// The two markers, as the byte pairs they are.
    private static let opener = (UInt8(ascii: "<"), UInt8(ascii: "|"))
    private static let closer = (UInt8(ascii: "|"), UInt8(ascii: ">"))

    /// The line breaks `isTokenSpan` refuses — the same scalars `Character.isNewline` names (LF,
    /// VT, FF, CR, NEL, LS, PS), read per scalar so a mark fused onto one cannot hide it.
    private static let lineBreaks = CharacterSet.newlines

    /// Single forward pass building a fresh string — deliberately NOT in-place
    /// `removeSubrange`: skipping a non-token `<|` requires carrying a cursor across the
    /// mutation, and `String.Index` is invalidated by it. Searches on the byte view and copies
    /// by `String` slices between the indices it finds: those are scalar-aligned by construction
    /// (both bytes of a marker are ASCII), and a slice between scalar-aligned indices is
    /// byte-exact even when it opens or closes inside a grapheme cluster.
    private static func stripTokensInPlace(_ content: inout String) {
        let bytes = content.utf8
        #if DEBUG
        _stripWork.wrappingAdd(bytes.count, ordering: .relaxed)
        #endif
        var next = firstPair(opener, in: bytes, from: bytes.startIndex)
        guard next != nil else { return }

        var result = ""
        result.reserveCapacity(bytes.count)
        var cursor = content.startIndex

        while let start = next {
            // No closer at all from here on: the original behaviour is to leave the
            // remainder untouched, and a partially-arrived token mid-stream is exactly
            // that case.
            guard let end = firstPair(closer, in: bytes, from: start.upperBound) else { break }

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
            next = firstPair(opener, in: bytes, from: cursor)
        }

        result.append(contentsOf: content[cursor...])
        content = result
    }

    /// The first occurrence of `pair` at or after `from`, as a range of indices — scalar-aligned by
    /// construction, since both bytes are ASCII. Generic over the byte collection so the gate can
    /// ask about a slice of the buffer's UTF-8 view without materializing it.
    private static func firstPair<Bytes: Collection<UInt8>>(
        _ pair: (UInt8, UInt8), in bytes: Bytes, from: Bytes.Index
    ) -> Range<Bytes.Index>? {
        var index = from
        while let hit = bytes[index...].firstIndex(of: pair.0) {
            let next = bytes.index(after: hit)
            guard next < bytes.endIndex else { return nil }
            if bytes[next] == pair.1 { return hit..<bytes.index(after: next) }
            index = next
        }
        return nil
    }

    /// Whether `[from, to)` is short enough and clean enough to be a sentinel, decided in
    /// at most `maxTokenSpan + 1` steps over the scalar view.
    ///
    /// The length being compared against the cap is unbounded: an opening `<|` with no closer
    /// nearby spans the rest of the buffer, so answering a question decided within the first
    /// 33 scalars must not cost a walk of the whole remainder, once per opener.
    ///
    /// This bounds the ANSWER, not the search. The closer search above is still an unbounded
    /// forward scan per iteration, so a buffer of k openers sharing one distant closer remains
    /// O(k·n) — measurably cheaper, not asymptotically better. Left as is: the observed defect is
    /// k≈1 per reply (2 of 30, one mangled opener each), and closing it means bounding that
    /// search too, which changes which spans pair with which closer.
    private static func isTokenSpan(
        _ content: String, from: String.Index, to: String.Index
    ) -> Bool {
        let scalars = content.unicodeScalars
        var index = from
        var scanned = 0
        while index < to {
            if scanned >= maxTokenSpan { return false }
            let scalar = scalars[index]
            if scalar == "{" || lineBreaks.contains(scalar) { return false }
            index = scalars.index(after: index)
            scanned += 1
        }
        return true
    }

    /// Check if content contains model tokens that should be cleaned.
    ///
    /// - Parameter content: The raw LLM response content
    /// - Returns: True if the content contains `<|...|>` style tokens
    ///
    /// Generic over `StringProtocol` so a caller can ask about a `Substring` WITHOUT
    /// materializing it — the gate must not cost what it gates (CLAUDE.md #106).
    static func containsModelTokens(_ content: some StringProtocol) -> Bool {
        containsTokenPair(content.utf8)
    }

    /// Fact 2's scan and `containsModelTokens`' body, with the work counter INSIDE it: whatever
    /// bytes this is handed are what it reports (CLAUDE.md #62).
    private static func containsTokenPair(_ bytes: some Collection<UInt8>) -> Bool {
        #if DEBUG
        _gateWork.wrappingAdd(bytes.count, ordering: .relaxed)
        #endif
        return firstPair(opener, in: bytes, from: bytes.startIndex) != nil
            && firstPair(closer, in: bytes, from: bytes.startIndex) != nil
    }

    /// Fact 1's scan, counter inside for the same reason: a regression that hands it the whole
    /// buffer instead of the delta is reported as exactly that — the no-`>` fixture of the work
    /// pin never reaches fact 2, so this counter is the only thing that can see it.
    private static func carriesCloserByte(_ bytes: some Collection<UInt8>) -> Bool {
        #if DEBUG
        _gateWork.wrappingAdd(bytes.count, ordering: .relaxed)
        #endif
        return bytes.contains(closer.1)
    }

    #if DEBUG
    /// Work-bound seam for `ModelTokenCleanerTailTests` and `PromptImprovementDisplayTests`:
    /// bytes this GATE has been asked about since the last reset — fact 1's scan of the delta
    /// plus, on a delta carrying `>`, fact 2's scan of the window (so a call that reaches fact 2
    /// counts its delta twice, plus the fixed overlap). Same shape as
    /// `WorkFolderContextPromptPlanner._testScalarWork`.
    ///
    /// It lives inside each scan, not beside its call site, and that placement is the whole
    /// point: the defect being pinned is a scan being handed the WHOLE BUFFER instead of a
    /// delta-sized slice, and a counter next to the call would keep reporting the slice's
    /// length no matter what the call was actually given. (Measured: with the counter outside,
    /// reverting the gate to `containsModelTokens(content)` left every assertion green —
    /// CLAUDE.md #62, a pin on a consequence.)
    ///
    /// A regression here is invisible in OUTPUT — the whole-buffer gate returns exactly
    /// the same answers, just Θ(N²/delta) slower — which is why the bound is asserted at
    /// all rather than left to a behavioural test.
    private static let _gateWork = Atomic<Int>(0)
    static func _testGateWork() -> Int { _gateWork.load(ordering: .relaxed) }
    static func _testResetGateWork() { _gateWork.store(0, ordering: .relaxed) }

    /// Work-bound seam for the STRIP: bytes handed to `stripTokensInPlace` since the last reset,
    /// counted BEFORE its first opener search — that search is itself an O(buffer) pass and is
    /// what a per-delta caller pays on every recompute, whether or not a token is found. Same
    /// placement as `_gateWork`: inside the work, not beside a call site — a counter next to the
    /// call would pin a consequence, not the decision (CLAUDE.md #62; measured on `_gateWork`) —
    /// so a caller that hands the whole buffer to the strip on every delta is reported as exactly
    /// that. Read by `PromptImprovementDisplayTests`.
    private static let _stripWork = Atomic<Int>(0)
    static func _testStripWork() -> Int { _stripWork.load(ordering: .relaxed) }
    static func _testResetStripWork() { _stripWork.store(0, ordering: .relaxed) }
    #endif
}
