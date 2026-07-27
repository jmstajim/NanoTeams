import XCTest

@testable import NanoTeams

/// Coverage for `resumeRun`'s failed-step recovery branch (the "send a message to
/// resume a failed task" feature). A run that stopped on a transient LLM/stall
/// failure leaves the step `.failed` + role `.failed`. Resuming must REVIVE it
/// (retry — conversation/session preserved), not wipe it, so the run continues.
///
/// Assertions are made synchronously right after `await resumeRun` returns: the
/// revived step is flipped to `.running` (via `markStepRunning`) before the
/// detached `startStepExecution` LLM task or the spawned engine run loop get a
/// chance to run, so the state is deterministic and LLM-independent (same pattern
/// as `ResumeAfterRestartAnswerTests`).
@MainActor
final class ResumeFailedStepTests: NTMSOrchestratorTestBase {

    /// Seeds the latest run with a single `.failed` step whose role is `.failed`,
    /// carrying a non-empty conversation + session so revival can be proven
    /// non-destructive. `step.id == roleID` because `effectiveRoleID == id`.
    private func createTaskWithFailedStep(
        roleID: String = "swe",
        conversation: [LLMMessage] = [LLMMessage(role: .assistant, content: "partial work so far")]
    ) async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: roleID,
                role: .softwareEngineer,
                title: "Engineer Step",
                status: .failed,
                completedAt: MonotonicClock.shared.now(),
                llmConversation: conversation
            )
            var run = Run(id: 0, steps: [step], roleStatuses: [roleID: .failed])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
            task.status = .paused
        }
        sut.engineState[taskID] = .failed
        return taskID
    }

    func testResumeRun_failedStep_revivedToRunning_withConversationAndSessionPreserved() async {
        let id = await createTaskWithFailedStep()

        await sut.resumeRun(taskID: id)

        let run = sut.loadedTask(id)?.runs.last
        let step = run?.steps.first
        XCTAssertEqual(step?.status, .running,
                       "Failed step must be flipped to .running so it retries")
        XCTAssertEqual(run?.roleStatuses["swe"], .working,
                       "Failed role must be flipped to .working so the run loop doesn't re-fail")
        XCTAssertNil(step?.completedAt, "completedAt must be cleared on revival")
        // Revival is a RETRY, not a reset — prior work must survive.
        XCTAssertEqual(step?.llmConversation.count, 1,
                       "Conversation must be preserved (retry, not reset)")
    }

    func testResumeRun_multipleFailedSteps_allRevived() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: id) { task in
            let a = StepExecution(id: "uxr", role: .uxResearcher, title: "UXR", status: .failed)
            let b = StepExecution(id: "pm", role: .productManager, title: "PM", status: .failed)
            var run = Run(id: 0, steps: [a, b], roleStatuses: ["uxr": .failed, "pm": .failed])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        await sut.resumeRun(taskID: id)

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.steps.first(where: { $0.id == "uxr" })?.status, .running)
        XCTAssertEqual(run?.steps.first(where: { $0.id == "pm" })?.status, .running)
        XCTAssertEqual(run?.roleStatuses["uxr"], .working)
        XCTAssertEqual(run?.roleStatuses["pm"], .working)
        XCTAssertFalse(run?.roleStatuses.values.contains(.failed) ?? true,
                       "No .failed role may remain — else the run loop re-fails immediately")
    }

    func testResumeRun_doneStepUntouched_whenSiblingFailed() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: id) { task in
            let done = StepExecution(id: "pm", role: .productManager, title: "PM",
                                     status: .done, completedAt: MonotonicClock.shared.now())
            let failed = StepExecution(id: "tl", role: .techLead, title: "TL", status: .failed)
            var run = Run(id: 0, steps: [done, failed],
                          roleStatuses: ["pm": .done, "tl": .failed])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        await sut.resumeRun(taskID: id)

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.steps.first(where: { $0.id == "pm" })?.status, .done,
                       "A done step must NOT be revived by the failed-recovery branch")
        XCTAssertEqual(run?.roleStatuses["pm"], .done)
        XCTAssertEqual(run?.steps.first(where: { $0.id == "tl" })?.status, .running,
                       "Only the failed step is revived")
        XCTAssertEqual(run?.roleStatuses["tl"], .working)
    }

    // MARK: - Corner cases

    /// A clean failed sibling must be revived even when another step is mid-`delegate_to_team`.
    /// Before the fix, the `stepHasActiveDelegation` short-circuit returned before failed-step
    /// revival, leaving the sibling stuck `.failed` and the engine re-failing immediately.
    func testResumeRun_failedSibling_withActiveDelegationStep_siblingRevived() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: id) { task in
            // Step A: mid-delegation (.running, owns a child) — must be left untouched.
            let delegating = StepExecution(
                id: "pm", role: .productManager, title: "PM", status: .running,
                activeDelegationChildID: 999
            )
            // Step B: failed sibling — must be revived.
            let failed = StepExecution(
                id: "swe", role: .softwareEngineer, title: "SWE", status: .failed,
                completedAt: MonotonicClock.shared.now(),
                llmConversation: [LLMMessage(role: .assistant, content: "partial")]
            )
            var run = Run(id: 0, steps: [delegating, failed],
                          roleStatuses: ["pm": .working, "swe": .failed])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
            task.status = .paused
        }
        sut.engineState[id] = .failed

        await sut.resumeRun(taskID: id)

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.steps.first(where: { $0.id == "swe" })?.status, .running,
                       "Clean failed sibling must be revived despite a mid-delegation step")
        XCTAssertEqual(run?.roleStatuses["swe"], .working)
        // The delegation step's awaiter must keep sleeping — untouched.
        XCTAssertEqual(run?.steps.first(where: { $0.id == "pm" })?.status, .running)
        XCTAssertEqual(run?.steps.first(where: { $0.id == "pm" })?.activeDelegationChildID, 999)
    }

    /// A failed step that STILL owns an unresolved `delegate_to_team` tool_call
    /// (`activeDelegationChildID != nil`) must NOT be blindly revived — re-running it would
    /// poison the model chain. It needs `cancel_delegation`, not a retry.
    func testResumeRun_failedStepOwningActiveDelegation_notRevived() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: "agent", role: .softwareEngineer, title: "Agent", status: .failed,
                llmConversation: [LLMMessage(role: .assistant, content: "delegating…")],
                activeDelegationChildID: 999
            )
            var run = Run(id: 0, steps: [step], roleStatuses: ["agent": .failed])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
            task.status = .paused
        }
        sut.engineState[id] = .failed

        await sut.resumeRun(taskID: id)

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.steps.first?.status, .failed,
                       "A failed step still owning an active delegation must not be auto-revived")
        XCTAssertEqual(run?.roleStatuses["agent"], .failed)
    }

    /// Defensive role guard: a failed step whose role is in a settled state (.done) is an
    /// invariant violation — revival must SKIP it rather than resurrect finished work.
    func testResumeRun_failedStepWithSettledRole_notRevived() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(id: "pm", role: .productManager, title: "PM", status: .failed)
            var run = Run(id: 0, steps: [step], roleStatuses: ["pm": .done])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        await sut.resumeRun(taskID: id)

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.roleStatuses["pm"], .done,
                       "A settled (.done) role must not be flipped back to .working")
        XCTAssertEqual(run?.steps.first?.status, .failed,
                       "Step left untouched when its role is settled")
    }

    /// resumeRun only restarts the LATEST run — an older run's failed step is left untouched.
    func testResumeRun_multipleRuns_onlyLatestRunRevived() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: id) { task in
            let old = StepExecution(id: "old", role: .softwareEngineer, title: "Old", status: .failed)
            var run0 = Run(id: 0, steps: [old], roleStatuses: ["old": .failed])
            run0.updatedAt = MonotonicClock.shared.now()
            let cur = StepExecution(id: "cur", role: .productManager, title: "Cur", status: .failed)
            var run1 = Run(id: 1, steps: [cur], roleStatuses: ["cur": .failed])
            run1.updatedAt = MonotonicClock.shared.now()
            task.runs = [run0, run1]
            task.status = .paused
        }

        await sut.resumeRun(taskID: id)

        let finalTask = sut.loadedTask(id)
        XCTAssertEqual(finalTask?.runs.first?.steps.first?.status, .failed,
                       "Older run's failed step is left untouched")
        XCTAssertEqual(finalTask?.runs.first?.roleStatuses["old"], .failed)
        XCTAssertEqual(finalTask?.runs.last?.steps.first?.status, .running,
                       "Latest run's failed step is revived")
        XCTAssertEqual(finalTask?.runs.last?.roleStatuses["cur"], .working)
    }

    /// No run yet → resumeRun guards on `runs.last` and no-ops silently (not an error).
    func testResumeRun_emptyRuns_noOpsWithoutError() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: id) { task in
            task.runs = []
            task.status = .paused
        }

        await sut.resumeRun(taskID: id)

        XCTAssertEqual(sut.loadedTask(id)?.runs.count, 0,
                       "resumeRun no-ops when there is no run to inspect")
        XCTAssertNil(sut.lastErrorMessage, "A task with no run yet is not an error")
    }

    /// A CLOSED task must never be revived by `resumeRun` — defends against the race where a
    /// close lands after a queue-flush dispatched its `Task { resumeRun }` (the `closedAt`
    /// guard in `wakeRunForQueuedMessages` only covers the pre-dispatch check).
    func testResumeRun_closedTask_isNoOp() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .failed)
            var run = Run(id: 0, steps: [step], roleStatuses: ["swe": .failed])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
            task.closedAt = MonotonicClock.shared.now()   // closed
        }
        sut.engineState[id] = .failed

        await sut.resumeRun(taskID: id)

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.steps.first?.status, .failed,
                       "A closed task's failed step must NOT be revived")
        XCTAssertEqual(run?.roleStatuses["swe"], .failed,
                       "A closed task's role must stay failed (no resurrection)")
    }

    /// Revival is a RETRY, not a reset — a failed revision step keeps its `revisionComment`
    /// and session so the continuation context survives.
    func testResumeRun_failedRevisionStep_revivedWithRevisionCommentPreserved() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: "swe", role: .softwareEngineer, title: "SWE", status: .failed,
                completedAt: MonotonicClock.shared.now(),
                llmConversation: [LLMMessage(role: .assistant, content: "attempt")],
                revisionComment: "address the feedback"
            )
            var run = Run(id: 0, steps: [step], roleStatuses: ["swe": .failed])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        await sut.resumeRun(taskID: id)

        let step = sut.loadedTask(id)?.runs.last?.steps.first
        XCTAssertEqual(step?.status, .running, "Failed revision step is revived")
        XCTAssertEqual(step?.revisionComment, "address the feedback",
                       "revisionComment is preserved — revival is a retry, not a reset()")
    }
}
