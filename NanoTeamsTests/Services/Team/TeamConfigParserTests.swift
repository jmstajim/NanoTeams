import XCTest

@testable import NanoTeams

/// Direct corner-case coverage for the pure helpers extracted into
/// `TeamConfigParser` that had **no dedicated unit tests** before the
/// extraction: `describeDecodingError`, `extractInnerTeamConfig`, and
/// `reUnescapeInnerJSON`.
///
/// The rest of the parser's surface — `decodeTeamConfig` / `extractJSONObject`
/// / the repair chain / `mergeMisplacedSiblings` / the sibling-merge counter —
/// is already exercised by `TeamGenerationServiceTests`, which was repointed to
/// `TeamConfigParser` when the parser was split out of `TeamGenerationService`.
final class TeamConfigParserTests: XCTestCase {

    /// Minimal `CodingKey` for hand-building `DecodingError.Context` values.
    private struct TestKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // MARK: - describeDecodingError

    func testDescribeDecodingError_typeMismatch_namesTypePathAndDebugDescription() {
        let ctx = DecodingError.Context(
            codingPath: [TestKey(stringValue: "roles")!],
            debugDescription: "expected an array"
        )
        let msg = TeamConfigParser.describeDecodingError(DecodingError.typeMismatch([String].self, ctx))
        XCTAssertTrue(msg.contains("Type mismatch"), msg)
        XCTAssertTrue(msg.contains("roles"), "must name the coding path: \(msg)")
        XCTAssertTrue(msg.contains("expected an array"), "must carry debugDescription: \(msg)")
    }

    func testDescribeDecodingError_keyNotFound_namesMissingKey() {
        let ctx = DecodingError.Context(codingPath: [], debugDescription: "no value associated")
        let msg = TeamConfigParser.describeDecodingError(
            DecodingError.keyNotFound(TestKey(stringValue: "name")!, ctx))
        XCTAssertTrue(msg.contains("Key not found: name"), msg)
    }

    func testDescribeDecodingError_valueNotFound_namesTypeAndPath() {
        let ctx = DecodingError.Context(
            codingPath: [TestKey(stringValue: "supervisor_requires")!],
            debugDescription: "null where String expected"
        )
        let msg = TeamConfigParser.describeDecodingError(DecodingError.valueNotFound(String.self, ctx))
        XCTAssertTrue(msg.contains("Value not found"), msg)
        XCTAssertTrue(msg.contains("supervisor_requires"), msg)
    }

    func testDescribeDecodingError_dataCorrupted_emptyPath_omitsPathSegment() {
        let ctx = DecodingError.Context(codingPath: [], debugDescription: "bad enum value")
        let msg = TeamConfigParser.describeDecodingError(DecodingError.dataCorrupted(ctx))
        XCTAssertTrue(msg.contains("Data corrupted"), msg)
        XCTAssertTrue(msg.contains("bad enum value"), msg)
        XCTAssertFalse(msg.contains(" at `"),
                       "empty codingPath must omit the ` at path` segment: \(msg)")
    }

    func testDescribeDecodingError_nestedPath_joinsSegmentsWithDots() {
        let ctx = DecodingError.Context(
            codingPath: [TestKey(stringValue: "roles")!, TestKey(stringValue: "tools")!],
            debugDescription: "x"
        )
        let msg = TeamConfigParser.describeDecodingError(DecodingError.dataCorrupted(ctx))
        XCTAssertTrue(msg.contains("roles.tools"), "nested path must join with dots: \(msg)")
    }

