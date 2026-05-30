import Foundation
import Observation

// MARK: - NTMSOrchestrator

@Observable @MainActor
final class NTMSOrchestrator {
    var workFolderURL: URL?
    var snapshot: WorkFolderContext?
    private(set) var activeTaskID: Int?
    var activeTask: NTMSTask?
    var selectedRunID: Int?
    var lastErrorMessage: String?
    var lastInfoMessage: String?
    private(set) var toolDefinitions: [ToolDefinitionRecord] = []

    /// Extracted engine state — views can observe this directly to avoid
    /// re-evaluating when unrelated orchestrator properties change.
    let engineState: OrchestratorEngineState

    /// Streaming preview manager for real-time LLM response display.
    let streamingPreviewManager: StreamingPreviewManager

    /// Extracted configuration — views can observe this directly to avoid
    /// triggering orchestrator-wide re-evaluation on settings changes.
    let configuration: StoreConfiguration

    // MARK: - Computed Properties

    /// Engine states keyed by task ID.
    /// Prefer observing `engineState` directly in views for finer-grained reactivity.
    var taskEngineStates: [Int: TeamEngineState] {
        engineState.taskEngineStates
    }

    var globalLLMConfig: LLMConfig {
        configuration.globalLLMConfig
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var globalLLMContext: String {
        configuration.globalContext
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var maxLLMRetries: Int {
        get { configuration.maxLLMRetries }
        set { configuration.maxLLMRetries = newValue }
    }

    var visionLLMConfig: LLMConfig? {
        configuration.visionLLMConfig
    }

    var loggingEnabled: Bool {
        configuration.loggingEnabled
    }

    var exploratorySearchEnabled: Bool {
        configuration.exploratorySearchEnabled
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var searchExploratoryByDefault: Bool {
        configuration.searchExploratoryByDefault
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var readFileMaxLines: Int {
        configuration.readFileMaxLines
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var searchMaxResults: Int {
        configuration.searchMaxResults
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var searchContextBefore: Int {
        configuration.searchContextBefore
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var searchContextAfter: Int {
        configuration.searchContextAfter
    }

    func awaitSearchIndex() async -> SearchIndex? {
        guard let coordinator = searchIndexCoordinator else { return nil }
        return await coordinator.awaitIndex()
    }

    func expandSearchQuery(
        query: String,
        tokens: [String]
    ) async -> VocabVectorIndexService.ExpansionResult {
        guard let coordinator = searchIndexCoordinator else {
            return .unavailable(reason: VocabVectorIndexService.reasonMissing)
        }
        return await coordinator.vectorIndex.expand(
            query: query,
            tokens: tokens,
            config: configuration.effectiveEmbeddingConfig,
            perTokenThreshold: Float(configuration.exploratorySearchPerTokenThreshold),
            phraseThreshold: Float(configuration.exploratorySearchPhraseThreshold)
        )
    }

    /// Coordinator that owns the search index + FS watcher. Populated on work
    /// folder open when `configuration.exploratorySearchEnabled == true`. `nil` when
    /// feature is off or no folder is open.
    ///
    /// Views DO observe this identity change — `ExploratorySearchSettingsView` passes
    /// `store.searchIndexCoordinator` into the status cards, and
    /// `SidebarWorkFolderCards` reads `store.searchIndexCoordinator?.isBuilding`.
    /// `@ObservationIgnored` would freeze the cards at their initial nil
    /// snapshot so enabling the toggle would not refresh them.
    var searchIndexCoordinator: SearchIndexCoordinator?

    /// Serial pipeline for exploratory-search toggle events. Each enqueued task
    /// awaits the prior one so three rapid detached-Task clicks from
    /// `ExploratorySearchToggleCard.onChanged` can't interleave inside
    /// `applyExploratorySearchSettingChange`, which would produce a non-deterministic
    /// final state. See `onExploratorySearchSettingChanged` in +WorkFolderManagement.
    @ObservationIgnored var pendingExploratorySearchToggle: Task<Void, Never>?

    /// Manages load/unload of the LM Studio embed model used by Exploratory
    /// Search. Reconciled at the end of every public lifecycle method
    /// (openWorkFolder, applyExploratorySearchSettingChange, embed-config change)
    /// so the model loaded in LM Studio tracks `searchIndexCoordinator != nil`.
    /// Test-injected via init to avoid real network calls in CI.
    @ObservationIgnored let embeddingLifecycle: EmbeddingModelLifecycleService
    /// Embedding client used by the per-folder `SearchIndexCoordinator` for
    /// vocab-vector builds. DI seam — tests inject a recording mock so the
    /// vector phase doesn't issue real `/v1/embeddings` round-trips.
    @ObservationIgnored let searchEmbeddingClient: any EmbeddingClient

    /// Shared "is the work-folder context currently being generated" flag.
    /// Both Settings and the Sidebar work-folder card observe this so generation
    /// triggered from either surface lights up the other.
    var isGeneratingWorkFolderContext: Bool = false

    @ObservationIgnored var workFolderContextGenerationTask: Task<Void, Never>?

    /// Generation counter for `startGeneratingWorkFolderContext`. The spawned
    /// lambda captures the value at start; on completion it only writes back
    /// state when the counter still matches. `cancelWorkFolderContextGeneration`
    /// bumps the counter so a late-firing lambda from a cancelled run can't
    /// clobber the flag / handle of a freshly started new run.
    @ObservationIgnored var workFolderContextGenerationGeneration: Int = 0

    /// All top-level tasks currently in memory (active + background).
    /// Child tasks created via `delegate_to_team` (`parentTaskID != nil`) are excluded —
    /// they are internal to the parent's tool call and never surface as Supervisor work.
    var allLoadedTasks: [NTMSTask] {
        var tasks: [NTMSTask] = []
        if let active = activeTask, active.parentTaskID == nil {
            tasks.append(active)
        }
        if let loaded = snapshot?.loadedTasks {
            for (id, task) in loaded where id != activeTaskID && task.parentTaskID == nil {
                tasks.append(task)
            }
        }
        return tasks
    }

    /// Variant including delegated child tasks. Used by internal lifecycle code
    /// (recursive removal, awaiter cleanup) that genuinely needs the full set.
    var allLoadedTasksIncludingChildren: [NTMSTask] {
        var tasks: [NTMSTask] = []
        if let active = activeTask { tasks.append(active) }
        if let loaded = snapshot?.loadedTasks {
            for (id, task) in loaded where id != activeTaskID {
                tasks.append(task)
            }
        }
        return tasks
    }

    @ObservationIgnored let repository: any NTMSRepositoryProtocol
    /// Engine instances keyed by task ID.
    @ObservationIgnored var taskEngines: [Int: TeamEngine] = [:]
    /// Background poll loop that fires due task recurrences and enforces per-run
    /// timeouts. Owned here (extensions can't add stored properties); started on
    /// `openWorkFolder`, cancelled on the next open. See `NTMSOrchestrator+Scheduling`.
    @ObservationIgnored var automationPollTask: Task<Void, Never>?
    /// Notification side-channel for synchronous delegation: `handleDelegateToTeam`
    /// awaits this when it spawns a child task. Wired in `engineForTask` — the
    /// engine's `onStateChanged` callback delivers terminal / `.needsSupervisorInput`
    /// transitions here in addition to the normal `engineState[taskID]` write.
    @ObservationIgnored let completionAwaiter: TaskCompletionAwaiter = TaskCompletionAwaiter()
    /// Watches delegated child tasks for pathologically repetitive output and
    /// auto-triggers Pause-and-Decide via `notifyDelegationInterrupt(...)`.
    /// Hooks fire from streaming (throttled), `commitStreaming`, and
    /// llmConversation appends — see `DelegationLoopWatcher`. The watcher
    /// holds a weak ref back to the orchestrator (resolved via `bind` after
    /// init since `self` isn't available in the property initializer).
    @ObservationIgnored let delegationLoopWatcher: DelegationLoopWatcher = DelegationLoopWatcher()
    /// Atomic reserve flag for generated-team creation. Inserted by
    /// `beginTeamGeneration` before the detached Task is spawned so concurrent
    /// `startRun` / `retryTeamGeneration` callers see the slot as taken even
    /// during the brief window before `registerTeamGenerationTask` installs
    /// the cancellation handle.
    @ObservationIgnored private var teamGenerationInFlight: Set<Int> = []
    /// Cancellation handles for detached team-generation Tasks, keyed by taskID.
    /// `pauseRun` cancels these so an in-flight `TeamGenerationService.generate`
    /// stream stops before it can transition the engine.
    @ObservationIgnored private var teamGenerationTasks: [Int: Task<Void, Never>] = [:]
    /// Serialization chain for `switchTask` cached-fast-path active-task pointer
    /// writes. Each new fast-path call captures the prior Task into its own
    /// closure as `previous` and awaits it before dispatching its own
    /// off-MainActor `setActiveTaskID`, so two fast-path switches issued in
    /// rapid succession commit to disk in MainActor-invocation order. Without
    /// this the two `Task.detached` writes would race on the cooperative pool
    /// and a "later-to-finish" A could leave disk pointing at the stale task
    /// while the UI is on B. The orchestrator slot only points to the LATEST
    /// Task — the chain is extended through closure captures, and prior links
    /// are released when each new Task's `_ = try? await previous?.value`
    /// returns and the closure-captured `previous` falls out of scope.
    /// Cancelled (and nil'd) on `closeProject` / `resetAllData` so an
    /// in-flight write doesn't fire against a torn-down workfolder.
    /// Other writers of `activeTaskID` (slow-path `switchTask`, top-level
    /// `createTask`, `deleteTask` active-task fallback) must
    /// `await flushPendingActiveTaskWrite()` first — see that helper for
    /// the ordering invariant they restore.
    @ObservationIgnored var pendingActiveTaskWrite: Task<Void, Error>?
    @ObservationIgnored let llmExecutionService: LLMExecutionService
    @ObservationIgnored let settingsService: SettingsService
    @ObservationIgnored let taskService: TaskService
    @ObservationIgnored let workFolderManagementService: WorkFolderManagementService
    @ObservationIgnored let engineFactory: @MainActor () -> TeamEngine
    @ObservationIgnored let fileManager: FileManager
    /// Source of queued Supervisor messages delivered on a role's next LLM iteration.
    /// Wired by `NanoTeamsApp` after `QuickCaptureController.shared.setup(...)`. Weak
    /// because `QuickCaptureController` already owns the strong reference to the
    /// shared form state.
    @ObservationIgnored weak var quickCaptureFormState: QuickCaptureFormState?

    /// Default internal storage used when no real work folder is selected.
    /// Teams like Quest Party and Discussion Club work without a real folder.
    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NanoTeams", isDirectory: true)
    }

    /// Whether a real user-chosen work folder is set (vs default internal storage).
    var hasRealWorkFolder: Bool {
        guard let url = workFolderURL else { return false }
        return url != Self.defaultStorageURL
    }

    init(
        repository: any NTMSRepositoryProtocol,
        llmExecutionService: LLMExecutionService? = nil,
        settingsService: SettingsService? = nil,
        taskService: TaskService? = nil,
        workFolderManagementService: WorkFolderManagementService? = nil,
        engineFactory: @MainActor @escaping () -> TeamEngine = { TeamEngine() },
        engineState: OrchestratorEngineState? = nil,
        streamingPreviewManager: StreamingPreviewManager? = nil,
        configuration: StoreConfiguration? = nil,
        fileManager: FileManager? = nil,
        embeddingLifecycle: EmbeddingModelLifecycleService? = nil,
        searchEmbeddingClient: (any EmbeddingClient)? = nil
    ) {
        self.repository = repository
        self.llmExecutionService = llmExecutionService ?? LLMExecutionService(repository: repository)
        self.settingsService = settingsService ?? SettingsService(repository: repository)
        self.taskService = taskService ?? TaskService(repository: repository)
        self.workFolderManagementService = workFolderManagementService ?? WorkFolderManagementService(repository: repository)
        self.engineFactory = engineFactory
        self.engineState = engineState ?? OrchestratorEngineState()
        self.streamingPreviewManager = streamingPreviewManager ?? StreamingPreviewManager()
        self.configuration = configuration ?? StoreConfiguration()
        self.fileManager = fileManager ?? .default
        self.embeddingLifecycle = embeddingLifecycle ?? EmbeddingModelLifecycleService()
        self.searchEmbeddingClient = searchEmbeddingClient ?? LMStudioEmbeddingClient()
        self.llmExecutionService.attach(delegate: self)
        // Bind the delegation loop watcher AFTER `self` is fully initialized
        // — its weak orchestrator ref can't be set in the property
        // initializer. Watcher's hooks fire from streaming/commit paths and
        // call `notifyDelegationInterrupt(...)` for child tasks that emit
        // pathologically repetitive output.
        self.delegationLoopWatcher.bind(orchestrator: self)
        // Wire soft-warning surfacing — VRAM-leak / transient-list failures
        // previously went silent. Use a weak self capture so the lifecycle
        // service doesn't keep the orchestrator alive after teardown.
        self.embeddingLifecycle.onWarning = { [weak self] message in
            self?.lastInfoMessage = message
        }
    }

    // MARK: - UI Helpers

    /// Set by Watchtower before navigating to a task; consumed by TeamBoardView on appear
    var pendingRoleSelection: String?

    /// Signals that a specific role should be selected when TeamBoardView appears.
    func selectRole(roleID: String) {
        pendingRoleSelection = roleID
    }

    var workFolder: WorkFolderProjection? { snapshot?.workFolder }

    var selectedRunSnapshot: Run? {
        RunService.selectedRunSnapshot(from: activeTask, selectedRunID: selectedRunID)
    }

    /// Resolves the effective team for a task: task.preferredTeamID → workFolder.activeTeam → Team.default
    func resolvedTeam(for task: NTMSTask?) -> Team {
        if let generated = task?.generatedTeam {
            return generated
        }
        if let preferredTeamID = task?.preferredTeamID,
           let team = workFolder?.team(withID: preferredTeamID) {
            return team
        }
        return workFolder?.activeTeam ?? Team.default
    }

    // MARK: - Multi-Engine Management

    func engineForTask(_ taskID: Int) -> TeamEngine {
        if let existing = taskEngines[taskID] { return existing }
        let engine = engineFactory()
        let adapter = TaskEngineStoreAdapter(orchestrator: self, taskID: taskID)
        engine.attach(store: adapter)
        engine.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.engineState[taskID] = state
            // Side-channel: wake any handler awaiting this child's completion or
            // supervisor-input yield. UI observation via engineState is unaffected.
            // Map the engine state to the narrow `TerminalOutcome` so the
            // awaiter type can't carry non-terminal cases (which would
            // wedge the handler into a tight loop).
            switch state {
            case .done:
                self.completionAwaiter.deliver(taskID: taskID, outcome: .terminal(.done))
            case .failed:
                self.completionAwaiter.deliver(taskID: taskID, outcome: .terminal(.failed))
            case .needsAcceptance:
                self.completionAwaiter.deliver(taskID: taskID, outcome: .terminal(.needsAcceptance))
            case .needsSupervisorInput:
                self.completionAwaiter.deliver(taskID: taskID, outcome: .needsSupervisorInput)
            default:
                break
            }
        }
        taskEngines[taskID] = engine
        return engine
    }

    func stopEngine(for taskID: Int) {
        taskEngines[taskID]?.stop()
        taskEngines.removeValue(forKey: taskID)
        engineState.removeEngine(for: taskID)
        engineState.clearMeetingParticipants(for: taskID)
        completionAwaiter.cancelAll(taskID: taskID)
    }

    func stopAllEngines() {
        for (_, engine) in taskEngines {
            engine.stop()
        }
        taskEngines.removeAll()
        engineState.removeAllEngines()
        completionAwaiter.cancelAll()
    }

    /// Awaits the next terminal or supervisor-input transition for `taskID`.
    /// Fast-path: if the engine is already in a wakeable state, returns immediately
    /// without registering — otherwise the awaiter would never fire (the engine
    /// already raced past the transition before this call could register).
    ///
    /// Second fast-path covers the auto-accept loop in `handleDelegateToTeam`:
    /// after the handler calls `closeTask(childID)` on `.needsAcceptance`, the
    /// engine is torn down via `stopEngine` (which also drops `engineState[id]`).
    /// The handler then loops back and re-enters this function — but with no
    /// engine state and no transition to deliver, the awaiter would register
    /// against a `cancelAll`'d slot and hang until the 30-minute timeout.
    /// Reading the task's `closedAt` (set by `closeTask` before tearing down
    /// the engine) lets us short-circuit to `.terminal(.done)`. Same idea for
    /// `derivedStatus == .failed` — recovery paths can leave the engine gone
    /// while the run carries a failed step.
    func awaitTaskTerminalState(taskID: Int) async -> TaskCompletionAwaiter.WaitOutcome {
        if let s = engineState.taskEngineStates[taskID] {
            switch s {
            case .done:
                return .terminal(.done)
            case .failed:
                return .terminal(.failed)
            case .needsAcceptance:
                return .terminal(.needsAcceptance)
            case .needsSupervisorInput:
                return .needsSupervisorInput
            default:
                break
            }
        }
        if let task = loadedTask(taskID) {
            if task.closedAt != nil {
                return .terminal(.done)
            }
            switch task.derivedStatusFromActiveRun() {
            case .failed:
                return .terminal(.failed)
            case .done:
                return .terminal(.done)
            default:
                break
            }
        }
        return await completionAwaiter.register(taskID: taskID)
    }

    /// Reserves an in-flight slot for generated-team creation for the given task.
    /// Returns `false` if a generation is already in flight for this task.
    /// After reserving, create the detached Task and call
    /// `registerTeamGenerationTask(taskID:task:)` so `pauseRun` can cancel it.
    func beginTeamGeneration(taskID: Int) -> Bool {
        teamGenerationInFlight.insert(taskID).inserted
    }

    /// Installs the Task handle paired with a prior `beginTeamGeneration(taskID:)`.
    /// Safe to call without a matching `begin` — the handle is still tracked so
    /// `cancelTeamGeneration` works, but `isGeneratingTeam` reflects the reserve flag.
    func registerTeamGenerationTask(taskID: Int, task: Task<Void, Never>) {
        teamGenerationTasks[taskID] = task
    }

    /// Releases the reserve flag + Task handle for this task.
    func endTeamGeneration(taskID: Int) {
        teamGenerationTasks.removeValue(forKey: taskID)
        teamGenerationInFlight.remove(taskID)
    }

    /// Cancels an in-flight generation Task for this task. The Task's `defer`
    /// is expected to call `endTeamGeneration` as it unwinds.
    func cancelTeamGeneration(taskID: Int) {
        teamGenerationTasks[taskID]?.cancel()
    }

    /// Whether a team generation is currently reserved for this task.
    func isGeneratingTeam(taskID: Int) -> Bool {
        teamGenerationInFlight.contains(taskID)
    }

    /// Syncs `taskEngineStates` from the task's derived status when no engine
    /// exists. Called after loading/recovering a task on app restart so the UI
    /// shows the correct Resume/Start buttons.
    ///
    /// Uses `task.derivedStatusFromActiveRun()` (not `run.derivedStatus()`) so
    /// the chat-mode override participates: a chat task with all-done steps
    /// and `closedAt == nil` reports `.running` and seeds engine state to
    /// `.paused`, instead of misseeded `.done`.
    func syncEngineStateFromRun(taskID: Int, task: NTMSTask) {
        guard taskEngines[taskID] == nil else { return }
        guard let lastRun = task.runs.last else { return }
        if let state = Self.mapDerivedStatusToEngineState(
            task.derivedStatusFromActiveRun(),
            hasSteps: !lastRun.steps.isEmpty
        ) {
            engineState[taskID] = state
        }
    }

    /// Pure mapping from a task's derived status to the engine state seeded on
    /// restart. Returns `nil` to mean "leave engine state unset" (intentional
    /// no-op for the `.running` + empty-steps case — a half-built run shape).
    ///
    /// Extracted as a static helper so every branch (including `.waiting`,
    /// which is currently unreachable through `derivedStatusFromActiveRun()`
    /// but kept for `TaskStatus` exhaustiveness) is unit-testable in isolation.
    static func mapDerivedStatusToEngineState(
        _ derivedStatus: TaskStatus,
        hasSteps: Bool
    ) -> TeamEngineState? {
        switch derivedStatus {
        case .paused:                    return .paused
        case .failed:                    return .failed
        case .needsSupervisorInput:      return .needsSupervisorInput
        case .done:                      return .done
        case .needsSupervisorAcceptance: return .done
        case .running:                   return hasSteps ? .paused : nil
        case .waiting:                   return .paused
        }
    }

    // MARK: - Loaded Task Access

    /// Returns a task by ID — active or background.
    func loadedTask(_ taskID: Int) -> NTMSTask? {
        if taskID == activeTaskID { return activeTask }
        return snapshot?.loadedTasks[taskID]
    }

    /// Removes a background task from the in-memory loaded tasks map.
    func evictLoadedTask(_ taskID: Int) {
        snapshot?.loadedTasks.removeValue(forKey: taskID)
    }

    /// Whether any task engines are currently in the `.running` state.
    var hasRunningTasks: Bool {
        engineState.taskEngineStates.values.contains(.running)
    }

    // MARK: - Task Mutation

    /// Mutates a task and persists it to disk. Returns `true` when the task was
    /// successfully persisted. Does NOT indicate whether the mutation closure made
    /// meaningful changes — callers that need that guarantee must check state first.
    @discardableResult
    func mutateTask(taskID: Int, _ mutate: (inout NTMSTask) -> Void) async -> Bool {
        guard let url = workFolderURL else {
            self.lastErrorMessage = "Cannot persist task \(taskID): no work folder is open."
            return false
        }

        // In-memory mutate + snapshot apply MUST run synchronously on
        // `@MainActor` so concurrent callers (parallel role engines per
        // CLAUDE.md invariant #45, streaming + tool-result writes on the
        // same task) cannot read a stale `activeTask` between our mutate
        // and apply. Only the JSON encode + atomic file write detaches —
        // that's where the main-thread cost is. Trade-off: in-memory may
        // be ahead of disk briefly; on disk failure we surface
        // `lastErrorMessage` but keep the in-memory mutation. See plan
        // C1 in `.claude/plans/snoopy-sprouting-tiger.md`.
        if taskID == activeTaskID {
            guard var task = activeTask else {
                self.lastErrorMessage = "Cannot persist active task \(taskID): task not loaded."
                return false
            }
            mutate(&task)
            task.updatedAt = MonotonicClock.shared.now()
            applyTaskUpdate(task)
            let repoCopy = repository
            let taskCopy = task
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repoCopy.updateTaskOnly(at: url, task: taskCopy)
                }.value
                return true
            } catch is CancellationError {
                return false
            } catch {
                self.lastErrorMessage = "Failed to save task: \(error.localizedDescription)"
                return false
            }
        } else {
            guard var task = loadedTask(taskID) else {
                self.lastErrorMessage = "Cannot persist task \(taskID): task not loaded."
                return false
            }
            mutate(&task)
            task.updatedAt = MonotonicClock.shared.now()
            // Update the in-memory snapshot synchronously on @MainActor (before the
            // detached disk write) — both `loadedTasks` AND the tasks index. See
            // `refreshBackgroundTaskInMemory` for why the index must move in lockstep.
            refreshBackgroundTaskInMemory(task)
            let repoCopy = repository
            let taskCopy = task
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repoCopy.updateTaskOnly(at: url, task: taskCopy)
                }.value
                return true
            } catch is CancellationError {
                return false
            } catch {
                self.lastErrorMessage = "Failed to save task: \(error.localizedDescription)"
                return false
            }
        }
    }

    /// Refreshes the in-memory snapshot for a **background** (non-active) task —
    /// both `loadedTasks` AND the tasks-index summary — synchronously on @MainActor.
    /// This is the background-branch mirror of what `applyTaskUpdate` does for the
    /// active task. Every background write path (`mutateTask`'s else branch,
    /// `createNewRun`) must route through here: the sidebar reads `taskSummaries`
    /// from `snapshot.tasksIndex`, so a path that updates `loadedTasks` alone leaves
    /// a stale status label for any non-active task mutating in the background —
    /// recurrence/timeout firing, delegation children, and parallel multi-task runs
    /// all hit this. Keeping it in one helper stops the two call sites from drifting.
    func refreshBackgroundTaskInMemory(_ task: NTMSTask) {
        guard var snap = snapshot else { return }
        snap.loadedTasks[task.id] = task
        let summary = task.toSummary()
        if let idx = snap.tasksIndex.tasks.firstIndex(where: { $0.id == summary.id }) {
            snap.tasksIndex.tasks[idx] = summary
        } else {
            snap.tasksIndex.tasks.append(summary)
        }
        snap.tasksIndex.tasks.sort(by: { $0.updatedAt > $1.updatedAt })
        snapshot = snap
    }

    // MARK: - Work Folder Mutation

    /// Atomic mutation entry point for the work folder projection.
    ///
    /// Closure bodies can freely mutate any combination of `state` (identity + active
    /// pointers), `settings` (user prefs), or `teams` (team configs). After the closure
    /// runs, the orchestrator diffs each sub-component and writes only the files that
    /// actually changed — giving you "one file per closure" granularity through
    /// runtime diff instead of through type-level API splits.
    ///
    /// Closure-body rename cheatsheet (vs the old `(inout WorkFolder)` signature):
    /// - `wf.description`        → `proj.settings.context`
    /// - `wf.descriptionPrompt`  → `proj.settings.contextPrompt`
    /// - `wf.selectedScheme`     → `proj.settings.selectedScheme`
    /// - `wf.teams.append(...)`  — unchanged (teams on top level of projection)
    /// - `wf.activeTeamID = ...` — unchanged (state.activeTeamID aliased on projection)
    func mutateWorkFolder(_ mutate: (inout WorkFolderProjection) -> Void) async {
        guard let url = workFolderURL else { return }
        guard var projection = snapshot?.projection else { return }

        let before = projection
        mutate(&projection)

        // Decide which sub-components changed.
        //
        // `state` and `settings` have clean structural `Hashable` — normal `!=`
        // works and is cheap.
        //
        // `teams` cannot use `!=` directly: `Team.==` is a custom shortcut that
        // only compares `id` + `updatedAt` (for @Observable performance), so
        // structural changes to roles/artifacts without a timestamp bump would
        // register as equal (CLAUDE.md pitfall #45). Fall back to a JSON-encoded
        // comparison for deep structural equality — and only for `teams`, where
        // the workaround is actually needed.
        let stateChanged = projection.state != before.state
        let settingsChanged = projection.settings != before.settings

        let teamsChanged: Bool
        do {
            let encoder = JSONCoderFactory.makePersistenceEncoder()
            teamsChanged = try encoder.encode(projection.teams) != encoder.encode(before.teams)
        } catch {
            // Encoding errors here (e.g. NaN/Infinity in Double fields) are
            // recoverable at the repository layer — the narrow writer will
            // throw with a file-specific error. Fail-safe to "assume changed"
            // so a transient encode hiccup does not silently drop user intent.
            print("[NTMSOrchestrator] WARNING: teams diff encoding failed (\(error)); "
                + "assuming teams changed.")
            teamsChanged = true
        }

        // No-op closure — nothing to write. This is the cheap path for
        // code that computes whether a change is needed inside the closure.
        if !stateChanged && !settingsChanged && !teamsChanged {
            return
        }

        // `updatedAt` on state is bumped by `repository.updateWorkFolderState`
        // directly. Settings/teams-only mutations intentionally do NOT touch
        // state.updatedAt — it tracks when the identity/pointers last changed,
        // not when any sub-file changed.

        // Sequential writes. `AtomicJSONStore.write` is per-file atomic, but
        // cross-file atomicity is not provided — if write #2 or #3 throws, the
        // first write is already on disk. We recover by re-reading the work
        // folder from disk and applying that to memory, so at least the
        // in-memory state matches what landed on disk (the user's partial
        // mutation is visible via lastErrorMessage and the UI reflects reality).
        do {
            var lastContext: WorkFolderContext?
            if stateChanged {
                lastContext = try repository.updateWorkFolderState(at: url) { $0 = projection.state }
            }
            if settingsChanged {
                lastContext = try repository.updateSettings(at: url) { $0 = projection.settings }
            }
            if teamsChanged {
                lastContext = try repository.updateTeams(at: url) { $0 = projection.teams }
            }
            if let ctx = lastContext {
                apply(ctx)
            }
        } catch {
            let fileHint = partialWriteFileHint(
                stateChanged: stateChanged,
                settingsChanged: settingsChanged,
                teamsChanged: teamsChanged
            )
            self.lastErrorMessage = "Failed to persist work folder changes\(fileHint): "
                + "\(error.localizedDescription)"
            // Re-sync memory with whatever actually landed on disk. If even
            // this fails, the in-memory snapshot stays as `before` (closure
            // mutation is discarded) and the user sees the error.
            if let ctx = try? repository.openOrCreateWorkFolder(at: url) {
                apply(ctx)
            }
        }
    }

    /// Produces a human-readable hint about which file(s) the mutation targeted,
    /// used in error messages so users can locate partial-write failures.
    private func partialWriteFileHint(
        stateChanged: Bool,
        settingsChanged: Bool,
        teamsChanged: Bool
    ) -> String {
        var files: [String] = []
        if stateChanged { files.append("workfolder.json") }
        if settingsChanged { files.append("settings.json") }
        if teamsChanged { files.append("teams.json") }
        guard !files.isEmpty else { return "" }
        return " (\(files.joined(separator: ", ")))"
    }

    // MARK: - Private

    func apply(_ snapshot: WorkFolderContext) {
        let previousActiveRunID = activeTask?.runs.last?.id
        let previousSelectedRunID = selectedRunID

        // Preserve loadedTasks from old snapshot
        var newSnapshot = snapshot
        if let oldLoaded = self.snapshot?.loadedTasks {
            newSnapshot.loadedTasks = oldLoaded
        }

        // When the active task changes, preserve the old active task in loadedTasks
        // so background engines can still access it via loadedTask(_:).
        if let oldTaskID = activeTaskID,
           let oldTask = activeTask,
           oldTaskID != newSnapshot.activeTaskID {
            newSnapshot.loadedTasks[oldTaskID] = oldTask
        }

        self.snapshot = newSnapshot
        self.activeTaskID = newSnapshot.activeTaskID
        self.activeTask = newSnapshot.activeTask
        self.toolDefinitions = newSnapshot.toolDefinitions
        ToolDefinitionRegistry.shared.update(newSnapshot.toolDefinitions)

        syncSelectedRunID(
            task: newSnapshot.activeTask,
            previousActiveRunID: previousActiveRunID,
            previousSelectedRunID: previousSelectedRunID
        )
    }

    /// Update the in-memory snapshot with a modified active task without rebuilding from disk.
    /// This is the fast path for task mutations — only the task and its index entry are updated.
    func applyTaskUpdate(_ task: NTMSTask) {
        let previousActiveRunID = activeTask?.runs.last?.id
        let previousSelectedRunID = selectedRunID

        self.activeTask = task

        guard var snap = snapshot else { return }
        snap.activeTask = task

        // Update index entry
        let summary = task.toSummary()
        if let idx = snap.tasksIndex.tasks.firstIndex(where: { $0.id == summary.id }) {
            snap.tasksIndex.tasks[idx] = summary
        } else {
            snap.tasksIndex.tasks.append(summary)
        }
        snap.tasksIndex.tasks.sort(by: { $0.updatedAt > $1.updatedAt })

        self.snapshot = snap

        syncSelectedRunID(
            task: task,
            previousActiveRunID: previousActiveRunID,
            previousSelectedRunID: previousSelectedRunID
        )
    }

    private func syncSelectedRunID(
        task: NTMSTask?, previousActiveRunID: Int?, previousSelectedRunID: Int?
    ) {
        guard let task else {
            selectedRunID = nil
            return
        }

        let runIDs = Set(task.runs.map(\.id))
        let newActiveRunID = task.runs.last?.id

        if let previousSelectedRunID, runIDs.contains(previousSelectedRunID) {
            if let previousActiveRunID, previousSelectedRunID == previousActiveRunID,
                previousActiveRunID != newActiveRunID
            {
                selectedRunID = newActiveRunID
            } else {
                selectedRunID = previousSelectedRunID
            }
        } else {
            selectedRunID = newActiveRunID
        }
    }

    // MARK: - Team Meetings

    func setActiveMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int) {
        engineState.setMeetingParticipants(participantIDs, for: taskID)
    }

    func clearActiveMeetingParticipants(for taskID: Int) {
        engineState.clearMeetingParticipants(for: taskID)
    }

    nonisolated deinit {}
}

// MARK: - LLMExecutionDelegate Conformance

extension NTMSOrchestrator: LLMExecutionDelegate {}

#if DEBUG
    extension NTMSOrchestrator {
        func _testRegisterStepTask(stepID: String, taskID: Int) {
            llmExecutionService._testRegisterStepTask(stepID: stepID, taskID: taskID)
        }

        func _testFinishStepWithWarning(stepID: String, warning: String) async {
            await llmExecutionService._testFinishStepWithWarning(stepID: stepID, warning: warning)
        }

        // periphery:ignore - used in #if DEBUG inside SidebarView.swift #Preview at line 477
        func _setActiveTaskID(_ id: Int?) {
            activeTaskID = id
        }
}
#endif

