import Foundation

/// One advisory verdict for a single `bash` command awaiting MANUAL approval.
/// Informational only — the human still decides. `id` is the command's position in
/// the (immutable, atomically-replaced) verdict list — a stable per-element id for
/// `ForEach` that never reorders.
nonisolated struct BashAdvice: Hashable, Sendable, Identifiable {
    let id: Int
    let command: String
    /// The judge's verdict under the current restriction level + sandbox.
    let allowed: Bool
    /// One-sentence rationale from the judge (or the fail-closed reason).
    let reason: String
    /// The "Ask AI" advisory from `BashExplainService`: what the command does plus
    /// an independent safety read. Empty when the explainer failed or returned
    /// nothing. Advisory only — never gates (the judge's verdict is authoritative).
    let explanation: String
}

/// On-demand advisory pass that runs the `bash` judge as an *advisor* over the
/// commands in a pending MANUAL approval, without affecting the gate. Each command
/// is judged independently (one verdict per command) under its own working
/// directory — the same `(command, workingDirectory, config)` inputs the real Auto
/// gate would feed the judge — so the advice matches what the configured judge
/// would conclude. Inherits `BashJudgeService`'s fail-closed semantics (a judge
/// error / uncertainty → `allowed == false` with a reason).
///
/// Alongside the verdict, each command gets an "Ask AI" advisory from
/// `BashExplainService` — what it DOES plus an independent safety read. A SEPARATE,
/// decoupled call that fails SOFT (empty on error); its safety read is advisory and
/// can never alter the gate verdict (which comes only from the judge).
///
/// PURE: reads only the inputs passed in, never the gate's pending-approval or
/// recorded-decision maps. The verdict is shown to the human; it does not consume
/// or pre-decide anything.
nonisolated enum BashAdviceService {
    static func advise(
        commands: [String],
        workingDirectories: [String?],
        policy: BashPolicy,
        config: LLMConfig,
        client: any LLMClient = LLMClientRouter(),
        logger: NetworkLogger? = nil
    ) async -> [BashAdvice] {
        var results: [BashAdvice] = []
        results.reserveCapacity(commands.count)
        for (index, command) in commands.enumerated() {
            // Cooperative cancellation: when the user taps Stop (or Allow/Deny removes
            // the card), the consuming Task is cancelled. `judge`/`explain` each swallow
            // CancellationError into a fail-closed / empty result, so the loop can't learn
            // of cancellation from them — check here so Stop actually stops issuing further
            // per-command calls instead of draining the whole batch.
            if Task.isCancelled { break }
            // Strictness Off: the configured judge approves everything without
            // review, so advice "identical to what Auto would conclude" (the
            // contract above) is a constant — return it without spending an LLM
            // round-trip. The explain pass is skipped too; the reason is
            // self-explanatory.
            if policy.restrictionLevel == .off {
                results.append(BashAdvice(
                    id: index, command: command, allowed: true,
                    reason: "Judge strictness is Off — every command is approved without review. Decide yourself.",
                    explanation: ""))
                continue
            }
            // Parallel array, defensively bounded: a length mismatch falls back to
            // the project root rather than crashing.
            let workingDirectory = index < workingDirectories.count ? workingDirectories[index] : nil
            // The verdict comes from the real gate judge (kept identical to what Auto
            // would conclude); the advisory is a SEPARATE, decoupled call — its
            // independent safety read can never alter the gate verdict.
            let verdict = await BashJudgeService.judge(
                command: command,
                workingDirectory: workingDirectory,
                policy: policy,
                config: config,
                client: client,
                logger: logger)
            let explanation = await BashExplainService.explain(
                command: command,
                workingDirectory: workingDirectory,
                policy: policy,
                config: config,
                client: client,
                logger: logger)
            results.append(BashAdvice(
                id: index, command: command, allowed: verdict.allowed,
                reason: verdict.reason, explanation: explanation))
        }
        return results
    }
}
