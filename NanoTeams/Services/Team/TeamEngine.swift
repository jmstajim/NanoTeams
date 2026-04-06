import Foundation

// MARK: - Team Engine Store Protocol

protocol TeamEngineStoreReading: AnyObject {
    var activeTask: NTMSTask? { get }
    var teamSettings: TeamSettings { get }
    /// The currently active team (with embedded roles and artifacts)
    var activeTeam: Team? { get }
    func stepStatus(stepID: String) -> StepStatus?
    func producedArtifactNames() -> Set<String>
}

protocol TeamEngineStoreMutating: AnyObject {
    func updateRoleStatus(roleID: String, status: RoleExecutionStatus) async
    func prepareStepForExecution(stepID: String) async
    func runStep(stepID: String) async
    func findOrCreateStep(roleID: String) async -> String?
    func resetStepForRevision(stepID: String) async
}

protocol TeamEngineStoreReporting: AnyObject {
    func setLastErrorMessageForUI(_ message: String) async
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

        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
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

        // Reset iteration count to allow another full set of iterations
        iterationCount = 0
        state = .running
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcileAfterPause()
            await self.runLoop()
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

}
