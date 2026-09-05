import XCTest

@testable import NanoTeams

/// `PromptImprovementDisplay` — the per-delta display pipeline of the improve stream.
///
/// Two obligations, pinned separately because they fail separately:
///   1. after EVERY `append`, `text` must equal the whole-buffer render of the raw buffer
///      (`rendered(stripTokens(raw))` — the shape it replaced, `displayText(accumulated)` on
///      every delta), and
///   2. the work it does must be linear in the stream, not quadratic.
///
/// (2) is invisible in output — the replaced code was correct and merely slow — so it is pinned
/// through the three `#if DEBUG` work counters (gate, strip, render), never wall-clock.
///
/// Not `@MainActor`: the display is a `nonisolated` value type.
final class PromptImprovementDisplayTests: XCTestCase {

    /// The invariant's right-hand side, spelled WITHOUT `append`: the behaviour being replaced was
    /// `displayText(accumulated)` — strip the whole buffer, then apply the fence rule. The
    /// equivalence and work tests compare `append`'s incremental `text` against THIS, so a
    /// mutation inside `append` cannot satisfy them by changing both sides at once (measured: with
    /// the oracle defined through `append`, dropping `|| !fence.isFinal` left every equivalence
    /// assertion green).
    private func reference(_ raw: String) -> String {
        PromptImprovementDisplay.rendered(ModelTokenCleaner.stripTokens(raw)).text
    }

    /// One `append` over the whole buffer — the single-shot use of the pipeline. It always takes
    /// the recompute branch (the window covers the whole buffer and the fence starts `.undecided`),
    /// so the eight transform tests below exercise `append` on the literals `displayText` used to.
    private func singleShot(_ raw: String) -> String {
        var display = PromptImprovementDisplay()
        display.append(raw)
        return display.text
    }

    // MARK: - Single-shot transform

    /// RED: skip `stripTokens` before `rendered` → this shows `"A<|channel|>B"`.
    func testDisplayText_stripsTokens() {
        XCTAssertEqual(singleShot("A<|channel|>B"), "AB")
    }

    /// RED: drop `lines.remove(at: index)` → the opening fence line stays visible.
    func testDisplayText_dropsOpeningFenceLine() {
        XCTAssertEqual(singleShot("```\nBody"), "Body")
        XCTAssertEqual(singleShot("```text\nBody"), "Body")
    }

    /// RED: start the fence search at line 0 only (drop the blank-skip loop) → `"\n  \n```\nBody"`
    /// is shown unchanged.
    func testDisplayText_dropsOpeningFenceAfterBlankLines() {
        XCTAssertEqual(singleShot("\n  \n```\nBody"), "\n  \nBody")
    }

    /// RED: remove the first non-blank line unconditionally → `"second line"` alone is shown.
    func testDisplayText_noFence_unchanged() {
        XCTAssertEqual(singleShot("Plain text\nsecond line"), "Plain text\nsecond line")
    }

    /// RED: test `"```".hasPrefix(head)` instead of `head.hasPrefix("```")` for hiding → `"``"`
    /// is hidden as if it were a fence.
    func testDisplayText_incompleteFencePrefix_untouched() {
        // "``" may still grow into a fence — shown as-is until it does.
        XCTAssertEqual(singleShot("``"), "``")
    }

    /// RED: remove EVERY fence line instead of the first non-blank one → the inner block's
    /// fences vanish.
    func testDisplayText_innerFenceNotFirstLine_preserved() {
        let input = "Use this:\n```\ncode\n```"
        XCTAssertEqual(singleShot(input), input)
    }

    /// RED: require a terminating "\n" before hiding the fence → `"```json"` is shown verbatim
    /// and the session would write it into the field.
    func testDisplayText_bareFenceOnly_returnsEmpty() {
        // Only an opening fence has arrived — nothing visible yet, so the
        // caller stays in `waitingForFirstDelta` (display is empty).
        XCTAssertEqual(singleShot("```"), "")
        XCTAssertEqual(singleShot("```json"), "")
    }

