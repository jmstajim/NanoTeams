import XCTest

@testable import NanoTeams

/// The `/v1/chat/completions` stream, replayed from chunks RECORDED on LM Studio 0.4.21
/// (2026-09-13, `gemma-4-26b-a4b-qat` and `qwen3.8-27b`) — not from the OpenAI spec.
final class OpenAIChatChunkParserTests: XCTestCase {

    private var parser: OpenAIChatChunkParser!

    override func setUp() {
        super.setUp()
        parser = OpenAIChatChunkParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    private func line(_ json: String) -> [OpenAIChatChunkParser.ParsedEvent] {
        parser.parse(line: "data: " + json)
    }

    private static let head = #"{"id":"chatcmpl-x","object":"chat.completion.chunk","created":1,"model":"m","system_fingerprint":"m","#

    // MARK: - The recorded gemma stream, in order

    func testGemmaStream_reasoningThenCallPiecesThenFinishThenUsage() {
        XCTAssertEqual(
            line(Self.head + #""choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"\n"},"logprobs":null,"finish_reason":null}]}"#),
            [.thinkingDelta("\n")])
        XCTAssertEqual(
            line(Self.head + #""choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"268992578","type":"function","function":{"name":"list_files","arguments":""}}]},"logprobs":null,"finish_reason":null}]}"#),
            [.toolCallDeltas([.init(index: 0, id: "268992578", name: "list_files", argumentsDelta: "")])])
        XCTAssertEqual(
            line(Self.head + #""choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"type":"function","function":{"arguments":"{\"path\":\".\"}"}}]},"logprobs":null,"finish_reason":null}]}"#),
            [.toolCallDeltas([.init(index: 0, id: nil, name: nil, argumentsDelta: #"{"path":"."}"#)])])
        XCTAssertEqual(
            line(Self.head + #""choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}]}"#),
            [.finish(reason: "tool_calls")])
        XCTAssertEqual(
            line(Self.head + #""choices":[],"usage":{"prompt_tokens":163,"completion_tokens":19,"total_tokens":182,"completion_tokens_details":{"reasoning_tokens":1}}}"#),
            [.usage(TokenUsage(inputTokens: 163, outputTokens: 19), reasoningTokens: 1)])
        XCTAssertEqual(parser.parse(line: "data: [DONE]"), [.done])
    }

    /// The pieces fold to one call through the app's accumulator — the same fold the step
    /// applies, so the parser's contract is "pieces in order", nothing more.
    func testPieces_foldToOneCallInTheAccumulator() {
        var accumulator = ToolCallAccumulator()
        accumulator.absorb([.init(index: 0, id: "268992578", name: "list_files", argumentsDelta: "")])
        accumulator.absorb([.init(index: 0, id: nil, name: nil, argumentsDelta: #"{"path":"."}"#)])
        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.providerID, "268992578")
        XCTAssertEqual(calls.first?.name, "list_files")
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"path":"."}"#)
    }

    /// The template's newlines around NATIVE calls are ordinary content, and they arrive as
    /// their own events — never folded into the call. Shape reconstructed from the accumulated
    /// content of 101 LM Studio records (tasks 111–113, 2026-09-13/14, `ornith-1.5-35b-a3b-mlx`):
    /// every turn's content ended with exactly `calls + 1` newlines, i.e. `\n\n` before the
    /// first `<tool_call>` and one `\n` at each `</tool_call>` → `<tool_call>` boundary. The
    /// parser's contract is to say what the server said; keeping the newlines off the bubble
    /// is `StreamingPreviewManager`'s (`StreamingPreviewManagerTrailingWhitespaceTests`).
    func testNewlinesAroundNativeCalls_areContentDeltas_separateFromTheCalls() {
        XCTAssertEqual(
            line(Self.head + #""choices":[{"index":0,"delta":{"content":"\n\n"},"logprobs":null,"finish_reason":null}]}"#),
            [.contentDelta("\n\n")])
        XCTAssertEqual(
            line(Self.head + #""choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"A.swift\"}"}}]},"logprobs":null,"finish_reason":null}]}"#),
            [.toolCallDeltas([.init(index: 0, id: "a1", name: "read_file", argumentsDelta: #"{"path":"A.swift"}"#)])])
        XCTAssertEqual(
            line(Self.head + #""choices":[{"index":0,"delta":{"content":"\n"},"logprobs":null,"finish_reason":null}]}"#),
            [.contentDelta("\n")])
        XCTAssertEqual(
            line(Self.head + #""choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"a2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"B.swift\"}"}}]},"logprobs":null,"finish_reason":null}]}"#),
            [.toolCallDeltas([.init(index: 1, id: "a2", name: "read_file", argumentsDelta: #"{"path":"B.swift"}"#)])])
    }

    // MARK: - Reasoning under both names, and the inline fallback

    func testReasoning_underEitherFieldName() {
        XCTAssertEqual(line(#"{"choices":[{"delta":{"reasoning_content":"a"}}]}"#), [.thinkingDelta("a")])
        XCTAssertEqual(line(#"{"choices":[{"delta":{"reasoning":"b"}}]}"#), [.thinkingDelta("b")])
    }

    func testContent_afterReasoning() {
        XCTAssertEqual(line(#"{"choices":[{"delta":{"content":"\n\n"}}]}"#), [.contentDelta("\n\n")])
    }

    /// No reasoning field at all — a build with no parser for the loaded model — puts the
    /// reasoning inline; the splitter re-routes it exactly as the two sibling parsers do.
    func testInlineThinkTag_isReroutedToThinking() {
        XCTAssertEqual(line(#"{"choices":[{"delta":{"content":"<think>r</think>a"}}]}"#),
                       [.thinkingDelta("r"), .contentDelta("a")])
    }

    func testThinkTagSplitAcrossChunks() {
        XCTAssertEqual(line(#"{"choices":[{"delta":{"content":"<th"}}]}"#), [])
        XCTAssertEqual(line(#"{"choices":[{"delta":{"content":"ink>abc</th"}}]}"#), [.thinkingDelta("abc")])
        XCTAssertEqual(line(#"{"choices":[{"delta":{"content":"ink>ok"}}]}"#), [.contentDelta("ok")])
    }

    func testHeldBackPrefix_isDrainedAtFinishAndAtTransportEnd() {
        XCTAssertEqual(line(#"{"choices":[{"delta":{"content":"<thi"}}]}"#), [])
        XCTAssertEqual(line(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
                       [.contentDelta("<thi"), .finish(reason: "stop")])
        XCTAssertEqual(parser.finalize(), [])
        var fresh = OpenAIChatChunkParser()
        _ = fresh.parse(line: #"data: {"choices":[{"delta":{"content":"<thi"}}]}"#)
        XCTAssertEqual(fresh.finalize(), [.contentDelta("<thi")])
    }

    // MARK: - Length, errors, framing

    /// The gemma reasoning loop (2026-09-13): 599 tokens of reasoning about a tool the
    /// schema lacks, then `length` — the reason `handleNoToolCalls` acts on.
    func testFinishLength_isReportedVerbatim() {
        XCTAssertEqual(line(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#), [.finish(reason: "length")])
    }

    func testErrorChunk_inEitherEnvelopeShape() {
        XCTAssertEqual(line(#"{"error":{"message":"Model not loaded"}}"#), [.error("Model not loaded")])
        XCTAssertEqual(line(#"{"error":"boom"}"#), [.error("boom")])
        XCTAssertEqual(line(#"{"error":{}}"#), [.error("Stream error")])
    }

    func testNonDataLines_andBlankLines_areFraming() {
        XCTAssertEqual(parser.parse(line: ""), [])
        XCTAssertEqual(parser.parse(line: "event: ping"), [])
        XCTAssertEqual(parser.parse(line: ": keep-alive"), [])
    }

    func testUndecodablePayload_isNoise() {
        XCTAssertEqual(parser.parse(line: "data: {not json"), [])
    }

    func testUsageWithNoCounts_emitsNothing() {
        XCTAssertEqual(line(#"{"choices":[],"usage":{}}"#), [])
    }

    /// A mistyped count must not cost the chunk its delta (the lenient-telemetry rule).
    func testMalformedUsage_doesNotDiscardTheDelta() {
        XCTAssertEqual(line(#"{"choices":[{"delta":{"content":"x"}}],"usage":"fast"}"#), [.contentDelta("x")])
    }

    func testMalformedToolCallPiece_doesNotDiscardTheContentBesideIt() {
        XCTAssertEqual(line(#"{"choices":[{"delta":{"content":"x","tool_calls":"nope"}}]}"#), [.contentDelta("x")])
    }

    func testToolCallDelta_withoutIndex_fallsBackToPosition() {
        XCTAssertEqual(
            line(#"{"choices":[{"delta":{"tool_calls":[{"id":"a","function":{"name":"f","arguments":"{}"}},{"id":"b","function":{"name":"g","arguments":"{}"}}]}}]}"#),
            [.toolCallDeltas([.init(index: 0, id: "a", name: "f", argumentsDelta: "{}"),
                              .init(index: 1, id: "b", name: "g", argumentsDelta: "{}")])])
    }
}
