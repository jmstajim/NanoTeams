import XCTest

@testable import NanoTeams

/// `ModelTokenCleaner.stripTokensInTail` and its gate `tailMayCompleteToken` — the per-delta
/// decision in front of the strip, and the thin wrapper that acts on it.
///
/// Three obligations, and they need separate tests because they fail separately:
///   1. the wrapper must produce EXACTLY what stripping the whole buffer after every delta
///      produced (the shape it replaced),
///   2. the work the gate does must be linear in the stream, not quadratic, and
///   3. the gate's RAW-buffer contract, which `PromptImprovementDisplay` leans on: gate-silent
///      ⟹ `stripTokens(A + d) == stripTokens(A) + d`.
///
/// (2) is invisible in output — the pre-fix code was correct and merely slow — so it is
/// pinned through `_testGateWork` rather than through a rendered string (CLAUDE.md #62).
final class ModelTokenCleanerTailTests: XCTestCase {

    /// The behaviour being replaced: strip the WHOLE buffer after every delta.
    private func referenceAppend(_ deltas: [String]) -> String {
        var buffer = ""
        for delta in deltas {
            buffer += delta
            if ModelTokenCleaner.containsModelTokens(buffer) {
                buffer = ModelTokenCleaner.stripTokens(buffer)
            }
        }
        return buffer
    }

    private func tailAppend(_ deltas: [String]) -> String {
        var buffer = ""
        for delta in deltas {
            buffer += delta
            ModelTokenCleaner.stripTokensInTail(&buffer, newDeltaCount: delta.count)
        }
        return buffer
    }

    // MARK: - Equivalence

    /// RED: widen the gate's window to `newDeltaCount` (drop `+ maxTokenSpan - 1`) ->
    /// the split-sentinel vectors stop being stripped.
    func testTailStrip_matchesWholeBufferStrip_onSentinelsSplitAcrossDeltas() {
        let vectors: [[String]] = [
            ["Hello <|chan", "nel|> world"],
            ["a", "<", "|", "c", "h", "a", "n", "n", "e", "l", "|", ">", "b"],
            ["prefix <|end|", "> suffix"],
            ["<|channel|>leading"],
            ["trailing<|channel|>"],
            // A mangled opener the cleaner deliberately KEEPS (brace in span), then a
            // genuine sentinel after it — the second must still be stripped.
            ["<|tool_call{payload\n", "then <|channel|> tail"],
            // Newline in span — also kept.
            ["<|start\nmid|>", " rest"],
        ]
        for deltas in vectors {
            XCTAssertEqual(
                tailAppend(deltas), referenceAppend(deltas),
                "windowed gate diverged from whole-buffer strip for \(deltas)")
        }
    }

    /// The window may size the DECISION but must never scope the EDIT.
    ///
    /// `stripTokensInPlace` is a single forward pass whose cursor decides which opener
    /// pairs with which closer, and a deletion can pull two previously-distant tokens
    /// within `maxTokenSpan` of each other — creating a pair that no tail window contains.
    /// So a variant that strips only the window and splices the result back diverges from
    /// the behaviour being preserved.
    ///
    /// This vector exists because the ordinary split-sentinel vectors above do NOT
    /// discriminate that variant: measured, it passed every other assertion in this file.
    /// The vector was found by searching randomized token-dense inputs for the shortest
    /// disagreement — writing the test from the mechanism alone would have missed it.
    ///
    /// RED: strip `content[start...]` into a local and `replaceSubrange` it back instead
    /// of calling `stripTokensInPlace(&content)` -> this returns
    /// `"\n<|tool_call><|tool_call>\n"`.
    func testTailStrip_windowScopesTheDecisionOnly_notTheEdit() {
        let deltas = [
            "\n<|tool_call>",
            "<|tool_call><|tool_call>",
            "<|channel|>|><|tool_call>",
            "\n",
        ]
        XCTAssertEqual(tailAppend(deltas), referenceAppend(deltas))
        XCTAssertEqual(
            tailAppend(deltas), "\n<|tool_call>\n",
            "a deletion inside the window let an EARLIER opener reach a closer; only a "
                + "whole-buffer strip sees that pairing")
    }

    /// The window is sized off `maxTokenSpan`, so the interesting inputs are the spans
    /// either side of that bound. A span longer than the cap is KEPT by `isTokenSpan`;
    /// both spellings must agree about which side of the line each one falls on.
    ///
    /// RED: change `maxTokenSpan` without changing the window -> the 32-char span
    /// disagrees.
    func testTailStrip_matchesWholeBufferStrip_atTheTokenSpanBoundary() {
        // span = inner + 4 (`<|` + inner + `|>`); 32 is the cap, so 28/29 straddle it.
        for inner in [26, 27, 28, 29, 30] {
            let token = "<|" + String(repeating: "z", count: inner) + "|>"
            for splitAt in [1, 2, 3, token.count - 1] {
                let cut = token.index(token.startIndex, offsetBy: splitAt)
                let deltas = ["head ", String(token[..<cut]), String(token[cut...]), " tail"]
                XCTAssertEqual(
                    tailAppend(deltas), referenceAppend(deltas),
                    "span \(inner + 4), split at \(splitAt)")
            }
        }
    }

    /// Plain prose must survive byte-for-byte, trailing whitespace included — the strip
    /// is not licensed to trim while the stream is still arriving.
    func testTailStrip_leavesPlainContentUntouched() {
        var buffer = ""
        for delta in ["one ", "two ", "three  "] {
            buffer += delta
            ModelTokenCleaner.stripTokensInTail(&buffer, newDeltaCount: delta.count)
        }
        XCTAssertEqual(buffer, "one two three  ")
    }

