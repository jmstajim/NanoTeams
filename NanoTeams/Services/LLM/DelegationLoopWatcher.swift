import Foundation

/// Watches delegated child tasks for pathologically repetitive output and
/// auto-triggers the Pause-and-Decide flow on detection. Runs the
/// `MessageRepetitionDetector` in four places:
///
///  - Streaming buffer (throttled to once every
///    `DelegationConstants.repetitionStreamingThrottleSeconds`) — catches
///    mid-stream loops in thinking AND content. Critical for reasoning
///    models that loop in `thinking` and never commit a finalized message.
///  - On `commitStreaming` of a finalized child message — single-pass scan,
///    cheap.
///  - On append to child step's `llmConversation` — across-messages overlap
///    check (catches strategic loops where each iteration regenerates
///    similar content). Caller feeds `thinking + content` joined per
///    message so tool-only assistant turns (empty `content`) still
///    contribute their reasoning text to the LCS comparison.
///  - On the same commit boundary, `considerToolCallSequence` scans the
///    step's recent `toolCalls` for N consecutive identical
///    `(name, argsJSON)` pairs — the most precise signal for tool-spam
///    loops where the model just keeps re-calling the same tool. This is
///    the only mode that catches loops where every assistant turn has
///    empty `content` and the entire signal lives in the structurally
///    identical tool-call payload.
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

    /// Per-child-step last-streaming-scan timestamp. Used for throttling
    /// — `considerStreamingBuffer` runs at most once every
    /// `repetitionStreamingThrottleSeconds` per step.
    private var lastStreamingScanByStep: [String: Date] = [:]

    init(orchestrator: NTMSOrchestrator? = nil) {
        self.orchestrator = orchestrator
    }

    func bind(orchestrator: NTMSOrchestrator) {
        self.orchestrator = orchestrator
    }

    // MARK: - Streaming-time detection

    /// Throttled hook — call from the streaming pipeline for child tasks
    /// after each significant buffer growth. Combines content + thinking
    /// into a single haystack (a loop in either should fire).
    func considerStreamingBuffer(
        taskID: Int,
        stepID: String,
        content: String,
        thinking: String
    ) {
        guard let orchestrator else { return }
        guard isChildTask(taskID, in: orchestrator) else { return }
        let now = MonotonicClock.shared.now()
        if let last = lastStreamingScanByStep[stepID],
           now.timeIntervalSince(last) < DelegationConstants.repetitionStreamingThrottleSeconds {
            return
        }
        // NOTE: throttle stamp is moved BELOW the cooldown / detection /
        // fire path. Setting it eagerly here was a bug — when
        // `notifyDelegationInterrupt` returns false (no waiter; race window
        // with `startRunForTask`), the cooldown is correctly not set
        // (`fireInterrupt` is conservative there), but the throttle would
        // already be burned, swallowing the next legitimate signal for
        // `repetitionStreamingThrottleSeconds`. Stamp only after we've
        // either decided "no signal worth processing" (no match) or
        // successfully fired.
        if isInCooldown(taskID: taskID, now: now) {
            // We already fired recently; throttle the next scan to keep the
            // cooldown well-defined. Otherwise back-to-back token deltas
            // would each pay the substring-search cost only to find the
            // cooldown.
            lastStreamingScanByStep[stepID] = now
            return
        }
        let combined = thinking + "\n" + content
        guard let match = MessageRepetitionDetector.detectWithinMessage(
            combined,
            minSubstringChars: DelegationConstants.repetitionMinSubstringChars,
            minRepeats: DelegationConstants.repetitionMinRepeats
        ) else {
            // No signal — throttle so we don't redo the search next token.
            lastStreamingScanByStep[stepID] = now
            return
        }
        let fired = fireInterrupt(
            childTaskID: taskID,
            scope: "streaming",
            diagnostic: match.diagnostic,
            now: now,
            orchestrator: orchestrator
        )
        if fired {
            lastStreamingScanByStep[stepID] = now
        }
        // If we DIDN'T fire (no waiter — extremely transient race),
        // intentionally leave the throttle alone so the very next scan can
        // try again. The cost is one extra detector pass per token; the
        // benefit is that a 3s window of detector silence doesn't develop
        // when the parent role hasn't quite registered yet.
    }

    // MARK: - Post-commit detection

    /// Runs once per finalized message on a child task. Cheap — single
    /// detector pass.
    func considerCommittedMessage(
        taskID: Int,
        stepID _: String,
        content: String,
        thinking: String?
    ) {
        guard let orchestrator else { return }
        guard isChildTask(taskID, in: orchestrator) else { return }
        let now = MonotonicClock.shared.now()
        if isInCooldown(taskID: taskID, now: now) { return }
        let combined = (thinking ?? "") + "\n" + content
        guard let match = MessageRepetitionDetector.detectWithinMessage(
            combined,
            minSubstringChars: DelegationConstants.repetitionMinSubstringChars,
            minRepeats: DelegationConstants.repetitionMinRepeats
        ) else { return }
        fireInterrupt(
            childTaskID: taskID,
            scope: "committed message",
            diagnostic: match.diagnostic,
            now: now,
            orchestrator: orchestrator
        )
    }

    // MARK: - Across-messages detection

    /// Compares the last N messages of the child step's role for
    /// strategic-loop overlap. Call after each new assistant message lands
    /// on `step.llmConversation`.
    func considerConversation(taskID: Int, recentRoleMessages: [String]) {
        guard let orchestrator else { return }
        guard isChildTask(taskID, in: orchestrator) else { return }
        let now = MonotonicClock.shared.now()
        if isInCooldown(taskID: taskID, now: now) { return }
        guard let match = MessageRepetitionDetector.detectAcrossMessages(recentRoleMessages) else { return }
        fireInterrupt(
            childTaskID: taskID,
            scope: "across messages",
            diagnostic: match.diagnostic,
            now: now,
            orchestrator: orchestrator
        )
    }

    // MARK: - Tool-call sequence detection

    /// Fires when the child step's recent tool-call history ends in
    /// `DelegationConstants.repetitionMinIdenticalToolCalls` consecutive
    /// identical `(name, argsJSON)` pairs. The strongest deterministic
    /// signal for tool-spam loops — works even when every assistant turn
    /// has empty `content` (the across-messages mode goes blind in that
    /// case because the LCS denominator collapses).
    ///
    /// **`createdAt` filter (defends against revision-history false
    /// positive).** `resetStepForRevision` retains `step.toolCalls` for
    /// audit, so the persisted suffix can include calls from a previous
    /// round that already triggered a fire. Without filtering, the cooldown
    /// would expire (30s, often less than a revision round), then the very
    /// first new call of the next round would land on a suffix where most
    /// entries are old-and-already-counted, causing instant re-fire on
    /// behavior the user already saw and acted on. We filter
    /// `recentCalls` to those strictly newer than the last successful
    /// trigger before handing them to the (stateless) detector — pre-fire
    /// history doesn't count against us twice. Caller passes
    /// `(name, argsJSON, createdAt)` triples; tuple ordering matches
    /// `StepToolCall` field names so the call site is grep-able.
    func considerToolCallSequence(
        taskID: Int,
        recentCalls: [(name: String, argsJSON: String, createdAt: Date)]
    ) {
        guard let orchestrator else { return }
        guard isChildTask(taskID, in: orchestrator) else { return }
        let now = MonotonicClock.shared.now()
        if isInCooldown(taskID: taskID, now: now) { return }
        let cutoff = lastTriggerByChildTask[taskID] ?? .distantPast
        let filtered = recentCalls
            .filter { $0.createdAt > cutoff }
            .map { (name: $0.name, argsJSON: $0.argsJSON) }
        guard let match = MessageRepetitionDetector.detectIdenticalToolCallSequence(
            filtered,
            minRepeats: DelegationConstants.repetitionMinIdenticalToolCalls
        ) else { return }
        fireInterrupt(
            childTaskID: taskID,
            scope: "tool-call repetition",
            diagnostic: match.diagnostic,
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
    /// `considerToolCallSequence` cutoff-filter regression: we need to
    /// simulate "the watcher already fired N seconds ago, cooldown has
    /// expired" without standing up a full awaiter + child engine + waiter
    /// resolution dance just to plant one timestamp.
    func _testForceTrigger(forTaskID taskID: Int, at when: Date) {
        lastTriggerByChildTask[taskID] = when
    }
    /// Inspect-only — exposes the per-step throttle stamp so the I4 fix
    /// (don't burn throttle when `notifyDelegationInterrupt` returns false
    /// during the no-waiter race) is regression-testable. Without this
    /// seam, reverting the I4 stamp-only-on-fire branch would silently
    /// swallow the next legitimate signal — no test failure.
    func _testLastStreamingScan(forStepID stepID: String) -> Date? {
        lastStreamingScanByStep[stepID]
    }
    #endif
}
