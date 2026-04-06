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
        let messages = chat.messagesToSend(session: nil)
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[3].content, "Question 2")
    }

    // MARK: - messagesToSend — stateful

    func testMessagesToSend_withSession_returnsOnlyNewMessages() {
        let chat = RoleConsultationChat(
            id: "pm",
            messages: [
                LLMMessage(role: .system, content: "System prompt"),
                LLMMessage(role: .user, content: "Question 1"),
                LLMMessage(role: .assistant, content: "Answer 1"),
                LLMMessage(role: .user, content: "Question 2"),
            ]
        )
        let session = LLMSession(responseID: "resp-1")
        let messages = chat.messagesToSend(session: session)
        // Should return only messages after last assistant message
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "Question 2")
        XCTAssertEqual(messages[0].role, .user)
    }

    func testMessagesToSend_withSession_noAssistantMessage_returnsAll() {
        let chat = RoleConsultationChat(
            id: "pm",
            messages: [
                LLMMessage(role: .system, content: "System prompt"),
                LLMMessage(role: .user, content: "First question"),
            ]
        )
        let session = LLMSession(responseID: "resp-1")
        let messages = chat.messagesToSend(session: session)
        // No assistant message found, return all
        XCTAssertEqual(messages.count, 2)
    }

    func testMessagesToSend_withSession_assistantIsLast_returnsEmpty() {
        let chat = RoleConsultationChat(
            id: "pm",
            messages: [
                LLMMessage(role: .user, content: "Question"),
                LLMMessage(role: .assistant, content: "Final answer"),
            ]
        )
        let session = LLMSession(responseID: "resp-1")
        let messages = chat.messagesToSend(session: session)
        // Assistant is the last message, nothing new after it
        XCTAssertTrue(messages.isEmpty)
    }

    func testMessagesToSend_emptyChat_returnsEmpty() {
        let chat = RoleConsultationChat(id: "empty")
        XCTAssertTrue(chat.messagesToSend(session: nil).isEmpty)
        XCTAssertTrue(chat.messagesToSend(session: LLMSession(responseID: "r")).isEmpty)
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
