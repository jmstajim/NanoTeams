import Foundation

/// A detected loop pattern in tool calls — the FACT only.
///
/// Deliberately carries no message. The text that reaches the model has to name tools,
/// and the only layer that knows the role's schema is `LLMExecutionService.loopWarningMessage`;
/// a message built here can only guess. It guessed wrong for years: the since-deleted
/// `.readOnlyLoop` shipped "Consider making a code change or committing your work" to the
/// built-in Code Reviewer, whose schema (SystemTemplates+RoleTemplates) is read-only plus
/// `create_artifact` — it can neither edit nor commit, and there is no tool call to reject,
/// so nothing corrects it. Worse, the GUI arm of `.repetitiveTool` deliberately said "do NOT
/// try different arguments, re-capture the screen", and the generic tail in
/// `loopWarningMessage` then appended "change the arguments" right after it.
///
/// A loop is REPETITION — the same call performed again — never a tool CATEGORY. There is
/// deliberately no "all reads" case: `.readOnlyLoop` was a pure tool-name predicate over the
/// window, so six reads of six DIFFERENT files — the ordinary opening of any task, and the
/// exact sequence the planning-phase brief prescribes ("explore with read-only tools, then
/// record findings") — fired it every time, with a message claiming the model was re-reading
/// files it had each read once. Standing first, it also masked `.repetitiveTool` for every
/// all-read window, replacing the honest "identical arguments" diagnosis with a false one.
nonisolated enum LoopDetection: Equatable {
    /// Every call in the window was a scratchpad write: the role is re-planning instead of acting.
    case repetitivePlanning(count: Int)
    /// One tool called with identical arguments `count` times IN A ROW — an unbroken
    /// trailing run over the successful, non-excluded calls in the window, bounded by
    /// the last INFORMATION EPOCH change (see `TrackedCall.informationEpoch`).
    case repetitiveTool(tool: String, count: Int)
    /// The same call FAILED `count` times in a row, identically. A separate case from
    /// `.repetitiveTool` rather than a widening of it, because the two describe opposite
    /// situations and want opposite advice: a repeated SUCCESS means the world is not
    /// changing, a repeated FAILURE means the call cannot succeed as written.
    ///
    /// `.repetitiveTool` is blind to this by design — `visibleCalls` filters on
    /// `wasSuccessful`, so a run of N identical failures has a trailing run of 0 for any
    /// N — and that blindness is correct for the question IT answers (a failed edit
    /// changed nothing, so identical rebuilds around it still describe an unchanged
    /// state). It is not correct as the whole system's answer: the 2026-08-13 gemma run
    /// sent four byte-identical failing `edit_file` calls and got no warning at all,
    /// leaving `maxNonProductiveTurns` — twenty turns away — as the only backstop.
    ///
    /// `errorCode` is the runtime's typed code, a FACT like the other payloads here; the
    /// advice built from it stays in `loopWarningMessage`, which is the only layer that
    /// knows the role's schema.
    case repetitiveFailure(tool: String, count: Int, errorCode: String?)
}

