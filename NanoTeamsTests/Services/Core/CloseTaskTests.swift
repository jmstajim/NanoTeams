import XCTest

@testable import NanoTeams

/// Tests for closeTask — step finalization, LLM cancellation, meeting cleanup.
@MainActor
final class CloseTaskTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Chat Mode: Step Finalization

    func testCloseTask_chatMode_runningStep_becomeDone() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        // Inject a running step (simulates chat advisory role mid-execution)
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .running),
            ], roleStatuses: ["assistant": .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        let task = sut.activeTask!
        XCTAssertNotNil(task.closedAt)
        XCTAssertEqual(task.runs.last?.steps.first?.status, .done)
        XCTAssertNotNil(task.runs.last?.steps.first?.completedAt)
        XCTAssertEqual(task.runs.last?.roleStatuses["assistant"], .done)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    func testCloseTask_chatMode_pausedStep_becomesDone() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .paused),
            ], roleStatuses: ["assistant": .working])]
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .done)
        XCTAssertEqual(sut.activeTask?.derivedStatusFromActiveRun(), .done)
    }

    func testCloseTask_chatMode_needsSupervisorInputStep_becomesDone() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .needsSupervisorInput),
            ], roleStatuses: ["assistant": .working])]
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .done)
        XCTAssertEqual(sut.activeTask?.derivedStatusFromActiveRun(), .done)
    }

    // MARK: - Non-Chat Mode: No-Op for Already-Done Steps

    func testCloseTask_nonChatMode_doneSteps_unchanged() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Task", supervisorTask: "Build")!

        let completedAt = MonotonicClock.shared.now()
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "pm", role: .productManager, title: "PM", status: .done, completedAt: completedAt),
                StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .done, completedAt: completedAt),
            ], roleStatuses: ["pm": .done, "swe": .done])]
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        let steps = sut.activeTask!.runs.last!.steps
        // completedAt should be preserved (not overwritten by closeTask)
        XCTAssertEqual(steps[0].completedAt, completedAt)
        XCTAssertEqual(steps[1].completedAt, completedAt)
    }

    // MARK: - Preserves Failed/Pending Steps

    func testCloseTask_failedStep_preservesFailedStatus() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .failed),
            ], roleStatuses: ["assistant": .failed])]
        }

        _ = await sut.closeTask(taskID: taskID)

        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .failed,
                        "Failed steps should preserve their status for diagnostics")
    }

    /// Pin: `closeTask` finalizes any role statuses still in
    /// `.needsAcceptance` to `.done`. Without this, after auto-accept on a
    /// delegation child the role node stays purple "Needs Review" in the
    /// graph forever, even though the task is closed (visible in delegation
    /// history layers as a stuck pill — pre-fix user symptom).
    func testCloseTask_finalizesNeedsAcceptanceRoleStatuses_toDone() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Task", supervisorTask: "Build")!

        await sut.mutateTask(taskID: taskID) { task in
            // Step is `.done` (work finished, awaiting acceptance) but role
            // status is `.needsAcceptance` — exact post-engine `.needsAcceptance`
            // state for a non-chat task before the human or auto-accept closes.
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "engineer",
                    role: .softwareEngineer,
                    title: "Build",
                    status: .done
                )],
                roleStatuses: ["engineer": .needsAcceptance]
            )]
        }

        _ = await sut.closeTask(taskID: taskID)

        XCTAssertEqual(
            sut.activeTask?.runs.last?.roleStatuses["engineer"], .done,
            "closeTask must flip .needsAcceptance role statuses to .done — implicit acceptance of completed work, otherwise the team graph keeps rendering 'Needs Review' on the closed task's nodes"
        )
        XCTAssertNotNil(
            sut.activeTask?.closedAt,
            "Sanity: closedAt is still set"
        )
    }

    func testCloseTask_pendingStep_preservesPendingStatus() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .pending),
            ])]
        }

        _ = await sut.closeTask(taskID: taskID)

        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .pending,
                        "Pending steps (never started) should not be marked done")
    }

    // MARK: - Multiple Steps Mixed Statuses

    func testCloseTask_multipleSteps_finalizesOnlyNonTerminal() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "role_a", role: .custom(id: "a"), title: "A", status: .running),
                StepExecution(id: "role_b", role: .custom(id: "b"), title: "B", status: .done),
                StepExecution(id: "role_c", role: .custom(id: "c"), title: "C", status: .paused),
                StepExecution(id: "role_d", role: .custom(id: "d"), title: "D", status: .failed),
            ], roleStatuses: ["role_a": .working, "role_b": .done, "role_c": .working, "role_d": .failed])]
        }

        _ = await sut.closeTask(taskID: taskID)

        let steps = sut.activeTask!.runs.last!.steps
        XCTAssertEqual(steps[0].status, .done, "Running → done")
        XCTAssertEqual(steps[1].status, .done, "Done stays done")
        XCTAssertEqual(steps[2].status, .done, "Paused → done")
        XCTAssertEqual(steps[3].status, .failed, "Failed stays failed")

        let roles = sut.activeTask!.runs.last!.roleStatuses
        XCTAssertEqual(roles["role_a"], .done)
        XCTAssertEqual(roles["role_b"], .done)
        XCTAssertEqual(roles["role_c"], .done)
        XCTAssertEqual(roles["role_d"], .failed, "Failed role status preserved")
    }

    // MARK: - Role-Status Finalization (finalizeRoleStatusesForClose)

    /// A `.working` role whose step is still `.pending` (never started): the step loop
    /// leaves the pending step alone, but the role status must be finalized to `.done` so
    /// the team graph (which reads `roleStatuses` raw) doesn't render a stale "Working" pill.
    func testCloseTask_workingRoleWithPendingStep_finalizesRoleStatus() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "r", role: .custom(id: "r"), title: "R", status: .pending),
            ], roleStatuses: ["r": .working])]
        }
        _ = await sut.closeTask(taskID: taskID)
        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .pending, "pending step untouched")
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["r"], .done, "working role finalized to .done")
    }

    func testCloseTask_revisionRequestedRole_finalizesToDone() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "r", role: .custom(id: "r"), title: "R", status: .done),
            ], roleStatuses: ["r": .revisionRequested])]
        }
        _ = await sut.closeTask(taskID: taskID)
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["r"], .done)
    }

    /// idle / ready roles with no steps (RunService seeds initialRoleStatuses for ALL
    /// roles up front) are the stale-pill source — they must finalize to `.done` on close.
    func testCloseTask_idleRoleThatNeverRan_finalizesToTerminal() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [], roleStatuses: ["a": .idle, "b": .ready])]
        }
        _ = await sut.closeTask(taskID: taskID)
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["a"], .done)
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["b"], .done)
    }

    /// `.failed` role status is preserved by the finalize pass (a failed role stays failed
    /// for the record), while a sibling idle role is finalized.
    func testCloseTask_failedRoleStatus_stillPreserved() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [], roleStatuses: ["a": .failed, "b": .idle])]
        }
        _ = await sut.closeTask(taskID: taskID)
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["a"], .failed, "failed role preserved")
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["b"], .done, "idle role finalized")
    }

    // MARK: - Engine & Meeting Cleanup

    func testCloseTask_stopsEngineAndClearsMeetingParticipants() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        // Simulate active engine + meeting participants
        sut.engineState[taskID] = .running
        sut.engineState.setMeetingParticipants(["role_a", "role_b"], for: taskID)

        _ = await sut.closeTask(taskID: taskID)

        XCTAssertNil(sut.taskEngineStates[taskID], "Engine state should be removed")
        XCTAssertNil(sut.engineState.activeMeetingParticipants[taskID],
                     "Meeting participants should be cleared")
    }

    func testStopEngine_clearsMeetingParticipants() {
        sut.engineState[0] = .running
        sut.engineState.setMeetingParticipants(["a", "b"], for: 0)

        sut.stopEngine(for: 0)

        XCTAssertNil(sut.engineState.activeMeetingParticipants[0])
    }

    func testRemoveAllEngines_clearsMeetingParticipants() {
        sut.engineState[0] = .running
        sut.engineState[1] = .paused
        sut.engineState.setMeetingParticipants(["a"], for: 0)
        sut.engineState.setMeetingParticipants(["b"], for: 1)

        sut.engineState.removeAllEngines()

        XCTAssertTrue(sut.engineState.activeMeetingParticipants.isEmpty)
        XCTAssertTrue(sut.engineState.taskEngineStates.isEmpty)
    }

    // MARK: - Cold Background Task (Post-Restart Eviction)

    /// Pin: sidebar → right-click → "Close Chat" on a chat task that hasn't been
    /// re-loaded since app restart. After `openWorkFolder`, only the active task
    /// is hydrated into `loadedTasks` — every other task lives on disk only.
    /// Pre-fix `closeTask` called `mutateTask` directly, whose background branch
    /// requires the task already be in memory and otherwise sets
    /// `lastErrorMessage = "Cannot persist task N: task not loaded."` (the user's
    /// reported error banner). `closeTask` must call `ensureTaskLoaded` first,
    /// matching the convention used by `startRun` / `pauseRun` / `restartRole`.
    func testCloseTask_evictedBackgroundChatTask_loadsAndCloses() async throws {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "Chat A", supervisorTask: "Help")!

        // Make A a chat-mode task with a mid-flight running step (matches the
        // user's screenshot: chat icon, no terminal state).
        await sut.mutateTask(taskID: idA) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .running),
            ], roleStatuses: ["assistant": .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        // Create B → B becomes active; A is preserved in `loadedTasks` via
        // `apply()`'s old-active rule. Then evict A to simulate the post-restart
        // state where only the active task was hydrated.
        let idB = await sut.createTask(title: "B", supervisorTask: "y")!
        XCTAssertEqual(sut.activeTaskID, idB)
        sut.evictLoadedTask(idA)

        // Sanity: bug condition reproduced — A is on disk but not in memory.
        XCTAssertNil(sut.loadedTask(idA),
                     "Setup: task A must be evicted to reproduce the user's post-restart state")

        // Clear any prior banner so we can attribute outcomes to closeTask alone.
        sut.lastErrorMessage = nil

        let success = await sut.closeTask(taskID: idA)

        XCTAssertTrue(success, "closeTask must load the cold task and persist the close")
        XCTAssertNil(sut.lastErrorMessage,
                     "No error banner should surface — pre-fix this was 'Cannot persist task N: task not loaded.'")

        // Verify the close actually persisted to disk (not just in-memory).
        let reloaded = try sut.repository.loadTask(at: tempDir, taskID: idA)
        XCTAssertNotNil(reloaded.closedAt, "closedAt must be persisted on disk")
        XCTAssertEqual(reloaded.runs.last?.steps.first?.status, .done,
                       "Running step must be finalized to .done on disk")
        XCTAssertEqual(reloaded.runs.last?.roleStatuses["assistant"], .done,
                       "Working role must be finalized to .done on disk")
        // Pin: `ensureTaskLoaded` → `syncEngineStateFromRun` briefly seeds
        // `engineState[idA] = .paused` for the chat-mode running step. The
        // production comment promises `stopEngine` cleans this up. Without
        // this assertion, a future reorder that drops `stopEngine` from the
        // success path leaks the seeded state — sidebar would render a stale
        // "Paused" pill on the closed task until next restart.
        XCTAssertNil(sut.engineState.taskEngineStates[idA],
                     "stopEngine must clear the engine state that ensureTaskLoaded briefly seeded for cold tasks")
    }

    /// Pin: sidebar → "Accept & Close" on a non-chat task evicted since app
    /// restart. Mirrors `testCloseTask_evictedBackgroundChatTask_loadsAndCloses`
    /// but exercises the non-chat code path: `derivedStatus` returns
    /// `.needsSupervisorAcceptance` (not `.running`), `mapDerivedStatusToEngineState`
    /// returns `.done` (not `.paused`), and `closeTask` finalizes
    /// `.needsAcceptance` role statuses to `.done` rather than running steps.
    /// Same fix line, different in-memory shape — pins that the load + close
    /// chain works for both sidebar context-menu labels.
    func testCloseTask_evictedBackgroundNonChatTask_loadsAndCloses() async throws {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "Task A", supervisorTask: "Build")!

        // Non-chat task in the post-engine `.needsAcceptance` state — what the
        // sidebar's "Accept & Close" button targets.
        await sut.mutateTask(taskID: idA) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "engineer",
                    role: .softwareEngineer,
                    title: "Build",
                    status: .done
                )],
                roleStatuses: ["engineer": .needsAcceptance]
            )]
        }

        let idB = await sut.createTask(title: "B", supervisorTask: "y")!
        XCTAssertEqual(sut.activeTaskID, idB)
        sut.evictLoadedTask(idA)
        XCTAssertNil(sut.loadedTask(idA),
                     "Setup: task A must be evicted to reproduce the post-restart state")

        sut.lastErrorMessage = nil

        let success = await sut.closeTask(taskID: idA)

        XCTAssertTrue(success)
        XCTAssertNil(sut.lastErrorMessage)

        let reloaded = try sut.repository.loadTask(at: tempDir, taskID: idA)
        XCTAssertNotNil(reloaded.closedAt)
        XCTAssertEqual(reloaded.runs.last?.roleStatuses["engineer"], .done,
                       ".needsAcceptance role must be implicitly accepted on close — same invariant as the active-task version")
        XCTAssertNil(sut.engineState.taskEngineStates[idA],
                     "stopEngine must clear the .done engine state seeded for the cold non-chat task")
    }

    /// Pin: cold-task close when the task has no runs at all. Exercises both
    /// `syncEngineStateFromRun`'s no-runs early-return (no engine state seeded)
    /// AND `closeTask`'s `guard var run = task.runs.last else { return }` skip
    /// past finalization. `closedAt` must still land. Companion to
    /// `testCloseTask_noRuns_stillSetsClosedAt` (which only covers the active
    /// task) — picks up the cold-no-runs intersection.
    func testCloseTask_evictedBackgroundTaskWithNoRuns_stillCloses() async throws {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        // Intentionally no `mutateTask` to inject runs — task A stays in its
        // freshly-created shape (`runs == []`).
        let idB = await sut.createTask(title: "B", supervisorTask: "y")!
        XCTAssertEqual(sut.activeTaskID, idB)
        sut.evictLoadedTask(idA)

        sut.lastErrorMessage = nil

        let success = await sut.closeTask(taskID: idA)

        XCTAssertTrue(success)
        XCTAssertNil(sut.lastErrorMessage)
        let reloaded = try sut.repository.loadTask(at: tempDir, taskID: idA)
        XCTAssertNotNil(reloaded.closedAt, "closedAt must persist even when the cold task has no runs")
    }

    /// Pin: double-click on sidebar "Close Chat" can spawn two overlapping
    /// `Task { _ = await store.closeTask(...) }` from [SidebarView.swift:351](NanoTeams/Views/App/SidebarView.swift#L351).
    /// Both calls must succeed without disk corruption — second call sees
    /// `closedAt` already set, idempotently re-sets it. Guards against a future
    /// `precondition(task.closedAt == nil)` or any non-idempotent mutation
    /// added to `closeTask`. Also implicitly verifies that the second call's
    /// `ensureTaskLoaded` short-circuits via the loaded-task fast path (no
    /// duplicate disk reads).
    func testCloseTask_concurrentCallsOnEvictedTask_bothSucceedIdempotently() async throws {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "Chat A", supervisorTask: "Help")!

        await sut.mutateTask(taskID: idA) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .running),
            ], roleStatuses: ["assistant": .working])]
        }

        _ = await sut.createTask(title: "B", supervisorTask: "y")!
        sut.evictLoadedTask(idA)
        sut.lastErrorMessage = nil

        async let r1 = sut.closeTask(taskID: idA)
        async let r2 = sut.closeTask(taskID: idA)
        let (s1, s2) = await (r1, r2)

        XCTAssertTrue(s1, "First concurrent close must succeed")
        XCTAssertTrue(s2, "Second concurrent close must succeed idempotently — not error or precondition-fail")
        XCTAssertNil(sut.lastErrorMessage)

        let reloaded = try sut.repository.loadTask(at: tempDir, taskID: idA)
        XCTAssertNotNil(reloaded.closedAt, "Disk has consistent closedAt after concurrent close")
        XCTAssertEqual(reloaded.runs.last?.steps.first?.status, .done,
                       "Disk has consistent finalized step after concurrent close")
    }

    /// Pin: when `task.json` is unreadable (POSIX 0o000 — analog to a permissions
    /// glitch from external tooling), the disk error must surface verbatim,
    /// NOT get overwritten by the generic "task not loaded" string. Companion
    /// to `testCloseTask_evictedTaskWithMissingDisk_preservesDiskErrorMessage`
    /// — different `repository.loadTask` failure shape (`NSFileReadNoPermissionError`
    /// vs `NSFileNoSuchFileError`), same short-circuit guard, same invariant.
    func testCloseTask_evictedTaskWithUnreadableDisk_preservesDiskErrorMessage() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        _ = await sut.createTask(title: "B", supervisorTask: "y")!
        sut.evictLoadedTask(idA)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let taskJSONPath = paths.taskJSON(taskID: idA).path
        // Make task.json unreadable — `Data(contentsOf:)` will throw permission denied.
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: taskJSONPath)
        // Restore perms for tearDown's removeItem cleanup, even on test failure.
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: taskJSONPath) }

        sut.lastErrorMessage = nil

        let success = await sut.closeTask(taskID: idA)

        XCTAssertFalse(success)
        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertFalse(
            sut.lastErrorMessage?.contains("task not loaded") ?? false,
            "Generic 'task not loaded' must NOT mask the actionable permission error — got: \(sut.lastErrorMessage ?? "nil")"
        )
    }

    /// Pin: when `ensureTaskLoaded` fails (e.g. `task.json` deleted between
    /// sidebar render and click), `closeTask` must short-circuit BEFORE
    /// `mutateTask` overwrites the actionable disk error in `lastErrorMessage`
    /// with the generic "Cannot persist task N: task not loaded." string —
    /// otherwise users see the same generic banner whether the file is missing,
    /// permission-denied, corrupted, or simply not in memory.
    func testCloseTask_evictedTaskWithMissingDisk_preservesDiskErrorMessage() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        _ = await sut.createTask(title: "B", supervisorTask: "y")!
        sut.evictLoadedTask(idA)

        // Delete A's task.json on disk to simulate corruption / external removal.
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try? FileManager.default.removeItem(at: paths.taskJSON(taskID: idA))

        sut.lastErrorMessage = nil

        let success = await sut.closeTask(taskID: idA)

        XCTAssertFalse(success, "Close must fail when disk read fails")
        XCTAssertNotNil(sut.lastErrorMessage, "Disk error must surface to the user")
        XCTAssertFalse(
            sut.lastErrorMessage?.contains("task not loaded") ?? false,
            "Generic 'task not loaded' must NOT mask the actionable disk error — got: \(sut.lastErrorMessage ?? "nil")"
        )
    }

    // MARK: - Empty Runs

    func testCloseTask_noRuns_stillSetsClosedAt() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        // Remove all runs
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = []
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        XCTAssertNotNil(sut.activeTask?.closedAt)
    }
}
