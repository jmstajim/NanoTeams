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
    ///
    /// NOTE: `repairFireCount` is a **process-global** `Atomic<Int>`. The reset-then-assert
    /// exact-count tests below are safe only because XCTest runs methods within a class
    /// serially. If `NanoTeams.xctestplan` ever enables parallel-across-classes execution, a
    /// concurrent `parseToolCallFromJSON` from another suite (~55 LLM test files call it) would
    /// race the count — switch these to delta/`>=` assertions before enabling that.
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

    func testRepairFireCount_bumpsWhenSanitizeAloneRecoversControlEscape() {
        // RC3 defect (`\` + a real newline) is recovered by sanitizeJSONControlCharacters
        // BEFORE the regex repair chain — strict parse then succeeds, so the prior code never
        // bumped the counter. That sanitize-layer recovery must ALSO bump repairFireCount so
        // the train-app audit's repair-rate metric isn't blind to it.
        ToolCallParsingHelpers._resetRepairFireCount()
        let payload = #"{"name":"write_file","arguments":{"new_text":"a"# + "\\" + "\n" + #"b","path":"x.py"}}"#
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(payload)
        XCTAssertEqual(call?.name, "write_file", "Sanity: the call recovers")
        XCTAssertEqual(ToolCallParsingHelpers.repairFireCount, 1,
                       "Sanitize-layer recovery must bump the repair counter exactly once")
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

    // MARK: - gemma-4-26b-a4b: over-escaped key:value pair at a property boundary
    //
    // Verbatim defect from an Engineering-Team / Software-Engineer headless run
    // (network_log.json responses BE3E536B / 27DF1B2F). The model backslash-escapes
    // the quotes of an ENTIRE key:value pair: `,\"path\":\"src/core/__init__.py\"`.
    // The `content` pair right before it is correctly formed — only `path` is broken.
    // Each `\"` sits at JSON-structural position (key open/close, value open/close)
    // where a backslash is illegal, so strict parse rejects the whole envelope and the
    // `write_file` call is silently dropped — sending the model into a malformed-JSON
    // retry loop until the run is cancelled.

    /// Exact arguments envelope the model emitted (response BE3E536B). The `\"` are
    /// real backslash+quote bytes; `\n` is a real escaped newline (the file's trailing
    /// newline). Raw string → backslashes are literal.
    private static let verbatimOverescapedPairPayload: String = #"""
    {"name":"write_file","arguments":{"content":"# Claude Opus 5.0 Core Components\n",\"path\":\"src/core/__init__.py\"}}
    """#

    func testStrictJSONSerialization_rejectsVerbatimOverescapedPayload() {
        // Sanity: the verbatim payload IS broken by strict parsing — without this a
        // future fix to the fixture could mask the repair.
        let data = Self.verbatimOverescapedPairPayload.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONSerialization.jsonObject(with: data, options: []),
            "Verbatim over-escaped payload must fail strict parse — that is the whole point"
        )
    }

    func testRepair_recoversVerbatimOverescapedPayloadIntoValidJSON() {
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(
            Self.verbatimOverescapedPairPayload)
        XCTAssertNotEqual(repaired, Self.verbatimOverescapedPairPayload, "Repair must change something")
        XCTAssertTrue(repaired.contains(#""path":"src/core/__init__.py""#),
                      "Repaired payload must de-escape the `path` key:value pair; got: \(repaired)")
        let data = repaired.data(using: .utf8)!
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: data, options: []),
            "Repaired payload must parse cleanly"
        )
    }

    func testParseToolCallFromJSON_recoversOverescapedWriteFileCall() {
        // End-to-end RED→GREEN assertion: on unrepaired code this returns nil and the
        // model loops. After the repair the write_file call dispatches normally.
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(Self.verbatimOverescapedPairPayload)
        XCTAssertNotNil(call, "Repair-aware parse must recover the over-escaped write_file call")
        XCTAssertEqual(call?.name, "write_file")
        let argsData = (call?.argumentsJSON ?? "").data(using: .utf8)!
        let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "src/core/__init__.py",
                       "The over-escaped `path` value must round-trip correctly")
        let content = args?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("# Claude Opus 5.0 Core Components"),
                      "The correctly-formed `content` value must survive the repair")
    }

    func testHarmonyExtraction_recoversOverescapedCallWithRealMarkers() {
        // The full Harmony path with the real `<|call|>…<|end|>` markers (response
        // 27DF1B2F — the `src/data` attempt). Drives the same strategy chain the
        // streaming resolver uses, proving the tool call resolves in the live pipeline.
        let envelope = #"""
        <|call|>{"name":"write_file","arguments":{"content":"# Claude Opus 5.0 Data Pipeline\n",\"path\":\"src/data/__init__.py\"}}<|end|>
        """#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 1, "Exactly one write_file call must resolve from the envelope")
        XCTAssertEqual(calls.first?.name, "write_file")
        let argsData = (calls.first?.argumentsJSON ?? "").data(using: .utf8)!
        let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "src/data/__init__.py")
    }

    // MARK: - Over-escape repair narrowness — must NOT corrupt valid JSON

    func testRepair_doesNotTouchLegitimateInStringEscapedQuotes() {
        // A legitimate escaped quote inside a string VALUE: `say \"hi\" now`. The `\"`
        // here is surrounded by string content, never an identifier-then-`\":` at a
        // property boundary, so the over-escape repair must leave it byte-for-byte
        // unchanged (and it strict-parses on its own — repair never even fires).
        let valid = #"{"name":"write_file","arguments":{"content":"say \"hi\" now","path":"a.txt"}}"#
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: valid.data(using: .utf8)!),
                         "Control payload must be valid on its own")
        let repaired = ToolCallParsingHelpers.repairCommonJSONDefects(valid)
        XCTAssertEqual(repaired, valid, "Legitimate in-string escaped quotes must not be touched")
        // And the parse still recovers the same call without invoking repair.
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(valid)
        XCTAssertEqual(call?.name, "write_file")
    }

    func testRepairFireCount_bumpsOnOverescapedPayload_butNotOnControl() {
        ToolCallParsingHelpers._resetRepairFireCount()
        _ = ToolCallParsingHelpers.parseToolCallFromJSON(Self.verbatimOverescapedPairPayload)
        XCTAssertEqual(ToolCallParsingHelpers.repairFireCount, 1,
                       "Repair must fire exactly once on the over-escaped payload")

        ToolCallParsingHelpers._resetRepairFireCount()
        let control = #"{"name":"write_file","arguments":{"content":"say \"hi\" now","path":"a.txt"}}"#
        _ = ToolCallParsingHelpers.parseToolCallFromJSON(control)
        XCTAssertEqual(ToolCallParsingHelpers.repairFireCount, 0,
                       "Repair must not fire on a payload that strict-parses cleanly")
    }

    // MARK: - gemma-4-26b-a4b: stray backslash before newline (invalid JSON escape)
    //
    // Verbatim defect (network_log.json response 79D38613): the model emitted a large
    // edit_file call whose `new_text` contained a hallucinated Python line-continuation
    // backslash before a real newline — `...range(self.num_experts):` + `\` + <newline>.
    // `\` + control char is an invalid JSON escape, so the whole call was rejected and the
    // model looped on the malformed-JSON nudge. The fix lives in
    // JSONUtilities.sanitizeJSONControlCharacters (escape validation, run before strict
    // parse); this pins the end-to-end tool-dispatch recovery.

    func testParseToolCallFromJSON_recoversStrayBackslashEditFileCall() {
        let payload = #"{"name":"edit_file","arguments":{"new_text":"for i in range(self.num_experts):"# + "\\" + "\n" + #"            # Find which expert","old_text":"old","path":"src/core/layers.py","replace_all":false}}"#
        // Sanity: the raw payload is strict-broken (the stray `\` + newline).
        XCTAssertNil(JSONUtilities.parseJSONDictionary(payload),
                     "Pre-condition: stray-backslash payload must fail strict parse")
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(payload)
        XCTAssertNotNil(call, "Sanitize-aware parse must recover the edit_file call")
        XCTAssertEqual(call?.name, "edit_file")
        let argsData = (call?.argumentsJSON ?? "").data(using: .utf8)!
        let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "src/core/layers.py")
        XCTAssertEqual(args?["replace_all"] as? Bool, false)
    }

    func testHarmonyExtraction_recoversStrayBackslashCallWithRealMarkers() {
        // Full Harmony path with the real `<|call|>…<|end|>` markers.
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text":"x = 1 +"# + "\\" + "\n" + #"    2","old_text":"y","path":"m.py","replace_all":false}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 1, "Exactly one edit_file call must resolve")
        XCTAssertEqual(calls.first?.name, "edit_file")
        let argsData = (calls.first?.argumentsJSON ?? "").data(using: .utf8)!
        let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "m.py")
    }

    // MARK: - Over-escape repair: additional coverage (multiple pairs, fail-safe boundary, salvage)

    func testRepair_overescaped_multiplePairsInOneObject() {
        // The defect is per-property: `edit_file` can over-escape BOTH old_text and new_text.
        // `repairOverescapedKeyValuePair` uses stringByReplacingMatches (all matches) — pin
        // that two ADJACENT over-escaped pairs both recover, catching any anchoring bug where
        // pair N's trailing `\"` is consumed as pair N+1's leading `\"`.
        let payload = #"{"name":"edit_file","arguments":{\"old_text\":\"a\",\"new_text\":\"b\"}}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(payload), "Pre-condition: strict-broken")
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(payload)
        XCTAssertEqual(call?.name, "edit_file")
        let args = try? JSONSerialization.jsonObject(
            with: (call?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?["old_text"] as? String, "a")
        XCTAssertEqual(args?["new_text"] as? String, "b")
    }

    func testRepair_overescaped_valueWithInternalEscape_doesNotMisrepair() {
        // Pins the documented fail-safe boundary: the value-body pattern `[^"\\]*` stops at a
        // backslash, so an over-escaped pair whose value contains an internal escape (`\n`)
        // does NOT match and is left UNCHANGED (→ strict parse still rejects → retry nudge).
        // Guards against a future widening of the value class that would start corrupting
        // partially-escaped values. The `\n` here is a literal backslash-n inside the value.
        let payload = #"{"content":"ok",\"path\":\"a\nb\"}"#
        XCTAssertEqual(
            ToolCallParsingHelpers.repairOverescapedKeyValuePair(payload), payload,
            "Over-escaped pair whose value has an internal escape must NOT be repaired (fail-safe)")
    }

    func testHarmonyExtraction_overescapedPair_missingOuterBrace_salvages() {
        // The walker change + salvage path together: an over-escaped pair (uniform-escape
        // walking) inside an envelope that is ALSO missing its outer `}` (lastCloseEnd
        // salvage). Both must compose so the call still resolves.
        let envelope = #"<|call|>{"name":"write_file","arguments":{"content":"x",\"path\":\"a.py\"}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 1, "Salvage + over-escape repair must compose to one call")
        XCTAssertEqual(calls.first?.name, "write_file")
        let args = try? JSONSerialization.jsonObject(
            with: (calls.first?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "a.py")
    }

    // MARK: - gemma-4-26b-a4b: missing key-quote in a <|call|> envelope (walker parity)
    //
    // Verbatim defect (network_log.json response B726EF7B): a large write_file whose `path`
    // key lost its OPENING quote — `..."content":"…",path":"docs/…md"}}`. The missing quote
    // flips the brace walker's string parity (the key's stray `"` opens a string, so the
    // closing `}}` are swallowed as string content), `extractJSONBracedValue` returns nil,
    // and the call is dropped BEFORE `repairMissingQuoteBeforeJSONKey` — which fixes exactly
    // this defect — can run. CallMarkerStrategy now falls back to the raw body up to <|end|>
    // and routes it through `parseToolCallFromJSON`'s repair chain.

    func testHarmonyExtraction_missingKeyQuote_brokenWalkerParity_recovers() {
        // `,path":` is missing its opening quote (should be `,"path":`). Minimal repro of the
        // B726EF7B shape: content closes, then the malformed key, then the swallowed `}}`.
        let envelope = #"<|call|>{"name":"write_file","arguments":{"content":"x",path":"a.md"}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 1, "Missing-key-quote call must recover via the raw-body fallback")
        XCTAssertEqual(calls.first?.name, "write_file")
        let args = try? JSONSerialization.jsonObject(
            with: (calls.first?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "a.md")
        XCTAssertEqual(args?["content"] as? String, "x")
    }

    func testHarmonyExtraction_cleanMultiCall_unaffectedByFallback() {
        // Regression guard: the raw-body fallback runs ONLY when the clean walker fails, so a
        // well-formed two-call envelope must still resolve to exactly two distinct calls.
        let envelope = #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"}}<|end|><|call|>{"name":"read_file","arguments":{"path":"b.txt"}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 2, "Clean multi-call extraction must be unaffected by the fallback")
        let paths = calls.compactMap { call -> String? in
            let args = try? JSONSerialization.jsonObject(
                with: (call.argumentsJSON).data(using: .utf8)!) as? [String: Any]
            return args?["path"] as? String
        }
        XCTAssertEqual(paths, ["a.txt", "b.txt"])
    }

    // MARK: - RC4 fallback: continuity & fail-closed coverage

    func testHarmonyExtraction_fallbackBlockFollowedByCleanCall_bothResolve() {
        // A malformed (missing-key-quote → walker fails → raw-body fallback) call IMMEDIATELY
        // followed by a clean call. Pins that the fallback's `cursor = endRange.upperBound`
        // advance leaves the loop positioned to resolve the next <|call|> — the distinct
        // fallback cursor path that the clean-multi-call guard above never exercises.
        let envelope = #"<|call|>{"name":"write_file","arguments":{"content":"x",path":"a.md"}}<|end|><|call|>{"name":"read_file","arguments":{"path":"b.txt"}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 2, "Fallback block then clean call must both resolve")
        XCTAssertEqual(calls.map(\.name), ["write_file", "read_file"])
        let paths = calls.compactMap { call -> String? in
            let args = try? JSONSerialization.jsonObject(
                with: (call.argumentsJSON).data(using: .utf8)!) as? [String: Any]
            return args?["path"] as? String
        }
        XCTAssertEqual(paths, ["a.md", "b.txt"])
    }

    func testHarmonyExtraction_fallbackUnrepairableBody_failsClosed_andLetsNextCallThrough() {
        // Walker fails, <|end|> present, but the body is unrepairable garbage → fallback's
        // parse returns nil → no call appended, cursor still advances past <|end|>, and a
        // following clean call still resolves (drop-and-continue, no crash, no poisoning).
        let envelope = #"<|call|>{ this is not json at all }<|end|><|call|>{"name":"read_file","arguments":{"path":"b.txt"}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 1, "Unrepairable block dropped; trailing clean call survives")
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    func testHarmonyExtraction_missingKeyQuote_noEndMarker_dropsCallNoCrash() {
        // Walker fails AND no <|end|> delimiter → the `if let endRange` fallback guard is
        // false, control falls through, the call is dropped (no spurious result, no spin).
        let envelope = #"<|call|>{"name":"write_file","arguments":{"content":"x",path":"a.md"}}"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 0, "Missing-quote block with no <|end|> must fail closed")
    }

    // MARK: - gemma-4-26b-a4b: over-escaped / missing key-quote WITH whitespace before the key
    //
    // Verbatim shape (network_log.json response 80A90B36): a write_file whose key is preceded
    // by a SPACE — `…capability.", \"path\":\"…blueprint.md\"}}`. Both key-quote repairs
    // anchored the key DIRECTLY on `{`/`,`, so insignificant JSON whitespace between the comma
    // and the (over-escaped) key defeated the regex → the repair never fired → the call was
    // dropped and the model looped on the malformed-JSON nudge.

    func testRepair_overescapedPair_withWhitespaceBeforeKey() {
        // `, \"path\":\"a.md\"` — over-escaped pair with a space after the comma.
        let payload = #"{"content":"x", \"path\":\"a.md\"}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(payload), "Pre-condition: strict-broken")
        let repaired = ToolCallParsingHelpers.repairOverescapedKeyValuePair(payload)
        XCTAssertNotEqual(repaired, payload, "Repair must fire across the leading whitespace")
        let parsed = JSONUtilities.parseJSONDictionary(repaired)
        XCTAssertEqual(parsed?["path"] as? String, "a.md")
        XCTAssertEqual(parsed?["content"] as? String, "x")
    }

    func testHarmonyExtraction_overescapedPair_whitespaceBeforeKey_recovers() {
        // Minimal repro of the 80A90B36 ending: content closes, comma, SPACE, over-escaped
        // `\"path\":\"…\"`, then `}}`.
        let envelope = #"<|call|>{"name":"write_file","arguments":{"content":"...spec...", \"path\":\"claude_opus_5_blueprint.md\"}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 1, "Over-escaped pair with leading whitespace must recover")
        XCTAssertEqual(calls.first?.name, "write_file")
        let args = try? JSONSerialization.jsonObject(
            with: (calls.first?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "claude_opus_5_blueprint.md")
    }

    func testRepair_missingKeyQuote_withWhitespaceBeforeKey() {
        // Same whitespace gap for the missing-opening-quote repair: `, key":` (space) must
        // recover, not just the no-space `,key":`. Assert the DECODED values to prove the
        // whitespace was dropped and the key correctly reconstructed (not merely "something
        // parses"). Also exercises a tab (\s* matches space/tab/newline uniformly).
        let broken = "{\"a\":1,\tkey\":2}"
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(broken)
        XCTAssertNotEqual(repaired, broken, "Repair must fire across the leading whitespace")
        let parsed = JSONUtilities.parseJSONDictionary(repaired)
        XCTAssertEqual(parsed?["a"] as? Int, 1)
        XCTAssertEqual(parsed?["key"] as? Int, 2, "Whitespace dropped, key reconstructed: \(repaired)")
    }

    // MARK: - RC5 narrowness: `\s*` must NOT corrupt valid spaced JSON, and must fail closed
    // on an in-string whitespace mis-fire (the exact surface `\s*` widened).

    func testRepair_missingKeyQuote_validSpacedJSON_unchanged() {
        // Legitimate JSON whitespace before an already-quoted key. The leading `"` on the key
        // blocks the match (`"` ∉ [A-Za-z_]), so a VALID spaced object passes through
        // byte-identical. Pins the exact invariant `\s*` put at risk.
        let valid = #"{"a":1, "b":2}"#
        XCTAssertEqual(ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(valid), valid,
                       "Valid spaced JSON must pass through unchanged")
    }

    func testRepair_overescaped_validSpacedJSON_unchanged() {
        // The over-escape regex requires a literal `\"` after `[{,]\s*`, which valid JSON never
        // has — so a valid spaced object is untouched.
        let valid = #"{"a":"x", "b":"y"}"#
        XCTAssertEqual(ToolCallParsingHelpers.repairOverescapedKeyValuePair(valid), valid,
                       "Valid spaced JSON must pass through unchanged")
    }

    func testRepair_missingKeyQuote_whitespacePairInsideStringValue_failsClosed() {
        // Adversarial: the only `, y":` is INSIDE the value `"x, y"`. `\s*` lets it match, the
        // mis-fire inserts a `"` that closes the value early → bareword → the repaired string
        // still fails strict parse. Whitespace-widening cannot fake-succeed a corrupted dispatch.
        let broken = #"{"a":"x, y":1}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken), "Pre-condition: strict-broken")
        let repaired = ToolCallParsingHelpers.repairMissingQuoteBeforeJSONKey(broken)
        XCTAssertNil(JSONUtilities.parseJSONDictionary(repaired),
                     "In-string whitespace mis-fire must remain unparseable (fail-closed); got \(repaired)")
    }

    func testRepair_overescaped_whitespacePairInsideStringValue_failsClosed() {
        // Adversarial: the content value contains a `, \"k\":\"v\"` shape (with space) AND the
        // outer `\"path\"` is the real over-escape defect. The repair de-escapes BOTH; the
        // in-string mis-fire closes the content value early → the result still fails strict
        // parse. Fail-closed under `\s*`.
        let broken = #"{"content":"a, \"k\":\"v\" b", \"path\":\"f.txt\"}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken), "Pre-condition: strict-broken")
        let repaired = ToolCallParsingHelpers.repairOverescapedKeyValuePair(broken)
        XCTAssertNil(JSONUtilities.parseJSONDictionary(repaired),
                     "In-string over-escape mis-fire must remain unparseable (fail-closed); got \(repaired)")
    }

    // MARK: - gemma-4-26b-a4b: RAW newlines + RAW (unescaped) quotes in a content field
    //
    // Verbatim defect (network_log.json response 15BED3EA): gemma emitted a large write_file
    // `content` with literal newlines AND literal unescaped double quotes —
    // `…"content":"# …Specification⏎## 1…the core philosophy is "Inference-Time Compute Scaling"—…","format":…,"path":…}}`.
    // The unescaped quotes break the string (sanitize only fixes control chars), so the call is
    // dropped. The tool-call STRUCTURE is known + clean, so the value of the one big content
    // field is re-escaped (structure-anchored, re-validated) to recover the call.

    func testHarmonyExtraction_rawNewlinesAndUnescapedQuotesInContent_recovers() {
        // `\n` produces real newlines, `\"quoted\"` produces real unescaped quotes inside the
        // content value — exactly the 15BED3EA shape, with a clean `"path"` tail.
        let envelope = "<|call|>{\"name\":\"write_file\",\"arguments\":{\"content\":\"# Title\n\nSome \"quoted\" phrase.\",\"path\":\"a.md\"}}<|end|>"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 1, "Raw-quotes-and-newlines content must recover via re-escape")
        XCTAssertEqual(calls.first?.name, "write_file")
        let args = try? JSONSerialization.jsonObject(
            with: (calls.first?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "a.md", "Clean trailing arg preserved")
        let content = args?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("# Title"), "Content preserved: \(content)")
        XCTAssertTrue(content.contains("\"quoted\""), "Unescaped quotes recovered into content: \(content)")
        XCTAssertTrue(content.contains("\n"), "Raw newlines recovered as escapes")
    }

    func testParseToolCallFromJSON_reescapesUnescapedContentField() {
        // Repair-function level (raw quotes + raw newline in content, clean `path` tail).
        let broken = "{\"name\":\"write_file\",\"arguments\":{\"content\":\"a \"b\" c\nd\",\"path\":\"x.md\"}}"
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken), "Pre-condition: strict-broken")
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(broken)
        XCTAssertEqual(call?.name, "write_file")
        let args = try? JSONSerialization.jsonObject(
            with: (call?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "x.md")
        XCTAssertEqual(args?["content"] as? String, "a \"b\" c\nd",
                       "Content value recovered verbatim (quotes + newline)")
    }

    func testReescape_preservesTrailingArgs_overTailAbsorbingSplit() {
        // create_artifact shape: content + format + name + path. The re-escape must pick the
        // split that PRESERVES all trailing args (max known-arg-keys), not the one that absorbs
        // format/name/path into the content blob.
        let broken = "{\"name\":\"create_artifact\",\"arguments\":{\"content\":\"say \"hi\"\",\"format\":\"markdown\",\"name\":\"Engineering Notes\",\"path\":\"x.md\"}}"
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(broken)
        XCTAssertEqual(call?.name, "create_artifact")
        let args = try? JSONSerialization.jsonObject(
            with: (call?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?["format"] as? String, "markdown")
        XCTAssertEqual(args?["name"] as? String, "Engineering Notes")
        XCTAssertEqual(args?["path"] as? String, "x.md")
        XCTAssertEqual(args?["content"] as? String, "say \"hi\"")
    }

    // MARK: - content re-escape narrowness

    func testReescape_doesNotAlterValidToolCall() {
        // A valid tool call parses via the normal path; the re-escape fallback never runs.
        let valid = #"{"name":"write_file","arguments":{"content":"clean text","path":"x.md"}}"#
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(valid)
        XCTAssertEqual(call?.name, "write_file")
        let args = try? JSONSerialization.jsonObject(
            with: (call?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?["content"] as? String, "clean text")
    }

    func testReescape_failsClosedOnNonContentEnvelope() {
        // No content-bearing field → re-escape can't fire → fail closed (nil), not a crash or
        // a corrupted dispatch.
        let broken = #"{"name":"git_status","arguments":{garbage not json}}"#
        XCTAssertNil(ToolCallParsingHelpers.parseToolCallFromJSON(broken))
    }

    // MARK: - knownToolArgumentKeys ↔ tool-schema sync guard
    //
    // `knownToolArgumentKeys` is a hand-maintained literal that the re-escape recovery uses to
    // reject splits that fabricate an unknown key. It must stay a SUPERSET of the schema
    // property keys of the file/artifact tools it gates — otherwise a future schema arg would
    // silently start rejecting otherwise-recoverable envelopes (comment-rot with no compile
    // error). This pins that invariant structurally.

    func testKnownToolArgumentKeys_coversFileAndArtifactToolSchemas() {
        var schemaKeys = Set<String>()
        for schema in [
            WriteFileTool.schema, EditFileTool.schema, DeleteFileTool.schema, CreateArtifactTool.schema,
        ] {
            if let properties = schema.parameters.properties {
                schemaKeys.formUnion(properties.keys)
            }
        }
        XCTAssertFalse(schemaKeys.isEmpty, "Sanity: the tool schemas expose argument properties")
        let known = ToolCallParsingHelpers._knownToolArgumentKeysForTesting
        XCTAssertTrue(
            schemaKeys.isSubset(of: known),
            "knownToolArgumentKeys must cover every file/artifact tool schema arg so re-escape "
                + "recovery can't silently reject a recoverable envelope. Missing: "
                + "\(schemaKeys.subtracting(known))")
    }

    // MARK: - parseAfterContentReescape: residual-ambiguity truncation (documented, pinned)
    //
    // The selection keeps the split with the MOST known-arg keys. When the content value itself
    // contains a `","<knownkey>":"…"`-shaped fragment, the bytes are identical whether that
    // fragment is real trailing args or literal content — so the max-arg split truncates the
    // content and treats the fragment as args. This is INHERENT input ambiguity: biasing toward
    // longest content would break the real gemma defect (a genuine `","path":"…"` tail this
    // recovery exists to preserve). The test pins CURRENT behaviour so a future heuristic change
    // is deliberate — it is NOT an endorsement of truncation. See the function doc.

    func testReescape_embeddedKnownKeyFragment_residualAmbiguity() {
        // content's intended value (in the truncating reading) is `say "hi" then ","path":"/etc/x`,
        // with raw quotes around `hi` making it strict-broken so it reaches re-escape. The max-arg
        // split closes content at `say "hi" then ` and treats `,"path":"/etc/x"` as a real arg.
        let broken = #"{"name":"write_file","arguments":{"content":"say "hi" then ","path":"/etc/x"}}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken), "Pre-condition: raw quotes → strict-broken")
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(broken)
        XCTAssertEqual(call?.name, "write_file", "A call still resolves (max-arg split)")
        let args = try? JSONSerialization.jsonObject(
            with: (call?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        // CURRENT behaviour: content truncated, the embedded fragment fabricated into `path`.
        XCTAssertEqual(args?["content"] as? String, "say \"hi\" then ",
                       "Pins the documented truncation under residual ambiguity (not an endorsement)")
        XCTAssertEqual(args?["path"] as? String, "/etc/x")
    }

    // MARK: - parseAfterContentReescape: two-raw-field absorption (residual ambiguity)

    func testReescape_twoRawContentFields_absorbsSecondIntoFirst_residualAmbiguity() {
        // Both old_text AND new_text carry raw quotes. Re-escaping new_text leaves the raw
        // old_text in the prefix (still broken), so the max-arg split lands on OLD_TEXT and
        // absorbs the entire `","new_text":"c"d` run into old_text's value — keeping
        // {old_text, path} (both known keys) and dropping new_text as a separate arg. This is
        // the SAME residual-ambiguity root cause as
        // `testReescape_embeddedKnownKeyFragment_residualAmbiguity`: the bytes are identical
        // whether the embedded `","key":"…"` is structure or literal content. Pins CURRENT
        // behaviour — two-raw-field envelopes recover by ABSORPTION, not by failing closed.
        // NOT an endorsement; a deliberate heuristic change should update this test.
        let broken = #"{"name":"edit_file","arguments":{"old_text":"a"b","new_text":"c"d","path":"x.py"}}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken), "Pre-condition: strict-broken")
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(broken)
        XCTAssertEqual(call?.name, "edit_file", "Recovers (does not fail closed) via the max-arg split")
        let args = try? JSONSerialization.jsonObject(
            with: (call?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?["path"] as? String, "x.py", "Trailing clean arg preserved")
        XCTAssertNil(args?["new_text"], "new_text is absorbed into old_text, not a separate arg")
        XCTAssertEqual(args?["old_text"] as? String, #"a"b","new_text":"c"d"#,
                       "old_text absorbs the new_text run (documented residual ambiguity)")
        XCTAssertEqual(args?.count, 2, "Exactly {old_text, path} survive")
    }

    // MARK: - parseAfterContentReescape: fail-closed boundaries

    func testReescape_exceedsQuoteScanCap_failsClosed() {
        // The `tried < 500` cap bounds the quote scan. A content value with >500 interior quotes
        // pushes the real closing quote past the cap → no qualifying split is found before the
        // budget runs out → graceful nil (no hang, no wrong split).
        let manyQuotes = String(repeating: "\"", count: 600)
        let broken = "{\"name\":\"write_file\",\"arguments\":{\"content\":\"" + manyQuotes
            + "\",\"path\":\"x\"}}"
        XCTAssertNil(JSONUtilities.parseJSONDictionary(broken), "Pre-condition: strict-broken")
        XCTAssertNil(ToolCallParsingHelpers.parseToolCallFromJSON(broken),
                     "Quote scan beyond the cap must fail closed, not hang or mis-split")
    }

    // MARK: - CallMarkerStrategy raw-body fallback: nested <|end|> inside the body

    func testHarmonyExtraction_nestedEndMarkerInsideBody_failsClosed() {
        // The walker fails (missing key-quote `,path":` flips parity), so the raw-body fallback
        // runs. It uses the FIRST `<|end|>` as the body boundary — but here a literal `<|end|>`
        // sits INSIDE the content value, before the real terminator. The body is truncated at the
        // nested marker → unrepairable → dropped. Pins that the first-<|end|>-wins truncation
        // fails closed rather than dispatching a corrupted call.
        let envelope = #"<|call|>{"name":"write_file","arguments":{"content":"see <|end|> here",path":"a.md"}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 0, "Nested <|end|> truncates the fallback body → call dropped")
    }

    // MARK: - extractJSONBracedValue: stray backslash before a structural close (direct unit)

    func testBraceWalker_strayBackslashBeforeClose_returnsNil() {
        // The uniform-escape change (escapes handled inside AND outside strings) makes a stray `\`
        // before a structural `}` consume the brace, so depth never balances and there is no prior
        // close to salvage → nil. Direct pin of the "returns nil instead of a broken span" half of
        // the superset claim (otherwise tested only end-to-end).
        let s = #"{"a":1\}"#  // raw string: the backslash is literal → {"a":1\}
        let sub = s[...]
        XCTAssertNil(
            ToolCallParsingHelpers.extractJSONBracedValue(in: sub, from: sub.startIndex),
            "Stray backslash before a structural close must fail closed (nil), not return a broken span")
    }

    // MARK: - spurious-escaped angle bracket: full edit_file recovery (end-to-end)

    func testEditFile_strayBackslashBeforeAngleBracketClose_recoversAllThreeArgs() {
        // Verbatim shape from network_log.json response 403E50AE (model gemma-4-26b-a4b):
        // an edit_file whose `old_text` value ends with the HTML close tag `</div\>` — a
        // spurious backslash before `>`. Before the sanitizer fix, strict parse failed and
        // `parseAfterContentReescape` absorbed `old_text` into `new_text`, dispatching a
        // corrupted call with only {new_text, path} → "Missing required argument: old_text".
        // After the fix the sanitizer drops the stray backslash, strict parse succeeds, and
        // ALL THREE args survive intact (reescape is never reached).
        let envelope = #"{"name":"edit_file","arguments":{"new_text":"<div id=\"result-display\" class=\"output-container\">new</div>","old_text":"<div id=\"result-display\" class=\"placeholder\">old</div\>","path":"index.html"}}"#
        // Pre-condition: the raw arguments object is strict-broken on the stray \>.
        XCTAssertNil(JSONUtilities.parseJSONDictionary(envelope),
                     "Pre-condition: stray \\> makes the envelope strict-broken")

        let call = ToolCallParsingHelpers.parseToolCallFromJSON(envelope)
        XCTAssertEqual(call?.name, "edit_file")
        let args = try? JSONSerialization.jsonObject(
            with: (call?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?.count, 3, "All three args must survive — no silent drop")
        XCTAssertEqual(args?["path"] as? String, "index.html")
        XCTAssertEqual(args?["new_text"] as? String,
                       #"<div id="result-display" class="output-container">new</div>"#)
        XCTAssertEqual(args?["old_text"] as? String,
                       #"<div id="result-display" class="placeholder">old</div>"#,
                       "old_text recovered intact with the stray backslash dropped (not absorbed)")
    }

    func testEditFile_strayBackslashBeforeAngleBracketOpen_recoversAllThreeArgs() {
        // Symmetric to the close-bracket case, end-to-end through `parseToolCallFromJSON`:
        // a spurious `\<` (gemma over-escaping a literal `<` in code). The unit-level
        // sanitizer test covers the byte transform; this proves the full dispatch path
        // (sanitize → strict parse → tool call) survives the open bracket too.
        let envelope = #"{"name":"edit_file","arguments":{"old_text":"if (x \< y) {","new_text":"if (x < y) {","path":"app.js"}}"#
        XCTAssertNil(JSONUtilities.parseJSONDictionary(envelope),
                     "Pre-condition: stray \\< makes the envelope strict-broken")
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(envelope)
        XCTAssertEqual(call?.name, "edit_file")
        let args = try? JSONSerialization.jsonObject(
            with: (call?.argumentsJSON ?? "").data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(args?.count, 3, "All three args survive")
        XCTAssertEqual(args?["old_text"] as? String, "if (x < y) {",
                       "Stray \\< recovered to a literal `<`")
        XCTAssertEqual(args?["new_text"] as? String, "if (x < y) {")
        XCTAssertEqual(args?["path"] as? String, "app.js")
    }

    // MARK: - malformedJSONDiagnostic (parse error attached to the retry nudge)

    func testMalformedJSONDiagnostic_noCallMarker_returnsNil() {
        // Only <|channel|> markers, no <|call|> — no concrete defect to name;
        // the caller keeps its generic hint list.
        XCTAssertNil(ToolCallParsingHelpers.malformedJSONDiagnostic(
            in: "<|channel|>commentary some prose"))
    }

    func testMalformedJSONDiagnostic_noJSONAfterMarker_namesIt() {
        XCTAssertEqual(
            ToolCallParsingHelpers.malformedJSONDiagnostic(in: "<|call|>ping<|end|>"),
            "no JSON object follows `<|call|>`")
    }

    func testMalformedJSONDiagnostic_unbalancedBraces_namesIt() {
        // No closing brace anywhere — beyond even the salvage path.
        XCTAssertEqual(
            ToolCallParsingHelpers.malformedJSONDiagnostic(
                in: #"<|call|>{"name":"write_file","arguments":{"path":"x"#),
            "the JSON object's braces never balance")
    }

    func testMalformedJSONDiagnostic_strictParseError_surfacesParserMessage() {
        // Braces balance but the object is invalid — an unescaped quote inside
        // a string value, the canonical production defect (models emitting
        // HTML/JS content inside create_artifact). The diagnostic carries the
        // actual JSONSerialization error, single line. (NOT a trailing comma:
        // macOS 26's swift-foundation JSONSerialization silently ACCEPTS
        // trailing commas, so that input parses and yields nil.)
        let diag = ToolCallParsingHelpers.malformedJSONDiagnostic(
            in: #"<|call|>{"name":"x","arguments":{"content":"say "hi""}}<|end|>"#)
        XCTAssertNotNil(diag, "a concrete parser error must be surfaced")
        XCTAssertFalse(diag!.isEmpty)
        XCTAssertFalse(diag!.contains("\n"), "diagnostic must be a single line")
        XCTAssertNotEqual(diag, "no JSON object follows `<|call|>`")
        XCTAssertNotEqual(diag, "the JSON object's braces never balance")
    }

    func testMalformedJSONDiagnostic_validJSON_returnsNil() {
        XCTAssertNil(ToolCallParsingHelpers.malformedJSONDiagnostic(
            in: #"<|call|>{"name":"x","arguments":{}}<|end|>"#))
    }

    /// Repair-recoverable envelope (strict parse fails, `parseAfterRepair`
    /// succeeds): classify falls to `.malformedJSON` for a DIFFERENT reason,
    /// so a confident strict-parse error would mislead the model about JSON
    /// the pipeline can actually accept — the diagnostic must return nil and
    /// let the generic hints stand. Uses the verbatim qwen fixture: its TWO
    /// unescaped-quote defects keep quote parity, so the brace walk extracts
    /// the object and the strict-parse/repair arms are genuinely exercised
    /// (a single-defect payload dies earlier, in extraction).
    func testMalformedJSONDiagnostic_repairRecoverableEnvelope_returnsNil() {
        // Pre-conditions: strict-broken but repair-recoverable (pinned above by
        // testStrictJSONSerialization_rejects… / testRepair_recovers…).
        XCTAssertNotNil(ToolCallParsingHelpers.parseAfterRepair(Self.verbatimBrokenPayload))
        let envelope = "<|call|>\(Self.verbatimBrokenPayload)<|end|>"
        XCTAssertNil(ToolCallParsingHelpers.malformedJSONDiagnostic(in: envelope),
                     "repair-recoverable envelope must not get a strict-parse diagnostic")
    }

    // MARK: - qwen3.8:27b-mlx: missing key quote + dropped closing brace (composed)

    /// Reduced from CubeCraft `tasks/8/runs/0/network_log.json` response 85235A94
    /// (2026-08-16, Ollama `qwen3.8:27b-mlx`): TWO defects in one `edit_file` envelope —
    /// the `path` key lost its OPENING quote (`,path":`, the family
    /// `repairMissingQuoteBeforeJSONKey` exists for) AND the final closing brace is
    /// missing (`"}` before `<|end|>` where `"}}` was needed). Each alone is recoverable;
    /// composed they poisoned the pipeline, because the brace walk runs on UNREPAIRED
    /// bytes: the missing quote inverts string parity from that point on, `old_text`'s
    /// value reads as structure, its `]` becomes the mid-string EOF salvage's anchor, and
    /// the "salvaged" span is truncated mid-value — unrepairable by any regex. The run's
    /// call died as `malformed_tool_call` although every argument was complete.
    /// `new_text` is shortened (the run's was 2478 bytes); `old_text` is verbatim.
    private static let composedDefectEnvelope =
        "<|call|>"
            + #"{"name":"edit_file","arguments":{"new_text":"const TEX_SIZE = 16;\n",path":"CubeCraft/game.js","old_text":"  const GROUND_COLOR = [ 70, 110, 50 ];    // floor plane\n"}"#
            + "<|end|>"

    /// Same composition, but the broken key is NOT identifier-shaped (`my-path`), so
    /// `repairMissingQuoteBeforeJSONKey` cannot match and no repair changes the bytes.
    private static let unrepairableComposedEnvelope =
        "<|call|>"
            + #"{"name":"edit_file","arguments":{"new_text":"const A = 1;\n",my-path":"a/b.js","old_text":"x = [ 1, 2 ];  // keep\n"}"#
            + "<|end|>"

    /// Sanity for the rescue tests below: on the UNREPAIRED bytes the walker's mid-string
    /// EOF salvage anchors on the `]` INSIDE `old_text`'s value and truncates the span
    /// there, discarding `;    // floor plane\n` — which is why parsing the walked span
    /// can never recover this envelope and the raw-body rescue exists. Pins the poisoning
    /// so a future fixture edit can't make the recovery test pass for the wrong reason.
    func testComposedDefect_walkedSpanIsTruncatedInsideOldText_preCondition() {
        let callRange = Self.composedDefectEnvelope.range(of: "<|call|>")!
        let tail = Self.composedDefectEnvelope[callRange.upperBound...]
        guard let (span, _) = ToolCallParsingHelpers.extractJSONBracedValue(
            in: tail, from: tail.startIndex, salvageEndMarker: "<|end|>")
        else {
            return XCTFail("the mid-string EOF salvage is expected to fire on this shape")
        }
        XCTAssertTrue(span.hasSuffix("]}}"),
                      "salvage truncates right after old_text's `]` and pads `}}`: \(span.suffix(40))")
        XCTAssertFalse(span.contains("// floor plane"),
                       "the bytes after the poisoned anchor are discarded from the span")
    }

    /// RED: revert `CallMarkerStrategy`'s fall-through to the raw-body fallback (continue
    /// unconditionally after a walked-span parse failure), or drop the
    /// `parseAfterRepairAndRewalk` layer → this envelope yields 0 calls again and the
    /// 1-rescued-call assertion fails (verified both ways: mutations M1 and M2).
    func testComposedDefect_missingKeyQuotePlusDroppedCloser_recoversTheFullCall() {
        let calls = HarmonyToolCallParser().extractAllToolCalls(
            from: Self.composedDefectEnvelope)
        guard calls.count == 1 else {
            return XCTFail("expected exactly 1 rescued call, got \(calls.count)")
        }
        XCTAssertEqual(calls[0].name, "edit_file")
        let args = JSONUtilities.parseJSONDictionary(calls[0].argumentsJSON)
        XCTAssertEqual(args?["path"] as? String, "CubeCraft/game.js")
        XCTAssertEqual(args?["new_text"] as? String, "const TEX_SIZE = 16;\n")
        XCTAssertEqual(
            args?["old_text"] as? String,
            "  const GROUND_COLOR = [ 70, 110, 50 ];    // floor plane\n",
            "old_text must survive COMPLETE — the model sent it complete; truncating it at "
                + "the `]` (the walker's salvage anchor) is the poisoning this rescue removes")
    }

    /// The rescue consumes exactly its own `<|call|>…<|end|>` block: a healthy sibling
    /// envelope after it must still parse. Pins the fallback's cursor advancement.
    func testComposedDefect_rescueDoesNotDisturbAHealthySiblingEnvelope() {
        let healthy = #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(
            from: Self.composedDefectEnvelope + "\n" + healthy)
        XCTAssertEqual(calls.map(\.name), ["edit_file", "git_status"])
    }

    /// The rescue is gated on a repair actually CHANGING the bytes — rewalking unrepaired
    /// bytes would reproduce the same poisoned span. With no matching repair the payload
    /// must stay undispatched (a malformed card + retry nudge), never a fabricated call.
    func testComposedDefect_unrepairableKeyShape_staysUndispatched() {
        let calls = HarmonyToolCallParser().extractAllToolCalls(
            from: Self.unrepairableComposedEnvelope)
        XCTAssertTrue(calls.isEmpty,
                      "no repair matches `,my-path\":` — nothing may dispatch: \(calls)")
    }
}