/// Stateless loop detection for tool call sequences.
/// Operates on a snapshot of recent calls from ToolCallTracker.
nonisolated enum ToolCallLoopDetector {

    private typealias TN = ToolNames

    /// Size of the tail window every branch reasons over.
    static let windowSize = 6

    /// Tools whose identical-argument repetition is PRESCRIBED usage, never a loop.
    /// Admission rule: a tool joins this set only when repeating the SAME arguments is
    /// the tool's own documented contract — not merely "its arguments are often equal"
    /// (`run_xcodebuild`'s constant args are cured by tail-anchoring below, not exclusion).
    ///
    /// - `update_scratchpad`: the tracker drops byte-identical content, so tracked calls
    ///   are always DIFFERENT plans; the all-scratchpad window belongs to
    ///   `.repetitivePlanning`.
    /// - `screen_capture`: re-capturing the SAME target is the computer-use workflow —
    ///   the UI changes between calls, that's the point — and counting it made the
    ///   nudge advise the very action it flagged.
    /// - `bash_output`: polling a background command is the contract `bash` itself
    ///   prescribes (its run_in_background envelope hands the model `bash_output` plus
    ///   the same command_id via `NextHint`), the arguments legitimately repeat, and
    ///   every read returns NEW incremental output — "the state isn't changing" would
    ///   be false.
    private static let excludedFromRepetition: Set<String> = [
        TN.updateScratchpad, TN.screenCapture, TN.bashOutput,
    ]

    /// Detects if recent calls form a loop pattern.
    /// - Parameter recentCalls: The last N tracked calls (typically limit: 6).
    static func detectLoopPattern(in recentCalls: [ToolCallTracker.TrackedCall]) -> LoopDetection? {
        // Checked BEFORE the window guard, and that placement is the point. A failure run
        // of three IS the whole signal; requiring six calls first makes the commonest
        // shape — a model retrying one broken call — invisible until it has burned twice
        // as many turns. It is also checked before `.repetitiveTool`: when the newest
        // calls are identical failures, that is the LIVE condition, whereas the trailing
        // run over `visibleCalls` can only describe successes that already stopped.
        if let failure = detectRepetitiveFailure(in: recentCalls) { return failure }

        guard recentCalls.count >= windowSize else { return nil }

        // A window that is nothing but scratchpad writes is a role re-planning instead of
        // acting. It never reaches the branch below — the repetition counter excludes
        // `update_scratchpad` — so before this arm existed a plan spin produced NO warning
        // at all, while `loopWarningMessage` carried a tool-aware "execute step 1 now"
        // ladder for a `.repetitiveTool(tool: update_scratchpad)` value that
        // `detectLoopPattern` could never construct. The tracker already drops
        // byte-identical scratchpad content, so six tracked calls are six DIFFERENT plans.
        if recentCalls.allSatisfy({ $0.toolName == TN.updateScratchpad }) {
            return .repetitivePlanning(count: recentCalls.count)
        }

        // Detect TRUE repetition: an unbroken TRAILING run of one call. Identity is
        // (tool, argumentsIdentity) — canonical arguments JSON, NOT the display summary
        // (see `TrackedCall.argumentsIdentity`; counting by tool name alone falsely
        // flagged legitimate scaffolding streaks in run EA190834). Consecutive and
        // tail-anchored, matching the committed-history sibling
        // (`MessageRepetitionDetector.detectIdenticalToolCallSequence`) and the
        // constant's own contract ("min CONSECUTIVE identical pairs").
        //
        // The previous FREQUENCY count over the window fired on interleaved repeats, and
        // the prescribed coding cycle interleaves by construction: run_xcodebuild's
        // arguments are legitimately constant, so edit(a)→build→edit(b)→build→edit(c)→
        // build was reported as "identical arguments 3 times and the state isn't
        // changing" — both halves false, every edit HAD changed the state (2026-08-11,
        // same class as the deleted `.readOnlyLoop`). A repeat the model RETURNS to
        // after doing something else is a workflow; a repeat with nothing between is a
        // loop.
        //
        // Failed and excluded calls are INVISIBLE — they neither extend nor break the
        // run. A failed edit changed nothing, so identical rebuilds around it still
        // describe an unchanged state honestly; only a DIFFERENT successful,
        // non-excluded call breaks it. Two accepted consequences, both normally
        // absorbed by the warn-once gate (the check runs every iteration, so the fire
        // lands at the run's own tail): the message's "in a row" reads over the
        // invisible calls, and a run followed by nothing but failed/excluded calls can
        // fire one iteration late — at which point the state has still not changed.
        // A run is also bounded by the last INFORMATION EPOCH: a call breaks it, and so
        // does information PUSHED at the model that no call of its own asked for — a
        // queued Supervisor turn delivered mid-loop (human steering, the Autovisor's
        // mid-review event notice, `message_task`). Those are `.user` messages, not tool
        // calls, so without this the prescribed reaction to being told a task changed —
        // re-checking it — read as "identical arguments N times and the state isn't
        // changing" immediately after being told the state changed. Deliberately NOT the
        // answer to a call the model made (a consultation reply, an `ask_supervisor`
        // answer): that lands after the call, so counting it would let a model spinning
        // on THAT tool refresh its own boundary with every repeat.
        //
        // The boundary is NOT immunity: it resets the count. The flagged call still
        // COUNTS (it was made knowing the new information); only what precedes it is
        // excluded. So a model that receives an event and then repeats one call three
        // times still fires — which is the whole point, since the actor most in need of
        // policing here (the Autovisor manager) is also the one events arrive for. That
        // claim holds end-to-end only because `loopWarningSignature` is scoped to the
        // epoch too: the once-per-condition gate would otherwise suppress the post-
        // boundary fire under the signature the pre-boundary run inserted.
        //
        // Scope: `.repetitiveTool` only. `.repetitivePlanning` returns above and is
        // deliberately left unbounded — six consecutive scratchpad rewrites are a role
        // re-planning instead of acting no matter what arrived while it did so.
        //
        // Because the epoch is an ORDINAL stamped on each call rather than a "starts here"
        // flag, a boundary that landed on an INVISIBLE call needs no special handling: the
        // calls after it carry the new epoch whether or not the detector can see the one it
        // landed on. That matters because the likeliest move right after an event is
        // `update_scratchpad` — excluded — and a flag there would have been swallowed
        // precisely when the model did the prescribed thing.
        let visible = Self.visibleCalls(in: recentCalls)
        guard let lastCall = visible.last else { return nil }
        let lastIdentity = CallIdentity(tool: lastCall.toolName, arguments: lastCall.argumentsIdentity)
        var trailingRun = 0
        for call in visible.reversed() {
            guard CallIdentity(tool: call.toolName, arguments: call.argumentsIdentity)
                    == lastIdentity else { break }
            guard call.informationEpoch == lastCall.informationEpoch else { break }
            trailingRun += 1
        }
        guard trailingRun >= DelegationConstants.repetitionMinIdenticalToolCalls else { return nil }
        return .repetitiveTool(tool: lastCall.toolName, count: trailingRun)
    }

    /// Which information epoch the run `detectLoopPattern` would report lives in — the
    /// epoch of the newest call the detector can SEE, or `0` when it can see none.
    ///
    /// `LLMExecutionService.loopWarningSignature` scopes its once-per-condition gate to
    /// this, deliberately NOT to `ToolCallTracker.informationEpoch`. The tracker's value
    /// advances the instant a Supervisor turn is delivered, which is before the model has
    /// made a single call under it; keying the gate on that re-armed the warning and
    /// appended a second identical nudge about a run made entirely BEFORE the news. This
    /// value moves only once the run itself does.
    static func epochOfTrailingRun(in recentCalls: [ToolCallTracker.TrackedCall]) -> Int {
        // When the failure arm is the one that fires, the gate has to key on ITS run.
        // `visibleCalls` cannot see failures, so for a pure-failure window it answers 0 —
        // a frozen signature that could never re-arm after an event arrived mid-run,
        // which is the exact defect the epoch scoping exists to prevent.
        if detectRepetitiveFailure(in: recentCalls) != nil, let last = recentCalls.last {
            return last.informationEpoch
        }
        return visibleCalls(in: recentCalls).last?.informationEpoch ?? 0
    }

    /// An unbroken TRAILING run of the SAME call failing the same way.
    ///
    /// Deliberately does not reuse `visibleCalls`: that filter exists to make failures
    /// invisible, which is exactly what this arm must see. Everything else mirrors
    /// `.repetitiveTool` so the two cannot drift — identity is `(tool, argumentsIdentity)`,
    /// the run is tail-anchored and consecutive, it is bounded by the information epoch
    /// (a model told the world moved and then retrying is in a new situation), and the
    /// threshold is the same `repetitionMinIdenticalToolCalls`.
    ///
    /// Excluded tools are NOT skipped here. Their exclusion is justified by identical
    /// arguments being each tool's own documented contract — `bash_output` polling the
    /// same command id, `screen_capture` re-shooting the same target — and none of those
    /// contracts covers FAILING three times running.
    static func detectRepetitiveFailure(
        in recentCalls: [ToolCallTracker.TrackedCall]
    ) -> LoopDetection? {
        guard let last = recentCalls.last, !last.wasSuccessful else { return nil }
        let identity = CallIdentity(tool: last.toolName, arguments: last.argumentsIdentity)

        var trailingRun = 0
        for call in recentCalls.reversed() {
            guard !call.wasSuccessful else { break }
            guard CallIdentity(tool: call.toolName, arguments: call.argumentsIdentity) == identity
            else { break }
            guard call.informationEpoch == last.informationEpoch else { break }
            trailingRun += 1
        }
        guard trailingRun >= DelegationConstants.repetitionMinIdenticalToolCalls else { return nil }

        return .repetitiveFailure(
            tool: last.toolName, count: trailingRun, errorCode: Self.errorCode(in: last))
    }

    /// The typed `error.code` out of a tracked call's result envelope, when it carries one.
    private static func errorCode(in call: ToolCallTracker.TrackedCall) -> String? {
        guard let dict = JSONUtilities.parseJSONDictionary(call.resultJSON),
              let error = dict["error"] as? [String: Any],
              let code = error["code"] as? String,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return code
    }

    /// Successful, non-excluded calls in order. Failed and excluded calls are INVISIBLE to
    /// every question this type answers, so both consumers share one definition of "the
    /// calls that count" rather than re-deriving it and drifting.
    private static func visibleCalls(
        in recentCalls: [ToolCallTracker.TrackedCall]
    ) -> [ToolCallTracker.TrackedCall] {
        recentCalls.filter { $0.wasSuccessful && !excludedFromRepetition.contains($0.toolName) }
    }

    /// Grouping key. A struct rather than a joined string: the old `"\(tool)\u{1F}\(summary)"`
    /// key had to be split back apart to recover the tool name, which a tool name or an
    /// argument containing U+001F would have corrupted.
    private struct CallIdentity: Hashable {
        let tool: String
        let arguments: Int
    }
}
