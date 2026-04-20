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

    // MARK: - collapseRedundantAssistantTextRuns (regression EA190834)

    /// Regression: Code Reviewer in run EA190834 produced 4-5 near-identical "All tasks
    /// complete..." prose dumps in succession. After each HTTP 400 retry, the conversation
    /// was rebuilt stateless including ALL prior text dumps, ballooning input tokens 1k → 13k.
    /// Collapse keeps only the most recent text-only assistant turn from any run of them.
    func testCollapse_replacesConsecutiveTextOnlyAssistantTurns() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "system"),
            ChatMessage(role: .user, content: "do work"),
            ChatMessage(role: .assistant, content: "first pass thoughts"),
            ChatMessage(role: .assistant, content: "second pass thoughts"),
            ChatMessage(role: .assistant, content: "third pass thoughts"),
            ChatMessage(role: .user, content: "ok"),
        ]
        ConversationRepairService.collapseRedundantAssistantTextRuns(&messages)
        XCTAssertEqual(messages.count, 4, "Three consecutive text-only assistants should collapse to one")
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertEqual(messages[2].content, "third pass thoughts", "Should keep most recent")
    }

    func testCollapse_preservesAssistantWithToolCalls() {
        let toolCall = ChatToolCall(id: "tc1", name: "read_file", argumentsJSON: "{}")
        var messages: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "thinking", toolCalls: [toolCall]),
            ChatMessage(role: .assistant, content: "more text"),
        ]
        let original = messages
        ConversationRepairService.collapseRedundantAssistantTextRuns(&messages)
        XCTAssertEqual(messages.count, original.count, "Tool-call assistant must not be collapsed")
        XCTAssertEqual(messages[0].toolCalls?.count, 1)
    }

    func testCollapse_preservesNonAdjacentAssistants() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "A"),
            ChatMessage(role: .user, content: "Q"),
            ChatMessage(role: .assistant, content: "B"),
        ]
        ConversationRepairService.collapseRedundantAssistantTextRuns(&messages)
        XCTAssertEqual(messages.count, 3, "Non-adjacent assistants must both survive")
    }

    func testCollapse_emptyAndSingleMessageNoop() {
        var empty: [ChatMessage] = []
        ConversationRepairService.collapseRedundantAssistantTextRuns(&empty)
        XCTAssertTrue(empty.isEmpty)

        var single: [ChatMessage] = [ChatMessage(role: .assistant, content: "alone")]
        ConversationRepairService.collapseRedundantAssistantTextRuns(&single)
        XCTAssertEqual(single.count, 1)
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

    // MARK: - isThinkingDrift

    // Regression for Run 13: qwen3.5-35b-a3b SWE step emitted a ~61,630-char
    // thinking trace with empty content and no tool call, consuming 215s and
    // timing out the run. The predicate fires on that exact shape.
    func testIsThinkingDrift_hugeThinkingEmptyContentNoToolCalls_returnsTrue() {
        XCTAssertTrue(ConversationRepairService.isThinkingDrift(
            thinkingLength: 61_630,
            contentLength: 0,
            toolCallCount: 0
        ))
    }

    func testIsThinkingDrift_atThreshold_returnsTrue() {
        XCTAssertTrue(ConversationRepairService.isThinkingDrift(
            thinkingLength: ConversationRepairService.thinkingDriftLengthThreshold,
            contentLength: 0,
            toolCallCount: 0
        ))
    }

    func testIsThinkingDrift_belowThreshold_returnsFalse() {
        XCTAssertFalse(ConversationRepairService.isThinkingDrift(
            thinkingLength: 5_000,
            contentLength: 0,
            toolCallCount: 0
        ))
    }

    func testIsThinkingDrift_contentPresent_returnsFalse() {
        // Long thinking alongside any user-visible content is not "drift" —
        // other branches (refusal, repetitive-non-tool) can classify it.
        XCTAssertFalse(ConversationRepairService.isThinkingDrift(
            thinkingLength: 50_000,
            contentLength: 42,
            toolCallCount: 0
        ))
    }

    func testIsThinkingDrift_hasToolCall_returnsFalse() {
        // A tool call IS a concrete action — never classify as drift even if
        // thinking is long.
        XCTAssertFalse(ConversationRepairService.isThinkingDrift(
            thinkingLength: 80_000,
            contentLength: 0,
            toolCallCount: 1
        ))
    }
}
