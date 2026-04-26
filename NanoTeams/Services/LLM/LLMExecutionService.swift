import Foundation

/// Service responsible for executing LLM steps including streaming, tool iterations,
/// and step completion handling.
///
/// This class is split across multiple extension files:
/// - `+Streaming.swift` — LLM streaming, planning phase, post-stream processing
/// - `+StepLifecycle.swift` — Step execution setup and tool loop orchestration
/// - `+StepFlowControl.swift` — No-tool-call handling and planning phase management
/// - `+ToolExecution.swift` — Tool call authorization, caching, execution batch
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
        var taskID: Int
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

        /// Cancels the running task and resets all fields to defaults.
        mutating func cleanup() {
            runningTask?.cancel()
            runningTask = nil
            planMessageIndex = nil
            memoriesMessageIndex = nil
            memoriesVersion = 0
            lastMemoriesFingerprint = nil
            originalSystemPrompt = nil
            planningTransitionDone = false
            finishRequested = false
            consecutiveDriftTurnCount = 0
            consecutiveAdvisoryNoToolTurns = 0
        }
    }

    // MARK: - Properties

    weak var delegate: LLMExecutionDelegate?
    /// All per-step execution state. Keyed by stepID. Entry present iff step is executing.
    var executionStates: [String: StepExecutionState] = [:]
    let repository: any NTMSRepositoryProtocol
    let artifactService: ArtifactService
    let harmonyParser: HarmonyToolCallParser

    /// Clears the running task entry for a step.
    func clearRunningTask(stepID: String) {
        executionStates[stepID]?.cleanup()
        executionStates[stepID] = nil
    }

    /// Returns the taskID associated with a running step.
    func taskIDForStep(_ stepID: String) -> Int? {
        executionStates[stepID]?.taskID
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

    /// Cancels execution for a specific step.
    func cancelStepExecution(stepID: String) {
        executionStates[stepID]?.cleanup()
        executionStates[stepID] = nil
        delegate?.clearStreamingPreview(stepID: stepID)
    }

    /// Cancels all running step executions.
    func cancelAllExecutions() {
        for (stepID, var state) in executionStates {
            state.runningTask?.cancel()
            delegate?.clearStreamingPreview(stepID: stepID)
        }
        executionStates.removeAll()
    }

    /// Request graceful finish for an advisory role's step.
    /// The step will complete as `.needsAcceptance` at the next iteration boundary.
    func requestFinish(stepID: String) {
        executionStates[stepID]?.finishRequested = true
    }

    /// Cancels all running step executions for a specific task.
    func cancelExecutions(forTaskID taskID: Int) {
        let stepsToCancel = executionStates.filter { $0.value.taskID == taskID }.keys
        for stepID in stepsToCancel {
            executionStates[stepID]?.cleanup()
            executionStates[stepID] = nil
            delegate?.clearStreamingPreview(stepID: stepID)
        }
    }

    /// Checks if a step is currently running.
    func isStepRunning(stepID: String) -> Bool {
        executionStates[stepID]?.runningTask != nil
    }

    // MARK: - LLM Tool Iteration

    /// Run exactly one assistant generation + optional tool execution pass.
    ///
    /// This method orchestrates a single LLM iteration by delegating to focused methods:
    /// - `applyPlanningPhase` — manages first-iteration planning constraints
    /// - `performStreamingCall` — executes the LLM streaming call and collects tokens
    /// - `processStreamingResult` — appends messages and detects completion signals
    /// - `handleNoToolCalls` — handles missing tool calls (learning + retry)
    /// - `executeToolCalls` — executes tools with caching
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
        memory: ToolCallCache,
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
            roleForMessage: roleForMessage,
            tools: tools,
            step: step,
            memory: memory,
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
        if let taskID = taskIDForStep(stepID) {
            await injectQueuedSupervisorMessage(
                stepID: stepID,
                taskID: taskID,
                roleID: step.effectiveRoleID,
                iterationNumber: iterationNumber,
                session: session,
                conversationMessages: &conversationMessages
            )
        }

        // 2. Determine messages to send: if session is active, only new messages since last call
        let messagesToSend: [ChatMessage]
        if session != nil,
           let lastAssistantIdx = conversationMessages.lastIndex(where: { $0.role == .assistant }) {
            // Stateful: system messages + new messages after last assistant turn.
            // System messages are always included here; NativeLMStudioClient omits on continuations
            // (system_prompt persists in the response chain).
            let systemMessages = conversationMessages.filter { $0.role == .system }
            let newMessages = Array(conversationMessages[(lastAssistantIdx + 1)...]
                .filter { $0.role != .system })
            // Defense-in-depth: if no new user/tool message would be sent, the API rejects the
            // request with HTTP 400 ("input must not be an empty string"). Fall back to a fresh
            // stateless turn rather than firing a guaranteed-bad request.
            let hasNonEmptyContent = newMessages.contains { msg in
                let content = msg.content ?? ""
                return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || msg.imageContent?.isEmpty == false
            }
            if !hasNonEmptyContent {
                session = nil
                messagesToSend = conversationMessages
            } else {
                messagesToSend = systemMessages + newMessages
            }
        } else {
            messagesToSend = conversationMessages
        }

        // 2b. Stream LLM response
        let streamResult = try await performStreamingCall(
            stepID: stepID,
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

        // 3. Process streaming result (append messages, check completion signals)
        if let completionStop = await processStreamingResult(
            streamResult, stepID: stepID, conversationMessages: &conversationMessages)
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
                memory: memory,
                roleDefinition: roleDefinition,
                conversationMessages: &conversationMessages
            )
        }

        // 5. Execute tool calls (with caching + authorization)
        // Reset drift counter: the model is acting, not just reasoning.
        executionStates[stepID]?.consecutiveDriftTurnCount = 0
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
            if let stop = await attemptAdvisoryAutoFinish(stepID: stepID, roleDefinition: roleDefinition) {
                return stop
            }
        } else {
            executionStates[stepID]?.consecutiveAdvisoryNoToolTurns = 0
        }
        let allowedToolNames = Set(toolsForIteration.map(\.name))
        let batch = executeToolCalls(
            resolvedToolCalls: streamResult.resolvedToolCalls,
            allowedToolNames: allowedToolNames,
            runtime: runtime,
            memory: memory,
            task: task,
            runIndex: runIndex,
            roleID: step.effectiveRoleID
        )

        toolObserver?(streamResult.resolvedToolCalls, batch.results)

        // 6. Process tool results (teammate, meeting, scratchpad, errors, learning)
        let outcome = await processToolResults(
            resolvedToolCalls: streamResult.resolvedToolCalls,
            results: batch.results,
            stepID: stepID,
            roleForMessage: roleForMessage,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            assistantContent: streamResult.assistantContent,
            client: client,
            config: config,
            memory: memory,
            memoryStore: memoryStore,
            iterationNumber: iterationNumber,
            cachedIndices: batch.cachedIndices,
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
        if let artifactStop = checkArtifactCompleteness(stepID: stepID) {
            return artifactStop
        }

        // 8. Inject Memories (tag index + plan summary)
        await injectMemories(
            stepID: stepID,
            memoryStore: memoryStore,
            session: session,
            conversationMessages: &conversationMessages
        )

        // 9. Check for looping patterns
        await checkAndInjectLoopWarning(
            stepID: stepID,
            memory: memory,
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

    nonisolated deinit {}
}

