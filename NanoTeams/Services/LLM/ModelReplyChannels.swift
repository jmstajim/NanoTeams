import Foundation

/// Which channel of a one-shot LLM reply carries the answer.
///
/// A model returns text on TWO channels and the app sees them as two separate delta
/// streams. `contentDelta` is the visible reply; `thinkingDelta` is the reasoning
/// channel — and a reasoning model routinely puts its ENTIRE answer there and leaves
/// `content` empty. Nothing merges them on the way in and nothing can: `SSEEventParser`
/// maps LM Studio's `reasoning.delta` to `.thinkingDelta`, and Ollama's
/// `ThinkTagSplitter` actively pulls inline `<think>…</think>` OUT of content. So a
/// caller that accumulates only `contentDelta` does not see a degraded answer — it sees
/// no answer at all, and reports that as the model's fault.
///
/// The rule is three lines, which is exactly why it had five spellings and four
/// omissions before this type existed:
///
/// | site | before |
/// |---|---|
/// | `+TeammateConsultation` | correct, `clean(trim(x))` then select |
/// | `BashJudgeService` / `ComputerUseJudgeService` | correct, `whitespaceTrimmed(clean(x))` then select |
/// | `SupervisorAutoAnswerService` | correct since wave 20, `cleanHarmonyTokens` then select |
/// | `WorkFolderContextService` | reasoning dropped |
/// | `VisionAnalysisService` | reasoning dropped |
/// | `TeamGenerationService` | reasoning dropped |
/// | `DelegatedSupervisorAnswerService` | reasoning dropped |
/// | `MeetingStreamingService` | reasoning COLLECTED, then ignored by `completeTurn` |
///
/// The last row is the one that argues for a named seam rather than a fourth copy of
/// the idiom: that site had the value in hand and still answered with `""`, because
/// nothing said out loud what the pair is FOR.
nonisolated enum ModelReplyChannels {

    /// The usable answer from a one-shot reply: prepared `content` when it carries
    /// anything, otherwise prepared `reasoning`, otherwise `""`.
    ///
    /// - Parameter prepare: applied to each channel BEFORE the emptiness test, so a
    ///   channel holding nothing but model tokens or whitespace counts as empty and
    ///   correctly yields to the other one. Callers differ here on purpose — the judges
    ///   must trim with the same predicate their parser rejects on, the Supervisor
    ///   answer needs `cleanHarmonyTokens`' glued-keyword handling — and there is
    ///   deliberately **no default**: every spelling is silently wrong for somebody
    ///   else's call site, so the compiler asks.
    ///
    /// Content wins when both channels speak. The reasoning channel is a fallback, not
    /// a second source: a model that thinks out loud and then answers must not have its
    /// deliberation delivered as the decision.
    static func answer(
        content: String,
        reasoning: String,
        prepare: (String) -> String
    ) -> String {
        let preparedContent = prepare(content)
        if !preparedContent.isEmpty { return preparedContent }
        return prepare(reasoning)
    }
}
