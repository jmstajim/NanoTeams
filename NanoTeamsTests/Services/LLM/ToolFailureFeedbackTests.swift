import XCTest

@testable import NanoTeams

/// The feedback loop the `gemma-4-26b-a4b-qat` MeditationApp run never got
/// (`network_log.json`, 2026-08-13). Three surfaces, all of them things the model
/// reads and none of which told it enough to recover:
///
/// - **D3** the assistant turn for an unresolved Harmony envelope was `content: nil`,
///   so the wire showed a bare `[Assistant]` and the model was scolded for JSON it
///   could no longer see. It spent a 19-second reasoning block insisting it had sent
///   `path` — correctly.
/// - **D3b** the malformed-JSON nudge shipped the literal `TOOL_NAME` while its two
///   sibling arms substitute a real tool the role holds.
/// - **D4** `INVALID_ARGS` guidance named only the first missing key, because handlers
///   throw on the first one they read. Three missing arguments cost three round-trips.
/// - **D6/D7** tag identity and the edit envelope's disclosures.
final class ToolFailureFeedbackTests: XCTestCase {

    // MARK: - D3: the model must see its own turn

    /// RED: return nil from `unresolvedEnvelopeAnchor` for a non-empty buffer → the wire
    /// shows a bare `[Assistant]` and the model cannot see the JSON it is asked to fix.
    func testUnresolvedEnvelope_isReplayedVerbatimAsTheAssistantTurn() {
        let buffer = #"<|call|>{"name":"edit_file","arguments":{new_text: "x"}}<|end|>"#
        let anchor = LLMExecutionService.unresolvedEnvelopeAnchor(buffer)
        XCTAssertEqual(anchor, buffer)
    }

    /// A runaway buffer must not become a permanent prefix on every later request.
    func testUnresolvedEnvelope_overTheCap_isTruncatedNotDropped() {
        let buffer = String(repeating: "x", count: 5000)
        guard let anchor = LLMExecutionService.unresolvedEnvelopeAnchor(buffer) else {
            return XCTFail("an oversized buffer must still be shown, not dropped")
        }
        XCTAssertLessThan(anchor.count, buffer.count)
        XCTAssertTrue(anchor.hasSuffix("[truncated]"))
        XCTAssertTrue(anchor.hasPrefix("xxx"))
    }

    /// Nothing emitted stays nothing — the existing "the turn happened but said
    /// nothing" anchor. Fabricating content the model never wrote would be a different
    /// lie from the one this fixes.
    /// RED: return `""` instead of nil for an empty buffer → an empty string is content
    /// the model never emitted, replacing the honest nil anchor.
    func testEmptyBuffer_stillYieldsTheNilAnchor() {
        XCTAssertNil(LLMExecutionService.unresolvedEnvelopeAnchor(""))
        XCTAssertNil(LLMExecutionService.unresolvedEnvelopeAnchor("   \n  "))
    }

    // MARK: - D4: the guidance names the whole contract

