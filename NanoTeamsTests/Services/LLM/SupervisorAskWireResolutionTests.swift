import XCTest

@testable import NanoTeams

/// The one producer of "the answer resolves the parked ask": the ids the last assistant turn
/// asked with, and the in-place replacement that keeps them.
final class SupervisorAskWireResolutionTests: XCTestCase {

    private func ask(_ id: String, form: Bool = false) -> ChatToolCall {
        ChatToolCall(id: id, name: form ? ToolNames.askSupervisorForm : ToolNames.askSupervisor,
                     argumentsJSON: #"{"question":"?"}"#)
    }

    // MARK: - pendingAskCallIDs

    func testIDs_areTheLastAssistantTurnsAskCalls_bothTools_inOrder() {
        let messages = [
            ChatMessage(role: .assistant, content: nil, toolCalls: [ask("old")]),
            ChatMessage(role: .tool, content: "answered", toolCallID: "old"),
            ChatMessage(role: .assistant, content: nil, toolCalls: [
                ChatToolCall(id: "r", name: ToolNames.readFile, argumentsJSON: "{}"),
                ask("a1"), ask("a2", form: true),
            ]),
            ChatMessage(role: .tool, content: "file", toolCallID: "r"),
            ChatMessage(role: .tool, content: "pending", toolCallID: "a1"),
            ChatMessage(role: .tool, content: "pending", toolCallID: "a2"),
        ]
        XCTAssertEqual(SupervisorAskWireResolution.pendingAskCallIDs(in: messages), ["a1", "a2"])
    }

    func testIDs_empty_whenTheLastTurnAskedNothing_orNoAssistantTurnExists() {
        XCTAssertEqual(SupervisorAskWireResolution.pendingAskCallIDs(in: []), [])
        XCTAssertEqual(SupervisorAskWireResolution.pendingAskCallIDs(in: [
            ChatMessage(role: .user, content: "go"),
        ]), [])
        XCTAssertEqual(SupervisorAskWireResolution.pendingAskCallIDs(in: [
            ChatMessage(role: .assistant, content: nil, toolCalls: [ask("early")]),
            ChatMessage(role: .assistant, content: "prose only"),
        ]), [], "an earlier turn's ask is not what a re-entry answers")
    }

    // MARK: - resolve

    func testResolve_replacesInPlace_keepsTheID_andReportsIt() {
        var messages = [
            ChatMessage(role: .assistant, content: nil, toolCalls: [ask("a1")]),
            ChatMessage(role: .tool, content: "pending", toolCallID: "a1"),
            ChatMessage(role: .user, content: "later"),
        ]
        XCTAssertTrue(SupervisorAskWireResolution.resolve(ids: ["a1"], with: "answer", in: &messages))
        XCTAssertEqual(messages.count, 3, "replaced, not appended")
        XCTAssertEqual(messages[1].role, .tool)
        XCTAssertEqual(messages[1].content, "answer")
        XCTAssertEqual(messages[1].toolCallID, "a1")
    }

    func testResolve_replacesEveryListedID_andTheLastOccurrenceOfEach() {
        var messages = [
            ChatMessage(role: .tool, content: "stale", toolCallID: "a1"),
            ChatMessage(role: .assistant, content: nil, toolCalls: [ask("a1"), ask("a2")]),
            ChatMessage(role: .tool, content: "pending", toolCallID: "a1"),
            ChatMessage(role: .tool, content: "pending", toolCallID: "a2"),
        ]
        XCTAssertTrue(SupervisorAskWireResolution.resolve(ids: ["a1", "a2"], with: "answer", in: &messages))
        XCTAssertEqual(messages.map(\.content), ["stale", nil, "answer", "answer"])
    }

    func testResolve_false_whenNothingMatches_orNoIDs() {
        var messages = [ChatMessage(role: .tool, content: "pending", toolCallID: "a1")]
        XCTAssertFalse(SupervisorAskWireResolution.resolve(ids: [], with: "answer", in: &messages))
        XCTAssertFalse(SupervisorAskWireResolution.resolve(ids: ["other"], with: "answer", in: &messages))
        XCTAssertEqual(messages.first?.content, "pending", "untouched")
    }
}
