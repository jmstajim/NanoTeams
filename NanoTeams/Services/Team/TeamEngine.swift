import Foundation

// MARK: - Team Engine Store Protocol

@MainActor
protocol TeamEngineStoreReading: AnyObject {
    var activeTask: NTMSTask? { get }
    var teamSettings: TeamSettings { get }
    /// The currently active team (with embedded roles and artifacts)
    var activeTeam: Team? { get }
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

    var runTask: Task<Void, Never>?
    var roleTasks: [String: Task<Void, Never>] = [:]
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
        state = .pending
        iterationCount = 0
    }

    func pause() {
        guard state == .running || state == .needsAcceptance || state == .needsSupervisorInput else { return }
        runTask?.cancel()
        runTask = nil
        for task in roleTasks.values { task.cancel() }
        roleTasks.removeAll()
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


    /// Cancels and removes the per-role execution tasks for the given roles so the run
    /// loop will re-spawn them. Used by `restartRole`: a finished role's Task lingers in
    /// `roleTasks` (a normally-returned Task is NOT `.isCancelled`), and `startRoles`'
    /// skip-guard would otherwise skip the role forever — so the restart silently does
    /// nothing. Mirrors what `stop()`/`pause()` do for all roles, scoped to the reset set.
    func cancelRoleTasks(for roleIDs: Set<String>) {
        for roleID in roleIDs {
            roleTasks[roleID]?.cancel()
            roleTasks.removeValue(forKey: roleID)
        }
    }

    /// Called when external event occurs (Supervisor input answered, role restarted, etc.)
    func notifyExternalEvent() {
        if state == .paused || state == .needsAcceptance || state == .needsSupervisorInput
            || state == .done || state == .failed {
            resume()
        }
    }

    func transition(to newState: TeamEngineState) {
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
