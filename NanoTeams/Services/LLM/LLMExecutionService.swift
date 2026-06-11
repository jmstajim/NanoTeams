import Foundation

/// Thread-safe once-flag used by `LLMExecutionService.awaitTaskWithTimeout` to ensure
/// the continuation resumes exactly once even when both racing child tasks complete.
nonisolated final class OnceResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func tryResolve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }
}

/// Service responsible for executing LLM steps including streaming, tool iterations,
/// and step completion handling.
///
/// This class is split across multiple extension files:
/// - `+Streaming.swift` — LLM streaming, planning phase, post-stream processing
/// - `+StepLifecycle.swift` — Step execution setup and tool loop orchestration
/// - `+StepFlowControl.swift` — No-tool-call handling and planning phase management
/// - `+ToolExecution.swift` — Tool call authorization, identical-write rejection, runtime dispatch
/// - `+ToolResultProcessing.swift` — Tool result orchestration (iterates, dispatches)
/// - `+ToolResultDispatching.swift` — Collaboration signal routing + regular tool dispatch
/// - `+ToolResultSideEffects.swift` — Scratchpad, artifact persistence, event recording
/// - `+ToolLoopState.swift` — Memories injection, loop detection, Supervisor auto-answer
/// - `+StepCompletion.swift` — Step completion and artifact completeness check
/// - `+ConversationManagement.swift` — Message building and persistence
/// - `+TaskStateMutations.swift` — Tool call recording, scratchpad, Supervisor auto-answer
/// - `+ConsultationChat.swift` — Per-role consultation chat management
/// - `+TeammateConsultation.swift` — ask_teammate handling
/// - `+TeamMeeting.swift` — request_team_meeting handling + meeting record persistence
/// - `+ChangeRequest.swift` — request_changes handling
/// - `+ToolResolution.swift` — buildEffectiveConfig, preflightCheck, toolSchemas
///
/// Extracted helpers (stateless enums):
/// - `ConversationRepairService` — Conversation repair + Harmony token cleaning
/// - `MeetingCoordinator` — Meeting turn messages + tool filtering
/// - `MeetingStreamingService` — Meeting LLM streaming + speaker selection
@MainActor
final class LLMExecutionService {

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

    // MARK: - Properties

    weak var delegate: LLMExecutionDelegate?
    /// All per-step execution state. Keyed by (taskID, stepID) — stepID alone is NOT
    /// unique across tasks (it equals the team role ID), so two concurrent tasks on the
    /// same team would otherwise evict/cross-write each other's entries (see TaskStepKey).
    /// Entry present iff step is executing.
    var executionStates: [TaskStepKey: StepExecutionState] = [:]
    /// Team IDs for which we have already surfaced the "designated coordinator
    /// no longer exists" info message. Throttles
    /// `reportOrphanCoordinatorIfNeeded` to one notification per team per
    /// service lifetime so the banner doesn't spam on every meeting.
    var orphanCoordinatorReportedTeams: Set<NTMSID> = []
    let repository: any NTMSRepositoryProtocol
    let artifactService: ArtifactService
    let harmonyParser: HarmonyToolCallParser

