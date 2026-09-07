import XCTest

@testable import NanoTeams

/// `FinishedReplyToolCallResolver` is the non-streaming twin of the step's three-route
/// resolution (`LLMExecutionService+Streaming`): native deltas, then the Harmony envelope
/// in the content channel, then the bare salvage. It exists because the meeting turn had
/// only route 1 — and no shipping client emits `toolCallDeltas`, so `conclude_meeting`
/// never fired (playbook R3.1.4 / R3.8.7, audit 2026-09-07).
final class FinishedReplyToolCallResolverTests: XCTestCase {

    private static let envelope =
        #"<|call|>{"name":"conclude_meeting","arguments":{"decision":"Ship it"}}<|end|>"#

    private static func schema(_ name: String) -> ToolSchema {
        ToolSchema(name: name, description: "t",
                   parameters: JSONSchema(type: "object", properties: [:], required: []))
    }

    // MARK: - Route 1: native deltas win and leave the content alone

    func testNativeCalls_win_andContentIsUntouched() {
        let native = [StepToolCall(name: "read_file", argumentsJSON: #"{"path":"a"}"#)]
        let r = FinishedReplyToolCallResolver.resolve(
            content: "Let me look. " + Self.envelope, nativeCalls: native, advertised: [])

        XCTAssertEqual(r.toolCalls.map(\.name), ["read_file"],
                       "a provider-native call outranks anything written in the content channel")
        XCTAssertEqual(r.content, "Let me look. " + Self.envelope,
                       "route 1 does not touch the content — nothing was taken from it")
    }

    // MARK: - Route 2: the Harmony envelope in the content channel

    func testHarmonyEnvelope_resolvesTheCall_andKeepsTheProseBeforeTheMarker() {
        let r = FinishedReplyToolCallResolver.resolve(
            content: "We have converged.\n\n" + Self.envelope, nativeCalls: [], advertised: [])

        XCTAssertEqual(r.toolCalls.map(\.name), ["conclude_meeting"])
        XCTAssertEqual(r.toolCalls.first?.argumentsJSON, #"{"decision":"Ship it"}"#)
        XCTAssertEqual(r.content, "We have converged.",
                       "the prose the model spoke before the envelope is the turn's content; "
                           + "the envelope itself leaves it, or the wire would carry the call twice")
    }

    func testEnvelopeOnly_contentBecomesEmpty() {
        let r = FinishedReplyToolCallResolver.resolve(
            content: Self.envelope, nativeCalls: [], advertised: [])

        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.content, "")
    }

    func testMangledOpeningSentinel_isNormalisedBeforeParsing() {
        // Verbatim shape from the 2026-08-07 MeditationApp run (`HarmonySentinelNormalizerTests`).
        let mangled = #"Agreed. <|tool_call>call|>{"name":"list_files","arguments":{"path":"."}}<|end|>"#
        let r = FinishedReplyToolCallResolver.resolve(
            content: mangled, nativeCalls: [], advertised: [])

        XCTAssertEqual(r.toolCalls.map(\.name), ["list_files"])
        XCTAssertEqual(r.content, "Agreed.")
    }

    func testMarkerWithoutAParseableEnvelope_resolvesNothing_andKeepsTheTextWhole() {
        let broken = "Thinking aloud <|call|>{not json"
        let r = FinishedReplyToolCallResolver.resolve(
            content: broken, nativeCalls: [], advertised: [])

        XCTAssertTrue(r.toolCalls.isEmpty)
        XCTAssertEqual(r.content, broken,
                       "with no call to re-materialise, cutting the text would lose what the model said")
    }

    func testDuplicateEnvelopes_areDeduplicated() {
        let r = FinishedReplyToolCallResolver.resolve(
            content: Self.envelope + "\n" + Self.envelope, nativeCalls: [], advertised: [])

        XCTAssertEqual(r.toolCalls.count, 1, "a byte-identical repeat is pure cost, never a second call")
    }

    // MARK: - Route 3: no sentinel at all

    func testBareJSONObject_isSalvaged_whenThereIsNoMarker() {
        let bare = #"{"name":"conclude_meeting","arguments":{"decision":"Ship it"}}"#
        let r = FinishedReplyToolCallResolver.resolve(
            content: bare, nativeCalls: [], advertised: [Self.schema("conclude_meeting")])

        XCTAssertEqual(r.toolCalls.map(\.name), ["conclude_meeting"])
        XCTAssertEqual(r.content, "", "the promoted payload leaves the content channel")
    }

    func testPlainProse_resolvesNothing_andIsReturnedVerbatim() {
        let r = FinishedReplyToolCallResolver.resolve(
            content: "I agree with the plan.", nativeCalls: [], advertised: [Self.schema("read_file")])

        XCTAssertTrue(r.toolCalls.isEmpty)
        XCTAssertEqual(r.content, "I agree with the plan.")
    }
}
