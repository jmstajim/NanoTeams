import XCTest

@testable import NanoTeams

final class StepExecutionServiceExtendedTests: XCTestCase {

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Test Helpers

    private func makeTask(
        withSteps steps: [StepExecution]
    ) -> NTMSTask {
        let run = Run(id: 0, steps: steps)
        return NTMSTask(id: 0, title: "Test Task",
            supervisorTask: "Test goal",
            runs: [run]
        )
    }

    private func makeStep(
        id: String = "test_step",
        role: Role = .productManager,
        status: StepStatus = .pending,
        supervisorCommentForNext: String? = nil
    ) -> StepExecution {
        StepExecution(
            id: id,
            role: role,
            title: "\(role.displayName) Step",
            status: status,
            supervisorCommentForNext: supervisorCommentForNext
        )
    }

    // MARK: - approveStep Tests

    func testApproveStep_fromNeedsApproval_setsPending() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .needsApproval)
        var task = makeTask(withSteps: [step])

        StepExecutionService.approveStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .pending)
    }

    func testApproveStep_fromPending_doesNothing() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .pending)
        var task = makeTask(withSteps: [step])

        StepExecutionService.approveStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .pending)
    }

    func testApproveStep_fromRunning_doesNothing() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .running)
        var task = makeTask(withSteps: [step])

        StepExecutionService.approveStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .running)
    }

    // MARK: - markStepRunning Tests

    func testMarkStepRunning_fromPending_setsRunning() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .pending)
        var task = makeTask(withSteps: [step])

        StepExecutionService.markStepRunning(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .running)
    }

    func testMarkStepRunning_fromPaused_setsRunning() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .paused)
        var task = makeTask(withSteps: [step])

        StepExecutionService.markStepRunning(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .running)
    }

    func testMarkStepRunning_fromDone_doesNothing() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .done)
        var task = makeTask(withSteps: [step])

        StepExecutionService.markStepRunning(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .done)
    }

    func testMarkStepRunning_fromRunning_doesNothing() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .running)
        var task = makeTask(withSteps: [step])

        StepExecutionService.markStepRunning(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .running)
    }

    // MARK: - pauseStep Tests

    func testPauseStep_fromRunning_setsPaused() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .running)
        var task = makeTask(withSteps: [step])

        StepExecutionService.pauseStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
    }

    func testPauseStep_fromNeedsSupervisorInput_setsPaused() {
        let stepID = "test_step"
        var step = makeStep(id: stepID, status: .needsSupervisorInput)
        step.needsSupervisorInput = true
        step.supervisorQuestion = "What should I do?"
        var task = makeTask(withSteps: [step])

        StepExecutionService.pauseStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
    }

    func testPauseStep_fromPending_doesNothing() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .pending)
        var task = makeTask(withSteps: [step])

        StepExecutionService.pauseStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .pending)
    }

    func testPauseStep_fromDone_doesNothing() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .done)
        var task = makeTask(withSteps: [step])

        StepExecutionService.pauseStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .done)
    }

    // MARK: - redoStep Tests

    func testRedoStep_resetsTargetStep() {
        let stepID = "test_step"
        var step = makeStep(id: stepID, status: .done)
        step.messages = [StepMessage(role: .productManager, content: "Completed")]
        step.artifacts = [Artifact(name: "Requirements")]
        var task = makeTask(withSteps: [step])

        StepExecutionService.redoStep(stepID: stepID, in: &task)

        let resetStep = task.runs[0].steps[0]
        XCTAssertEqual(resetStep.status, .pending)
        XCTAssertTrue(resetStep.messages.isEmpty)
        XCTAssertTrue(resetStep.artifacts.isEmpty)
    }

    func testRedoStep_resetsAllSubsequentSteps() {
        let step1ID = "step1"
        let step2ID = "step2"
        let step3ID = "step3"
        let step4ID = "step4id"

        var step1 = makeStep(id: step1ID, status: .done)
        step1.messages = [StepMessage(role: .productManager, content: "Step 1 done")]
        step1.artifacts = [Artifact(name: "Art1")]

        var step2 = makeStep(id: step2ID, role: .techLead, status: .done)
        step2.messages = [StepMessage(role: .techLead, content: "Step 2 done")]

        var step3 = makeStep(id: step3ID, role: .softwareEngineer, status: .running)
        step3.workNotes = "Working on implementation"

        var step4 = makeStep(id: step4ID, role: .codeReviewer, status: .pending)

        var task = makeTask(withSteps: [step1, step2, step3, step4])

        // Redo from step2 - should reset steps 2, 3, 4 but not step1
        StepExecutionService.redoStep(stepID: step2ID, in: &task)

        // Step1 unchanged
        XCTAssertEqual(task.runs[0].steps[0].status, .done)
        XCTAssertFalse(task.runs[0].steps[0].messages.isEmpty)
        XCTAssertFalse(task.runs[0].steps[0].artifacts.isEmpty)

        // Step2 reset
        XCTAssertEqual(task.runs[0].steps[1].status, .pending)
        XCTAssertTrue(task.runs[0].steps[1].messages.isEmpty)

        // Step3 reset
        XCTAssertEqual(task.runs[0].steps[2].status, .pending)
        XCTAssertNil(task.runs[0].steps[2].workNotes)

        // Step4 reset
        XCTAssertEqual(task.runs[0].steps[3].status, .pending)
    }

    func testRedoStep_clearsAllStepFields() {
        let stepID = "test_step"
        var step = makeStep(id: stepID, status: .done)
        step.messages = [StepMessage(role: .productManager, content: "Message")]
        step.artifacts = [Artifact(name: "Artifact")]
        step.toolCalls = [StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"/tmp/file.txt\"}")]
        step.workNotes = "Some work notes"
        step.needsSupervisorInput = true
        step.supervisorQuestion = "What should I do next?"
        step.supervisorAnswer = "Proceed with the plan"
        step.supervisorCommentForNext = "Good job, keep going"

        var task = makeTask(withSteps: [step])

        StepExecutionService.redoStep(stepID: stepID, in: &task)

        let resetStep = task.runs[0].steps[0]
        XCTAssertTrue(resetStep.messages.isEmpty, "messages should be cleared")
        XCTAssertTrue(resetStep.artifacts.isEmpty, "artifacts should be cleared")
        XCTAssertTrue(resetStep.toolCalls.isEmpty, "toolCalls should be cleared")
        XCTAssertNil(resetStep.workNotes, "workNotes should be nil")
        XCTAssertFalse(resetStep.needsSupervisorInput, "needsSupervisorInput should be false")
        XCTAssertNil(resetStep.supervisorQuestion, "supervisorQuestion should be nil")
        XCTAssertNil(resetStep.supervisorAnswer, "supervisorAnswer should be nil")
        XCTAssertNil(resetStep.supervisorCommentForNext, "supervisorCommentForNext should be nil")
    }

    // MARK: - stepStatus Tests

    func testStepStatus_returnsCorrectStatus() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .needsApproval)
        let task = makeTask(withSteps: [step])

        let status = StepExecutionService.stepStatus(stepID: stepID, from: task)

        XCTAssertEqual(status, .needsApproval)
    }

    func testStepStatus_nilTask_returnsNil() {
        let status = StepExecutionService.stepStatus(stepID: "test_step", from: nil)

        XCTAssertNil(status)
    }

    func testStepStatus_unknownStepID_returnsNil() {
        let step = makeStep(status: .running)
        let task = makeTask(withSteps: [step])

        let status = StepExecutionService.stepStatus(stepID: "nonexistent_step", from: task)

        XCTAssertNil(status)
    }

    // MARK: - Supervisor Comment Injection Deduplication

    func testSupervisorCommentInjection_doesNotDuplicate() {
        let step1ID = "step1"
        let step2ID = "step2"
        var step1 = makeStep(id: step1ID, status: .done)
        step1.supervisorCommentForNext = "Please review carefully"
        let step2 = makeStep(id: step2ID, status: .pending)

        var task = makeTask(withSteps: [step1, step2])

        // First call should inject the comment
        StepExecutionService.prepareStepForExecution(
            stepID: step2ID,
            in: &task
        )

        XCTAssertEqual(task.runs[0].steps[1].messages.count, 1)
        XCTAssertEqual(task.runs[0].steps[1].messages[0].role, .supervisor)
        XCTAssertEqual(task.runs[0].steps[1].messages[0].content, "Supervisor Comment: Please review carefully")

        // Second call with the same comment should NOT add another message
        StepExecutionService.prepareStepForExecution(
            stepID: step2ID,
            in: &task
        )

        XCTAssertEqual(task.runs[0].steps[1].messages.count, 1, "Should not duplicate Supervisor comment on repeated calls")
    }
}
