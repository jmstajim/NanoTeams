import XCTest
@testable import NanoTeams

final class ToolCallParsingHelpersTests: XCTestCase {

    // MARK: - skipWhitespace

    func testSkipWhitespace_skipsSpacesAndTabs() {
        let s: Substring = "   hello"
        let result = ToolCallParsingHelpers.skipWhitespace(in: s, from: s.startIndex)
        XCTAssertEqual(s[result], "h")
    }

    func testSkipWhitespace_noWhitespace_returnsOriginal() {
        let s: Substring = "hello"
        let result = ToolCallParsingHelpers.skipWhitespace(in: s, from: s.startIndex)
        XCTAssertEqual(result, s.startIndex)
    }

    func testSkipWhitespace_allWhitespace_returnsEnd() {
        let s: Substring = "   "
        let result = ToolCallParsingHelpers.skipWhitespace(in: s, from: s.startIndex)
        XCTAssertEqual(result, s.endIndex)
    }

    // MARK: - extractIdentifier

    func testExtractIdentifier_simpleWord() {
        let s: Substring = "read_file rest"
        let result = ToolCallParsingHelpers.extractIdentifier(in: s, from: s.startIndex)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, "read_file")
    }

    func testExtractIdentifier_withDotsAndDashes() {
        let s: Substring = "functions.read-file("
        let result = ToolCallParsingHelpers.extractIdentifier(in: s, from: s.startIndex)
        XCTAssertEqual(result?.0, "functions.read-file")
    }

    func testExtractIdentifier_digitsAllowed() {
        let s: Substring = "tool123 next"
        let result = ToolCallParsingHelpers.extractIdentifier(in: s, from: s.startIndex)
        XCTAssertEqual(result?.0, "tool123")
    }

    func testExtractIdentifier_emptyInput_returnsNil() {
        let s: Substring = ""
        XCTAssertNil(ToolCallParsingHelpers.extractIdentifier(in: s, from: s.startIndex))
    }

    func testExtractIdentifier_startsWithSpace_returnsNil() {
        let s: Substring = " hello"
        XCTAssertNil(ToolCallParsingHelpers.extractIdentifier(in: s, from: s.startIndex))
    }

    // MARK: - extractJSONBracedValue

    func testExtractJSON_simpleObject() {
        let s: Substring = "{\"key\": \"value\"} rest"
        let result = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, "{\"key\": \"value\"}")
    }

    func testExtractJSON_nestedObjects() {
        let s: Substring = "{\"a\": {\"b\": 1}} rest"
        let result = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(result?.0, "{\"a\": {\"b\": 1}}")
    }

    func testExtractJSON_withEscapedQuotes() {
        let s: Substring = "{\"msg\": \"hello \\\"world\\\"\"} rest"
        let result = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, "{\"msg\": \"hello \\\"world\\\"\"}")
    }

    func testExtractJSON_unclosedBrace_returnsNil() {
        let s: Substring = "{\"key\": \"value\""
        XCTAssertNil(ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex))
    }

    func testExtractJSON_array() {
        let s: Substring = "[1, 2, 3] rest"
        let result = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(result?.0, "[1, 2, 3]")
    }

    func testExtractJSON_nestedArray() {
        let s: Substring = "{\"arr\": [1, [2, 3]]} rest"
        let result = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(result?.0, "{\"arr\": [1, [2, 3]]}")
    }

    func testExtractJSON_emptyObject() {
        let s: Substring = "{} after"
        let result = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(result?.0, "{}")
    }

    func testExtractJSON_notBraceStart_returnsNil() {
        let s: Substring = "hello {}"
        XCTAssertNil(ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex))
    }

    func testExtractJSON_bracesInsideString_ignored() {
        let s: Substring = "{\"val\": \"{nested}\"} end"
        let result = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(result?.0, "{\"val\": \"{nested}\"}")
    }

    // MARK: - advanceCursor

    func testAdvanceCursor_markerFound_returnsAfterMarker() {
        let s: Substring = "hello<|end|>rest"
        let result = ToolCallParsingHelpers.advanceCursor(in: s, from: s.startIndex, endMarker: "<|end|>")
        let remaining = String(s[result...])
        XCTAssertEqual(remaining, "rest")
    }

    func testAdvanceCursor_markerNotFound_returnsOriginal() {
        let s: Substring = "hello world"
        let result = ToolCallParsingHelpers.advanceCursor(in: s, from: s.startIndex, endMarker: "<|end|>")
        XCTAssertEqual(result, s.startIndex)
    }

    // MARK: - normalizeArgumentsJSONString

    func testNormalizeJSON_sortsKeys() {
        let input = "{\"b\": 2, \"a\": 1}"
        let result = ToolCallParsingHelpers.normalizeArgumentsJSONString(input)
        let aIdx = result.range(of: "\"a\"")!.lowerBound
        let bIdx = result.range(of: "\"b\"")!.lowerBound
        XCTAssertLessThan(aIdx, bIdx)
    }

    func testNormalizeJSON_invalidJSON_returnsOriginal() {
        let input = "not json"
        XCTAssertEqual(ToolCallParsingHelpers.normalizeArgumentsJSONString(input), input)
    }

    func testNormalizeJSON_array_normalizes() {
        let input = "[3, 1, 2]"
        let result = ToolCallParsingHelpers.normalizeArgumentsJSONString(input)
        XCTAssertEqual(result, "[3,1,2]")
    }

    // MARK: - stableJSONString

    func testStableJSONString_dict_sortedKeys() {
        let dict: [String: Any] = ["b": 2, "a": 1]
        let result = ToolCallParsingHelpers.stableJSONString(from: dict)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("\"a\""))
        XCTAssertTrue(result!.contains("\"b\""))
    }

    func testStableJSONString_invalidObject_returnsNil() {
        // A plain string is not valid JSON object for JSONSerialization
        XCTAssertNil(ToolCallParsingHelpers.stableJSONString(from: "hello"))
    }

    // MARK: - parseToolCallFromJSON

    func testParseToolCall_nameFormat() {
        let json = "{\"name\": \"read_file\", \"arguments\": {\"path\": \"/file.swift\"}}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "read_file")
        XCTAssertTrue(result?.argumentsJSON.contains("/file.swift") ?? false)
    }

    func testParseToolCall_toolNameFormat() {
        let json = "{\"tool_name\": \"git_status\", \"args\": {}}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "git_status")
    }

    func testParseToolCall_toolFormat() {
        let json = "{\"tool\": \"list_files\", \"params\": {\"path\": \"/src\"}}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "list_files")
    }

    func testParseToolCall_functionFormat() {
        let json = "{\"function\": {\"name\": \"edit_file\", \"arguments\": {\"path\": \"/f.swift\"}}}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "edit_file")
    }

    func testParseToolCall_withProviderID() {
        let json = "{\"id\": \"call-123\", \"name\": \"read_file\", \"arguments\": {}}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertEqual(result?.providerID, "call-123")
    }

    func testParseToolCall_withCallID() {
        let json = "{\"call_id\": \"c456\", \"name\": \"list_files\", \"args\": {}}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertEqual(result?.providerID, "c456")
    }

    func testParseToolCall_invalidJSON_returnsNil() {
        XCTAssertNil(ToolCallParsingHelpers.parseToolCallFromJSON("not json"))
    }

    func testParseToolCall_noNameField_returnsNil() {
        let json = "{\"something\": \"else\"}"
        XCTAssertNil(ToolCallParsingHelpers.parseToolCallFromJSON(json))
    }

    func testParseToolCall_stringArguments() {
        let json = "{\"name\": \"write_file\", \"arguments\": \"raw string args\"}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.argumentsJSON, "raw string args")
    }

    // MARK: - parseToolCallFromJSON: lenient top-level argument synthesis

    /// Some models (e.g. gemma-4-26b-a4b) emit Harmony tool calls with `content`
    /// at the top level instead of inside `arguments`. Without lenient synthesis,
    /// `argumentsJSON` comes out empty → `update_scratchpad` fails with
    /// `INVALID_ARGS` → model loops retrying the same broken format.
    func testParseToolCall_synthesizesArgs_fromTopLevelContent_gemmaPattern() {
        let json = "{\"name\":\"update_scratchpad\",\"content\":\"# Plan: Add workingRoles query\"}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "update_scratchpad")
        XCTAssertTrue(
            result?.argumentsJSON.contains("\"content\":\"# Plan: Add workingRoles query\"") ?? false,
            "Expected synthesized args to contain promoted `content`, got: \(result?.argumentsJSON ?? "nil")"
        )
    }

    func testParseToolCall_synthesizesArgs_multipleTopLevelKeys() {
        let json = "{\"name\":\"write_file\",\"path\":\"/a.swift\",\"content\":\"x\"}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "write_file")
        let args = result?.argumentsJSON ?? ""
        XCTAssertTrue(args.contains("\"path\":\"/a.swift\""), "Expected `path` promoted, got: \(args)")
        XCTAssertTrue(args.contains("\"content\":\"x\""), "Expected `content` promoted, got: \(args)")
    }

    /// Explicit `arguments` always wins — top-level keys are ignored when an
    /// `arguments` block is present. Prevents accidental merging when a model
    /// emits both shapes simultaneously.
    func testParseToolCall_explicitArguments_takePrecedence_overTopLevelKeys() {
        let json = "{\"name\":\"write_file\",\"content\":\"oops_top_level\",\"arguments\":{\"path\":\"/real.swift\",\"content\":\"real\"}}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        let args = result?.argumentsJSON ?? ""
        XCTAssertTrue(args.contains("\"path\":\"/real.swift\""), "Expected explicit args used: \(args)")
        XCTAssertTrue(args.contains("\"content\":\"real\""), "Expected explicit content, not top-level: \(args)")
        XCTAssertFalse(args.contains("oops_top_level"), "Top-level `content` must be ignored when `arguments` exists: \(args)")
    }

    /// Identifier-only payload has nothing to promote — synthesis returns nil and
    /// `argumentsJSON` falls back to the empty-string convention used for "no args".
    /// (See `normalizeArgumentsJSON(nil)` in HarmonyToolCallParsingHelpers.)
    func testParseToolCall_noPromotableKeys_keepsEmptyArgs() {
        let json = "{\"name\":\"git_status\",\"id\":\"call-1\"}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "git_status")
        XCTAssertEqual(result?.providerID, "call-1")
        XCTAssertEqual(result?.argumentsJSON, "", "Expected empty-args fallback")
    }

    /// Synthesis must work for the `tool_name`/`tool`/`function_name` paths too,
    /// not only the `name` path.
    func testParseToolCall_synthesizesArgs_underToolNameKey() {
        let json = "{\"tool_name\":\"update_scratchpad\",\"content\":\"plan body\"}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "update_scratchpad")
        XCTAssertTrue(result?.argumentsJSON.contains("\"content\":\"plan body\"") ?? false)
    }

    /// Provider ID + content at top level: provider id stays out of the synthesized
    /// arguments (it's an envelope identifier, not a tool parameter).
    func testParseToolCall_synthesizesArgs_excludesProviderID() {
        let json = "{\"id\":\"call-9\",\"name\":\"ask_supervisor\",\"question\":\"what next?\"}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.providerID, "call-9")
        let args = result?.argumentsJSON ?? ""
        XCTAssertTrue(args.contains("\"question\":\"what next?\""), "Expected `question` promoted: \(args)")
        XCTAssertFalse(args.contains("call-9"), "Provider id must not leak into args: \(args)")
        XCTAssertFalse(args.contains("\"id\":"), "`id` key must not leak into args: \(args)")
    }

    /// I5 regression: Harmony framing fields (`type`, `channel`, `recipient`,
    /// `constrain`) and OpenAI tool-call envelope fields (`type:"function"`)
    /// must NEVER be promoted into synthesized args. A model emitting
    /// `{"name":"X","type":"function","content":"…"}` would otherwise pass
    /// `{"type":"function","content":"…"}` to the tool, producing
    /// `INVALID_ARGS` rejection or silent garbage acceptance.
    func testParseToolCall_synthesizesArgs_excludesFramingFields() {
        let json = #"""
        {
          "name": "update_scratchpad",
          "type": "function",
          "channel": "commentary",
          "recipient": "functions.update_scratchpad",
          "constrain": "json",
          "content": "plan body"
        }
        """#
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "update_scratchpad")
        let args = result?.argumentsJSON ?? ""

        XCTAssertTrue(args.contains("\"content\":\"plan body\""), "Real arg must be promoted: \(args)")
        XCTAssertFalse(args.contains("\"type\":"), "Harmony/OpenAI `type` must not leak: \(args)")
        XCTAssertFalse(args.contains("\"channel\":"), "Harmony `channel` must not leak: \(args)")
        XCTAssertFalse(args.contains("\"recipient\":"), "Harmony `recipient` must not leak: \(args)")
        XCTAssertFalse(args.contains("\"constrain\":"), "Harmony `constrain` must not leak: \(args)")
    }

    /// Each individual envelope key must be excluded — otherwise a regression
    /// like "removed `tool_name` from reserved set" would pass the multi-key
    /// happy-path test but break in production.
    func testParseToolCall_synthesizesArgs_excludesAllReservedEnvelopeKeys() {
        let envelopeKeys = ["call_id", "function", "tool", "function_name"]
        for key in envelopeKeys {
            let json = "{\"name\":\"X\",\"\(key)\":\"envelope-value\",\"real_arg\":\"keep\"}"
            let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
            XCTAssertNotNil(result, "Failed to parse for envelope key \(key)")
            let args = result?.argumentsJSON ?? ""
            XCTAssertTrue(args.contains("\"real_arg\":\"keep\""), "real_arg dropped for \(key): \(args)")
            XCTAssertFalse(args.contains("envelope-value"), "Envelope key '\(key)' leaked into args: \(args)")
        }
    }

    /// I5 + S8: regression test for the `Any?` vs `[String:Any]?` `??`-chain
    /// hazard documented in `synthesizeArgumentsFromTopLevel`. When the
    /// synthesized dict has zero promotable keys, the function MUST return
    /// `nil` (not an empty dict, not the literal string `"nil"`). Pre-fix the
    /// double-wrap caused `argumentsJSON` to be exactly `"nil"`.
    func testParseToolCall_synthesizesArgs_emptyDict_doesNotProduceNilString() {
        // Identifier-only payload — every top-level key is reserved.
        let json = "{\"name\":\"git_status\",\"id\":\"call-1\",\"type\":\"function\",\"channel\":\"commentary\"}"
        let result = ToolCallParsingHelpers.parseToolCallFromJSON(json)
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result?.argumentsJSON, "nil",
                          "argumentsJSON must never be the literal string 'nil' — that's the Any?/Dict? double-wrap hazard")
        XCTAssertEqual(result?.argumentsJSON, "",
                       "Empty synthesis must fall back to the empty-args convention")
    }
}
