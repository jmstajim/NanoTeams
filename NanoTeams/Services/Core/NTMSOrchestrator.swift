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
    /// The Autovisor task is also excluded: it IS the (automated) Supervisor, so it
    /// must not appear as supervised work in Watchtower notifications.
    var allLoadedTasks: [NTMSTask] {
        let managerID = autovisorTaskID
        var tasks: [NTMSTask] = []
        if let active = activeTask, active.parentTaskID == nil, active.id != managerID {
            tasks.append(active)
        }
        if let loaded = snapshot?.loadedTasks {
            for (id, task) in loaded where id != activeTaskID && task.parentTaskID == nil && id != managerID {
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
    @ObservationIgnored var teamGenerationInFlight: Set<Int> = []
    /// Cancellation handles for detached team-generation Tasks, keyed by taskID.
    /// `pauseRun` cancels these so an in-flight `TeamGenerationService.generate`
    /// stream stops before it can transition the engine.
    @ObservationIgnored var teamGenerationTasks: [Int: Task<Void, Never>] = [:]
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

    /// Timestamp of the manager's last review pass start (any path: event-wake,
    /// recurrence, Run-now, open-time). A "last reviewed" diagnostic signal, NOT a
    /// throttle — the event-wake debounce was removed: events reach the manager
    /// immediately when it's idle, or queue (mid-review injection) when it's running.
    /// Stamped in `startRun`'s manager hook.
    @ObservationIgnored var autovisorLastWakeAt: Date?

    /// Top-level task ids the Autovisor has already seen, so the `onTaskCreated`
    /// activation trigger fires once per genuinely-new task rather than every tick.
    /// Seeded at open from the existing tasks; refreshed whenever the manager wakes.
    @ObservationIgnored var autovisorSeenTaskIDs: Set<Int> = []

    /// (task, trigger) conditions already delivered into the manager's LIVE
    /// conversation as a mid-review event notice, so a still-matching level doesn't
    /// re-inject the same message every tick of a long pass. Scoped to the
    /// mid-review injection branch ONLY — the fresh-pass wake path deliberately
    /// stays edge-dedup-free (a `handled`-style set there was adversarially
    /// rejected; see `testWake_afterDebounceWindow_reFires`). Seeded with every
    /// non-stuck condition matching at pass start (`seedAutovisorNotifiedKeysForPassStart`
    /// deliberately passes `stuck: []` — one stuck notice per pass is intended)
    /// and pruned on each wake to keys still matching among the triggers that wake
    /// evaluated (`.stuck` keys survive observer wakes, which never run the stuck
    /// detector), so a condition that clears and later re-fires notifies again.
    @ObservationIgnored var autovisorNotifiedAttentionKeys: Set<AutovisorAttentionKey> = []

    /// Stable snapshot of the attention conditions present at the manager's last
    /// review pass start — the DELIVER-ONCE baseline for event wakes. There is no
    /// time-throttle: a condition NOT in this set is "fresh" — it arose SINCE the last
    /// pass (typically a task the manager created mid-pass whose artifact /
    /// `ask_supervisor` landed after it parked) — and wakes the manager immediately
    /// (or, if it's already running, is injected into the live conversation). A
    /// condition already in the snapshot is NOT re-delivered; the periodic recurrence
    /// sweep re-reviews unresolved ones. The pass-start seed RECOMPUTES `.stuck` into
    /// the baseline so a stuck task is delivered once, not every poll. Deliberately SEPARATE
    /// from `autovisorNotifiedAttentionKeys` (the mid-review injection dedup set —
    /// pruned + `formUnion`'d during a pass): this one is NOT pruned, so a condition
    /// present at pass start stays "not fresh" even if it momentarily flickers. Set at
    /// every pass start (`seedAutovisorNotifiedKeysForPassStart`) AND synchronously in
    /// `wakeAutovisorForEvents` before the `await` — that synchronous record is the
    /// SOLE serialization between the concurrent observer + poll callers (a second wake
    /// for the same conditions sees them as not-fresh and bails, so neither
    /// double-starts a `createNewRun`).
    @ObservationIgnored var autovisorLastPassAttentionKeys: Set<AutovisorAttentionKey> = []

    /// Tasks the Autovisor created during the CURRENT review pass. Reset to 0
    /// on each manager run start (in `startRun`); bounded in `createManagedTask` by
    /// `settings.autovisorTuning.maxManagedTasksPerReview` (default
    /// `AutovisorConstants.maxManagedTasksPerReview`).
    @ObservationIgnored var autovisorCreationsThisReview: Int = 0

    /// In-memory auto-off deadline (sleep timer). Armed by `rearmAutovisorAutoDisable`
    /// on enable / duration edit / folder open; consumed by `evaluateAutovisorAutoDisable`
    /// each scheduler tick. Deliberately NOT persisted — the countdown restarts fresh
    /// each launch. Observable (unlike the wake bookkeeping above) so Settings can show
    /// the off time; it changes rarely, so no hot-path cost.
    var autovisorAutoDisableAt: Date?

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

    /// Resolves the effective team for a task. Pins a started run to its
    /// `Run.teamID` (see `TeamResolution.resolve`). Non-optional convenience /
    /// display resolver: a pin-failure coalesces to `Team.default` and does NOT
    /// surface a diagnostic — this method is called from SwiftUI `body` (7 view
    /// sites), so it MUST NOT mutate observable state (`lastErrorMessage`) during
    /// view evaluation. The LOUD diagnostic is owned by the engine paths that
    /// actually fail the run: `TaskEngineStoreAdapter.resolvedTeam` and
    /// `findOrCreateStep`'s roster-swap guard.
    func resolvedTeam(for task: NTMSTask?) -> Team {
        guard let task else { return workFolder?.activeTeam ?? Team.default }
        switch TeamResolution.resolve(
            task: task,
            teamProvider: { workFolder?.team(withID: $0) },
            activeTeam: workFolder?.activeTeam
        ) {
        case .resolved(let team):
            return team
        case .failed, .noTeam:
            return workFolder?.activeTeam ?? Team.default
        }
    }

    /// True when the team is the pinned team (`runs.last?.teamID`) of any
    /// non-closed task — i.e. deleting it would strand that task's run on a team
    /// that no longer exists. Used to block team deletion.
    ///
    /// Scans the in-memory `tasksIndex` (every task's `TaskSummary`, including
    /// paused/evicted/never-loaded tasks and children), NOT just `loadedTasks` —
    /// `evictIfReclaimable` can drop a paused non-closed task from memory, so a
    /// loaded-only scan would miss it and silently allow the destructive delete.
    /// A summary `status == .done` means closed (a non-chat task only derives
    /// `.done` once `closedAt` is set), so non-`.done` is the "still needs its
    /// team" proxy. No per-task disk I/O.
    func teamIsInUseByActiveRun(_ teamID: NTMSID) -> Bool {
        guard let summaries = snapshot?.tasksIndex.tasks else { return false }
        return summaries.contains { summary in
            // A `.done` task with an ENABLED recurrence will re-run on this team on
            // its next fire — deleting the team now would strand that future run.
            // `toSummary` sets `nextRecurrenceFireAt = isEnabled ? nextFireAt : nil`,
            // so it is non-nil for any enabled recurrence that still has a scheduled
            // fire — INCLUDING one already due but not yet rescheduled (still the safe
            // direction: keep a team that's about to re-run un-deletable). A spent
            // rule self-disables via `TaskRecurrence.reschedule`, nilling it.
            summary.pinnedTeamID == teamID
                && (summary.status != .done || summary.nextRecurrenceFireAt != nil)
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

    // MARK: - Private

    func apply(_ snapshot: WorkFolderContext) {
        let previousTaskID = activeTaskID
        let previousFolderID = self.snapshot?.projection.id
        let previousActiveRunID = activeTask?.runs.last?.id
        let previousSelectedRunID = selectedRunID

        // Preserve loadedTasks from the old snapshot — but ONLY within the same
        // work folder. Task IDs are sequential ints per folder, so collisions
        // across folders are the norm: carrying folder A's loaded tasks into
        // folder B's snapshot lets any background write path (status sweep,
        // recurrence reconcile, mutateTask) resolve a colliding ID against the
        // ghost and persist folder A's content into folder B's task.json.
        var newSnapshot = snapshot
        let sameFolder = previousFolderID == newSnapshot.projection.id
        if sameFolder, let oldLoaded = self.snapshot?.loadedTasks {
            newSnapshot.loadedTasks = oldLoaded
        }

        // When the active task changes (within the same folder), preserve the
        // old active task in loadedTasks so background engines can still access
        // it via loadedTask(_:).
        if sameFolder,
           let oldTaskID = activeTaskID,
           let oldTask = activeTask,
           oldTaskID != newSnapshot.activeTaskID {
            newSnapshot.loadedTasks[oldTaskID] = oldTask
        }

        self.snapshot = newSnapshot
        self.activeTaskID = newSnapshot.activeTaskID
        self.activeTask = newSnapshot.activeTask
        self.toolDefinitions = newSnapshot.toolDefinitions
        ToolDefinitionRegistry.shared.update(newSnapshot.toolDefinitions)

        // The preserve logic in syncSelectedRunID only makes sense within ONE
        // task. Run IDs are sequential ints per task (0, 1, 2…) AND task IDs are
        // sequential ints per work folder, so on a task switch — or a folder
        // switch where the new folder's active task happens to share the old
        // task's id — the old selection can collide with an unrelated run id in
        // the new task and pin the feed to a stale run (seen as "task ran but
        // the chat shows nothing new"). Reset to the new task's latest run.
        if previousTaskID != newSnapshot.activeTaskID || previousFolderID != newSnapshot.projection.id {
            selectedRunID = newSnapshot.activeTask?.runs.last?.id
            return
        }

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

        func _testFinishStepWithWarning(stepID: String, taskID: Int, warning: String) async {
            await llmExecutionService._testFinishStepWithWarning(
                stepID: stepID, taskID: taskID, warning: warning)
        }

        // periphery:ignore - used in #if DEBUG inside SidebarView.swift #Preview at line 477
        func _setActiveTaskID(_ id: Int?) {
            activeTaskID = id
        }
}
#endif

