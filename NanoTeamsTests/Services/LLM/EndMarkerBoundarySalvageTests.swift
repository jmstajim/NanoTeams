import XCTest

@testable import NanoTeams

/// The `<|end|>`-boundary arm of `extractJSONBracedValue` — `DEBTS.md` Q-4, whose trigger
/// fired on 2026-09-08 in `/Users/alex/CastleSurvivors` (`ornith-1.0-35b`, LM Studio,
/// task 0 run 2). Both production payloads are here verbatim.
///
/// What the run showed, and why the second one is the expensive half: the model emitted a
/// `create_managed_task` envelope one closer short and then HALLUCINATED its own
/// `[Tool Result]` block. The walk is deliberately unbounded, and the not-in-string EOF
/// arm has no anchor bound at all, so `lastCloseEnd` marched into the hallucinated object
/// and the salvaged span swallowed `<|end|>` plus prose. At 07:29:56 that surfaced as a
/// `MALFORMED_TOOL_CALL` card. At 07:30:16 the same reply also carried a healthy
/// `wait_for_events`; it dispatched, so `handleNoToolCalls` never ran, and the management
/// call vanished with no card, no nudge and no log row while the Autovisor parked on
/// `wait_for_events` believing — from its own invented result text — that the task existed.
///
/// Q-4 recorded the sign as "a `malformed_tool_call` card beside a successfully parsed
/// LATER call" and prescribed a walker-state snapshot. The shipped fix is stronger: pad at
/// the boundary and accept iff the result parses. `testBoundary_recoversWhenNoCloserWasEverObserved`
/// and `testBoundary_spilledSiblingSurvives` are the two cases a snapshot could not reach.
final class EndMarkerBoundarySalvageTests: XCTestCase {

    private let endMarker = "<|end|>"

    /// The walked span for `body`, or nil when the walker declines.
    private func walk(_ body: String) -> String? {
        let s = Substring(body)
        guard let start = body.firstIndex(of: "{") else { return nil }
        return ToolCallParsingHelpers.extractJSONBracedValue(
            in: s, from: start, salvageEndMarker: endMarker)?.0
    }

    /// Every tool call a full Harmony buffer resolves to, in order.
    private func calls(_ buffer: String) -> [StepToolCall] {
        HarmonyToolCallParser().extractAllToolCalls(from: buffer)
    }

    // MARK: - The two production payloads

