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

    /// Collapse runs of consecutive assistant text-only turns (no tool calls) by keeping only
    /// the most recent. After repeated HTTP 400 retries the conversation can accumulate several
    /// near-identical "All tasks complete..." prose dumps that explode token counts on the next
    /// stateless rebuild (regression: Code Reviewer in run EA190834 ballooned 1k → 13k input
    /// tokens). Use after `repairConversationIfNeeded` and before re-streaming.
    static func collapseRedundantAssistantTextRuns(_ messages: inout [ChatMessage]) {
        guard messages.count >= 2 else { return }
        var compacted: [ChatMessage] = []
        compacted.reserveCapacity(messages.count)
        for msg in messages {
            let isTextOnlyAssistant = msg.role == .assistant
                && (msg.toolCalls?.isEmpty ?? true)
                && !(msg.content?.isEmpty ?? true)
            if isTextOnlyAssistant,
               let prev = compacted.last,
               prev.role == .assistant,
               prev.toolCalls?.isEmpty ?? true,
               !(prev.content?.isEmpty ?? true) {
                // Replace prior text-only assistant with this newer one
                compacted[compacted.count - 1] = msg
            } else {
                compacted.append(msg)
            }
        }
        messages = compacted
    }

    // MARK: - Message-Level Loop Detection

    /// Outcome of scanning recent assistant messages for loop patterns.
    enum MessageLoopOutcome: Equatable {
        case noLoop
        /// Assistant is stuck refusing in a loop (matches refusal-pattern regex).
        /// `count` is how many recent refusals were detected.
        /// Escalate to supervisor — the program has no way to un-stick the model.
        case refusalLoop(count: Int, sample: String)
        /// Assistant emits near-identical non-refusal responses without tool calls.
        /// Single-shot nudge; escalate if it repeats next iteration.
        case repetitiveNonTool(count: Int)
    }

    /// Regex detecting the "I can't do this in this environment" refusal family.
    /// Case-insensitive, tolerates the curly apostrophe `’`. Pattern is the source
    /// of truth — do not restate its clauses in prose (they will drift).
    private static let refusalPatternRegex: NSRegularExpression? = {
        let pattern = #"(?i)\b(i['’]?m sorry|i can(?:not|['’]?t)|i do(?:n['’]?t| not) have|unable to|do(?:es)?(?:n['’]?t| not) allow|(?:no|don['’]?t have) permission|don['’]?t have (?:access|the ability)|do(?:es)?(?:n['’]?t| not) permit)\b"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Detects a message-level loop at the conversation tail.
    ///
    /// Two patterns are caught:
    /// 1. **Refusal loop**: the last `window` consecutive no-tool-call assistant
    ///    messages all match the refusal regex — escalate to supervisor.
    /// 2. **Repetitive non-tool**: identical normalized fingerprints without
    ///    matching the refusal pattern — single-shot nudge.
    ///
    /// Otherwise `.noLoop`. Messages with nil/empty content are skipped.
    /// Window default is 3: 2 is too noisy (models say "I'm sorry" mid-progress),
    /// 3 is a real pattern.
    static func detectMessageLoop(
        conversationMessages: [ChatMessage],
        window: Int = 3
    ) -> MessageLoopOutcome {
        guard window >= 2 else { return .noLoop }

        // Collect recent text-only assistant messages (no tool calls, non-empty content).
        var recent: [String] = []
        for msg in conversationMessages.reversed() {
            guard msg.role == .assistant,
                  (msg.toolCalls?.isEmpty ?? true),
                  let content = msg.content, !content.isEmpty
            else { continue }
            recent.append(content)
            if recent.count >= window { break }
        }

        guard recent.count >= window else { return .noLoop }

        // Check refusal-loop first: all last N messages matching the refusal pattern.
        // Byte-identical fingerprints NOT required — refusals paraphrase but stay semantically fixed.
        if recent.allSatisfy({ isRefusalContent($0) }) {
            return .refusalLoop(count: recent.count, sample: recent[0])
        }

        // Non-refusal repetition needs byte-identical fingerprints; a single-shot
        // nudge is enough for "ok, continuing" × N style stalls.
        let fingerprints = recent.map { normalizeForLoopFingerprint($0) }
        let first = fingerprints[0]
        guard !first.isEmpty, fingerprints.allSatisfy({ $0 == first }) else {
            return .noLoop
        }
        return .repetitiveNonTool(count: recent.count)
    }

    /// Cheap, stable fingerprint for loop detection: lowercased + whitespace-collapsed
    /// + first 200 chars of the content. Two refusals that differ only in trailing
    /// whitespace/punctuation still fingerprint identically.
    static func normalizeForLoopFingerprint(_ content: String) -> String {
        let lowered = content.lowercased()
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed: String
        if let regex = try? NSRegularExpression(pattern: #"\s+"#, options: []) {
            collapsed = regex.stringByReplacingMatches(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed),
                withTemplate: " "
            )
        } else {
            collapsed = trimmed
        }
        return String(collapsed.prefix(200))
    }

    /// True when content matches a refusal pattern. Public so the step-flow
    /// caller can also classify a single message when composing its escalation question.
    static func isRefusalContent(_ content: String) -> Bool {
        guard let regex = refusalPatternRegex else { return false }
        let range = NSRange(content.startIndex..., in: content)
        return regex.firstMatch(in: content, options: [], range: range) != nil
    }

    // MARK: - Thinking-Drift Detection

    /// Threshold for `thinking` content length that signals "reasoning without acting."
    /// Derived from Run 13 (qwen3.5-35b-a3b): a 61,630-char thinking trace with no tool
    /// call consumed 215s and timed out the run. gpt-oss-20b typically emits <5,000
    /// chars of thinking; 10,000 catches runaway reasoning without false-positives on
    /// models that routinely reason briefly.
    static let thinkingDriftLengthThreshold: Int = 10_000

    /// True when the latest streaming turn is a "thinking-drift" pattern: long
    /// `thinking` trace, empty `content`, no tool calls. Pure predicate — no state.
    /// Callers maintain a consecutive-drift counter themselves.
    static func isThinkingDrift(
        thinkingLength: Int,
        contentLength: Int,
        toolCallCount: Int
    ) -> Bool {
        thinkingLength >= thinkingDriftLengthThreshold
            && contentLength == 0
            && toolCallCount == 0
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
