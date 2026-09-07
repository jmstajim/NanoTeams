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
    ///   - allowedToolNames: The tool ids this request's schema authorizes
    ///                 (`PlanningPhasePolicy.Authorization.allowed`). The nudge's
    ///                 "if you are blocked" clause names the escalation channel the
    ///                 runtime can DETECT — `wait_for_events` for the manager,
    ///                 `ask_supervisor` for a role that holds it — and is dropped
    ///                 for a role holding neither. No default, for the same reason as
    ///                 `canParkForSupervisor`: the set selects between three texts.
    static func decide(
        signal: LoopSignal,
        breakCount: Int,
        maxRetries: Int,
        supervisorMode: SupervisorMode,
        isChatMode: Bool,
        canParkForSupervisor: Bool,
        roleName: String,
        allowedToolNames: Set<String>
    ) -> Decision {
        if breakCount < maxRetries {
            return .retryWithNudge(nudge: nudgeText(
                signal: signal, attempt: breakCount, allowedToolNames: allowedToolNames))
        }
        switch supervisorMode {
        case .manual, .off:
            // Off removes `ask_supervisor` from the ROLE; this escalation is the app's
            // own and still waits for the human (see the `SupervisorMode` contract).
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
    /// a step that may still run for dozens of iterations. Names only a tool in
    /// `allowedToolNames` (see `blockedClause`): per-role toolsets differ, and steering
    /// toward one the role does not have earns a `tool_not_authorized` ping-pong. That is a
    /// property of the whole string, not just of this template — which is why nothing
    /// interpolated here may carry model-authored text; see `shapeClause` for the
    /// interpolation that used to, and what it cost.
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
    private static func nudgeText(
        signal: LoopSignal, attempt: Int, allowedToolNames: Set<String>
    ) -> String {
        let escalation = attempt >= 2
            ? " This has now happened \(attempt) times in a row. Do not restate the plan or "
            + "re-read anything: make the single smallest tool call that moves the work forward."
            : " Do not re-derive the reasoning it was part-way through — decide from what is "
            + "already in this conversation and continue with a tool call."
        return """
        \(MessageSourceContext.loopCorrectionBlockOpen)
        \(nudgePrefix)\(shapeClause(signal)) You were not shown it.\
        \(escalation)\(blockedClause(attempt: attempt, allowedToolNames: allowedToolNames))
        \(MessageSourceContext.loopCorrectionBlockClose)
        """
    }

    /// What a role that genuinely cannot move should DO — named as a tool call the runtime
    /// detects, or not named at all.
    ///
    /// Until 2026-09-06 both attempts ended by asking for one sentence of prose about the blocker.
    /// Nothing reads that sentence: a prose reply lands in `handleNoToolCalls`, which counts
    /// it as a non-productive turn and answers with the generic no-tool nudge — so the model
    /// that obeyed the correction was penalised for obeying it, and the sentence itself
    /// reached no one (playbook R3.8.6: name the channel the code detects). The clause is
    /// keyed on the SCHEMA rather than on team identity, exactly like `noToolCallNudge`:
    /// `wait_for_events` first because it identifies the Autovisor manager, whose Supervisor
    /// reads the chat and for whom "call ask_supervisor" would be the wrong channel; then
    /// `ask_supervisor`; and for a role holding neither the clause is dropped — an instruction
    /// to write prose is an instruction to make a non-productive turn.
    private static func blockedClause(attempt: Int, allowedToolNames: Set<String>) -> String {
        let channel = escalationChannel(in: allowedToolNames)
        if channel == ToolNames.waitForEvents {
            return " If nothing in this pass can move, call wait_for_events."
        }
        if channel == ToolNames.askSupervisor {
            return attempt >= 2
                ? " If nothing can move, call ask_supervisor with one sentence naming what is blocking you."
                : " If you genuinely cannot decide, call ask_supervisor with one sentence naming what is blocking you."
        }
        return ""
    }

    /// The tool a blocked role can escalate through, or `nil` when it holds none — the ONE
    /// answer every correction text composes its escalation clause from (R3.8.6).
    ///
    /// `wait_for_events` first: it identifies the Autovisor manager, which parks and is
    /// re-driven by events and never holds `ask_supervisor` (resolution step 8 strips it).
    /// Then `ask_supervisor` for any role that holds it. A role with neither has no
    /// escalation the runtime detects, so a text that tells it to "ask the Supervisor" or
    /// "report this" is an instruction to write prose nobody reads — the clause is dropped
    /// instead. Keyed on the schema, not on team identity, so a role gets the right channel
    /// however it acquired the tool.
    static func escalationChannel(in allowedToolNames: Set<String>) -> String? {
        if allowedToolNames.contains(ToolNames.waitForEvents) { return ToolNames.waitForEvents }
        if allowedToolNames.contains(ToolNames.askSupervisor) { return ToolNames.askSupervisor }
        return nil
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
        signal.modelFacingClause
    }

    /// The escalation question, on `shapeClause` rather than `diagnostic` + `scope`.
    ///
    /// The 2026-08-24 fix carved this out as a human-audience reader and left it
    /// interpolating both. The carve-out was wrong in two directions, and both are
    /// machine readers:
    ///
    ///  - `NTMSOrchestrator+AutovisorWake` matches on `stuckQuestionMarker` and wakes the
    ///    Autovisor on these questions — an LLM reads them.
    ///  - a question persisted as `step.supervisorQuestion` is replayed into the role's OWN
    ///    next request by `PromptBuilder` step 5, wrapped as its own `ask_supervisor` call;
    ///    under `SupervisorMode.autonomous` (which FAANG and Engineering ship with) the
    ///    ANSWER is written by an LLM that read it too.
    ///
    /// So all three harms `shapeClause` documents applied here as well — chief among them
    /// that `makeDiagnostic` quotes up to 80 characters of the repeated block verbatim, i.e.
    /// the loop is handed back to the looping model. The human audience is unaffected: the
    /// repeated turns are cards in the step's own feed.
    private static func stuckQuestion(signal: LoopSignal, roleName: String) -> String {
        """
        Role \(roleName) \(stuckQuestionMarker)\(shapeClause(signal)) \
        Advise how to proceed — clarify the task, give a concrete next step, or mark the step failed.
        """
    }
}
