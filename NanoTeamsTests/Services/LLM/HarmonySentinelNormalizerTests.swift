import XCTest

@testable import NanoTeams

/// Pins the three forms `google/gemma-4-e4b` was observed to emit, and — more
/// importantly — the four it must NOT touch. The normalizer's whole safety argument is
/// that it demands an intent signal (`{` right after a whitespace-free debris run), so
/// the negatives carry more weight here than the positives.
final class HarmonySentinelNormalizerTests: XCTestCase {

    private let canonical = "<|call|>"

    // MARK: - Positives (verbatim from the 2026-08-07 MeditationApp run)

    /// Record `[33]` @13:51:15.910Z.
    func testNormalize_toolCallGtCallPipeGt_becomesCanonical() {
        let input = #"<|tool_call>call|>{"name":"list_files","arguments":{"path":"MeditationApp"}}|<|<end|>"#
        let output = HarmonySentinelNormalizer.normalize(input)
        XCTAssertTrue(output.hasPrefix(canonical + "{"))
        XCTAssertTrue(output.contains(#""name":"list_files""#), "payload must be untouched")
    }

    /// Record `[39]` @13:52:24.821Z — no closing `|>` on the alien token at all.
    func testNormalize_toolCallGtCallMultiple_becomesCanonical() {
        let input = #"<|tool_call>call_multiple{"contributions":[]}<|end|>"#
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(input),
            #"<|call|>{"contributions":[]}<|end|>"#)
    }

    /// The unspliced training-data token, which the other two are corruptions of.
    func testNormalize_plainToolCallToken_becomesCanonical() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(#"<|tool_call|>{"name":"search"}"#),
            #"<|call|>{"name":"search"}"#)
    }

    func testNormalize_preservesPrecedingProse() {
        let input = #"Done. <|tool_call>call|>{"name":"git_status","arguments":{}}<|end|>"#
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(input),
            #"Done. <|call|>{"name":"git_status","arguments":{}}<|end|>"#)
    }

    func testNormalize_repairsEveryOccurrence() {
        let input = #"<|tool_call|>{"a":1}<|end|> then <|tool_call>call|>{"b":2}<|end|>"#
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(input),
            #"<|call|>{"a":1}<|end|> then <|call|>{"b":2}<|end|>"#)
    }

    // MARK: - Negatives — the intent signal is missing

    /// No payload brace: the model is TALKING about the sentinel, not using it.
    /// Promoting this is the inference `BareToolCallSalvage` explicitly refuses.
    func testNormalize_tokenWithoutPayload_isUntouched() {
        let input = "Emit your call as <|tool_call|> followed by the arguments."
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// Whitespace between the token and the brace means prose, not one token.
    func testNormalize_whitespaceBeforeBrace_isUntouched() {
        let input = #"<|tool_call|> {"name":"search"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    func testNormalize_newlineBeforeBrace_isUntouched() {
        let input = "<|tool_call|>\n{\"name\":\"search\"}"
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// Debris run past the cap — a scan that walked this far could swallow prose on its
    /// way to an unrelated brace.
    func testNormalize_debrisRunOverCap_isUntouched() {
        let input = #"<|tool_call>aaaaaaaaaaaaaaaaaaaaaaaaaaaaa{"name":"search"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// The bare word carries no `<|`, so it can never match.
    func testNormalize_proseMentioningToolCall_isUntouched() {
        let input = #"Use a tool_call like {"name":"search"} when you need results."#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    // MARK: - Invariants

    func testNormalize_canonicalEnvelope_isByteIdentical() {
        let input = #"<|call|>{"name":"read_file","arguments":{"path":"a.swift"}}<|end|>"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    func testNormalize_isIdempotent() {
        let once = HarmonySentinelNormalizer.normalize(#"<|tool_call>call|>{"name":"search"}"#)
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(once), once)
    }

    func testNormalize_emptyAndPlainText_areUntouched() {
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(""), "")
        XCTAssertEqual(HarmonySentinelNormalizer.normalize("Just prose."), "Just prose.")
    }

    /// A non-matching occurrence must not stop the scan — otherwise one mention of the
    /// token in prose would suppress repair of a real call later in the same buffer.
    func testNormalize_unmatchedOccurrenceDoesNotBlockLaterRepair() {
        let input = #"See <|tool_call|> docs. <|tool_call>call|>{"name":"search"}"#
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(input),
            #"See <|tool_call|> docs. <|call|>{"name":"search"}"#)
    }

    // MARK: - Parser integration

    /// The parser normalizes at its own entry so callers that hand it a finished body
    /// (`TeamGenerationService`, `DelegatedSupervisorAnswerService`) are covered without
    /// a marker-detection pass of their own.
    func testParser_extractAllToolCalls_repairsGarbledSentinel() {
        let calls = HarmonyToolCallParser().extractAllToolCalls(
            from: #"<|tool_call>call|>{"name":"list_files","arguments":{"path":"src"}}<|end|>"#)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.listFiles)
    }

    /// The diagnostic classifier must agree with the parser, or a mangled sentinel is
    /// reported as "you never attempted a call" when the model plainly did.
    func testClassify_garbledSentinelWithNamelessPayload_isMissingToolName() {
        XCTAssertEqual(
            ToolCallParsingHelpers.classifyHarmonyCallIssue(
                in: #"<|tool_call>call_multiple{"contributions":[]}<|end|>"#),
            .missingToolName(inferredToolName: nil))
    }

    // MARK: - classify ↔ diagnostic parity

    /// `classifyHarmonyCallIssue` and `malformedJSONDiagnostic` are a PAIR: classify picks
    /// the nudge, the diagnostic fills in its parenthetical. Both build on `postCallJSON`,
    /// whose marker test is an exact substring, so normalizing one and not the other makes
    /// them disagree — classify answers `.malformedJSON`, the diagnostic answers
    /// `.noCallMarker` → nil, and the model is handed the generic brace/quote/comma guesses
    /// instead of the parser's own sentence.
    func testMalformedJSONDiagnostic_namesTheDefectThroughAGarbledSentinel() {
        let garbled = #"<|tool_call>call|>{"name":"read_file","arguments":{"path":"a" "b"}}<|end|>"#
        XCTAssertEqual(
            ToolCallParsingHelpers.classifyHarmonyCallIssue(in: garbled), .malformedJSON)
        let defect = ToolCallParsingHelpers.malformedJSONDiagnostic(in: garbled)
        XCTAssertNotNil(defect, "a classify verdict of .malformedJSON must be nameable")
        XCTAssertFalse(defect?.isEmpty ?? true)
    }

    /// The canonical envelope is the control: the pair already agreed on it, and
    /// normalization must not change that answer by a byte.
    func testMalformedJSONDiagnostic_canonicalEnvelope_matchesTheGarbledOne() {
        let canonical = #"<|call|>{"name":"read_file","arguments":{"path":"a" "b"}}<|end|>"#
        let garbled = #"<|tool_call>call|>{"name":"read_file","arguments":{"path":"a" "b"}}<|end|>"#
        XCTAssertEqual(
            ToolCallParsingHelpers.malformedJSONDiagnostic(in: canonical),
            ToolCallParsingHelpers.malformedJSONDiagnostic(in: garbled))
    }

    // MARK: - Fast path

    /// The normalizer runs on the WHOLE accumulated buffer on every content delta until a
    /// marker is found, so a buffer carrying the alien token with NO payload after it must
    /// short-circuit rather than rebuild the string once per delta. The risk that fast path
    /// introduces is bailing when a rewrite WAS needed — pinned from the other side by the
    /// positive tests above, which all go red if `hasNormalizableOccurrence` under-reports.
    /// This pins the side it owns: every unmatched shape comes back untouched.
    func testNormalize_unmatchedShapes_comeBackUntouched() {
        let unmatched = [
            "The model emits <|tool_call and then, separately, some prose.",
            "<|tool_call",                                   // sentinel mid-stream, no payload
            "<|tool_call> here is what it means",            // whitespace ⇒ prose
            "<|tool_call>" + String(repeating: "x", count: 40) + "{}",  // debris over the cap
            "plain text with no token at all",
            "",
        ]
        for text in unmatched {
            XCTAssertEqual(HarmonySentinelNormalizer.normalize(text), text, text)
        }
    }
}
