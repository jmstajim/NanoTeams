import Foundation

/// Pure, stateless policy for a TOP-LEVEL role whose stream was broken mid-flight
/// by a thinking loop: decide whether to retry with a correction, or take a
/// mode-aware terminal action. One exhaustive switch instead of ad-hoc branches on
/// diagnostic strings.
///
/// Delegated CHILD tasks are intentionally NOT modeled here — they fire the parent
/// interrupt directly via `DelegationLoopWatcher.noteStreamLoop` and never reach a
/// retry/terminal decision (the parent's awaiter owns the child's terminal state).
nonisolated enum LoopRecoveryPolicy {

    /// Terminal action when the retry budget is exhausted.
    enum TerminalDecision: Equatable {
        /// Pause and surface a question to the human Supervisor (manual mode).
        case escalateSupervisor(question: String)
        /// Park at `.needsSupervisorInput` carrying the loop diagnostic, via the
        /// step-lifecycle handoff so the wire transcript is persisted BEFORE the
        /// park is published. For an autonomous chat role that something will wake
        /// again (today: the Autovisor manager, woken by its recurrence and by
        /// event wakes) — a silent finish there is a false success that erases the
        /// pass and repeats on the next tick.
        case parkForSupervisor(question: String)
        /// End the step gracefully (autonomous chat-mode advisory → `.done` idle).
        /// Still correct for an autonomous chat role with no waker: parking one
        /// would strand it waiting on a human who was never told to expect a question.
        case finishGraceful
        /// Mark the step failed (autonomous non-chat).
        case failStep(message: String)
    }

    enum Decision: Equatable {
        /// Within retry budget: append `nudge` to the conversation and re-enter the
        /// tool loop.
        ///
        /// The nudge is the whole recovery. Before the transport went stateless
        /// (`d239183`) this arm cleared the server-side session, which forced the
        /// next request to be rebuilt and therefore DIFFERENT. With no session left
        /// to clear, a bare re-entry resends byte-identical bytes and re-enters the
        /// same loop — which is exactly how a real incident burned both attempts and
        /// silently ended an Autovisor pass. Perturbing the conversation is now the
        /// only thing that makes the retry a retry.
        case retryWithNudge(nudge: String)
        /// Retry budget exhausted: take a terminal action.
        case terminal(TerminalDecision)
    }

    /// Leading marker every nudge carries, so the persisted turn is identifiable
    /// after the fact (and greppable in `wireTranscript` / `network_log.json`).
    ///
    /// Anchored to the nudge's own POSITION ("just before this note"), never to the reader's
    /// present ("your previous turn"). `consecutiveThinkingLoopBreaks` resets on every clean
    /// stream, so a step can accumulate one of these per loop episode, and both providers are
    /// stateless with nothing pruning the conversation — every one of them stays on the wire for
    /// the rest of the step. A "your previous turn" phrasing is false the moment a second turn
    /// follows it; this phrasing stays true at any distance.
    static let nudgePrefix = "The turn immediately before this note was discarded: it repeated itself"

    /// Marker every `parkForSupervisor` question carries, so the orchestrator can tell a
    /// LOOP park from the Autovisor's healthy idle park (`AutovisorConstants.idleParkQuestion`)
    /// without re-deriving the wording. `NTMSOrchestrator.taskHasLoopParkStep` matches on it
    /// to roll back the attention baseline a looped-out pass never earned — so this string is
    /// a contract between the two, not decoration.
    static let stuckQuestionMarker = "appears stuck in a reasoning loop"

    /// - Parameters:
    ///   - breakCount: How many consecutive times THIS step's stream has been broken
    ///                 for a loop (1 on the first break).
    ///   - maxRetries: Retry budget (`LLMConstants.maxThinkingLoopBreaks`).
    ///   - canParkForSupervisor: Whether a park at `.needsSupervisorInput` will
    ///                 actually be woken again. Passed in rather than derived here so
    ///                 no team identity leaks into a pure policy type. No default:
    ///                 it selects between two different terminal behaviours, so a new
    ///                 caller must decide rather than inherit one silently.
    static func decide(
        signal: LoopSignal,
        breakCount: Int,
        maxRetries: Int,
        supervisorMode: SupervisorMode,
        isChatMode: Bool,
        canParkForSupervisor: Bool,
        roleName: String
    ) -> Decision {
        if breakCount < maxRetries {
            return .retryWithNudge(nudge: nudgeText(signal: signal, attempt: breakCount))
        }
        switch supervisorMode {
        case .manual:
            return .terminal(.escalateSupervisor(question: stuckQuestion(signal: signal, roleName: roleName)))
        case .autonomous:
            if isChatMode {
                return canParkForSupervisor
                    ? .terminal(.parkForSupervisor(question: stuckQuestion(signal: signal, roleName: roleName)))
                    : .terminal(.finishGraceful)
            }
            return .terminal(.failStep(
                message: "Reasoning loop detected (\(signal.scope)): \(signal.diagnostic). Step aborted after \(maxRetries) retry attempts."
            ))
        }
    }

    /// Deliberately scoped to the turn that was discarded, and free of open-ended
    /// style instructions. Both providers are stateless and the conversation is never
    /// pruned, so this turn rides the prefix of every remaining request of the step
    /// and is written into `wireTranscript` — an unbounded "be brief" here would bias
    /// a step that may still run for dozens of iterations. Names no tool: per-role
    /// toolsets differ, and steering toward one the role does not have earns a
    /// `tool_not_authorized` ping-pong. That is a property of the whole string, not just of
    /// this template — which is why nothing interpolated here may carry model-authored text;
    /// see `shapeClause` for the interpolation that used to, and what it cost.
    ///
    /// Every sentence is anchored to this note's own position rather than to the reader's
    /// present, because a step can accumulate one per loop episode (see `nudgePrefix`) and each
    /// one is then read again on every later request. Retiring the older copies was considered
    /// and rejected: retirement means rewriting an early index, which invalidates the server's
    /// KV prefix from that point — trading a recurring full re-prefill for ~115 saved tokens,
    /// in the one part of this codebase whose entire purpose is to keep that prefix intact.
    /// A note that stays TRUE at any distance costs nothing.
    ///
    /// - Parameter attempt: which consecutive break this is (1 = first). The retry
    ///   budget is spent on RE-SAMPLING, so each attempt must differ from the last or
    ///   it is not a retry at all. Nudges accumulate rather than being retired (see
    ///   the note above about the KV prefix), so a later attempt already carries more
    ///   text than the first — the escalation makes that difference say something.
    private static func nudgeText(signal: LoopSignal, attempt: Int) -> String {
        let escalation = attempt >= 2
            ? " This has now happened \(attempt) times in a row. Do not restate the plan or "
            + "re-read anything: make the single smallest tool call that moves the work forward, "
            + "or say in one sentence what is blocking you."
            : " Do not re-derive the reasoning it was part-way through — decide from what is "
            + "already in this conversation and continue with a tool call. If you genuinely "
            + "cannot decide, say in one sentence what is blocking you."
        return """
        \(MessageSourceContext.loopCorrectionBlockOpen)
        \(nudgePrefix)\(shapeClause(signal)) You were not shown it.\
        \(escalation)
        \(MessageSourceContext.loopCorrectionBlockClose)
        """
    }

    /// How the discarded turn repeated itself, derived from the signal's CASE.
    ///
    /// Deliberately NOT `signal.diagnostic` + `signal.scope`, which this used to interpolate.
    /// Both are written for a different audience — `diagnostic`'s own doc comment scopes it to
    /// "the paused envelope's `supervisor_message`", and `scope` mirrors the legacy
    /// `fireInterrupt` strings for the delegating parent — and both stay exactly as they are for
    /// those readers (`stuckQuestion`, the `failStep` message, `DelegationLoopWatcher`,
    /// `AutovisorStuckEvaluator`). Three things went wrong when the model read them instead:
    ///
    ///  - **the loop came back into the prompt.** `makeDiagnostic` quotes up to 80 characters of
    ///    the repeated block verbatim, cut wherever the slice lands — and nudges are never
    ///    retired (see the note above about the KV prefix), so that fragment rides the prefix of
    ///    every remaining request of the step. The one turn whose job is to break a repetition
    ///    was re-seeding it.
    ///  - **it named tools and paths.** A real correction shipped ``substring "'s call
    ///    `read_file` for `scripts/core/frame_diff.gd`…"`` — steering the role straight back at
    ///    what it had been looping on, and falsifying `nudgeText`'s own "names no tool" promise
    ///    from a value composed in another module.
    ///  - **it leaked `(within-message)`**, an internal classification label, into text the
    ///    model reads. No `handleNoToolCalls` nudge shows one.
    ///
    /// The repeat COUNT goes with them. It is recoverable only by widening `LoopSignal` (the
    /// structured `substring` / `repeatCount` are dropped at `LoopScanner`), and the note already
    /// carries one N — the attempt counter in `escalation`. Two different Ns in four lines read
    /// worse than none, and the audience that wants the exact figure is the human one, which
    /// still gets it.
    ///
    /// Exhaustive on purpose: a fourth detection shape must be given words here rather than
    /// silently inheriting another's.
    private static func shapeClause(_ signal: LoopSignal) -> String {
        switch signal {
        case .withinMessage:
            return " — the same block of text, several times in a row."
        case .acrossMessages:
            return " — restating content from its earlier turns almost verbatim."
        case .identicalToolCallSequence:
            return " — the same tool call with identical arguments, several times in a row."
        }
    }

    private static func stuckQuestion(signal: LoopSignal, roleName: String) -> String {
        """
        Role \(roleName) \(stuckQuestionMarker) (\(signal.scope)): \(signal.diagnostic). \
        Please advise how to proceed — clarify the task, give a concrete next step, or mark the step failed.
        """
    }
}
