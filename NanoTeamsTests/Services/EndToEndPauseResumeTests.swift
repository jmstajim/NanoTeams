import XCTest

@testable import NanoTeams

/// E2E tests for pause/resume flow with status recovery:
/// pause → status transitions → recovery service → resume.
@MainActor
final class EndToEndPauseResumeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Pause sets correct statuses

    func testPause_setsStepsAndRolesToCorrectStatuses() {
        var task = makeRunningTask()

        // Simulate pause: running steps → paused, roles working → idle
        for runIndex in task.runs.indices {
            for stepIndex in task.runs[runIndex].steps.indices {
                StepExecutionService.pauseStep(
                    stepID: task.runs[runIndex].steps[stepIndex].id,
                    in: &task
                )
            }
        }

        let step = task.runs[0].steps[0]
        XCTAssertEqual(step.status, .paused, "Running step should become paused")
    }

    // MARK: - Test 2: Pause preserves supervisor input steps

    func testPause_preservesSupervisorInputSteps() {
        var task = makeTaskWithSupervisorInput()

        // Pause step that needs supervisor input
        let stepID = task.runs[0].steps[0].id
        StepExecutionService.pauseStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .paused,
                       "needsSupervisorInput step should become paused")
    }

    // MARK: - Test 3: StatusRecoveryService recovers stale statuses

    func testStatusRecovery_staleRunningSteps_becomesPaused() {
        var task = makeRunningTask()

        // Simulate app restart — steps stuck in .running without engine
        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed, "Should report changes made")
        XCTAssertEqual(task.runs[0].steps[0].status, .paused,
                       "Stale running step should become paused")
    }

    // MARK: - Test 4: StatusRecoveryService handles needsSupervisorInput

    func testStatusRecovery_staleNeedsSupervisorInput_becomesPaused() {
        var task = makeTaskWithSupervisorInput()

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused,
                       "Stale needsSupervisorInput should become paused")
    }

    // MARK: - Test 5: StatusRecoveryService recovers working roles

    func testStatusRecovery_workingRoles_becomeIdle() {
        var task = makeRunningTask()
        task.runs[0].roleStatuses["swe-role"] = .working

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].roleStatuses["swe-role"], .idle,
                       "Stale working role should become idle")
    }

    // MARK: - Test 6: Recovery sets task status to paused

    func testStatusRecovery_setsTaskStatusToPaused() {
        var task = makeRunningTask()
        task.status = .running

        StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertEqual(task.status, .paused,
                       "Task status should become .paused after recovery")
    }

    // MARK: - Test 7: Done steps not affected by recovery

    func testStatusRecovery_doneSteps_notAffected() {
        var task = makeDoneTask()

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task)

        XCTAssertFalse(changed, "Done steps should not be changed")
        XCTAssertEqual(task.runs[0].steps[0].status, .done)
    }

    // MARK: - Test 8: markStepRunning restores from paused

    func testResume_markStepRunning_restoresFromPaused() {
        var task = makeRunningTask()

        // Pause
        let stepID = task.runs[0].steps[0].id
        StepExecutionService.pauseStep(stepID: stepID, in: &task)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)

        // Resume
        StepExecutionService.markStepRunning(stepID: stepID, in: &task)
        XCTAssertEqual(task.runs[0].steps[0].status, .running,
                       "Paused step should become running after resume")
    }

    // MARK: - Helpers

    private func makeRunningTask() -> NTMSTask {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineering Notes",
            expectedArtifacts: ["Engineering Notes"],
            status: .running
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["swe-role": .working])
        return NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
    }

    private func makeTaskWithSupervisorInput() -> NTMSTask {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "work",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "How should I proceed?"
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
    }

    private func makeDoneTask() -> NTMSTask {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "done work",
            status: .done,
            completedAt: MonotonicClock.shared.now()
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["swe-role": .done])
        return NTMSTask(id: 0, title: "Done", supervisorTask: "Goal", status: .done, runs: [run])
    }
}
