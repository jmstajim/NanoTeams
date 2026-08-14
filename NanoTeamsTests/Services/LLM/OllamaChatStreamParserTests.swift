import XCTest

@testable import NanoTeams

/// NDJSON stream parsing for the Ollama `/api/chat` endpoint + the
/// `<think>` tag splitter that re-routes inline reasoning to the thinking
/// channel for models whose templates Ollama doesn't parse server-side.
final class OllamaChatStreamParserTests: XCTestCase {

    var parser: OllamaChatStreamParser!

    override func setUp() {
        super.setUp()
        parser = OllamaChatStreamParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Basic NDJSON chunks

    func testContentDeltaLine() {
        let events = parser.parse(
            line: #"{"model":"m","message":{"role":"assistant","content":"Hello"},"done":false}"#)
        XCTAssertEqual(events, [.contentDelta("Hello")])
    }

    func testThinkingFieldLine_routesToThinking() {
        let events = parser.parse(
            line: #"{"model":"m","message":{"role":"assistant","content":"","thinking":"hmm"},"done":false}"#)
        XCTAssertEqual(events, [.thinkingDelta("hmm")])
    }

    func testThinkingAndContentInOneChunk_emitsBoth() {
        let events = parser.parse(
            line: #"{"message":{"thinking":"t","content":"c"},"done":false}"#)
        XCTAssertEqual(events, [.thinkingDelta("t"), .contentDelta("c")])
    }

    func testDoneLineWithCounts_emitsUsage() {
        let events = parser.parse(
            line: #"{"model":"m","done":true,"done_reason":"stop","prompt_eval_count":120,"eval_count":45}"#)
        XCTAssertEqual(events, [.chatEnd(usage: TokenUsage(inputTokens: 120, outputTokens: 45), prefill: nil)])
    }

    func testDoneLineWithoutCounts_emitsNilUsage() {
        let events = parser.parse(line: #"{"model":"m","done":true}"#)
        XCTAssertEqual(events, [.chatEnd(usage: nil, prefill: nil)])
    }

    func testDoneLineWithTrailingContent_emitsContentThenEnd() {
        let events = parser.parse(
            line: #"{"message":{"content":"bye"},"done":true,"prompt_eval_count":1,"eval_count":2}"#)
        XCTAssertEqual(events, [
            .contentDelta("bye"),
            .chatEnd(usage: TokenUsage(inputTokens: 1, outputTokens: 2), prefill: nil),
        ])
    }

    func testErrorLine() {
        let events = parser.parse(line: #"{"error":"model \"x\" not found, try pulling it first"}"#)
        XCTAssertEqual(events, [.error("model \"x\" not found, try pulling it first")])
    }

    func testBlankLine_skipped() {
        XCTAssertEqual(parser.parse(line: "   "), [])
    }

    func testMalformedLine_skipped() {
        XCTAssertEqual(parser.parse(line: "not json at all"), [])
    }

    func testEmptyContentAndNoThinking_noEvents() {
        XCTAssertEqual(parser.parse(line: #"{"message":{"content":""},"done":false}"#), [])
    }

    // MARK: - Inline <think> routing

    func testLeadingThinkBlock_routedToThinking() {
        var events = parser.parse(line: #"{"message":{"content":"<think>reasoning"},"done":false}"#)
        XCTAssertEqual(events, [.thinkingDelta("reasoning")])
        events = parser.parse(line: #"{"message":{"content":" more</think>answer"},"done":false}"#)
        XCTAssertEqual(events, [.thinkingDelta(" more"), .contentDelta("answer")])
    }

    func testThinkTagSplitAcrossChunks() {
        // "<th" + "ink>abc</th" + "ink>ok"
        XCTAssertEqual(parser.parse(line: #"{"message":{"content":"<th"},"done":false}"#), [])
        XCTAssertEqual(
            parser.parse(line: #"{"message":{"content":"ink>abc</th"},"done":false}"#),
            [.thinkingDelta("abc")])
        XCTAssertEqual(
            parser.parse(line: #"{"message":{"content":"ink>ok"},"done":false}"#),
            [.contentDelta("ok")])
    }

    func testLeadingWhitespaceBeforeThink_stillRecognized() {
        let events = parser.parse(line: #"{"message":{"content":"\n<think>r</think>a"},"done":false}"#)
        XCTAssertEqual(events, [.thinkingDelta("r"), .contentDelta("\na")])
    }

    func testThinkAfterRealContent_staysContent() {
        // Once content has flowed, a literal <think> is prose/code — never
        // re-routed (protects Harmony envelopes from being split mid-JSON).
        XCTAssertEqual(
            parser.parse(line: #"{"message":{"content":"answer "},"done":false}"#),
            [.contentDelta("answer ")])
        XCTAssertEqual(
            parser.parse(line: #"{"message":{"content":"<think>literal</think>"},"done":false}"#),
            [.contentDelta("<think>literal</think>")])
    }

    func testUnclosedThink_doneLineFlushesAsThinking() {
        XCTAssertEqual(
            parser.parse(line: #"{"message":{"content":"<think>never closed"},"done":false}"#),
            [.thinkingDelta("never closed")])
        // The stream ends mid-think: the held-back text (none here) plus the
        // end event — reasoning already routed, nothing lost.
        let events = parser.parse(line: #"{"done":true,"prompt_eval_count":5,"eval_count":6}"#)
        XCTAssertEqual(events, [.chatEnd(usage: TokenUsage(inputTokens: 5, outputTokens: 6), prefill: nil)])
    }

    func testPartialTagAtTransportEnd_finalizeEmitsItVerbatim() {
        // Stream dies while "<thi" is still a viable tag prefix — finalize
        // must surface it rather than swallow it.
        XCTAssertEqual(parser.parse(line: #"{"message":{"content":"<thi"},"done":false}"#), [])
        XCTAssertEqual(parser.finalize(), [.contentDelta("<thi")])
    }

    func testPartialCloseTagHeldThenCompleted() {
        XCTAssertEqual(
            parser.parse(line: #"{"message":{"content":"<think>r</"},"done":false}"#),
            [.thinkingDelta("r")])
        XCTAssertEqual(
            parser.parse(line: #"{"message":{"content":"think>done"},"done":false}"#),
            [.contentDelta("done")])
    }

    func testFinalizeAfterCleanStream_isEmpty() {
        _ = parser.parse(line: #"{"message":{"content":"hi"},"done":false}"#)
        _ = parser.parse(line: #"{"done":true}"#)
        XCTAssertEqual(parser.finalize(), [])
    }

    // MARK: - NDJSON shape corners

    func testFinalize_isIdempotent() {
        _ = parser.parse(line: #"{"message":{"content":"<thi"},"done":false}"#)
        XCTAssertEqual(parser.finalize(), [.contentDelta("<thi")])
        XCTAssertEqual(parser.finalize(), [], "second finalize must not re-emit")
    }

    func testDoneLineWithThinkingField_emitsThinkingBeforeEnd() {
        let events = parser.parse(
            line: #"{"message":{"thinking":"last thought"},"done":true,"prompt_eval_count":1,"eval_count":2}"#)
        XCTAssertEqual(events, [
            .thinkingDelta("last thought"),
            .chatEnd(usage: TokenUsage(inputTokens: 1, outputTokens: 2), prefill: nil),
        ])
    }

    func testLineWithoutMessageKey_notDone_noEvents() {
        XCTAssertEqual(parser.parse(line: #"{"model":"m","created_at":"2026-07-23T22:00:00Z"}"#), [])
    }

    func testPromptEvalCountOnly_usageWithZeroOutput() {
        let events = parser.parse(line: #"{"done":true,"prompt_eval_count":77}"#)
        XCTAssertEqual(events, [.chatEnd(usage: TokenUsage(inputTokens: 77, outputTokens: 0), prefill: nil)])
    }

    func testEvalCountOnly_usageWithZeroInput() {
        let events = parser.parse(line: #"{"done":true,"eval_count":9}"#)
        XCTAssertEqual(events, [.chatEnd(usage: TokenUsage(inputTokens: 0, outputTokens: 9), prefill: nil)])
    }

    func testCRLFLineEnding_trimmedBeforeDecode() {
        let events = parser.parse(line: "{\"message\":{\"content\":\"x\"},\"done\":false}\r")
        XCTAssertEqual(events, [.contentDelta("x")])
    }

    func testUnicodeContent_survivesIntact() {
        let events = parser.parse(
            line: #"{"message":{"content":"привет 🚀 → done"},"done":false}"#)
        XCTAssertEqual(events, [.contentDelta("привет 🚀 → done")])
    }

    func testEmptyErrorString_stillAnErrorEvent() {
        // An empty error message is still a server-declared failure — it must
        // not be silently absorbed as a no-op line.
        XCTAssertEqual(parser.parse(line: #"{"error":""}"#), [.error("")])
    }

    func testJSONArrayLine_skippedNotCrashed() {
        XCTAssertEqual(parser.parse(line: #"[1,2,3]"#), [])
    }
}

// MARK: - ThinkTagSplitter unit corners

final class ThinkTagSplitterTests: XCTestCase {

    var splitter: ThinkTagSplitter!

    override func setUp() {
        super.setUp()
        splitter = ThinkTagSplitter()
    }

    override func tearDown() {
        splitter = nil
        super.tearDown()
    }

    func testNoTags_passThrough() {
        let out = splitter.feed("plain text")
        XCTAssertEqual(out, ThinkTagSplitter.Output(content: "plain text", thinking: ""))
    }

    func testWholeBlockInOneChunk() {
        let out = splitter.feed("<think>abc</think>xyz")
        XCTAssertEqual(out, ThinkTagSplitter.Output(content: "xyz", thinking: "abc"))
    }

    func testAngleBracketProseNotAPrefix_emitsImmediately() {
        let out = splitter.feed("<div>html</div>")
        XCTAssertEqual(out.content, "<div>html</div>")
        XCTAssertEqual(out.thinking, "")
    }

    func testSingleAngleBracketHeldThenReleased() {
        var out = splitter.feed("<")
        XCTAssertEqual(out, ThinkTagSplitter.Output())
        out = splitter.feed("hello")
        // "<h" is not a prefix of "<think>" past "<"… "<h" IS a prefix? No —
        // "<think>" starts "<t", so "<hello" is emitted whole.
        XCTAssertEqual(out.content, "<hello")
    }

    func testLiteralThinkAfterContent_inTheSAMEChunk_staysContent() {
        // Chunk framing must not change semantics: the same bytes split
        // across two feeds are pinned by testThinkAfterRealContent_staysContent
        // (in the parser suite) — one coalesced chunk must behave identically.
        let out = splitter.feed("Here is the file content: <think>internal note</think> end.")
        XCTAssertEqual(out.thinking, "")
        XCTAssertEqual(out.content, "Here is the file content: <think>internal note</think> end.")
    }

    func testLiteralThinkInsideHarmonyEnvelope_oneChunk_neverSplit() {
        _ = splitter.feed("<think>plan</think>")
        let envelope = "<|call|>{\"name\":\"write_file\",\"arguments\":{\"content\":\"<think>tag</think>\"}}<|end|>"
        let out = splitter.feed(envelope)
        XCTAssertEqual(out.thinking, "", "envelope arguments must never be split across channels")
        XCTAssertEqual(out.content, envelope)
    }

    func testHarmonyEnvelopeAfterThink_neverSplit() {
        _ = splitter.feed("<think>plan</think>")
        let envelope = "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.txt\"}}<|end|>"
        var collected = ""
        // Feed in tiny chunks to maximize the chance of a false hold.
        for ch in envelope {
            let out = splitter.feed(String(ch))
            XCTAssertEqual(out.thinking, "", "envelope char routed to thinking: \(ch)")
            collected += out.content
        }
        collected += splitter.flush().content
        XCTAssertEqual(collected, envelope)
    }

    func testFlushInsideThink_emitsAsThinking() {
        _ = splitter.feed("<think>partial")
        let out = splitter.feed(" reasoning</thi")
        XCTAssertEqual(out.thinking, " reasoning")
        let flushed = splitter.flush()
        XCTAssertEqual(flushed.thinking, "</thi")
        XCTAssertEqual(flushed.content, "")
    }

    // MARK: - Degenerate inputs

    func testEmptyFeed_noOutput_noStateChange() {
        XCTAssertEqual(splitter.feed(""), ThinkTagSplitter.Output())
        XCTAssertEqual(splitter.feed("<think>a").thinking, "a",
                       "empty feed must not have closed the tag window")
    }

    func testEmptyThinkBlock() {
        let out = splitter.feed("<think></think>answer")
        XCTAssertEqual(out, ThinkTagSplitter.Output(content: "answer", thinking: ""))
    }

    func testOpenTagOnly_thenFlush_bodyStaysThinking() {
        XCTAssertEqual(splitter.feed("<think>"), ThinkTagSplitter.Output())
        let flushed = splitter.flush()
        XCTAssertEqual(flushed, ThinkTagSplitter.Output(),
                       "nothing buffered after a bare open tag")
        // Everything after an unclosed open tag routes to thinking until flush.
        var s2 = ThinkTagSplitter()
        _ = s2.feed("<think>orphan")
        XCTAssertEqual(s2.flush().thinking, "")  // "orphan" already emitted by feed
    }

    func testCloseTagWithoutOpen_isLiteralContent() {
        let out = splitter.feed("</think>foo")
        XCTAssertEqual(out.thinking, "")
        XCTAssertEqual(out.content, "</think>foo")
    }

    func testUppercaseTag_notRecognized() {
        let out = splitter.feed("<THINK>loud</THINK>")
        XCTAssertEqual(out.content, "<THINK>loud</THINK>")
        XCTAssertEqual(out.thinking, "")
    }

    func testFlushTwice_secondIsEmpty() {
        _ = splitter.feed("<thi")
        XCTAssertEqual(splitter.flush().content, "<thi")
        XCTAssertEqual(splitter.flush(), ThinkTagSplitter.Output())
    }

    func testWhitespaceBetweenTwoThinkBlocks_secondStillRecognized() {
        // Deliberate semantics: only NON-whitespace content closes the open-tag
        // window, so "<think>a</think>\n<think>b</think>ok" routes both blocks
        // to thinking (some models emit two reasoning passes).
        var out = splitter.feed("<think>a</think>\n")
        XCTAssertEqual(out.thinking, "a")
        out = splitter.feed("<think>b</think>ok")
        XCTAssertEqual(out.thinking, "b")
        XCTAssertEqual(out.content, "ok")
    }

    // MARK: - Chunk-framing independence (property-style)

    /// Feeds `text` through a fresh splitter in the given piece sizes and
    /// returns the aggregate (content, thinking) including the final flush.
    private func run(_ text: String, chunks: [String]) -> ThinkTagSplitter.Output {
        var s = ThinkTagSplitter()
        var total = ThinkTagSplitter.Output()
        for chunk in chunks {
            let out = s.feed(chunk)
            total.content += out.content
            total.thinking += out.thinking
        }
        let flushed = s.flush()
        total.content += flushed.content
        total.thinking += flushed.thinking
        return total
    }

    /// THE invariant the 2026-07-23 review fix restored: the split point of
    /// the incoming chunks must never change WHAT is routed where — a proxy
    /// that coalesces NDJSON deltas or a model that emits multi-token deltas
    /// must see identical semantics to char-by-char streaming.
    private func assertFramingIndependent(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let reference = run(text, chunks: [text])
        // Every two-chunk split.
        for i in 0...text.count {
            let idx = text.index(text.startIndex, offsetBy: i)
            let out = run(text, chunks: [String(text[..<idx]), String(text[idx...])])
            XCTAssertEqual(out, reference,
                           "two-chunk split at \(i) diverged for: \(text)",
                           file: file, line: line)
        }
        // Char-by-char.
        let charByChar = run(text, chunks: text.map(String.init))
        XCTAssertEqual(charByChar, reference,
                       "char-by-char diverged for: \(text)", file: file, line: line)
    }

    func testFramingIndependence_leadingThinkThenAnswer() {
        assertFramingIndependent("<think>plan it</think>the answer")
    }

    func testFramingIndependence_proseThenLiteralThink() {
        assertFramingIndependent("prose first <think>literal</think> end")
    }

    func testFramingIndependence_whitespaceThenThink() {
        assertFramingIndependent("\n <think>r</think>a")
    }

    func testFramingIndependence_thinkThenHarmonyEnvelope() {
        assertFramingIndependent(
            "<think>plan</think><|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a<think>b\"}}<|end|>")
    }

    func testFramingIndependence_unclosedThink() {
        assertFramingIndependent("<think>never closed at all")
    }

    func testFramingIndependence_noTagsAtAll() {
        assertFramingIndependent("just some plain prose with < and > and </ inside")
    }

    // MARK: - Server prefill report (prompt-prefix cache detection)

    func testDone_withPrefillDurations_reportsThemForCacheDetection() {
        var parser = OllamaChatStreamParser()
        let line = #"{"done":true,"prompt_eval_count":1000,"eval_count":8,"#
            + #""prompt_eval_duration":450000000,"load_duration":0}"#
        let events = parser.parse(line: line)

        guard case .chatEnd(_, let prefill)? = events.last else {
            return XCTFail("expected chatEnd, got \(events)")
        }
        XCTAssertEqual(prefill?.prefillNs, 450_000_000)
        XCTAssertEqual(prefill?.promptTokens, 1000)
        XCTAssertEqual(prefill?.modelLoadMs, 0)
        // 450ms / 1000 tokens — the measured COLD rate on this project's models.
        XCTAssertEqual(prefill?.nsPerToken ?? 0, 450_000, accuracy: 1)
    }

    func testDone_withModelLoad_reportsItInMilliseconds() {
        var parser = OllamaChatStreamParser()
        let events = parser.parse(
            line: #"{"done":true,"prompt_eval_count":10,"load_duration":2236645542}"#)

        guard case .chatEnd(_, let prefill)? = events.last else {
            return XCTFail("expected chatEnd, got \(events)")
        }
        // bench_baseline's one genuine cold load. The parser converts ns→ms VERBATIM and applies
        // no threshold: a reported load is a duration, not a flag (Ollama reports ~22 ms on every
        // warm request), and `PrefixCachePolicy.minimumLoadMsForReload` is what decides. Keeping
        // the raw number here is also what lets that threshold be re-derived from a real run.
        XCTAssertEqual(prefill?.modelLoadMs ?? 0, 2236.6, accuracy: 0.1,
                       "the load duration reaches the policy unrounded and unfiltered")
    }

    func testDone_withoutDurations_reportsNoPrefill() {
        var parser = OllamaChatStreamParser()
        let events = parser.parse(line: #"{"done":true,"prompt_eval_count":5,"eval_count":6}"#)

        guard case .chatEnd(_, let prefill)? = events.last else {
            return XCTFail("expected chatEnd, got \(events)")
        }
        XCTAssertNil(prefill, "prompt_eval_count alone is a denominator, not a signal")
    }

    func testNsPerToken_requiresBothHalvesToBePositive() {
        XCTAssertNil(ServerPrefillReport(prefillNs: 100, promptTokens: 0).nsPerToken)
        XCTAssertNil(ServerPrefillReport(prefillNs: 0, promptTokens: 100).nsPerToken)
        XCTAssertNil(ServerPrefillReport(promptTokens: 100).nsPerToken)
        XCTAssertEqual(ServerPrefillReport(prefillNs: 1000, promptTokens: 10).nsPerToken, 100)
    }

}
