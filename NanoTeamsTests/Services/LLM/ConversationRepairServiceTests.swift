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

    /// The repair deletes the assistant turn the recovery message refers to —
    /// the message must therefore NAME the failed call (tool + args) so the
    /// model knows what not to repeat [Laban2025].
    func testRepairConversation_recoveryMessageNamesFailedCall() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Build a feature"),
            ChatMessage(
                role: .assistant,
                content: nil,
                toolCalls: [ChatToolCall(id: "tc1", name: "edit_file", argumentsJSON: "{\"path\":\"/x\"}")]
            ),
            ChatMessage(role: .tool, content: "Error", toolCallID: "tc1", isToolError: true),
            ChatMessage(role: .user, content: "guidance"),
        ]
        ConversationRepairService.repairConversationIfNeeded(&messages)

        let recovery = messages.last?.content ?? ""
        XCTAssertTrue(recovery.contains("edit_file"), "must name the failed tool. Got: \(recovery)")
        XCTAssertTrue(recovery.contains("/x"), "must quote the failing arguments")
        XCTAssertFalse(recovery.contains("Your previous tool call"),
                       "generic phrasing only when the tool list is unavailable")
    }

    /// Oversized arguments are truncated in the recovery message — the repair
    /// must not re-inject a huge payload it just removed.
    func testRepairConversation_recoveryMessageTruncatesLongArgs() {
        let longArgs = "{\"content\":\"" + String(repeating: "a", count: 1000) + "\"}"
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "s"),
            ChatMessage(role: .user, content: "u"),
            ChatMessage(
                role: .assistant, content: nil,
                toolCalls: [ChatToolCall(id: "tc1", name: "write_file", argumentsJSON: longArgs)]
            ),
            ChatMessage(role: .tool, content: "Error", toolCallID: "tc1", isToolError: true),
            ChatMessage(role: .user, content: "g"),
        ]
        ConversationRepairService.repairConversationIfNeeded(&messages)
        XCTAssertLessThan(messages.last?.content?.count ?? .max, 500)
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
