import XCTest
@testable import NanoTeams

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

    /// Feeds the chunks through a fresh splitter and returns the aggregate
    /// (content, thinking) including the final flush.
    private func run(chunks: [String]) -> ThinkTagSplitter.Output {
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
        let reference = run(chunks: [text])
        // Every two-chunk split.
        for i in 0...text.count {
            let idx = text.index(text.startIndex, offsetBy: i)
            let out = run(chunks: [String(text[..<idx]), String(text[idx...])])
            XCTAssertEqual(out, reference,
                           "two-chunk split at \(i) diverged for: \(text)",
                           file: file, line: line)
        }
        // Char-by-char.
        let charByChar = run(chunks: text.map(String.init))
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

}

// MARK: - Provider parity

/// The same `<think>` bytes, framed as Ollama NDJSON and as LM Studio SSE, must land on
/// the same channels in the same order — the splitter is one type, and this pins that
/// BOTH parsers run it. `SSEEventParser` did not until 2026-09-07: its `message.delta`
/// passed through untouched, so on an LM Studio build without a reasoning parser for the
/// loaded repo the reasoning reached the feed, the loop detector and
/// `HarmonyToolCallParser` as content (playbook R2.3.1 / R2.3.3).
///
/// RED: drop the `splitter` from `SSEEventParser` → every framing but "no tags at all"
/// diverges on the LM Studio side.
final class ThinkTagRoutingParityTests: XCTestCase {

    private enum Routed: Equatable {
        case thinking(String)
        case content(String)
    }

    private static let framings: [(name: String, chunks: [String])] = [
        ("one chunk", ["<think>r</think>a"]),
        ("tag split across chunks", ["<th", "ink>r</th", "ink>a"]),
        ("leading newline before the tag", ["\n<think>", "r", "</think>", "a"]),
        ("tag after prose stays content", ["prose ", "<think>x</think>"]),
        ("held-back close prefix at transport end", ["<think>r", "</thi"]),
        ("no tags at all", ["plain ", "answer"]),
    ]

    func testEveryFraming_routesIdenticallyOnBothProviders() throws {
        for framing in Self.framings {
            XCTAssertEqual(try Self.ollama(framing.chunks), try Self.lmStudio(framing.chunks), framing.name)
        }
    }

    func testLeadingThinkSpan_landsOnTheThinkingChannel_onLMStudio() throws {
        XCTAssertEqual(try Self.lmStudio(["<think>r</think>a"]), [.thinking("r"), .content("a")])
    }

    func testHeldBackPrefix_isDrainedAtTransportEnd_onBothProviders() throws {
        let expected: [Routed] = [.thinking("r"), .thinking("</thi")]
        XCTAssertEqual(try Self.ollama(["<think>r", "</thi"]), expected)
        XCTAssertEqual(try Self.lmStudio(["<think>r", "</thi"]), expected)
    }

    private static func ollama(_ chunks: [String]) throws -> [Routed] {
        var parser = OllamaChatStreamParser()
        var out: [Routed] = []
        for chunk in chunks {
            let line = try jsonLine(["message": ["role": "assistant", "content": chunk]])
            out += parser.parse(line: line).compactMap(route)
        }
        out += parser.finalize().compactMap(route)
        return out
    }

    private static func lmStudio(_ chunks: [String]) throws -> [Routed] {
        var parser = SSEEventParser()
        var out: [Routed] = []
        for chunk in chunks {
            _ = parser.parse(line: "event: message.delta")
            let payload = try jsonLine(["content": chunk])
            out += parser.parse(line: "data: " + payload).compactMap(route)
        }
        out += parser.finalize().compactMap(route)
        return out
    }

    private static func route(_ event: OllamaChatStreamParser.ParsedEvent) -> Routed? {
        switch event {
        case .thinkingDelta(let text): return .thinking(text)
        case .contentDelta(let text): return .content(text)
        default: return nil
        }
    }

    private static func route(_ event: SSEEventParser.ParsedEvent) -> Routed? {
        switch event {
        case .thinkingDelta(let text): return .thinking(text)
        case .contentDelta(let text): return .content(text)
        default: return nil
        }
    }

    private static func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