    /// RED: strip a dangling `<|…` tail as if it were a token → `"Body "` is shown.
    func testDisplayText_incompleteTokenMidStream_shownVerbatim() {
        // A half-arrived `<|` token has no closing `|>` yet — `stripTokens`
        // leaves it; it disappears once the token completes on a later delta.
        XCTAssertEqual(singleShot("Body <|chan"), "Body <|chan")
    }

    // MARK: - Fence state

    /// The decision state is what lets `append` stop recomputing: `.none` / `.hiddenClosed` are
    /// final, `.undecided` / `.hiddenOpen` are not.
    ///
    /// RED: compute `terminated` AFTER `lines.remove` → `"```\n"` and `"\n  \n```\nBody"` report
    /// `.hiddenOpen` instead of `.hiddenClosed`.
    /// RED: replace `"```".hasPrefix(head)` with `true` → `"``x"` reports `.undecided` instead of
    /// `.none`.
    func testRendered_reportsFenceState() {
        typealias D = PromptImprovementDisplay
        for undecided in ["", "\n  ", "``", "`` "] {
            let r = D.rendered(undecided)
            XCTAssertEqual(r.fence, .undecided, "\(undecided.debugDescription)")
            XCTAssertEqual(r.text, undecided, "\(undecided.debugDescription) is shown unchanged")
            XCTAssertFalse(r.fence.isFinal)
        }
        for decidedNone in ["``x", "`\nfoo", "Plain"] {
            let r = D.rendered(decidedNone)
            XCTAssertEqual(r.fence, .none, "\(decidedNone.debugDescription)")
            XCTAssertEqual(r.text, decidedNone)
            XCTAssertTrue(r.fence.isFinal)
        }
        XCTAssertEqual(D.rendered("```json").text, "")
        XCTAssertEqual(D.rendered("```json").fence, .hiddenOpen)
        XCTAssertEqual(D.rendered("\n  \n```").text, "\n  ")
        XCTAssertEqual(D.rendered("\n  \n```").fence, .hiddenOpen)
        XCTAssertFalse(D.OpeningFence.hiddenOpen.isFinal)

        XCTAssertEqual(D.rendered("```\n").text, "")
        XCTAssertEqual(D.rendered("```\n").fence, .hiddenClosed)
        XCTAssertEqual(D.rendered("\n  \n```\nBody").text, "\n  \nBody")
        XCTAssertEqual(D.rendered("\n  \n```\nBody").fence, .hiddenClosed)
        XCTAssertTrue(D.OpeningFence.hiddenClosed.isFinal)
    }

    // MARK: - Incremental == whole-buffer render

    /// Hand vectors, each chosen to cross a boundary the incremental path must respect: a
    /// sentinel split across deltas, a fence arriving one backtick at a time, a fence with its
    /// info string split, blank lines before the fence, a token inside the fence line, a kept
    /// opener followed by a real sentinel, trailing whitespace, CRLF, a no-break space before the
    /// fence — and the DISCRIMINATOR: an opener whose span is too long to delete, with a real
    /// sentinel inside it and its own `|>` arriving last. Re-stripping an already-stripped buffer
    /// deletes it (`<|` + 27 a's + `|>` is 31 chars once the inner token is gone); stripping the
    /// RAW buffer keeps it (the opener's FIRST closer makes a 34-char span). The field must show
    /// what a whole-buffer strip shows.
    ///
    /// RED: replace the recompute with the `StreamingPreviewManager` shape — `text += delta;
    /// ModelTokenCleaner.stripTokensInTail(&text, newDeltaCount: delta.count)` → the discriminator
    /// renders `""` instead of `"<|aaa…a|>"`.
    /// RED: drop `|| !fence.isFinal` from the recompute condition → the char-by-char fence vector
    /// shows `"```"` after its third delta where the whole-buffer render shows `""`.
    func testAppend_matchesWholeBufferRender_onHandVectors() {
        let longOpener = "<|" + String(repeating: "a", count: 27)
        let vectors: [[String]] = [
            ["Hello <|chan", "nel|> world"],
            ["`", "`", "`", "\n", "Body"],
            ["```js", "on\nBody"],
            ["\n  \n", "```", "\nBody"],
            ["```<|x|>\n", "Body"],
            ["<|tool_call>\n", "text <|channel|> more"],
            ["one ", "two  "],
            ["```\r\n", "Body"],
            ["\u{00A0}``", "`\nBody"],
            [longOpener + "<|e|>", "|>"],
        ]
        for deltas in vectors {
            var display = PromptImprovementDisplay()
            for (k, delta) in deltas.enumerated() {
                display.append(delta)
                let raw = deltas[...k].joined()
                XCTAssertEqual(display.raw, raw, "raw must be the untouched concatenation, \(deltas)")
                XCTAssertEqual(
                    display.text, reference(raw),
                    "incremental text diverged from the whole-buffer render after delta \(k) of \(deltas)")
            }
        }
        var discriminator = PromptImprovementDisplay()
        discriminator.append(longOpener + "<|e|>")
        discriminator.append("|>")
        XCTAssertEqual(
            discriminator.text, longOpener + "|>",
            "a whole-buffer strip KEEPS the long opener; only an incrementally-stripped buffer deletes it")
    }

