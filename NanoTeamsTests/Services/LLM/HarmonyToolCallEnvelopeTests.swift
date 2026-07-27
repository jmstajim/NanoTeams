import XCTest

@testable import NanoTeams

/// `HarmonyToolCallEnvelope` owns the RENDER half of the format whose PARSE half is
/// `HarmonyToolCallParser`. Both request builders and both measurement surfaces call it, so
/// these bytes are the contract: get them wrong and the model is shown a transcript of its own
/// tool calls that it did not make, or one it cannot parse.
///
/// Two of these tests were RED before the type existed, against live wire bugs in the code this
/// replaces (`OllamaClient.buildRequest`'s inline loop):
///   - `argumentsJSON == ""` emitted `{"name":"git_status","arguments":}` — malformed JSON,
///     reachable on any zero-argument tool call.
///   - `call.name` was spliced into a JSON string literal with zero escaping.
final class HarmonyToolCallEnvelopeTests: XCTestCase {

    private func call(
        _ name: String = "read_file",
        _ args: String = #"{"path":"A.swift"}"#,
        id: String = "tc-1"
    ) -> ChatToolCall {
        ChatToolCall(id: id, name: name, argumentsJSON: args)
    }

    private func assistant(_ content: String?, _ calls: [ChatToolCall]?) -> ChatMessage {
        ChatMessage(role: .assistant, content: content, toolCalls: calls)
    }

    // MARK: - text(name:argumentsJSON:)

