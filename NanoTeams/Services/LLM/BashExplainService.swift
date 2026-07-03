import Foundation

/// A short, plain-language "Ask AI" advisory for a single held `bash` command:
/// first what the command does, then an independent read on whether it looks
/// safe to run. Shown beside the judge's verdict so the human reviewing a held
/// command gets both a description and a second opinion.
///
/// Advisory only — it never drives the gate. The authoritative verdict (the
/// ✅/❌ glyph) still comes solely from `BashJudgeService`; this call's safety
/// read is a human-facing second voice, grounded in the same sandbox limits the
/// judge sees so it rarely contradicts the gate. Unlike the judge (which fails CLOSED), this fails SOFT — any
/// transport error, an empty reply, or noise resolves to an empty string, so a
/// missing advisory simply shows nothing rather than blocking or misleading the
/// human. A fresh `session: nil` call (DIP over `any LLMClient`), reusing the
/// dedicated judge model override so it comes from the same model the user
/// configured for bash decisions.
nonisolated enum BashExplainService {
    static func explain(
        command: String,
        workingDirectory: String?,
        policy: BashPolicy,
        config: LLMConfig,
        client: any LLMClient = LLMClientRouter(),
        logger: NetworkLogger? = nil
    ) async -> String {
        let messages = [
            ChatMessage(role: .system, content: explainSystemPrompt(policy: policy)),
            ChatMessage(role: .user, content: explainUserPrompt(command: command, workingDirectory: workingDirectory)),
        ]

        var content = ""
        var thinking = ""
        do {
            // JudgeConfig.applying, NOT configForJudge: this call wants only the
            // judge's model targeting (URL/model/maxTokens override). The verdict
            // path's temperature-0 pin is for strict-JSON extraction — this is
            // generative prose, so the operator's temperature stays in effect.
            let stream = client.streamChat(
                config: JudgeConfig.applying(policy.judgeOverride, to: config),
                messages: messages,
                tools: [],
                session: nil,
                logger: logger,
                stepID: nil
            )
            for try await event in stream {
                content += event.contentDelta
                thinking += event.thinkingDelta
            }
        } catch {
            return ""   // informational only — fail soft, never block the human
        }

        let cleaned = ModelTokenCleaner.clean(content).trimmingCharacters(in: .whitespacesAndNewlines)
        // Reasoning models sometimes leave the description only in the thinking channel.
        let source = cleaned.isEmpty
            ? ModelTokenCleaner.clean(thinking).trimmingCharacters(in: .whitespacesAndNewlines)
            : cleaned
        return unwrapQuotes(source)
    }

    /// The "Ask AI" advisory system prompt — describe, then assess, GROUNDED in the
    /// same sandbox limits the judge sees (`sandboxConfinementDescription`) so the
    /// safety read rarely contradicts the gate glyph. Still separate from the judge:
    /// this is a human-facing second opinion, NOT the gate verdict (the judge's ✅/❌
    /// stays authoritative), so its read can never alter the gate decision.
    static func explainSystemPrompt(policy: BashPolicy) -> String {
        """
        The command runs under these limits: \(BashJudgeService.sandboxConfinementDescription(policy: policy))
        First, in ONE short plain-language sentence, state what the given shell command does — \
        its purpose and effect. Then, in ONE short sentence, say whether it looks safe to run under \
        those limits, and why. \
        Reply with just those two sentences — no preamble, no quotes, no code fences.
        """
    }

    /// The advisory's user turn — the command plus its working directory, mirroring
    /// the judge's so the same `(command, workingDirectory)` context is in view.
    static func explainUserPrompt(command: String, workingDirectory: String?) -> String {
        """
        Command:
        \(command)

        Working directory: \(workingDirectory ?? "(project root)")

        Reply now: first what it does, then whether it is safe.
        """
    }

    /// Strips one pair of wrapping quotes a model may add despite the instruction,
    /// so the card shows `Lists files…`, not `"Lists files…"`. Only fires when the
    /// whole string is a SINGLE quote-wrapped span — if the interior still holds the
    /// same quote (e.g. a two-sentence reply that quoted each sentence:
    /// `"Lists files." "It only reads."`), the string wasn't simply wrapped, so it's
    /// left intact rather than mangled into `Lists files." "It only reads.`.
    private static func unwrapQuotes(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return s }
        let inner = s.dropFirst().dropLast()
        guard !inner.contains(first) else { return s }
        return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
