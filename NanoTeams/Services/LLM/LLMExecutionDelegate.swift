import Foundation

// MARK: - TaskMutationDelegate

/// Atomic mutate-and-persist operation on a task.
///
/// Services that only need to mutate task state (without reading project-wide
/// settings) should depend on this narrow protocol rather than the full
/// `LLMStateDelegate`. `TaskMutationService` composes its pure inout helpers
/// inside the closure passed to `mutateTask` — the delegate guarantees atomic
/// persistence of the combined mutation.
@MainActor
protocol TaskMutationDelegate: AnyObject {
    /// Mutates a specific task and persists changes to disk.
    /// Returns `true` if the mutation persisted successfully.
    @discardableResult
    func mutateTask(taskID: Int, _ mutate: (inout NTMSTask) -> Void) async -> Bool
}

// MARK: - LLMStateDelegate

/// Read-only access to project/task state plus task mutation.
/// Used by all LLMExecutionService extensions that read or mutate task state.
@MainActor
protocol LLMStateDelegate: TaskMutationDelegate {
    var workFolderURL: URL? { get }
    /// The global LLM configuration — provider, URL, model, maxTokens, temperature.
    var globalLLMConfig: LLMConfig { get }
    /// App-wide instruction text appended to every LLM system prompt. Empty
    /// string disables the append. Surfaced from `StoreConfiguration.globalContext`.
    var globalLLMContext: String { get }
    /// Maximum consecutive LLM server error retries (0 = unlimited).
    var maxLLMRetries: Int { get }
    /// Vision model configuration (nil = vision not configured).
    var visionLLMConfig: LLMConfig? { get }
    /// Returns the project snapshot (for project-level reads like settings, targets).
    var snapshot: WorkFolderContext? { get }
    /// Whether logging (network_log.json, conversation_log.md, tool_calls.jsonl) is enabled.
    var loggingEnabled: Bool { get }
    /// Loads a task by ID (active or background).
    func loadedTask(_ taskID: Int) -> NTMSTask?
    /// Atomically consumes the next queued Supervisor message eligible for this
    /// role on its next LLM iteration. Preference order: messages whose
    /// `targetRoleID == roleID` (FIFO within tier), then untargeted messages
    /// (FIFO within tier).
    ///
    /// Performs staged-attachment finalization and appends **one**
    /// `LLMMessage(role: .user, sourceRole: .supervisor, sourceContext:
    /// .supervisorMessage)` to `step.llmConversation` so the activity feed
    /// renders the Supervisor bubble. Does NOT append a `StepMessage` —
    /// `step.messages` has no UI consumer and mid-iteration mutations don't
    /// feed back into the current run's `fullConversation`.
    ///
    /// `restartRole` preserves queued messages: `step.reset()` nulls
    /// `llmSessionID`, so iteration 1 of the restarted step satisfies the
    /// injection hook's `iterationNumber > 1 || session == nil` guard and the
    /// queue is consumed then. Do not "fix" this by adding role-level cleanup.
    ///
    /// Returns the final prompt text (already including "## Attached Files"
    /// / embedded content per `AnswerTextBuilder`) the caller must append to
    /// the LLM conversation for this iteration. Returns `nil` if no eligible
    /// message exists OR if attachment finalization fails (in which case the
    /// message stays queued and `lastErrorMessage` is set).
    func consumeQueuedSupervisorMessage(taskID: Int, roleID: String, stepID: String) async -> String?

    // MARK: - Exploratory Search

