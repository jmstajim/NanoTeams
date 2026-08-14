import XCTest

@testable import NanoTeams

/// Wave 11 — the argument shapes `ToolCallParsingHelpers` normalizes that no fixture had carried.
///
/// Both functions here sit on the path from "bytes a local model emitted" to "the `argumentsJSON`
/// string the tool runtime parses and the stateless resend re-materializes into a Harmony envelope".
/// A shape that falls through them wrong does not fail loudly: it reaches the handler as one
/// unusable argument value and costs the model a round trip, then rides every subsequent request
/// (CLAUDE.md's 2026-07-26 laundering entry is exactly this failure, found in the field rather than
/// in a test).
///
/// The uncovered arms were the NON-OBJECT ones. Every fixture in the corpus carries a JSON object,
/// because that is what a well-behaved call looks like — which is the reason the array and scalar
/// arms had never run, and the reason they are worth stating: they exist for the payloads that are
/// NOT well behaved.
final class HarmonyArgumentNormalizationCoverageTests: XCTestCase {

    // MARK: - normalizeArgumentsJSONString

    /// A top-level JSON ARRAY is re-serialised stably, exactly as an object is.
    ///
    /// Stability is the whole point of the function: the bytes it returns ride the wire on every
    /// stateless resend, and the app's only speed lever is a byte-identical prefix. An arm that
    /// returned the input unchanged would leak the model's key order (or, for an array, its
    /// whitespace) into the prefix on every turn.
    ///
    /// RED: delete `if let arr = object as? [Any] { return stableJSONString(from: arr) }` → the
    /// function falls to `return jsonText` and the whitespace assertion fails.
    func testNormalizeArgumentsJSONString_topLevelArray_isReserialisedStably() {
        let normalized = ToolCallParsingHelpers.normalizeArgumentsJSONString("[ 1,   2 ,3 ]")

        XCTAssertEqual(normalized, "[1,2,3]",
                       "an array must be re-serialised, not passed through with the model's spacing")
    }

    /// A payload that is neither an object nor an array — and is therefore not valid top-level JSON
    /// without `.fragmentsAllowed`, which this parser deliberately does not pass — comes back
    /// BYTE-IDENTICAL. That is the contract the doc comment states as "widens what is recoverable,
    /// never what is accepted": a Windows path, a regex, a bare word all survive untouched.
    ///
    /// RED: add `.fragmentsAllowed` to `normalizedJSONContainer`'s `jsonObject` options → `"42"`
    /// parses as a fragment, falls past both container arms to `return nil`, and… still returns the
    /// input. The honest RED is on the first case: change the final `return jsonText` to
    /// `return ""` → both assertions fail.
    func testNormalizeArgumentsJSONString_nonContainerPayloads_arePassedThroughUnchanged() {
        XCTAssertEqual(ToolCallParsingHelpers.normalizeArgumentsJSONString("42"), "42")
        XCTAssertEqual(
            ToolCallParsingHelpers.normalizeArgumentsJSONString(#"C:\Users\a\b.txt"#),
            #"C:\Users\a\b.txt"#,
            "a Windows path keeps its backslashes byte-for-byte")
    }

    // MARK: - parseToolCallFromJSON

    /// A call whose `arguments` is a bare SCALAR. The recognizer resolves the tool name from the
    /// top-level `name` and hands the scalar down; normalization has no JSON container to
    /// re-serialise, so it renders the value rather than dropping it.
    ///
    /// Rendering beats dropping here: the handler will reject `"42"` with a clear argument error the
    /// model can act on, whereas an empty `argumentsJSON` reads as "the model called the tool with no
    /// arguments" and the handler's own missing-argument message names the wrong problem.
    ///
    /// RED: change the final `return String(describing: value)` in `normalizeArgumentsJSON` to
    /// `return ""` → the argumentsJSON assertion fails.
    func testParseToolCallFromJSON_scalarArguments_areRenderedNotDropped() {
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(
            #"{"name":"read_file","arguments":42}"#)

        XCTAssertEqual(call?.name, ToolNames.readFile)
        XCTAssertEqual(call?.argumentsJSON, "42",
                       "a scalar argument must survive to the handler, not become an empty payload")
    }

    /// The same path with an ARRAY `arguments`, which DOES have a container arm and so is
    /// re-serialised stably rather than rendered by `String(describing:)`.
    ///
    /// Paired with the scalar case deliberately: `String(describing:)` on a Foundation array would
    /// produce Swift's `[1, 2]` debug rendering, not JSON, so the two arms are not interchangeable
    /// and a refactor that collapsed them would be silently wrong on exactly this input.
    ///
    /// RED: delete the `if let arr = value as? [Any]` arm in `normalizeArgumentsJSON` → the value
    /// falls to `String(describing:)`, which renders `(\n    1,\n    2\n)`, and the assertion fails.
    func testParseToolCallFromJSON_arrayArguments_areReserialisedAsJSON() {
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(
            #"{"name":"read_file","arguments":[1,2]}"#)

        XCTAssertEqual(call?.argumentsJSON, "[1,2]",
                       "an array argument must be JSON, not Swift's debug rendering")
    }

    // MARK: - extractJSONBracedValue

    /// Called at the end of the string. The scanner reads `s[i]` on its next line, so the bound
    /// check is what stands between a malformed envelope and an index-out-of-range trap in the
    /// streaming parser — a crash on model output, i.e. on untrusted input.
    ///
    /// RED: delete `guard i < s.endIndex else { return nil }` → `let startChar = s[i]` traps and the
    /// test crashes instead of asserting.
    func testExtractJSONBracedValue_atEndIndex_returnsNilRatherThanTrapping() {
        let text = "{}"
        XCTAssertNil(ToolCallParsingHelpers.extractJSONBracedValue(
            in: text[text.startIndex...], from: text.endIndex))
    }

    /// One position earlier, on a character that opens nothing. Kept beside the bound check so the
    /// two rejections — "past the end" and "not a container" — read as one decision.
    ///
    /// RED: none against production; this arm is already covered. It is here so the bound-check test
    /// above cannot be mistaken for the only way this function declines.
    func testExtractJSONBracedValue_onANonOpeningCharacter_returnsNil() {
        let text = "abc"
        XCTAssertNil(ToolCallParsingHelpers.extractJSONBracedValue(
            in: text[text.startIndex...], from: text.startIndex))
    }
}
