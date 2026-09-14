import XCTest

@testable import NanoTeams

/// `ModelTokenCleaner.IncrementalStrip` and its gate `tailMayCompleteToken` — the per-delta
/// decision in front of the strip, and the one incremental shape built on it.
///
/// Four obligations, and they need separate tests because they fail separately:
///   1. the value derived through the shape must equal `stripTokens(raw)` after EVERY delta — the
///      value commit persists — including the two streams on which re-stripping the derived value
///      instead diverges (a pulled-together token; a kept opener reaching a later closer) and the
///      one on which a windowed EDIT diverges (a pairing that crosses the window's edge),
///   2. the cleaner's unit is the Unicode scalar, matched byte for byte: a combining mark fused
///      onto a `>` hides nothing, and the span cap counts what the window counts,
///   3. the work the gate does must be linear in the stream, not quadratic — on each of its two
///      facts, and
///   4. the gate's RAW-buffer contract, the one the shape leans on: gate-silent ⟹
///      `stripTokens(A + d) == stripTokens(A) + d`.
///
/// (3) is invisible in output — the pre-fix code was correct and merely slow — so it is
/// pinned through `_testGateWork` rather than through a rendered string (CLAUDE.md #62).
final class ModelTokenCleanerTailTests: XCTestCase {

    /// The oracle: the whole raw stream stripped once, as commit does.
    private func reference(_ deltas: [String]) -> String {
        ModelTokenCleaner.stripTokens(deltas.joined())
    }

    /// The shape under test: a derived value grown by the delta on a silent gate, replaced by
    /// the whole-buffer strip otherwise — checked against the oracle after EVERY delta, not
    /// only at the end, so a divergence names the delta that caused it. Compared as BYTES:
    /// `==` on `String` is canonical equivalence, and the unit under test is the scalar.
    private func incremental(
        _ deltas: [String], file: StaticString = #filePath, line: UInt = #line
    ) -> String {
        var stream = ModelTokenCleaner.IncrementalStrip()
        var derived = ""
        var prefix = ""
        for delta in deltas {
            prefix += delta
            if let stripped = stream.append(delta) { derived = stripped } else { derived += delta }
            XCTAssertEqual(stream.raw, prefix, "raw must be the untouched stream", file: file, line: line)
            let expected = ModelTokenCleaner.stripTokens(prefix)
            XCTAssertTrue(
                Array(derived.utf8) == Array(expected.utf8),
                "diverged after \(delta.debugDescription) over \(prefix.debugDescription): "
                    + "\(derived.debugDescription) ≠ \(expected.debugDescription)",
                file: file, line: line)
        }
        return derived
    }

