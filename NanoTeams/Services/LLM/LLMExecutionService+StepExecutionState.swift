import Foundation

// Per-step ephemeral execution state, extracted from the LLMExecutionService
// core (the class is split across 17+ focused files). A nested type so its
// qualified name (LLMExecutionService.StepExecutionState) is unchanged.
extension LLMExecutionService {

    // MARK: - Step Execution State

    /// Per-step execution context. Consolidates all ephemeral per-step state into one struct,
    /// eliminating the need for 7 parallel dictionaries. Entry exists iff step is executing.
    struct StepExecutionState {
        var runningTask: Task<Void, Never>?
        /// Index of the plan message in conversationMessages (for in-place update).
        var planMessageIndex: Int?
        /// Index of the Memories message in conversationMessages (for in-place update).
        var memoriesMessageIndex: Int?
        /// Memories version counter (increments on each update).
        var memoriesVersion: Int = 0
        /// The (base, model) residency key this step resolved its effective
        /// config to, set once after config resolution in `runStep`. Read by
        /// `LLMExecutionService.activeModelKeys()` so residency reconciliation
        /// never unloads a model a live step is using. Nil until resolved.
        var activeModelKey: String?

        /// Whether the context-window overflow warning already fired for this step.
        /// The banner is a single coalescing slot (`lastInfoMessage` / `lastErrorMessage`),
        /// and the condition is static across a step's iterations — re-posting it every
        /// iteration would clobber every other message the user needs to see.
        var didWarnContextOverflow: Bool = false
    /// The server's own `prompt_eval_count` on this step's previous request.
    ///
    /// The truncation detector needs a DELTA, not an absolute: a server that has started dropping
    /// the head stops growing this number even as the conversation grows. Comparing against our own
    /// token estimate instead was measured to be unusable — the estimator is 2.2× high on Cyrillic
    /// and 2.6× low on emoji, so no threshold survives both.
    var lastServerPromptTokens: Int?

        /// `"<normalizedBase>|<model>"` keys whose context-window probe this step has
        /// already spent.
        ///
        /// The service-wide memo only caches a REAL answer, because `/api/ps` reports
        /// nothing while the model is cold — caching that `nil` forever is what used to
        /// leave the overflow net permanently unarmed. This is the other half: it bounds
        /// the retry to once per step, so a server that genuinely never answers costs one
        /// round-trip per step rather than one per iteration.
        ///
        /// Keyed rather than a Bool so it can never mask the memo's own per-model
        /// keying — a step that resolves a different (server, model) is a different
        /// question and deserves its own probe.
        var probedContextKeys: Set<String> = []

        /// Where this step's conversation came from when it (re-)entered.
        ///
        /// Drives the prompt-prefix cache detector's first-request rule, which cannot simply be
        /// "exempt iteration 1": EVERY re-entry replay is also an iteration 1, and
        /// `.legacyConversation` is a documented guaranteed miss ("not byte-identical to what was
        /// sent, so the prefix cache will miss once") that is one of the most valuable things to
        /// report. `nil` = built fresh, i.e. a genuinely new step or a `restartRole` — inherent,
        /// never reported.
        var replaySource: ConversationReplay.Source?

        /// Whether the previous request in this step carried images. The single-use image strip
        /// nils them out AFTER sending, so the next request legitimately diverges at that
        /// message; without this the strip would be reported as a defect on every vision turn.
        var lastRequestCarriedImages: Bool = false

        /// Whether the prompt-prefix cache detector already fired for this step's CURRENT
        /// iteration boundary — set when the planning-phase boundary sliced the conversation, so
        /// the deliberate reset is not reported as a miss. One-shot: consumed by the next check.
        var expectedPrefixResetPending: Bool = false

