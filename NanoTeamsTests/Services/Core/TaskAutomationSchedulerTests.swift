import XCTest

@testable import NanoTeams

/// Behavior of the recurring-task scheduler + run-timeout watchdog
/// (`NTMSOrchestrator+Scheduling`). Deterministic via the injectable `now:`
/// parameters — no wall-clock waits, no real tick loop.
@MainActor
final class TaskAutomationSchedulerTests: NTMSOrchestratorTestBase {

    // MARK: - Minute-boundary alignment

    func testSecondsUntilNextMinuteBoundary() {
        // 1_700_000_040 is on a minute boundary → a full minute remains.
        XCTAssertEqual(NTMSOrchestrator.secondsUntilNextMinuteBoundary(from: Date(timeIntervalSince1970: 1_700_000_040)), 60, accuracy: 0.0001)
        // 37s past a boundary → 23s remain until the next.
        XCTAssertEqual(NTMSOrchestrator.secondsUntilNextMinuteBoundary(from: Date(timeIntervalSince1970: 1_700_000_077)), 23, accuracy: 0.0001)
    }

    // MARK: - Public API

    func testSetTaskRecurrence_persistsAndReschedulesToFuture() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!

        await sut.setTaskRecurrence(taskID: taskID, recurrence: TaskRecurrence(rule: .interval(seconds: 3_600)))