    /// A `newDeltaCount` larger than the buffer (or negative) must clamp to the whole
    /// buffer rather than trap on an out-of-range index.
    ///
    /// RED: drop `limitedBy:` -> `index(_:offsetBy:)` traps past `startIndex`.
    func testTailStrip_deltaCountLargerThanBuffer_clampsInsteadOfTrapping() {
        var buffer = "<|channel|>x"
        ModelTokenCleaner.stripTokensInTail(&buffer, newDeltaCount: 10_000)
        XCTAssertEqual(buffer, "x")

        var negative = "<|channel|>y"
        ModelTokenCleaner.stripTokensInTail(&negative, newDeltaCount: -5)
        XCTAssertEqual(negative, "y")
    }

    // MARK: - Raw-buffer contract

    /// The second contract of `tailMayCompleteToken`, the one `PromptImprovementDisplay` leans
    /// on: asked about a RAW (never-stripped) buffer, `false` proves that stripping the whole
    /// buffer equals stripping the buffer-before-the-delta and appending the delta verbatim. That
    /// is what lets a caller keep `raw` and a DERIVED buffer and grow the derived one by
    /// `+= delta` on a silent gate.
    ///
    /// Hand pairs first (a kept long opener whose closer arrives; a split sentinel that must
    /// fire), then 5 000 seeded pairs from the sentinel alphabet; the gate must have been silent
    /// on at least 1 000 of them or the equality was never exercised.
    ///
    /// RED: drop `+ maxTokenSpan - 1` from the window → A = `"<|"` + 28 a's, d = `"|>"` reports
    /// false while `stripTokens(A + d)` is `""` and `stripTokens(A) + d` is `A + d`.
    func testTailMayCompleteToken_false_provesAppendOnlyStrip_onRawBuffer() {
        // A 44-char span is over `maxTokenSpan`: the strip KEEPS it, so both sides equal A + d.
        let longA = "<|" + String(repeating: "a", count: 40)
        XCTAssertFalse(ModelTokenCleaner.tailMayCompleteToken(longA + "|>", newDeltaCount: 2))
        XCTAssertEqual(ModelTokenCleaner.stripTokens(longA + "|>"), longA + "|>")
        XCTAssertEqual(ModelTokenCleaner.stripTokens(longA) + "|>", longA + "|>")
        // A 32-char span sits AT the cap and is deleted — the gate must fire for it.
        let capA = "<|" + String(repeating: "a", count: 28)
        XCTAssertTrue(ModelTokenCleaner.tailMayCompleteToken(capA + "|>", newDeltaCount: 2))
        XCTAssertEqual(ModelTokenCleaner.stripTokens(capA + "|>"), "")
        // A split sentinel must fire.
        XCTAssertTrue(ModelTokenCleaner.tailMayCompleteToken("x <|chan" + "nel|>", newDeltaCount: 5))

        let alphabet = [
            "<|channel|>", "<|", "|>", "<|tool_call>", "{", "\n", " ", "a", "aaaaaaaaaaaa",
            "<|start\nmid|>", "|", "<", ">",
        ]
        var rng = SeededGenerator(seed: 2026)
        var silent = 0
        for _ in 0..<5000 {
            var a = ""
            for _ in 0..<Int.random(in: 0...6, using: &rng) {
                a += alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]
            }
            var d = ""
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                d += alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]
            }
            guard !ModelTokenCleaner.tailMayCompleteToken(a + d, newDeltaCount: d.count) else { continue }
            silent += 1
            XCTAssertEqual(
                ModelTokenCleaner.stripTokens(a + d), ModelTokenCleaner.stripTokens(a) + d,
                "gate was silent but the delta changed the strip: A=\(a.debugDescription) "
                    + "d=\(d.debugDescription)")
        }
        XCTAssertGreaterThanOrEqual(silent, 1000, "anti-vacuum: the equality was barely exercised")
    }

    // MARK: - Work bound

    /// The defect this method exists for: the gate used to read the WHOLE buffer on every
    /// delta, so the characters it examined grew as Θ(N²/delta) across a stream. Measured
    /// before the fix: 25 050 000 characters scanned for a 100 000-character reply.
    ///
    /// The assertion is a RATIO, not a constant: it must survive a change to
    /// `uiFlushCharThreshold` or `maxTokenSpan`, and only a return to whole-buffer
    /// scanning breaks it.
    ///
    /// RED: gate on `containsModelTokens(content)` instead of the window -> work jumps
    /// from ~N to ~N²/delta and the assertion fails by two orders of magnitude.
    func testTailStrip_gateWorkIsLinearInTheStream_notQuadratic() {
        let deltaSize = 200
        let deltaCount = 500
        let total = deltaSize * deltaCount

        ModelTokenCleaner._testResetGateWork()
        var buffer = ""
        let delta = String(repeating: "a", count: deltaSize)
        for _ in 0..<deltaCount {
            buffer += delta
            ModelTokenCleaner.stripTokensInTail(&buffer, newDeltaCount: deltaSize)
        }
        let walked = ModelTokenCleaner._testGateWork()

        XCTAssertEqual(buffer.count, total, "sanity: the stream really was assembled")
        // Linear bound: every call reads its own delta plus a fixed overlap, so the total
        // is `total + deltaCount * maxTokenSpan`. 2x that leaves room for the constant
        // without leaving room for a whole-buffer scan (which would be ~50x total here).
        XCTAssertLessThan(
            walked, total * 2,
            "gate examined \(walked) characters for a \(total)-character stream — "
                + "that is whole-buffer scanning, not windowed")
        // Anti-vacuum: a gate that examines NOTHING would also pass the bound above, and
        // would mean the strip never runs at all.
        XCTAssertGreaterThanOrEqual(
            walked, total, "gate must still see every delta it was handed")
    }
}