    /// 3 000 seeded sequences over an alphabet of sentinels, partial sentinels, braces, line
    /// breaks (LF and CRLF), whitespace incl. a no-break space, and every backtick prefix of a
    /// fence — the classes the two gates (token window, fence finality) reason about.
    ///
    /// Anti-vacuum: the render work `append` did over the sweep must be STRICTLY less than the
    /// render work the oracle did — the oracle IS a per-delta whole-buffer render, so equality
    /// means `append` recomputed on every delta and the `text += delta` branch never ran. Measured
    /// per call (before/after each `append` and each `reference`), because the oracle shares the
    /// counter: a plain `_testRenderWork() < Σ raw.count` bound stays green under an unconditional
    /// recompute whenever a token was stripped.
    ///
    /// RED: gate on the SHOWN buffer (`tailMayCompleteToken(text, …)`) instead of `raw` → a prefix
    /// diverges within the first few hundred sequences.
    /// RED: drop `+ maxTokenSpan - 1` from the window → same.
    /// RED: recompute unconditionally in `append` (`if true || …`) → the equivalence holds, and the
    /// anti-vacuum fails with `append` render work == oracle render work.
    func testAppend_matchesWholeBufferRender_randomized() {
        let alphabet = [
            "<|channel|>", "<|", "|>", "<|tool_call>", "{", "\n", "\r\n", " ", "\t", "\u{00A0}",
            "`", "``", "```", "```json", "a", "Body",
        ]
        var appendRenderWork = 0
        var oracleRenderWork = 0
        for seed in 1...3000 {
            var rng = SeededGenerator(seed: UInt64(seed))
            let count = Int.random(in: 1...10, using: &rng)
            var deltas: [String] = []
            for _ in 0..<count {
                deltas.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)])
            }
            var display = PromptImprovementDisplay()
            for (k, delta) in deltas.enumerated() {
                let beforeAppend = PromptImprovementDisplay._testRenderWork()
                display.append(delta)
                let beforeOracle = PromptImprovementDisplay._testRenderWork()
                let expected = reference(display.raw)
                appendRenderWork += beforeOracle - beforeAppend
                oracleRenderWork += PromptImprovementDisplay._testRenderWork() - beforeOracle
                if display.text != expected {
                    XCTFail(
                        "seed \(seed), after delta \(k) of \(deltas.map(\.debugDescription)): "
                            + "incremental \(display.text.debugDescription) != whole-buffer "
                            + "\(expected.debugDescription)")
                    return
                }
            }
        }
        XCTAssertGreaterThan(oracleRenderWork, 0, "fixture: the oracle rendered something")
        XCTAssertLessThan(
            appendRenderWork, oracleRenderWork,
            "anti-vacuum: `append` rendered \(appendRenderWork) characters against the oracle's "
                + "\(oracleRenderWork) — equal means the incremental branch never ran over the sweep")
    }

    // MARK: - Work bound

    /// The defect this type exists for: `displayText(accumulated)` stripped and re-rendered the
    /// WHOLE buffer on every delta — Θ(N²) across the improve stream. All three counters are
    /// asserted, because each mutation moves a different one: an unconditional recompute inflates
    /// strip + render while the gate stays linear; a whole-buffer gate inflates the gate while the
    /// render stays linear.
    ///
    /// The bounds are RATIOS against the stream length, so a change to `maxTokenSpan` survives
    /// them and only a return to whole-buffer work breaks them.
    ///
    /// RED: recompute unconditionally in `append` (drop the `if`) → `_testStripWork` and
    /// `_testRenderWork` ≈ 25 000 000 ≫ total.
    /// RED: gate with `containsModelTokens(raw)` instead of `tailMayCompleteToken` →
    /// `_testGateWork` ≈ 25 000 000 ≫ 2×total (measured; and because `raw` keeps the completed
    /// sentinel forever, that gate never goes silent again, so strip/render follow at ≈ 18 800 000).
    func testAppend_workIsLinearInTheStream_notQuadratic() {
        let deltaSize = 200
        let deltaCount = 500
        let total = deltaSize * deltaCount
        let sentinelAt = 249   // "…<|chan" ends delta 249, "nel|>…" opens delta 250 (0-based)

        var deltas: [String] = []
        for i in 0..<deltaCount {
            let delta: String
            switch i {
            case 0:
                let lead = "Rewrite this:\n"
                delta = lead + String(repeating: "a", count: deltaSize - lead.count)
            case sentinelAt:
                let tail = "<|chan"
                delta = String(repeating: "a", count: deltaSize - tail.count) + tail
            case sentinelAt + 1:
                let head = "nel|>"
                delta = head + String(repeating: "a", count: deltaSize - head.count)
            default:
                delta = String(repeating: "a", count: deltaSize)
            }
            XCTAssertEqual(delta.count, deltaSize, "fixture: every delta is exactly \(deltaSize) chars")
            deltas.append(delta)
        }
        let expectedRawCount = deltas.reduce(0) { $0 + $1.count }
        XCTAssertEqual(expectedRawCount, total, "fixture arithmetic")

        ModelTokenCleaner._testResetGateWork()
        ModelTokenCleaner._testResetStripWork()
        PromptImprovementDisplay._testResetRenderWork()
        var display = PromptImprovementDisplay()
        for delta in deltas {
            display.append(delta)
        }
        let gate = ModelTokenCleaner._testGateWork()
        let strip = ModelTokenCleaner._testStripWork()
        let render = PromptImprovementDisplay._testRenderWork()

        XCTAssertEqual(display.raw.count, expectedRawCount, "sanity: the stream really was assembled")
        XCTAssertEqual(display.text, reference(display.raw))
        XCTAssertFalse(display.text.contains("<|channel|>"), "the split sentinel was stripped")

        // Gate: every delta plus a fixed overlap — linear; whole-buffer would be ~250x total.
        XCTAssertLessThan(
            gate, total * 2,
            "gate examined \(gate) characters for a \(total)-character stream — whole-buffer scanning")
        XCTAssertGreaterThanOrEqual(gate, total, "gate must still see every delta it was handed")
        // Strip: once on delta 0 (fence undecided → decided) and once at the completed sentinel
        // (~50 000 chars). A per-delta whole-buffer strip would be ~250x total.
        XCTAssertLessThan(
            strip, total,
            "strip was handed \(strip) characters — it must not see the stream even once over")
        XCTAssertGreaterThanOrEqual(strip, deltaSize, "anti-vacuum: the first delta MUST be stripped")
        // Render: same cadence as the strip.
        XCTAssertLessThan(
            render, total,
            "render was handed \(render) characters — it must not see the stream even once over")
        XCTAssertGreaterThanOrEqual(render, deltaSize, "anti-vacuum: the first delta MUST be rendered")
    }
}
