import XCTest

@testable import NanoTeams

/// The class of defect that cost a round trip in the `qwen3.8:27b-mlx` MeditationApp run
/// (`network_log.json`, 2026-08-15, 07:58:25): **the model finished a complete call, then
/// emitted junk instead of the last closing brace.**
///
/// The observed payload ended
///
///     <|call|>{"name":"edit_file","arguments":{…,"new_text":"…\n}"},"<|end|>
///
/// — `}` closes `arguments`, then a stray `,` and a stray `"` that never closes, and the
/// ROOT brace is never written. The model meant `}}`. Every argument it sent was COMPLETE.
///
/// `extractJSONBracedValue`'s EOF salvage would have recovered it exactly: `depth == 1`,
/// `depth <= maxSalvageDepth`, and `lastCloseEnd` pointing at precisely the right byte.
/// Only the blanket `!inString` guard refused, because the stray quote left the walker
/// in-string — and everything after that anchor (`,"` then `<|end|>`) is the junk the
/// truncation exists to discard. The other three recovery routes are closed by the same
/// quote: `BareToolCallSalvage` is suppressed once `sawHarmonyMarker` is set, the shape
/// recognizer needs an already-parsed dict, and the `<|end|>`-bounded raw-body fallback
/// KEEPS the `,"` so none of its repairs fire.
///
/// This is NOT the `ToolCallArgumentSpill` class (an over-close, where the walker succeeds
/// and drops members that follow). Here the walker fails and nothing complete exists past
/// the anchor — which is exactly what the discriminator tests: a member is `key : value`,
/// so with no STRUCTURAL (outside-string) colon after the anchor the truncation can
/// discard at most a partial key name. The negative pins below matter at least as much as
/// the positive ones, since a salvage that reaches one member too far is a silent argument
/// dropper.
///
/// Fixture discipline: every envelope is a RAW string literal (`#"…"#`) so `\n` stays the
/// two-character JSON escape it is on the wire. In an interpolating `"""` literal it would
/// become a real newline inside a JSON string, making the fixture invalid for a reason the
/// test does not intend. `assertIsInvalidJSON` guards the premise in place.
final class StrayCommaQuoteTailSalvageTests: XCTestCase {

    // MARK: - Helpers

    private func calls(_ envelope: String) -> [StepToolCall] {
        HarmonyToolCallParser().extractAllToolCalls(from: envelope)
    }

    private func arguments(
        _ envelope: String, file: StaticString = #filePath, line: UInt = #line
    ) -> [String: Any] {
        guard let call = calls(envelope).first else {
            XCTFail("no tool call parsed", file: file, line: line)
            return [:]
        }
        guard let dict = JSONUtilities.parseJSONDictionary(call.argumentsJSON) else {
            XCTFail("argumentsJSON is not an object: \(call.argumentsJSON)", file: file, line: line)
            return [:]
        }
        return dict
    }

    /// Anti-vacuum guard: the payload really is broken, so a green test is not measuring a
    /// well-formed fixture that never needed salvaging.
    private func assertIsInvalidJSON(
        _ json: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(
            try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            "fixture was supposed to be malformed but parses cleanly — the test would be vacuous",
            file: file, line: line)
    }

    private func salvage(_ raw: String, endMarker: String? = nil) -> String? {
        let s = raw[...]
        return ToolCallParsingHelpers.extractJSONBracedValue(
            in: s, from: s.startIndex, salvageEndMarker: endMarker
        )?.0
    }

    // MARK: - 1. The verbatim production payload

    /// RED: restore the blanket `!inString` refusal in `extractJSONBracedValue` → the
    /// walker returns nil, the `<|end|>`-bounded raw-body fallback cannot repair a `,"`
    /// tail either (every re-escape split leaves the stray comma-quote in place), and zero
    /// calls come back — the production drop verbatim.
    func testProductionPayload_strayCommaQuoteTail_resolvesEditFileWithAllThreeArguments() {
        let body = #"{"name":"edit_file","arguments":{"path":"MeditationApp/ContentView.swift","old_text":"struct ContentView: View {\n    var body: some View {\n        Text(\"hi\")\n    }\n}","new_text":"struct ContentView: View {\n    var body: some View {\n        Text(\"hello\")\n    }\n}"},""#
        assertIsInvalidJSON(body)
        let envelope = "<|call|>" + body + "<|end|>"

        let parsed = calls(envelope)
        XCTAssertEqual(parsed.count, 1, "the complete call the model sent must survive its junk tail")
        XCTAssertEqual(parsed.first?.name, "edit_file")

        let args = arguments(envelope)
        XCTAssertEqual(args.count, 3, "all three arguments were complete on the wire")
        XCTAssertEqual(args["path"] as? String, "MeditationApp/ContentView.swift")
        XCTAssertEqual(
            args["old_text"] as? String,
            "struct ContentView: View {\n    var body: some View {\n        Text(\"hi\")\n    }\n}")
        XCTAssertEqual(
            args["new_text"] as? String,
            "struct ContentView: View {\n    var body: some View {\n        Text(\"hello\")\n    }\n}")
    }

