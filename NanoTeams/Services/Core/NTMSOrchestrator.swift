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
    var maxLLMRetries: Int {
        get { configuration.maxLLMRetries }
        set { configuration.maxLLMRetries = newValue }
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var visionLLMConfig: LLMConfig? {
        configuration.visionLLMConfig
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var loggingEnabled: Bool {
        configuration.loggingEnabled
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var expandedSearchEnabled: Bool {
        configuration.expandedSearchEnabled
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func awaitSearchIndex() async -> SearchIndex? {
        guard let coordinator = searchIndexCoordinator else { return nil }
        return await coordinator.awaitIndex()
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
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
            perTokenThreshold: Float(configuration.expandedSearchPerTokenThreshold),
            phraseThreshold: Float(configuration.expandedSearchPhraseThreshold)
        )
    }

    /// Coordinator that owns the search index + FS watcher. Populated on work
    /// folder open when `configuration.expandedSearchEnabled == true`. `nil` when
    /// feature is off or no folder is open.
    ///
    /// Views DO observe this identity change — `AdvancedSettingsView` passes
    /// `store.searchIndexCoordinator` into the status cards, and
    /// `SidebarWorkFolderCards` reads `store.searchIndexCoordinator?.isBuilding`.
    /// `@ObservationIgnored` would freeze the cards at their initial nil
    /// snapshot so enabling the toggle would not refresh them.
    var searchIndexCoordinator: SearchIndexCoordinator?

    /// Serial pipeline for expanded-search toggle events. Each enqueued task
    /// awaits the prior one so three rapid detached-Task clicks from
    /// `ExpandedSearchToggleCard.onChanged` can't interleave inside
    /// `applyExpandedSearchSettingChange`, which would produce a non-deterministic
    /// final state. See `onExpandedSearchSettingChanged` in +WorkFolderManagement.
    @ObservationIgnored var pendingExpandedSearchToggle: Task<Void, Never>?

    /// All tasks currently in memory (active + background).
    var allLoadedTasks: [NTMSTask] {
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
        fileManager: FileManager? = nil
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
        self.llmExecutionService.attach(delegate: self)
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
            self?.engineState[taskID] = state
        }
        taskEngines[taskID] = engine
        return engine
    }

    func stopEngine(for taskID: Int) {
        taskEngines[taskID]?.stop()
        taskEngines.removeValue(forKey: taskID)
        engineState.removeEngine(for: taskID)
        engineState.clearMeetingParticipants(for: taskID)
    }

    func stopAllEngines() {
        for (_, engine) in taskEngines {
            engine.stop()
        }
        taskEngines.removeAll()
        engineState.removeAllEngines()
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

    /// Syncs `taskEngineStates` from the run's derived status when no engine exists.
    /// Called after loading/recovering a task on app restart so the UI shows
    /// the correct Resume/Start buttons.
    func syncEngineStateFromRun(taskID: Int, run: Run) {
        guard taskEngines[taskID] == nil else { return }
        switch run.derivedStatus() {
        case .paused:             engineState[taskID] = .paused
        case .failed:             engineState[taskID] = .failed
        case .needsSupervisorInput:      engineState[taskID] = .needsSupervisorInput
        case .done:               engineState[taskID] = .done
        case .needsSupervisorAcceptance: engineState[taskID] = .done
        case .running:
            if !run.steps.isEmpty {
                engineState[taskID] = .paused
            }
        case .waiting:
            engineState[taskID] = .paused
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

        if taskID == activeTaskID {
            // Active task: persist to disk and update in-memory snapshot directly
            // (avoids re-reading project.json, roles.json, tools.json from disk)
            guard var task = activeTask else {
                self.lastErrorMessage = "Cannot persist active task \(taskID): task not loaded."
                return false
            }
            mutate(&task)
            task.updatedAt = MonotonicClock.shared.now()
            do {
                try repository.updateTaskOnly(at: url, task: task)
                applyTaskUpdate(task)
                return true
            } catch {
                self.lastErrorMessage = "Failed to save task: \(error.localizedDescription)"
                return false
            }
        } else {
            // Background task: lightweight persistence
            guard var task = loadedTask(taskID) else {
                self.lastErrorMessage = "Cannot persist task \(taskID): task not loaded."
                return false
            }
            mutate(&task)
            task.updatedAt = MonotonicClock.shared.now()
            do {
                try repository.updateTaskOnly(at: url, task: task)
                snapshot?.loadedTasks[taskID] = task
                return true
            } catch {
                self.lastErrorMessage = "Failed to save task: \(error.localizedDescription)"
                return false
            }
        }
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
    /// - `wf.description`        → `proj.settings.description`
    /// - `wf.descriptionPrompt`  → `proj.settings.descriptionPrompt`
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

