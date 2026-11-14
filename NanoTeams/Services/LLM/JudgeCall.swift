import Foundation

/// The one-shot call every approval judge makes, once.
///
/// `BashJudgeService` and `ComputerUseJudgeService` each carried their own copy of this loop
/// until 2026-09-23 — the same two attempts, the same catch, the same channel policy — kept in
/// step by a comment ("same two-attempt shape as `BashJudgeService`"), and the computer-use
/// judge reached its transport through the bash judge's type. A third judge (MCP) would have
/// been a third copy. What stays with each judge is what differs: its prompt, the sentences its
/// `Decision` carries, and the noun its failures name.
///
/// Owns:
/// - the verdict config — `JudgeConfig.forVerdict`: temperature 0, then the judge's override;
/// - the transport (`collect`), both channels read whole;
/// - the two attempts. The second exists only for a reasoning-only `OK`
///   (`JudgeReplyChannelPolicy`), and a second such reply is `.reasoningOnlyAllow`;
/// - the throw → `.callFailed` mapping, with the classified message, so a transport error
///   reaches the model's denial envelope as stable English rather than the system language
///   (R1.8.2);
/// - cancellation → `.cancelled`, which no judge turns into a deny (see the case) — read before
///   each request as well as after it, so a stopped run sends none;
/// - the mapping of every outcome but a parsed reply onto a `JudgeRuling` (`ruling`), so the
///   runtime's arms are spelled once for every judge.
///
/// It does NOT build the opening turns. The system message is built where its text is
/// authored, in each judge's own file — which is also where `PromptFormatConventionsTests`'
/// census of one-shot system prompts looks for it.
nonisolated enum JudgeCall {

    /// What one judge call came to — before any judge maps it to a decision.
    enum Outcome: Hashable {
        /// A reply the judge answered with, read by `JudgeVerdictParser` — the visible reply,
        /// or a reasoning-only reply that is not an allow (every non-`OK` outcome denies).
        case parsed(JudgeVerdictParser.Outcome)
        /// The call threw before a verdict arrived. `message` is `ToolErrorHandler.classify`'s.
        case callFailed(message: String)
        /// The reasoning channel said `OK` on both attempts and the visible reply stayed empty:
        /// not a verdict.
        case reasoningOnlyAllow
        /// The task asking was cancelled — Pause, a work-folder switch, teardown — before a
        /// verdict it could act on. NOT a deny: nobody ruled (#152). Until 2026-09-23 this fell
        /// into the fail-closed arms — a stream ended by cancellation reads as an EMPTY reply,
        /// so "Judge returned no verdict; denied for safety." — and because
        /// `cancelStepExecution` awaits the step before clearing it, that refusal was written to
        /// the tool-call card, the replayed wire (under a do-not-retry direction) and
        /// `tool_calls.jsonl` (`JudgePauseLeavesNoDenialTests`).
        case cancelled
    }

    /// Runs the call. `opening` is the judge's system and user turns; the retry turn, when
    /// there is one, is appended here.
    static func run(
        opening: [ChatMessage],
        config: LLMConfig,
        override: LLMOverride?,
        client: any LLMClient,
        logger: NetworkLogger?
    ) async -> Outcome {
        var messages = opening
        let verdictConfig = JudgeConfig.forVerdict(config, override: override)
        // Strip the model's `<|…|>` tokens, then trim with the SAME predicate the parser uses
        // (`Character.isWhitespace`) and nothing else, so an invisible character the parser must
        // reject (a zero-width space padding the object) reaches it. `ModelTokenCleaner.clean`
        // would not do: it trims by Foundation's `.whitespacesAndNewlines`, which holds U+200B —
        // and both judges called it, under a comment claiming this very property, from
        // 2026-07-02 to 2026-09-23 (`JudgeCallTests`, the zero-width case).
        let prepare: (String) -> String = { JudgeVerdictParser.whitespaceTrimmed(ModelTokenCleaner.stripTokens($0)) }
        for attempt in 0..<2 {
            // Nothing is sent for a run that has stopped. A gate's batch can hold several calls
            // that need a verdict, and after a Pause cut the first judge short the rest arrive
            // here under the cancelled task — each one a request, and a `network_log.jsonl`
            // record, for a verdict no one would act on (`JudgeCallTests`, the already-cancelled
            // case).
            if Task.isCancelled { return .cancelled }
            let reply: (content: String, thinking: String)
            do {
                reply = try await collect(client: client, config: verdictConfig, messages: messages, logger: logger)
            } catch {
                if Task.isCancelled || CancellationClassifier.isCancellation(error) { return .cancelled }
                return .callFailed(message: ToolErrorHandler.classify(error).message)
            }
            // A cancelled consumer does not see a throw: `AsyncThrowingStream` ends its
            // iteration quietly, so what arrived so far is an empty or partial reply that the
            // parser would read as a deny — or, raced to the last byte, as a whole verdict for a
            // run that has already stopped. Neither is the judge's answer to this run.
            if Task.isCancelled { return .cancelled }
            switch JudgeReplyChannelPolicy.resolve(content: reply.content, reasoning: reply.thinking, prepare: prepare) {
            case .verdict(let source):
                return .parsed(JudgeVerdictParser.evaluate(source))
            case .reasoningOnlyAllow:
                if attempt == 0 {
                    messages.append(ChatMessage(role: .user, content: JudgeReplyChannelPolicy.retryInstruction))
                }
            }
        }
        return .reasoningOnlyAllow
    }

    /// The ruling a gate acts on. A parsed reply is read by `decide` — each judge its own
    /// default sentences and unparseable-reply reasons; every other outcome is the runtime's,
    /// and is the same for every judge but for the subject its failure names.
    static func ruling(
        _ outcome: Outcome,
        subject: JudgeFailClosedReason.Subject,
        decide: (JudgeVerdictParser.Outcome) -> JudgeDecision
    ) -> JudgeRuling {
        switch outcome {
        case .parsed(let reply):
            return .decided(decide(reply))
        case .callFailed(let message):
            return .decided(JudgeDecision(
                allowed: false, reason: JudgeFailClosedReason.callFailed(subject: subject, message: message)))
        case .reasoningOnlyAllow:
            return .decided(JudgeDecision(allowed: false, reason: JudgeReplyChannelPolicy.reasoningOnlyAllowReason))
        case .cancelled:
            return .cancelled
        }
    }

    /// One streamed call, both channels collected whole.
    static func collect(
        client: any LLMClient, config: LLMConfig, messages: [ChatMessage], logger: NetworkLogger?
    ) async throws -> (content: String, thinking: String) {
        var content = ""
        var thinking = ""
        // prefix-cache-owner: registered by the caller — each gate notes its judge as a
        // `.oneShot` through `askApprovalJudge` (`LLMExecutionService+BashGate` "bash judge",
        // `+ComputerUseGate` "computer-use judge"), `NTMSOrchestrator+BashAdvice` "bash advice",
        // before `run`; `collect` is its transport, called at most twice per verdict.
        let stream = client.streamChat(config: config, messages: messages, tools: [], logger: logger, stepID: nil)
        for try await event in stream {
            content += event.contentDelta
            thinking += event.thinkingDelta
        }
        return (content, thinking)
    }
}

/// A judge's ruling on one call: the model's verdict, or the runtime's fail-closed deny.
nonisolated struct JudgeDecision: Hashable, Sendable {
    let allowed: Bool
    let reason: String
}

/// What a judge answers the gate that asked it — a decision, or none at all because the run
/// stopped while it was being asked. The gate answers the second with the cancellation
/// envelope (`makeCancelledResult`), the twin of an abandoned human approval hold: the call
/// does not run, and nothing tells the model it was refused.
nonisolated enum JudgeRuling: Hashable, Sendable {
    case decided(JudgeDecision)
    case cancelled

    /// The decision, when there is one.
    var decision: JudgeDecision? {
        if case .decided(let decision) = self { return decision }
        return nil
    }
}
