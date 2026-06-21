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
        /// Normalized body (version header stripped) of the last MEMORIES block
        /// injected in stateful mode — skip the append when unchanged (prior
        /// block is still in the server chain). Stored as a string rather than
        /// `hashValue` to eliminate the (small but silent) collision risk.
        var lastMemoriesFingerprint: String?
        /// Saved original system prompt (to restore after planning phase).
        var originalSystemPrompt: String?
        /// Whether this step has already received the planning→implementation transition.
        var planningTransitionDone: Bool = false
        /// Whether Supervisor requested graceful finish (advisory roles).
        var finishRequested: Bool = false
        /// Whether the Autovisor manager requested an idle park (`wait_for_events`):
        /// the tool loop ends the pass by parking the step at `.needsSupervisorInput`
        /// with the session preserved, so a human message continues the SAME
        /// conversation via stateful continuation. Distinct from `finishRequested`
        /// (which completes the step) — and deliberately NOT routed through the
        /// `.supervisorQuestion` signal, whose autonomous-mode in-loop auto-answer
        /// would answer the park itself and defeat the wait.
        var parkForEventsRequested: Bool = false
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
        /// Drives `LoopRecoveryPolicy` (stateless replay until `maxThinkingLoopBreaks`,
        /// then a mode-aware terminal). Reset on ANY clean stream completion (the
        /// `thinkingLoopSignal == nil` path in `runOneLLMToolIteration`) — NOT via
        /// `resetCountersOnParseableToolCall`, which would miss clean no-tool turns —
        /// and on `cleanup()`.
        var consecutiveThinkingLoopBreaks: Int = 0

        /// Count of consecutive turns by an advisory role (under autonomous supervisor
        /// mode) that produced no productive activity. A turn is "non-productive" when
        /// it has either (a) no tool calls at all, or (b) tool calls consisting only of
        /// `ask_supervisor` — since in autonomous mode that tool is auto-answered and
        /// thus the model can ping itself in a loop without ever progressing the work.
        ///
        /// Advisory roles have no `producesArtifacts` to terminate on, and autonomous
        /// mode has no human in the loop to escalate to. Without a cap, the role loops
        /// indefinitely.
        ///
        /// Reset paths:
        /// 1. `cleanup()` — step teardown.
        /// 2. A turn that contains at least one tool call other than `ask_supervisor`
        ///    (real productive work). A turn whose only tool is `ask_supervisor`
        ///    counts as non-productive (auto-answered by the supervisor service)
        ///    and routes through the same increment path as a no-tool turn.
        /// 3. Inside the auto-finish branch itself, so a re-entry of the same step
        ///    (e.g. via `restartRole`) starts clean.
        var consecutiveAdvisoryNoToolTurns: Int = 0

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

        /// In-flight detached tool-batch task spawned by `executeToolCalls`.
        /// Stored so cancellation reaches the synchronous handler chain
        /// (`ToolRuntime.executeAll` observes `Task.isCancelled` between calls;
        /// `ProcessRunner.run` does the same in its cooperative wait). Without
        /// the handle, `Task.detached` is unstructured and a paused run can't
        /// stop in-flight subprocesses or file I/O.
        var currentToolBatchTask: Task<[ToolExecutionResult], Never>?

        /// Cancels the running task and resets all fields to defaults.
        mutating func cleanup() {
            runningTask?.cancel()
            runningTask = nil
            currentToolBatchTask?.cancel()
            currentToolBatchTask = nil
            planMessageIndex = nil
            memoriesMessageIndex = nil
            memoriesVersion = 0
            lastMemoriesFingerprint = nil
            originalSystemPrompt = nil
            planningTransitionDone = false
            finishRequested = false
            parkForEventsRequested = false
            consecutiveDriftTurnCount = 0
            consecutiveThinkingLoopBreaks = 0
            consecutiveAdvisoryNoToolTurns = 0
            consecutiveHarmonyParseFailureCount = 0
        }
    }
}
