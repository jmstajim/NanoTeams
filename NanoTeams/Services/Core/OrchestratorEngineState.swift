import Foundation
import Observation

/// Extracted observable state for engine and meeting participant tracking.
/// Views that only need to react to engine state changes can observe this object
/// instead of the full `NTMSOrchestrator`, avoiding unnecessary re-evaluations
/// when unrelated orchestrator properties change.
@Observable @MainActor
final class OrchestratorEngineState {

    /// Engine states keyed by task ID.
    private(set) var taskEngineStates: [Int: TeamEngineState] = [:]

    /// Role IDs currently in a meeting, keyed by task ID (for UI badge/glow).
    private(set) var activeMeetingParticipants: [Int: Set<String>] = [:]

    /// Role IDs whose inputs are ready but which are waiting for a concurrency slot, keyed
    /// by task ID (rendered as the "Queued" pill on the role node and its banner).
    ///
    /// An EPHEMERAL projection, exactly like `activeMeetingParticipants` above and for the
    /// same reason: "queued" is a fact about the engine's current dispatch pass, not about
    /// the run. A `RoleExecutionStatus` case would be persisted into `task.json`, where a
    /// build without that case could no longer decode the run at all.
    ///
    /// Keyed by task ID because `StepExecution.id == roleID` (invariant #5): two tasks on
    /// one team share every role id, so a flat set would leak one task's queue into another's
    /// graph.
    private(set) var queuedRoleIDs: [Int: Set<String>] = [:]

    /// Tasks whose run start is in flight: between `claimRunStart` and the moment
    /// `launchRun` hands off to `engine.start()`.
    ///
    /// Two jobs in one set, and they are the same question asked by different callers.
    /// It is the double-start CLAIM — the engine-state guard above cannot see a run
    /// that is still being created across the start's suspension points (task load,
    /// run creation, the agent-instruction and skill rescans), so a concurrent second
    /// call would double-create runs. And it is what the four surfaces render as
    /// "Initializing…": the Team Board navbar, the activity feed, the Quick Capture
    /// panel and the sidebar spinner.
    ///
    /// It lives HERE, and observably, because both jobs are the same fact and a fact
    /// has one home (CLAUDE.md #91). It sat on the orchestrator as an
    /// `@ObservationIgnored` set until 2026-08-27, so the phase was real in the model
    /// and invisible on screen — which is exactly what the user reported once the
    /// launch moved to the background: "the chat opens instantly, but it looks like
    /// nothing is happening".
    ///
    /// NOT a `TeamEngineState` case (CLAUDE.md #95): the claim is held until
    /// `launchRun` RETURNS and `engine.start()` is its last statement, so
    /// "initializing" and `.running` are briefly true AT ONCE. Two simultaneous facts
    /// are two fields; as one enum whichever wrote second would erase the other.
    private(set) var initializingRunTaskIDs: Set<Int> = []

    // MARK: - State Mutation

    subscript(taskID: Int) -> TeamEngineState? {
        get { taskEngineStates[taskID] }
        set { taskEngineStates[taskID] = newValue }
    }

    /// Whether the engine for the given task is actively running or waiting (not idle/done/failed).
    /// Includes `.paused` — a paused run is still active and should block a fresh start.
    func isEngineActive(for taskID: Int) -> Bool {
        guard let state = taskEngineStates[taskID] else { return false }
        return state == .running || state == .paused
            || state == .needsSupervisorInput || state == .needsAcceptance
    }

    /// Whether starting a new run should be blocked for the given task.
    /// Unlike `isEngineActive`, `.paused` does NOT block — the user can abandon
    /// a paused run and start fresh.
    func isNewRunBlocked(for taskID: Int) -> Bool {
        guard let state = taskEngineStates[taskID] else { return false }
        return state == .running || state == .needsSupervisorInput || state == .needsAcceptance
    }

    func removeEngine(for taskID: Int) {
        taskEngineStates.removeValue(forKey: taskID)
    }

    func removeAllEngines() {
        taskEngineStates.removeAll()
        activeMeetingParticipants.removeAll()
        queuedRoleIDs.removeAll()
        // Nothing survives the work-folder boundary — the same contract
        // `stopAllEngines` states for engines and pending launches. A claim left
        // behind would keep a spinner alive for a task id that now names a
        // DIFFERENT task (`NTMSTask.id` is sequential per folder).
        initializingRunTaskIDs.removeAll()
    }

    // MARK: - Run Start

    /// Claims the run start for this task, or reports that one is already in flight.
    ///
    /// `insert().inserted` tests and claims in ONE step, so two callers landing on the
    /// same tick cannot both pass — the property the double-start guards need, and the
    /// reason this is not `contains` followed by `insert`.
    func beginRunStart(_ taskID: Int) -> Bool {
        initializingRunTaskIDs.insert(taskID).inserted
    }

    /// Drops the claim. Idempotent: an abort and the launch's own `defer` both land here.
    func endRunStart(_ taskID: Int) {
        initializingRunTaskIDs.remove(taskID)
    }

    func isInitializingRun(_ taskID: Int) -> Bool {
        initializingRunTaskIDs.contains(taskID)
    }

    // MARK: - Meeting Participants

    func setMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int) {
        activeMeetingParticipants[taskID] = participantIDs
    }

    func clearMeetingParticipants(for taskID: Int) {
        activeMeetingParticipants[taskID] = nil
    }

    // MARK: - Queued Roles

    /// Publishes the waiting-for-a-slot set for one task.
    ///
    /// Writes only on a real change: the engine asks four times a second while a role waits,
    /// and an unconditional write would be four observation ticks a second through every
    /// graph node for a value that did not move (CLAUDE.md #106).
    func setQueuedRoles(_ roleIDs: Set<String>, for taskID: Int) {
        if roleIDs.isEmpty {
            guard queuedRoleIDs[taskID] != nil else { return }
            queuedRoleIDs[taskID] = nil
            return
        }
        guard queuedRoleIDs[taskID] != roleIDs else { return }
        queuedRoleIDs[taskID] = roleIDs
    }

    func clearQueuedRoles(for taskID: Int) {
        setQueuedRoles([], for: taskID)
    }
    nonisolated deinit {}
}
