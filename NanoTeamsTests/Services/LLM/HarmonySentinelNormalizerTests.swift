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

    // MARK: - Fast-path arms (2026-08-21, post-windowing)

    /// Since detection moved into `StreamMarkerWindow`, `normalize` runs on full
    /// buffers only after a needle was seen — but its no-op guard is still the
    /// contract for the parser's one-shot callers, where the sentinel can be absent.
    func testPlainProse_returnsTheExactSameString() {
        let prose = "no sentinel anywhere in this reply, just prose"
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(prose), prose)
    }

    /// A buffer carrying BOTH a non-normalizable occurrence (prose about the
    /// token, no payload) and a genuine one: the first must be emitted verbatim,
    /// the second rewritten — the emit-and-continue arm of the rebuild loop.
    func testMixedOccurrences_verbatimThenRewritten() {
        let text = "talking about <|tool_call tokens and then <|tool_call>call|>{\"a\":1}"
        let normalized = HarmonySentinelNormalizer.normalize(text)
        XCTAssertTrue(normalized.contains("talking about <|tool_call tokens"),
                      "the payload-less occurrence must survive verbatim")
        XCTAssertTrue(normalized.contains("<|call|>{\"a\":1}"),
                      "the genuine occurrence must be rewritten")
    }

    // MARK: - Truncated canonical sentinel (CastleSurvivorsNT task 12 run 1, 2026-09-05)

    /// `ornith-1.5:35b` on Ollama dropped the canonical marker's closing `>` and abutted
    /// the payload. Verbatim from the run's turn 41 (`network_log.jsonl`, the last
    /// assistant turn of the step).
    func testNormalize_truncatedCanonical_becomesCanonical() {
        let input = #"<|call|{"name":"bash","arguments":{"command":"git ls-tree -r --name-only dfba13d | grep -i guard_core"}}"#
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(input),
            #"<|call|>{"name":"bash","arguments":{"command":"git ls-tree -r --name-only dfba13d | grep -i guard_core"}}"#)
    }

    /// The payload must survive byte-for-byte — a `bash` command carries pipes, quotes
    /// and `$?`, and a repair that touched any of them would dispatch a different call
    /// than the model asked for.
    func testNormalize_truncatedCanonical_payloadIsUntouched() {
        let input = #"<|call|{"name":"bash","arguments":{"command":"cd . && git ls-tree -r --name-only dfba13d | grep -i guard_core; echo \"exit $?\""}}"#
        let output = HarmonySentinelNormalizer.normalize(input)
        XCTAssertTrue(output.hasPrefix(#"<|call|>{"#))
        XCTAssertTrue(output.hasSuffix(#"echo \"exit $?\""}}"#))
    }

    /// Prose then the broken sentinel on its own line — the run's turn 25 shape.
    func testNormalize_truncatedCanonicalAfterProse_repairsOnlyTheSentinel() {
        let input = "Let me find guard_core.gd in git.\n" +
            #"<|call|{"name":"bash","arguments":{}}"#
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(input),
            "Let me find guard_core.gd in git.\n" +
                #"<|call|>{"name":"bash","arguments":{}}"#)
    }

    func testNormalize_truncatedCanonical_isIdempotent() {
        let once = HarmonySentinelNormalizer.normalize(#"<|call|{"name":"search"}"#)
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(once), once)
        XCTAssertEqual(once, #"<|call|>{"name":"search"}"#)
    }

    /// Both families in one buffer, repaired left to right — `nextSentinel` orders by
    /// position, so neither prefix can starve the other.
    func testNormalize_bothFamiliesInOneBuffer_bothRepaired() {
        let input = #"<|tool_call>call|>{"name":"search"} then <|call|{"name":"read_file"}"#
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(input),
            #"<|call|>{"name":"search"} then <|call|>{"name":"read_file"}"#)
    }

    // MARK: - Truncated canonical: the negatives are the safety argument

    /// The whole reason this family tolerates no debris. `<|call|>tool_name{…}` is a
    /// live `CallMarkerStrategy` branch; a debris-tolerant rule would rewrite it and
    /// `trailingToolName` would drop any identifier `ToolNames.allNames` does not list,
    /// leaving a nameless payload that resolves to nothing.
    func testNormalize_canonicalWithToolName_isByteIdentical() {
        let input = #"<|call|>read_file{"path":"a.swift"}<|end|>"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// Same shape with a name that is NOT a tool — the case a tolerant rule would
    /// silently strip.
    func testNormalize_canonicalWithUnknownName_isByteIdentical() {
        let input = #"<|call|>mystery_tool{"path":"a.swift"}<|end|>"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// A name between the broken sentinel and the payload is NOT repaired: no run has
    /// produced this shape, and admitting it is exactly what would reach the two cases
    /// above.
    func testNormalize_truncatedCanonicalWithDebris_isUntouched() {
        let input = #"<|call|read_file{"path":"a.swift"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    func testNormalize_truncatedCanonicalWithSpaceBeforeBrace_isUntouched() {
        let input = #"<|call| {"name":"search"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    func testNormalize_truncatedCanonicalWithNewlineBeforeBrace_isUntouched() {
        let input = "<|call|\n{\"name\":\"search\"}"
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// Mid-stream: the sentinel arrived but its payload has not. `nil` here is retried
    /// on the next delta, never final — same contract as the alien family.
    func testNormalize_truncatedCanonicalAtBufferEnd_isUntouched() {
        let input = "Let me call a tool.\n<|call|"
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// Prose ABOUT the sentinel carries no abutting brace, so it can never be promoted.
    func testNormalize_proseMentioningCallToken_isUntouched() {
        let input = "Write <|call| and then the JSON object on the same line."
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// A canonical envelope and a broken one in the same buffer: the canonical one must
    /// come through untouched while the broken one is repaired.
    func testNormalize_canonicalThenTruncated_onlyTheBrokenOneChanges() {
        let input = #"<|call|>{"name":"search"}<|end|> and <|call|{"name":"read_file"}"#
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(input),
            #"<|call|>{"name":"search"}<|end|> and <|call|>{"name":"read_file"}"#)
    }

    /// `hasNormalizableOccurrence` is the streaming gate, so it must agree with
    /// `normalize` on every fixture above — a gate that says "nothing to do" over a
    /// buffer `normalize` would rewrite is a call dropped before the parser is reached.
    func testHasNormalizableOccurrence_agreesWithNormalize() {
        let cases: [String] = [
            #"<|call|{"name":"bash","arguments":{}}"#,
            #"<|call|>{"name":"bash"}<|end|>"#,
            #"<|call|>read_file{"path":"a"}"#,
            #"<|call|read_file{"path":"a"}"#,
            #"<|call| {"name":"search"}"#,
            "<|call|",
            "prose with no sentinel",
            #"<|tool_call>call|>{"name":"search"}"#,
        ]
        for text in cases {
            let rewritten = HarmonySentinelNormalizer.normalize(text) != text
            XCTAssertEqual(
                HarmonySentinelNormalizer.hasNormalizableOccurrence(in: text[...]), rewritten,
                "gate and rewrite disagree on: \(text)")
        }
    }
}
