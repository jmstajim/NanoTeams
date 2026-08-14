import XCTest

@testable import NanoTeams

/// The second defect from the `google/gemma-4-26b-a4b-qat` MeditationApp run
/// (`network_log.json`, 2026-08-13, 19:53:21): the model spliced its own training
/// sentinel into the taught marker and wrote
///
///     <|tool_call>call:edit_file{new_text: "…", old_text: "…", path: "…"}<|end|>
///
/// `HarmonySentinelNormalizer` matched it (debris run `>call:edit_file` is 15 chars,
/// whitespace-free, terminated by `{`) and replaced the WHOLE run with `<|call|>` —
/// taking `edit_file` with it. The payload then reached the parser with no tool name
/// and JSON5-style bare keys, resolved to nothing, and the call was dropped in
/// silence; the model got a nudge about braces for a call it could no longer see.
///
/// Both halves are recoverable and neither requires guessing: the identifier is in
/// hand on the line that discards it, and the parser already has a first-class
/// `<|call|>edit_file{…}` branch. Bare keys in key position are always invalid JSON,
/// so quoting them can only turn invalid into valid.
///
/// The negative pins are the point: an identifier that is NOT a real tool must never
/// be promoted (we recover names, we do not invent them), and a `key:` sequence
/// inside a STRING VALUE must never be touched — the production payload carries
/// `struct ContentView: View {` inside `new_text`.
final class MangledSentinelIdentityTests: XCTestCase {

    private func firstCall(_ text: String) -> StepToolCall? {
        HarmonyToolCallParser().extractAllToolCalls(from: text).first
    }

    // MARK: - D2a: the debris run carries the identity

    /// RED: revert the identifier-preserving branch in `HarmonySentinelNormalizer` →
    /// `edit_file` is erased with the debris and the payload resolves to no call.
    func testMangledSentinel_carryingToolName_preservesIt() {
        let normalized = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call:edit_file{"path":"f.swift"}<|end|>"#)
        XCTAssertTrue(
            normalized.contains("edit_file"),
            "the tool name lives in the debris run and must survive it: \(normalized)")
        XCTAssertEqual(firstCall(normalized)?.name, "edit_file")
    }

    func testMangledSentinel_differentTool_alsoPreserved() {
        let normalized = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call:read_file{"path":"f.swift"}<|end|>"#)
        XCTAssertEqual(firstCall(normalized)?.name, "read_file")
    }

    func testCleanAlienToken_followedByToolName_isPreserved() {
        let normalized = HarmonySentinelNormalizer.normalize(
            #"<|tool_call|>edit_file{"path":"f.swift"}<|end|>"#)
        XCTAssertEqual(firstCall(normalized)?.name, "edit_file")
    }

    /// We recover names; we do not invent them.
    /// RED: drop the `ToolNames.allNames` gate on the recovered identifier → a tool named
    /// `not_a_tool` is dispatched, i.e. the normalizer starts inventing names.
    func testDebrisIdentifier_thatIsNotARealTool_isNotPromoted() {
        let normalized = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call:not_a_tool{"path":"f.swift"}<|end|>"#)
        XCTAssertFalse(normalized.contains("not_a_tool"))
        XCTAssertTrue(normalized.hasPrefix("<|call|>{"))
    }

    func testDebrisIdentifier_runTogetherWithDebris_isNotPromoted() {
        // Trailing identifier is `call_edit_file`, which is not a tool.
        let normalized = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call_edit_file{"path":"f.swift"}<|end|>"#)
        XCTAssertTrue(normalized.hasPrefix("<|call|>{"))
    }

    /// Tool names are matched exactly — a shouted variant is not a tool.
    func testDebrisIdentifier_wrongCase_isNotPromoted() {
        let normalized = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call:EDIT_FILE{"path":"f.swift"}<|end|>"#)
        XCTAssertTrue(normalized.hasPrefix("<|call|>{"))
    }

    /// The two shapes the normalizer was originally written for must be untouched.
    /// RED: any change that makes the identifier branch fire for them → `call_multiple`
    /// is emitted as a tool name and the two original shapes stop resolving.
    func testOriginalShapes_stillNormalizeToABareMarker() {
        let spliced = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call|>{"name":"list_files","arguments":{}}<|end|>"#)
        XCTAssertTrue(spliced.hasPrefix("<|call|>{"), spliced)

        let multiple = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call_multiple{"contributions":[]}<|end|>"#)
        XCTAssertTrue(multiple.hasPrefix("<|call|>{"), multiple)
    }

    func testTwoOccurrences_eachFollowItsOwnRule() {
        let normalized = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call:read_file{"path":"a"}<|end|><|tool_call>call|>{"name":"git_status","arguments":{}}<|end|>"#)
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: normalized)
        XCTAssertEqual(calls.map(\.name), ["read_file", "git_status"])
    }

    // MARK: - D2b: bare keys

