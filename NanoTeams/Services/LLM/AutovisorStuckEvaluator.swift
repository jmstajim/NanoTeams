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
    /// Which side of the first token a hang was observed on.
    ///
    /// A case rather than a field because the two cannot be true at once —
    /// `processingStatus != nil` partitions the space (#95) — and it lives in the VERDICT
    /// rather than in the wire vocabulary. `wireRow` still says `"hang"`: the manager's remedy
    /// set does not differ (steer or restart), and the kind strings have a second home in the
    /// manager prompt, so a third kind is #91 drift plus prompt budget for a distinction the
    /// consumer cannot act on differently. What DOES differ is the advice weighting, and that
    /// rides in the diagnostic.
    nonisolated enum HangPhase: Equatable, Hashable {
        /// A request is in flight and no generation delta has arrived — model load or prefill.
        case beforeFirstToken
        /// Tokens were flowing and stopped.
        case duringGeneration
    }

    enum StuckVerdict: Equatable, Hashable {
        case notStuck
        case loop(signal: LoopSignal)
        case hang(phase: HangPhase, diagnostic: String)

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
            case .hang(_, let d): return ("hang", d)
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
    /// `processingStatus` is the role's live prompt-processing state, and it is exactly the fact
    /// the pre-token budget needs: `LLMExecutionService+Streaming` sets `.indeterminate` for
    /// EVERY provider right after `beginStreaming`, and the first thinking or content delta
    /// clears it, so non-nil ⟺ a request is in flight with zero generation deltas.
    ///
    /// Chosen over the obvious alternative `hasStreamActivity[key] != true`, which is also nil
    /// when there is no stream AT ALL — between LLM turns, or during synchronous tool
    /// execution — and would hand the larger budget to windows that are not prefill. Same fact,
    /// two possible sources, and only one has the right lifetime (#91).
    static func evaluate(
        step: StepExecution,
        now: Date,
        lastStreamActivityAt: Date?,
        liveStreamText: String? = nil,
        processingStatus: PromptProcessingStatus? = nil,
        hangSeconds: TimeInterval = AutovisorConstants.stuckHangSeconds,
        prefillHangSeconds: TimeInterval = AutovisorConstants.stuckPrefillHangSeconds,
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
        // Same tail walk as the `commitStreaming` caller, from the same home: the
        // eager `filter { $0.role == .assistant }` this replaces materialised the whole
        // assistant history to take its last five (CLAUDE.md #51 — the class had
        // exactly two members and both are here).
        let recentAssistant = CommittedScanInputs.recentAssistantTurns(
            in: step.llmConversation, limit: 5)
        let recentCalls = CommittedScanInputs.recentToolCalls(
            in: step.toolCalls,
            limit: DelegationConstants.repetitionMinIdenticalToolCalls + 5)
        // Bound the tool-call scan at the last UNSOLICITED arrival. Both callers evaluate
        // MANAGED tasks, never the manager itself (`autovisorWatchableTasks` excludes it,
        // and `task_status` inspects another task), so the arrival here is the manager's
        // own `message_task` steering or a human queued chat turn landing in that task's
        // conversation. A role told "focus on the parser instead" and re-reading the file
        // it was pointed at is reacting, not spinning — but the count only RESTARTS at the
        // arrival, so a role that is told something and then really does spin still fires.
        if let signal = LoopScanner.scanCommitted(
            recentAssistant: recentAssistant,
            toolCalls: recentCalls,
            cutoffDate: cutoff,
            informationBoundary: ConversationInformationBoundary.lastArrival(in: step.llmConversation),
            scope: .thinkingAndContent
        ) {
            return .loop(signal: signal)
        }

        // HANG — token silence. Guard 3 (tool in flight) stays FIRST and the ordering is
        // load-bearing: an in-flight tool wins regardless of the pre-token window, and the
        // ordering must not depend on the coincidence that a tool running between LLM turns has
        // no processing status anyway.
        if !AutovisorStatus.hasToolInFlight(step: step) {
            let idle = AutovisorStatus.idleSeconds(
                step: step, now: now, lastStreamActivityAt: lastStreamActivityAt
            )
            // Guard 4: before the first token the server may still be loading or prefilling and
            // emits nothing, so the general budget is the wrong yardstick. A larger one, not
            // silence — see `stuckPrefillHangSeconds` for why suppression was refused.
            let preToken = processingStatus != nil
            if idle > Int(preToken ? prefillHangSeconds : hangSeconds) {
                return .hang(
                    phase: preToken ? .beforeFirstToken : .duringGeneration,
                    diagnostic: preToken
                        ? "no tokens at all for \(idle)s — the request is in flight but the server has not produced its first token, so it may still be loading the model or processing the prompt"
                        : "no tokens or output for \(idle)s while running")
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
        processingStatus: (String) -> PromptProcessingStatus? = { _ in nil },
        hangSeconds: TimeInterval = AutovisorConstants.stuckHangSeconds,
        prefillHangSeconds: TimeInterval = AutovisorConstants.stuckPrefillHangSeconds,
        loopRecencySeconds: TimeInterval = AutovisorConstants.stuckLoopRecencySeconds
    ) -> StuckVerdict {
        guard let run = task.runs.last else { return .notStuck }
        for step in run.steps where step.status == .running {
            let verdict = evaluate(
                step: step, now: now,
                lastStreamActivityAt: lastStreamActivityAt(step.id),
                liveStreamText: liveStreamText(step.id),
                processingStatus: processingStatus(step.id),
                hangSeconds: hangSeconds,
                prefillHangSeconds: prefillHangSeconds,
                loopRecencySeconds: loopRecencySeconds
            )
            if verdict.isStuck { return verdict }
        }
        return .notStuck
    }
}
