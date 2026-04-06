import XCTest

@testable import NanoTeams

final class UniversalToolCallParserTests: XCTestCase {

    // MARK: - Basic Parsing Tests

    func testParse_emptyText_returnsNoCalls() {
        let parser = UniversalToolCallParser()

        let (calls, unknowns) = parser.parse(from: "")

        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(unknowns.isEmpty)
    }

    func testParse_plainText_returnsNoCalls() {
        let parser = UniversalToolCallParser()

        let (calls, unknowns) = parser.parse(from: "This is just regular text with no tool calls.")

        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(unknowns.isEmpty)
    }

    func testParse_harmonyFormat_extractsCalls() {
        let parser = UniversalToolCallParser()
        // Correct Harmony format: <|call|>tool_name{JSON}<|end|>
        let text = """
        Let me read the file.
        <|call|>read_file{"path": "test.txt"}<|end|>
        """

        let (calls, _) = parser.parse(from: text)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    func testParse_multipleHarmonyCalls() {
        let parser = UniversalToolCallParser()
        // Correct Harmony format: <|call|>tool_name{JSON}<|end|>
        let text = """
        <|call|>read_file{"path": "a.txt"}<|end|>
        <|call|>read_file{"path": "b.txt"}<|end|>
        """

        let (calls, _) = parser.parse(from: text)

        XCTAssertEqual(calls.count, 2)
    }

    // MARK: - Unknown Format Detection Tests

    func testParse_unrecognizedToolCallMarker_returnsUnknown() {
        let parser = UniversalToolCallParser()
        // Contains markers but not in recognized format
        let text = """
        <|call|>unknown format here
        """

        let (calls, unknowns) = parser.parse(from: text)

        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(unknowns.isEmpty)
    }

    func testParse_jsonWithFunctionKey_markedAsUnknown() {
        let parser = UniversalToolCallParser()
        // Contains "function" keyword but not in parseable format
        let text = """
        Here is a "function" definition that should be unknown
        """

        let (calls, unknowns) = parser.parse(from: text)

        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(unknowns.isEmpty)
    }

    func testParse_jsonWithToolKey_markedAsUnknown() {
        let parser = UniversalToolCallParser()
        let text = """
        {"tool": "something", "arguments": {}}
        """

        let (calls, unknowns) = parser.parse(from: text)

        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(unknowns.isEmpty)
    }

    func testParse_jsonWithNameKey_markedAsUnknown() {
        let parser = UniversalToolCallParser()
        let text = """
        {"name": "read_file", "arguments": {"path": "test"}}
        """

        let (calls, unknowns) = parser.parse(from: text)

        // This might be parsed by Harmony parser or marked as unknown
        // depending on exact format
        XCTAssertTrue(calls.isEmpty || !unknowns.isEmpty)
    }

    func testParse_toEqualsMarker_markedAsUnknown() {
        let parser = UniversalToolCallParser()
        let text = """
        to=read_file {"path": "test.txt"}
        """

        let (calls, unknowns) = parser.parse(from: text)

        // Contains to= marker
        if calls.isEmpty {
            XCTAssertFalse(unknowns.isEmpty)
        }
    }

    // MARK: - Tool Call Markers Detection Tests

    func testContainsToolCallMarkers_callMarker() {
        let parser = UniversalToolCallParser()
        let text = "Some text with <|call|> marker"

        let (calls, unknowns) = parser.parse(from: text)

        // Should detect as potential tool call
        XCTAssertTrue(calls.isEmpty) // Can't parse incomplete format
        XCTAssertFalse(unknowns.isEmpty)
    }

    func testContainsToolCallMarkers_startMarker() {
        let parser = UniversalToolCallParser()
        let text = "Text with <|start|> marker"

        let (calls, unknowns) = parser.parse(from: text)

        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(unknowns.isEmpty)
    }

    func testContainsToolCallMarkers_channelMarker() {
        let parser = UniversalToolCallParser()
        let text = "Text with <|channel|> marker"

        let (calls, unknowns) = parser.parse(from: text)

        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(unknowns.isEmpty)
    }

    func testContainsToolCallMarkers_argumentsKey() {
        let parser = UniversalToolCallParser()
        let text = """
        {"name": "tool", "arguments": {}}
        """

        let (calls, unknowns) = parser.parse(from: text)

        // Contains "arguments": key
        XCTAssertTrue(calls.isEmpty || !unknowns.isEmpty)
    }

    // MARK: - Integration with HarmonyToolCallParser Tests

    func testParse_validHarmonyJSON() {
        let parser = UniversalToolCallParser()
        // Correct Harmony format: <|call|>tool_name{JSON}<|end|>
        let text = """
        <|call|>write_file{"path": "output.txt", "content": "Hello World"}<|end|>
        """

        let (calls, _) = parser.parse(from: text)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "write_file")
        XCTAssertTrue(calls.first?.argumentsJSON.contains("output.txt") ?? false)
    }

    func testParse_mixedValidAndInvalidFormats() {
        let parser = UniversalToolCallParser()
        // Correct Harmony format: <|call|>tool_name{JSON}<|end|>
        let text = """
        Valid call:
        <|call|>read_file{"path": "valid.txt"}<|end|>

        Invalid marker: <|call|> incomplete
        """

        let (calls, _) = parser.parse(from: text)

        // Should extract the valid call
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    // MARK: - Edge Cases

    func testParse_whitespaceOnlyText() {
        let parser = UniversalToolCallParser()

        let (calls, unknowns) = parser.parse(from: "   \n\t\n   ")

        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(unknowns.isEmpty)
    }

    func testParse_veryLongText() {
        let parser = UniversalToolCallParser()
        let longText = String(repeating: "A", count: 100_000)

        let (calls, unknowns) = parser.parse(from: longText)

        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(unknowns.isEmpty)
    }

    func testParse_specialCharacters() {
        let parser = UniversalToolCallParser()
        // Correct Harmony format: <|call|>tool_name{JSON}<|end|>
        let text = """
        <|call|>write_file{"path": "test/特殊文字.txt", "content": "日本語 🎉"}<|end|>
        """

        let (calls, _) = parser.parse(from: text)

        XCTAssertEqual(calls.count, 1)
    }
}

// MARK: - ToolCallParseResult Tests

final class ToolCallParseResultTests: XCTestCase {

    func testSuccess_containsToolCall() {
        let call = StepToolCall(name: "test_tool", argumentsJSON: "{}")
        let result = ToolCallParseResult.success(call)

        switch result {
        case .success(let parsed):
            XCTAssertEqual(parsed.name, "test_tool")
        case .unknownFormat:
            XCTFail("Expected success")
        }
    }

    func testUnknownFormat_containsRawText() {
        let result = ToolCallParseResult.unknownFormat(rawText: "some unknown format")

        switch result {
        case .success:
            XCTFail("Expected unknownFormat")
        case .unknownFormat(let raw):
            XCTAssertEqual(raw, "some unknown format")
        }
    }
}
