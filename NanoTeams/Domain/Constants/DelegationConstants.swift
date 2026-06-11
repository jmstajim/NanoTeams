import Foundation

/// Constants for the role-driven team delegation feature (`delegate_to_team` tool).
nonisolated enum DelegationConstants {
    /// Sentinel `team_id` value passed to `delegate_to_team` to request on-the-fly
    /// team generation from `task_brief`. Never a valid `NTMSID`, so collisions with
    /// real team IDs are impossible.
    static let generatedTeamSentinel = "generated"

    /// Hard cap on delegation chain depth. A task with `delegationDepth == maxDepth`
    /// cannot itself delegate further — the handler returns a `DELEGATION_DENIED` envelope.
    static let maxDelegationDepth = 3

    /// Defensive safety multiplier for cycle guards in tasks-tree traversals
    /// (`TasksIndex.ancestorIDs(of:)`, `TasksIndex.descendantIDs(of:)`, recursive
    /// `pauseRun` / `removeTask` walks). A real chain can never exceed
    /// `maxDelegationDepth`; anything past `maxDelegationDepth * cycleSafetyMultiplier`
    /// indicates a corrupted parent-child link or a cycle and the walk should bail.
    /// Multiplier is generous (10×) so the cap stays well above the runtime cap even
    /// after a few maxDelegationDepth bumps without re-derivation.
    static let cycleSafetyMultiplier = 10

    /// Cycle-safety cap for tree traversals. Computed as
    /// `maxDelegationDepth * cycleSafetyMultiplier`. Single source of truth so a
    /// future bump to `maxDelegationDepth` automatically widens the cap rather than
    /// silently truncating BFS at a hardcoded constant.
    static var treeTraversalSafetyCap: Int {
        maxDelegationDepth * cycleSafetyMultiplier
    }

    /// Per-delegation hard timeout (seconds). If the child team doesn't reach a terminal
    /// state within this window, the handler stops the child engine and returns a
    /// `TIMED_OUT` envelope. Default 30 minutes.
    static let delegationTimeoutSeconds: TimeInterval = 1800

    // MARK: - Auto-detect repetition loop in delegated child team
    // (Streaming-scan throttling moved to `LLMConstants.streamLoopScanCadenceChars`
    // when streaming-loop detection relocated into `performStreamingCall`.)

    /// Min seconds between two consecutive auto-trigger fires for the same
    /// child task. After firing once, the parent role gets a paused envelope;
    /// if it `resume_delegation`-s and the team keeps looping, we don't want
    /// to fire again immediately — let the role's first reaction play out.
    static let repetitionCooldownSeconds: TimeInterval = 30

    /// Min repeats of a substring (consecutive) for within-message detection
    /// to fire. Tuned conservatively — false positives block legitimate work.
    static let repetitionMinRepeats = 5

    /// Min substring length (chars) for within-message detection. Below this
    /// the substring is too small to be a meaningful loop signal (a 3-char
    /// run is usually punctuation noise).
    static let repetitionMinSubstringChars = 8

    /// Max substring length (chars) for within-message detection. Reasoning models
    /// loop on whole *paragraphs* — and even on multi-paragraph *cycles*: seven real
    /// production loops (Autovisor / Coding Assistant thinking buffers) repeated
    /// ~233–1244-char blocks, all silently missed by the prior 200-char cap. The
    /// largest (1244) was a 12-item template cycle (a varying token cycling through a
    /// fixed list). The production path uses the tail-anchored `detectTailLoop`
    /// (O(maxLen²), uniformly cheap), so 1500 covers the observed range with ~1.2×
    /// headroom over the worst (1244) without any perf-vs-coverage tension. (Cycles
    /// longer than 1500 — 15+ varying items — still escape the exact-period detector;
    /// that's its ceiling.) See `RealWorldThinkingLoopDetectionTests`.
    static let repetitionMaxSubstringChars = 1500

    /// Tail window (chars) the within-message scan inspects. Must hold the binding
    /// `period * requiredReps` across the tiers (`500 * 8 = 4000` for large blocks,
    /// `1500 * 4 = 6000` for very-large cycles) plus phase slack so the required
    /// consecutive reps fit regardless of where the window boundary lands. The prior
    /// 2000 window couldn't hold even 5 reps of a ~440-char block, so loops never fired.
    static let repetitionTailWindowChars = 9000

    /// Substring-length threshold separating the "short phrase" regime from the
    /// "paragraph block" regime. At or below this, a repeat needs only
    /// `repetitionMinRepeats` (a short phrase looping 5× is obviously stuck). Above
    /// it, the stricter `repetitionLargeBlockMinRepeats` applies — because a model
    /// legitimately *stamps* a large identical block a few times (scaffolding 5–6
    /// similar test cases / checklist items, then filling them in), whereas a real
    /// loop re-emits it indefinitely. Set below the smallest observed loop period
    /// (233) and above ordinary short phrases.
    static let repetitionLargeSubstringChars = 120

    /// Required consecutive reps for a *large* block (> `repetitionLargeSubstringChars`,
    /// ≤ `repetitionVeryLargeSubstringChars`) to count as a loop. The real loops
    /// repeated 12–70+ times; legitimate "stamp a few identical items then move on"
    /// scaffolding tops out around 5–6, and an adversarial sweep found every false
    /// positive sat at exactly 5 reps with blocks ≤ 488 chars. 8 cleanly separates them.
    static let repetitionLargeBlockMinRepeats = 8

    /// Substring-length threshold for the "very large block / multi-paragraph cycle"
    /// regime. A block this big repeated even a few times is unambiguously a loop — no
    /// legitimate scaffold stamps a >500-char block verbatim (the observed false
    /// positives all sat ≤ 488 chars). Requiring the full `repetitionLargeBlockMinRepeats`
    /// here would also need an impractically large tail window (8 × 1244 ≈ 10K), and
    /// would make the model loop ~10K chars before firing.
    static let repetitionVeryLargeSubstringChars = 500

    /// Required consecutive reps for a *very large* block (> `repetitionVeryLargeSubstringChars`).
    /// 4 verbatim reps of a 500–1500-char block is loop-grade with no realistic
    /// false-positive, and `1500 * 4 = 6000` fits the 9000 tail window.
    static let repetitionVeryLargeBlockMinRepeats = 4

    /// Min consecutive identical `(toolName, argumentsJSON)` pairs in a child
    /// step's `toolCalls` history before the tool-call-sequence detector
    /// fires. The hook reads `step.toolCalls` from inside `commitStreaming`,
    /// which runs BEFORE the current iteration's `appendToolCalls` — so when
    /// `step.toolCalls` already contains 3 identical entries, the model has
    /// just emitted (and is about to persist) a 4th. Effective fire is on
    /// the 4th emit. 3 in persisted history is the smallest threshold safe
    /// against legitimate workflows like read → edit → re-read (which lands
    /// at most 2 identical reads before a write breaks the chain).
    static let repetitionMinIdenticalToolCalls = 3
}
