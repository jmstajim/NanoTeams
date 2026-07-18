import Foundation

/// Watches delegated child tasks for pathologically repetitive output and
/// auto-triggers the Pause-and-Decide flow on detection. Detection itself is
/// shared (`LoopScanner` → `MessageRepetitionDetector`); this class owns the
/// child-task cooldown and the fire (`notifyDelegationInterrupt`) at two entry
/// points:
///
///  - `noteStreamLoop(taskID:stepID:signal:)` — reactive, in-stream. The scan
///    runs inside `performStreamingCall` (the stream consumer, where the
///    buffers live); this just applies the per-task cooldown and fires. Returns
///    whether the in-stream scanner should advance its throttle baseline (the
///    relocated I4 invariant — see the method doc). Critical for reasoning
///    models that loop in `thinking` and never commit a finalized message.
///  - `considerCommitted(taskID:recentAssistant:toolCalls:)` — post-commit. One
///    `LoopScanner.scanCommitted` pass over the finalized conversation +
///    tool-call history (tool-call sequence → within-message → across-messages,
///    first signal wins; the per-task `lastTrigger` is the `createdAt` cutoff that
///    defends against revision-retained history). Replaces the prior three separate
///    hooks.
///
/// On detection, calls `orchestrator.notifyDelegationInterrupt(...)` with
/// an auto-generated diagnostic — the parent role's awaiter wakes up the
/// same way as if the human Supervisor had queued a chat message, and the
/// existing pause-and-decide envelope flows through. The role then chooses
/// `cancel_delegation` / `resume_delegation` / `forward_to_team`.
///
/// Per-task cooldown (`repetitionCooldownSeconds`) prevents flapping: after
/// firing once, the same child task can't trigger again until the parent
/// role's reaction plays out. Without cooldown, a `resume_delegation` on a
/// genuinely-stuck team would fire the detector again on the next token,
/// trapping the role in a loop of paused envelopes.
@MainActor
final class DelegationLoopWatcher {

    private weak var orchestrator: NTMSOrchestrator?

    /// Per-child-task last-fire timestamp. Used for cooldown.
    private var lastTriggerByChildTask: [Int: Date] = [:]

    init(orchestrator: NTMSOrchestrator? = nil) {
        self.orchestrator = orchestrator
    }

    func bind(orchestrator: NTMSOrchestrator) {
        self.orchestrator = orchestrator
    }

    // MARK: - Streaming-time detection

    /// Reactive in-stream entry for a CHILD task's streaming loop. Detection
    /// (`LoopScanner.scanStreaming`) now runs inside `performStreamingCall` (the
    /// stream consumer, where the buffers live); this applies the per-task
    /// cooldown and fires the parent interrupt.
    ///
    /// Returns whether the in-stream scanner should ADVANCE its throttle baseline:
    ///  - `true`  — cooldown active (no point re-scanning) OR a fire succeeded.
    ///  - `false` — the no-waiter race (`fireInterrupt` returned false). Hold the
    ///    throttle so the next legitimate signal isn't swallowed once the parent
    ///    awaiter registers. This is the I4 invariant, relocated from the old
    ///    `lastStreamingScanByStep` stamp logic into the scanner's growth counter.
    @discardableResult
    func noteStreamLoop(taskID: Int, stepID _: String, signal: LoopSignal) -> Bool {
        guard let orchestrator else { return true }
        guard isChildTask(taskID, in: orchestrator) else { return true }
        let now = MonotonicClock.shared.now()
        if isInCooldown(taskID: taskID, now: now) { return true }
        return fireInterrupt(
            childTaskID: taskID,
            scope: signal.scope,
            diagnostic: signal.diagnostic,
            now: now,
            orchestrator: orchestrator
        )
    }

    // MARK: - Post-commit detection

    /// Runs once per `commitStreaming` boundary on a child task. Scans the
    /// finalized conversation + tool-call history via `LoopScanner.scanCommitted`
    /// (tool-call sequence → within-message → across-messages, first signal wins)
    /// and fires the parent interrupt. Replaces the prior three separate hooks
    /// (`considerCommittedMessage` / `considerConversation` /
    /// `considerToolCallSequence`).
    ///
    /// **`createdAt` cutoff (revision-retained-history guard).**
    /// `resetStepForRevision` retains `step.toolCalls`/`llmConversation` for
    /// audit, so the persisted suffix can include entries from a previous round
    /// that already triggered a fire. The cutoff = this child's last successful
    /// trigger; `scanCommitted` drops everything `createdAt <= cutoff` before
    /// running the detectors, so pre-fire history doesn't re-fire after the 30s
    /// cooldown expires (often shorter than a revision round). Before any fire the
    /// cutoff is `.distantPast` → nothing filtered (identical to the legacy
    /// pre-fire behavior).
    func considerCommitted(
        taskID: Int,
        recentAssistant: [(thinking: String?, content: String, createdAt: Date)],
        toolCalls: [(name: String, argsJSON: String, createdAt: Date)]
    ) {
        guard let orchestrator else { return }
        guard isChildTask(taskID, in: orchestrator) else { return }
        let now = MonotonicClock.shared.now()
        if isInCooldown(taskID: taskID, now: now) { return }
        let cutoff = lastTriggerByChildTask[taskID] ?? .distantPast
        guard let signal = LoopScanner.scanCommitted(
            recentAssistant: recentAssistant,
            toolCalls: toolCalls,
            cutoffDate: cutoff,
            scope: .thinkingAndContent
        ) else { return }
        fireInterrupt(
            childTaskID: taskID,
            scope: signal.scope,
            diagnostic: signal.diagnostic,
            now: now,
            orchestrator: orchestrator
        )
    }

