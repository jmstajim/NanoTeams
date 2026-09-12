import Foundation

// MARK: - Team Engine Store Protocol

@MainActor
protocol TeamEngineStoreReading: AnyObject {
    var activeTask: NTMSTask? { get }
    var teamSettings: TeamSettings { get }
    /// The currently active team (with embedded roles and artifacts)
    var activeTeam: Team? { get }
    /// How many roles of this task may execute at once, or `nil` for "the app imposes no
    /// limit" (`RoleConcurrencyMode.providerLimited`).
    ///
    /// Deliberately NO default implementation in a protocol extension: there are exactly two
    /// conformers, and a defaulted `nil` would let a forgotten adapter switch the whole
    /// feature off in silence rather than fail to compile.
    var maxConcurrentRoles: Int? { get }
    func stepStatus(stepID: String) -> StepStatus?
    func producedArtifactNames() -> Set<String>
}

@MainActor
protocol TeamEngineStoreMutating: AnyObject {
    func updateRoleStatus(roleID: String, status: RoleExecutionStatus) async
    func prepareStepForExecution(stepID: String) async
    func runStep(stepID: String) async
    func findOrCreateStep(roleID: String) async -> String?
    func resetStepForRevision(stepID: String) async
}

@MainActor
protocol TeamEngineStoreReporting: AnyObject {
    func setLastErrorMessageForUI(_ message: String)
}

typealias TeamEngineStore = TeamEngineStoreReading & TeamEngineStoreMutating & TeamEngineStoreReporting

// MARK: - Team Engine State

enum TeamEngineState: String, CaseIterable, Hashable {
    case pending
    case running
    case paused
    case needsAcceptance = "needs_acceptance"
    case needsSupervisorInput = "needs_supervisor_input"
    case done
    case failed
}

// MARK: - Team Engine

/// Orchestrates role execution based on artifact dependencies.
@MainActor
final class TeamEngine {
    var store: TeamEngineStore?

    private(set) var state: TeamEngineState = .pending {
        didSet {
            guard oldValue != state else { return }
            onStateChanged?(state)
        }
    }

    var onStateChanged: ((TeamEngineState) -> Void)?
    var onRoleStatusChanged: ((String, RoleExecutionStatus) -> Void)?

    /// Fires when the set of roles that are ready but waiting for a concurrency slot
    /// changes. An EPHEMERAL projection, deliberately not a `RoleExecutionStatus` case:
    /// "queued" is a fact about this engine's current pass, not about the run, and adding
    /// a persisted case would make `task.json` undecodable on any build without it.
    var onQueuedRolesChanged: ((Set<String>) -> Void)?

    /// Roles that could run right now but are waiting for a slot. Published, never stored.
    private(set) var queuedRoleIDs: Set<String> = []

    var runTask: Task<Void, Never>?
    var roleTasks: [String: Task<Void, Never>] = [:]

    /// Monotonic per-role launch stamp. `roleTasks` alone cannot answer "is this role
    /// executing?": a Task that returned normally is NOT `.isCancelled`, so its record
    /// lingers forever — which is exactly why `cancelRoleTasks` has to exist. Each launch
    /// stamps a generation and evicts its OWN record on exit, so a record in `roleTasks`
    /// means a live execution and `hasLiveRoleTask` can be believed.
    private var roleTaskGeneration: [String: Int] = [:]

    /// The occupancy set observed on the previous slot-wait pass. See `runLoop`.
    var lastSlotWaitOccupancy: Set<String>?

    /// The newest `updatedAt` across in-flight steps, observed on the previous WORKING-wait
    /// pass. See the working-wait branch in `runLoop` for why the watchdog needs it.
    var lastWorkingWaitProgress: Date?

    private var autoIterationLimitOverride: Int?  // For testing only
    var iterationCount: Int = 0

    /// Get the auto iteration limit from team settings or use default
    var autoIterationLimit: Int {
        if let override = autoIterationLimitOverride {
            return override
        }
        return store?.teamSettings.limits.autoIterationLimit ?? 10000
    }

    // MARK: - Initialization

    init(store: TeamEngineStore? = nil) {
        self.store = store
    }

    func attach(store: TeamEngineStore) {
        self.store = store
    }

    func setAutoIterationLimitForTesting(_ limit: Int) {
        autoIterationLimitOverride = max(1, limit)
    }

    // MARK: - Control

    func start() {
        guard state != .running && state != .needsAcceptance && state != .needsSupervisorInput else { return }
        stop()
        state = .running
        iterationCount = 0
        launchRunLoop()
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        for task in roleTasks.values {
            task.cancel()
        }
        roleTasks.removeAll()
        roleTaskGeneration.removeAll()
        publishQueuedRoles([])
        lastSlotWaitOccupancy = nil
        lastWorkingWaitProgress = nil
        state = .pending
        iterationCount = 0
    }

    func pause() {
        guard state == .running || state == .needsAcceptance || state == .needsSupervisorInput else { return }
        runTask?.cancel()
        runTask = nil
        for task in roleTasks.values { task.cancel() }
        roleTasks.removeAll()
        roleTaskGeneration.removeAll()
        publishQueuedRoles([])
        lastSlotWaitOccupancy = nil
        lastWorkingWaitProgress = nil
        state = .paused
    }

