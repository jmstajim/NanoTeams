import XCTest

@testable import NanoTeams

final class ConversationRepairServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - repairConversationIfNeeded

    func testRepairConversation_repairsPoisonedTail() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Build a feature"),
            ChatMessage(
                role: .assistant,
                content: nil,
                toolCalls: [ChatToolCall(id: "tc1", name: "read_file", argumentsJSON: "{\"path\":\"/bad\"}")]
            ),
            ChatMessage(role: .tool, content: "Error: file not found", toolCallID: "tc1", isToolError: true),
            ChatMessage(role: .user, content: "Please continue without that file"),
        ]

        let originalCount = messages.count
        ConversationRepairService.repairConversationIfNeeded(&messages)

        // Poisoned tail (assistant+tool+user) replaced with single recovery user message
        XCTAssertEqual(messages.count, originalCount - 2, "Should remove 3 messages and add 1")
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertTrue(messages.last?.content?.contains("server error") ?? false)
    }

    func testRepairConversation_leavesHealthyConversationUnchanged() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there"),
        ]

        let originalCount = messages.count
        ConversationRepairService.repairConversationIfNeeded(&messages)

        XCTAssertEqual(messages.count, originalCount, "Healthy conversation should not be modified")
    }

    // MARK: - cleanHarmonyTokens

    func testCleanHarmonyTokens_stripsChannelAndConstrain() {
        let input = "<|channel|>final Here is my analysis <|constrain|>requirements"
        let result = ConversationRepairService.cleanHarmonyTokens(input)

        XCTAssertFalse(result.contains("<|channel|>"))
        XCTAssertFalse(result.contains("<|constrain|>"))
        XCTAssertTrue(result.contains("Here is my analysis"))
    }

    func testCleanHarmonyTokens_stripsImStartAndFunctions() {
        let input = "Hello <|im_start|>assistant world <|start|>functions.read_file"
        let result = ConversationRepairService.cleanHarmonyTokens(input)

        XCTAssertFalse(result.contains("<|im_start|>"))
        XCTAssertFalse(result.contains("<|start|>"))
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("world"))
    }
}
