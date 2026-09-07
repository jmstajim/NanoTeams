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

    /// A WHITESPACE run between the broken sentinel and its payload is repaired, and the
    /// abutment rule the type comment gives never covered it: `prefixTable` is sorted
    /// longest-first, so `<|call|>` matches as `.canonical` BEFORE `<|call|` is offered —
    /// which means at a `.truncatedCanonical` hit the next character is provably not `>`,
    /// and no shape that parses today can carry whitespace there. This pin asserted the
    /// opposite from 2026-09-05 until 2026-09-07, and its fixture is byte-for-byte the
    /// shape that broke `MeditationApp` task 39 run 8 the next day.
    func testNormalize_truncatedCanonicalWithSpaceBeforeBrace_becomesCanonical() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(#"<|call| {"name":"search"}"#),
            #"<|call|>{"name":"search"}"#)
    }

    func testNormalize_truncatedCanonicalWithNewlineBeforeBrace_becomesCanonical() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize("<|call|\n{\"name\":\"search\"}"),
            #"<|call|>{"name":"search"}"#)
    }

    /// The gap is a CAP, not an invitation. Five spaces is prose spacing, not a mangled
    /// token, and the same argument that bounds `maxWrapperGap` bounds this one.
    func testNormalize_truncatedCanonicalGapOverCap_isUntouched() {
        let input = #"<|call|     {"name":"search"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// Whitespace is the ONLY tolerated run. A name in the gap stays untouched exactly as
    /// it did before the gap existed — `trailingToolName` would otherwise have to decide
    /// identity across a space, which is the 2026-08-14 identity-loss defect one step on.
    func testNormalize_truncatedCanonicalWithSpacedName_isUntouched() {
        let input = #"<|call| read_file{"path":"a.swift"}"#
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
            // ChatML wrapper family (2026-09-07) — both sides of every decision.
            "x<tool_call>\n" + #"<|call|>{"name":"bash"}"#,
            "x<tool_call>" + #"<|call|>{"name":"bash"}"#,
            "<tool_call>\n<|start|>assistant",
            "x<tool_call>\n" + #"<|call|{"name":"bash"}"#,
            "x<tool_call>     \n" + #"<|call|>{"name":"bash"}"#,
            "x<tool_call> but first some prose " + #"<|call|>{"name":"bash"}"#,
            #"<tool_call>{"name":"bash"}</tool_call>"#,
            "<tool_call> alone in prose",
            #"<|call|>{"name":"bash"}</tool_call>"#,
        ]
        for text in cases {
            let rewritten = HarmonySentinelNormalizer.normalize(text) != text
            XCTAssertEqual(
                HarmonySentinelNormalizer.hasNormalizableOccurrence(in: text[...]), rewritten,
                "gate and rewrite disagree on: \(text)")
        }
    }

    // MARK: - ChatML wrapper (MeditationApp task 39 run 1, 2026-09-07)

    /// `ornith-1.5:35b` on Ollama wrapped the CANONICAL envelope in its own native
    /// ChatML tool-call tag instead of choosing between the two forms:
    ///
    ///     …and ContentView.swift.<tool_call>
    ///     <|call|>{"name":"read_file",…}
    ///     <|end|>
    ///     </tool_call>
    ///
    /// The envelope parses and the call dispatches, so nothing raised a diagnostic — but
    /// the opening tag sits BEFORE the earliest marker, survives the truncation rewind
    /// into `assistantCollected`, and is invisible to `ModelTokenCleaner` (whose contract
    /// is `<|…|>` spans only). It reached the user as literal text in the bubble AND rode
    /// the append-only wire, so the model saw its own tag as the freshest example: 10 of
    /// 10 non-empty turns after the first slip carried it, 64 occurrences replayed.
    ///
    /// Measured over the run: the gap between tag and marker was a single `\n` in all 10
    /// cases; `</tool_call>` appeared exactly ONCE in 28 turns (the model almost never
    /// closes it), which is why the marker-less `<tool_call>{…}</tool_call>` form is out
    /// of scope by measurement rather than deferred.
    private let wrappedTurn = """
    I'll start by reading the key files to understand the current structure before \
    implementing the Today tab. Let me first look at the folder layout and \
    ContentView.swift.<tool_call>
    <|call|>{"name":"read_file","arguments":{"path":"MeditationApp/ContentView.swift"}}
    <|end|>
    </tool_call>
    """

    func testNormalize_chatMLWrapperBeforeCanonical_isStripped() {
        let expected = """
        I'll start by reading the key files to understand the current structure before \
        implementing the Today tab. Let me first look at the folder layout and \
        ContentView.swift.
        <|call|>{"name":"read_file","arguments":{"path":"MeditationApp/ContentView.swift"}}
        <|end|>
        </tool_call>
        """
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(wrappedTurn), expected)
    }

    /// Zero gap — the tag abuts the marker directly.
    func testNormalize_chatMLWrapperZeroGap_isStripped() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(#"done.<tool_call><|call|>{"name":"bash"}"#),
            #"done.<|call|>{"name":"bash"}"#)
    }

    /// The tag opens the buffer, so the wrapper's lower bound EQUALS the rebuild cursor.
    /// The floor comparison must therefore be `>=`, not `>` — records 68 and 80 of the run
    /// are exactly this shape, and a strict comparison would leave both uncleaned.
    func testNormalize_chatMLWrapperAtBufferStart_isStripped() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize("<tool_call>\n" + #"<|call|>{"name":"bash"}"#),
            "\n" + #"<|call|>{"name":"bash"}"#)
    }

    /// The wrapper is stripped before ANY marker the streamer latches on, not just
    /// `<|call|>` — the family is defined by `HarmonyToolCallParser.harmonyMarkers`, the
    /// same set `sawHarmonyMarker` and the earliest-marker rewind use.
    func testNormalize_chatMLWrapperBeforeStartMarker_isStripped() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize("x<tool_call>\n<|start|>assistant"),
            "x\n<|start|>assistant")
    }

    func testNormalize_chatMLWrapperBeforeChannelMarker_isStripped() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize("x<tool_call>\n<|channel|>commentary"),
            "x\n<|channel|>commentary")
    }

    /// Composition with the 2026-09-05 family: the tag must not survive in front of a
    /// sentinel this same pass repairs, or the leak simply moves one family to the left.
    func testNormalize_chatMLWrapperBeforeTruncatedSentinel_bothRepaired() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize("x<tool_call>\n" + #"<|call|{"name":"bash"}"#),
            "x\n" + #"<|call|>{"name":"bash"}"#)
    }

    /// Same, for the 2026-08-07 alien family.
    func testNormalize_chatMLWrapperBeforeAlienSentinel_bothRepaired() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize("x<tool_call>\n" + #"<|tool_call>call|>{"a":1}"#),
            "x\n" + #"<|call|>{"a":1}"#)
    }

    func testNormalize_twoChatMLWrappers_bothStripped() {
        let input = "a<tool_call>\n" + #"<|call|>{"a":1}"# + " b<tool_call>\n" + #"<|call|>{"b":2}"#
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(input),
            "a\n" + #"<|call|>{"a":1}"# + " b\n" + #"<|call|>{"b":2}"#)
    }

    func testNormalize_chatMLWrapper_isIdempotent() {
        let once = HarmonySentinelNormalizer.normalize(wrappedTurn)
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(once), once)
    }

    /// The CLOSING tag is deliberately left alone: it arrives after the latch, so the
    /// streamer never re-normalizes it, and in the one branch where it can still reach the
    /// wire (`unresolvedEnvelopeAnchor`) evidence beats cleanliness. Pinned so a future
    /// "tidy up the closer too" edit has to argue with this comment first.
    func testNormalize_chatMLClosingTag_survivesVerbatim() {
        XCTAssertTrue(HarmonySentinelNormalizer.normalize(wrappedTurn).hasSuffix("</tool_call>"))
    }

    // MARK: - ChatML wrapper: the negatives carry the safety argument

    /// The tag alone is prose about a format — `evidence.md` documents this very DSL, and
    /// the playbook names it at R3.8.7. Promoting it would corrupt our own documentation.
    func testNormalize_chatMLTagWithoutEnvelope_isByteIdentical() {
        let input = "Qwen3.8 emits <tool_call><function=read_file> natively."
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// The marker-less form. OUT OF SCOPE BY MEASUREMENT, not deferred: it needs a paired
    /// closer to be recognisable, and the model wrote `</tool_call>` exactly once in 28
    /// turns. Promoting text to a call without field evidence is the over-reach both
    /// `BareToolCallSalvage` and this file exist to refuse.
    func testNormalize_chatMLWrappedJSONWithoutMarker_isByteIdentical() {
        let input = #"<tool_call>{"name":"read_file","arguments":{"path":"a"}}</tool_call>"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// Gap over the cap: five spaces. The cap exists so the strip stays adjacency-gated
    /// rather than becoming a backward scan that could swallow prose.
    func testNormalize_chatMLTagGapOverCap_isUntouched() {
        let input = "x<tool_call>     " + #"<|call|>{"name":"bash"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// Non-whitespace between tag and marker means the model was writing prose.
    func testNormalize_proseBetweenChatMLTagAndMarker_isUntouched() {
        let input = "x<tool_call> as in " + #"<|call|>{"name":"bash"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    func testNormalize_truncatedChatMLTag_isUntouched() {
        let input = "x<tool_call\n" + #"<|call|>{"name":"bash"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// Exact literal only — case-folding here would be inference, the same rule
    /// `trailingToolName` states for tool names.
    func testNormalize_uppercaseChatMLTag_isUntouched() {
        let input = "x<TOOL_CALL>\n" + #"<|call|>{"name":"bash"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    func testNormalize_spacedChatMLTag_isUntouched() {
        let input = "x< tool_call >\n" + #"<|call|>{"name":"bash"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// `<tool_call|>` — the gemma junk form that ALREADY lives in two fixtures
    /// (`RealGemmaRunEnvelopeTests`, `MalformedToolCallEnvelopeCornerTests`). It differs
    /// from the wrapper on both axes at once: it does not open with `<|`, and it is not
    /// the literal `<tool_call>`. Assert both so a future widening of either has to break
    /// this test on purpose.
    func testNormalize_toolCallPipeGtJunk_isUntouched() {
        let input = #"<|call|>{"name":"create_artifact"}<tool_call|><afthought>done.</afthought>"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// A bare marker must come back byte-identical even though `.canonical` now makes the
    /// scan STOP on it — `nextSentinel` used to walk straight past `<|start|>` and
    /// `<|channel|>`, and re-emitting them is what keeps `classifyHarmonyCallIssue`'s
    /// input unchanged.
    func testNormalize_bareStartAndChannelMarkers_areByteIdentical() {
        let cases = [
            "<|start|>assistant<|channel|>final<|message|>hello",
            "<|channel|>analysis<|message|>thinking out loud",
            #"<|start|>{"name":"x"}"#,
            #"<|channel|>{"name":"x"}"#,
        ]
        for input in cases {
            XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input, input)
        }
    }

    /// **The fast-path invariant.** `.canonical` must count as normalizable ONLY when a
    /// wrapper actually precedes it. Without that condition `hasNormalizableOccurrence`
    /// returns `true` for every ordinary `<|call|>{…}` — and it is the guard on
    /// `normalize`'s early return, so every envelope-bearing turn would rebuild the whole
    /// buffer. That regression is invisible in output and shows up only as slowness,
    /// which is exactly why it is pinned rather than left to a behavioural test.
    func testHasNormalizableOccurrence_ordinaryEnvelope_staysOffTheRebuildPath() {
        let ordinary = [
            #"<|call|>{"name":"read_file","arguments":{"path":"a.swift"}}<|end|>"#,
            #"Here you go. <|call|>{"name":"bash","arguments":{"command":"ls"}}<|end|>"#,
            "<|start|>assistant<|channel|>final<|message|>plain answer",
            #"<|call|>read_file{"path":"a.swift"}<|end|>"#,
        ]
        for text in ordinary {
            XCTAssertFalse(
                HarmonySentinelNormalizer.hasNormalizableOccurrence(in: text[...]),
                "ordinary envelope must not arm the rebuild: \(text)")
        }
    }

    /// The classifier reads the NORMALIZED buffer, so a `.canonical` branch that failed to
    /// re-emit its marker verbatim would flip the verdict to `.noEnvelopeAttempt` and hand
    /// the model a nudge about a call it plainly made. Run through `classifyHarmonyCallIssue`,
    /// not just `normalize` — that is the consumer whose answer must not move.
    func testClassify_chatMLWrappedEnvelope_matchesTheUnwrappedOne() {
        let payload = #"<|call|>{"name":"read_file","arguments":{"path":"a" "b"}}<|end|>"#
        let wrapped = "prose.<tool_call>\n" + payload + "\n</tool_call>"
        let bare = "prose.\n" + payload
        XCTAssertEqual(ToolCallParsingHelpers.classifyHarmonyCallIssue(in: wrapped), .malformedJSON)
        XCTAssertEqual(
            ToolCallParsingHelpers.classifyHarmonyCallIssue(in: wrapped),
            ToolCallParsingHelpers.classifyHarmonyCallIssue(in: bare))
    }

    // MARK: - Linearity (DEBTS.md D-B6)

    /// `nextSentinel` inspects each `<|` candidate AT MOST ONCE across a whole rebuild:
    /// `searchFrom` only ever moves forward past an inspected opener, so its searches are
    /// disjoint spans whose lengths sum to the buffer's. That argument is the central
    /// claim of this file and, since the repair loop moved into a private helper, the
    /// complexity ratchet no longer guards it (D-B6) — so it is asserted here instead.
    ///
    /// The bound is deliberately loose (4×): `normalize` legitimately walks the candidates
    /// twice, once for the gate and once for the rebuild. A non-disjoint scan is
    /// quadratic — for this fixture ~20 000 inspections against a cap of 804 — so the
    /// margin costs nothing in discrimination.
    ///
    /// RED: in `nextSentinel`, search from the rebuild `cursor` instead of the advancing
    /// `searchFrom` → the scans stop being disjoint and the `LessThanOrEqual` bound below
    /// fails, reporting inspections in the tens of thousands.
    func testNextSentinel_inspectsEachCandidateAtMostOnce() {
        let candidates = 200
        let text = String(repeating: "<|x ", count: candidates) + #"<|call|{"a":1}"#
        HarmonySentinelNormalizer._testResetScanWork()
        _ = HarmonySentinelNormalizer.normalize(text)
        let work = HarmonySentinelNormalizer._testScanWork()
        XCTAssertGreaterThan(work, 0, "the counter must sit on the path actually taken")
        XCTAssertLessThanOrEqual(
            work, 4 * (candidates + 1),
            "scans must stay disjoint — \(work) inspections over \(candidates + 1) candidates")
    }

    // MARK: - Dangling `<|` before an envelope opening (task 39 run 8, record 115)

    /// The run's LAST turn opened with a bare `<|` on its own line and then the canonical
    /// envelope. The truncation rewind cuts at the earliest marker, so `<|` survived as
    /// assistant prose; `ModelTokenCleaner` cannot see it (no `|>` anywhere after it, so
    /// `stripTokensInPlace` breaks and returns the remainder verbatim), and it reached the
    /// user as a two-character bubble.
    ///
    /// It is the SAME shape as the `<tool_call>` wrapper — debris standing immediately to
    /// the left of an opening — so it is recognised by the same bounded look-back rather
    /// than by anything new (CLAUDE.md #192).
    func testNormalize_danglingSentinelOpenBeforeCanonical_isStripped() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize("<|\n" + #"<|call|>{"name":"create_artifact"}"#),
            "\n" + #"<|call|>{"name":"create_artifact"}"#)
    }

    func testNormalize_danglingSentinelOpenZeroGap_isStripped() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.normalize(#"done.<|<|call|>{"name":"bash"}"#),
            #"done.<|call|>{"name":"bash"}"#)
    }

    /// A COMPLETE token to the left is not debris. `<|end|>` ends in `|>`, so the two
    /// characters before the marker are `|>` and the look-back finds no wrapper — the
    /// property that keeps this family off every ordinary back-to-back envelope.
    func testNormalize_completeTokenBeforeMarker_isUntouched() {
        let input = #"<|call|>{"a":1}<|end|>"# + "\n" + #"<|call|>{"b":2}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    /// An unrepaired truncated sentinel immediately before a healthy one: the floor is the
    /// rebuild cursor, which sits just past the emitted `<|call|`, so the look-back cannot
    /// reach back into text already committed and re-eat it.
    func testNormalize_unrepairedTruncatedThenCanonical_onlyTheCanonicalSurvives() {
        let input = #"<|call|<|call|>{"name":"bash"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(input), input)
    }

    // MARK: - unrepairedSentinel: naming a near-miss the repair refuses

    /// The repair is deliberately conservative; the DIAGNOSIS must not be. A shape too
    /// mangled to repair is exactly the one the model most needs named — before this,
    /// `sawHarmonyMarker` stayed open and `handleNoToolCalls` fell through to whichever
    /// branch happened to match, which for a producing role is the artifact nudge.
    func testUnrepairedSentinel_debrisRun_namesTheTruncatedPrefix() {
        XCTAssertEqual(
            HarmonySentinelNormalizer.unrepairedSentinel(in: #"<|call|read_file{"path":"a"}"#),
            "<|call|")
    }

    /// Past `maxDebrisRun` the repair refuses — the diagnosis window is wider on purpose.
    func testUnrepairedSentinel_alienDebrisOverRepairCap_namesTheAlienPrefix() {
        let text = "<|tool_call>" + String(repeating: "x", count: 25) + #"{"name":"search"}"#
        XCTAssertEqual(HarmonySentinelNormalizer.unrepairedSentinel(in: text), "<|tool_call")
    }

    /// A shape this pass REPAIRS is not a near-miss: it dispatches, and naming it would
    /// nudge a model whose call worked.
    func testUnrepairedSentinel_repairableShapes_areNil() {
        let repairable = [
            #"<|call| {"name":"search"}"#,
            #"<|call|{"name":"search"}"#,
            #"<|tool_call>call|>{"name":"search"}"#,
        ]
        for text in repairable {
            XCTAssertNil(HarmonySentinelNormalizer.unrepairedSentinel(in: text), text)
        }
    }

    /// A healthy envelope is not a near-miss either.
    func testUnrepairedSentinel_canonicalEnvelope_isNil() {
        XCTAssertNil(HarmonySentinelNormalizer.unrepairedSentinel(
            in: #"<|call|>{"name":"read_file","arguments":{"path":"a"}}<|end|>"#))
        XCTAssertNil(HarmonySentinelNormalizer.unrepairedSentinel(
            in: #"<|call|>read_file{"path":"a"}<|end|>"#))
    }

    /// **The safety argument.** Whitespace in the run means the model was writing PROSE
    /// about the sentinel, so the same rule that keeps the repair off prose keeps the
    /// diagnosis off it — one rule, both places.
    func testUnrepairedSentinel_prose_isNil() {
        let prose = [
            "Write <|call| and then the JSON object on the same line.",
            "Emit your call as <|tool_call|> followed by the arguments.",
            #"Use <|call| when you want {"name":"x"} to run."#,
            "Let me call a tool.\n<|call|",
            "plain prose with no sentinel at all",
            "",
        ]
        for text in prose {
            XCTAssertNil(HarmonySentinelNormalizer.unrepairedSentinel(in: text), text)
        }
    }

    /// The diagnosis window is bounded too — a `{` far downstream is an unrelated brace.
    func testUnrepairedSentinel_payloadPastTheDiagnosticWindow_isNil() {
        let text = "<|tool_call>" + String(repeating: "x", count: 80) + #"{"name":"search"}"#
        XCTAssertNil(HarmonySentinelNormalizer.unrepairedSentinel(in: text))
    }

    /// It returns a literal from `prefixTable`, never a slice of the model's own bytes:
    /// a nudge is never retired, and quoting the looping output back into the prefix of
    /// every later request is the defect playbook R3.8.3 exists to forbid.
    func testUnrepairedSentinel_returnsOurOwnLiteral_notModelBytes() {
        let name = HarmonySentinelNormalizer.unrepairedSentinel(
            in: #"<|call|read_file{"path":"secret/path.swift"}"#)
        XCTAssertEqual(name, "<|call|")
        XCTAssertFalse(name?.contains("secret") ?? true)
    }
}
