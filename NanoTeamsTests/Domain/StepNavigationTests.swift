import XCTest
@testable import NanoTeams

/// Tests for NTMSTask+StepNavigation - step location and immutable mutations
final class StepNavigationTests: XCTestCase {

    // MARK: - Test Helpers

    func createStep(id: String = UUID().uuidString, role: Role = .productManager, status: StepStatus = .pending) -> StepExecution {
        StepExecution(id: id, role: role, title: role.displayName, status: status)
    }

    func createRun(id: Int = 0, steps: [StepExecution] = []) -> Run {
        Run(id: id, steps: steps)
    }

    func createTask(runs: [Run] = []) -> NTMSTask {
        NTMSTask(id: 0, title: "Test Task", supervisorTask: "Test Goal", runs: runs)
    }

    // MARK: - StepLocation Tests

    func testStepLocationInit() {
        let location = StepLocation(runIndex: 1, stepIndex: 2)

        XCTAssertEqual(location.runIndex, 1)
        XCTAssertEqual(location.stepIndex, 2)
    }

    // MARK: - locateStepInLatestRun Tests

    func testLocateStepInLatestRunFindsStep() {
        let stepID = "test_step"
        let step = createStep(id: stepID)
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let location = task.locateStepInLatestRun(stepID: stepID)

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.runIndex, 0)
        XCTAssertEqual(location?.stepIndex, 0)
    }

    func testLocateStepInLatestRunMultipleSteps() {
        let step1ID = "step1"
        let step2ID = "step2"
        let step3ID = "step3"
        let steps = [
            createStep(id: step1ID),
            createStep(id: step2ID),
            createStep(id: step3ID)
        ]
        let run = createRun(id: 0, steps: steps)
        let task = createTask(runs: [run])

        let location = task.locateStepInLatestRun(stepID: step2ID)

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.stepIndex, 1)
    }

    func testLocateStepInLatestRunUsesLatestRun() {
        let stepID = "test_step"
        let step1 = createStep()
        let step2 = createStep(id: stepID)

        let run1 = createRun(id: 0, steps: [step1])
        let run2 = createRun(id: 0, steps: [step2])
        let task = createTask(runs: [run1, run2])

        let location = task.locateStepInLatestRun(stepID: stepID)

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.runIndex, 1)
        XCTAssertEqual(location?.stepIndex, 0)
    }

    func testLocateStepInLatestRunStepNotInLatestRun() {
        let stepID = "test_step"
        let step1 = createStep(id: stepID)
        let step2 = createStep()

        let run1 = createRun(id: 0, steps: [step1])
        let run2 = createRun(id: 0, steps: [step2])
        let task = createTask(runs: [run1, run2])

        // Step is in run1, not run2
        let location = task.locateStepInLatestRun(stepID: stepID)

        XCTAssertNil(location)
    }

    func testLocateStepInLatestRunNoRuns() {
        let task = createTask(runs: [])

        let location = task.locateStepInLatestRun(stepID: "test_step")

        XCTAssertNil(location)
    }

    func testLocateStepInLatestRunStepNotFound() {
        let step = createStep()
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let location = task.locateStepInLatestRun(stepID: "test_step")

        XCTAssertNil(location)
    }

    // MARK: - locateStep(stepID:inRun:) Tests

    func testLocateStepInSpecificRun() {
        let stepID = "test_step"
        let runID = 0
        let step = createStep(id: stepID)
        let run = createRun(id: runID, steps: [step])
        let task = createTask(runs: [run])

        let location = task.locateStep(stepID: stepID, inRun: runID)

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.runIndex, 0)
        XCTAssertEqual(location?.stepIndex, 0)
    }

    func testLocateStepInSpecificRunNotFound() {
        let runID = 0
        let step = createStep()
        let run = createRun(id: runID, steps: [step])
        let task = createTask(runs: [run])

        let location = task.locateStep(stepID: "test_step", inRun: runID)

        XCTAssertNil(location)
    }

    func testLocateStepInWrongRun() {
        let stepID = "test_step"
        let run1ID = 0
        let run2ID = 1

        let step = createStep(id: stepID)
        let run1 = createRun(id: run1ID, steps: [step])
        let run2 = createRun(id: run2ID, steps: [])
        let task = createTask(runs: [run1, run2])

        // Step is in run1, looking in run2
        let location = task.locateStep(stepID: stepID, inRun: run2ID)

        XCTAssertNil(location)
    }

    func testLocateStepRunNotFound() {
        let step = createStep()
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let location = task.locateStep(stepID: step.id, inRun: 99)

        XCTAssertNil(location)
    }

    // MARK: - step(at:) Tests

    func testStepAtValidLocation() {
        let stepID = "test_step"
        let step = createStep(id: stepID, role: .softwareEngineer)
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let location = StepLocation(runIndex: 0, stepIndex: 0)
        let found = task.step(at: location)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, stepID)
        XCTAssertEqual(found?.role, .softwareEngineer)
    }

    func testStepAtInvalidRunIndex() {
        let step = createStep()
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let location = StepLocation(runIndex: 5, stepIndex: 0)
        let found = task.step(at: location)

        XCTAssertNil(found)
    }

    func testStepAtInvalidStepIndex() {
        let step = createStep()
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let location = StepLocation(runIndex: 0, stepIndex: 5)
        let found = task.step(at: location)

        XCTAssertNil(found)
    }

    func testStepAtNegativeIndices() {
        let step = createStep()
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        // Negative indices are invalid
        let location = StepLocation(runIndex: -1, stepIndex: 0)
        let found = task.step(at: location)

        XCTAssertNil(found)
    }

    // MARK: - latestRun Tests

    func testLatestRunWithRuns() {
        let run1 = createRun(id: 0)
        let run2ID = 1
        let run2 = createRun(id: run2ID)
        let task = createTask(runs: [run1, run2])

        let latest = task.latestRun

        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.id, run2ID)
    }

    func testLatestRunNoRuns() {
        let task = createTask(runs: [])

        XCTAssertNil(task.latestRun)
    }

    func testLatestRunSingleRun() {
        let runID = 0
        let run = createRun(id: runID)
        let task = createTask(runs: [run])

        let latest = task.latestRun

        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.id, runID)
    }

    // MARK: - latestRunIndex Tests

    func testLatestRunIndexWithRuns() {
        let task = createTask(runs: [createRun(id: 0), createRun(id: 0), createRun(id: 0)])

        XCTAssertEqual(task.latestRunIndex, 2)
    }

    func testLatestRunIndexNoRuns() {
        let task = createTask(runs: [])

        XCTAssertNil(task.latestRunIndex)
    }

    func testLatestRunIndexSingleRun() {
        let task = createTask(runs: [createRun(id: 0)])

        XCTAssertEqual(task.latestRunIndex, 0)
    }

    // MARK: - withStep(at:mutation:) Tests

    func testWithStepAtLocationMutatesStep() {
        let stepID = "test_step"
        let step = createStep(id: stepID, status: .pending)
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let location = StepLocation(runIndex: 0, stepIndex: 0)
        let updated = task.withStep(at: location) { step in
            step.status = .done
        }

        XCTAssertEqual(updated.runs[0].steps[0].status, .done)
    }

    func testWithStepAtLocationReturnsNewInstance() {
        let step = createStep(status: .pending)
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let location = StepLocation(runIndex: 0, stepIndex: 0)
        let updated = task.withStep(at: location) { step in
            step.status = .done
        }

        // Original should be unchanged
        XCTAssertEqual(task.runs[0].steps[0].status, .pending)
        // Updated should be changed
        XCTAssertEqual(updated.runs[0].steps[0].status, .done)
    }

    func testWithStepAtLocationUpdatesTimestamp() {
        let oldDate = Date(timeIntervalSince1970: 1000)
        var task = createTask(runs: [createRun(id: 0, steps: [createStep()])])
        task.updatedAt = oldDate

        let location = StepLocation(runIndex: 0, stepIndex: 0)
        let updated = task.withStep(at: location) { _ in }

        XCTAssertGreaterThan(updated.updatedAt, oldDate)
    }

    func testWithStepAtInvalidLocationReturnsSelf() {
        let task = createTask(runs: [createRun(id: 0, steps: [createStep()])])

        let location = StepLocation(runIndex: 5, stepIndex: 0)
        let updated = task.withStep(at: location) { step in
            step.status = .done
        }

        // Should return original task unchanged
        XCTAssertEqual(updated.id, task.id)
        XCTAssertEqual(updated.runs[0].steps[0].status, .pending)
    }

    // MARK: - withStep(stepID:mutation:) Tests

    func testWithStepByIDMutatesStep() {
        let stepID = "test_step"
        let step = createStep(id: stepID, status: .pending)
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let updated = task.withStep(stepID: stepID) { step in
            step.status = .running
        }

        XCTAssertEqual(updated.runs[0].steps[0].status, .running)
    }

    func testWithStepByIDNotFound() {
        let task = createTask(runs: [createRun(id: 0, steps: [createStep()])])

        let updated = task.withStep(stepID: "test_step") { step in
            step.status = .done
        }

        // Should return original unchanged
        XCTAssertEqual(updated.runs[0].steps[0].status, .pending)
    }

    // MARK: - withLatestRun Tests

    func testWithLatestRunMutatesRun() {
        let step = createStep(status: .pending)
        let run = createRun(id: 0, steps: [step])
        let task = createTask(runs: [run])

        let updated = task.withLatestRun { run in
            run.steps[0].status = .done
        }

        XCTAssertEqual(updated.runs[0].steps[0].status, .done)
    }

    func testWithLatestRunNoRunsReturnsSelf() {
        let task = createTask(runs: [])

        let updated = task.withLatestRun { _ in }

        XCTAssertEqual(updated.id, task.id)
    }

    func testWithLatestRunUpdatesTimestamp() {
        let oldDate = Date(timeIntervalSince1970: 1000)
        var task = createTask(runs: [createRun(id: 0)])
        task.updatedAt = oldDate

        let updated = task.withLatestRun { _ in }

        XCTAssertGreaterThan(updated.updatedAt, oldDate)
    }

    // MARK: - Run Extension Tests

    func testRunLocateStep() {
        let stepID = "test_step"
        let steps = [
            createStep(),
            createStep(id: stepID),
            createStep()
        ]
        let run = createRun(id: 0, steps: steps)

        let index = run.locateStep(stepID: stepID)

        XCTAssertEqual(index, 1)
    }

    func testRunLocateStepNotFound() {
        let run = createRun(id: 0, steps: [createStep()])

        let index = run.locateStep(stepID: "test_step")

        XCTAssertNil(index)
    }

    func testRunStepById() {
        let stepID = "test_step"
        let step = createStep(id: stepID, role: .sre)
        let run = createRun(id: 0, steps: [step])

        let found = run.step(id: stepID)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.role, .sre)
    }

    func testRunStepByIdNotFound() {
        let run = createRun(id: 0, steps: [createStep()])

        let found = run.step(id: "nonexistent")

        XCTAssertNil(found)
    }

    func testRunWithStepMutatesStep() {
        let stepID = "test_step"
        let step = createStep(id: stepID, status: .pending)
        let run = createRun(id: 0, steps: [step])

        let updated = run.withStep(stepID: stepID) { step in
            step.status = .done
        }

        XCTAssertEqual(updated.steps[0].status, .done)
    }

    func testRunWithStepNotFoundReturnsSelf() {
        let step = createStep(status: .pending)
        let run = createRun(id: 0, steps: [step])

        let updated = run.withStep(stepID: "test_step") { step in
            step.status = .done
        }

        XCTAssertEqual(updated.steps[0].status, .pending)
    }

    func testRunWithStepUpdatesTimestamp() {
        let stepID = "test_step"
        let oldDate = Date(timeIntervalSince1970: 1000)
        var run = createRun(id: 0, steps: [createStep(id: stepID)])
        run.updatedAt = oldDate

        let updated = run.withStep(stepID: stepID) { _ in }

        XCTAssertGreaterThan(updated.updatedAt, oldDate)
    }

    // MARK: - Complex Scenario Tests

    func testComplexNavigationScenario() {
        // Create a task with multiple runs and steps
        let step1ID = "step1"
        let step2ID = "step2"
        let step3ID = "step3"
        let run1ID = 0
        let run2ID = 1

        let run1 = createRun(id: run1ID, steps: [
            createStep(id: step1ID, role: .productManager, status: .done)
        ])
        let run2 = createRun(id: run2ID, steps: [
            createStep(id: step2ID, role: .productManager, status: .done),
            createStep(id: step3ID, role: .softwareEngineer, status: .running)
        ])

        let task = createTask(runs: [run1, run2])

        // Test various navigation
        XCTAssertNil(task.locateStepInLatestRun(stepID: step1ID)) // step1 is in run1, not latest
        XCTAssertNotNil(task.locateStepInLatestRun(stepID: step2ID))
        XCTAssertNotNil(task.locateStepInLatestRun(stepID: step3ID))

        XCTAssertNotNil(task.locateStep(stepID: step1ID, inRun: run1ID))
        XCTAssertNil(task.locateStep(stepID: step1ID, inRun: run2ID))

        // Test mutation
        let updated = task.withStep(stepID: step3ID) { step in
            step.status = .done
        }

        XCTAssertEqual(updated.runs[1].steps[1].status, .done)
        XCTAssertEqual(task.runs[1].steps[1].status, .running) // Original unchanged
    }
}