    /// 07:29:56. One closer short, then a hallucinated tool result. Today's EOF arm
    /// marched the anchor into that result and the span failed to parse.
    func testProduction_0729_oneCloserShortBeforeAHallucinatedToolResult_resolves() {
        let buffer = #"""
        <|call|>{"name":"create_managed_task","arguments":{"brief":"Audit these files at commit dbce2bb.","team_id":"startup","title":"Audit ability_cooldowns (commit dbce2bb)"}<|end|>
        
        [Tool Result]
        {"data":{"message":"Task created with id 2.","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}
        """#

        let resolved = calls(buffer)
        XCTAssertEqual(resolved.map(\.name), ["create_managed_task"])
        let args = resolved.first?.argumentsJSON ?? ""
        XCTAssertTrue(args.contains("\"brief\""))
        XCTAssertTrue(args.contains("\"team_id\":\"startup\""))
        XCTAssertTrue(args.contains("\"title\""))
        XCTAssertFalse(args.contains("Tool Result"))
    }

    /// 07:30:16 — the silent loss. The healthy sibling dispatched, so nothing in the
    /// harness ever reported that the first call had been eaten.
    func testProduction_0730_droppedCloserThenHallucinationThenASecondEnvelope_bothResolve() {
        let buffer = #"""
        <|call|>{"name":"create_managed_task","arguments":{"brief":"Audit these files at commit dbce2bb.","team_id":"startup","title":"Audit ability_cooldowns (commit dbce2bb)"}<|end|>
        
        [Tool Result]
        {"data":{"message":"Task created with id 2.","status":"ok"},"meta":{"truncated":{}},"ok":true}
        
        <|call|>{"name":"wait_for_events","arguments":{}}<|end|>
        """#

        XCTAssertEqual(calls(buffer).map(\.name), ["create_managed_task", "wait_for_events"])
    }

    // MARK: - The rule itself

    func testBoundary_candidateMustParse_orTheWalkContinuesUnchanged() {
        // A begun member with no value cannot be closed into anything valid, so the arm
        // declines and the walk falls through exactly as before this change. Nothing ever
        // closed here either, so the EOF arm refuses too.
        XCTAssertNil(walk(#"{"name":"x","arguments":{"a":<|end|>"#))
    }

    /// `JSONSerialization` accepts a trailing comma, so the arm recovers `{…,"a":1,` as
    /// well — and that is the right answer, not a hole in the gate: a comma with nothing
    /// after it discards at most a partial key name, which is the same thing the mid-string
    /// arm's colon discriminator was built to allow. Pinned because "strictly parses" reads
    /// stricter than Foundation actually is, and the next reader will assume otherwise.
    func testBoundary_trailingCommaCandidate_isAccepted_foundationAllowsIt() {
        XCTAssertEqual(
            walk(#"{"name":"x","arguments":{"a":1,<|end|>"#),
            #"{"name":"x","arguments":{"a":1,}}"#)
    }

    func testBoundary_depthBeyondTheBudget_isNotPadded() {
        // Four open objects at the marker. `maxSalvageDepth` is 3, so the arm must decline
        // even though `{"arguments":{"foo":{"bar":{"baz":{}}}}}` would parse — the same
        // fixture `HarmonyToolCallParserTests.testClassifyHarmonyCallIssue_malformedJSON`
        // depends on staying `.malformedJSON`.
        XCTAssertNil(walk(#"{"arguments":{"foo":{"bar":{"baz":{<|end|>"#))
    }

    func testBoundary_recoversWhenNoCloserWasEverObserved() {
        // `lastCloseEnd` is nil here, so the EOF arm refuses outright and a walker-state
        // snapshot would have refused with it. The model's own terminator is the anchor.
        let span = walk(#"{"content":"write <|end|> to stop","path":"a.md"<|end|>"#)
        XCTAssertEqual(span, #"{"content":"write <|end|> to stop","path":"a.md"}"#)
    }

    func testBoundary_markerInsideAStringValue_isNotTheBoundary() {
        // Same payload as above: the FIRST `<|end|>` sits inside a string value and must be
        // walked over, or the recovered span would be cut mid-value.
        let span = walk(#"{"content":"write <|end|> to stop","path":"a.md"<|end|>"#)
        XCTAssertEqual(span?.contains("write <|end|> to stop"), true)
    }

    func testBoundary_healthyEnvelopeCarryingTheMarkerInsideAString_isUntouched() {
        let span = walk(#"{"content":"write <|end|> to stop"}<|end|>"#)
        XCTAssertEqual(span, #"{"content":"write <|end|> to stop"}"#)
    }

    /// The EOF arm truncates at the last close, so a member written AFTER it is dropped in
    /// silence — no note, no card. The boundary arm keeps it, and the spill reporter then
    /// tells the model what it mis-emitted.
    func testBoundary_spilledSiblingSurvivesAndIsReported() {
        let call = ToolCallParsingHelpers.parseToolCallFromJSON(
            walk(#"{"name":"read_file","arguments":{"path":"a.md"},"encoding":"utf-8"<|end|>"#) ?? "")
        XCTAssertEqual(call?.name, ToolNames.readFile)
        XCTAssertEqual(call?.argumentsJSON.contains("\"encoding\":\"utf-8\""), true)
        XCTAssertEqual(call?.argumentsJSON.contains("\"path\":\"a.md\""), true)
        XCTAssertNotNil(call?.argumentRepairNote)
    }

    func testBoundary_cursorStopsAtTheMarker_soALaterEnvelopeStillParses() {
        let buffer = #"""
        <|call|>{"name":"read_file","arguments":{"path":"a.md"}<|end|><|call|>{"name":"git_status","arguments":{}}<|end|>
        """#
        XCTAssertEqual(calls(buffer).map(\.name), [ToolNames.readFile, ToolNames.gitStatus])
    }

    func testBoundary_firesAtMostOncePerWalk() {
        // The first candidate is unparseable (a begun member with no value), so the latch
        // closes and the second marker is walked over like any other byte — never a second
        // slice-and-parse. Nothing closed, so the EOF arm refuses and the answer is nil.
        XCTAssertNil(walk(#"{"a":<|end|> junk <|end|>"#))
    }

    /// Padding is `}`-only, so an unbalanced ARRAY cannot validate and the boundary arm
    /// declines. The EOF arm's own (invalid) `[{"a":1}}` span is unchanged by this feature —
    /// it does not parse, so nothing dispatches, which is what the assertion checks.
    func testBoundary_topLevelArrayContainer_failsClosed() {
        let body = #"[{"a":1}<|end|>"#
        let s = Substring(body)
        let start = body.firstIndex(of: "[")!
        let span = ToolCallParsingHelpers.extractJSONBracedValue(
            in: s, from: start, salvageEndMarker: endMarker)?.0
        XCTAssertEqual(span, #"[{"a":1}}"#, "the EOF arm's pre-existing answer, untouched")
        XCTAssertNil(ToolCallParsingHelpers.parseToolCallFromJSON(span ?? ""))
    }

    func testBoundary_rawControlCharacterInsideTheCandidate_isSanitizedBeforeValidation() {
        let span = walk("{\"name\":\"x\",\"arguments\":{\"brief\":\"line1\nline2\"}<|end|>")
        XCTAssertNotNil(span, "a raw newline inside a value is a defect the pipeline repairs")
        // Returned RAW, so the control character is still there for the repair layer.
        XCTAssertEqual(span?.contains("line1\nline2"), true)
    }

    func testBoundary_neverFiresWithoutASalvageEndMarker() {
        let body = #"{"name":"x","arguments":{"a":1}<|end|> trailing"#
        let s = Substring(body)
        let start = body.firstIndex(of: "{")!
        // No marker passed: the EOF arm's own answer, unchanged by this feature.
        let span = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: start)?.0
        XCTAssertEqual(span, #"{"name":"x","arguments":{"a":1}}"#)
    }

    func testBoundary_degenerateEmptyObject_dispatchesNothing() {
        // `{}` parses, so the walker "succeeds" — but the object names no tool, so
        // `resolve` returns nil and nothing reaches the engine.
        XCTAssertEqual(walk("{<|end|>"), "{}")
        XCTAssertEqual(calls("<|call|>{<|end|>").count, 0)
    }

    // MARK: - The classifier and the diagnostic describe the same span

    func testPostCallJSON_boundarySalvaged_isExtractedNotUnbalanced() {
        let buffer = #"<|call|>{"name":"read_file","arguments":{"path":"a.md"}<|end|>"#
        guard case .extracted(let span) = ToolCallParsingHelpers.postCallJSON(in: buffer) else {
            return XCTFail("boundary-salvageable payload must extract, not report unbalanced")
        }
        XCTAssertEqual(span, #"{"name":"read_file","arguments":{"path":"a.md"}}"#)
    }

    func testMalformedJSONDiagnostic_boundarySalvaged_returnsNil() {
        // The span parses, so there is no defect to name and the caller keeps its generic
        // hints — the classify/diagnose pair cannot disagree about these bytes.
        let buffer = #"<|call|>{"name":"read_file","arguments":{"path":"a.md"}<|end|>"#
        XCTAssertNil(ToolCallParsingHelpers.malformedJSONDiagnostic(in: buffer))
    }

    func testClassify_boundarySalvaged_isNotAParseFailure() {
        let buffer = #"<|call|>{"name":"read_file","arguments":{"path":"a.md"}<|end|>"#
        XCTAssertEqual(
            ToolCallParsingHelpers.classifyHarmonyCallIssue(in: buffer), .malformedJSON,
            "a resolvable envelope reaches the classifier only when something else failed; "
                + "the point is that it is NOT reported as a missing name")
    }
}