        /// Whether Supervisor requested graceful finish (advisory roles).
        var finishRequested: Bool = false
        /// Whether the Autovisor manager requested an idle park (`wait_for_events`):
        /// the tool loop ends the pass by parking the step at `.needsSupervisorInput`
        /// with the wire transcript persisted, so a human message continues the SAME
        /// conversation on re-entry. Distinct from `finishRequested`
        /// (which completes the step) — and deliberately NOT routed through the
        /// `.supervisorQuestion` signal, whose autonomous-mode in-loop auto-answer
        /// would answer the park itself and defeat the wait.
        var parkForEventsRequested: Bool = false
        /// Question to park with when `parkForEventsRequested` fires. `nil` = the
        /// standard idle park. Set by the thinking-loop terminal so a loop-terminated
        /// pass is DISTINGUISHABLE from a healthy `wait_for_events` park:
        /// `taskHasIdleParkStep` matches `AutovisorConstants.idleParkQuestion` by exact
        /// equality and the sidebar gates the manager's attention badge on
        /// `!isIdleParked`, so reusing that text would make a loop break pixel-identical
        /// to a healthy idle — re-creating the invisibility this path exists to remove.
        var parkQuestionOverride: String?
        /// Count of consecutive "thinking drift" no-tool-call turns. A drift turn is one
        /// where the model emitted a long `thinking` trace (reasoning about the task)
        /// but no `content` and no tool calls. First drift → targeted nudge; second
        /// consecutive drift → escalate to supervisor.
        ///
        /// Reset on three paths so the counter can never carry stale state across
        /// productive activity:
        /// 1. Tool calls about to execute — the model is acting (`runOneLLMToolIteration`).
        /// 2. Non-drift no-tool-call turn (`handleNoToolCalls` else-branch) — the model
        ///    produced content even if no tool, so it's not silently reasoning.
        /// 3. After supervisor escalation — fresh start once the supervisor responds.
        /// Also cleared on `cleanup()`.
        var consecutiveDriftTurnCount: Int = 0

        /// Count of consecutive in-stream thinking-loop breaks for a TOP-LEVEL step.
        /// Drives `LoopRecoveryPolicy` (corrected retry until `maxThinkingLoopBreaks`,
        /// then a mode-aware terminal). Reset on ANY clean stream completion (the
        /// `thinkingLoopSignal == nil` path in `runOneLLMToolIteration`) — NOT via
        /// `resetCountersOnParseableToolCall`, which would miss clean no-tool turns —
        /// and on `cleanup()`.
        var consecutiveThinkingLoopBreaks: Int = 0

        /// Count of consecutive turns, by ANY role, that produced no productive activity.
        /// A turn is "non-productive" when it has (a) no tool calls at all, (b) tool calls
        /// consisting only of `ask_supervisor` — auto-answered in autonomous mode, so the
        /// model can ping itself in a loop without ever progressing — or (c) a batch whose
        /// every result came back an error (`ToolTurnProductivity`: emitting a call is not
        /// acting).
        ///
        /// Deliberately SHAPE-INDEPENDENT: incremented once per non-productive turn at the
        /// top of `handleNoToolCalls`, whatever the turn looked like. Every shape-specific
        /// cap above it (drift = 2, Harmony parse failure = 3) bounds ONE failure mode, so
        /// a model that varies how it fails slips past all of them. This counter is the
        /// only bound that doesn't care, and `maxToolIterations` is unlimited — nothing
        /// else is watching.
        ///
        /// Reset paths:
        /// 1. `cleanup()` — step teardown.
        /// 2. A `ToolTurnProductivity.productive` turn: at least one tool other than
        ///    `ask_supervisor` actually ran and returned a non-error result. Applied in
        ///    `runOneLLMToolIteration` AFTER the results are known — resetting on the mere
        ///    presence of a parsed call is what made an all-rejected batch re-arm the loop.
        /// 3. Inside EACH terminal branch of `noteNonProductiveTurn` — the manager's park,
        ///    the chat-advisory finish and the Supervisor escalation all zero it — so a
        ///    re-entry of the same step (e.g. via `restartRole`) starts clean.
        ///
        /// NOT incremented while the step is in revision: the Supervisor is already
        /// driving, so the loop this bounds cannot run away unobserved.
        var consecutiveNonProductiveTurns: Int = 0

