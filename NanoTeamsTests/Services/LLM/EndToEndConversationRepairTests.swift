import XCTest

@testable import NanoTeams

/// Integration tests for conversation repair: poisoned tail detection → repair → token cleaning.
/// Validates ConversationRepairService + ModelTokenCleaner work correctly together.
@MainActor
final class EndToEndConversationRepairTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Poisoned tail detected and repaired

    func testPoisonedTail_detected_repaired() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are an engineer."),
            ChatMessage(role: .user, content: "Start the step."),
            ChatMessage(role: .assistant, content: "Let me read the file.",
                        toolCalls: [ChatToolCall(id: "tc1", name: "read_file", argumentsJSON: "{}")]),
            ChatMessage(role: .tool, content: "Error: file not found", toolCallID: "tc1", isToolError: true),
            ChatMessage(role: .user, content: "Continue with your task without repeating the failed call."),
        ]

        ConversationRepairService.repairConversationIfNeeded(&messages)

        // Poisoned tail (assistant + tool + user) should be replaced with single user message
        XCTAssertEqual(messages.count, 3, "Should have system + user + repair message")
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertTrue(messages.last?.content?.contains("server error") ?? false,
                      "Repair message should mention server error")
    }

    // MARK: - Test 2: Harmony tokens cleaned

    func testHarmonyTokens_cleaned() {
        let dirtyContent = "<|channel|>final Here is my analysis <|constrain|>requirements of the code."
        let cleaned = ConversationRepairService.cleanHarmonyTokens(dirtyContent)

        XCTAssertFalse(cleaned.contains("<|channel|>"), "Should strip <|channel|> token")
        XCTAssertFalse(cleaned.contains("<|constrain|>"), "Should strip <|constrain|> token")
        XCTAssertTrue(cleaned.contains("Here is my analysis"), "Should preserve content")
        XCTAssertTrue(cleaned.contains("of the code"), "Should preserve content after tokens")
    }

    // MARK: - Test 3: Repair preserves valid messages

    func testRepair_preservesValidMessages() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Start working"),
            ChatMessage(role: .assistant, content: "I'll analyze the code."),
            ChatMessage(role: .user, content: "Good, continue."),
        ]

        let originalCount = messages.count
        ConversationRepairService.repairConversationIfNeeded(&messages)

        // No poisoned pattern — messages should be unchanged
        XCTAssertEqual(messages.count, originalCount,
                       "Valid conversation should not be modified")
    }

    // MARK: - Test 4: Short conversation not affected

    func testRepair_shortConversation_notAffected() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System"),
            ChatMessage(role: .user, content: "Start"),
        ]

        ConversationRepairService.repairConversationIfNeeded(&messages)

        XCTAssertEqual(messages.count, 2, "Short conversation should not be modified")
    }

    // MARK: - Test 5: Multiple tool results in poisoned tail

    func testRepair_multipleTailToolResults_allRemoved() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Start"),
            ChatMessage(role: .assistant, content: nil,
                        toolCalls: [
                            ChatToolCall(id: "tc1", name: "read_file", argumentsJSON: "{}"),
                            ChatToolCall(id: "tc2", name: "list_files", argumentsJSON: "{}"),
                        ]),
            ChatMessage(role: .tool, content: "Error 1", toolCallID: "tc1", isToolError: true),
            ChatMessage(role: .tool, content: "Error 2", toolCallID: "tc2", isToolError: true),
            ChatMessage(role: .user, content: "Retry guidance"),
        ]

        ConversationRepairService.repairConversationIfNeeded(&messages)

        // Should remove: assistant(2 toolCalls) + 2 tool results + user guidance = 4 messages
        XCTAssertEqual(messages.count, 3, "Should have system + user(start) + repair message")
        XCTAssertEqual(messages.last?.role, .user)
    }

    // MARK: - Test 6: ModelTokenCleaner strips generic tokens

    func testModelTokenCleaner_stripsGenericTokens() {
        let dirty = "Here is the <|im_start|>code <|im_end|>implementation."
        let clean = ModelTokenCleaner.clean(dirty)

        XCTAssertFalse(clean.contains("<|im_start|>"))
        XCTAssertFalse(clean.contains("<|im_end|>"))
        XCTAssertTrue(clean.contains("code"))
        XCTAssertTrue(clean.contains("implementation"))
    }
}