    func testText_rendersTheExactEnvelopeBytes() {
        XCTAssertEqual(
            HarmonyToolCallEnvelope.text(name: "read_file", argumentsJSON: #"{"path":"A.swift"}"#),
            #"<|call|>{"name":"read_file","arguments":{"path":"A.swift"}}<|end|>"#)
    }

    /// Key order is `name` then `arguments`, always. Reaching for `JSONEncoder` with
    /// `.sortedKeys` here would emit `arguments` first and silently change the wire bytes of
    /// every healthy tool call in the app.
    func testText_keyOrderIsNameThenArguments() {
        let rendered = HarmonyToolCallEnvelope.text(name: "n", argumentsJSON: "{}")
        let nameIndex = rendered.range(of: "\"name\"")!.lowerBound
        let argsIndex = rendered.range(of: "\"arguments\"")!.lowerBound
        XCTAssertLessThan(nameIndex, argsIndex)
    }

    /// `argumentsJSON` is spliced verbatim — the model's whitespace and key order are part of
    /// the bytes the server cached, so re-encoding it would break the prompt prefix.
    func testText_argumentsJSONIsSplicedVerbatim_notReEncoded() {
        let quirky = #"{ "b" : 2,  "a":1 }"#
        XCTAssertTrue(
            HarmonyToolCallEnvelope.text(name: "n", argumentsJSON: quirky).contains(quirky))
    }

    func testText_neverCarriesTheToolCallID() {
        XCTAssertFalse(
            HarmonyToolCallEnvelope.text(name: "read_file", argumentsJSON: "{}")
                .contains("tc-1"))
    }

    // MARK: - Empty arguments (was a live wire bug)

    /// A model emitting `{"name":"git_status"}` — the natural shape for a zero-argument tool —
    /// yields `argumentsJSON == ""` via `normalizeArgumentsJSON`. Splicing that verbatim
    /// produced `"arguments":` with no value: malformed JSON, resent on every later iteration.
    func testText_emptyArgumentsJSON_becomesAnEmptyObject() {
        XCTAssertEqual(
            HarmonyToolCallEnvelope.text(name: "git_status", argumentsJSON: ""),
            #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#)
    }

    func testText_whitespaceOnlyArgumentsJSON_becomesAnEmptyObject() {
        XCTAssertEqual(
            HarmonyToolCallEnvelope.text(name: "git_status", argumentsJSON: "  \n "),
            #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#)
    }

    func testText_emptyArguments_producesParseableJSON() {
        let inner = innerJSON(of: HarmonyToolCallEnvelope.text(name: "git_status", argumentsJSON: ""))
        XCTAssertNotNil(
            try? JSONSerialization.jsonObject(with: Data(inner.utf8)),
            "a zero-argument call must not poison the transcript with unparseable JSON")
    }

    // MARK: - Name escaping (was a live wire bug)

    func testText_nameContainingAQuote_isEscaped() {
        let rendered = HarmonyToolCallEnvelope.text(name: #"read "file""#, argumentsJSON: "{}")
        let object = try? JSONSerialization.jsonObject(
            with: Data(innerJSON(of: rendered).utf8)) as? [String: Any]
        XCTAssertEqual(object?["name"] as? String, #"read "file""#)
    }

    func testText_nameContainingABackslash_isEscaped() {
        let rendered = HarmonyToolCallEnvelope.text(name: #"a\b"#, argumentsJSON: "{}")
        let object = try? JSONSerialization.jsonObject(
            with: Data(innerJSON(of: rendered).utf8)) as? [String: Any]
        XCTAssertEqual(object?["name"] as? String, #"a\b"#)
    }

    func testText_nameContainingANewline_isEscaped() {
        let rendered = HarmonyToolCallEnvelope.text(name: "a\nb", argumentsJSON: "{}")
        XCTAssertFalse(
            rendered.contains("\n"), "a raw newline inside a JSON string literal is invalid")
        let object = try? JSONSerialization.jsonObject(
            with: Data(innerJSON(of: rendered).utf8)) as? [String: Any]
        XCTAssertEqual(object?["name"] as? String, "a\nb")
    }

    /// An ordinary name must not gain escaping it never had — that would change the bytes of
    /// every tool call in the app and invalidate every server prompt-prefix cache.
    func testText_ordinaryNameIsUnchanged() {
        XCTAssertTrue(
            HarmonyToolCallEnvelope.text(name: "read_file", argumentsJSON: "{}")
                .contains(#""name":"read_file""#))
    }

    // MARK: - appendedWireText: role gate

    func testAppended_nonAssistantRoles_contributeNothing() {
        for role in [MessageRole.user, .tool, .system] {
            XCTAssertEqual(
                HarmonyToolCallEnvelope.appendedWireText(
                    for: ChatMessage(role: role, content: "x", toolCalls: [call()])),
                "",
                "\(role) turns carry no envelope on either wire, so none may be priced either")
        }
    }

    func testAppended_noToolCalls_isEmpty() {
        XCTAssertEqual(HarmonyToolCallEnvelope.appendedWireText(for: assistant("hi", nil)), "")
        XCTAssertEqual(HarmonyToolCallEnvelope.appendedWireText(for: assistant("hi", [])), "")
    }

    // MARK: - appendedWireText: the separator rule

    func testAppended_nilContent_oneCall_hasNoLeadingSeparator() {
        XCTAssertEqual(
            HarmonyToolCallEnvelope.appendedWireText(for: assistant(nil, [call()])),
            #"<|call|>{"name":"read_file","arguments":{"path":"A.swift"}}<|end|>"#)
    }

    func testAppended_emptyStringContent_behavesLikeNil() {
        XCTAssertEqual(
            HarmonyToolCallEnvelope.appendedWireText(for: assistant("", [call()])),
            HarmonyToolCallEnvelope.appendedWireText(for: assistant(nil, [call()])))
    }

    /// The gate is `isEmpty`, not `trimmed.isEmpty` — whitespace-only content is non-empty, so
    /// it gets a separator. Mirrors the builder exactly rather than tidying after it.
    func testAppended_whitespaceOnlyContent_getsASeparator() {
        XCTAssertTrue(
            HarmonyToolCallEnvelope.appendedWireText(for: assistant(" ", [call()]))
                .hasPrefix("\n"))
    }

    func testAppended_proseThenOneCall_hasALeadingSeparator() {
        XCTAssertEqual(
            HarmonyToolCallEnvelope.appendedWireText(for: assistant("Let me check.", [call("git_status", "{}")])),
            "\n" + #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#)
    }

    func testAppended_nilContentThreeCalls_hasExactlyTwoSeparators() {
        let text = HarmonyToolCallEnvelope.appendedWireText(
            for: assistant(nil, [call("a", "{}"), call("b", "{}"), call("c", "{}")]))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 2)
        XCTAssertFalse(text.hasPrefix("\n"))
    }

    func testAppended_proseThenTwoCalls_hasExactlyTwoSeparators() {
        let text = HarmonyToolCallEnvelope.appendedWireText(
            for: assistant("x", [call("a", "{}"), call("b", "{}")]))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 2)
        XCTAssertTrue(text.hasPrefix("\n"))
    }

    func testAppended_multipleCalls_preserveOrder() {
        let text = HarmonyToolCallEnvelope.appendedWireText(
            for: assistant(nil, [call("first", "{}"), call("second", "{}")]))
        XCTAssertLessThan(
            text.range(of: "first")!.lowerBound, text.range(of: "second")!.lowerBound)
    }

    // MARK: - Round trip with the parser that reads this format

    func testRoundTrip_parserRecoversEveryCall() {
        let text = HarmonyToolCallEnvelope.appendedWireText(
            for: assistant(nil, [
                call("read_file", #"{"path":"A.swift"}"#),
                call("git_status", ""),
            ]))
        let parsed = HarmonyToolCallParser().extractAllToolCalls(from: text)
        XCTAssertEqual(parsed.map(\.name), ["read_file", "git_status"])
        XCTAssertEqual(parsed.first?.argumentsJSON, #"{"path":"A.swift"}"#)
    }

    func testRoundTrip_escapedNameSurvives() {
        let text = HarmonyToolCallEnvelope.appendedWireText(
            for: assistant(nil, [call(#"read "file""#, "{}")]))
        XCTAssertEqual(
            HarmonyToolCallParser().extractAllToolCalls(from: text).first?.name,
            #"read "file""#)
    }

    // MARK: - Helper

    /// Strips the `<|call|>` / `<|end|>` markers, leaving the JSON object between them.
    private func innerJSON(of envelope: String) -> String {
        var s = envelope
        if let r = s.range(of: HarmonyToolCallParser.callMarker) { s.removeSubrange(r) }
        if let r = s.range(of: HarmonyToolCallParser.endMarker) { s.removeSubrange(r) }
        return s
    }
}