    /// RED: revert `repairUnquotedJSONKeys` → the JSON5 payload never parses, so the
    /// arguments reach the tool as one unparsed blob.
    func testBareKeys_areQuotedAndTheCallDispatches() {
        let normalized = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call:edit_file{new_text: "import UIKit", old_text: "import SwiftUI", path: "MeditationApp/ContentView.swift"}<|end|>"#)
        guard let call = firstCall(normalized) else { return XCTFail("no tool call parsed") }
        XCTAssertEqual(call.name, "edit_file")

        guard let args = JSONUtilities.parseJSONDictionary(call.argumentsJSON) else {
            return XCTFail("arguments did not become an object: \(call.argumentsJSON)")
        }
        XCTAssertEqual(args["path"] as? String, "MeditationApp/ContentView.swift")
        XCTAssertEqual(args["old_text"] as? String, "import SwiftUI")
        XCTAssertEqual(args["new_text"] as? String, "import UIKit")
    }

    func testBareKeys_partiallyQuotedInput_isRepaired() {
        let repaired = ToolCallParsingHelpers.repairUnquotedJSONKeys(
            #"{"new_text": "B", old_text: "A"}"#)
        XCTAssertEqual(
            JSONUtilities.parseJSONDictionary(repaired ?? "")?["old_text"] as? String, "A")
    }

    func testBareKeys_nested_areRepaired() {
        let repaired = ToolCallParsingHelpers.repairUnquotedJSONKeys(#"{args: {path: "x"}}"#)
        let outer = JSONUtilities.parseJSONDictionary(repaired ?? "")
        XCTAssertEqual((outer?["args"] as? [String: Any])?["path"] as? String, "x")
    }

    func testBareKeys_nonStringValue_isRepaired() {
        let repaired = ToolCallParsingHelpers.repairUnquotedJSONKeys(#"{depth: 2}"#)
        XCTAssertEqual(JSONUtilities.parseJSONDictionary(repaired ?? "")?["depth"] as? Int, 2)
    }

    /// The single most dangerous over-reach: a `key:` sequence inside a string VALUE.
    /// The production payload carried `struct ContentView: View {` and `let x: Int`
    /// shapes inside `new_text`, so a string-blind repair would corrupt the very edit
    /// the model was trying to make.
    /// RED: drop the `inString` tracking from `repairUnquotedJSONKeys` → `path:` inside
    /// the Swift source being edited is quoted as a key and the value is corrupted.
    func testKeyLikeTextInsideAStringValue_isNeverTouched() {
        let source = #"{"new_text": "let path: String\nstruct V: View {", "path": "f.swift"}"#
        XCTAssertNil(
            ToolCallParsingHelpers.repairUnquotedJSONKeys(source),
            "already-valid JSON must report nothing to repair")

        // …and end to end, through a real named call, the value survives byte-for-byte.
        let envelope = #"<|call|>{"name":"edit_file","arguments":{"new_text": "let path: String\nstruct V: View {","path":"f.swift"}}<|end|>"#
        let args = JSONUtilities.parseJSONDictionary(firstCall(envelope)?.argumentsJSON ?? "")
        XCTAssertEqual(args?["new_text"] as? String, "let path: String\nstruct V: View {")
        XCTAssertEqual(args?["path"] as? String, "f.swift")
    }

    /// Out of scope on purpose: quoting the key leaves a single-quoted VALUE, which is
    /// still not JSON. Declining beats guessing what the model meant.
    func testSingleQuotedValues_areNotGuessedAt() {
        let normalized = HarmonySentinelNormalizer.normalize(
            #"<|tool_call>call:read_file{path: 'f.swift'}<|end|>"#)
        let call = firstCall(normalized)
        // The call may resolve by name, but its arguments must never claim to be an
        // object built out of a shape we cannot actually read.
        if let call, let args = JSONUtilities.parseJSONDictionary(call.argumentsJSON) {
            XCTAssertNil(args["path"], "a single-quoted value must not be adopted as a string")
        }
    }

    /// RED: make `repairUnquotedJSONKeys` return its input instead of nil when nothing
    /// changed → callers read nil as "no defect of this kind", so a non-nil no-op bumps
    /// the repair-rate metric on every healthy call and hides the real defect rate.
    func testValidJSON_reportsNothingToRepair() {
        XCTAssertNil(ToolCallParsingHelpers.repairUnquotedJSONKeys(#"{"path":"f.swift"}"#))
        XCTAssertNil(ToolCallParsingHelpers.repairUnquotedJSONKeys(#"{"a":{"b":[1,2]}}"#))
    }

    /// A `,` inside an ARRAY does not open a key position.
    func testCommaInsideArray_doesNotStartAKey() {
        XCTAssertNil(ToolCallParsingHelpers.repairUnquotedJSONKeys(#"{"paths":["a","b"]}"#))
    }
}