    /// Gates the `exploratory` branch on `SearchTool`. When `false`, the
    /// processor falls back to a plain search with an informational envelope
    /// marker so the LLM can see it isn't running in exploratory mode.
    var exploratorySearchEnabled: Bool { get }
    /// User preference: when `true`, `search` calls without an explicit
    /// `exploratory` argument default to exploratory mode. Independent of
    /// `exploratorySearchEnabled`; if the feature is disabled the processor
    /// still falls back to plain search.
    var searchExploratoryByDefault: Bool { get }
    /// User preference: hard line limit enforced by `read_file`. Files exceeding
    /// this return an error directing the LLM to use `read_lines`.
    var readFileMaxLines: Int { get }
    /// User preference: default `max_results` for `search` when the LLM omits
    /// the argument.
    var searchMaxResults: Int { get }
    /// User preference: default `context_before` for `search` when the LLM
    /// omits the argument.
    var searchContextBefore: Int { get }
    /// User preference: default `context_after` for `search` when the LLM
    /// omits the argument.
    var searchContextAfter: Int { get }
    /// True when a user-selected work folder is open (as opposed to default
    /// internal storage in Application Support). Exploratory-search indexing is only
    /// meaningful against a real project folder — the processor uses this to
    /// distinguish "architecturally unsupported" from "coordinator returned
    /// nil despite a real folder (true bug)" in the envelope's error reason.
    var hasRealWorkFolder: Bool { get }
    /// Blocks until the currently-running token-index build completes (if any),
    /// then returns the current search index. Returns `nil` when no work folder
    /// is open / the coordinator isn't configured.
    func awaitSearchIndex() async -> SearchIndex?
    /// Expands an `exploratory` query via the semantic vector index. Returns a
    /// `ExpansionResult` whose `terms` are vocab tokens cosine-close to
    /// the query (per-token + whole-phrase), plus canonical strings for
    /// transient errors / unavailability. The caller surfaces these into the
    /// `exploratory` envelope (`expanded_terms`, `expansion_error`).
    func expandSearchQuery(query _: String, tokens _: [String]) async -> VocabVectorIndexService.ExpansionResult

    // MARK: - User-Visible Banners

    /// Surface a user-visible info banner. Used by exploratory search to
    /// notify the Supervisor that a `SearchExecutor` exception fired and the
    /// branch fell back to plain search — the LLM sees `searchError` in its
    /// envelope, but without this the human user would have no signal.
    func setLastInfoMessageForUI(_ message: String)

    /// Surface a user-visible error banner. Used by delegation handlers when a
    /// silent persistence failure would otherwise leave the parent role's
    /// awaiter hung — the LLM sees the failure envelope but the human needs
    /// the same signal in the UI banner channel.
    func setLastErrorMessageForUI(_ message: String)

    /// Trigger the queued-Supervisor-message backstop drain for `taskID`. Called
    /// from `setNeedsSupervisorInput` after the step mutation persists,
    /// regardless of whether the engine state transition fires.
    ///
    /// Background: `MainLayoutView.onChange(of: engineState.taskEngineStates)`
    /// is the SwiftUI-driven trigger for
    /// `QuickCaptureController.tryFlushQueuedMessages`. But per CLAUDE.md
    /// "`TeamEngine.transition(to:)` guards same-state re-entry", the engine's
    /// `didSet` short-circuits when `oldValue == newValue` — so when parallel
    /// roles (CLAUDE.md "`TeamEngine` runs ready roles in parallel, not
    /// serially") ask questions back-to-back, the engine stays in
    /// `.needsSupervisorInput`, the dictionary value doesn't change, and queued
    /// messages targeted at the newly-waiting role sit forever. This hook
    /// closes that gap by calling the backstop directly from the step-mutation
    /// side.
    ///
    /// Note: the drain is dispatched asynchronously inside
    /// `tryFlushQueuedMessages` (each `.needsSupervisorInput` task gets its own
    /// `Task { ... }`); failure surfaces via `lastErrorMessage` from inside
    /// `flushQueuedChatMessage`, NOT synchronously to this call.
    func notifyQueuedMessageBackstop(taskID: Int)

    // MARK: - Delegation

    /// Awaits the next terminal or supervisor-input transition for `taskID`. Used by
    /// `handleDelegateToTeam` to block on child task completion. See
    /// `TaskCompletionAwaiter` and `NTMSOrchestrator.awaitTaskTerminalState`.
    func awaitTaskTerminalState(taskID: Int) async -> TaskCompletionAwaiter.WaitOutcome

    /// Creates a child task with the given parentage and returns its task ID.
    /// Caller must invoke `startRunForTask(taskID:)` separately to start its engine.
    func createDelegatedTask(
        parentTaskID: Int,
        parentRoleID: String,
        title: String,
        supervisorTask: String,
        preferredTeamID: NTMSID?,
        depth: Int
    ) async -> Int?

    /// Starts a task's run (creates engine if needed and dispatches `engine.start()`).
    /// Used by `handleDelegateToTeam` after creating the child task. Returns immediately
    /// — completion is observed via `awaitTaskTerminalState`.
    func startRunForTask(taskID: Int) async