        let rec = sut.loadedTask(taskID)?.recurrence
        XCTAssertNotNil(rec)
        XCTAssertTrue(rec?.isEnabled == true)
        XCTAssertNotNil(rec?.nextFireAt)
        XCTAssertGreaterThan(rec!.nextFireAt!, Date(), "setTaskRecurrence reschedules into the future")
        XCTAssertNotNil(
            sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.nextRecurrenceFireAt,
            "summary index must carry the next fire so the scheduler/sidebar see it"
        )
    }

    func testSetTaskRecurrence_nilClears() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.setTaskRecurrence(taskID: taskID, recurrence: TaskRecurrence(rule: .interval(seconds: 3_600)))

        await sut.setTaskRecurrence(taskID: taskID, recurrence: nil)

        XCTAssertNil(sut.loadedTask(taskID)?.recurrence)
        XCTAssertNil(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.nextRecurrenceFireAt)
    }

    func testSetTaskRunTimeout_persistsAndClears() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!

        await sut.setTaskRunTimeout(taskID: taskID, seconds: 600)
        XCTAssertEqual(sut.loadedTask(taskID)?.runTimeoutSeconds, 600)

        await sut.setTaskRunTimeout(taskID: taskID, seconds: nil)
        XCTAssertNil(sut.loadedTask(taskID)?.runTimeoutSeconds)
    }

    // MARK: - Skip-missed reconcile

    func testReconcileMissed_advancesPastSlotWithoutFiring() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.reconcileMissedRecurrences(now: now)

        let rec = sut.loadedTask(taskID)?.recurrence
        XCTAssertNotNil(rec?.nextFireAt)
        XCTAssertGreaterThan(rec!.nextFireAt!, now, "missed slot advanced to the future")
        XCTAssertNil(rec?.lastFiredAt, "reconcile skips — it must NOT fire")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, runsBefore, "reconcile must not append a run")
    }

    // MARK: - Fire / overlap

    func testEvaluateDue_firesWhenDueAndNotActive() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNotNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt, "fired → lastFiredAt set")
        XCTAssertGreaterThan(sut.loadedTask(taskID)!.recurrence!.nextFireAt!, now, "rescheduled forward after firing")
        XCTAssertGreaterThanOrEqual(
            sut.loadedTask(taskID)?.runs.count ?? 0, runsBefore + 1,
            "firing re-runs the same task — a fresh Run is appended"
        )

        // Stop the background engine that startRun spun up.
        await sut.pauseRun(taskID: taskID)
    }

    func testEvaluateDue_overlapSkip_whenEngineActive() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }
        // Previous occurrence still running.
        sut.engineState[taskID] = .running
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt, "overlap → skip, no fire")
        XCTAssertGreaterThan(sut.loadedTask(taskID)!.recurrence!.nextFireAt!, now, "schedule still advances on overlap-skip")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, runsBefore, "overlap-skip must not append a run")
    }

    // MARK: - Run timeout watchdog

    func testRunTimeout_pausesOverBudgetRunOnce() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 60
            task.runs = [Run(
                id: 0,
                createdAt: now.addingTimeInterval(-120), // 120s old, budget 60s → over
                steps: [StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .running)],
                roleStatuses: ["assistant": .working]
            )]
        }
        sut.engineState[taskID] = .running
        sut.lastInfoMessage = nil

        await sut.evaluateRunTimeouts(now: now)

        let stamp = sut.loadedTask(taskID)?.runs.last?.timedOutAt
        XCTAssertNotNil(stamp, "over-budget run is marked timed out")
        XCTAssertNotNil(sut.lastInfoMessage, "Supervisor is notified via the info banner")

        // Second pass must NOT re-fire (guarded by timedOutAt).
        await sut.evaluateRunTimeouts(now: now.addingTimeInterval(30))
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.timedOutAt, stamp, "fires once per run — no re-pause")
    }

    func testRunTimeout_underBudget_noPause() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 3_600
            task.runs = [Run(
                id: 0,
                createdAt: now, // fresh, well under budget
                steps: [StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .running)],
                roleStatuses: ["assistant": .working]
            )]
        }
        sut.engineState[taskID] = .running

        await sut.evaluateRunTimeouts(now: now)

        XCTAssertNil(sut.loadedTask(taskID)?.runs.last?.timedOutAt, "under-budget run must not be paused")
    }

    func testRunTimeout_noTimeoutSet_noPause() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            // No runTimeoutSeconds set.
            task.runs = [Run(
                id: 0,
                createdAt: now.addingTimeInterval(-10_000),
                steps: [StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .running)],
                roleStatuses: ["assistant": .working]
            )]
        }
        sut.engineState[taskID] = .running

        await sut.evaluateRunTimeouts(now: now)

        XCTAssertNil(sut.loadedTask(taskID)?.runs.last?.timedOutAt, "no timeout configured → never fires")
    }

    // MARK: - Recurrence corner cases

    func testReconcileMissed_leavesFutureSlotUntouched() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        let future = now.addingTimeInterval(3_600)
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: future)
        }

        await sut.reconcileMissedRecurrences(now: now)

        XCTAssertEqual(sut.loadedTask(taskID)?.recurrence?.nextFireAt, future, "a future slot must be left exactly as-is")
        XCTAssertTrue(sut.loadedTask(taskID)?.recurrence?.isEnabled == true)
    }

    func testReconcileMissed_pastOnce_selfDisables() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .once(date: now.addingTimeInterval(-100)), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }

        await sut.reconcileMissedRecurrences(now: now)

        let rec = sut.loadedTask(taskID)?.recurrence
        XCTAssertEqual(rec?.isEnabled, false, "a missed one-shot disables itself rather than firing late")
        XCTAssertNil(rec?.nextFireAt)
        XCTAssertNil(rec?.lastFiredAt, "reconcile never fires")
    }

    func testEvaluateDue_ignoresDisabledRecurrence() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        let pastFire = now.addingTimeInterval(-100)
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 60), isEnabled: false, nextFireAt: pastFire)
        }
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt, "disabled recurrence must never fire")
        XCTAssertEqual(sut.loadedTask(taskID)?.recurrence?.nextFireAt, pastFire, "disabled recurrence is untouched")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, runsBefore)
    }

    func testEvaluateDue_dueOnce_firesThenDisables() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .once(date: now.addingTimeInterval(-1)), isEnabled: true, nextFireAt: now.addingTimeInterval(-1))
        }
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        let rec = sut.loadedTask(taskID)?.recurrence
        XCTAssertNotNil(rec?.lastFiredAt, "one-shot fired")
        XCTAssertEqual(rec?.isEnabled, false, "one-shot disables after firing")
        XCTAssertNil(rec?.nextFireAt)
        XCTAssertNil(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.nextRecurrenceFireAt,
                     "disabled one-shot drops out of the index → no sidebar badge / scheduler scan")
        XCTAssertGreaterThanOrEqual(sut.loadedTask(taskID)?.runs.count ?? 0, runsBefore + 1)

        await sut.pauseRun(taskID: taskID)
    }

    func testSetTaskRecurrence_pastOnce_immediatelyDisabled() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!

        await sut.setTaskRecurrence(taskID: taskID, recurrence: TaskRecurrence(rule: .once(date: Date().addingTimeInterval(-100))))

        let rec = sut.loadedTask(taskID)?.recurrence
        XCTAssertEqual(rec?.isEnabled, false, "scheduling a one-shot in the past is effectively off")
        XCTAssertNil(rec?.nextFireAt)
        XCTAssertNil(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.nextRecurrenceFireAt)
    }

    // MARK: - Run timeout corner cases

    func testRunTimeout_exactBoundary_notFired() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 60
            task.runs = [Run(
                id: 0,
                createdAt: now.addingTimeInterval(-60), // elapsed == budget exactly
                steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .running)],
                roleStatuses: ["a": .working]
            )]
        }
        sut.engineState[taskID] = .running

        await sut.evaluateRunTimeouts(now: now)

        XCTAssertNil(sut.loadedTask(taskID)?.runs.last?.timedOutAt, "elapsed == budget must NOT trip (strict >)")
    }

    func testRunTimeout_firesWhileWaitingForSupervisor() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 60
            task.runs = [Run(
                id: 0,
                createdAt: now.addingTimeInterval(-120),
                steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .needsSupervisorInput)],
                roleStatuses: ["a": .working]
            )]
        }
        // "All time from start" — supervisor-wait counts, so needsSupervisorInput is enforced.
        sut.engineState[taskID] = .needsSupervisorInput

        await sut.evaluateRunTimeouts(now: now)

        XCTAssertNotNil(sut.loadedTask(taskID)?.runs.last?.timedOutAt, "timeout counts supervisor-wait time too")
    }

    func testRunTimeout_pausedEngine_notFired() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 60
            task.runs = [Run(
                id: 0,
                createdAt: now.addingTimeInterval(-10_000),
                steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .paused)],
                roleStatuses: ["a": .working]
            )]
        }
        // Manually paused — the watchdog only enforces on running / needsSupervisorInput.
        sut.engineState[taskID] = .paused

        await sut.evaluateRunTimeouts(now: now)

        XCTAssertNil(sut.loadedTask(taskID)?.runs.last?.timedOutAt, "a manually-paused run must not be timed out")
    }

    func testRunTimeout_noRuns_doesNotCrash() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 60
            task.runs = []
        }
        sut.engineState[taskID] = .running
        sut.lastInfoMessage = nil

        await sut.evaluateRunTimeouts(now: Date())

        XCTAssertNil(sut.lastInfoMessage, "no run → nothing to time out, no banner, no crash")
    }

    // MARK: - Eviction (memory bound)

    func testReconcile_evictsBackgroundTask_butKeepsChangePersisted() async throws {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        let now = Date()
        // Give A a missed recurrence while it is still the active task.
        await sut.mutateTask(taskID: idA) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }
        // Switch active to B → A becomes a loaded background task.
        let idB = await sut.createTask(title: "B", supervisorTask: "y")!
        XCTAssertEqual(sut.activeTaskID, idB)
        XCTAssertNotNil(sut.loadedTask(idA), "A is still loaded as a background task")

        await sut.reconcileMissedRecurrences(now: now)

        XCTAssertNil(sut.loadedTask(idA), "reconcile evicts the touched background task to bound memory")
        // …but the rescheduled recurrence is persisted to disk.
        let reloaded = try sut.repository.loadTask(at: tempDir, taskID: idA)
        XCTAssertGreaterThan(reloaded.recurrence!.nextFireAt!, now, "the skip advanced the slot on disk")
        XCTAssertNil(reloaded.recurrence?.lastFiredAt, "skip did not fire")
    }

    func testReconcile_doesNotEvictActiveTask() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: idA) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }

        await sut.reconcileMissedRecurrences(now: now)

        XCTAssertNotNil(sut.loadedTask(idA), "the active task is never evicted")
        XCTAssertGreaterThan(sut.loadedTask(idA)!.recurrence!.nextFireAt!, now)
    }

    // MARK: - Parked-on-supervisor-input corner

    /// A chat-mode recurring task that ended its occurrence by calling
    /// `ask_supervisor` parks at `.needsSupervisorInput`. The schedule must
    /// supersede that stale question and start a fresh run — otherwise the
    /// recurrence is stuck forever (the user's reported symptom).
    func testEvaluateDue_chatTaskParkedOnSupervisorInput_firesFreshRun() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "assistant", role: .custom(id: "assistant"), title: "Chat",
                    status: .needsSupervisorInput, needsSupervisorInput: true, supervisorQuestion: "Anything else?"
                )],
                roleStatuses: ["assistant": .working]
            )]
        }
        sut.engineState[taskID] = .needsSupervisorInput
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNotNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt,
                        "a parked chat task must re-fire on schedule, not stay stuck on the old question")
        XCTAssertGreaterThanOrEqual(sut.loadedTask(taskID)?.runs.count ?? 0, runsBefore + 1,
                                    "firing appends a fresh run")

        await sut.pauseRun(taskID: taskID)
    }

    /// A task whose run finished and is parked on `.needsAcceptance` (producing
    /// roles done, awaiting the Supervisor's Accept) must re-fire on schedule —
    /// the work is done, the schedule supersedes the pending acceptance.
    func testEvaluateDue_taskParkedOnAcceptance_firesFreshRun() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Build", status: .done)],
                roleStatuses: ["eng": .needsAcceptance]
            )]
        }
        sut.engineState[taskID] = .needsAcceptance
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNotNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt,
                        "a task parked awaiting acceptance must re-fire on schedule")
        XCTAssertGreaterThanOrEqual(sut.loadedTask(taskID)?.runs.count ?? 0, runsBefore + 1)

        await sut.pauseRun(taskID: taskID)
    }

    /// "Restart on the timer unless it's still running": a task parked on
    /// `.needsSupervisorInput` — even a non-chat one — is superseded by the
    /// schedule and re-fires. The prior run/question stays in history.
    func testEvaluateDue_parkedOnSupervisorInput_firesFreshRun() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(false)
            task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "eng", role: .softwareEngineer, title: "Build",
                    status: .needsSupervisorInput, needsSupervisorInput: true, supervisorQuestion: "Which approach?"
                )],
                roleStatuses: ["eng": .working]
            )]
        }
        sut.engineState[taskID] = .needsSupervisorInput
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNotNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt, "parked on a question → re-fires on schedule")
        XCTAssertGreaterThanOrEqual(sut.loadedTask(taskID)?.runs.count ?? 0, runsBefore + 1)

        await sut.pauseRun(taskID: taskID)
    }

    /// Only `.running` blocks — a paused previous run is also superseded and re-fires.
    func testEvaluateDue_pausedRun_firesFreshRun() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .paused)],
                roleStatuses: ["a": .working]
            )]
        }
        sut.engineState[taskID] = .paused
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNotNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt, "a paused run is superseded by the schedule")
        XCTAssertGreaterThanOrEqual(sut.loadedTask(taskID)?.runs.count ?? 0, runsBefore + 1)

        await sut.pauseRun(taskID: taskID)
    }

    func testEvaluateDue_doneEngineState_firesFreshRun() async {
        await assertFiresForEngineState(.done)
    }

    func testEvaluateDue_failedEngineState_firesFreshRun() async {
        await assertFiresForEngineState(.failed)
    }

    /// Shared driver: a recurring task in a terminal/parked engine `state` re-fires.
    private func assertFiresForEngineState(_ state: TeamEngineState) async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
            task.runs = [Run(id: 0, steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .done)], roleStatuses: ["a": .done])]
        }
        sut.engineState[taskID] = state
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNotNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt, "state \(state) is not running → re-fires")
        XCTAssertGreaterThanOrEqual(sut.loadedTask(taskID)?.runs.count ?? 0, runsBefore + 1)
        await sut.pauseRun(taskID: taskID)
    }

    // MARK: - Restart cleanup (adversarial-review fixes)

    /// Restarting a recurring task must DROP the prior occurrence's queued
    /// Supervisor messages — otherwise they re-inject into the fresh run as
    /// phantom answers.
    func testFire_clearsStaleQueuedSupervisorMessages() async {
        await sut.openWorkFolder(tempDir)
        let formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState // weak on the orchestrator; retained by this local
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .needsSupervisorInput, needsSupervisorInput: true, supervisorQuestion: "?")],
                roleStatuses: ["a": .working]
            )]
        }
        sut.engineState[taskID] = .needsSupervisorInput
        let msg = QuickCaptureFormState.QueuedChatMessage(text: "stale feedback", attachments: [], clippedTexts: [])!
        formState.appendQueuedMessage(msg, for: taskID)
        XCTAssertTrue(formState.hasQueuedMessage(for: taskID), "sanity: message queued")

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertFalse(formState.hasQueuedMessage(for: taskID),
                       "restart must clear stale queued Supervisor messages so they don't re-inject")
        await sut.pauseRun(taskID: taskID)
    }

    /// Restarting a recurring task that had an in-flight delegation must tear
    /// down the child engine too (recursive `stopEngineForTask`), not orphan it.
    func testFire_recursivelyTearsDownDelegationChildEngine() async {
        await sut.openWorkFolder(tempDir)
        let parentID = await sut.createTask(title: "Parent", supervisorTask: "x")!
        guard let childID = await sut.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "pm",
            title: "Child", supervisorTask: "sub", preferredTeamID: nil, depth: 1
        ) else { return XCTFail("child creation failed") }
        XCTAssertEqual(sut.childTaskIDs(of: parentID), [childID], "sanity: child registered under parent")

        let now = Date()
        await sut.mutateTask(taskID: parentID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }
        // Parent parked, child engine still alive (in-flight delegation).
        sut.engineState[parentID] = .paused
        sut.engineState[childID] = .paused

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNil(sut.taskEngineStates[childID],
                     "recursive teardown must stop the delegation child engine on restart — not orphan it")
        XCTAssertNotNil(sut.loadedTask(parentID)?.recurrence?.lastFiredAt, "parent re-fired")
        await sut.pauseRun(taskID: parentID)
    }

    // MARK: - Multi-task / no-tight-loop

    func testEvaluateDue_firesAllDueTasksInOnePass() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        let idB = await sut.createTask(title: "B", supervisorTask: "y")!
        let now = Date()
        for id in [idA, idB] {
            await sut.mutateTask(taskID: id) {
                $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
            }
        }

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNotNil(sut.loadedTask(idA)?.recurrence?.lastFiredAt, "A fired")
        XCTAssertNotNil(sut.loadedTask(idB)?.recurrence?.lastFiredAt, "B fired")
        await sut.pauseRun(taskID: idA)
        await sut.pauseRun(taskID: idB)
    }

    func testEvaluateDue_secondPassSameNow_doesNotReFire() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }

        await sut.evaluateDueRecurrences(now: now)
        let runsAfterFirst = sut.loadedTask(taskID)?.runs.count ?? 0
        let firstFiredAt = sut.loadedTask(taskID)?.recurrence?.lastFiredAt

        // Same `now` again — nextFireAt has advanced past it, so no re-fire (no tight loop).
        await sut.evaluateDueRecurrences(now: now)

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, runsAfterFirst, "must not re-fire on the same tick")
        XCTAssertEqual(sut.loadedTask(taskID)?.recurrence?.lastFiredAt, firstFiredAt, "lastFiredAt unchanged on the no-op second pass")
        await sut.pauseRun(taskID: taskID)
    }

    // MARK: - Overlap-skip: team generation in flight (review gap #1)

    /// The overlap guard blocks on `.running` OR a team still being generated.
    /// A Generated-Team recurring task whose generation is still in flight at the
    /// next slot must skip — firing would tear down the in-flight generation and
    /// double-start. Pins the `isGeneratingTeam` half of the guard.
    func testEvaluateDue_overlapSkip_whenTeamGenerating() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }
        // Previous occurrence's team is still generating (engine not yet running).
        XCTAssertTrue(sut.beginTeamGeneration(taskID: taskID), "sanity: marked generating")
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt, "generation in flight → skip, no fire")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, runsBefore, "generating overlap must not append a run")
        XCTAssertGreaterThan(sut.loadedTask(taskID)!.recurrence!.nextFireAt!, now, "schedule still advances on overlap-skip")
        sut.endTeamGeneration(taskID: taskID)
    }

    // MARK: - Fire-vs-disable race re-read (review gap #2)

    /// `fireRecurrence` re-reads the loaded task's recurrence and re-checks
    /// `isDue` AFTER the index scan, so a recurrence disabled in the window
    /// between scan and fire is not fired. Force the in-memory index to still
    /// claim the task is due while the loaded recurrence is already disabled.
    func testEvaluateDue_disabledBetweenScanAndFire_reReadGuardBlocksFire() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        let past = now.addingTimeInterval(-100)
        // Loaded recurrence is DISABLED (isDue == false)…
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 60), isEnabled: false, nextFireAt: past)
        }
        // …but force the index summary to still report it as due (simulating the
        // disable landing after the scan collected this ID).
        if let i = sut.snapshot?.tasksIndex.tasks.firstIndex(where: { $0.id == taskID }) {
            sut.snapshot?.tasksIndex.tasks[i].nextRecurrenceFireAt = past
        }
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNil(sut.loadedTask(taskID)?.recurrence?.lastFiredAt,
                     "the re-read + isDue guard must block a recurrence disabled since the scan")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, runsBefore, "no run appended for the disabled-since-scan recurrence")
    }

    // MARK: - Scheduler lifecycle / wiring (review gap #3)

    func testOpenWorkFolder_startsScheduler_stopCancels() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.automationPollTask, "openWorkFolder starts the automation poll loop")
        sut.stopAutomationScheduler()
        XCTAssertNil(sut.automationPollTask, "stop cancels and clears the poll task")
    }

    func testStartScheduler_idempotent_cancelsPriorLoop() async {
        await sut.openWorkFolder(tempDir)
        let first = sut.automationPollTask
        XCTAssertNotNil(first, "open started a loop")

        await sut.startAutomationScheduler()

        XCTAssertEqual(first?.isCancelled, true, "re-starting cancels the prior loop — no double poll")
        XCTAssertNotNil(sut.automationPollTask, "a fresh loop is running after re-start")
        sut.stopAutomationScheduler()
        XCTAssertNil(sut.automationPollTask)
    }

    // MARK: - Timeout actually pauses (review gap #4)

    /// The watchdog must not merely stamp `timedOutAt` — it must PAUSE the run.
    /// Asserting the step transitions to `.paused` pins the user-visible behavior
    /// the feature is named for (a refactor that dropped the `pauseRun` call but
    /// kept the stamp would otherwise ship green).
    func testRunTimeout_actuallyPausesTheRunningStep() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 60
            task.runs = [Run(
                id: 0,
                createdAt: now.addingTimeInterval(-120),
                steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .running)],
                roleStatuses: ["a": .working]
            )]
        }
        sut.engineState[taskID] = .running

        await sut.evaluateRunTimeouts(now: now)

        XCTAssertNotNil(sut.loadedTask(taskID)?.runs.last?.timedOutAt, "run marked timed out")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.first?.status, .paused,
                       "timeout must actually PAUSE the running step, not just stamp the marker")
    }

    // MARK: - Multiple simultaneous timeouts coalesce (review H4)

    /// Two runs exceeding budget in the same tick must produce ONE combined
    /// banner — `lastInfoMessage` is a single slot, so a per-task assignment
    /// would clobber all but the last and silently drop the others.
    func testRunTimeout_multipleSameTick_combinedBanner() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "Alpha", supervisorTask: "x")!
        let idB = await sut.createTask(title: "Beta", supervisorTask: "y")!
        let now = Date()
        for id in [idA, idB] {
            await sut.mutateTask(taskID: id) { task in
                task.runTimeoutSeconds = 60
                task.runs = [Run(
                    id: 0,
                    createdAt: now.addingTimeInterval(-120),
                    steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .running)],
                    roleStatuses: ["a": .working]
                )]
            }
            sut.engineState[id] = .running
        }
        sut.lastInfoMessage = nil

        await sut.evaluateRunTimeouts(now: now)

        XCTAssertNotNil(sut.loadedTask(idA)?.runs.last?.timedOutAt, "A timed out")
        XCTAssertNotNil(sut.loadedTask(idB)?.runs.last?.timedOutAt, "B timed out")
        XCTAssertEqual(sut.lastInfoMessage, "2 tasks paused — they exceeded their run timeouts.",
                       "simultaneous timeouts coalesce into one banner instead of clobbering lastInfoMessage")
    }

    // MARK: - Child/delegated tasks never recur

    func testEvaluateDue_childDelegatedTask_neverFires() async {
        await sut.openWorkFolder(tempDir)
        let parentID = await sut.createTask(title: "Parent", supervisorTask: "x")!
        guard let childID = await sut.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "pm",
            title: "Child", supervisorTask: "sub", preferredTeamID: nil, depth: 1
        ) else { return XCTFail("child creation failed") }
        let now = Date()
        // Even with a due recurrence, a child task must not fire — the scan
        // filters `parentTaskID == nil`.
        await sut.mutateTask(taskID: childID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }
        let runsBefore = sut.loadedTask(childID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNil(sut.loadedTask(childID)?.recurrence?.lastFiredAt,
                     "a delegated child task must never recur (parentTaskID != nil is filtered)")
        XCTAssertEqual(sut.loadedTask(childID)?.runs.count, runsBefore, "no fresh run for a child task")
    }

    // MARK: - Eviction guards (review gap #7)

    /// A generating task that gets touched by reconcile must NOT be evicted —
    /// dropping it from `loadedTasks` mid-generation would lose the in-flight team.
    func testReconcile_doesNotEvictGeneratingBackgroundTask() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: idA) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: now.addingTimeInterval(-100))
        }
        _ = await sut.createTask(title: "B", supervisorTask: "y")! // A → background
        XCTAssertTrue(sut.beginTeamGeneration(taskID: idA), "sanity: A is generating")

        await sut.reconcileMissedRecurrences(now: now)

        XCTAssertNotNil(sut.loadedTask(idA), "a generating task must not be evicted mid-generation")
        sut.endTeamGeneration(taskID: idA)
    }

    // MARK: - Timeout watchdog state boundary

    /// The watchdog only enforces on `.running` / `.needsSupervisorInput`. A task
    /// parked awaiting acceptance (work done) is not "burning" budget and must not
    /// be timed out, even if its run is technically older than the limit.
    func testRunTimeout_needsAcceptanceState_notFired() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        let now = Date()
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 60
            task.runs = [Run(
                id: 0,
                createdAt: now.addingTimeInterval(-10_000),
                steps: [StepExecution(id: "a", role: .softwareEngineer, title: "C", status: .done)],
                roleStatuses: ["a": .needsAcceptance]
            )]
        }
        sut.engineState[taskID] = .needsAcceptance

        await sut.evaluateRunTimeouts(now: now)

        XCTAssertNil(sut.loadedTask(taskID)?.runs.last?.timedOutAt,
                     "a task awaiting acceptance is not enforced by the run-timeout watchdog")
    }

    // MARK: - taskSummaries(.recurring) production filter (review gap #6)

    func testTaskSummaries_recurringFilter_keepsOnlyTasksWithLiveNextFire() async {
        await sut.openWorkFolder(tempDir)
        let recID = await sut.createTask(title: "Recurring", supervisorTask: "x")!
        let plainID = await sut.createTask(title: "Plain", supervisorTask: "y")!
        await sut.setTaskRecurrence(taskID: recID, recurrence: TaskRecurrence(rule: .interval(seconds: 3_600)))

        let recurring = sut.taskSummaries(filter: .recurring)

        XCTAssertEqual(recurring.map(\.id), [recID], "only a task with a live next-fire is in the recurring filter")
        XCTAssertFalse(recurring.contains { $0.id == plainID }, "a non-recurring task is excluded")
    }
}
