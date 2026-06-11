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
}