        /// Count of consecutive turns where the model emitted a Harmony tool-call
        /// marker (`<|call|>…<|end|>`) but the JSON envelope failed to parse —
        /// classified as `.malformedJSON` by `ToolCallParsingHelpers`. Some models
        /// have stable per-payload defects (e.g. `qwen3.5-9b-mlx` consistently
        /// drops the closing escape on `onclick=\"appendOperator('-')\"` HTML
        /// attributes), and they reproduce the same broken JSON every retry. The
        /// generic retry nudge can't fix what the model can't see — we'd loop
        /// indefinitely until `delegate_to_team`'s 30-min timeout fires, surfacing
        /// only a wall of "Thinking" bubbles to the user.
        ///
        /// Reset paths (mirror `consecutiveDriftTurnCount`):
        /// 1. Tool calls about to execute — the model produced a parseable call
        ///    (`runOneLLMToolIteration` immediately before `executeToolCalls`).
        /// 2. Inside the supervisor-escalation branch itself, so a post-supervisor
        ///    restart starts clean.
        /// 3. `cleanup()`.
        ///
        /// Only `.malformedJSON` increments — `.missingToolName` is a different
        /// recoverable defect with its own targeted nudge that usually self-corrects
        /// on the next attempt.
        var consecutiveHarmonyParseFailureCount: Int = 0

        /// Most-recent computer-use screenshot for this step: the conversion metadata
        /// (region origin/size, pixel size) the `.click`/`.scroll` finalizers need, plus
        /// the base64 for the approval-card preview. In-memory only — never persisted.
        /// Legitimately per-step: a click's coordinates are only valid against the capture
        /// taken in the SAME step. (The first-capture-per-RUN gate counter lives per-TASK on the
        /// service — `computerUseCaptureCountByTask` — so it survives step/pause boundaries.)
        var lastComputerUseCapture: CapturedScreen?

        /// The (deduped) ax_elements advertised with `lastComputerUseCapture` — the click
        /// finalizer's containment echo resolves against this exact list so the echo can
        /// never contradict what the model was shown. Same lifecycle as the capture.
        var lastComputerUseElements: [AXElementInfo] = []

        /// UI-changing computer-use actions (click / type / key / scroll) executed since the
        /// last `screen_capture`. Zero right after a capture; > 0 means the saved screenshot,
        /// its element list, and the `element_at_point` echo may describe a UI that no longer
        /// exists — pointer results then carry `staleCaptureWarning` steering the model to
        /// re-capture instead of probing stale coordinates.
        var computerUseActionsSinceCapture: Int = 0

        /// In-flight detached tool-batch task spawned by `executeToolCalls`.
        /// Stored so cancellation reaches the synchronous handler chain
        /// (`ToolRuntime.executeAll` observes `Task.isCancelled` between calls;
        /// `ProcessRunner.run` does the same in its cooperative wait). Without
        /// the handle, `Task.detached` is unstructured and a paused run can't
        /// stop in-flight subprocesses or file I/O.
        var currentToolBatchTask: Task<[ToolExecutionResult], Never>?

        /// Clears everything that points INTO `conversationMessages`.
        ///
        /// Called when the planning→implementation boundary REPLACES that array,
        /// not just on teardown. The indices are absolute offsets, and
        /// `injectMemories` only guards `index < count` — a stale index that
        /// happens to remain in range would OVERWRITE the seed turn instead of
        /// appending. `didWarnContextOverflow` rides along because its
        /// once-per-step latch is justified by "the conversation only grows",
        /// and the boundary is the one place that makes it shrink: leaving the
        /// latch set would silence a real overflow later in the step.
        mutating func resetConversationIndices() {
            planMessageIndex = nil
            memoriesMessageIndex = nil
            memoriesVersion = 0
            didWarnContextOverflow = false
            // Same reasoning one level down: the implementation phase is a fresh
            // conversation, so it deserves a fresh chance to learn the window — by
            // then the model is warm and `/api/ps` can finally answer.
            probedContextKeys = []
        }

        /// Cancels the running task and resets all fields to defaults.
        mutating func cleanup() {
            runningTask?.cancel()
            runningTask = nil
            currentToolBatchTask?.cancel()
            currentToolBatchTask = nil
            resetConversationIndices()
            finishRequested = false
            parkForEventsRequested = false
            parkQuestionOverride = nil
            consecutiveDriftTurnCount = 0
            consecutiveThinkingLoopBreaks = 0
            consecutiveNonProductiveTurns = 0
            consecutiveHarmonyParseFailureCount = 0
            lastComputerUseCapture = nil
            lastComputerUseElements = []
            computerUseActionsSinceCapture = 0
        }
    }
}
