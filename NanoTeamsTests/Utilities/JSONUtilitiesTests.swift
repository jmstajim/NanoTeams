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

    // MARK: - sanitizeJSONControlCharacters: invalid-escape recovery
    //
    // Verbatim defect from a Coding-Agent headless run (network_log.json response
    // 79D38613, model google/gemma-4-26b-a4b): a large edit_file call whose `new_text`
    // contained a hallucinated Python line-continuation backslash before a real newline —
    // `...range(self.num_experts):` + `\` + <newline>. A backslash followed by an
    // unescaped control char is an invalid JSON escape (and the raw newline is itself
    // illegal inside a JSON string), so JSONSerialization rejected the whole tool call and
    // the model looped on the malformed-JSON nudge. The sanitizer previously trusted the
    // char after a `\` blindly, leaving the broken sequence intact.

    func testSanitize_recoversStrayBackslashBeforeNewline() {
        // new_text value: `for i in range(n):` + `\` + <real newline> + `    # comment`
        let broken = #"{"new_text":"for i in range(n):"# + "\\" + "\n" + #"    # comment"}"#
        // Sanity: the raw payload IS strict-broken (invalid escape + raw control char).
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken),
                     "Pre-condition: the stray-backslash payload must fail strict parse")

        let sanitized = JSONUtilities.sanitizeJSONControlCharacters(broken)
        let parsed = JSONUtilities.parseJSONDictionary(sanitized)
        XCTAssertNotNil(parsed, "Sanitize must make the stray-backslash payload parseable")
        let value = parsed?["new_text"] as? String ?? ""
        XCTAssertTrue(value.contains("for i in range(n):"), "Prefix must survive: \(value)")
        XCTAssertTrue(value.contains("# comment"), "Suffix must survive: \(value)")
    }

    func testSanitize_strayBackslashBeforeNonControlChar_failsClosed() {
        // A stray backslash before an ordinary char (`\U`, `\p` — invalid JSON escapes that
        // are NOT control chars) is intentionally NOT repaired: it is ambiguous (literal `\`
        // vs the model's intent) and repairing it risks silently corrupting an adjacent
        // VALID escape (see testSanitize_windowsPathWithValidEscapeChar_doesNotCorrupt). The
        // sanitizer leaves it for strict parse to reject → the model gets a retry nudge.
        // This matches pre-change behaviour; only the `\`+control-char defect is repaired.
        let broken = #"{"win":"C:\Users\path"}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken),
                     "Pre-condition: \\U is an invalid escape → strict-broken")
        XCTAssertNil(JSONUtilities.parseJSONDictionary(
            JSONUtilities.sanitizeJSONControlCharacters(broken)),
                     "Non-control stray backslashes must fail closed, not be silently repaired")
    }

    func testSanitize_windowsPathWithValidEscapeChar_doesNotCorrupt() {
        // Regression pin (silent-failure-hunter CRITICAL): `C:\Users\foo` mixes an invalid
        // escape (`\U`) with `\f` — where `f` IS a valid JSON escape char (form-feed). A
        // broad "repair every invalid backslash" pass would fix `\U` (making the whole
        // string parse) while leaving `\f` to decode as a form-feed (U+000C) — silently
        // dispatching a corrupted path `C:\Users<FF>oo`. The sanitizer must instead fail
        // closed (leave the value for the model to retry), never emit a control char into a
        // value that parses.
        let broken = #"{"path":"C:\Users\foo"}"#
        let sanitized = JSONUtilities.sanitizeJSONControlCharacters(broken)
        let parsed = JSONUtilities.parseJSONDictionary(sanitized)
        if let path = parsed?["path"] as? String {
            XCTAssertFalse(path.unicodeScalars.contains { $0.value < 0x20 },
                           "Sanitize must never silently emit a control char into a parseable value; got \(path.unicodeScalars.map(\.value))")
            // If it parsed at all, it must be the faithful literal path (no form-feed).
            XCTAssertEqual(path, #"C:\Users\foo"#)
        }
        // The expected, safe outcome is fail-closed:
        XCTAssertNil(parsed,
                     "Ambiguous mixed invalid+valid-escape path must fail closed, not mis-dispatch")
    }

    func testSanitize_escapesRawNonNewlineControlChar() {
        // appendEscapingControlCharacter's default branch (\u%04x) — a raw ESC (0x1B) inside
        // a string, no backslash, must be escaped so the JSON parses and round-trips.
        let broken = #"{"x":"a"# + "\u{1b}" + #"b"}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken), "Raw ESC byte → strict-broken")
        let parsed = JSONUtilities.parseJSONDictionary(
            JSONUtilities.sanitizeJSONControlCharacters(broken))
        XCTAssertEqual(parsed?["x"] as? String, "a\u{1b}b",
                       "Raw control char must round-trip via \\u001b")
    }

    func testSanitize_preservesValidEscapeSequences() {
        // All valid JSON escapes inside a value (\n \t \" \\ \/) must round-trip intact —
        // the invalid-escape fix must be a pure superset of prior behaviour.
        let valid = #"{"code":"a\nb\tc\"d\\e\/f"}"#
        XCTAssertNotNil(JSONUtilities.parseJSONDictionary(valid),
                        "Control: payload is valid on its own")
        let sanitized = JSONUtilities.sanitizeJSONControlCharacters(valid)
        let parsed = JSONUtilities.parseJSONDictionary(sanitized)
        XCTAssertEqual(parsed?["code"] as? String, "a\nb\tc\"d\\e/f",
                       "Valid escapes must decode unchanged after sanitize")
    }

    func testSanitize_stillEscapesRawControlCharacters() {
        // Existing behaviour: a raw newline inside a string (no preceding backslash) is
        // escaped so the JSON parses. Must remain intact after the invalid-escape fix.
        let broken = #"{"text":"line1"# + "\n" + #"line2"}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken), "Raw newline → strict-broken")
        let parsed = JSONUtilities.parseJSONDictionary(
            JSONUtilities.sanitizeJSONControlCharacters(broken))
        XCTAssertEqual(parsed?["text"] as? String, "line1\nline2")
    }
}
