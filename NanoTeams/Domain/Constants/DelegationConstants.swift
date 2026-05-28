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

    /// Min seconds between two consecutive streaming-buffer scans for the
    /// same child step. Without throttling, the detector would run on every
    /// token append — O(n²) substring search per token kills throughput.
    static let repetitionStreamingThrottleSeconds: TimeInterval = 3

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
