import XCTest
@testable import NanoTeams

/// The `{}{"name":…}` envelope — an empty object glued before the call — observed sixteen
/// times in ONE step from `ornith-1.5:35b` (MeditationApp task 94, 2026-09-13, prompt-taught).
/// Until then the walker returned the empty object, the parser found no `name`, and the
/// missing-name nudge described a defect the envelope did not have — so the model re-emitted
/// the shape every time. Now the call after the empty run dispatches, and the model hears once
/// what was dropped (REC.5).
final class LeadingEmptyObjectEnvelopeTests: XCTestCase {

    private let live = "<|call|>{}{\"name\":\"read_file\",\"arguments\":{\"path\":\"MeditationApp/TabRouter.swift\"}}<|end|>"

    // MARK: - Dispatch

    func testLiveEnvelope_dispatchesTheCallAfterTheEmptyObject_withANote() {
        let calls = CallMarkerStrategy().parse(from: live)
        XCTAssertEqual(calls.map(\.name), ["read_file"])
        XCTAssertEqual(calls.first?.argumentsJSON, "{\"path\":\"MeditationApp/TabRouter.swift\"}")
        XCTAssertEqual(calls.first?.argumentRepairNote, ToolCallParsingHelpers.leadingEmptyObjectsNote(count: 1))
    }

    func testSeveralEmptyObjectsWithWhitespace_areAllSkipped_andCounted() {
        let text = "<|call|>{ } {}\n\t{}{\"name\":\"git_status\",\"arguments\":{}}<|end|>"
        let calls = CallMarkerStrategy().parse(from: text)
        XCTAssertEqual(calls.map(\.name), ["git_status"])
        XCTAssertEqual(calls.first?.argumentRepairNote, ToolCallParsingHelpers.leadingEmptyObjectsNote(count: 3))
        XCTAssertEqual(calls.first?.argumentRepairNote?.hasPrefix("3 empty `{}` objects stood"), true)
    }

    func testTwoEnvelopes_eachWithItsOwnEmptyRun_bothDispatch() {
        let text = "<|call|>{}{\"name\":\"read_file\",\"arguments\":{\"path\":\"a\"}}<|end|>\n"
            + "<|call|>{}{}{\"name\":\"read_file\",\"arguments\":{\"path\":\"b\"}}<|end|>"
        let calls = CallMarkerStrategy().parse(from: text)
        XCTAssertEqual(calls.map(\.argumentsJSON), ["{\"path\":\"a\"}", "{\"path\":\"b\"}"])
        XCTAssertEqual(calls.first?.argumentRepairNote?.hasPrefix("an empty `{}` object stood"), true)
        XCTAssertEqual(calls.last?.argumentRepairNote?.hasPrefix("2 empty `{}` objects stood"), true)
    }

    /// The skip is at CALL level only: `"arguments":{}` is a legitimate empty object.
    func testEmptyArgumentsObject_isUntouched_andCarriesNoNote() {
        let calls = CallMarkerStrategy().parse(from: "<|call|>{\"name\":\"git_status\",\"arguments\":{}}<|end|>")
        XCTAssertEqual(calls.map(\.name), ["git_status"])
        XCTAssertNil(calls.first?.argumentRepairNote)
    }

    // MARK: - What is NOT skipped

    /// `{}` with nothing after it is still the (name-less) call, for dispatch and diagnosis alike.
    func testEmptyObjectAlone_isStillTheNamelessCall() {
        let text = "<|call|>{}<|end|>"
        XCTAssertTrue(CallMarkerStrategy().parse(from: text).isEmpty)
        guard case .missingToolName = ToolCallParsingHelpers.classifyHarmonyCallIssue(in: text) else {
            return XCTFail("`{}` alone is a call without a name, not a leading empty object")
        }
    }

    /// The `{` after `<|end|>` belongs to the next envelope or to prose, never to this call.
    func testEmptyObjectBeforeTheEndMarker_isNotSkippedAcrossIt() {
        let text = "<|call|>{}<|end|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a\"}}"
        let sub = Substring(text)
        let brace = sub.index(sub.startIndex, offsetBy: "<|call|>".count)
        let limit = sub.range(of: "<|end|>")!.lowerBound
        let (start, skipped) = ToolCallParsingHelpers.callObjectStart(in: sub, from: brace, limit: limit)
        XCTAssertEqual(start, brace)
        XCTAssertEqual(skipped, 0)
        XCTAssertTrue(CallMarkerStrategy().parse(from: text).isEmpty)
    }

    /// `{},"name":…` is the premature-close shape `repairPrematureObjectClose` owns — the empty
    /// object is followed by a member list, not by another object, so nothing is skipped.
    func testEmptyObjectFollowedByAMemberList_isNotSkipped() {
        let s = Substring("{},\"name\":\"read_file\",\"arguments\":{\"path\":\"a\"}}")
        let r = ToolCallParsingHelpers.callObjectStart(in: s, from: s.startIndex, limit: s.endIndex)
        XCTAssertEqual(r.start, s.startIndex)
        XCTAssertEqual(r.skippedEmptyObjects, 0)
    }

    func testEmptyObjectsThenNotAnObject_areNotSkipped() {
        for tail in ["\"x\"", "5", "", "  ", "}"] {
            let s = Substring("{} " + tail)
            let r = ToolCallParsingHelpers.callObjectStart(in: s, from: s.startIndex, limit: s.endIndex)
            XCTAssertEqual(r.start, s.startIndex, "tail: \(tail)")
            XCTAssertEqual(r.skippedEmptyObjects, 0, "tail: \(tail)")
        }
    }

    func testCallObjectStart_withoutABrace_orWithANonEmptyFirstObject_returnsTheIndexUnchanged() {
        for text in ["{\"name\":\"x\"}{}", "abc", "", "{\"a\":1}"] {
            let s = Substring(text)
            let r = ToolCallParsingHelpers.callObjectStart(in: s, from: s.startIndex, limit: s.endIndex)
            XCTAssertEqual(r.start, s.startIndex, text)
            XCTAssertEqual(r.skippedEmptyObjects, 0, text)
        }
    }

    // MARK: - Diagnosis reads the bytes dispatch accepted

    func testPostCallJSON_extractsTheCallObject_notTheEmptyOne() {
        guard case .extracted(let json) = ToolCallParsingHelpers.postCallJSON(in: live) else {
            return XCTFail("expected .extracted")
        }
        XCTAssertEqual(json, "{\"name\":\"read_file\",\"arguments\":{\"path\":\"MeditationApp/TabRouter.swift\"}}")
    }

    // MARK: - The note

    func testNote_isNilForZeroOrLess_singularForOne_countsAbove() {
        XCTAssertNil(ToolCallParsingHelpers.leadingEmptyObjectsNote(count: 0))
        XCTAssertNil(ToolCallParsingHelpers.leadingEmptyObjectsNote(count: -1))
        XCTAssertEqual(
            ToolCallParsingHelpers.leadingEmptyObjectsNote(count: 1),
            "an empty `{}` object stood before your call object and was dropped; open the call object directly after `<|call|>`")
        XCTAssertEqual(ToolCallParsingHelpers.leadingEmptyObjectsNote(count: 2)?.hasPrefix("2 empty `{}` objects stood"), true)
    }
}
