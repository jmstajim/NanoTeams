import XCTest

@testable import NanoTeams

/// The class of defect that broke the `google/gemma-4-26b-a4b-qat` MeditationApp run
/// (`network_log.json`, 2026-08-13, 19:53:20 and 19:53:28): **the model closed a
/// structural object before it had finished writing its members.**
///
/// The observed payload was
///
///     {"name":"edit_file","arguments":{"new_text":"…"},"old_text":"…"},"path":"…"}}
///
/// — `arguments` closes one brace early, so `old_text` becomes a SIBLING of the
/// wrapper, the top-level object then closes too, and `path` trails behind it
/// entirely. Two independent mechanisms then dropped data: the brace walker returns
/// at the first depth-0 close (so `path` never entered the dict at all), and
/// `ToolCallShapeRecognizer`'s `??` chain short-circuits on a non-empty `arguments`
/// (so `old_text`, which DID enter the dict, was discarded). `edit_file` dispatched
/// with `new_text` alone and answered `Missing required argument: path` — twice, to a
/// model that had sent all three arguments both times.
///
/// The fixtures below pin the CLASS, not that one byte string: the next miss will be
/// a brace in a neighbouring position. The negative pins matter at least as much —
/// a repair that reaches too far is a silent data corrupter, and fixture 6 (braces
/// inside a string value) is exactly the shape the real payload carried
/// (`struct ContentView: View {`).
///
/// Fixture discipline: every payload is a RAW string literal (`#"…"#`) so `\n` stays
/// the two-character JSON escape it is on the wire. In an interpolating `"""` literal
/// it would become a real newline INSIDE a JSON string, making the fixture invalid
/// JSON and the test vacuous. `assertParses` guards that in-place.
final class ToolCallArgumentSpillTests: XCTestCase {

    // MARK: - Helpers

    private func firstCall(_ envelope: String) -> StepToolCall? {
        HarmonyToolCallParser().extractAllToolCalls(from: envelope).first
    }

    private func arguments(
        _ envelope: String, file: StaticString = #filePath, line: UInt = #line
    ) -> [String: Any] {
        guard let call = firstCall(envelope) else {
            XCTFail("no tool call parsed", file: file, line: line)
            return [:]
        }
        guard let dict = JSONUtilities.parseJSONDictionary(call.argumentsJSON) else {
            XCTFail("argumentsJSON is not an object: \(call.argumentsJSON)", file: file, line: line)
            return [:]
        }
        return dict
    }

    /// Anti-vacuum guard for the fixtures that are supposed to be REPAIRABLE-but-broken:
    /// asserts the payload really is what the test claims about it.
    private func assertIsInvalidJSON(
        _ json: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let data = Data(json.utf8)
        XCTAssertNil(
            try? JSONSerialization.jsonObject(with: data),
            "fixture was supposed to be malformed but parses cleanly — the test would be vacuous",
            file: file, line: line)
    }

    private func assertIsValidJSON(
        _ json: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let data = Data(json.utf8)
        XCTAssertNotNil(
            try? JSONSerialization.jsonObject(with: data),
            "fixture was supposed to be well-formed but does not parse",
            file: file, line: line)
    }

    // MARK: - 1. The verbatim production payload

    /// RED: drop either half of the fix — the premature-closer repair in
    /// `ToolCallParsingHelpers`, or the sibling merge in `ToolCallShapeRecognizer` →
    /// `edit_file` dispatches with `new_text` alone and answers `Missing required
    /// argument: path`, which is the production defect verbatim. Each half fails a
    /// different way: without the repair `path` is never in the parsed dict, and
    /// without the merge `old_text`/`path` stay siblings of `arguments`.
    func testProductionPayload_argumentsClosedEarly_deliversAllThreeArguments() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text":"import SwiftUI\nimport UIKit\n\nstruct ContentView: View {"},"old_text":"import SwiftUI\n\nstruct ContentView: View {"},"path":"MeditationApp/ContentView.swift"}}<|end|>"#

        let call = firstCall(envelope)
        XCTAssertEqual(call?.name, "edit_file")

        let args = arguments(envelope)
        XCTAssertEqual(args["path"] as? String, "MeditationApp/ContentView.swift")
        XCTAssertEqual(args["old_text"] as? String, "import SwiftUI\n\nstruct ContentView: View {")
        XCTAssertEqual(
            args["new_text"] as? String,
            "import SwiftUI\nimport UIKit\n\nstruct ContentView: View {")
    }

    /// The run's own evidence that this was not a one-off: the identical shape came
    /// back eight seconds later (19:53:28) after the model had been told "Fix the
    /// arguments and retry".
    func testProductionPayload_secondOccurrence_alsoRecovers() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text":"import SwiftUI\nimport UIKit"},"old_text":"import SwiftUI"},"path":"MeditationApp/ContentView.swift"}}<|end|>"#
        let args = arguments(envelope)
        XCTAssertEqual(args["path"] as? String, "MeditationApp/ContentView.swift")
        XCTAssertEqual(args["old_text"] as? String, "import SwiftUI")
    }

