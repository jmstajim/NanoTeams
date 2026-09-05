import Foundation
#if DEBUG
import Synchronization
#endif

/// Stateless service for repairing poisoned LLM conversations and cleaning model-specific tokens.
/// All methods are static — no instances needed.
nonisolated enum ConversationRepairService {

    // MARK: - Conversation Repair

    /// Repairs a "poisoned" conversation that causes LLM servers to crash (HTTP 500).
    /// Pattern: assistant(toolCalls) -> tool(error) -> user(guidance) at the tail.
    /// Replaces the poisoned tail with a single user message so the next LLM call can succeed.
    ///
    /// Returns whether it actually repaired anything. The caller needs that: the repair is a
    /// DELIBERATE prefix reset (it truncates the tail), so it has to arm
    /// `expectedPrefixResetPending` — but only when it fired. Arming unconditionally would let a
    /// no-op repair swallow the NEXT genuine cache miss, since the flag is a consumed one-shot.
    /// It is necessary rather than optional — the alternative is an unrecoverable HTTP 500 loop —
    /// which is what makes it an exemption rather than a defect.
    @discardableResult
    static func repairConversationIfNeeded(_ messages: inout [ChatMessage]) -> Bool {
        guard messages.count >= 3 else { return false }

        // Scan backwards: expect user(guidance), then one or more tool results, then assistant(toolCalls)
        let last = messages[messages.count - 1]
        guard last.role == .user else { return false }

        // Count tool messages before the user guidance
        var toolCount = 0
        var idx = messages.count - 2
        while idx >= 0, messages[idx].role == .tool {
            toolCount += 1
            idx -= 1
        }
        guard toolCount > 0, idx >= 0 else { return false }

        // Check if the message before tool results is an assistant with toolCalls
        let assistantMsg = messages[idx]
        guard assistantMsg.role == .assistant, assistantMsg.toolCalls != nil else { return false }

        // Found poisoned pattern — replace everything from assistant onwards.
        // The replacement message must restate WHICH call failed: the repair
        // just deleted the assistant turn it refers to, so "your previous tool
        // call" would point at nothing the model can see [Laban2025 — restate
        // the critical context you removed].
        let failedCalls = (assistantMsg.toolCalls ?? []).map { call in
            let args = String(call.argumentsJSON.prefix(200))
            return "\(call.name)(\(args))"
        }
        let callsDescription = failedCalls.isEmpty
            ? "Your previous tool call"
            : "Your \(failedCalls.joined(separator: ", ")) call"
        let removeCount = 1 + toolCount + 1 // assistant + tools + user
        messages.removeLast(removeCount)
        messages.append(
            ChatMessage(
                role: .user,
                content: "\(callsDescription) had invalid arguments and caused a server error. "
                    + "Do not repeat that exact call — fix the arguments or take the next step of your task."
            )
        )
        return true
    }

    // A `collapseRedundantAssistantTextRuns` used to run here, on the same retry path, folding
    // runs of consecutive text-only assistant turns down to the newest. It was deleted (2026-07)
    // for three independent reasons, recorded so it is not reinvented:
    //
    //  1. **Its trigger was wrong.** It fired in the retryable-LLM-error arm, while the shape it
    //     targeted is produced by the model looping without tool calls — iteration by iteration,
    //     not by the retry. Its regression (EA190834) was the `previous_response_id` HTTP-400
    //     loop of the stateful era, which no longer exists.
    //  2. **It could not fire anyway.** Adjacency needs two text-only assistant turns in a row,
    //     and every `.continueLoop` arm of `handleNoToolCalls` appends a `.user` nudge first;
    //     `processStreamingResult` appends exactly one assistant turn per iteration. The only
    //     reachable adjacency is `ConversationReplay.rebuildFromDisplayRecord`, which is already
    //     a total prefix loss reported as `degradedReplay`. Pinned by
    //     `ConversationAppendInvariantTests`.
    //  3. **Its cost was unbounded.** It rebuilt the array, so the divergence index could be as
    //     early as 2 — a full re-prefill (~4-6 s at 13k tokens) on a stateless transport, paid on
    //     top of an already-failed request, and with no exemption it also reported as a defect.
    //     Token volume is the context-budget subsystem's concern; the looping shape is
    //     `detectMessageLoop`'s, which shipped in the same commit.

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

    /// The detector's window. One home for the literal (CLAUDE.md #91): the default of
    /// `detectMessageLoop`, the capacity of the `StepExecutionState.recentNoToolAssistantContents`
    /// ring, and the guard in `classifyMessageLoop` all read it from here.
    ///
    /// 3, because 2 is too noisy (models say "I'm sorry" mid-progress) and 3 is a real pattern.
    static let messageLoopWindow = 3

    /// Detects a message-level loop at the conversation tail.
    ///
    /// Two patterns are caught:
    /// 1. **Refusal loop**: the last `window` consecutive no-tool-call assistant
    ///    messages all match the refusal regex — escalate to supervisor.
    /// 2. **Repetitive non-tool**: identical normalized fingerprints without
    ///    matching the refusal pattern — single-shot nudge.
    ///
    /// Otherwise `.noLoop`. Messages with nil/empty content are skipped.
    ///
    /// The reference composition: the tail walk (`recentNoToolAssistantContents`) followed by
    /// the pure classifier (`classifyMessageLoop`). The tool loop does NOT call this per
    /// iteration — it maintains the walk's result as a ring in `StepExecutionState` and hands
    /// the ring to the classifier — but this function is what that ring must agree with at
    /// every read (`MessageLoopDetectorTests` pins ring ≡ walk on randomised wires).
    static func detectMessageLoop(
        conversationMessages: [ChatMessage],
        window: Int = messageLoopWindow
    ) -> MessageLoopOutcome {
        classifyMessageLoop(
            recentNoToolAssistantContents: recentNoToolAssistantContents(
                in: conversationMessages, window: window),
            window: window)
    }

    /// The membership predicate — the ONE home for "this assistant turn counts toward a
    /// message loop": `.assistant`, no tool calls (`nil` or `[]`), non-empty content. Used by
    /// the walk below and by the append site that pushes into the ring.
    static func qualifiesForMessageLoop(_ message: ChatMessage) -> Bool {
        message.role == .assistant
            && (message.toolCalls?.isEmpty ?? true)
            && !(message.content ?? "").isEmpty
    }

    /// The last `window` qualifying assistant contents in `messages`, OLDEST-FIRST.
    ///
    /// Walks from the tail and stops at `window` matches, so it is Θ(Δ) when qualifying turns
    /// sit near the tail — and honestly Θ(N) on a wire with fewer than `window` of them, which
    /// is exactly the tool-heavy shape the tool loop no longer pays per iteration.
    static func recentNoToolAssistantContents(
        in messages: [ChatMessage],
        window: Int = messageLoopWindow
    ) -> [String] {
        var tail: [String] = []
        for message in messages.reversed() {
            #if DEBUG
            MessageLoopScanProbe.noteExamined()
            #endif
            guard qualifiesForMessageLoop(message), let content = message.content else { continue }
            tail.append(content)
            if tail.count >= window { break }
        }
        return tail.reversed()
    }

    /// Appends one qualifying content to a ring kept in the shape
    /// `recentNoToolAssistantContents(in:)` returns (oldest-first, at most `window` entries).
    static func pushMessageLoopContent(
        _ content: String, into ring: inout [String], window: Int = messageLoopWindow
    ) {
        ring.append(content)
        if ring.count > window { ring.removeFirst(ring.count - window) }
    }

    /// The pure half of `detectMessageLoop`. `recent` MUST be exactly
    /// `recentNoToolAssistantContents(in: wire)` for the wire the caller is about to send —
    /// the tool loop maintains it as a ring in `StepExecutionState`, and this file owns the
    /// predicate that decides membership (`qualifiesForMessageLoop`).
    ///
    /// `sample` is the NEWEST entry (the old newest-first walk read `recent[0]`; the array is
    /// oldest-first now, so it is the last). The all-equal fingerprint test is order-symmetric.
    static func classifyMessageLoop(
        recentNoToolAssistantContents recent: [String],
        window: Int = messageLoopWindow
    ) -> MessageLoopOutcome {
        guard window >= 2 else { return .noLoop }
        guard recent.count >= window else { return .noLoop }

        // Check refusal-loop first: all last N messages matching the refusal pattern.
        // Byte-identical fingerprints NOT required — refusals paraphrase but stay semantically fixed.
        if recent.allSatisfy({ isRefusalContent($0) }) {
            return .refusalLoop(count: recent.count, sample: recent[recent.count - 1])
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

    /// Tool names the model wrote into the REASONING channel as a Harmony envelope.
    ///
    /// Diagnosis only, never dispatch. The result reaches nothing but the text of a nudge:
    /// there is no route from `thinkingCollected` into `resolvedToolCalls`, and none is being
    /// added — see the route list in `performStreamingCall` for why a rehearsed call is not a
    /// call. This function exists because the turn is ALREADY lost by the time it runs, and
    /// the model deserves to be told which channel swallowed it.
    ///
    /// Names come back in written order and deduplicated: a nudge that lists one name twice
    /// reads as two separate mistakes.
    static func reasoningChannelToolCallNames(in thinking: String) -> [String] {
        var seen = Set<String>()
        return HarmonyToolCallParser().extractAllToolCalls(from: thinking)
            .map(\.name)
            .filter { seen.insert($0).inserted }
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

#if DEBUG
/// Work-bound seam: how many wire messages `recentNoToolAssistantContents` EXAMINED since the
/// last reset.
///
/// Inside the walk, not beside a call site (CLAUDE.md #62): a regression that puts the walk
/// back into `handleNoToolCalls` is invisible in OUTPUT — the ring and the walk agree by
/// construction — and shows only as a Θ(N) pass per no-tool turn on an uncapped wire.
nonisolated enum MessageLoopScanProbe {
    private static let _examined = Atomic<Int>(0)
    static func noteExamined() { _examined.wrappingAdd(1, ordering: .relaxed) }
    static func examined() -> Int { _examined.load(ordering: .relaxed) }
    static func reset() { _examined.store(0, ordering: .relaxed) }
}
#endif
