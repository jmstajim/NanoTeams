import Foundation

/// Stateless service for repairing poisoned LLM conversations and cleaning model-specific tokens.
/// All methods are static — no instances needed.
enum ConversationRepairService {

    // MARK: - Conversation Repair

    /// Repairs a "poisoned" conversation that causes LLM servers to crash (HTTP 500).
    /// Pattern: assistant(toolCalls) -> tool(error) -> user(guidance) at the tail.
    /// Replaces the poisoned tail with a single user message so the next LLM call can succeed.
    static func repairConversationIfNeeded(_ messages: inout [ChatMessage]) {
        guard messages.count >= 3 else { return }

        // Scan backwards: expect user(guidance), then one or more tool results, then assistant(toolCalls)
        let last = messages[messages.count - 1]
        guard last.role == .user else { return }

        // Count tool messages before the user guidance
        var toolCount = 0
        var idx = messages.count - 2
        while idx >= 0, messages[idx].role == .tool {
            toolCount += 1
            idx -= 1
        }
        guard toolCount > 0, idx >= 0 else { return }

        // Check if the message before tool results is an assistant with toolCalls
        let assistantMsg = messages[idx]
        guard assistantMsg.role == .assistant, assistantMsg.toolCalls != nil else { return }

        // Found poisoned pattern — replace everything from assistant onwards
        let removeCount = 1 + toolCount + 1 // assistant + tools + user
        messages.removeLast(removeCount)
        messages.append(
            ChatMessage(
                role: .user,
                content: "Your previous tool call had invalid arguments and caused a server error. Continue with your task without repeating the failed tool call."
            )
        )
    }

    // MARK: - Harmony Token Cleaning

    /// Clean Harmony/model control tokens from content before persisting.
    /// Uses `ModelTokenCleaner` for generic `<|...|>` token removal, then strips
    /// orphaned Harmony protocol keywords (e.g. "final", "commentary") that follow tokens.
    static func cleanHarmonyTokens(_ content: String) -> String {
        // First: strip Harmony sequences where keyword is glued to the token (e.g. "<|channel|>final")
        var result = content
        let harmonyPatterns = [
            #"<\|channel\|>(?:\s*(?:final|commentary|message|requirements|plan))?\s*"#,
            #"<\|constrain\|>(?:\s*(?:requirements|plan|design))?\s*"#,
            #"<\|start\|>functions\.[a-zA-Z_]*"#,
            #"<\|im_start\|>(?:\s*\w*)?"#,
        ]
        for pattern in harmonyPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        // Then: catch any remaining <|...|> tokens generically
        return ModelTokenCleaner.clean(result)
    }
}
