import Foundation

/// Awaitable primitive that resumes when a task's `TeamEngine` reaches a terminal
/// or supervisor-input state. Used by `handleDelegateToTeam` to block the parent
/// role's tool loop until the child task completes.
///
/// Wired into `NTMSOrchestrator.engineForTask` — the engine's `onStateChanged`
/// callback calls `deliver(...)` whenever the state transitions to one of the
/// outcomes we wait on. The orchestrator's `engineState[taskID]` map remains the
/// authoritative state store for UI; this awaiter is only a notification side-channel.
@MainActor
final class TaskCompletionAwaiter {
    /// Narrow set of engine end-states the awaiter is allowed to deliver.
    /// `TeamEngineState` has 7 cases but only these 3 represent terminal
    /// or acceptance-yield states; the rest (`.idle`, `.running`,
    /// `.paused`, `.needsSupervisorInput`) are non-terminal and produce
    /// other `WaitOutcome` cases (or no delivery at all).
    /// Pinning this as a nested narrow enum makes the consumer-side
    /// `switch` exhaustive without a defensive fall-through arm — and
    /// makes `.terminal(.idle)` (which would have wedged the handler
    /// into a tight loop) unrepresentable.
    enum TerminalOutcome: Equatable {
        case done
        case failed
        case needsAcceptance
    }

    /// What we resume on. `.terminal` covers the engine end-states; `.needsSupervisorInput`
    /// is a yield point — the parent must answer the child's question before the child
    /// can continue, so we let the awaiter wake up to handle it without conflating it
    /// with completion.
    enum WaitOutcome: Equatable {
        case terminal(TerminalOutcome)
        case needsSupervisorInput
        /// The Supervisor queued a message for the parent role while the
        /// child engine was still mid-flight. The handler pauses (does NOT
        /// stop) the child engine and returns the message text to the
        /// parent role's tool loop inside a `paused_by_supervisor` success
        /// envelope; the role then picks `cancel_delegation` /
        /// `resume_delegation` / `forward_to_team` to drive the next step.
        /// Without this wakeup, queued messages for a delegating role would
        /// sit unread until the child finished — defeating the "team is
        /// looping, stop it" feedback loop.
        case parentMessageQueued(text: String)
    }

    private var waiters: [Int: [CheckedContinuation<WaitOutcome, Never>]] = [:]

    /// Suspends until `deliver(taskID:outcome:)` or `cancelAll(taskID:)` is called for
    /// this taskID. Caller is responsible for the fast-path check (i.e. inspect
    /// `engineState[taskID]` first; only register if state is non-terminal). Without
    /// the fast path, an engine that races past the wait state before registration
    /// would never wake the continuation.
    func register(taskID: Int) async -> WaitOutcome {
        await withCheckedContinuation { cont in
            waiters[taskID, default: []].append(cont)
        }
    }

    /// Wakes every continuation registered for `taskID` with `outcome`. Removes the
    /// taskID from the registry — single-shot per registration. If the handler loops
    /// for more outcomes (e.g. multiple `.needsSupervisorInput` followed by `.done`),
    /// it must call `register` again.
    func deliver(taskID: Int, outcome: WaitOutcome) {
        guard let pending = waiters.removeValue(forKey: taskID) else { return }
        for cont in pending { cont.resume(returning: outcome) }
    }

    /// Releases every continuation for `taskID` with `.terminal(.failed)`. Called
    /// from `stopEngine`/`removeTask` so handlers waiting on a torn-down engine
    /// don't hang forever.
    func cancelAll(taskID: Int) {
        guard let pending = waiters.removeValue(forKey: taskID) else { return }
        for cont in pending { cont.resume(returning: .terminal(.failed)) }
    }

    /// Releases every continuation across all tasks with `.terminal(.failed)`.
    /// Called from `stopAllEngines`.
    func cancelAll() {
        let pending = waiters.values.flatMap { $0 }
        waiters.removeAll()
        for cont in pending { cont.resume(returning: .terminal(.failed)) }
    }

    /// Inspect-only — returns `true` iff there is at least one waiter registered for
    /// the given task. Used by tests; not part of the production wake path.
    func hasWaiters(for taskID: Int) -> Bool {
        guard let list = waiters[taskID] else { return false }
        return !list.isEmpty
    }
}
