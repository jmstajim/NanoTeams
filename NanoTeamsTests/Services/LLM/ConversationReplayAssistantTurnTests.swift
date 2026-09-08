import XCTest

@testable import NanoTeams

/// The legacy replay path — `wireTranscript` empty, so the wire is rebuilt from the display
/// record — used to DROP every envelope-only assistant turn, because `LLMMessage` has no
/// `toolCalls` field and the streaming path truncates such a turn's content at the Harmony
/// marker.
///
/// Measured on a production wire (`ornith-1.0-35b`, `/Users/alex/CastleSurvivors`, task 1
/// run 0, 2026-09-08): the planning-phase requests carried 21 `[Tool Result]` blocks and
/// ZERO `[Assistant]` turns, while a `.missingToolName` nudge told the model to keep the
/// arguments of an attempt the wire no longer held, and the `.malformedJSON` nudge claimed
/// that attempt was "quoted verbatim in that turn". The model's only in-context example of a
/// tool call was the `[CALL] name` / `Arguments: {…}` composite — two SIBLING labels, which
/// is the shape it then emitted (`{"arguments":{…,"name":"read_file"}}`,
/// `NestedToolNameEnvelopeTests`).
final class ConversationReplayAssistantTurnTests: XCTestCase {

    private func toolTurn(_ name: String, _ args: String, _ result: String = #"{"ok":true}"#)
        -> LLMMessage
    {
        LLMMessage(
            role: .tool,
            content: TaskMutationService.toolResultComposite(
                toolName: name, argumentsJSON: args, resultJSON: result))
    }

    func testEnvelopeOnlyAssistantTurn_isRematerializedNotDropped() {
        let record: [LLMMessage] = [
            LLMMessage(role: .user, content: "Audit the file."),
            LLMMessage(role: .assistant, content: ""),
            toolTurn(ToolNames.readFile, #"{"path":"a.gd"}"#),
        ]
        let wire = ConversationReplay.rebuildFromDisplayRecord(record)
        XCTAssertEqual(wire.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(wire[1].toolCalls?.map(\.name), [ToolNames.readFile])
        XCTAssertEqual(wire[1].toolCalls?.first?.argumentsJSON, #"{"path":"a.gd"}"#)
    }

    /// The re-materialized turn must render as the same bytes the live path writes, or the
    /// replay teaches a second call syntax.
    func testRematerializedTurn_rendersTheCanonicalEnvelope() {
        let wire = ConversationReplay.rebuildFromDisplayRecord([
            LLMMessage(role: .assistant, content: ""),
            toolTurn(ToolNames.readFile, #"{"path":"a.gd"}"#),
        ])
        XCTAssertEqual(
            HarmonyToolCallEnvelope.appendedWireText(for: wire[0]),
            #"<|call|>{"name":"read_file","arguments":{"path":"a.gd"}}<|end|>"#)
    }

    func testBatchOfThreeCalls_allBelongToTheOneAssistantTurn() {
        let wire = ConversationReplay.rebuildFromDisplayRecord([
            LLMMessage(role: .assistant, content: ""),
            toolTurn(ToolNames.search, #"{"query":"a"}"#),
            toolTurn(ToolNames.search, #"{"query":"b"}"#),
            toolTurn(ToolNames.readLines, #"{"path":"a.gd"}"#),
        ])
        XCTAssertEqual(wire.first?.toolCalls?.count, 3)
        XCTAssertEqual(
            wire.map(\.role), [.assistant, .tool, .tool, .tool],
            "the composites still ride the wire as tool turns — the model needs both halves")
    }

    /// The one case the old drop was right about: an empty assistant turn with nothing after
    /// it names no call, so replaying it would show the model a blank turn.
    func testEmptyAssistantTurn_withNoToolTurnsAfterIt_isStillDropped() {
        let wire = ConversationReplay.rebuildFromDisplayRecord([
            LLMMessage(role: .user, content: "hi"),
            LLMMessage(role: .assistant, content: ""),
            LLMMessage(role: .user, content: "still there?"),
        ])
        XCTAssertEqual(wire.map(\.role), [.user, .user])
    }

    func testAssistantTurnWithProse_isUnchanged() {
        let wire = ConversationReplay.rebuildFromDisplayRecord([
            LLMMessage(role: .assistant, content: "Here is my plan."),
            toolTurn(ToolNames.readFile, #"{"path":"a.gd"}"#),
        ])
        XCTAssertEqual(wire.first?.content, "Here is my plan.")
        XCTAssertNil(wire.first?.toolCalls, "a turn with prose kept its own content, as before")
    }

    func testDisplayOnlyEntries_areStillDropped() {
        let wire = ConversationReplay.rebuildFromDisplayRecord([
            LLMMessage(role: .user, content: "retrying", sourceContext: .serverError),
            LLMMessage(role: .assistant, content: ""),
            toolTurn(ToolNames.readFile, #"{"path":"a.gd"}"#),
        ])
        XCTAssertEqual(wire.map(\.role), [.assistant, .tool])
    }

    func testUnparseableToolTurn_doesNotFabricateACall() {
        let wire = ConversationReplay.rebuildFromDisplayRecord([
            LLMMessage(role: .assistant, content: ""),
            LLMMessage(role: .tool, content: "not a composite at all"),
        ])
        XCTAssertEqual(wire.map(\.role), [.tool], "no call to name, so the empty turn drops")
    }

    // MARK: - The composite reader

    func testParseComposite_roundTripsTheProducer() {
        let text = TaskMutationService.toolResultComposite(
            toolName: ToolNames.editFile,
            argumentsJSON: #"{"path":"a.gd","new_text":"x"}"#,
            resultJSON: #"{"ok":true}"#)
        let parsed = TaskMutationService.parseToolResultComposite(text)
        XCTAssertEqual(parsed?.toolName, ToolNames.editFile)
        XCTAssertEqual(parsed?.argumentsJSON, #"{"path":"a.gd","new_text":"x"}"#)
    }

    /// A model's raw `argumentsJSON` is not always one line — the arguments run to the blank
    /// line before `[RESULT]`, never to the first newline.
    func testParseComposite_multilineArguments() {
        let text = TaskMutationService.toolResultComposite(
            toolName: ToolNames.writeFile,
            argumentsJSON: "{\n  \"path\": \"a.gd\"\n}",
            resultJSON: #"{"ok":true}"#)
        XCTAssertEqual(
            TaskMutationService.parseToolResultComposite(text)?.argumentsJSON,
            "{\n  \"path\": \"a.gd\"\n}")
    }

    func testParseComposite_rejectsNonComposites() {
        XCTAssertNil(TaskMutationService.parseToolResultComposite("plain prose"))
        XCTAssertNil(TaskMutationService.parseToolResultComposite("[CALL] read_file"))
        XCTAssertNil(TaskMutationService.parseToolResultComposite("[CALL] \nArguments: {}"))
        XCTAssertNil(TaskMutationService.parseToolResultComposite(""))
    }
}