    /// True while the (taskID, stepID) execution is still registered.
    ///
    /// This is the post-teardown WRITE BARRIER that the deleted `taskIDForStep`
    /// guard used to provide implicitly: once a teardown path removes the
    /// executionStates entry (`cancelExecutions(forTaskID:)`, `cancelAllExecutions`,
    /// or `cancelStepExecution`'s bounded-timeout escape), any late write from the
    /// cooperatively-cancelled task's catch handlers must be DROPPED — otherwise
    /// orphaned mutations land on whatever currently answers to the captured
    /// taskID (a fresh run after a recurrence supersede, or even a same-numbered
    /// task in a newly opened work folder). `cancelStepExecution`'s normal path
    /// removes the entry only AFTER awaiting the catch handler, so legitimate
    /// partial-content commits pass this gate.
    func isExecutionLive(stepID: String, taskID: Int) -> Bool {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] != nil
    }

    /// Clears the running task entry for a step.
    func clearRunningTask(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        executionStates[key]?.cleanup()
        executionStates[key] = nil
    }

    /// Centralized reset for retry-cap counters that fire when the model produced a
    /// parseable tool call (the "drift" / "malformed-JSON" streaks are broken).
    /// Called from `runOneLLMToolIteration` immediately before `executeToolCalls`.
    /// Centralized so a refactor that accidentally drops one of the resets in the
    /// inline path is caught by tests targeting this function.
    func resetCountersOnParseableToolCall(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        executionStates[key]?.consecutiveDriftTurnCount = 0
        executionStates[key]?.consecutiveHarmonyParseFailureCount = 0
    }

    /// Resets the consecutive thinking-loop-break counter. Called from
    /// `runOneLLMToolIteration` on any clean stream completion (no
    /// `thinkingLoopSignal`) — the budget counts *consecutive* breaks, so a
    /// healthy turn between two breaks must clear it. Deliberately separate from
    /// `resetCountersOnParseableToolCall`: a clean *no-tool* turn (which never
    /// reaches that reset) must still clear the loop counter. Named so a refactor
    /// dropping the reset is caught by the helper that delegates here.
    func resetThinkingLoopBreakCount(stepID: String, taskID: Int) {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.consecutiveThinkingLoopBreaks = 0
    }

    // MARK: - Initialization

    /// Factory for creating LLM clients. Defaults to `LLMClientRouter()`.
    /// Inject a custom factory for testing.
    let clientFactory: @Sendable () -> any LLMClient

    init(
        repository: any NTMSRepositoryProtocol,
        artifactService: ArtifactService? = nil,
        clientFactory: @escaping @Sendable () -> any LLMClient = { LLMClientRouter() },
        harmonyParser: HarmonyToolCallParser = HarmonyToolCallParser()
    ) {
        self.repository = repository
        self.artifactService = artifactService ?? ArtifactService(repository: repository)
        self.clientFactory = clientFactory
        self.harmonyParser = harmonyParser
    }

    func attach(delegate: LLMExecutionDelegate) {
        self.delegate = delegate
    }

    // MARK: - Public API

    /// Cancels execution for a specific step of a specific task. Async because we wait
    /// for the cancelled task's catch handler to run — that's where partial streaming
    /// content is committed (via `commitStreamingContent` → `delegate.commitStreaming`)
    /// and token usage is persisted (via `persistTokenUsage`).
    ///
    /// The wait is bounded by `LLMConstants.cancelHandlerTimeoutSeconds`. If the catch
    /// handler stalls (e.g. blocked disk I/O during `persistTokenUsage`), we surface a
    /// banner and proceed to teardown so the user isn't permanently frozen on Pause —
    /// the orphan task keeps running, but every late write it attempts is dropped by
    /// the `isExecutionLive` barrier (its executionStates entry is gone), so partial
    /// content from a timed-out cancel is lost rather than mis-targeted.
    func cancelStepExecution(stepID: String, taskID: Int) async {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let runningTask = executionStates[key]?.runningTask
        runningTask?.cancel()
        if let runningTask {
            let finished = await Self.awaitTaskWithTimeout(
                runningTask, seconds: LLMConstants.cancelHandlerTimeoutSeconds)
            if !finished {
                delegate?.setLastErrorMessageForUI(
                    "Pause: cancellation handler timed out after \(Int(LLMConstants.cancelHandlerTimeoutSeconds))s — partial content may not be persisted."
                )
            }
        }
        executionStates[key] = nil
        delegate?.clearStreamingPreview(stepID: stepID, taskID: taskID)
    }

    /// Races `task.value` against a sleep timeout, returning `true` if the task finished
    /// first. `Task<Void, Never>.value` doesn't honor cancellation propagation, so we use
    /// a once-resolver to ensure the continuation resumes exactly once even when both
    /// child tasks eventually complete.
    nonisolated static func awaitTaskWithTimeout(
        _ task: Task<Void, Never>,
        seconds: TimeInterval
    ) async -> Bool {
        let resolver = OnceResolver()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            Task {
                await task.value
                if resolver.tryResolve() {
                    cont.resume(returning: true)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if resolver.tryResolve() {
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// Cancels all running step executions.
    func cancelAllExecutions() {
        for (key, state) in executionStates {
            state.runningTask?.cancel()
            state.currentToolBatchTask?.cancel()
            delegate?.clearStreamingPreview(stepID: key.stepID, taskID: key.taskID)
        }
        executionStates.removeAll()
    }

    /// Request graceful finish for an advisory role's step. At the next iteration
    /// boundary the step completes via `finishStepGraceful`: chat-mode teams finish
    /// directly as `.done`; other teams complete as `.needsAcceptance`.
    func requestFinish(stepID: String, taskID: Int) {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.finishRequested = true
    }

    /// Cancels all running step executions for a specific task.
    func cancelExecutions(forTaskID taskID: Int) {
        let keysToCancel = executionStates.keys.filter { $0.taskID == taskID }
        for key in keysToCancel {
            executionStates[key]?.cleanup()
            executionStates[key] = nil
            delegate?.clearStreamingPreview(stepID: key.stepID, taskID: key.taskID)
        }
    }

    /// Checks if a step is currently running.
    func isStepRunning(stepID: String, taskID: Int) -> Bool {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.runningTask != nil
    }

    // MARK: - Stateful continuation slice

    /// Computes the message slice to send on a stateful (`previous_response_id`) continuation.
    ///
    /// In stateful mode the server already holds every prior turn, so we send only the
    /// messages AFTER the last assistant turn (plus system messages, which
    /// `NativeLMStudioClient` omits on continuations — they persist in the chain). If that
    /// slice has no non-empty user/tool content (which would make the API reject the request
    /// with HTTP 400 "input must not be an empty string"), `fallBackToStateless` is `true` so
    /// the caller clears the session and resends the full conversation.
    ///
    /// Pure and `nonisolated` so `LLMSliceAnchorTests` exercises the REAL slice rather than a
    /// replicated copy (the prior drift risk). Anchoring on `lastIndex(where: .assistant)` is
    /// why every model turn must advance an assistant anchor — see `processStreamingResult`.
    nonisolated static func statefulContinuationSlice(
        conversationMessages: [ChatMessage], isStateful: Bool
    ) -> (messages: [ChatMessage], fallBackToStateless: Bool) {
        guard isStateful,
              let lastAssistantIdx = conversationMessages.lastIndex(where: { $0.role == .assistant })
        else {
            return (conversationMessages, false)
        }
        let systemMessages = conversationMessages.filter { $0.role == .system }
        let newMessages = Array(conversationMessages[(lastAssistantIdx + 1)...]
            .filter { $0.role != .system })
        let hasNonEmptyContent = newMessages.contains { msg in
            let content = msg.content ?? ""
            return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || msg.imageContent?.isEmpty == false
        }
        if !hasNonEmptyContent {
            return (conversationMessages, true)
        }
        return (systemMessages + newMessages, false)
    }

    // MARK: - LLM Tool Iteration

    /// Run exactly one assistant generation + optional tool execution pass.
    ///
    /// This method orchestrates a single LLM iteration by delegating to focused methods:
    /// - `applyPlanningPhase` — manages first-iteration planning constraints
    /// - `performStreamingCall` — executes the LLM streaming call and collects tokens
    /// - `processStreamingResult` — appends messages and detects completion signals
    /// - `handleNoToolCalls` — handles missing tool calls (learning + retry)
    /// - `executeToolCalls` — executes tools through `ToolRuntime`
    /// - `processToolResults` — processes results (teammate, meeting, scratchpad, errors)
    /// - `handleSupervisorAutoAnswer` — auto-answers Supervisor questions in autonomous mode
    /// - `injectMemories` — keeps the LLM oriented with tag index and plan context
    /// - `checkAndInjectLoopWarning` — detects and warns about looping patterns
    func runOneLLMToolIteration(
        stepID: String,
        roleForMessage: Role,
        client: any LLMClient,
        config: LLMConfig,
        tools: [ToolSchema],
        runtime: ToolRuntime,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        supervisorMode: SupervisorMode,
        conversationMessages: inout [ChatMessage],
        tracker: ToolCallTracker,
        memoryStore: MemoryTagStore,
        iterationNumber: Int,
        session: inout LLMSession?,
        cumulativeUsage: inout TokenUsage,
        networkLogger: NetworkLogger? = nil,
        toolObserver: (([StepToolCall], [ToolExecutionResult]) -> Void)? = nil
    ) async throws -> LLMStepStop {
        guard let delegate else { return .toolFailure(message: "Delegate not available") }

        // Refresh the task snapshot so every downstream read this iteration sees
        // the state just committed through `delegate.mutateTask`.
        let task = Self.refreshedTaskSnapshot(task, delegate: delegate)
        let resolvedTeam = resolveTeam(task: task)
        let step = task.runs[runIndex].steps[stepIndex]
        let roleDefinition = resolvedTeam?.findRole(byIdentifier: step.effectiveRoleID)

        // 2. Apply planning phase (first iteration only)
        let (toolsForIteration, resetSession) = await applyPlanningPhase(
            stepID: stepID,
            taskID: task.id,
            roleForMessage: roleForMessage,
            tools: tools,
            step: step,
            tracker: tracker,
            conversationMessages: &conversationMessages,
            roleDefinition: roleDefinition
        )
        // After planning→implementation transition, the system prompt changed.
        // Clear session so the next call sends the full original prompt in a fresh chain
        // (NativeLMStudioClient omits system_prompt on stateful continuations).
        if resetSession { session = nil }

        // 2a. Consume any queued Supervisor message targeted at this role (or the
        // untargeted Team queue). Appends a user turn to `conversationMessages`
        // for this iteration's request. Skipped on iteration-1 continuation paths
        // (see `injectQueuedSupervisorMessage` for the stateful-chain rationale).
        if isExecutionLive(stepID: stepID, taskID: task.id) {
            await injectQueuedSupervisorMessage(
                stepID: stepID,
                taskID: task.id,
                roleID: step.effectiveRoleID,
                iterationNumber: iterationNumber,
                session: session,
                conversationMessages: &conversationMessages
            )
        }

        // 2. Determine messages to send: on a stateful continuation, only the new messages
        // since the last call (the empty-slice case falls back to a fresh stateless turn).
        let slice = Self.statefulContinuationSlice(
            conversationMessages: conversationMessages, isStateful: session != nil)
        if slice.fallBackToStateless { session = nil }
        let messagesToSend = slice.messages

        // 2b. Stream LLM response
        let streamResult = try await performStreamingCall(
            stepID: stepID,
            taskID: task.id,
            roleForMessage: roleForMessage,
            client: client,
            config: config,
            tools: toolsForIteration,
            conversationMessages: messagesToSend,
            session: session,
            networkLogger: networkLogger,
            roleName: roleForMessage.displayName.isEmpty ? nil : roleForMessage.displayName
        )

        // Update session and accumulate token usage
        if let newSession = streamResult.session {
            session = newSession
        }
        if let usage = streamResult.tokenUsage { cumulativeUsage.accumulate(usage) }

        // 2c. Top-level thinking-loop break: the stream was aborted + the looping
        // generation discarded (no anchor in `conversationMessages`, nothing in
        // `step.messages`). Recover via `LoopRecoveryPolicy` — clean retry or a
        // mode-aware terminal — BEFORE `processStreamingResult`. Any clean stream
        // completion (no signal) resets the consecutive-break counter.
        if let loopSignal = streamResult.thinkingLoopSignal {
            return await handleStreamLoopBreak(
                stepID: stepID, signal: loopSignal, task: task,
                roleForMessage: roleForMessage, supervisorMode: supervisorMode,
                session: &session)
        }
        resetThinkingLoopBreakCount(stepID: stepID, taskID: task.id)

        // 3. Process streaming result (append messages, check completion signals)
        if let completionStop = await processStreamingResult(
            streamResult, stepID: stepID, taskID: task.id,
            conversationMessages: &conversationMessages)
        {
            return completionStop
        }

        // 4. If no tool calls, handle accordingly
        if streamResult.resolvedToolCalls.isEmpty {
            return await handleNoToolCalls(
                stepID: stepID,
                result: streamResult,
                roleForMessage: roleForMessage,
                task: task,
                runIndex: runIndex,
                stepIndex: stepIndex,
                tracker: tracker,
                roleDefinition: roleDefinition,
                conversationMessages: &conversationMessages
            )
        }

        // 5. Execute tool calls (authorization + identical-write guard)
        // Reset drift + Harmony parse-failure counters: the model is acting and
        // produced a parseable tool call. Centralized so a refactor that drops
        // the call here is also detected by `LLMExecutionServiceParseFailureCapTests`
        // (regression: T1 — the helper-only reset was not exercising this prod path).
        resetCountersOnParseableToolCall(stepID: stepID, taskID: task.id)
        // Reset advisory no-tool-call counter only when at least one tool call is
        // *productive*. `ask_supervisor` doesn't qualify under autonomous supervisor
        // mode — it gets auto-answered, and the model can ping itself in a loop with
        // it forever without doing any real work. So a turn whose only tool calls are
        // `ask_supervisor` is treated the same as a no-tool-call turn for the purposes
        // of the advisory auto-finish safeguard (incremented in `handleNoToolCalls`).
        let toolNamesThisTurn = Set(streamResult.resolvedToolCalls.map(\.name))
        let isAskSupervisorOnly = toolNamesThisTurn == [ToolNames.askSupervisor]
        if isAskSupervisorOnly {
            // Non-productive turn: ask_supervisor gets auto-answered in autonomous mode,
            // so the model can ping itself in a loop with it forever. Treat it as a
            // no-tool-call turn for the advisory auto-finish counter.
            if let stop = await attemptAdvisoryAutoFinish(
                stepID: stepID, taskID: task.id, roleDefinition: roleDefinition)
            {
                return stop
            }
        } else {
            executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?
                .consecutiveAdvisoryNoToolTurns = 0
        }
        let allowedToolNames = Set(toolsForIteration.map(\.name))
        let toolResults = await executeToolCalls(
            resolvedToolCalls: streamResult.resolvedToolCalls,
            allowedToolNames: allowedToolNames,
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: runIndex,
            roleID: step.effectiveRoleID
        )

        toolObserver?(streamResult.resolvedToolCalls, toolResults)

        // 6. Process tool results (teammate, meeting, scratchpad, errors, learning)
        let outcome = await processToolResults(
            resolvedToolCalls: streamResult.resolvedToolCalls,
            results: toolResults,
            stepID: stepID,
            roleForMessage: roleForMessage,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            assistantContent: streamResult.assistantContent,
            client: client,
            config: config,
            tracker: tracker,
            memoryStore: memoryStore,
            iterationNumber: iterationNumber,
            conversationMessages: &conversationMessages,
            networkLogger: networkLogger
        )

        // 6b. Handle Supervisor question BEFORE artifact completeness — if the LLM both
        // completed all artifacts AND asked a supervisor question in one batch, the question
        // must not be silently dropped.
        if let autoAnswerStop = await handleSupervisorAutoAnswer(
            outcome: outcome,
            stepID: stepID,
            supervisorMode: supervisorMode,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            client: client,
            config: config,
            conversationMessages: &conversationMessages
        ) {
            return autoAnswerStop
        }

        if outcome.shouldStopForSupervisor, let q = outcome.supervisorQuestion {
            return .needsSupervisorInput(question: q)
        }

        // 7. Check if all expected artifacts have been created → auto-complete
        if let artifactStop = checkArtifactCompleteness(stepID: stepID, taskID: task.id) {
            return artifactStop
        }

        // 8. Inject Memories (tag index + plan summary)
        await injectMemories(
            stepID: stepID,
            taskID: task.id,
            memoryStore: memoryStore,
            session: session,
            conversationMessages: &conversationMessages
        )

        // 9. Check for looping patterns
        await checkAndInjectLoopWarning(
            stepID: stepID,
            taskID: task.id,
            tracker: tracker,
            conversationMessages: &conversationMessages
        )

        return .continueLoop
    }

    // MARK: - Shared Utilities

    /// Latest task state from the delegate, with fallback to the passed snapshot.
    /// Called at iteration start so fields mutated by `delegate.mutateTask` in
    /// prior iterations (scratchpad, supervisor answer, role statuses) are visible.
    static func refreshedTaskSnapshot(_ task: NTMSTask, delegate: LLMExecutionDelegate) -> NTMSTask {
        delegate.loadedTask(task.id) ?? task
    }

    /// Resolves the team for a task (prefers preferredTeamID, falls back to activeTeam).
    func resolveTeam(task: NTMSTask) -> Team? {
        if let generated = task.generatedTeam {
            return generated
        }
        if let preferredTeamID = task.preferredTeamID,
           let team = delegate?.snapshot?.workFolder.team(withID: preferredTeamID)
        {
            return team
        }
        return delegate?.snapshot?.workFolder.activeTeam
    }

    /// Builds a JSON tool result containing the actual collaboration response.
    func buildCollaborationToolResult(toolName: String, response: String) -> String {
        let dict: [String: Any] = ["ok": true, "tool": toolName, "response": response]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return #"{"ok":true,"tool":"\#(toolName)","response":"(response available)"}"#
    }

    /// Parses the top-level `ok` field of a tool envelope JSON string into a
    /// three-state result. Used to reflect deferred collaboration-handler
    /// outcomes (delegation, teammate, meeting, change request) onto the
    /// persisted `StepToolCall.isError` so the activity-feed card renders red
    /// on failure instead of the green ✓ from the placeholder result.
    ///
    /// Three states are distinct on purpose:
    /// - `.success` on `{"ok": true, ...}` — leave placeholder as-is.
    /// - `.failure` on `{"ok": false, ...}` — caller flips `isError = true`.
    /// - `.indeterminate` on malformed JSON, missing `ok` field, non-Bool
    ///   `ok`, or non-object root — treat as success (no UI change). Every
    ///   collaboration handler routes through `Tools+Envelope.makeSuccessResult`
    ///   / `makeErrorResult`, so an unreadable envelope means a parser miss,
    ///   never a real operation failure.
    ///
    /// Caller pattern: `if envelopeStatus(response) == .failure { ... }`.
    /// A bare `if !envelopeStatus(...).isSuccess` would mis-classify
    /// `.indeterminate` as failure — use explicit `== .failure` checks.
    func envelopeStatus(_ json: String) -> EnvelopeStatus {
        guard let data = json.data(using: .utf8) else { return .indeterminate }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return .indeterminate }
        guard let dict = parsed as? [String: Any] else { return .indeterminate }
        guard let ok = dict["ok"] as? Bool else { return .indeterminate }
        return ok ? .success : .failure
    }

    nonisolated deinit {}
}

/// Three-state outcome of `LLMExecutionService.envelopeStatus(_:)`. See that
/// method for semantics. Defined at file scope so test fixtures and the
/// dispatcher can pattern-match without re-stating the cases.
enum EnvelopeStatus: Hashable {
    case success
    case failure
    case indeterminate
}