    /// Closes/accepts a task — sets `closedAt`, transitions engine to `.done`.
    /// Used by `handleDelegateToTeam` to auto-accept the child when it reaches
    /// `.needsAcceptance` (children are never reviewed by the human).
    @discardableResult
    func closeTask(taskID: Int) async -> Bool

    /// Returns the most recent error message captured for `taskID`, if any.
    /// Used by `handleDelegateToTeam` to surface child failure detail in the
    /// envelope returned to the parent role.
    func lastErrorMessageForTask(_ taskID: Int) -> String?

    /// Wall-clock time of the last live stream activity (token delta / prompt-
    /// processing progress) for a step, or nil if it has no live stream. Read by
    /// `task_status` so the Autovisor stuck-detector tells a hung `.running` role
    /// (token silence) from one mid-(even long-)response.
    func streamLastActivityAt(stepID: String, taskID: Int) -> Date?

    /// The step's CURRENT (uncommitted) streaming thinking+content buffer, or nil if
    /// none. Lets the stuck-detector catch a reasoning model looping inside its
    /// thinking phase without ever committing — invisible to the committed-message
    /// and hang paths.
    func streamLiveText(stepID: String, taskID: Int) -> String?

    /// Hard-stops a task's engine and cancels any awaiter waiters. Used by
    /// `handleDelegateToTeam` on timeout — the child has wedged past the
    /// per-delegation deadline and we need to abort cleanly.
    func stopEngineForTask(_ taskID: Int)

    /// Pauses a task's engine and cascades to any in-flight child
    /// delegations. Used by `handleDelegateToTeam` when the Supervisor
    /// interrupts via queued chat message — the child engine is held in
    /// `.paused` state while the parent role decides via
    /// `cancel_delegation` / `resume_delegation` / `forward_to_team`.
    /// Distinct from `stopEngineForTask` which tears down the engine
    /// entirely.
    func pauseRun(taskID: Int) async

    /// Resumes a paused task's engine. Counterpart of `pauseRun`. Used by
    /// `resume_delegation` and `forward_to_team` after the parent role
    /// decides to keep the delegation running.
    func resumeRun(taskID: Int) async

    /// Returns the in-flight delegation child task id for `roleID` on
    /// `taskID`, or `nil` if the role isn't mid-delegation. Used by the
    /// `cancel_delegation` / `resume_delegation` / `forward_to_team`
    /// handlers to validate the child id the LLM passed in matches the
    /// actual paused delegation (defense against hallucinated ids).
    func activeDelegationChildID(taskID: Int, roleID: String) -> Int?

    /// Submits an answer to a step's `supervisorQuestion` and resumes the engine.
    /// Used by `DelegatedSupervisorAnswerService` to deliver the parent role's
    /// answer to a delegated child team's `ask_supervisor` call.
    /// Returns `true` if the mutation persisted and the engine was nudged.
    @discardableResult
    func answerSupervisorQuestion(taskID: Int, stepID: String, answer: String) async -> Bool

    // MARK: - Autovisor

    /// Applies one Autovisor write-action (create/control/manage/answer/
    /// message/schedule/set-context) by dispatching to the matching orchestrator
    /// operation. Single hook for all manager write tools so the protocol (and its
    /// test mock) don't sprout ~16 methods. Enforces the self-guard (refuses any
    /// action targeting the manager's own task). Returns a structured result the
    /// caller formats into the tool-result envelope.
    func performAutovisorAction(_ action: AutovisorAction) async -> AutovisorActionResult

    /// Persists the Autovisor's standing memory (write-through from the
    /// manager's `update_scratchpad`). Writes only `settings.json` via `mutateWorkFolder`.
    /// Returns `false` if the write failed — memory is the manager's only cross-run
    /// state, so the caller surfaces a persistence failure rather than letting it
    /// silently forget.
    func persistAutovisorMemory(_ text: String) async -> Bool

    /// Loads a task into memory (if needed) and returns it, for `task_status`
    /// inspection. Background folder tasks aren't necessarily in `loadedTasks`, so
    /// the plain `loadedTask(_:)` read isn't enough for the manager to inspect them.
    func autovisorLoadTask(_ taskID: Int) async -> NTMSTask?
}

// MARK: - LLMStreamingDelegate