    /// The shared locate-and-extract walk behind the classifier and the retry diagnostic
    /// must see the same bytes the dispatch walk now accepts — otherwise a payload that
    /// dispatches fine would still be described to the model as "braces never balance".
    ///
    /// Deliberately asserted on `postCallJSON`, NOT on `classifyHarmonyCallIssue`: that
    /// function's `hasTopLevelName` arm returns `.malformedJSON` as a catch-all, because it
    /// is only ever consulted once the parser has ALREADY failed to resolve a call. On this
    /// payload the parser now succeeds, so the classifier is unreachable in production —
    /// test 1 is what pins that.
    /// RED: restore the blanket `!inString` refusal, or drop the `salvageEndMarker` argument
    /// from `postCallJSON` → this walk returns `.unbalanced` and the diagnostic goes back to
    /// naming a defect the dispatch path no longer has.
    func testPostCallJSON_strayCommaQuoteTail_isExtractedNotUnbalanced() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"path":"a.swift","old_text":"A","new_text":"B"},""# + "<|end|>"
        guard case .extracted(let json) = ToolCallParsingHelpers.postCallJSON(in: envelope) else {
            XCTFail("expected .extracted, got \(ToolCallParsingHelpers.postCallJSON(in: envelope))")
            return
        }
        XCTAssertEqual(
            json,
            #"{"name":"edit_file","arguments":{"path":"a.swift","old_text":"A","new_text":"B"}}"#)
    }

    // MARK: - 2. The walker, directly

    /// RED: delete the `if inString { … }` relaxation and go back to refusing whenever the
    /// walker is in-string at EOF → the salvage is nil and every assertion here is skipped.
    func testWalker_commaQuoteJunkTail_salvagesAtTheAnchor() {
        XCTAssertEqual(salvage(#"{"a":{"b":1},""#), #"{"a":{"b":1}}"#)
    }

    /// The cursor must stop at the anchor, leaving the junk to the caller — the same
    /// contract the not-in-string arm already has.
    /// RED: return `s.endIndex` as the cursor instead of `truncate` → a following envelope
    /// in the same buffer is swallowed and never parsed.
    func testWalker_cursorStopsAtTheAnchorNotAtEndOfBuffer() {
        let raw = #"{"a":{"b":1},"junk"#
        let s = raw[...]
        let result = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(result?.0, #"{"a":{"b":1}}"#)
        XCTAssertEqual(result.map { String(s[$0.1...]) }, #","junk"#)
    }

    // MARK: - 3. The discriminator — STRUCTURAL colon

    /// The word "structural" is load-bearing: this colon is inside the unterminated KEY, so
    /// no member began and the complete call must still survive.
    /// RED: set `memberBeganAfterLastClose` on any `:` (hoist it out of the outside-string
    /// branch, or scan the tail with `contains(":")`) → the colon inside the key counts, the
    /// salvage is refused, and a complete call is dropped.
    func testValuelessTrailingKey_carryingAColonInsideIt_stillSalvages() {
        let envelope = #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"},"note: see below"# + "<|end|>"
        let parsed = calls(envelope)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "read_file")
        XCTAssertEqual(arguments(envelope)["path"] as? String, "a.txt")
    }

    /// The flag must be cleared every time the anchor moves, or the `"path":` colon from
    /// INSIDE `arguments` still marks the tail as a begun member.
    /// RED: delete `memberBeganAfterLastClose = false` in the `}`/`]` branch → the flag is
    /// still true from `"path":`, the arm refuses, and a complete call is lost.
    func testValuelessTrailingKey_salvagesBecauseTheFlagResetsOnEveryClose() {
        XCTAssertEqual(
            salvage(#"{"name":"read_file","arguments":{"path":"a.txt"},"extra"#),
            #"{"name":"read_file","arguments":{"path":"a.txt"}}"#)
    }

    /// The negative half, at depth 2: a value the model DID begin writing must never be
    /// silently discarded — that is the `ToolCallArgumentSpill` failure class.
    /// RED: drop the `!memberBeganAfterLastClose` condition → this salvages to
    /// `{…{"team_config":{"name":"X"}}}` and the `members` the model began is gone from a
    /// call that then dispatches as if it were complete.
    func testNestedDepthTwo_begunMemberValue_staysRefused() {
        XCTAssertNil(salvage(#"{"name":"create_team","arguments":{"team_config":{"name":"X"},"members":"[Alice"#))
    }

    /// RED: replace `String(repeating: "}", count: depth)` with a single literal `"}"` →
    /// the depth-2 salvage is one closer short and the result does not parse.
    func testNestedDepthTwo_valuelessTrailingKey_padsBothClosers() {
        XCTAssertEqual(
            salvage(#"{"name":"create_team","arguments":{"team_config":{"name":"X"},"members"#),
            #"{"name":"create_team","arguments":{"team_config":{"name":"X"}}}"#)
    }

    // MARK: - 4. Quote-parity inversion across envelopes

    /// A stray quote inverts quote parity for the REST of the buffer, so envelope 2's
    /// braces and colons land inside a string and cannot move the anchor. Both calls
    /// resolve — the salvage recovers the first, the cursor hands the second on.
    /// RED: restore the blanket `!inString` refusal → only `read_file` comes back and the
    /// `edit_file` the model actually sent is dropped, exactly as in production.
    func testProductionShapeFollowedByACleanEnvelope_bothResolve() {
        let envelope =
            #"<|call|>{"name":"edit_file","arguments":{"path":"a","old_text":"x","new_text":"y"},""#
            + "<|end|>"
            + #"<|call|>{"name":"read_file","arguments":{"path":"b"}}"# + "<|end|>"

        XCTAssertEqual(calls(envelope).map(\.name), ["edit_file", "read_file"])
    }

    /// When parity flips BACK — a brace inside a later envelope's string value is counted
    /// as structure — the anchor marches into that envelope and a salvage there would span
    /// both, parse as nothing, and consume the buffer. The `salvageEndMarker` bound refuses
    /// instead, leaving the raw-body fallback to recover the later call: today's behaviour,
    /// no regression. Recovering `edit_file` here needs a walker-state snapshot at the
    /// boundary, which is deliberately not implemented.
    /// RED: drop the `salvageEndMarker` bound from the mid-string arm → the marched anchor
    /// is accepted, the returned span crosses `<|end|>`, it fails strict parse, and BOTH
    /// calls are lost where today's code returns one.
    func testAnchorMarchedIntoTheNextEnvelope_isRefusedRatherThanSalvaged() {
        let envelope =
            #"<|call|>{"name":"edit_file","arguments":{"path":"a"},""#
            + "<|end|>"
            + #"<|call|>{"name":"write_file","arguments":{"content":"func f() {}","path":"b"}}"#
            + "<|end|>"

        XCTAssertEqual(
            calls(envelope).map(\.name), ["write_file"],
            "the bound must not cost the later call, and must not fabricate a spanning one")
    }

    /// The rejected alternative, pinned so nobody re-implements it: bounding the WALK (not
    /// just the anchor) looks equivalent and silently drops healthy calls. Roles in this
    /// project write documentation about the Harmony format into files, so `<|end|>` inside
    /// a string value is a real payload, not a hypothetical.
    /// RED: bound the walk at `salvageEndMarker` instead of only the salvage anchor → the
    /// walk is cut inside `content`, the braces never balance, and this healthy call dies.
    func testHealthyEnvelopeCarryingTheEndMarkerInsideAStringValue_stillResolves() {
        let envelope =
            #"<|call|>{"name":"write_file","arguments":{"content":"write <|end|> to stop","path":"a.md"}}"#
            + "<|end|>"

        XCTAssertEqual(calls(envelope).map(\.name), ["write_file"])
        XCTAssertEqual(arguments(envelope)["content"] as? String, "write <|end|> to stop")
    }

    // MARK: - 5. The guards the new arm must NOT weaken

    /// Isolated from the colon guard on purpose: this fixture has NO structural colon, so
    /// the flag is clear and only the missing anchor can refuse it. (A payload like
    /// `{"name":"x","arguments":{"p":"a` would be refused by the flag instead and would
    /// leave this guard untested.)
    /// RED: drop the `lastCloseEnd != nil` condition → there is no anchor to truncate at,
    /// so the salvage invents a span out of a payload with no observed structure.
    func testNoCloseEverObserved_staysRefusedEvenThoughTheColonFlagIsClear() {
        XCTAssertNil(salvage(#"{"arguments"#))
    }

    /// RED: raise `maxSalvageDepth` or drop the depth condition from the shared guard →
    /// a four-deep imbalance is padded instead of failing closed.
    func testDepthBeyondTheBudget_staysRefusedInTheMidStringArmToo() {
        XCTAssertNil(salvage(#"{"a":{"b":{"c":{"d":{"e":1},"f"#))
    }
}
