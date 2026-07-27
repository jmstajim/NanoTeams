import Foundation

// Multi-engine lifecycle + team-generation tracking + engine-state sync.
// Extracted from the NTMSOrchestrator core (project idiom: this class is
// split across many focused +Extension files).
extension NTMSOrchestrator {

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
                self.clearAutovisorLoopParkLedger(taskID)
            case .failed:
                self.completionAwaiter.deliver(taskID: taskID, outcome: .terminal(.failed))
            case .needsAcceptance:
                self.completionAwaiter.deliver(taskID: taskID, outcome: .terminal(.needsAcceptance))
                self.clearAutovisorLoopParkLedger(taskID)
            case .needsSupervisorInput:
                self.completionAwaiter.deliver(taskID: taskID, outcome: .needsSupervisorInput)
                // A manager pass killed by a reasoning loop reviewed nothing, so the
                // attention baseline it wrote at pass start is a false claim — roll it
                // back once so the next poll can re-deliver. This hook (not a SwiftUI
                // observer) is what makes the recovery work headless too. No-op for
                // every other task and for the healthy `wait_for_events` idle park.
                self.noteAutovisorLoopPark(taskID)
            default:
                break
            }
            // Run-boundary residency sweep: a model de-referenced while this
            // task's streams were open was deferred by the in-use census, and
            // without this the sweep waited for an unrelated settings change.
            self.sweepResidencyAfterEngineTransition(state)
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
        // Kill any background `bash` commands this task started so a detached
        // server/watcher doesn't outlive its task (close / removal / delegation
        // stop / recurrence supersede). Pause does NOT route through here, so a
        // paused-then-resumed run keeps its background commands.
        BackgroundBashRegistry.shared.terminate(taskID: taskID)
    }

    func stopAllEngines() {
        for (_, engine) in taskEngines {
            engine.stop()
        }
        taskEngines.removeAll()
        engineState.removeAllEngines()
        completionAwaiter.cancelAll()
        // Work-folder switch / shutdown: nothing may keep running across folders.
        BackgroundBashRegistry.shared.terminateAll()
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
}
