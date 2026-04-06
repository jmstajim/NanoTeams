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
}
