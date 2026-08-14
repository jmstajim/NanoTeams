import XCTest

@testable import NanoTeams

/// The run-timeout watchdog measures a budget against `Run.createdAt` — a
/// `MonotonicClock` stamp — so its `now` must come from the SAME clock.
///
/// `NTMSOrchestrator+Scheduling`'s header states that scheduling comparisons use wall-clock
/// `Date()`, and for the recurrence half that is exactly right: `RecurrenceRule` computes
/// `nextFireAt` from a wall-clock date, so `nextFireAt <= now` compares like with like. The
/// timeout half is the other kind of comparison — its other operand is a MODEL timestamp — and
/// it inherited the wall-clock `now` anyway. `MonotonicClock.now()` is
/// `max(Date(), last + 1ms)`, so it only ever runs AHEAD of the wall clock; subtracting a
/// monotonic stamp from a wall-clock one therefore UNDERSTATES elapsed time by exactly the
/// drift accumulated when the run was stamped, and the budget fires late or not at all.
///
/// This is the class CLAUDE.md's 2026-07-18 audit swept and fixed in four places
/// (`AppUpdateState`, `AutovisorStatus.idleSeconds` / `.roleElapsedSeconds`,
/// `list_tasks.updated_seconds_ago`, `AutovisorStuckEvaluator`'s recency cutoff). The two
/// `AutovisorStatus` helpers even carry the contract in their signatures — `now: Date =
/// MonotonicClock.shared.now()` — and name their pin. This one was missed.
@MainActor
final class RunTimeoutClockCoverageTests: NTMSOrchestratorTestBase {

    /// Drift big enough to separate the two clocks, then undone — a test that moves the shared
    /// clock and does not reset it manufactures flakes in the next class on the same worker
    /// (CLAUDE.md, 2026-07-18).
    private func induceClockDrift() -> TimeInterval {
        for _ in 0..<40_000 { _ = MonotonicClock.shared.now() }
        return MonotonicClock.shared.now().timeIntervalSince(Date())
    }

    private func seedOverBudgetRun(taskID: Int, createdAt: Date, timeout: TimeInterval) async {
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = timeout
            task.runs = [Run(
                id: 0,
                createdAt: createdAt,
                steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .running)],
                roleStatuses: ["a": .working]
            )]
        }
        sut.engineState[taskID] = .running
    }

    /// RED: restore `now: Date = Date()` on `evaluateRunTimeouts` → the run is 30s old on the
    /// clock that stamped it and the budget is 20s, but a wall-clock `now` reads the age as
    /// `30 - drift` seconds (negative here), so the watchdog never fires and the run burns
    /// past its budget unbounded.
    func testRunTimeout_isMeasuredOnTheStampingClock_notWallClock() async {
        defer { MonotonicClock.shared.reset() }
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!

        let drift = induceClockDrift()
        XCTAssertGreaterThan(
            drift, 10, "Setup invariant: the two clocks must be separated by more than the "
                + "margin between the run's age and its budget, or this proves nothing")

        // 30s old on the clock that stamps `Run.createdAt`, against a 20s budget.
        await seedOverBudgetRun(
            taskID: taskID,
            createdAt: MonotonicClock.shared.now().addingTimeInterval(-30),
            timeout: 20)

        // No `now:` argument — this is the production call the poll loop makes.
        await sut.evaluateRunTimeouts()

        XCTAssertNotNil(
            sut.loadedTask(taskID)?.runs.last?.timedOutAt,
            "a run 30s past its 20s budget on its own stamping clock must time out")
    }

    /// RED: same mutation → `timedOutAt` is stamped from the wall clock while `createdAt` came
    /// from the monotonic one, so the run records having timed out BEFORE it started. The three
    /// dates on `Run` are siblings; `Run.createdAt` and `.updatedAt` are both `MonotonicClock`
    /// stamps, and a marker that can precede the creation it annotates is not a timestamp.
    func testRunTimeout_stampIsOrderedAfterTheRunItMarks() async {
        defer { MonotonicClock.shared.reset() }
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!

        let drift = induceClockDrift()
        XCTAssertGreaterThan(drift, 10, "Setup invariant")

        let createdAt = MonotonicClock.shared.now().addingTimeInterval(-30)
        await seedOverBudgetRun(taskID: taskID, createdAt: createdAt, timeout: 20)

        await sut.evaluateRunTimeouts()

        guard let stamp = sut.loadedTask(taskID)?.runs.last?.timedOutAt else {
            return XCTFail("the run did not time out — see the sibling test")
        }
        XCTAssertGreaterThan(
            stamp, createdAt,
            "`timedOutAt` must be orderable against the `createdAt` it is measured from")
    }

    /// The fix must not make the watchdog trigger-happy: a run genuinely under budget on the
    /// stamping clock still must not fire, drift or no drift.
    func testRunTimeout_underBudgetOnTheStampingClock_stillDoesNotFire() async {
        defer { MonotonicClock.shared.reset() }
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!

        _ = induceClockDrift()
        await seedOverBudgetRun(
            taskID: taskID,
            createdAt: MonotonicClock.shared.now().addingTimeInterval(-10),
            timeout: 3_600)

        await sut.evaluateRunTimeouts()

        XCTAssertNil(
            sut.loadedTask(taskID)?.runs.last?.timedOutAt,
            "10s into a 3600s budget is not a timeout on any clock")
    }
}
