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
/// - `+Streaming.swift` — LLM streaming and post-stream processing
/// - `+StepLifecycle.swift` — Step execution setup and tool loop orchestration
/// - `+PlanningPhase.swift` — The @MainActor half of the planning phase
/// - `+StepFlowControl.swift` — No-tool-call handling and the escalation caps
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

    /// Probed context-window size per `"<normalizedBase>|<model>"`. Probing costs a network
    /// round-trip, the answer only changes when the user reloads the model with a different
    /// window, and the check runs on every iteration of every step — so it is memoized for
    /// the service's lifetime. A failed probe caches `nil` deliberately: a server that does
    /// not report a window will not start doing so mid-run, and retrying per iteration would
    /// add a round-trip to the hot path for an answer that never arrives.
    var probedContextLengths: [String: Int?] = [:]

    /// Held `bash` commands awaiting the human's in-loop Allow / Deny decision,
    /// keyed by (taskID, stepID) → command key → waiter. The gate's `await`
    /// registers one per held command; a button tap (via the orchestrator) or a
    /// Pause cancellation resolves it. The decision goes straight to the gate — the
    /// model is never asked to re-issue. See `LLMExecutionService+BashApproval`.
    var bashApprovalWaiters: [TaskStepKey: [String: BashApprovalWaiter]] = [:]

    /// The command a step is currently holding for approval — read by the on-demand
    /// "Ask AI" advisor (`requestBashJudgeAdvice`) so it can judge the exact held
    /// command. Populated only for the duration of `awaitBashApproval`.
    var pendingBashApprovals: [TaskStepKey: PendingBashApproval] = [:]

    /// Held computer-use actions awaiting the human's in-loop Allow / Deny / Always decision,
    /// keyed by (taskID, stepID) → action key → waiter. Mirror of `bashApprovalWaiters`.
    var computerUseApprovalWaiters: [TaskStepKey: [String: ComputerUseApprovalWaiter]] = [:]

    /// Per-run "always allow in this app" grants for computer-use, keyed by taskID → set of
    /// lowercased bundle ids / app names. Runtime only — never persisted (user chose per-run
    /// scope). Cleared per-TASK (`clearComputerUseTaskState`), never per-step, so an
    /// "always allow for the rest of the run" grant survives the granting role's step completing
    /// (and any parallel sibling role finishing).
    var computerUseSessionAllowedApps: [Int: Set<String>] = [:]

    /// Number of `screen_capture` calls made this run, keyed by taskID. Per-TASK (not per-step)
    /// so the "gate only the FIRST capture per run" prompt fires once per run, not once per role
    /// / once after every pause. Cleared alongside `computerUseSessionAllowedApps`.
    var computerUseCaptureCountByTask: [Int: Int] = [:]

    /// Remembers what each caller last sent to each `(server, model)` so a prompt-prefix (KV)
    /// cache miss can be detected and attributed.
    ///
    /// Lives here rather than in the clients because the clients' `streamChat` is implemented by
    /// 44 test doubles, and — more importantly — every interleaving caller that can plausibly
    /// evict a running step's prefix is issued from THIS service: the bash and computer-use
    /// judges, the Supervisor auto-answer, meeting turns, `ask_teammate` consultations and the
    /// delegated-Supervisor side exchange. One reference here sees all of them.
    ///
    /// **Owned per service, never process-global** (CLAUDE.md Swift Style #49). The init seam
    /// defaults to `nil` and resolves INWARD to a fresh ledger. Production builds exactly one
    /// orchestrator and therefore one service, so per-service scope IS process scope there —
    /// while the ~100 test sites that construct this service directly each get an isolated one.
    /// A `.shared` default instead leaked three pieces of order-dependent state across suites:
    /// the activity list that names suspects, the never-reset `prefillFloorNsPerToken` minimum,
    /// and the per-owner chains (keyed `base|model|step:taskID:stepID`, and test task ids and
    /// role ids collide by construction).
    ///
    /// A future recorder outside this service (Vision, team generation, work-folder context) must
    /// be HANDED this instance, not reach for a global.
    let prefixLedger: PromptPrefixLedger

    /// Auto-detected "can the main model see images?" verdicts, keyed by
    /// `"baseURL|model"`. Replaces the removed "Main model supports vision"
    /// Settings toggle. Only DEFINITIVE probe results are cached (a model's
    /// capabilities don't change while loaded); an undeterminable probe
    /// (server unreachable, no capability metadata) is NOT cached so a
    /// transient failure can't pin a wrong verdict for the service lifetime.
    var mainModelVisionCache: [String: Bool] = [:]

    /// Tears a step's bash-approval state down: resumes any pending waiter with
    /// `.deny` (fail safe) and drops the pending record. Called from every teardown
    /// path that removes the `executionStates` entry.
    func clearBashState(stepID: String, taskID: Int) {
        failPendingBashApprovals(stepID: stepID, taskID: taskID)
        pendingBashApprovals[TaskStepKey(taskID: taskID, stepID: stepID)] = nil
        // Computer-use PER-STEP teardown rides the same paths: fail any held approval (deny) so a
        // paused step never leaves a hung waiter. The per-run app allowlist + capture count are
        // per-TASK — cleared by `clearComputerUseTaskState`, NOT here (clearing them per-step
        // wiped an "always allow for the rest of the run" grant the moment any step finished).
        failPendingComputerUseApprovals(stepID: stepID, taskID: taskID)
    }

    /// Drops the per-TASK computer-use session state (the "always allow in app" grants and the
    /// first-capture-per-run counter) when a task's run ends — task pause/stop/switch and full
    /// teardown. Keyed by taskID; task IDs are reused across folders, so clearing here stops a
    /// grant leaking into a same-numbered task in a newly-opened folder.
    func clearComputerUseTaskState(taskID: Int) {
        computerUseSessionAllowedApps[taskID] = nil
        computerUseCaptureCountByTask[taskID] = nil
    }
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

    /// Clears the running task entry for a step. Also drops the step's
    /// active-model registration (see `activeModelKeys`) — the model it was
    /// using is no longer pinned by this step.
    func clearRunningTask(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        executionStates[key]?.cleanup()
        executionStates[key] = nil
        clearBashState(stepID: stepID, taskID: taskID)
    }

    /// Records the (base, model) a running step resolved its effective config
    /// to, so residency reconciliation can treat that exact model as in-use
    /// while the step runs. Set once in `runStep` after config resolution.
    ///
    /// This is a MODEL-SPECIFIC in-use signal, not the model-agnostic
    /// `hasLiveExecutions` c70ec54 deleted: it pins only the model a running
    /// step actually captured, so a step on model B never pins model A. It
    /// closes the census gap during tool-execution pauses — a long
    /// `run_xcodebuild` between iterations opens no chat request, so the
    /// census alone would let a foreign engine transition unload the model the
    /// step will reuse on its next iteration (a 30-60s reload, or a
    /// `model_load_failed` on a memory-tight box).
    func recordActiveModel(stepID: String, taskID: Int, config: LLMConfig) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        executionStates[key]?.activeModelKey = ChatModelEnsurer.residencyKey(
            model: config.modelName, base: config.baseURLString)
    }

    /// The (base, model) residency keys every live step is currently using.
    /// Consulted by `reconcileChatModelResidency` so an in-flight step's model
    /// is never reclaimed out from under it.
    func activeModelKeys() -> Set<String> {
        Set(executionStates.values.compactMap(\.activeModelKey))
    }

    /// Drop this step's prompt-prefix chain when its conversation is being built from SCRATCH.
    ///
    /// The ledger keys a step by `step:<taskID>:<stepID>` and `StepExecution.id` IS the role id,
    /// so that key survives every run of the task and every `restartRole` — while the
    /// conversation does not. Without this, request #1 of a brand-new conversation is compared
    /// against the PREVIOUS run's chain, and both outcomes are wrong: an opening that still
    /// matches reads as `.reused` (a short chain is a strict PREFIX of the long one, and
    /// `PrefixCachePolicy.compare` bounds at `min(previous.count, current.count)`), so the server
    /// signals get consulted for a conversation that has nothing to lose; an opening that moved —
    /// the Autovisor rewriting `## Current Memory` into its own system prompt between passes —
    /// reads as a full-size false `.systemPromptChanged`. Either way exemption 5 in
    /// `reportPrefixCacheMissIfAny`, written for exactly this case, can never fire.
    ///
    /// The condition is `replaySource == nil`, the fact `startStepExecution` already computes at
    /// the one place that knows it (`ConversationReplay.resume(from:) == nil`, documented there
    /// as "a genuinely fresh step"). A re-entry that REPLAYS keeps its chain: that replay is
    /// byte-identical to what the server already holds, so its `.reused` verdict is precisely
    /// what makes the server half of `resolve` meaningful across a long human pause.
    ///
    /// "Nothing to replay" is `Optional.none` and nothing else: `ConversationReplay.Source`
    /// used to carry an unreachable `.none` case alongside it, which made `Optional.none` and
    /// `Source.none` two different nothings one could be mistaken for the other. The case is
    /// gone, so the ambiguity is now unrepresentable rather than merely warned about.
    func forgetPrefixChainForFreshConversation(stepID: String, taskID: Int) async {
        // A missing entry means the step is torn down — the same write barrier every other
        // prefix-cache seam uses.
        guard let state = executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] else {
            return
        }
        guard state.replaySource == nil else { return }
        await prefixLedger.forgetOwner(.step(taskID: taskID, stepID: stepID))
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
        harmonyParser: HarmonyToolCallParser = HarmonyToolCallParser(),
        prefixLedger: PromptPrefixLedger? = nil
    ) {
        self.repository = repository
        self.artifactService = artifactService ?? ArtifactService(repository: repository)
        self.clientFactory = clientFactory
        self.harmonyParser = harmonyParser
        self.prefixLedger = prefixLedger ?? PromptPrefixLedger()
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
        clearBashState(stepID: stepID, taskID: taskID)
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
        bashApprovalWaiters.values.forEach { $0.values.forEach { $0.resolve(.deny) } }
        bashApprovalWaiters.removeAll()
        pendingBashApprovals.removeAll()
        // Same teardown for computer-use: resolve every held waiter with `.deny` (fail safe),
        // drop the per-run app grants + capture counts, and clear the published cards directly —
        // `executionStates.removeAll()` above bypasses the per-key `clearBashState`, so without
        // this a held action leaks a stale card into a newly-opened folder and an "always allow
        // in app" grant survives into a same-numbered task there.
        computerUseApprovalWaiters.values.forEach { $0.values.forEach { $0.resolve(.deny) } }
        computerUseApprovalWaiters.removeAll()
        computerUseSessionAllowedApps.removeAll()
        computerUseCaptureCountByTask.removeAll()
        // Drop the orchestrator's published cards too — resolving the waiters above
        // resumes the orphaned awaits which will each call `bashApprovalDidEnd`, but
        // that may run AFTER a newly-opened folder has rendered; clear directly so no
        // stale card can show (and, with task-ID reuse, be mis-attributed).
        delegate?.clearAllBashApprovalRequests()
        delegate?.clearAllComputerUseApprovalRequests()
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
            clearBashState(stepID: key.stepID, taskID: key.taskID)
            delegate?.clearStreamingPreview(stepID: key.stepID, taskID: key.taskID)
        }
        // The task's run is ending — drop its per-run computer-use grants + capture count so a
        // restart re-prompts and a same-numbered task in another folder can't inherit them.
        clearComputerUseTaskState(taskID: taskID)
    }

    /// Checks if a step is currently running.
    func isStepRunning(stepID: String, taskID: Int) -> Bool {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.runningTask != nil
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

