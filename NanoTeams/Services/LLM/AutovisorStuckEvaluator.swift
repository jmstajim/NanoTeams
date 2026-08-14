import Foundation

/// Detects that a `.running` role is pathologically stuck — caught in a tool/output
/// loop, or hung (token silence). Pure + `nonisolated`: the live stream signals
/// (last-activity timestamp + current thinking/content buffer) are injected as
/// parameters (read from `StreamingPreviewManager` by the caller), so this stays
/// orchestrator-free and trivially unit-testable.
///
/// Lives in Services (not Domain) because it routes through `LoopScanner`
/// (→ `MessageRepetitionDetector`) — the same detection pipeline
/// `DelegationLoopWatcher` uses for delegated children. Timing facts come from
/// `AutovisorStatus` (Domain). Both the manager's `task_status` tool (pull) and the
/// per-minute poll backstop (push) call through here, so a single verdict definition
/// drives both surfaces.
nonisolated enum AutovisorStuckEvaluator {

    /// Verdict that a `.running` role is stuck. Modeled as a sum type so the
    /// "diagnostic is meaningful iff stuck" invariant is unrepresentable-when-violated
    /// (no bool + correlated optionals). `wireRow` confines the LLM-facing
    /// `"loop"`/`"hang"` string to the boundary; the in-memory model switches on cases.
    enum StuckVerdict: Equatable, Hashable {
        case notStuck
        case loop(signal: LoopSignal)
        case hang(diagnostic: String)

        var isStuck: Bool {
            if case .notStuck = self { return false }
            return true
        }

        /// `(kind, detail)` for the `task_status` JSON row, or nil when not stuck.
        /// A single accessor so the consumer never re-correlates two independent
        /// optionals (the exact smell the sum-type refactor removed). The wire
        /// string is unchanged by the `LoopSignal` migration — `signal.diagnostic`
        /// is the same one-liner the old `loop(diagnostic:)` carried.
        var wireRow: (kind: String, detail: String)? {
            switch self {
            case .notStuck: return nil
            case .loop(let s): return ("loop", s.diagnostic)
            case .hang(let d): return ("hang", d)
            }
        }
    }

    /// Evaluates a single step. Returns `.notStuck` unless the role is actively
    /// `.running`, not blocked on a delegation, and one of:
    ///  - LOOP — same tool re-called with identical args; a single buffer (live
    ///    stream OR a recent committed turn) repeats a substring; or recent role
    ///    outputs heavily overlap (strategic loop).
    ///  - HANG — no token / progress / message / tool-call activity for longer than
    ///    `stuckHangSeconds`, AND no tool is currently in flight.
    ///
    /// `liveStreamText` is the role's CURRENT (uncommitted) thinking+content buffer.
    /// It is the only signal that catches a reasoning model looping inside its
    /// thinking phase without ever committing — there it has at most one (empty)
    /// assistant message (so across-messages is blind) and tokens keep `idle` near
    /// zero (so the hang path never fires).
    ///
    /// The tool-call / across-messages / committed-within loop modes are gated on
    /// `stuckLoopRecencySeconds`: the repeating signal must be recent.
    /// `resetStepForRevision` retains `toolCalls` + `llmConversation` for audit, so
    /// without this a stale trailing run from a prior attempt would re-flag a
    /// just-restarted role. Each mode checks the recency of its OWN collection (a new
    /// turn pre-creating an empty `llmConversation` entry must not unblock the
    /// stale-tool-call check, and vice-versa). The live buffer is inherently current,
    /// so it is not recency-gated.
    static func evaluate(
        step: StepExecution,
        now: Date,
        lastStreamActivityAt: Date?,
        liveStreamText: String? = nil,
        hangSeconds: TimeInterval = AutovisorConstants.stuckHangSeconds,
        loopRecencySeconds: TimeInterval = AutovisorConstants.stuckLoopRecencySeconds
    ) -> StuckVerdict {
        // Guard 1 (state) + Guard 2 (delegation): a role parked on `delegate_to_team`
        // emits nothing while the child works — its child is watched separately by
        // `DelegationLoopWatcher`, and restarting the parent would orphan the child.
        guard step.status == .running, step.activeDelegationChildID == nil else {
            return .notStuck
        }

        // LOOP — within the LIVE buffer (reasoning models loop in thinking and never
        // commit; nothing else sees it). Inherently current → NOT recency-gated, so it
        // goes through `scanStreaming` (the no-recency entry). `liveStreamText` is the
        // delegate's already-combined thinking+content buffer, so `.thinkingOnly` scans
        // it verbatim (tail-anchored `detectTailLoop`).
        if let live = liveStreamText,
           let signal = LoopScanner.scanStreaming(thinking: live, content: "", scope: .thinkingOnly) {
            return .loop(signal: signal)
        }

        // LOOP — committed history (tool-call sequence → within-message → across-messages),
        // recency-gated via `cutoffDate`. `scanCommitted` filters `createdAt > cutoff`, so
        // stale pre-revision history (retained by `resetStepForRevision`) is excluded —
        // the same guard the old per-mode `lastCall`/`lastMsg` recency checks provided.
        let cutoff = now.addingTimeInterval(-loopRecencySeconds)
        let recentAssistant = step.llmConversation
            .filter { $0.role == .assistant }
            .suffix(5)
            .map { (thinking: $0.thinking, content: $0.content, createdAt: $0.createdAt) }
        let recentCalls = step.toolCalls
            .suffix(DelegationConstants.repetitionMinIdenticalToolCalls + 5)
            .map { (name: $0.name, argsJSON: $0.argumentsJSON, createdAt: $0.createdAt) }
        // Bound the tool-call scan at the last UNSOLICITED arrival. Both callers evaluate
        // MANAGED tasks, never the manager itself (`autovisorWatchableTasks` excludes it,
        // and `task_status` inspects another task), so the arrival here is the manager's
        // own `message_task` steering or a human queued chat turn landing in that task's
        // conversation. A role told "focus on the parser instead" and re-reading the file
        // it was pointed at is reacting, not spinning — but the count only RESTARTS at the
        // arrival, so a role that is told something and then really does spin still fires.
        if let signal = LoopScanner.scanCommitted(
            recentAssistant: Array(recentAssistant),
            toolCalls: Array(recentCalls),
            cutoffDate: cutoff,
            informationBoundary: ConversationInformationBoundary.lastArrival(in: step.llmConversation),
            scope: .thinkingAndContent
        ) {
            return .loop(signal: signal)
        }

        // HANG — token silence. Guard 3: suppress while a tool is legitimately running.
        if !AutovisorStatus.hasToolInFlight(step: step) {
            let idle = AutovisorStatus.idleSeconds(
                step: step, now: now, lastStreamActivityAt: lastStreamActivityAt
            )
            if idle > Int(hangSeconds) {
                return .hang(diagnostic: "no tokens or output for \(idle)s while running")
            }
        }

        return .notStuck
    }

    /// Task-level verdict: the first stuck `.running` step in the latest run.
    /// `lastStreamActivityAt` / `liveStreamText` map a step id to its live signals.
    static func evaluate(
        task: NTMSTask,
        now: Date,
        lastStreamActivityAt: (String) -> Date?,
        liveStreamText: (String) -> String? = { _ in nil },
        hangSeconds: TimeInterval = AutovisorConstants.stuckHangSeconds,
        loopRecencySeconds: TimeInterval = AutovisorConstants.stuckLoopRecencySeconds
    ) -> StuckVerdict {
        guard let run = task.runs.last else { return .notStuck }
        for step in run.steps where step.status == .running {
            let verdict = evaluate(
                step: step, now: now,
                lastStreamActivityAt: lastStreamActivityAt(step.id),
                liveStreamText: liveStreamText(step.id),
                hangSeconds: hangSeconds,
                loopRecencySeconds: loopRecencySeconds
            )
            if verdict.isStuck { return verdict }
        }
        return .notStuck
    }
}
