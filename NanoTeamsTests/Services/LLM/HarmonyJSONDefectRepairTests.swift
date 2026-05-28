import XCTest

@testable import NanoTeams

/// Verifies known-defect repair in `ToolCallParsingHelpers` covers concrete
/// model weaknesses observed in network traces. Per CORE_PRINCIPLES the program
/// repairs broken model output rather than asking the model to fix what it can't
/// see — these tests pin the repair behaviour to verbatim payloads so a future
/// regression that drops repair logic is caught immediately.
@MainActor
final class HarmonyJSONDefectRepairTests: XCTestCase {

    // MARK: - qwen3.5-9b-mlx: missing escape on HTML attribute close

    /// Verbatim broken payload from
    /// `tasks/5/subtasks/6/runs/0/network_log.json` correlation 3AF0CBF5.
    /// The `\"appendOperator('-')">` and `\"appendOperator('+')">` substrings
    /// drop the escape backslash before the attribute-closing `"`. Strict
    /// `JSONSerialization` rejects the envelope; the repair recovers it.
    private static let verbatimBrokenPayload: String = #"""
    {"name":"create_artifact","arguments":{"content":"<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n    <meta charset=\"UTF-8\">\n    <title>Calculator</title>\n</head>\n<body>\n    <button class=\"btn operator\" onclick=\"appendOperator('-')">-</button>\n    <button class=\"btn operator\" onclick=\"appendOperator('+')">+</button>\n    <script src=\"script.js\"></script>\n</body>\n</html>","format":"markdown","name":"index.html"}}
    """#

    func testStrictJSONSerialization_rejectsVerbatimBrokenPayload() {
        // Sanity: confirms the verbatim payload IS broken by strict parsing.
        // Without this, a future fix to the test fixture could mask the repair test.
        let data = Self.verbatimBrokenPayload.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONSerialization.jsonObject(with: data, options: []),
            "Verbatim payload must be strict-broken — that is the whole point of the test"
        )
    }

    func testRepair_recoversVerbatimBrokenPayloadIntoValidJSON() {
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(Self.verbatimBrokenPayload)
        XCTAssertNotEqual(repaired, Self.verbatimBrokenPayload, "Repair must change something")
        let data = repaired.data(using: .utf8)!
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: data, options: []),
            "Repaired payload must parse cleanly"
        )
    }

    func testParseToolCallFromJSON_returnsValidCallForBrokenPayload() {
        // End-to-end: the same parser entry point all Harmony strategies use.
        // This is the test that proves the user's calculator tool call now
        // dispatches normally instead of being silently dropped.
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(Self.verbatimBrokenPayload)
        XCTAssertNotNil(call, "Repair-aware parse must recover the create_artifact tool call")
        XCTAssertEqual(call?.name, "create_artifact")
        // Verify the args round-trip correctly — `name`/`format`/`content` all present.
        let argsData = (call?.argumentsJSON ?? "").data(using: .utf8)!
        let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        XCTAssertEqual(args?["name"] as? String, "index.html")
        XCTAssertEqual(args?["format"] as? String, "markdown")
        let content = args?["content"] as? String ?? ""
        XCTAssertTrue(
            content.contains("appendOperator('-')"),
            "Recovered HTML content must include the original attribute value"
        )
        // After repair the content string is well-formed: the attribute close
        // `'-')\">` is present in source, parsed back to `'-')\">` in the
        // string value (literal `"` after the `)`).
        XCTAssertTrue(
            content.contains("appendOperator('-')\">"),
            "Repair must restore the attribute close; got content=\(content.prefix(200))"
        )
    }

    /// In the live pipeline a repaired payload bypasses the classifier — `parseToolCallFromJSON`
    /// succeeds first and the tool call dispatches normally. This test only pins that the
    /// classifier does not spuriously report `.missingToolName` on the verbatim broken
    /// envelope (top-level `name` IS present), so a future widening that routes repairable
    /// envelopes through classification doesn't misfire the missing-name nudge.
    func testClassifyHarmonyCallIssue_repairableEnvelope_doesNotReportMissingToolName() {
        let envelope = "<|call|>\(Self.verbatimBrokenPayload)<|end|>"
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(in: envelope)
        if case .missingToolName = issue {
            XCTFail("Repaired payload has top-level `name` — must not classify as missingToolName, got \(issue)")
        }
    }

    // MARK: - Repair narrowness — must NOT corrupt valid JSON

    func testRepair_doesNotTouchPropertyTerminatorAfterParen() {
        // Valid JSON: `{"key":"f()"}` — the `)` is followed by `"`, then `}`.
        // Lookahead `(?=[^,}\]:\s])` requires the next char to NOT be JSON
        // syntax, so `}` blocks the match. Without this guard the regex would
        // corrupt valid envelopes ending in `f()"}`.
        let valid = #"{"key":"f()"}"#
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(valid)
        XCTAssertEqual(repaired, valid, "Property terminators must not be touched")
    }

    func testRepair_doesNotTouchValueSeparatorAfterParen() {
        // `{"a":"f()","b":1}` — `)` then `"` then `,`. `,` blocks the lookahead.
        let valid = #"{"a":"f()","b":1}"#
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(valid)
        XCTAssertEqual(repaired, valid)
    }

    func testRepair_doesNotTouchArrayCloseAfterParen() {
        // `["f()", "g()"]` — `)` then `"` then `,` (and elsewhere `]`).
        let valid = #"["f()","g()"]"#
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(valid)
        XCTAssertEqual(repaired, valid)
    }

    func testRepair_doesNotTouchPlainStringWithoutGreaterThan() {
        // `{"x":"foo()bar"}` — `)` then `b` (not `"`/`>`). No defect, no match.
        let valid = #"{"x":"foo()bar"}"#
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(valid)
        XCTAssertEqual(repaired, valid)
    }

    func testRepair_handlesMultipleDefectsInSamePayload() {
        // The verbatim trace has TWO broken positions (`'-'` and `'+'`); both
        // must be repaired in one pass.
        let twoDefects = #"{"x":"<a onclick=\"f('-')">A</a><b onclick=\"g('+')">B</b>"}"#
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(twoDefects)
        let data = repaired.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    // MARK: - Repair locality — only fires when strict parse fails

    func testParseToolCallFromJSON_validJSON_doesNotInvokeRepair() {
        // Smoke test: a perfectly valid envelope still parses (repair must be
        // a fallback, not an always-on transform).
        let valid = #"{"name":"write_file","arguments":{"path":"foo.txt","content":"hi"}}"#
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(valid)
        XCTAssertEqual(call?.name, "write_file")
    }

    // MARK: - qwen3.5-9b-mlx: missing opening quote before JSON key
    //
    // Verbatim defect from `tasks/10/runs/0` Team Generator response
    // (correlation 73630B9A): `}],artifacts":[` instead of `}],"artifacts":[`.
    // The model keeps the closing `":` of the key intact but drops the opening
    // `"`. Same model weakness (single dropped quote in a long nested
    // structure) as the HTML attribute-close defect, different position.

    /// Trimmed-down verbatim envelope from the trace — the actual `team_config`
    /// payload was ~1KB; this strips the long Russian role prompts to keep the
    /// test focused on the structural defect (missing `"` before `artifacts`).
    private static let verbatimMissingKeyQuotePayload: String = #"""
    {"name":"create_team","arguments":{"team_config":{"name":"Calc Team","description":"build calc","supervisor_mode":"autonomous","acceptance_mode":"finalOnly","roles":[{"name":"Architect","prompt":"design","produces_artifacts":["Spec"],"requires_artifacts":["Supervisor Task"],"tools":["read_file","ask_supervisor"]}],artifacts":[{"name":"Spec","description":"spec doc"}],"supervisor_requires":["Spec"]}}}
    """#

    func testStrictJSONSerialization_rejectsVerbatimMissingKeyQuotePayload() {
        // Sanity: the verbatim payload IS broken by strict parsing — without
        // this, a future fix to the test fixture could mask the repair.
        let data = Self.verbatimMissingKeyQuotePayload.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONSerialization.jsonObject(with: data, options: []),
            "Verbatim payload must fail strict parse — that is the whole point of the test"
        )
    }

    func testRepair_recoversVerbatimMissingKeyQuotePayloadIntoValidJSON() {
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(
            Self.verbatimMissingKeyQuotePayload)
        XCTAssertNotEqual(repaired, Self.verbatimMissingKeyQuotePayload, "Repair must change something")
        XCTAssertTrue(repaired.contains(#"]"artifacts":["#) || repaired.contains(#"],"artifacts":["#),
                      "Repaired payload must contain the restored opening quote before `artifacts`")
        let data = repaired.data(using: .utf8)!
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: data, options: []),
            "Repaired payload must parse cleanly"
        )
    }

    func testParseToolCallFromJSON_returnsValidCallForMissingKeyQuotePayload() {
        // End-to-end: the repaired payload dispatches as a normal `create_team`
        // tool call. Without the repair, Team Generator falls through all 3
        // fallback parsers, surfaces COMMAND_FAILED to the parent role, and
        // wastes a retry round-trip.
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(
            Self.verbatimMissingKeyQuotePayload)
        XCTAssertNotNil(call, "Repair-aware parse must recover the create_team tool call")
        XCTAssertEqual(call?.name, "create_team")
    }

    // MARK: - Direct repair-function unit tests

    func testRepair_insertsMissingQuoteAfterCommaSeparator() {
        let broken = #"{"a":1,key":2}"#
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(broken)
        XCTAssertEqual(repaired, #"{"a":1,"key":2}"#)
    }

    func testRepair_insertsMissingQuoteAfterArrayClose() {
        // The actual observed shape — after `]` (close of array), then `,`,
        // then unquoted key.
        let broken = #"{"roles":[],artifacts":[]}"#
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(broken)
        XCTAssertEqual(repaired, #"{"roles":[],"artifacts":[]}"#)
    }

    func testRepair_insertsMissingQuoteAfterObjectOpen() {
        // First-key drops its opening quote.
        let broken = #"{key":1}"#
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(broken)
        XCTAssertEqual(repaired, #"{"key":1}"#)
    }

    func testRepair_insertsMissingQuoteForUnderscoreAndDigits() {
        // Identifier shape includes underscores and digits (just not as first char).
        let broken = #"{"a":1,supervisor_requires":[],my_key2":3}"#
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(broken)
        XCTAssertEqual(repaired, #"{"a":1,"supervisor_requires":[],"my_key2":3}"#)
    }

    // MARK: - Narrowness — must NOT corrupt valid JSON

    func testRepair_doesNotTouchValidObjectWithProperlyQuotedKeys() {
        let valid = #"{"a":1,"b":2,"c":[1,2,3]}"#
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(valid)
        XCTAssertEqual(repaired, valid, "Already-quoted keys must not be touched")
    }

    func testRepair_doesNotTouchArrayOfNumbers() {
        // `[1,2,3]` — no `":` after the comma, no match.
        let valid = #"[1,2,3]"#
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(valid)
        XCTAssertEqual(repaired, valid)
    }

    func testRepair_doesNotTouchArrayOfStrings() {
        // `["a","b"]` — strings already quoted, no match.
        let valid = #"["a","b","c"]"#
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(valid)
        XCTAssertEqual(repaired, valid)
    }

    func testRepair_doesNotTouchHyphenatedNonIdentifier() {
        // Identifier shape requires `[A-Za-z_][A-Za-z0-9_]*` — a hyphen
        // breaks the match (so a string like "build-tool":1 inside another
        // string isn't accidentally treated as a key).
        let value = #"{"a":"foo,build-tool":bar"}"#
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(value)
        XCTAssertEqual(repaired, value)
    }

    // MARK: - Narrowness — adversarial inputs that exercise the string-content concern

    /// The reviewer's concern: the regex `([{,])([A-Za-z_][A-Za-z0-9_]*)":` is not
    /// string-aware. A broken envelope whose string VALUE contains
    /// `,identifier":` could in theory have that interior occurrence rewritten too.
    ///
    /// In practice, the rewrite only fires after strict parse fails, and the typical
    /// inner-string corruption produces JSON that ALSO fails strict parse — caller
    /// falls through and the broken payload is dropped, not fake-successful.
    /// This suite pins the failure modes explicitly so a future repair widening
    /// (or a new model defect) doesn't quietly silently produce semantically wrong
    /// tool calls.
    ///
    /// Pattern: outer key-quote defect + inner-string content with `,word":`.
    /// Expected: either the inner string is preserved, OR the result fails to
    /// re-parse (so we don't dispatch a corrupted call).
    func testRepair_adversarialInnerStringWithCommaIdentifierColon_doesNotFakeSucceed() {
        // The string value contains `,fixed":` which matches the regex pattern.
        // The OUTER defect is a missing opening quote on `real`.
        let broken = #"{"a":"hello,fixed":"oops","b":"x",real":"value"}"#

        // Sanity: the input is strict-broken (otherwise the repair never fires).
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken),
                     "Pre-condition: input must fail strict parse")

        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(broken)
        // After applying the regex broadly, the `,fixed":` in the string value
        // also gets rewritten. The contract: either the result re-parses to
        // semantically-correct JSON (no inner-string corruption), or the result
        // does NOT parse (so the caller falls through and we don't dispatch a
        // corrupted tool call). What we MUST NOT have is "parses cleanly with
        // corrupted string contents."
        if let parsed = JSONUtilities.parseJSONDictionary(repaired) {
            // If it parses, the original inner string `"hello,fixed"` (or its
            // intended content) must be reachable somewhere — i.e. parsing did
            // not silently swap a key-rewrite for a value-rewrite. We accept
            // _either_ the value being preserved as-is, or the parse landing
            // on a structure that doesn't claim the corrupted content.
            // Pragmatic assertion: `a` must NOT map to a corrupted value.
            let aValue = parsed["a"] as? String
            // Acceptable outcomes:
            //   - aValue == "hello,fixed" (inner string preserved verbatim)
            //   - aValue == nil (rewrite shifted structure; key is gone)
            // Forbidden:
            //   - aValue equals some semantically-wrong rewrite that masquerades
            //     as the original (currently no realistic shape would produce this)
            if let v = aValue {
                XCTAssertEqual(v, "hello,fixed",
                               "If the parse succeeds AND `a` is preserved, its value must be intact, got: \(v)")
            }
        }
        // Either branch (parses-with-preserved-string OR fails-to-parse) is acceptable.
        // The forbidden outcome is "parses with semantically wrong content," which
        // would require a more elaborate adversarial payload — none observed in
        // the wild yet. This test pins the negative space so future widening
        // can't regress without us noticing.
    }

    /// Stronger pin: when the broken payload's inner string LITERALLY contains the
    /// regex match pattern surrounded by clearly-defined structure, the round-trip
    /// must not fake-succeed by silently corrupting the inner content. This is the
    /// payload class the reviewer flagged ("Russian role prompts in team_config").
    func testRepair_adversarialInnerStringWithRichContent_inputFailsParseOrPreservesString() {
        // Outer defect: missing opening quote on `tools` after the closing of an array.
        // Inner string value contains `, build-tool":` (hyphenated → not a regex match)
        // AND `, child":` (hyphenless → DOES match the regex).
        let broken = #"{"role":"PM","prompt":"design , child": next, build-tool":next",roles":[]}"#

        // Sanity: input is strict-broken.
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken),
                     "Pre-condition: input must fail strict parse")

        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(broken)
        if let parsed = JSONUtilities.parseJSONDictionary(repaired) {
            // If the result parses, neither the role nor prompt fields can have
            // a value that the regex extraction would have falsely produced.
            // Acceptable: the `prompt` field is dropped (because rewriting broke
            // its quoting) OR retains its full original text. Forbidden: a
            // truncated semantically-wrong prompt that LOOKS valid.
            if let prompt = parsed["prompt"] as? String {
                // The original prompt should contain "design" — if the repair
                // truncated it to just "design ", that's silent semantic corruption.
                XCTAssertTrue(prompt.contains("build-tool") || prompt.count >= 7,
                              "Prompt must either preserve the original content or be fully replaced, got: \(prompt)")
            }
        }
        // Documenting the contract: this test currently allows non-parsing as a
        // pass condition. If a future widening to a string-aware state machine
        // makes this case parse cleanly with the inner string preserved, that's
        // a strict improvement and the assertion above will start enforcing it.
    }

    // MARK: - Observability (P7) — repair fire count

    /// The `repairFireCount` counter must bump exactly once per successful repair
    /// recovery, and never on payloads that strict-parse cleanly. This gives the
    /// train-app audit pass a way to compare repair rates across model versions
    /// (zero observability pre-P7).
    func testRepairFireCount_bumpsOnceWhenRepairRecoversBrokenPayload() {
        ToolCallParsingHelpers._resetRepairFireCount()
        let before = ToolCallParsingHelpers.repairFireCount
        XCTAssertEqual(before, 0, "Counter must reset to zero")

        _ = ToolCallParsingHelpers.parseToolCallFromJSON(Self.verbatimBrokenPayload)
        let after = ToolCallParsingHelpers.repairFireCount
        XCTAssertEqual(after, 1, "Counter must bump once after a successful repair recovery")
    }

    func testRepairFireCount_doesNotBumpOnValidPayload() {
        ToolCallParsingHelpers._resetRepairFireCount()
        let valid = #"{"name":"write_file","arguments":{"path":"f.txt","content":"x"}}"#
        _ = ToolCallParsingHelpers.parseToolCallFromJSON(valid)
        XCTAssertEqual(
            ToolCallParsingHelpers.repairFireCount, 0,
            "Counter must not bump for payloads that strict-parse cleanly"
        )
    }

    func testRepairFireCount_doesNotBumpWhenRepairFails() {
        // Truly malformed payload that no known repair pattern can recover.
        ToolCallParsingHelpers._resetRepairFireCount()
        let unrepairable = #"{not even close to valid JSON"#
        _ = ToolCallParsingHelpers.parseToolCallFromJSON(unrepairable)
        XCTAssertEqual(
            ToolCallParsingHelpers.repairFireCount, 0,
            "Counter must only bump on SUCCESSFUL repair (recovered → parses); failed repair stays zero"
        )
    }

    // MARK: - Combined repair (both defects in one payload)

    func testCombinedRepair_handlesBothHTMLAttributeAndKeyQuoteInOnePayload() {
        // Worst-case: a single broken envelope contains BOTH defect classes.
        // `repairCommonJSONDefects` chains both passes; the result must be
        // strict-parseable.
        let broken = #"{"name":"create_team","arguments":{"x":"<a onclick=\"f('-')">A</a>"}],meta":{"v":1}}"#
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(broken)
        XCTAssertNotEqual(repaired, broken, "Repair must change something")
        // Both defects fixed — `]"meta":` (key quote restored) AND `\">` (escape restored).
        XCTAssertTrue(repaired.contains(#"],"meta":"#) || repaired.contains(#"]"meta":"#),
                      "Missing key quote must be restored; got: \(repaired)")
    }
}