    // MARK: - 2..8 Analogues of the same class

    /// Spill WITHOUT a trailing member: the top-level object stays balanced, so only
    /// the sibling merge is needed.
    /// RED: revert the merge in `ToolCallShapeRecognizer` → `path`/`old_text` stay
    /// siblings of `arguments` and never reach the tool.
    func testSpill_allSiblingsInsideBalancedTopObject_recovers() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text":"B"},"old_text":"A","path":"f.swift"}<|end|>"#
        assertIsValidJSON(
            #"{"name":"edit_file","arguments":{"new_text":"B"},"old_text":"A","path":"f.swift"}"#)

        let args = arguments(envelope)
        XCTAssertEqual(args["path"] as? String, "f.swift")
        XCTAssertEqual(args["old_text"] as? String, "A")
        XCTAssertEqual(args["new_text"] as? String, "B")
    }

    /// The TOP-LEVEL object closed early, so the last member trails past the span the
    /// brace walker returns — the half of the defect that loses `path` outright,
    /// because it never enters the parsed dict at all.
    /// RED: revert the premature-closer repair in `ToolCallParsingHelpers` → the walker
    /// stops at the early close and `path` is never in the parsed dict at all.
    func testSpill_topObjectClosedEarly_recoversTrailingMember() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text":"B","old_text":"A"}},"path":"f.swift"}<|end|>"#
        let args = arguments(envelope)
        XCTAssertEqual(args["path"] as? String, "f.swift")
        XCTAssertEqual(args["old_text"] as? String, "A")
    }

    func testSpill_emptyArgumentsWrapper_stillRecoversTrailingMember() {
        let envelope = #"<|call|>{"name":"read_file","arguments":{}},"path":"f.swift"}}<|end|>"#
        let args = arguments(envelope)
        XCTAssertEqual(args["path"] as? String, "f.swift")
    }

    /// A spilled value need not be a string.
    func testSpill_nonStringValue_recoversWithItsType() {
        let envelope = #"<|call|>{"name":"list_files","arguments":{"path":"."},"depth":2}}<|end|>"#
        let args = arguments(envelope)
        XCTAssertEqual(args["depth"] as? Int, 2)
        XCTAssertEqual(args["path"] as? String, ".")
    }

    /// The real payload's `new_text` ends in `struct ContentView: View {` — an
    /// unbalanced brace inside a string. The walker must keep treating it as string
    /// content, and the repair must not count it as structure.
    /// RED: make the repair scanner string-blind (drop its `inString` tracking) → the
    /// braces inside `new_text` are counted as structure and the span is cut mid-value.
    func testSpill_bracesInsideStringValues_doNotConfuseTheRepair() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text":"if x { y } else { z }"},"old_text":"guard let a = b else { return }","path":"f.swift"}}<|end|>"#
        let args = arguments(envelope)
        XCTAssertEqual(args["new_text"] as? String, "if x { y } else { z }")
        XCTAssertEqual(args["old_text"] as? String, "guard let a = b else { return }")
        XCTAssertEqual(args["path"] as? String, "f.swift")
    }

    func testSpill_whitespaceAndNewlineBeforeContinuation_recovers() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text":"B"},"old_text":"A"} ,   "path":"f.swift"}}<|end|>"#
        let args = arguments(envelope)
        XCTAssertEqual(args["path"] as? String, "f.swift")
    }

    /// The fix is generic, not a special case for `edit_file`.
    func testSpill_appliesToOtherTools() {
        let write = #"<|call|>{"name":"write_file","arguments":{"content":"hi"},"path":"n.txt"}}<|end|>"#
        XCTAssertEqual(arguments(write)["path"] as? String, "n.txt")

        let search = #"<|call|>{"name":"search","arguments":{"query":"UIDevice"},"file_glob":"*.swift"}}<|end|>"#
        XCTAssertEqual(arguments(search)["file_glob"] as? String, "*.swift")
    }

    // MARK: - 9..15 Negative pins: the repair must not reach further than the defect

    /// The single most important pin in the file. A well-formed call must come out
    /// byte-identical, with no repair note attached.
    /// RED: make the premature-closer repair unconditional, dropping the
    /// member-continuation precondition → every healthy call is rewritten and
    /// re-serialised, so the repair note fires on calls with no defect and the
    /// repair-rate metric stops meaning anything.
    func testHealthyCall_isUnchangedAndCarriesNoRepairNote() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"path":"f.swift","old_text":"A","new_text":"B"}}<|end|>"#
        guard let call = firstCall(envelope) else { return XCTFail("no tool call parsed") }

        XCTAssertEqual(call.name, "edit_file")
        XCTAssertEqual(call.argumentsJSON, #"{"new_text":"B","old_text":"A","path":"f.swift"}"#)
        XCTAssertNil(
            call.argumentRepairNote,
            "a healthy call must not be annotated — the note is the model's signal that it mis-emitted")
    }

    /// A nested value closing legitimately is not a premature close.
    /// RED: treat every depth-drop as premature instead of only depth-to-zero ones →
    /// `team_config`'s own closer is removed and the nested object swallows `note`.
    func testNestedValue_closesLegitimately_isNotTreatedAsPremature() {
        let envelope = #"<|call|>{"name":"create_team","arguments":{"team_config":{"name":"X"},"note":"y"}}<|end|>"#
        let args = arguments(envelope)
        XCTAssertEqual((args["team_config"] as? [String: Any])?["name"] as? String, "X")
        XCTAssertEqual(args["note"] as? String, "y")
    }

    /// A spilled key that collides with one already inside `arguments`: the wrapper
    /// wins, because it is the value the model put where the value belongs.
    /// RED: reverse the merge direction (`spilled` overwriting `arguments`) → `path`
    /// resolves to `outside.swift` and the model edits a file it did not name.
    func testCollidingKey_argumentsWrapperWins() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"path":"inside.swift"},"path":"outside.swift"}<|end|>"#
        XCTAssertEqual(arguments(envelope)["path"] as? String, "inside.swift")
    }

    /// Envelope metadata is not an argument.
    /// RED: drop the `reserved` filter from the sibling merge → `id`/`type`/`channel`
    /// are injected into the tool's arguments dict.
    func testReservedEnvelopeKeys_areNotPromotedIntoArguments() {
        let envelope = #"<|call|>{"name":"edit_file","id":"call_1","type":"function","arguments":{"path":"f.swift"},"channel":"commentary"}<|end|>"#
        let args = arguments(envelope)
        XCTAssertNil(args["id"])
        XCTAssertNil(args["type"])
        XCTAssertNil(args["channel"])
        XCTAssertEqual(args["path"] as? String, "f.swift")
    }

    /// Prose after a balanced object is not a continuation — the repair must decline.
    /// RED: trigger the repair on any non-empty remainder instead of member syntax →
    /// the prose is spliced into the object and the strict re-parse drops the call.
    func testProseAfterBalancedObject_doesNotTriggerRepair() {
        let envelope = #"<|call|>{"name":"read_file","arguments":{"path":"f.swift"}} now I will read it<|end|>"#
        guard let call = firstCall(envelope) else { return XCTFail("no tool call parsed") }
        XCTAssertEqual(call.argumentsJSON, #"{"path":"f.swift"}"#)
        XCTAssertNil(call.argumentRepairNote)
    }

    /// The repair must not swallow a following envelope in the same buffer. The first
    /// envelope here genuinely triggers the premature-closer repair, so the repair
    /// span has something to over-reach with.
    /// RED: let the repair span run to the end of the buffer instead of to `<|end|>` →
    /// the second envelope is swallowed and only one call comes back.
    func testSecondEnvelopeInSameBuffer_survivesTheRepair() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text":"B"}},"path":"a.swift"}<|end|><|call|>{"name":"read_file","arguments":{"path":"b.swift"}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.name, "edit_file")
        XCTAssertEqual(calls.last?.name, "read_file")
        XCTAssertEqual(
            JSONUtilities.parseJSONDictionary(calls.last?.argumentsJSON ?? "")?["path"] as? String,
            "b.swift")
    }

    /// Garbled beyond the salvage budget: decline rather than invent a shape.
    /// RED: remove the cap on how many premature closers may be removed → the garbled
    /// tail is spliced in and `b` is adopted as an argument the model never sent.
    func testOverCloseBeyondSalvageBudget_declinesRatherThanMangles() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"a":"1"}}}}},"b":"2"}}}}}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: envelope)
        // Either nothing is produced, or the untouched first-balanced-object result is —
        // what must never happen is a fabricated merge of the garbled tail.
        if let call = calls.first {
            let args = JSONUtilities.parseJSONDictionary(call.argumentsJSON) ?? [:]
            XCTAssertNil(args["b"], "the tail past a garbled over-close must not be adopted")
        }
    }

    /// The model closed early AND never closed the object at all. Removing the premature
    /// closer leaves the result under-closed, so the tail is padded on the same budget the
    /// EOF salvage uses — and the spilled member is recovered.
    /// RED: delete the `depth > 0` padding arm of `repairPrematureObjectClose` → the
    /// reconstruction fails to parse and `extra` is silently dropped.
    func testSpill_underClosedAfterRemovingThePrematureCloser_isPadded() {
        let envelope = #"<|call|>{"name":"read_file","arguments":{"path":"a"}},"extra":"x"<|end|>"#
        let args = arguments(envelope)
        XCTAssertEqual(args["path"] as? String, "a")
        XCTAssertEqual(args["extra"] as? String, "x")
    }

    /// A reconstruction that does not parse is worse than the truncated span it would
    /// replace, so the repair declines and the walker's original result stands.
    /// RED: return `out` from `repairPrematureObjectClose` without the strict re-parse →
    /// a broken object is handed to `parseToolCallFromJSON` and the whole call is lost.
    func testSpill_repairThatWouldNotParse_fallsBackToTheWalkerSpan() {
        let envelope = #"<|call|>{"name":"read_file","arguments":{"path":"a"}},"b":}<|end|>"#
        guard let call = firstCall(envelope) else {
            return XCTFail("the walker's own result must survive a declined repair")
        }
        XCTAssertEqual(call.name, "read_file")
        XCTAssertEqual(call.argumentsJSON, #"{"path":"a"}"#)
        XCTAssertNil(call.argumentRepairNote, "nothing was recovered, so nothing is claimed")
    }

    // MARK: - The repair note (D1c)

    /// RED: stop populating `argumentRepairNote` in the parser → the repair goes silent
    /// and the model re-emits the same broken shape for the rest of the run.
    func testRepairedCall_carriesANoteNamingTheRecoveredKeys() {
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text":"B"},"old_text":"A","path":"f.swift"}<|end|>"#
        guard let note = firstCall(envelope)?.argumentRepairNote else {
            return XCTFail("a repaired call must carry a note")
        }
        XCTAssertTrue(note.contains("old_text"), "note must name what was recovered: \(note)")
        XCTAssertTrue(note.contains("path"), "note must name what was recovered: \(note)")
        XCTAssertTrue(
            note.contains("arguments"),
            "note must name where the parameters belonged: \(note)")
    }

    // MARK: - The note reaching the wire

    /// The note is spliced into the tool RESULT, which is where the model already looks,
    /// rather than into a separate conversation turn that would grow the prompt prefix
    /// every time the defect recurs.
    /// RED: make `appendingRepairNote` return `content` unconditionally → the note never
    /// reaches the wire and `format_note` is absent from the envelope.
    func testRepairNote_isSplicedIntoTheResultEnvelopeAsJSON() {
        let spliced = LLMExecutionService.appendingRepairNote(
            "put every parameter inside `arguments`",
            to: #"{"ok":true,"path":"f.swift"}"#)

        guard let dict = JSONUtilities.parseJSONDictionary(spliced) else {
            return XCTFail("splicing must leave the envelope parseable: \(spliced)")
        }
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["path"] as? String, "f.swift")
        XCTAssertEqual(dict["format_note"] as? String, "put every parameter inside `arguments`")
    }

    /// RED: drop the empty-body separator guard → `{}` splices to `{,"format_note":…}`,
    /// which is not JSON, so the tool result stops parsing for the model.
    func testRepairNote_intoAnEmptyEnvelope_staysValidJSON() {
        let spliced = LLMExecutionService.appendingRepairNote("n", to: "{}")
        XCTAssertNotNil(
            JSONUtilities.parseJSONDictionary(spliced), "must not emit `{,…}`: \(spliced)")
    }

    /// A non-JSON tool result still gets the note, just not as a member.
    func testRepairNote_ontoNonJSONResult_fallsBackToAPlainLine() {
        let spliced = LLMExecutionService.appendingRepairNote("n", to: "plain text output")
        XCTAssertTrue(spliced.hasPrefix("plain text output"))
        XCTAssertTrue(spliced.contains("format_note"))
    }

    func testNoRepairNote_leavesTheEnvelopeByteIdentical() {
        let envelope = #"{"ok":true}"#
        XCTAssertEqual(LLMExecutionService.appendingRepairNote(nil, to: envelope), envelope)
        XCTAssertEqual(LLMExecutionService.appendingRepairNote("", to: envelope), envelope)
    }

    // MARK: - Fixture self-checks

    /// The production payload really is the malformation this file claims. Without
    /// this the whole file could be pinning a well-formed string.
    func testFixtures_areActuallyMalformed() {
        assertIsInvalidJSON(
            #"{"name":"edit_file","arguments":{"new_text":"A"},"old_text":"B"},"path":"C"}}"#)
        assertIsValidJSON(#"{"name":"edit_file","arguments":{"path":"f.swift"}}"#)
    }
}
