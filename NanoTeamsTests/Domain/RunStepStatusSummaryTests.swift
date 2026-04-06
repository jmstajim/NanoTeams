import XCTest

@testable import NanoTeams

final class RunStepStatusSummaryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Helpers

    private func makeStep(status: StepStatus) -> StepExecution {
        StepExecution(id: UUID().uuidString, role: .softwareEngineer, title: "Step", status: status)
    }

    private func makeRun(statuses: [StepStatus]) -> Run {
        Run(id: 0, steps: statuses.map { makeStep(status: $0) })
    }

    // MARK: - stepStatusSummary Tests

    func testStepStatusSummary_allDone() {
        let run = makeRun(statuses: [.done, .done, .done])
        let summary = run.stepStatusSummary()

        XCTAssertTrue(summary.allDone)
        XCTAssertFalse(summary.hasFailed)
        XCTAssertFalse(summary.hasNeedsSupervisorInput)
        XCTAssertFalse(summary.hasPaused)
        XCTAssertFalse(summary.hasNeedsApproval)
    }

    func testStepStatusSummary_hasFailed_doesNotPreventAllDone() {
        // .failed does NOT set allDone=false (by design — failed is an error flag, not a "still working" flag)
        let run = makeRun(statuses: [.failed, .done, .done])
        let summary = run.stepStatusSummary()

        XCTAssertTrue(summary.allDone, ".failed should not prevent allDone")
        XCTAssertTrue(summary.hasFailed)
    }

    func testStepStatusSummary_mixedStatuses() {
        let run = makeRun(statuses: [
            .pending, .paused, .needsSupervisorInput, .needsApproval, .done, .failed,
        ])
        let summary = run.stepStatusSummary()

        XCTAssertFalse(summary.allDone)
        XCTAssertTrue(summary.hasFailed)
        XCTAssertTrue(summary.hasPaused)
        XCTAssertTrue(summary.hasNeedsSupervisorInput)
        XCTAssertTrue(summary.hasNeedsApproval)
    }

    func testStepStatusSummary_hasRunning() {
        let run = makeRun(statuses: [.running, .done])
        let summary = run.stepStatusSummary()

        XCTAssertTrue(summary.hasRunning)
        XCTAssertFalse(summary.allDone)
    }

    func testStepStatusSummary_pendingIsNotRunning() {
        let run = makeRun(statuses: [.pending, .done])
        let summary = run.stepStatusSummary()

        XCTAssertFalse(summary.hasRunning)
        XCTAssertFalse(summary.allDone)
    }

    func testStepStatusSummary_emptySteps() {
        let run = Run(id: 0, steps: [])
        let summary = run.stepStatusSummary()

        // Vacuous truth: no steps → allDone=true
        XCTAssertTrue(summary.allDone)
        XCTAssertFalse(summary.hasFailed)
        XCTAssertFalse(summary.hasNeedsSupervisorInput)
        XCTAssertFalse(summary.hasPaused)
        XCTAssertFalse(summary.hasNeedsApproval)
    }

    // MARK: - derivedTaskStatus Priority Chain

    func testDerivedTaskStatus_priorityChain() {
        // Priority: failed > needsSupervisorInput > paused > needsApproval(→paused when idle) > allDone(→done) > running

        // 1. failed takes priority over everything
        let failedRun = makeRun(statuses: [.failed, .needsSupervisorInput, .paused])
        XCTAssertEqual(failedRun.derivedStatus(), .failed)

        // 2. needsSupervisorInput over paused
        let supervisorRun = makeRun(statuses: [.needsSupervisorInput, .paused, .done])
        XCTAssertEqual(supervisorRun.derivedStatus(), .needsSupervisorInput)

        // 3. paused
        let pausedRun = makeRun(statuses: [.paused, .done])
        XCTAssertEqual(pausedRun.derivedStatus(), .paused)

        // 4. needsApproval maps to .paused
        let approvalRun = makeRun(statuses: [.needsApproval, .done])
        XCTAssertEqual(approvalRun.derivedStatus(), .paused)

        // 5. allDone maps to .done
        let doneRun = makeRun(statuses: [.done, .done])
        XCTAssertEqual(doneRun.derivedStatus(), .done)

        // 6. running (default — some steps still pending/running)
        let runningRun = makeRun(statuses: [.running, .pending])
        XCTAssertEqual(runningRun.derivedStatus(), .running)
    }
}
