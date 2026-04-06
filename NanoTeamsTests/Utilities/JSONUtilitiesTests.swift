import XCTest
@testable import NanoTeams

/// Tests for JSONUtilities - centralized JSON parsing and serialization
final class JSONUtilitiesTests: XCTestCase {

    // MARK: - parseJSONDictionary Tests

    func testParseJSONDictionarySimple() {
        let json = """
        {"key": "value"}
        """
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?["key"] as? String, "value")
    }

    func testParseJSONDictionaryWithMultipleKeys() {
        let json = """
        {"name": "test", "count": 42, "active": true}
        """
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?["name"] as? String, "test")
        XCTAssertEqual(result?["count"] as? Int, 42)
        XCTAssertEqual(result?["active"] as? Bool, true)
    }

    func testParseJSONDictionaryWithNestedObjects() {
        let json = """
        {"outer": {"inner": "value"}}
        """
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNotNil(result)
        let outer = result?["outer"] as? [String: Any]
        XCTAssertNotNil(outer)
        XCTAssertEqual(outer?["inner"] as? String, "value")
    }

    func testParseJSONDictionaryWithArray() {
        let json = """
        {"items": [1, 2, 3]}
        """
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNotNil(result)
        let items = result?["items"] as? [Int]
        XCTAssertEqual(items, [1, 2, 3])
    }

    func testParseJSONDictionaryEmpty() {
        let json = "{}"
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.isEmpty ?? false)
    }

    func testParseJSONDictionaryInvalidJSON() {
        let json = "not valid json"
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNil(result)
    }

    func testParseJSONDictionaryMalformedJSON() {
        let json = """
        {"key": "value"
        """
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNil(result)
    }

    func testParseJSONDictionaryArrayNotDictionary() {
        let json = "[1, 2, 3]"
        let result = JSONUtilities.parseJSONDictionary(json)

        // Should return nil because it's an array, not a dictionary
        XCTAssertNil(result)
    }

    func testParseJSONDictionaryEmptyString() {
        let json = ""
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNil(result)
    }

    func testParseJSONDictionaryWithNullValue() {
        let json = """
        {"key": null}
        """
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNotNil(result)
        XCTAssertTrue(result?["key"] is NSNull)
    }

    func testParseJSONDictionaryWithSpecialCharacters() {
        let json = """
        {"message": "Hello\\nWorld"}
        """
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?["message"] as? String, "Hello\nWorld")
    }

    func testParseJSONDictionaryWithUnicode() {
        let json = """
        {"emoji": "🎉", "unicode": "Hello"}
        """
        let result = JSONUtilities.parseJSONDictionary(json)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?["emoji"] as? String, "🎉")
        XCTAssertEqual(result?["unicode"] as? String, "Hello")
    }

    // MARK: - jsonStringForToolArgs Tests

    func testJsonStringForToolArgsSimple() {
        let dict: [String: Any] = ["key": "value"]
        let result = JSONUtilities.jsonStringForToolArgs(dict)

        XCTAssertEqual(result, "{\"key\":\"value\"}")
    }

    func testJsonStringForToolArgsEmpty() {
        let dict: [String: Any] = [:]
        let result = JSONUtilities.jsonStringForToolArgs(dict)

        XCTAssertEqual(result, "{}")
    }

    func testJsonStringForToolArgsWithMultipleKeys() {
        let dict: [String: Any] = ["a": 1, "b": 2]
        let result = JSONUtilities.jsonStringForToolArgs(dict)

        // Keys are sorted
        XCTAssertEqual(result, "{\"a\":1,\"b\":2}")
    }

    func testJsonStringForToolArgsSortedKeys() {
        let dict: [String: Any] = ["z": 1, "a": 2, "m": 3]
        let result = JSONUtilities.jsonStringForToolArgs(dict)

        // Should be sorted alphabetically
        XCTAssertEqual(result, "{\"a\":2,\"m\":3,\"z\":1}")
    }

    func testJsonStringForToolArgsWithString() {
        let dict: [String: Any] = ["name": "test"]
        let result = JSONUtilities.jsonStringForToolArgs(dict)

        XCTAssertEqual(result, "{\"name\":\"test\"}")
    }

    func testJsonStringForToolArgsWithNumber() {
        let dict: [String: Any] = ["count": 42]
        let result = JSONUtilities.jsonStringForToolArgs(dict)

        XCTAssertEqual(result, "{\"count\":42}")
    }

    func testJsonStringForToolArgsWithBoolean() {
        let dict: [String: Any] = ["active": true]
        let result = JSONUtilities.jsonStringForToolArgs(dict)

        XCTAssertEqual(result, "{\"active\":true}")
    }

    func testJsonStringForToolArgsWithArray() {
        let dict: [String: Any] = ["items": [1, 2, 3]]
        let result = JSONUtilities.jsonStringForToolArgs(dict)

        XCTAssertEqual(result, "{\"items\":[1,2,3]}")
    }

    func testJsonStringForToolArgsWithNestedDictionary() {
        let dict: [String: Any] = ["outer": ["inner": "value"]]
        let result = JSONUtilities.jsonStringForToolArgs(dict)

        XCTAssertEqual(result, "{\"outer\":{\"inner\":\"value\"}}")
    }

    // MARK: - escapeForJSON Tests

    func testEscapeForJSONPlainString() {
        let result = JSONUtilities.escapeForJSON("hello world")
        XCTAssertEqual(result, "hello world")
    }

    func testEscapeForJSONWithQuotes() {
        let result = JSONUtilities.escapeForJSON("say \"hello\"")
        XCTAssertEqual(result, "say \\\"hello\\\"")
    }

    func testEscapeForJSONWithBackslash() {
        let result = JSONUtilities.escapeForJSON("path\\to\\file")
        XCTAssertEqual(result, "path\\\\to\\\\file")
    }

    func testEscapeForJSONWithNewline() {
        let result = JSONUtilities.escapeForJSON("line1\nline2")
        XCTAssertEqual(result, "line1\\nline2")
    }

    func testEscapeForJSONWithCarriageReturn() {
        let result = JSONUtilities.escapeForJSON("line1\rline2")
        XCTAssertEqual(result, "line1\\rline2")
    }

    func testEscapeForJSONWithTab() {
        let result = JSONUtilities.escapeForJSON("col1\tcol2")
        XCTAssertEqual(result, "col1\\tcol2")
    }

    func testEscapeForJSONWithAllSpecialChars() {
        let result = JSONUtilities.escapeForJSON("\"test\\\n\r\t\"")
        XCTAssertEqual(result, "\\\"test\\\\\\n\\r\\t\\\"")
    }

    func testEscapeForJSONEmptyString() {
        let result = JSONUtilities.escapeForJSON("")
        XCTAssertEqual(result, "")
    }

    func testEscapeForJSONWithUnicode() {
        let result = JSONUtilities.escapeForJSON("Hello 🌍")
        XCTAssertEqual(result, "Hello 🌍")
    }

    func testEscapeForJSONWithMultibyteCharacters() {
        let result = JSONUtilities.escapeForJSON("Hello world")
        XCTAssertEqual(result, "Hello world")
    }

    // MARK: - value(in:at:) Tests

    func testValueAtKeyPathSimple() {
        let dict: [String: Any] = ["key": "value"]
        let result = JSONUtilities.value(in: dict, at: "key")

        XCTAssertEqual(result as? String, "value")
    }

    func testValueAtKeyPathNested() {
        let dict: [String: Any] = ["outer": ["inner": "value"]]
        let result = JSONUtilities.value(in: dict, at: "outer.inner")

        XCTAssertEqual(result as? String, "value")
    }

    func testValueAtKeyPathDeeplyNested() {
        let dict: [String: Any] = [
            "level1": [
                "level2": [
                    "level3": [
                        "value": 42
                    ]
                ]
            ]
        ]
        let result = JSONUtilities.value(in: dict, at: "level1.level2.level3.value")

        XCTAssertEqual(result as? Int, 42)
    }

    func testValueAtKeyPathNotFound() {
        let dict: [String: Any] = ["key": "value"]
        let result = JSONUtilities.value(in: dict, at: "nonexistent")

        XCTAssertNil(result)
    }

    func testValueAtKeyPathPartialNotFound() {
        let dict: [String: Any] = ["outer": ["inner": "value"]]
        let result = JSONUtilities.value(in: dict, at: "outer.nonexistent")

        XCTAssertNil(result)
    }

    func testValueAtKeyPathEmptyPath() {
        let dict: [String: Any] = ["key": "value"]
        let result = JSONUtilities.value(in: dict, at: "")

        // Empty path should return the whole dict
        XCTAssertNotNil(result)
    }

    func testValueAtKeyPathIntermediateNotDictionary() {
        let dict: [String: Any] = ["key": "string_not_dict"]
        let result = JSONUtilities.value(in: dict, at: "key.nested")

        // Should return nil because "key" is a string, not a dictionary
        XCTAssertNil(result)
    }

    func testValueAtKeyPathWithArray() {
        let dict: [String: Any] = ["items": [1, 2, 3]]
        let result = JSONUtilities.value(in: dict, at: "items")

        XCTAssertNotNil(result)
        XCTAssertEqual(result as? [Int], [1, 2, 3])
    }

    func testValueAtKeyPathWithNumber() {
        let dict: [String: Any] = ["data": ["count": 100]]
        let result = JSONUtilities.value(in: dict, at: "data.count")

        XCTAssertEqual(result as? Int, 100)
    }

    func testValueAtKeyPathWithBoolean() {
        let dict: [String: Any] = ["config": ["enabled": true]]
        let result = JSONUtilities.value(in: dict, at: "config.enabled")

        XCTAssertEqual(result as? Bool, true)
    }

    func testValueAtKeyPathEmptyDict() {
        let dict: [String: Any] = [:]
        let result = JSONUtilities.value(in: dict, at: "any.path")

        XCTAssertNil(result)
    }

    // MARK: - Round-trip Tests

    func testParseAndSerializeRoundTrip() {
        let original: [String: Any] = ["name": "test", "count": 42]
        let serialized = JSONUtilities.jsonStringForToolArgs(original)
        let parsed = JSONUtilities.parseJSONDictionary(serialized)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["name"] as? String, "test")
        XCTAssertEqual(parsed?["count"] as? Int, 42)
    }

    func testEscapeAndParseRoundTrip() {
        let original = "Hello \"World\"\nNew Line"
        let escaped = JSONUtilities.escapeForJSON(original)
        let json = "{\"message\": \"\(escaped)\"}"
        let parsed = JSONUtilities.parseJSONDictionary(json)

        XCTAssertEqual(parsed?["message"] as? String, original)
    }
}