    func testDescribeDecodingError_nonDecodingError_fallsBackToLocalizedDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "kaboom" } }
        XCTAssertEqual(TeamConfigParser.describeDecodingError(Boom()), "kaboom")
    }

    // MARK: - extractInnerTeamConfig

    func testExtractInnerTeamConfig_objectForm_returnsInnerVerbatim() {
        let input = #"{"team_config":{"name":"X","roles":[]}}"#
        XCTAssertEqual(
            TeamConfigParser.extractInnerTeamConfig(from: input),
            #"{"name":"X","roles":[]}"#
        )
    }

    func testExtractInnerTeamConfig_stringForm_unescapesInner() {
        // Inner JSON is string-encoded with escaped quotes (`\"`); the extractor
        // brace-walks past the escapes, then JSON-string-unescapes the captured span.
        let input = #"{"team_config":"{\"name\":\"X\"}"}"#
        XCTAssertEqual(TeamConfigParser.extractInnerTeamConfig(from: input), #"{"name":"X"}"#)
    }

    func testExtractInnerTeamConfig_nestedBraces_capturesWholeObject() {
        let input = #"{"team_config":{"a":{"b":1},"c":2}}"#
        XCTAssertEqual(
            TeamConfigParser.extractInnerTeamConfig(from: input),
            #"{"a":{"b":1},"c":2}"#
        )
    }

    func testExtractInnerTeamConfig_noTeamConfigKey_returnsNil() {
        XCTAssertNil(TeamConfigParser.extractInnerTeamConfig(from: #"{"name":"X","roles":[]}"#))
    }

    func testExtractInnerTeamConfig_unbalancedBraces_returnsNil() {
        // Opening `{` with no matching close — the brace walk runs off the end.
        XCTAssertNil(TeamConfigParser.extractInnerTeamConfig(from: #"{"team_config":{"name":"X""#))
    }

    // MARK: - reUnescapeInnerJSON

    func testReUnescape_unescapesEscapedQuotes() {
        // input:  \"x\"   →   "x"
        XCTAssertEqual(TeamConfigParser.reUnescapeInnerJSON("\\\"x\\\""), "\"x\"")
    }

    func testReUnescape_unescapesWhitespaceAndSlashEscapes() {
        XCTAssertEqual(TeamConfigParser.reUnescapeInnerJSON("a\\nb"), "a\nb")
        XCTAssertEqual(TeamConfigParser.reUnescapeInnerJSON("a\\tb"), "a\tb")
        XCTAssertEqual(TeamConfigParser.reUnescapeInnerJSON("a\\rb"), "a\rb")
        XCTAssertEqual(TeamConfigParser.reUnescapeInnerJSON("path\\/to"), "path/to")
    }

    func testReUnescape_collapsesDoubleBackslash() {
        // input: a\\b (a, backslash, backslash, b)  →  a\b
        XCTAssertEqual(TeamConfigParser.reUnescapeInnerJSON("a\\\\b"), "a\\b")
    }

    func testReUnescape_noEscapes_returnsInputUnchanged() {
        XCTAssertEqual(TeamConfigParser.reUnescapeInnerJSON("plain text 123"), "plain text 123")
        XCTAssertEqual(TeamConfigParser.reUnescapeInnerJSON(""), "")
    }

    // MARK: - extractJSONObject — fenced / raw / trailing junk

    func testExtractJSONObject_fencedJSONBlock_extractsInner() {
        let input = "Here is the team:\n```json\n{\"name\":\"X\"}\n```\nDone."
        XCTAssertEqual(TeamConfigParser.extractJSONObject(from: input), "{\"name\":\"X\"}")
    }

    func testExtractJSONObject_plainFencedBlock_extractsInner() {
        let input = "```\n{\"name\":\"X\"}\n```"
        XCTAssertEqual(TeamConfigParser.extractJSONObject(from: input), "{\"name\":\"X\"}")
    }

    func testExtractJSONObject_rawObjectInProse_extractsFirstBalanced() {
        XCTAssertEqual(
            TeamConfigParser.extractJSONObject(from: "prose {\"a\":1} trailing junk"),
            "{\"a\":1}"
        )
    }

    func testExtractJSONObject_bracesInsideStrings_doNotPerturbDepth() {
        XCTAssertEqual(
            TeamConfigParser.extractJSONObject(from: #"{"a":"}{ braces in string","b":1}"#),
            #"{"a":"}{ braces in string","b":1}"#
        )
    }

    func testExtractJSONObject_noObject_returnsNil() {
        XCTAssertNil(TeamConfigParser.extractJSONObject(from: ""))
        XCTAssertNil(TeamConfigParser.extractJSONObject(from: "no json here at all"))
    }

    // MARK: - extractJSONObject — truncation salvage (depth boundary ≤ 3)

    func testExtractJSONObject_truncatedDepth1_salvagedWithOneCloser() {
        XCTAssertEqual(TeamConfigParser.extractJSONObject(from: "{\"a\":1"), "{\"a\":1}")
    }

    func testExtractJSONObject_truncatedDepth2_salvaged() {
        XCTAssertEqual(
            TeamConfigParser.extractJSONObject(from: "{\"a\":{\"b\":1"),
            "{\"a\":{\"b\":1}}"
        )
    }

    func testExtractJSONObject_truncatedDepth3_salvaged_atBoundary() {
        XCTAssertEqual(
            TeamConfigParser.extractJSONObject(from: "{\"a\":{\"b\":{\"c\":1"),
            "{\"a\":{\"b\":{\"c\":1}}}"
        )
    }

    func testExtractJSONObject_truncatedDepth4_exceedsSalvageCap_returnsNil() {
        // depth 4 > maxSalvageDepth (3) → too garbled to safely synthesize closers.
        XCTAssertNil(TeamConfigParser.extractJSONObject(from: "{\"a\":{\"b\":{\"c\":{\"d\":1"))
    }

    func testExtractJSONObject_truncatedAfterLastClose_dropsTrailingJunk() {
        // Stream ended mid-envelope after a complete inner object — salvage truncates
        // at the last observed `}` and pads, dropping the partial tail.
        XCTAssertEqual(
            TeamConfigParser.extractJSONObject(from: "{\"a\":{\"b\":1} garb"),
            "{\"a\":{\"b\":1}}"
        )
    }

    // MARK: - repairMissingArrayClose

    func testRepairMissingArrayClose_droppedInnerArrayClose_isRepaired() {
        // `["x"}]` should have been `["x"]}]` — the inner array's `]` was dropped.
        let buggy = #"{"items":[{"tags":["x"}]}"#
        XCTAssertEqual(
            TeamConfigParser.repairMissingArrayClose(buggy),
            #"{"items":[{"tags":["x"]}]}"#
        )
    }

    func testRepairMissingArrayClose_noPattern_returnsNil() {
        XCTAssertNil(TeamConfigParser.repairMissingArrayClose(#"{"a":1}"#))
    }

    func testRepairMissingArrayClose_legitimateArrayOfObjects_returnsNil() {
        // `[{"a":"b"}]` is valid; injecting `]` would BREAK it, so no candidate
        // parses → nil (the repair must not corrupt already-valid JSON).
        XCTAssertNil(TeamConfigParser.repairMissingArrayClose(#"{"k":[{"a":"b"}]}"#))
    }

    // MARK: - repairUnescapedInteriorQuotes

    func testRepairUnescapedInteriorQuotes_escapesInteriorQuotes() {
        let buggy = #"{"a":"he said "hi" ok"}"#
        XCTAssertEqual(
            TeamConfigParser.repairUnescapedInteriorQuotes(buggy),
            #"{"a":"he said \"hi\" ok"}"#
        )
    }

    func testRepairUnescapedInteriorQuotes_validInput_unchanged() {
        let valid = #"{"a":"b","c":1}"#
        XCTAssertEqual(TeamConfigParser.repairUnescapedInteriorQuotes(valid), valid)
    }

    func testRepairUnescapedInteriorQuotes_alreadyEscaped_preserved() {
        // Backslash before the quote → treated as escaped, not a close.
        let already = #"{"a":"x \" y"}"#
        XCTAssertEqual(TeamConfigParser.repairUnescapedInteriorQuotes(already), already)
    }
}
