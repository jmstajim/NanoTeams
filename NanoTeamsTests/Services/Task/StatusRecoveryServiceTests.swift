import XCTest

@testable import NanoTeams

@MainActor
final class StatusRecoveryServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Helpers

    private func makeTask(
        stepStatuses: [StepStatus],
        roleStatuses: [String: RoleExecutionStatus] = [:]
    ) -> NTMSTask {
        let steps = stepStatuses.map { status in
            StepExecution(
                id: "test_step",
                role: .softwareEngineer,
                title: "Step",
                status: status
            )
        }
        let run = Run(
            id: 0,
            steps: steps,
            roleStatuses: roleStatuses
        )
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [run]
        return task
    }

    // MARK: - Step Recovery Tests

    func testRecoverRunningStepsToPaused() {
        var task = makeTask(stepStatuses: [.running, .done, .pending])

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.runs[0].steps[1].status, .done)
        XCTAssertEqual(task.runs[0].steps[2].status, .pending)
        XCTAssertEqual(task.status, .paused)
    }

    func testRecoverNeedsSupervisorInputStepsToPaused() {
        var task = makeTask(stepStatuses: [.needsSupervisorInput, .done])

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.runs[0].steps[1].status, .done)
        XCTAssertEqual(task.status, .paused)
    }

    func testRecoverMultipleStaleSteps() {
        var task = makeTask(stepStatuses: [.running, .needsSupervisorInput, .running])

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.runs[0].steps[1].status, .paused)
        XCTAssertEqual(task.runs[0].steps[2].status, .paused)
    }

    // MARK: - Role Recovery Tests

    func testRecoverWorkingRolesToIdle() {
        var task = makeTask(
            stepStatuses: [.running],
            roleStatuses: [
                "softwareEngineer": .working,
                "productManager": .done,
                "sre": .idle,
            ]
        )

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].roleStatuses["softwareEngineer"], .idle)
        XCTAssertEqual(task.runs[0].roleStatuses["productManager"], .done)
        XCTAssertEqual(task.runs[0].roleStatuses["sre"], .idle)
        XCTAssertEqual(task.status, .paused)
    }

    // MARK: - No-op Tests

    func testNoChangeWhenAllStatusesSafe() {
        var task = makeTask(
            stepStatuses: [.done, .pending, .paused],
            roleStatuses: [
                "softwareEngineer": .done,
                "productManager": .accepted,
                "sre": .idle,
            ]
        )
        let originalStatus = task.status

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertFalse(changed)
        XCTAssertEqual(task.status, originalStatus, "task.status should not change when no recovery needed")
    }

    func testReturnsFalseWhenNoRuns() {
        var task = NTMSTask(id: 0, title: "Empty", supervisorTask: "Goal")
        task.runs = []

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertFalse(changed)
    }

    // MARK: - Chat Mode Recovery Tests

    func testRecoverChatModeTask_setsPaused() {
        var task = makeTask(stepStatuses: [.running])
        task.isChatMode = true

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.status, .paused)
        XCTAssertTrue(task.isChatMode, "isChatMode should be preserved after recovery")
    }

    // MARK: - Preserved Status Tests

    func testPreservesCompletedStatuses() {
        var task = makeTask(
            stepStatuses: [.done, .failed, .needsApproval],
            roleStatuses: [
                "softwareEngineer": .done,
                "productManager": .accepted,
                "uxDesigner": .failed,
                "sre": .needsAcceptance,
                "tpm": .revisionRequested,
                "supervisor": .skipped,
            ]
        )

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertFalse(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .done)
        XCTAssertEqual(task.runs[0].steps[1].status, .failed)
        XCTAssertEqual(task.runs[0].steps[2].status, .needsApproval)
        XCTAssertEqual(task.runs[0].roleStatuses["softwareEngineer"], .done)
        XCTAssertEqual(task.runs[0].roleStatuses["productManager"], .accepted)
        XCTAssertEqual(task.runs[0].roleStatuses["uxDesigner"], .failed)
        XCTAssertEqual(task.runs[0].roleStatuses["sre"], .needsAcceptance)
        XCTAssertEqual(task.runs[0].roleStatuses["tpm"], .revisionRequested)
        XCTAssertEqual(task.runs[0].roleStatuses["supervisor"], .skipped)
    }

    // MARK: - Timestamp Tests

    func testUpdatesTimestampsOnChange() {
        var task = makeTask(stepStatuses: [.running])
        let originalTaskUpdatedAt = task.updatedAt
        let originalStepUpdatedAt = task.runs[0].steps[0].updatedAt

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed)
        XCTAssertGreaterThan(task.updatedAt, originalTaskUpdatedAt)
        XCTAssertGreaterThan(task.runs[0].steps[0].updatedAt, originalStepUpdatedAt)
        XCTAssertGreaterThan(task.runs[0].updatedAt, originalTaskUpdatedAt)
    }

    func testDoesNotUpdateTimestampsWhenNoChange() {
        var task = makeTask(stepStatuses: [.done, .pending])
        let originalUpdatedAt = task.updatedAt

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertFalse(changed)
        XCTAssertEqual(task.updatedAt, originalUpdatedAt)
    }

    // MARK: - Multiple Runs Tests

    func testRecoverMultipleRuns() {
        let step1 = StepExecution(id: "test_step", role: .productManager, title: "Step1", status: .running)
        let step2 = StepExecution(id: "test_step", role: .softwareEngineer, title: "Step2", status: .needsSupervisorInput)

        let run1 = Run(id: 0, steps: [step1], roleStatuses: ["productManager": .working])
        let run2 = Run(id: 0, steps: [step2], roleStatuses: ["softwareEngineer": .working])

        var task = NTMSTask(id: 0, title: "Multi-run", supervisorTask: "Goal")
        task.runs = [run1, run2]

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.runs[0].roleStatuses["productManager"], .idle)
        XCTAssertEqual(task.runs[1].steps[0].status, .paused)
        XCTAssertEqual(task.runs[1].roleStatuses["softwareEngineer"], .idle)
    }
}