    private func assertBytes(
        _ actual: String, _ expected: String, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            Array(actual.utf8) == Array(expected.utf8),
            "\(actual.debugDescription) ≠ \(expected.debugDescription) \(message)", file: file, line: line)
    }

    // MARK: - Equivalence

    /// RED: widen the gate's window to `newDeltaCount` (drop `+ maxTokenSpan - 1`) ->
    /// the split-sentinel vectors stop being stripped.
    func testIncremental_matchesTheStreamStrip_onSentinelsSplitAcrossDeltas() {
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
                incremental(deltas), reference(deltas),
                "the incremental shape diverged from the stream's strip for \(deltas)")
        }
    }

    /// The two streams on which the previous shape — strip the DERIVED value again after each
    /// delta — diverged from the stream's own strip. Both are what commit persists.
    ///
    /// RED: keep a derived buffer in the struct and return `stripTokens(derived + delta)` — the
    /// shape the preview had until 2026-09-14, and the `incremental` helper's own
    /// `derived = stripTokens(derived + delta)` — → `""` and `""` here.
    func testIncremental_pulledTogetherToken_isWhatTheStreamStripsTo() {
        // Deleting `<|x|>` pulls `<` and `|y|>` together; the one pass over the stream keeps them.
        let deltas = ["<<|x|>", "|y|>"]
        XCTAssertEqual(incremental(deltas), "<|y|>")
        XCTAssertEqual(reference(deltas), "<|y|>")
    }

    func testIncremental_keptOpenerDoesNotReachALaterCloserThroughADeletion() {
        // `<|tool_call>`'s FIRST closer is the inner token's, 41 scalars on — kept; the inner
        // token goes. Re-stripping that result would pair the opener with ` ok|>` at 17
        // scalars and delete the whole thing.
        let deltas = ["<|tool_call><|" + String(repeating: "a", count: 25) + "|>", " ok|>"]
        XCTAssertEqual(incremental(deltas), "<|tool_call> ok|>")
        XCTAssertEqual(reference(deltas), "<|tool_call> ok|>")
    }

    /// The pairing is the STREAM's, decided by one forward pass over the raw bytes — never a
    /// window's. The whole pass gives the closer at scalar 3 to the opener at 0 (`<|<|>` goes),
    /// then the opener at 6 the closer at 18. A pass started at the window's edge — scalar 1, once
    /// the final `>` sizes a 32-scalar window over a 33-scalar stream — cannot see the `<` at 0: it
    /// pairs the opener at 2 with the closer at 18 (the one at 3 overlaps its own `|`), and on its
    /// own returns the same string; spliced back onto the raw prefix it brings back the `<` the
    /// stream deleted. Found by searching randomized token-dense inputs for the shortest
    /// disagreement between a windowed edit and the whole-stream strip.
    ///
    /// RED: strip only the window and splice it onto the raw prefix (`raw[..<start] +
    /// stripTokens(raw[start...])`) → `"<|<|tool_call>>"`.
    /// RED, the coarser shape of the same mutation: a token that ended outside the window comes
    /// back — the second vector shows `<|a|>` again.
    func testIncremental_pairingIsTheStreamsOwn_notTheWindows() {
        let deltas = ["<|<|", ">|<|tool_call>|>", "<|tool_call>", ">"]
        XCTAssertEqual(incremental(deltas), reference(deltas))
        XCTAssertEqual(
            incremental(deltas), "|<|tool_call>>",
            "opener 0 takes the closer at 3; the second token goes whole; the last opener has no closer and is kept")

        let farApart = ["<|a|>", String(repeating: "x", count: 40), "<|b|>"]
        XCTAssertEqual(incremental(farApart), String(repeating: "x", count: 40))
    }

    /// The window is sized off `maxTokenSpan`, so the interesting inputs are the spans
    /// either side of that bound. A span longer than the cap is KEPT by `isTokenSpan`;
    /// both spellings must agree about which side of the line each one falls on.
    ///
    /// RED: change `maxTokenSpan` without changing the window -> the 32-scalar span
    /// disagrees.
    func testIncremental_matchesTheStreamStrip_atTheTokenSpanBoundary() {
        // span = inner + 4 (`<|` + inner + `|>`); 32 is the cap, so 28/29 straddle it.
        for inner in [26, 27, 28, 29, 30] {
            let token = "<|" + String(repeating: "z", count: inner) + "|>"
            for splitAt in [1, 2, 3, token.count - 1] {
                let cut = token.index(token.startIndex, offsetBy: splitAt)
                let deltas = ["head ", String(token[..<cut]), String(token[cut...]), " tail"]
                XCTAssertEqual(
                    incremental(deltas), reference(deltas),
                    "span \(inner + 4), split at \(splitAt)")
            }
        }
    }

    /// Plain prose must survive byte-for-byte, trailing whitespace included — the strip
    /// is not licensed to trim while the stream is still arriving.
    func testIncremental_leavesPlainContentUntouched() {
        XCTAssertEqual(incremental(["one ", "two ", "three  "]), "one two three  ")
    }

    /// A span the cleaner KEEPS (`{` inside) sitting in the last window used to fire the gate —
    /// and the whole-buffer strip behind it — on every later delta while the span was still
    /// inside the window: the inter-call `\n`s of a native tool-call turn, one per call. A delta
    /// without `>` cannot end a closer (fact 1 of the gate), so nothing fires until a `>` arrives.
    ///
    /// RED: drop the `>` scan from `tailMayCompleteToken` → the first 17 newlines each re-run the
    /// strip (the 15-scalar span is inside the 32-scalar window until then); the first
    /// `XCTAssertNil` fails and `_testStripWork` reads 17 whole-buffer passes.
    func testIncremental_keptSpanInTheWindow_doesNotRestripOnEveryLaterDelta() {
        var stream = ModelTokenCleaner.IncrementalStrip()
        XCTAssertNotNil(stream.append("<|tool_call{x|>"), "a `>` arrived: the gate fires")
        XCTAssertEqual(ModelTokenCleaner.stripTokens(stream.raw), "<|tool_call{x|>", "kept: brace in span")
        ModelTokenCleaner._testResetStripWork()
        for _ in 0..<1000 {
            XCTAssertNil(stream.append("\n"), "no `>`: append-only, proven without the window")
        }
        XCTAssertNil(stream.append("prose without a closer"))
        XCTAssertEqual(ModelTokenCleaner._testStripWork(), 0, "the kept span must not re-run the strip")
        XCTAssertEqual(stream.append("<|end|>"), "<|tool_call{x|>" + String(repeating: "\n", count: 1000) + "prose without a closer")
    }

    // MARK: - The unit: scalars, matched byte for byte

    /// A combining mark right after a token fuses with its `>` into one grapheme cluster. Until
    /// 2026-09-14 the strip searched with Foundation's `range(of:)`, which matches composed
    /// character sequences, so `|>` was unfindable and the sentinel stayed — while the gate,
    /// reading bytes, had proven the mark could not matter and the derived value had dropped it:
    /// the live bubble and the committed turn disagreed on `<|x|>` + U+0301. Same for a mark on
    /// the opener's `|`, a variation selector, a zero-width joiner.
    ///
    /// RED: search `<|` / `|>` with `range(of:)` / `contains` on the `String` instead of the
    /// byte pairs → `stripTokens("<|x|>\u{301}")` is `"<|x|>\u{301}"` and the first vector
    /// diverges after its second delta.
    func testStrip_findsAMarkerInsideAGraphemeCluster_soFact1StaysSound() {
        let vectors: [[String]] = [
            ["<|x|>", "\u{301}"],
            ["<|channel|>", "\u{FE0F}x"],
            ["<|channel|>", "\u{200D}"],
            ["<|x|>\u{301}", " tail"],
            ["a<|", "\u{301}b|>c"],
        ]
        for deltas in vectors {
            XCTAssertEqual(incremental(deltas), reference(deltas), "\(deltas)")
        }
        assertBytes(ModelTokenCleaner.stripTokens("<|x|>\u{301}"), "\u{301}")
        assertBytes(ModelTokenCleaner.stripTokens("a<|\u{301}b|>c"), "ac", "a mark on the opener's `|` hides nothing either")
        XCTAssertTrue(ModelTokenCleaner.containsModelTokens("<|x|>\u{301}"))
    }

    /// `isTokenSpan` reads scalars for the same reason: `{` + U+0301 is one `Character`, not
    /// equal to `"{"`, and a payload brace wearing a mark would have let the span pass as a token.
    ///
    /// RED: compare `content[index] == "{"` on the `Character` view → the span is deleted.
    func testStrip_refusesABraceWithACombiningMarkOnIt() {
        let span = "<|a{\u{301}b|>"
        assertBytes(ModelTokenCleaner.stripTokens(span), span, "kept: brace in span")
    }

    /// The cap and the window count the same unit. Fifteen `e` + U+0301 are 30 scalars in 15
    /// characters: with the markers, a 34-scalar span the cleaner KEEPS, and a 33-scalar window
    /// that starts one scalar past its opener — the gate is silent, and the derived value keeps it
    /// too. A span counted in characters (19 ≤ 32) would delete what the window could not see.
    ///
    /// RED: count `isTokenSpan`'s steps on the `Character` view → the first vector diverges: the
    /// strip deletes the span, the shape keeps it.
    func testStrip_spanCapCountsScalars_asTheWindowDoes() {
        let over = String(repeating: "e\u{301}", count: 15)
        XCTAssertEqual(incremental(["<|" + over, "|>"]), reference(["<|" + over, "|>"]))
        assertBytes(incremental(["<|" + over, "|>"]), "<|" + over + "|>", "34 scalars: over the cap, kept")
        let atCap = String(repeating: "e\u{301}", count: 14)
        assertBytes(incremental(["<|" + atCap, "|>"]), "", "32 scalars: at the cap, deleted")
    }

    // MARK: - The gate's edges

    /// A `newDeltaCount` past the buffer's start clamps to the whole buffer rather than trapping
    /// on an out-of-range index; zero or negative is "no new scalars" and cannot have
    /// completed anything.
    ///
    /// RED: drop `limitedBy:` -> `index(_:offsetBy:)` traps past `startIndex`.
    func testTailMayCompleteToken_deltaCountOutsideTheBuffer_clampsInsteadOfTrapping() {
        XCTAssertTrue(ModelTokenCleaner.tailMayCompleteToken("<|channel|>x", newDeltaCount: 10_000))
        XCTAssertFalse(ModelTokenCleaner.tailMayCompleteToken("<|channel|>x", newDeltaCount: 0))
        XCTAssertFalse(ModelTokenCleaner.tailMayCompleteToken("<|channel|>x", newDeltaCount: -5))
        XCTAssertFalse(ModelTokenCleaner.tailMayCompleteToken("", newDeltaCount: 3))
    }

    // MARK: - Raw-buffer contract

    /// The contract of `tailMayCompleteToken`, the one `IncrementalStrip` leans on: asked about a
    /// RAW (never-stripped) buffer, `false` proves that stripping the whole buffer equals stripping
    /// the buffer-before-the-delta and appending the delta verbatim. That is what lets a caller
    /// keep `raw` and a DERIVED buffer and grow the derived one by `+= delta` on a silent gate.
    ///
    /// Hand pairs first (a kept long opener whose closer arrives; a split sentinel that must
    /// fire; a delta without `>`, silent whatever the window holds), then 5 000 seeded pairs from
    /// the sentinel alphabet — bare marks and decomposed text included, so a delta that fuses
    /// onto the buffer's last scalar is exercised; the gate must have been silent on at least
    /// 1 000 of them or the equality was never exercised. Compared as bytes.
    ///
    /// RED: drop `+ maxTokenSpan - 1` from the window → A = `"<|"` + 28 a's, d = `"|>"` reports
    /// false while `stripTokens(A + d)` is `""` and `stripTokens(A) + d` is `A + d`.
    /// RED: scan the delta for `|` instead of `>` → `"x <|channel|" + ">"` reports false while
    /// the delta completed the sentinel.
    /// RED: search the markers by `Character` again → A = `"<|x|>"`, d = `"\u{301}"` is silent
    /// while the strip of `A + d` keeps the token.
    func testTailMayCompleteToken_false_provesAppendOnlyStrip_onRawBuffer() {
        // A 44-scalar span is over `maxTokenSpan`: the strip KEEPS it, so both sides equal A + d.
        let longA = "<|" + String(repeating: "a", count: 40)
        XCTAssertFalse(ModelTokenCleaner.tailMayCompleteToken(longA + "|>", newDeltaCount: 2))
        XCTAssertEqual(ModelTokenCleaner.stripTokens(longA + "|>"), longA + "|>")
        XCTAssertEqual(ModelTokenCleaner.stripTokens(longA) + "|>", longA + "|>")
        // A 32-scalar span sits AT the cap and is deleted — the gate must fire for it.
        let capA = "<|" + String(repeating: "a", count: 28)
        XCTAssertTrue(ModelTokenCleaner.tailMayCompleteToken(capA + "|>", newDeltaCount: 2))
        XCTAssertEqual(ModelTokenCleaner.stripTokens(capA + "|>"), "")
        // A split sentinel must fire.
        XCTAssertTrue(ModelTokenCleaner.tailMayCompleteToken("x <|chan" + "nel|>", newDeltaCount: 5))
        // A delta without `>` is silent with a sentinel's whole body in the window — and the `>`
        // that closes it fires on its own.
        XCTAssertFalse(ModelTokenCleaner.tailMayCompleteToken("x <|chan" + "nel|", newDeltaCount: 4))
        XCTAssertTrue(ModelTokenCleaner.tailMayCompleteToken("x <|channel|" + ">", newDeltaCount: 1))

        let alphabet = [
            "<|channel|>", "<|", "|>", "<|tool_call>", "{", "\n", " ", "a", "aaaaaaaaaaaa",
            "<|start\nmid|>", "|", "<", ">", "\u{301}", "e\u{301}",
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
            guard !ModelTokenCleaner.tailMayCompleteToken(a + d, newDeltaCount: d.unicodeScalars.count) else { continue }
            silent += 1
            assertBytes(
                ModelTokenCleaner.stripTokens(a + d), ModelTokenCleaner.stripTokens(a) + d,
                "— gate was silent but the delta changed the strip: A=\(a.debugDescription) d=\(d.debugDescription)")
        }
        XCTAssertGreaterThanOrEqual(silent, 1000, "anti-vacuum: the equality was barely exercised")
    }

    // MARK: - Work bound

    /// The defect this method exists for: the gate used to read the WHOLE buffer on every
    /// delta, so the characters it examined grew as Θ(N²/delta) across a stream. Measured
    /// before the fix: 25 050 000 characters scanned for a 100 000-character reply.
    ///
    /// Two arms, one per fact, because each fact has its own scan and its own way of regressing.
    /// The counter sits INSIDE each scan (CLAUDE.md #62), so it reports whatever the scan was
    /// handed: a fixture without `>` exercises fact 1 alone (work ≈ Σ delta), a fixture whose
    /// EVERY delta ends in a `>` that closes nothing exercises fact 2 on every call (work ≈
    /// Σ (delta + delta + maxTokenSpan − 1)). The assertions are RATIOS, not constants: they
    /// survive a change to the delta size or `maxTokenSpan`; only a return to whole-buffer
    /// scanning breaks them.
    ///
    /// RED (fact 1): scan `content.utf8` for `>` instead of the delta's slice → the first arm
    /// reads ≈ 25 000 000 bytes, two orders of magnitude over its bound.
    /// RED (fact 2): `windowLength = content.unicodeScalars.count`, or `containsModelTokens(content)`
    /// after the `>` guard → the second arm reads ≈ 25 000 000 while the first stays green — it
    /// never reaches the window, which is why it cannot be the only arm.
    func testIncremental_gateWorkIsLinearInTheStream_onBothFacts() {
        let deltaSize = 200
        let deltaCount = 500
        let total = deltaSize * deltaCount

        // Arm 1: no `>` anywhere — fact 1 answers every call.
        ModelTokenCleaner._testResetGateWork()
        var stream = ModelTokenCleaner.IncrementalStrip()
        var derived = ""
        let plain = String(repeating: "a", count: deltaSize)
        for _ in 0..<deltaCount {
            if let stripped = stream.append(plain) { derived = stripped } else { derived += plain }
        }
        let fact1 = ModelTokenCleaner._testGateWork()
        XCTAssertEqual(derived.count, total, "sanity: the stream really was assembled")
        XCTAssertLessThan(
            fact1, total * 2,
            "fact 1 examined \(fact1) bytes for a \(total)-byte stream — that is whole-buffer scanning, not a delta scan")
        XCTAssertGreaterThanOrEqual(fact1, total, "fact 1 must still see every delta it was handed")

        // Arm 2: every delta ends in a bare `>` — fact 2's window runs on every call.
        ModelTokenCleaner._testResetGateWork()
        stream = ModelTokenCleaner.IncrementalStrip()
        derived = ""
        let closing = String(repeating: "a", count: deltaSize - 1) + ">"
        for _ in 0..<deltaCount {
            if let stripped = stream.append(closing) { derived = stripped } else { derived += closing }
        }
        let fact2 = ModelTokenCleaner._testGateWork()
        XCTAssertEqual(derived.count, total, "sanity: nothing was stripped — a bare `>` closes nothing")
        XCTAssertLessThan(
            fact2, total * 3,
            "fact 2 examined \(fact2) bytes for a \(total)-byte stream — the window is not delta-sized")
        XCTAssertGreaterThanOrEqual(
            fact2, total * 2, "anti-vacuum: every call must read its delta twice — once per fact")
    }
}