    func resume() {
        guard state != .running else { return }

        // Cancel any surviving loop before launching a replacement — `start()` (via `stop()`)
        // and `pause()` both do this, and `resume()` was the one member of the trio that did
        // not. A non-`.running` state does NOT prove the previous `runTask` is finished: only
        // `stop()` / `pause()` cancel it, so any path that writes the state directly
        // (`transition(to:)` from outside the loop) leaves a live loop behind, and
        // `launchRunLoop()` would then reassign `runTask` — orphaning the old one to keep
        // reconciling and starting roles against the same store.
        runTask?.cancel()

        // Reset iteration count to allow another full set of iterations
        iterationCount = 0
        lastSlotWaitOccupancy = nil
        state = .running
        launchRunLoop()
    }

    /// The one launcher both `start()` and `resume()` use, so the invariant "a launched
    /// run loop always begins from a reconciled state" cannot drift between them.
    ///
    /// `start()` used to skip `reconcileAfterPause()`, and that asymmetry is where the
    /// restart-review bug hid: `resumeRun` deliberately takes the `start()` branch after
    /// an app restart (the freshly-created engine is `.pending`), so the one path that
    /// most needed reconciliation was the one that never got it.
    private func launchRunLoop() {
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcileAfterPause()
            await self.runLoop()
        }
    }


    /// Cancels and removes the per-role execution tasks for the given roles so the run loop
    /// will re-spawn them. Used by `restartRole`, which resets roles and steps underneath a
    /// possibly-live execution: cancelling is what stops the old one from writing over the
    /// reset. Mirrors what `stop()`/`pause()` do for all roles, scoped to the reset set.
    ///
    /// Until `launchRoleTask` started evicting finished records, this ALSO had to exist to
    /// un-stick `startRoles` — a Task that returned normally is not `.isCancelled`, so its
    /// record lingered and the skip-guard skipped the role forever. That half is now handled
    /// at the source; the cancellation half is still this method's own job.
    func cancelRoleTasks(for roleIDs: Set<String>) {
        for roleID in roleIDs {
            roleTasks[roleID]?.cancel()
            roleTasks.removeValue(forKey: roleID)
            roleTaskGeneration.removeValue(forKey: roleID)
        }
    }

    /// Registers `body` as THE live execution for `roleID`, replacing whatever record the
    /// previous one left behind, and evicts its own record when it returns.
    ///
    /// The eviction is what makes `hasLiveRoleTask` meaningful, and the generation stamp is
    /// what keeps it honest: a task that finishes after a newer one was launched for the
    /// same role must not delete the newer one's record.
    func launchRoleTask(
        roleID: String,
        _ body: @escaping @MainActor (TeamEngine, TeamEngineStore) async -> Void
    ) {
        let generation = (roleTaskGeneration[roleID] ?? 0) + 1
        roleTaskGeneration[roleID] = generation
        roleTasks[roleID] = Task { [weak self] in
            guard let self, let store = self.store else { return }
            await body(self, store)
            guard self.roleTaskGeneration[roleID] == generation else { return }
            self.roleTasks.removeValue(forKey: roleID)
            self.roleTaskGeneration.removeValue(forKey: roleID)
        }
    }

    /// Whether this role has an execution in flight right now.
    func hasLiveRoleTask(_ roleID: String) -> Bool {
        guard let task = roleTasks[roleID] else { return false }
        return !task.isCancelled
    }

    /// The role IDs of every in-flight execution.
    func liveRoleTaskIDs() -> Set<String> {
        Set(roleTasks.filter { !$0.value.isCancelled }.keys)
    }

    /// Publishes the waiting-for-a-slot set, and only when it actually changed — the run
    /// loop asks four times a second and an unconditional write would be four observation
    /// ticks a second through every graph node (CLAUDE.md #106).
    func publishQueuedRoles(_ roleIDs: Set<String>) {
        guard queuedRoleIDs != roleIDs else { return }
        queuedRoleIDs = roleIDs
        onQueuedRolesChanged?(roleIDs)
    }

    /// Called when external event occurs (Supervisor input answered, role restarted, etc.)
    func notifyExternalEvent() {
        if state == .paused || state == .needsAcceptance || state == .needsSupervisorInput
            || state == .done || state == .failed {
            resume()
        }
    }

    func transition(to newState: TeamEngineState) {
        // Nothing waits for a slot in a run that is no longer running.
        if newState != .running { publishQueuedRoles([]) }
        state = newState
    }

    // MARK: - Query Methods

    /// Get all roles that are currently working
    func workingRoles() -> [String] {
        guard let run = store?.activeTask?.runs.last else { return [] }
        return run.roleStatuses.compactMap { (roleID, status) in
            status == .working ? roleID : nil
        }
    }

    /// Get all roles pending acceptance
    func pendingAcceptanceRoles() -> [String] {
        guard let run = store?.activeTask?.runs.last else { return [] }
        return AcceptanceService.getPendingAcceptances(roleStatuses: run.roleStatuses)
    }

    nonisolated deinit {}
}