/// Real-time streaming display and processing progress.
/// Used by LLMExecutionService streaming extensions only.
@MainActor
protocol LLMStreamingDelegate: AnyObject {
    /// Pre-creates an empty LLMMessage in the step's conversation at stream start.
    /// This allows the timeline to render the message immediately (with spinner)
    /// and stream content into it inline, avoiding visual jumps on commit.
    func beginStreaming(stepID: String, taskID: Int, messageID: UUID, role: Role) async
    /// Appends content to the streaming preview for a step.
    func appendStreamingPreview(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String)
    /// Replaces the streaming preview content for a step in one shot.
    /// Used to rewind the on-screen preview when a Harmony tool-call marker is
    /// detected mid-flush, so partial prefixes (e.g. `<`, `<|`) don't linger.
    func replaceStreamingPreview(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String)
    /// Appends thinking content to the streaming preview for a step.
    func appendStreamingThinking(stepID: String, taskID: Int, content: String)
    /// Commits streaming: updates the pre-created LLMMessage with final content and thinking,
    /// and updates/creates the corresponding StepMessage.
    func commitStreaming(stepID: String, taskID: Int, content: String, thinking: String?) async
    /// Discards a top-level looping generation: removes the pre-created empty
    /// `LLMMessage` (by `messageID`) and clears the streaming preview. Called by
    /// `performStreamingCall` instead of `commitStreaming` when an in-stream
    /// thinking loop breaks the stream for a top-level task.
    func discardStreaming(stepID: String, messageID: UUID, taskID: Int) async
    /// Reactive in-stream streaming-loop signal for a CHILD task: applies the
    /// per-task cooldown and fires the parent delegation interrupt. Returns
    /// whether the in-stream scanner should advance its throttle baseline
    /// (`true` = fired or in cooldown; `false` = no-waiter race, keep re-scanning).
    @discardableResult
    func noteStreamLoop(taskID: Int, stepID: String, signal: LoopSignal) -> Bool
    /// Clears the streaming preview for a step without committing.
    func clearStreamingPreview(stepID: String, taskID: Int)
    /// Updates prompt processing progress for a step (0.0–1.0).
    func updateStreamingProcessingProgress(stepID: String, taskID: Int, progress: Double)
    /// Clears prompt processing progress for a step.
    func clearStreamingProcessingProgress(stepID: String, taskID: Int)
    /// Marks the step as having received at least one stream delta of any
    /// kind. Called from the streaming service on EVERY delta (thinking,
    /// content, tool-call, harmony-buffered) so the UI can distinguish
    /// "Waiting" (nothing arrived yet) from "Generating" (tokens flowing
    /// but landing in invisible buffers like harmony tool-call args).
    /// Note: this flag alone cannot surface "Generating" once visible
    /// content/thinking exists — `markStreamingToolCall` covers the
    /// frozen-content case; a non-empty thinking preview is itself the
    /// indicator (no status row).
    /// Idempotent.
    func markStreamActivity(stepID: String, taskID: Int)
    /// Marks the step's live stream as having committed to tool-call
    /// emission — a Harmony envelope marker was detected or OpenAI
    /// tool-call deltas arrived. Drives two UI effects during the
    /// envelope/args assembly: keeps the Thinking loader animating
    /// (`MessageBubbleView.isThinkingStreaming` includes it — the
    /// envelope text streams into the thinking preview, which is the
    /// live indicator), and serves as the indicator's "Generating"
    /// fallback when the thinking preview is still empty (frozen
    /// pre-marker prose would otherwise suppress every status).
    /// Idempotent; reset by the next `beginStreaming` and cleared on
    /// commit/clear.
    func markStreamingToolCall(stepID: String, taskID: Int)
}

// MARK: - LLMMeetingDelegate

/// Meeting participant UI signals.
/// Used by LLMExecutionService team collaboration extensions.
@MainActor
protocol LLMMeetingDelegate: AnyObject {
    /// Signals that the given roles are currently participating in a meeting for this task.
    func setActiveMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int)
    /// Clears the active meeting participant signal for this task.
    func clearActiveMeetingParticipants(for taskID: Int)
}

// MARK: - LLMExecutionDelegate

/// Composed delegate — full conformance for NTMSOrchestrator.
/// Individual LLMExecutionService extensions declare the narrower sub-protocol
/// they actually need (LLMStateDelegate, LLMStreamingDelegate, or LLMMeetingDelegate).
typealias LLMExecutionDelegate = LLMStateDelegate & LLMStreamingDelegate & LLMMeetingDelegate
