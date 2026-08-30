import XCTest
@testable import NanoTeams

/// Pins `AutovisorStuckEvaluator` — the single verdict definition behind both
/// `task_status` (pull) and the per-minute push wake. Covers the loop modes,
/// the token-silence hang, and all three false-positive guards (fresh tokens,
/// in-flight tool, active delegation).
final class AutovisorStuckEvaluatorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func step(
        status: StepStatus = .running,
        createdAt: Date,
        messages: [StepMessage] = [],
        toolCalls: [StepToolCall] = [],
        llm: [LLMMessage] = [],
        activeDelegationChildID: Int? = nil
    ) -> StepExecution {
        StepExecution(
            id: "engineering_team_software_engineer", role: .codingAgent, title: "SWE",
            status: status, createdAt: createdAt, updatedAt: createdAt,
            messages: messages, toolCalls: toolCalls, llmConversation: llm,
            activeDelegationChildID: activeDelegationChildID
        )
    }

    private func toolCall(_ name: String, _ args: String, resultJSON: String? = "{}", at: Date) -> StepToolCall {
        StepToolCall(createdAt: at, name: name, argumentsJSON: args, resultJSON: resultJSON)
    }

    // MARK: - Loop

    func testLoop_identicalToolCalls() {
        let recent = now.addingTimeInterval(-5)
        let calls = (0..<DelegationConstants.repetitionMinIdenticalToolCalls).map {
            toolCall("read_file", #"{"path":"a.swift"}"#, at: recent.addingTimeInterval(Double($0)))
        }
        let s = step(createdAt: now.addingTimeInterval(-30), toolCalls: calls)
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now)
        XCTAssertTrue(v.isStuck)
        XCTAssertEqual(v.wireRow?.kind, "loop")
    }

    func testLoop_acrossMessages() {
        let line = "Reading the configuration file, but it is too large to load, let me try again."
        // Explicit RECENT createdAt so the loop-recency gate is exercised deterministically.
        let msgs = (0..<3).map { _ in
            LLMMessage(createdAt: now.addingTimeInterval(-5), role: .assistant, content: line)
        }
        // Fresh token activity — proves the LOOP path fires even when NOT idle.
        let s = step(createdAt: now.addingTimeInterval(-30), llm: msgs)
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now)
        XCTAssertTrue(v.isStuck)
        XCTAssertEqual(v.wireRow?.kind, "loop")
    }

    func testLoop_staleToolCalls_recencyGate_notFlagged() {
        // resetStepForRevision retains toolCalls. A trailing run of identical calls
        // from a PRIOR attempt (older than stuckLoopRecencySeconds) must NOT re-flag a
        // restarted role as looping — and the gap here (<stuckHangSeconds) isn't a hang.
        let stale = now.addingTimeInterval(-(AutovisorConstants.stuckLoopRecencySeconds + 10))
        let calls = (0..<DelegationConstants.repetitionMinIdenticalToolCalls).map {
            toolCall("read_file", #"{"path":"a.swift"}"#, at: stale.addingTimeInterval(Double($0)))
        }
        let s = step(createdAt: now.addingTimeInterval(-200), toolCalls: calls)
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: nil)
        XCTAssertFalse(v.isStuck, "stale identical tool calls (pre-revision) must not flag a loop")
    }

    // MARK: - Loop / information boundary

    /// The reported false positive. An event notice reaches the manager mid-review as
    /// an injected `.user` turn ("task 7 now needs input"); the prescribed reply is to
    /// re-check that task, which to a tool-call scan looks like the same call again.
    /// Only the calls made after the arrival may be counted together.
    ///
    /// RED: drop `informationBoundary:` from the evaluator's `scanCommitted` call →
    /// this flags `.loop`, the manager is woken with "the team appears stuck", and the
    /// remedy it is handed is to restart a role that is behaving correctly.
    func testLoop_identicalToolCalls_splitByAnEventNotice_notFlagged() {
        let first = now.addingTimeInterval(-9)
        let calls = (0..<DelegationConstants.repetitionMinIdenticalToolCalls).map {
            toolCall("task_status", #"{"task_id":7}"#, at: first.addingTimeInterval(Double($0) * 2))
        }
        // News lands between the first poll and the rest.
        let notice = LLMMessage(
            createdAt: first.addingTimeInterval(1),
            role: .user,
            content: "Supervisor:\nTask 7 now needs input.",
            sourceContext: .supervisorMessage
        )
        let s = step(createdAt: now.addingTimeInterval(-60), toolCalls: calls, llm: [notice])
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now)
        XCTAssertFalse(
            v.isStuck,
            "Re-checking a task right after being told it changed is the prescribed reaction, not a loop"
        )
    }

    /// The cross-agent form of self-immunization, pinned through the Autovisor consumer —
    /// the one `ConversationInformationBoundary.lastArrival` caller whose verdict drives an
    /// ACTION (`restart_role`) rather than a log line.
    ///
    /// The manager writes most revision comments on a task it manages (`manage_role` →
    /// `requestRevision`). If `.supervisorFeedback` opened a boundary, a manager spinning on
    /// request-changes would refresh its own cutoff with every repeat and could never be
    /// scored as stuck — the same trap `.retryNudge` is kept out of on the in-run side, one
    /// agent further out.
    ///
    /// RED: flip `.supervisorFeedback` to `true` in `carriesUnsolicitedInformation` → this
    /// fails, and a manager wedged in a revision cycle stops being detected.
    func testLoop_identicalToolCalls_splitByItsOwnRevisionFeedback_stillFlagged() {
        let first = now.addingTimeInterval(-9)
        let calls = (0..<DelegationConstants.repetitionMinIdenticalToolCalls).map {
            toolCall("task_status", #"{"task_id":7}"#, at: first.addingTimeInterval(Double($0) * 2))
        }
        // Feedback the MANAGER itself caused, landing in the same slot the event notice
        // occupies in the test above — the only difference is the context.
        let feedback = LLMMessage(
            createdAt: first.addingTimeInterval(1),
            role: .user,
            content: MessageSourceContext.supervisorFeedbackPrefix + "Fix the citations.",
            sourceRole: .supervisor,
            sourceContext: .supervisorFeedback
        )
        let s = step(createdAt: now.addingTimeInterval(-60), toolCalls: calls, llm: [feedback])
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now)
        XCTAssertTrue(
            v.isStuck,
            "a revision comment is not news arriving on a cadence the manager cannot control "
                + "— it is the manager's own output, so it must not reset the loop cutoff"
        )
    }

    /// The boundary resets the count; it does not grant immunity. A manager that gets
    /// an event and THEN spins on one call is still stuck.
    ///
    /// RED: make the boundary suppress the tool scan outright → this fails, and a
    /// genuinely wedged manager stays invisible for as long as events keep arriving.
    func testLoop_identicalToolCalls_afterAnEventNotice_stillFlagged() {
        let notice = LLMMessage(
            createdAt: now.addingTimeInterval(-30),
            role: .user,
            content: "Supervisor:\nTask 7 now needs input.",
            sourceContext: .supervisorMessage
        )
        let first = now.addingTimeInterval(-9)
        let calls = (0..<DelegationConstants.repetitionMinIdenticalToolCalls).map {
            toolCall("task_status", #"{"task_id":7}"#, at: first.addingTimeInterval(Double($0)))
        }
        let s = step(createdAt: now.addingTimeInterval(-60), toolCalls: calls, llm: [notice])
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now)
        XCTAssertTrue(v.isStuck, "A full run made after the arrival is a spin")
        XCTAssertEqual(v.wireRow?.kind, "loop")
    }

    /// Self-cancellation guard at the evaluator level: the repetition warning is
    /// persisted as `.retryNudge`, so if that counted as external information the
    /// detector would clear its own floor every time it fired.
    ///
    /// RED: classify `.retryNudge` as external information → this stops flagging, and
    /// a spinning role becomes permanently undetectable once warned.
    func testLoop_retryNudgeBetweenIdenticalCalls_stillFlagged() {
        let first = now.addingTimeInterval(-9)
        let calls = (0..<DelegationConstants.repetitionMinIdenticalToolCalls).map {
            toolCall("task_status", #"{"task_id":7}"#, at: first.addingTimeInterval(Double($0) * 2))
        }
        let nudge = LLMMessage(
            createdAt: first.addingTimeInterval(1),
            role: .user,
            content: "You've called task_status 3 times in a row…",
            sourceContext: .retryNudge
        )
        let s = step(createdAt: now.addingTimeInterval(-60), toolCalls: calls, llm: [nudge])
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now)
        XCTAssertTrue(v.isStuck, "The detector's own warning must not reset the detector")
    }

    func testLoop_liveThinkingBuffer() {
        // Reasoning model looping inside its thinking phase, never committing: no tool
        // calls, one empty assistant message, tokens flowing (idle ≈ 0 → not a hang).
        // Only the live-buffer within-message check catches it.
        let live = String(repeating: "Wait, let me reconsider. ", count: 6)
        let s = step(createdAt: now.addingTimeInterval(-30),
                     llm: [LLMMessage(createdAt: now, role: .assistant, content: "")])
        let v = AutovisorStuckEvaluator.evaluate(
            step: s, now: now, lastStreamActivityAt: now, liveStreamText: live)
        XCTAssertTrue(v.isStuck)
        XCTAssertEqual(v.wireRow?.kind, "loop")
    }

    func testLoop_committedThinkingWithinMessage() {
        // A single committed turn whose thinking repeats — across-messages is blind
        // (needs 3 messages); the within-message check on the recent turn catches it.
        let thinking = String(repeating: "Wait, let me reconsider. ", count: 6)
        let s = step(createdAt: now.addingTimeInterval(-30),
                     llm: [LLMMessage(createdAt: now.addingTimeInterval(-5), role: .assistant,
                                      content: "", thinking: thinking)])
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now)
        XCTAssertTrue(v.isStuck)
        XCTAssertEqual(v.wireRow?.kind, "loop")
    }

    func testLoop_staleAcrossMessages_recencyGate_notFlagged() {
        // Symmetric twin of the stale-tool-calls test: overlapping assistant messages
        // from a PRIOR attempt (older than stuckLoopRecencySeconds) must NOT flag a
        // loop. Keys off recentAssistant.last.createdAt, a DIFFERENT timestamp than the
        // tool-call gate — guards against the two gates being swapped.
        let stale = now.addingTimeInterval(-(AutovisorConstants.stuckLoopRecencySeconds + 10))
        let line = "Reading the configuration file, but it is too large to load, let me try again."
        let msgs = (0..<3).map { _ in LLMMessage(createdAt: stale, role: .assistant, content: line) }
        // createdAt close enough that the gap isn't a hang either (< stuckHangSeconds).
        let s = step(createdAt: now.addingTimeInterval(-135), llm: msgs)
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: nil)
        XCTAssertFalse(v.isStuck, "stale overlapping messages (pre-revision) must not flag a loop")
    }

    func testLoop_mixedRecencyAcrossMessages_onlyFreshLastSurvives_notFlagged() {
        // The refactor changed across-messages gating from "if the LAST turn is recent,
        // feed ALL retained turns (incl. stale) to detectAcrossMessages" to a per-entry
        // `createdAt > cutoff` filter. So a window whose last turn is fresh but whose
        // earlier identical turns are stale (pre-revision) now drops the stale ones
        // individually — only the 1 fresh turn survives → across-messages can't fire
        // (needs ≥3) and the single fresh line doesn't repeat within itself. The OLD
        // code WOULD have flagged this; this pins the new, stricter semantics.
        let line = "Reading the configuration file, but it is too large to load, let me try again."
        let stale = now.addingTimeInterval(-(AutovisorConstants.stuckLoopRecencySeconds + 10))
        let recent = now.addingTimeInterval(-5)
        let msgs = [
            LLMMessage(createdAt: stale, role: .assistant, content: line),
            LLMMessage(createdAt: stale, role: .assistant, content: line),
            LLMMessage(createdAt: recent, role: .assistant, content: line),  // only this survives the cutoff
        ]
        // Fresh token activity → not a hang either, so a non-`.notStuck` verdict could
        // only come from the loop path we're asserting stays silent.
        let s = step(createdAt: now.addingTimeInterval(-30), llm: msgs)
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now)
        XCTAssertFalse(v.isStuck,
                       "Mixed recency: only the fresh last turn survives the per-entry cutoff → across-messages must not fire")
    }

    // MARK: - Hang

    func testHang_tokenSilence() {
        let old = now.addingTimeInterval(-(AutovisorConstants.stuckHangSeconds + 60))
        let s = step(createdAt: old)
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: nil)
        XCTAssertTrue(v.isStuck)
        XCTAssertEqual(v.wireRow?.kind, "hang")
    }

    func testNotHang_freshTokens() {
        // Same silence in persisted data, but tokens are flowing right now → not hung.
        let old = now.addingTimeInterval(-(AutovisorConstants.stuckHangSeconds + 60))
        let s = step(createdAt: old)
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now.addingTimeInterval(-2))
        XCTAssertFalse(v.isStuck)
    }

    func testNotHang_toolInFlight() {
        // A single long-running tool (no result yet) emits no tokens but is working.
        let old = now.addingTimeInterval(-(AutovisorConstants.stuckHangSeconds + 60))
        let inFlight = toolCall("run_xcodebuild", #"{}"#, resultJSON: nil, at: old)
        let s = step(createdAt: old, toolCalls: [inFlight])
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: nil)
        XCTAssertFalse(v.isStuck, "an in-flight tool must suppress the hang verdict")
    }

    func testHang_thresholdIsStrict() {
        // idle EXACTLY == threshold must NOT hang (`>` not `>=`); +1 must.
        let atThreshold = now.addingTimeInterval(-AutovisorConstants.stuckHangSeconds)
        XCTAssertFalse(
            AutovisorStuckEvaluator.evaluate(step: step(createdAt: atThreshold), now: now, lastStreamActivityAt: nil).isStuck,
            "idle == threshold is not yet a hang")
        let pastThreshold = now.addingTimeInterval(-(AutovisorConstants.stuckHangSeconds + 1))
        XCTAssertTrue(
            AutovisorStuckEvaluator.evaluate(step: step(createdAt: pastThreshold), now: now, lastStreamActivityAt: nil).isStuck,
            "idle == threshold + 1 is a hang")
    }

    // MARK: - Guards

    func testNotStuck_activeDelegation() {
        let old = now.addingTimeInterval(-(AutovisorConstants.stuckHangSeconds + 60))
        let s = step(createdAt: old, activeDelegationChildID: 42)
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: nil)
        XCTAssertFalse(v.isStuck, "a role parked on delegate_to_team is not stuck")
    }

    func testNotStuck_notRunning() {
        let old = now.addingTimeInterval(-(AutovisorConstants.stuckHangSeconds + 60))
        let s = step(status: .done, createdAt: old)
        let v = AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: nil)
        XCTAssertFalse(v.isStuck)
    }

    // MARK: - Task-level + timing

    func testTaskLevel_firstStuckRunningStep() {
        let old = now.addingTimeInterval(-(AutovisorConstants.stuckHangSeconds + 60))
        let doneStep = step(status: .done, createdAt: old)
        var hung = step(createdAt: old)
        hung.id = "engineering_team_tech_lead"
        let task = NTMSTask(id: 7, title: "T", supervisorTask: "...",
                            runs: [Run(id: 0, steps: [doneStep, hung])])
        let v = AutovisorStuckEvaluator.evaluate(task: task, now: now, lastStreamActivityAt: { _ in nil })
        XCTAssertTrue(v.isStuck)
        XCTAssertEqual(v.wireRow?.kind, "hang")
    }

    func testIdleSeconds_clampsNegative() {
        // createdAt in the future (MonotonicClock can sit a hair ahead of `now`).
        let s = step(createdAt: now.addingTimeInterval(100))
        XCTAssertEqual(AutovisorStatus.idleSeconds(step: s, now: now, lastStreamActivityAt: nil), 0)
    }

    // MARK: - Custom thresholds (user-tunable via AutovisorTuning)

    func testHang_customHangSeconds_overridesDefault() {
        // idle ≈ 120s: under the 180s default (not a hang), over a custom 60s (hang).
        let s = step(createdAt: now.addingTimeInterval(-120))
        XCTAssertFalse(
            AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: nil).isStuck,
            "120s idle is under the 180s default hang threshold")
        let v = AutovisorStuckEvaluator.evaluate(
            step: s, now: now, lastStreamActivityAt: nil, hangSeconds: 60)
        XCTAssertTrue(v.isStuck, "a custom 60s hang threshold flags 120s idle")
        XCTAssertEqual(v.wireRow?.kind, "hang")
    }

    func testLoop_customLoopRecency_widensWindow() {
        // Identical calls ~128s old: outside the 120s default recency (not flagged),
        // inside a custom 600s window (flagged). Fresh tokens keep the hang path quiet
        // so the LOOP verdict is what's under test.
        let old = now.addingTimeInterval(-130)
        let calls = (0..<DelegationConstants.repetitionMinIdenticalToolCalls).map {
            toolCall("read_file", #"{"path":"a.swift"}"#, at: old.addingTimeInterval(Double($0)))
        }
        let s = step(createdAt: now.addingTimeInterval(-200), toolCalls: calls)
        XCTAssertFalse(
            AutovisorStuckEvaluator.evaluate(step: s, now: now, lastStreamActivityAt: now).isStuck,
            "the loop is outside the 120s default recency window")
        let v = AutovisorStuckEvaluator.evaluate(
            step: s, now: now, lastStreamActivityAt: now, loopRecencySeconds: 600)
        XCTAssertTrue(v.isStuck, "a custom 600s recency window flags the older loop")
        XCTAssertEqual(v.wireRow?.kind, "loop")
    }

    func testTaskLevel_customThresholds_threadThrough() {
        // The task-level overload must forward both thresholds to the step-level pass.
        var hung = step(createdAt: now.addingTimeInterval(-120))
        hung.id = "engineering_team_tech_lead"
        let task = NTMSTask(id: 7, title: "T", supervisorTask: "...",
                            runs: [Run(id: 0, steps: [hung])])
        XCTAssertFalse(
            AutovisorStuckEvaluator.evaluate(task: task, now: now, lastStreamActivityAt: { _ in nil }).isStuck,
            "120s idle is under the default hang threshold at task level")
        let v = AutovisorStuckEvaluator.evaluate(
            task: task, now: now, lastStreamActivityAt: { _ in nil }, hangSeconds: 60)
        XCTAssertTrue(v.isStuck, "custom hangSeconds must thread through the task-level overload")
        XCTAssertEqual(v.wireRow?.kind, "hang")
    }
    // MARK: - Pre-token window (D-17)
    //
    // `processingStatus != nil` means a request is in flight and NOT ONE generation delta has
    // arrived — the server may still be loading the model or processing the prompt, and in that
    // window Ollama emits nothing at all (measured: 103.5 s cold prefill at 38.5k tokens). The
    // general hang budget is calibrated on a server that is already producing tokens, so this
    // window gets a larger one. NOT silence: suppressing the verdict entirely would blind the
    // detector exactly where "prefilling" and "wedged" are indistinguishable.

    /// RED: delete the `processingStatus != nil` branch so `hangSeconds` applies always → a
    /// healthy prefill is flagged `.hang`, and the manager is handed `restart` as the remedy.
    func testNotHang_beforeFirstToken_underPrefillBudget() {
        let idle = AutovisorConstants.stuckHangSeconds + 120
        let v = AutovisorStuckEvaluator.evaluate(
            step: step(createdAt: now.addingTimeInterval(-idle)), now: now,
            lastStreamActivityAt: nil, processingStatus: .indeterminate)
        XCTAssertFalse(v.isStuck, "still inside the pre-token budget")
    }

    /// RED: make the pre-token branch return `.notStuck` unconditionally — D-17 as originally
    /// written → a genuinely wedged Ollama becomes permanently invisible.
    func testHang_beforeFirstToken_overPrefillBudget() {
        let idle = AutovisorConstants.stuckPrefillHangSeconds + 1
        let v = AutovisorStuckEvaluator.evaluate(
            step: step(createdAt: now.addingTimeInterval(-idle)), now: now,
            lastStreamActivityAt: nil, processingStatus: .indeterminate)
        XCTAssertTrue(v.isStuck)
        XCTAssertEqual(v.wireRow?.kind, "hang", "the wire vocabulary must NOT grow a third kind")
    }

    /// RED: apply `prefillHangSeconds` unconditionally → a mid-response stall stops being
    /// reported for a further seven minutes.
    func testHang_duringGeneration_keepsTheShorterBudget() {
        let idle = AutovisorConstants.stuckHangSeconds + 1
        let v = AutovisorStuckEvaluator.evaluate(
            step: step(createdAt: now.addingTimeInterval(-idle)), now: now,
            lastStreamActivityAt: nil, processingStatus: nil)
        XCTAssertTrue(v.isStuck)
        XCTAssertEqual(v.wireRow?.kind, "hang")
    }

    /// The phase rides in the verdict and the DETAIL, never in the kind — the kind strings have
    /// a second home in the manager prompt, and the remedy set does not differ.
    ///
    /// RED: drop `phase` from the `.hang` payload, or emit the same diagnostic for both → the
    /// detail assertion fails and the manager loses the one cue that tells it a restart would
    /// discard a prefill.
    func testHang_beforeFirstToken_detailNamesThePhase() {
        let idle = AutovisorConstants.stuckPrefillHangSeconds + 1
        let v = AutovisorStuckEvaluator.evaluate(
            step: step(createdAt: now.addingTimeInterval(-idle)), now: now,
            lastStreamActivityAt: nil, processingStatus: .indeterminate)
        XCTAssertEqual(v.wireRow?.kind, "hang")
        XCTAssertTrue(v.wireRow?.detail.contains("first token") ?? false,
                      "got: \(v.wireRow?.detail ?? "nil")")
        guard case .hang(let phase, _) = v else { return XCTFail("expected .hang, got \(v)") }
        XCTAssertEqual(phase, .beforeFirstToken)
    }

    /// RED: `>=` for `>` in the pre-token comparison → the equality half fails.
    func testHang_prefillThresholdIsStrict() {
        func verdict(idle: TimeInterval) -> AutovisorStuckEvaluator.StuckVerdict {
            AutovisorStuckEvaluator.evaluate(
                step: step(createdAt: now.addingTimeInterval(-idle)), now: now,
                lastStreamActivityAt: nil, processingStatus: .indeterminate)
        }
        XCTAssertFalse(verdict(idle: AutovisorConstants.stuckPrefillHangSeconds).isStuck,
                       "exactly at the threshold is not a hang")
        XCTAssertTrue(verdict(idle: AutovisorConstants.stuckPrefillHangSeconds + 1).isStuck)
    }

    /// The pair the custom-threshold tests in this suite always ship as one: the default does
    /// NOT fire, the override DOES.
    ///
    /// RED: ignore the parameter and read the constant → the override half fails.
    func testHang_customPrefillHangSeconds_overridesDefault() {
        let s = step(createdAt: now.addingTimeInterval(-200))
        XCTAssertFalse(
            AutovisorStuckEvaluator.evaluate(
                step: s, now: now, lastStreamActivityAt: nil,
                processingStatus: .indeterminate).isStuck,
            "200s is under the 600s default")
        XCTAssertTrue(
            AutovisorStuckEvaluator.evaluate(
                step: s, now: now, lastStreamActivityAt: nil,
                processingStatus: .indeterminate, prefillHangSeconds: 60).isStuck,
            "and over a 60s override")
    }

    /// RED: drop the forward in the task-level overload → this fails while every step-level pin
    /// above stays green (CLAUDE.md #60).
    func testTaskLevel_prefillWindow_threadsThrough() {
        let s = step(createdAt: now.addingTimeInterval(-300))
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "g")
        task.runs = [Run(id: 0, steps: [s])]

        XCTAssertFalse(
            AutovisorStuckEvaluator.evaluate(
                task: task, now: now, lastStreamActivityAt: { _ in nil },
                processingStatus: { _ in .indeterminate }).isStuck,
            "300s is inside the pre-token budget")
        XCTAssertTrue(
            AutovisorStuckEvaluator.evaluate(
                task: task, now: now, lastStreamActivityAt: { _ in nil }).isStuck,
            "and outside the general one when no request is in flight")
    }

    /// Guard ordering is load-bearing: an in-flight tool wins regardless of the pre-token
    /// window, and the order must not rest on the coincidence that a tool running between LLM
    /// turns has no processing status anyway.
    ///
    /// RED: move the pre-token branch above the `hasToolInFlight` guard → this fails.
    func testNotStuck_toolInFlight_winsOverThePreTokenWindow() {
        let old = now.addingTimeInterval(-(AutovisorConstants.stuckPrefillHangSeconds + 100))
        let s = step(createdAt: old, toolCalls: [toolCall("bash", "{}", resultJSON: nil, at: old)])
        XCTAssertFalse(
            AutovisorStuckEvaluator.evaluate(
                step: s, now: now, lastStreamActivityAt: nil,
                processingStatus: .indeterminate).isStuck)
    }
}