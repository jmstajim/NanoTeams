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

    /// Seconds to wait between retries of a recoverable LLM error. Defaults to the
    /// product value (`LLMConstants.llmRetryDelaySeconds`); retry-loop tests set a
    /// small value so they don't pay the real backoff.
    var retryDelaySeconds: UInt64 = LLMConstants.llmRetryDelaySeconds

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


    // MARK: - Shared Utilities

    /// Latest task state from the delegate, with fallback to the passed snapshot.
    /// Called at iteration start so fields mutated by `delegate.mutateTask` in
    /// prior iterations (scratchpad, supervisor answer, role statuses) are visible.
    static func refreshedTaskSnapshot(_ task: NTMSTask, delegate: LLMExecutionDelegate) -> NTMSTask {
        delegate.loadedTask(task.id) ?? task
    }

    /// Resolves the team for a task. Pins a started run to its `Run.teamID`
    /// (see `TeamResolution.resolve`) — a deleted-mid-run team yields `nil`, never
    /// a silent swap to `activeTeam`.
    func resolveTeam(task: NTMSTask) -> Team? {
        let snapshot = delegate?.snapshot
        switch TeamResolution.resolve(
            task: task,
            teamProvider: { snapshot?.workFolder.team(withID: $0) },
            activeTeam: snapshot?.workFolder.activeTeam
        ) {
        case .resolved(let team):
            return team
        case .failed(let reason):
            delegate?.setLastErrorMessageForUI(reason)
            return nil
        case .noTeam:
            return nil
        }
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

    /// Builds a JSON `{"ok":false,…}` envelope for a failed attribution-bearing
    /// collaboration tool (consultation / meeting / change request). The card
    /// renders red and the LLM gets an honest failure signal — consistent with
    /// every other tool's error envelope. `envelopeStatus` reads the top-level `ok`.
    func buildCollaborationErrorResult(toolName: String, message: String) -> String {
        let dict: [String: Any] = ["ok": false, "tool": toolName, "error": ["message": message]]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return #"{"ok":false,"tool":"\#(toolName)","error":{"message":"(error)"}}"#
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

/// Outcome of an attribution-bearing collaboration handler (ask_teammate,
/// request_team_meeting, request_changes): the human-readable `text` rendered in
/// the consulted/initiating role's attribution bubble, tagged by outcome. The
/// dispatcher turns this into a single `{"ok":…}` envelope (green answer / red
/// failure) for both the LLM and the tool card. Modeled as an enum so the
/// success/failure states are mutually exclusive and unrepresentable-when-wrong
/// (no leaked memberwise init, no meaningless `(text, succeeded)` quadrants).
nonisolated enum CollaborationReply {
    case ok(String)
    case failed(String)

    /// Prose for the attribution bubble — the answer on success, the reason on failure.
    var text: String {
        switch self {
        case .ok(let t), .failed(let t): return t
        }
    }

    var succeeded: Bool {
        if case .ok = self { return true }
        return false
    }
}