    // MARK: - Private

    private func isChildTask(_ taskID: Int, in orchestrator: NTMSOrchestrator) -> Bool {
        orchestrator.loadedTask(taskID)?.parentTaskID != nil
    }

    private func isInCooldown(taskID: Int, now: Date) -> Bool {
        guard let last = lastTriggerByChildTask[taskID] else { return false }
        return now.timeIntervalSince(last) < DelegationConstants.repetitionCooldownSeconds
    }

    /// Walks the `parentTaskID`/`parentRoleID` chain from a child task up to
    /// the IMMEDIATE parent (one level up — that's the role whose handler
    /// is suspended on `awaitTaskTerminalState(taskID: childTID)`).
    private func resolveImmediateParent(
        childTaskID: Int,
        orchestrator: NTMSOrchestrator
    ) -> (parentTaskID: Int, parentRoleID: String)? {
        guard let child = orchestrator.loadedTask(childTaskID),
              let parentTID = child.parentTaskID,
              let parentRID = child.parentRoleID
        else { return nil }
        return (parentTID, parentRID)
    }

    /// Returns `true` iff a waiter was actually woken — the cooldown is set
    /// only on success. The caller may also use the return value to decide
    /// whether to update its throttle stamp.
    @discardableResult
    private func fireInterrupt(
        childTaskID: Int,
        scope: String,
        diagnostic: String,
        now: Date,
        orchestrator: NTMSOrchestrator
    ) -> Bool {
        guard let parent = resolveImmediateParent(childTaskID: childTaskID, orchestrator: orchestrator)
        else { return false }
        let teamName = orchestrator.loadedTask(childTaskID).map { orchestrator.resolvedTeam(for: $0).name } ?? "child team"
        let message = "[Auto-detected loop in \(teamName) (\(scope))]: \(diagnostic). The team appears stuck — decide whether to cancel, resume, or forward guidance."
        let woken = orchestrator.notifyDelegationInterrupt(
            parentTaskID: parent.parentTaskID,
            parentRoleID: parent.parentRoleID,
            text: message
        )
        if woken {
            lastTriggerByChildTask[childTaskID] = now
        }
        // If `notifyDelegationInterrupt` returned false (no waiter — unusual:
        // the child was running but parent isn't actually awaiting), we
        // intentionally don't set cooldown. The next legitimate signal will
        // try again rather than silently swallowing.
        return woken
    }

    // MARK: - Test seam

    #if DEBUG
    func _testLastTrigger(forTaskID taskID: Int) -> Date? {
        lastTriggerByChildTask[taskID]
    }
    /// Inject-only test seam — plant a `lastTrigger` timestamp without
    /// running the real `fireInterrupt` path. Required by the
    /// `considerCommitted` cutoff-filter regression: we need to
    /// simulate "the watcher already fired N seconds ago, cooldown has
    /// expired" without standing up a full awaiter + child engine + waiter
    /// resolution dance just to plant one timestamp.
    ///
    /// **`when` MUST be a `MonotonicClock.shared.now()` stamp, not a `Date()`.**
    /// `isInCooldown` compares it against `MonotonicClock.shared.now()`, which
    /// returns `max(Date(), last + 1ms)` and only heals via `reset()` — so over a
    /// test worker's lifetime it drifts arbitrarily far ahead of wall clock. A
    /// wall-clock stamp reads as already-expired the moment that drift exceeds
    /// `repetitionCooldownSeconds`, silently turning a cooldown assertion into a
    /// scheduling-dependent flake. Pinned by
    /// `DelegationLoopWatcherTests.testWatcher_cooldown_holdsUnderMonotonicClockDrift`.
    func _testForceTrigger(forTaskID taskID: Int, at when: Date) {
        lastTriggerByChildTask[taskID] = when
    }
    #endif
}
