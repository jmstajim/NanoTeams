import XCTest
@testable import NanoTeams

final class RoleConsultationChatTests: XCTestCase {

    // MARK: - toChatMessages

    func testToChatMessages_convertsRolesCorrectly() {
        let chat = RoleConsultationChat(
            id: "pm",
            messages: [
                LLMMessage(role: .system, content: "You are a PM"),
                LLMMessage(role: .user, content: "What should we build?"),
                LLMMessage(role: .assistant, content: "Let me think..."),
            ]
        )
        let chatMessages = chat.toChatMessages()
        XCTAssertEqual(chatMessages.count, 3)
        XCTAssertEqual(chatMessages[0].role, .system)
        XCTAssertEqual(chatMessages[0].content, "You are a PM")
        XCTAssertEqual(chatMessages[1].role, .user)
        XCTAssertEqual(chatMessages[2].role, .assistant)
        XCTAssertEqual(chatMessages[2].content, "Let me think...")
    }

    func testToChatMessages_emptyChat_returnsEmpty() {
        let chat = RoleConsultationChat(id: "empty")
        XCTAssertTrue(chat.toChatMessages().isEmpty)
    }

    func testToChatMessages_toolRole_converts() {
        let chat = RoleConsultationChat(
            id: "swe",
            messages: [
                LLMMessage(role: .tool, content: "{\"ok\": true}"),
            ]
        )
        let chatMessages = chat.toChatMessages()
        XCTAssertEqual(chatMessages.count, 1)
        XCTAssertEqual(chatMessages[0].role, .tool)
    }

    // MARK: - messagesToSend — stateless

    func testMessagesToSend_noSession_returnsAll() {
        let chat = RoleConsultationChat(
            id: "pm",
            messages: [
                LLMMessage(role: .system, content: "System prompt"),
                LLMMessage(role: .user, content: "Question 1"),
                LLMMessage(role: .assistant, content: "Answer 1"),
                LLMMessage(role: .user, content: "Question 2"),
            ]
        )
        let messages = chat.messagesToSend()
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[3].content, "Question 2")
    }

    // MARK: - messagesToSend — always the full history

    /// Server-side response chains were removed: the chat's ENTIRE history rides
    /// every call, including the turns already answered. A "send only what's new"
    /// slice is exactly the shape that made the model wake with no memory of the
    /// exchange after a provider switch.
    func testMessagesToSend_afterAnAnsweredTurn_stillReturnsEverything() {
        let chat = RoleConsultationChat(
            id: "pm",
            messages: [
                LLMMessage(role: .system, content: "System prompt"),
                LLMMessage(role: .user, content: "Question 1"),
                LLMMessage(role: .assistant, content: "Answer 1"),
                LLMMessage(role: .user, content: "Question 2"),
            ]
        )
        let messages = chat.messagesToSend()
        XCTAssertEqual(messages.count, 4,
                       "The whole chat is the request — no post-assistant slice")
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[2].content, "Answer 1",
                       "The prior answer must still be visible to the model")
        XCTAssertEqual(messages[3].content, "Question 2")
    }

    func testMessagesToSend_assistantIsLast_stillReturnsEverything() {
        let chat = RoleConsultationChat(
            id: "pm",
            messages: [
                LLMMessage(role: .user, content: "Question"),
                LLMMessage(role: .assistant, content: "Final answer"),
            ]
        )
        XCTAssertEqual(chat.messagesToSend().count, 2)
    }

    func testMessagesToSend_emptyChat_returnsEmpty() {
        let chat = RoleConsultationChat(id: "empty")
        XCTAssertTrue(chat.messagesToSend().isEmpty)
    }

    // MARK: - injectedArtifactIDs

    func testInit_defaultInjectedArtifactIDs_isEmpty() {
        let chat = RoleConsultationChat(id: "test")
        XCTAssertTrue(chat.injectedArtifactIDs.isEmpty)
    }

    func testInit_withInjectedArtifactIDs() {
        let chat = RoleConsultationChat(id: "test", injectedArtifactIDs: ["artifact-1", "artifact-2"])
        XCTAssertEqual(chat.injectedArtifactIDs.count, 2)
        XCTAssertTrue(chat.injectedArtifactIDs.contains("artifact-1"))
    }
}