    /// RED: revert `requiredArgumentsHint` to "" → the guidance names only the first
    /// missing key, so three missing arguments cost three round-trips.
    func testInvalidArgs_namesEveryRequiredParameterAndWhatArrived() {
        let hint = ToolErrorNotePolicy.requiredArgumentsHint(
            toolName: ToolNames.editFile, argumentsJSON: #"{"new_text":"B"}"#)

        XCTAssertTrue(hint.contains("path"), hint)
        XCTAssertTrue(hint.contains("old_text"), hint)
        XCTAssertTrue(hint.contains("new_text"), hint)
        XCTAssertTrue(
            hint.contains("carried"),
            "the model must be told which of its arguments arrived: \(hint)")
    }

    func testInvalidArgs_withNoArgumentsAtAll_saysSo() {
        let hint = ToolErrorNotePolicy.requiredArgumentsHint(
            toolName: ToolNames.editFile, argumentsJSON: "")
        XCTAssertTrue(hint.contains("no arguments"), hint)
    }

    /// A tool with no required parameters must not get an empty "requires: ." clause.
    /// RED: drop the `required.isEmpty` guard → an argument-less tool gets the dangling
    /// clause `requires: .` appended to every failure.
    func testToolWithNoRequiredParameters_getsNoHint() {
        XCTAssertEqual(
            ToolErrorNotePolicy.requiredArgumentsHint(
                toolName: ToolNames.gitStatus, argumentsJSON: "{}"),
            "")
    }

    /// An unknown tool name (a hallucinated one) has no schema to quote.
    func testUnknownTool_getsNoHint() {
        XCTAssertEqual(
            ToolErrorNotePolicy.requiredArgumentsHint(
                toolName: "no_such_tool", argumentsJSON: "{}"),
            "")
    }

    // MARK: - D6: the legend must not consume the first tag of every type

    /// The system prompt carries `<§R1§> read, <§E1§> edit, …` as an ILLUSTRATION.
    /// Counting it made the first real tag of every type `#2`, so the prompt taught a
    /// handle the model could never be given.
    /// RED: drop the `message.role != .system` filter in `seedTagCounters` → the legend
    /// seeds every counter to 1 and the first minted tag of each type becomes `#2`.
    func testSystemPromptTagLegend_doesNotConsumeTheFirstTag() {
        let store = MemoryTagStore(workFolderRoot: URL(fileURLWithPath: "/tmp"))
        store.seedTagCounters(replaying: [
            ChatMessage(
                role: .system,
                content: "Tool results may carry a tag: <§R1§> read, <§E1§> edit, <§B1§> build."),
            ChatMessage(role: .user, content: "go"),
        ])
        XCTAssertEqual(store.nextTag(.read), "<§R1§>")
        XCTAssertEqual(store.nextTag(.edit), "<§E1§>")
    }

    /// The behaviour the seed actually exists for is untouched: a replayed transcript
    /// from a previous entry of the same step must not have its handles re-minted.
    /// RED: any change that makes the seed skip non-system messages too → a re-entered
    /// step re-mints `<§R2§>` next to a replayed one holding different content.
    func testReplayedTranscriptTags_stillAdvanceTheCounters() {
        let store = MemoryTagStore(workFolderRoot: URL(fileURLWithPath: "/tmp"))
        store.seedTagCounters(replaying: [
            ChatMessage(role: .system, content: "legend <§R1§> read"),
            ChatMessage(role: .tool, content: #"{"tag":"<§R2§>","path":"a.swift"}"#),
        ])
        XCTAssertEqual(store.nextTag(.read), "<§R3§>")
    }

    // MARK: - D7: the edit envelope keeps the handler's disclosures

    /// `EditFileTool` emits `matched_ignoring_trailing_whitespace` only when the fuzzy
    /// fallback fired, "so the model knows the file's bytes differed from its anchor".
    /// Rebuilding the tagged envelope from scratch threw that away and presented a
    /// fuzzy match as a clean success.
    /// RED: revert `processEdit` to the three-field envelope → a fuzzy-matched edit is
    /// presented to the model as a clean exact success.
    func testFuzzyMatchedEdit_disclosesThatTheAnchorDidNotMatchExactly() {
        let store = MemoryTagStore(workFolderRoot: URL(fileURLWithPath: "/tmp"))
        let result = ToolExecutionResult(
            toolName: ToolNames.editFile,
            argumentsJSON: #"{"path":"f.swift"}"#,
            outputJSON:
            #"{"ok":true,"data":{"path":"f.swift","replacements_made":3,"matched_ignoring_trailing_whitespace":true}}"#,
            isError: false)

        guard case .tagged(let content, _) = store.processEdit(result) else {
            return XCTFail("a successful edit must be tagged")
        }
        let dict = JSONUtilities.parseJSONDictionary(content)
        XCTAssertEqual(dict?["matched_ignoring_trailing_whitespace"] as? Bool, true)
        XCTAssertEqual(dict?["replacements_made"] as? Int, 3)
        XCTAssertEqual(dict?["path"] as? String, "f.swift")
        XCTAssertEqual(dict?["status"] as? String, "success")
    }

    /// An exact match discloses nothing extra — the flag is a signal, not a field that
    /// should always be present.
    func testExactMatchedEdit_omitsTheFuzzyFlagButKeepsTheCount() {
        let store = MemoryTagStore(workFolderRoot: URL(fileURLWithPath: "/tmp"))
        let result = ToolExecutionResult(
            toolName: ToolNames.editFile,
            argumentsJSON: #"{"path":"f.swift"}"#,
            outputJSON: #"{"ok":true,"data":{"path":"f.swift","replacements_made":1}}"#,
            isError: false)

        guard case .tagged(let content, _) = store.processEdit(result) else {
            return XCTFail("a successful edit must be tagged")
        }
        let dict = JSONUtilities.parseJSONDictionary(content)
        XCTAssertNil(dict?["matched_ignoring_trailing_whitespace"])
        XCTAssertEqual(dict?["replacements_made"] as? Int, 1)
    }

    /// A failed edit stays an untagged passthrough, and does not burn a tag number.
    func testFailedEdit_isPassthroughAndDoesNotConsumeATag() {
        let store = MemoryTagStore(workFolderRoot: URL(fileURLWithPath: "/tmp"))
        let failure = ToolExecutionResult(
            toolName: ToolNames.editFile,
            argumentsJSON: #"{"path":"f.swift"}"#,
            outputJSON: #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"nope"}}"#,
            isError: true)

        guard case .passthrough = store.processEdit(failure) else {
            return XCTFail("a failed edit must not be tagged")
        }
        XCTAssertEqual(store.nextTag(.edit), "<§E1§>")
    }
}
