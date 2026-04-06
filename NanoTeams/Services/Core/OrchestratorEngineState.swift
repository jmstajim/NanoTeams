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
    }

    // MARK: - Meeting Participants

    func setMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int) {
        activeMeetingParticipants[taskID] = participantIDs
    }

    func clearMeetingParticipants(for taskID: Int) {
        activeMeetingParticipants[taskID] = nil
    }
}
