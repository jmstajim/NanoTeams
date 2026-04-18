import XCTest

@testable import NanoTeams

final class StepExecutionServiceTests: XCTestCase {

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

    // MARK: - prepareStepForExecution Tests

    func testPrepareStepForExecution_injectsSupervisorCommentFromPreviousStep() {
        let step1ID = "step1"
        let step2ID = "step2"
        var step1 = makeStep(id: step1ID, status: .done, supervisorCommentForNext: "Important note")
        step1.supervisorCommentForNext = "Important note"
        let step2 = makeStep(id: step2ID, status: .pending)

        var task = makeTask(withSteps: [step1, step2])

        StepExecutionService.prepareStepForExecution(
            stepID: step2ID,
            in: &task
        )

        let messages = task.runs[0].steps[1].messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .supervisor)
        XCTAssertEqual(messages[0].content, "Supervisor Comment: Important note")
    }

    func testPrepareStepForExecution_doesNotDuplicateSupervisorComment() {
        let step1ID = "step1"
        let step2ID = "step2"
        var step1 = makeStep(id: step1ID, status: .done)
        step1.supervisorCommentForNext = "Important note"
        var step2 = makeStep(id: step2ID, status: .pending)
        // Simulate already injected message
        step2.messages.append(StepMessage(role: .supervisor, content: "Supervisor Comment: Important note"))

        var task = makeTask(withSteps: [step1, step2])

        StepExecutionService.prepareStepForExecution(
            stepID: step2ID,
            in: &task
        )

        // Should still be just 1 message, not duplicated
        XCTAssertEqual(task.runs[0].steps[1].messages.count, 1)
    }

    func testPrepareStepForExecution_doesNothingForNonexistentStep() {
        let step = makeStep(status: .pending)
        var task = makeTask(withSteps: [step])
        let originalStatus = task.runs[0].steps[0].status

        StepExecutionService.prepareStepForExecution(
            stepID: "test_step", // Different ID
            in: &task
        )

        XCTAssertEqual(task.runs[0].steps[0].status, originalStatus)
    }

    func testPrepareStepForExecution_doesNotInjectEmptySupervisorComment() {
        let step1ID = "step1"
        let step2ID = "step2"
        var step1 = makeStep(id: step1ID, status: .done)
        step1.supervisorCommentForNext = "   " // Whitespace only
        let step2 = makeStep(id: step2ID, status: .pending)

        var task = makeTask(withSteps: [step1, step2])

        StepExecutionService.prepareStepForExecution(
            stepID: step2ID,
            in: &task
        )

        XCTAssertTrue(task.runs[0].steps[1].messages.isEmpty)
    }

    // MARK: - approveStep Tests

    func testApproveStep_changesStatusFromNeedsApprovalToPending() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .needsApproval)

        var task = makeTask(withSteps: [step])

        StepExecutionService.approveStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .pending)
    }

    func testApproveStep_doesNotChangeOtherStatuses() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .running)

        var task = makeTask(withSteps: [step])

        StepExecutionService.approveStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .running)
    }

    func testApproveStep_injectsSupervisorCommentFromPreviousStep() {
        let step1ID = "step1"
        let step2ID = "step2"
        var step1 = makeStep(id: step1ID, status: .done)
        step1.supervisorCommentForNext = "Review feedback"
        let step2 = makeStep(id: step2ID, status: .needsApproval)

        var task = makeTask(withSteps: [step1, step2])

        StepExecutionService.approveStep(stepID: step2ID, in: &task)

        XCTAssertEqual(task.runs[0].steps[1].status, .pending)
        XCTAssertEqual(task.runs[0].steps[1].messages.count, 1)
        XCTAssertEqual(task.runs[0].steps[1].messages[0].content, "Supervisor Comment: Review feedback")
    }

    // MARK: - markStepRunning Tests

    func testMarkStepRunning_changesFromPendingToRunning() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .pending)

        var task = makeTask(withSteps: [step])

        StepExecutionService.markStepRunning(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .running)
    }

    func testMarkStepRunning_changesFromPausedToRunning() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .paused)

        var task = makeTask(withSteps: [step])

        StepExecutionService.markStepRunning(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .running)
    }

    func testMarkStepRunning_doesNotChangeOtherStatuses() {
        let statuses: [StepStatus] = [.needsApproval, .needsSupervisorInput, .done, .failed]

        for status in statuses {
            let stepID = "test_step"
            let step = makeStep(id: stepID, status: status)
            var task = makeTask(withSteps: [step])

            StepExecutionService.markStepRunning(stepID: stepID, in: &task)

            XCTAssertEqual(task.runs[0].steps[0].status, status, "Should not change \(status)")
        }
    }

    // MARK: - pauseStep Tests

    func testPauseStep_changesFromRunningToPaused() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .running)

        var task = makeTask(withSteps: [step])

        StepExecutionService.pauseStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
    }

    func testPauseStep_doesNotChangePendingStatus() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .pending)

        var task = makeTask(withSteps: [step])

        StepExecutionService.pauseStep(stepID: stepID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .pending)
    }

    // MARK: - redoStep Tests

    func testRedoStep_resetsStepAndSubsequentSteps() {
        let step1ID = "step1"
        let step2ID = "step2"
        let step3ID = "step3"
        var step1 = makeStep(id: step1ID, status: .done)
        step1.messages = [StepMessage(role: .productManager, content: "Done")]
        step1.artifacts = [Artifact(name: "Art")]
        var step2 = makeStep(id: step2ID, status: .done)
        step2.messages = [StepMessage(role: .tpm, content: "Done")]
        var step3 = makeStep(id: step3ID, status: .running)
        step3.scratchpad = "Some notes"

        var task = makeTask(withSteps: [step1, step2, step3])

        // Redo from step2 - should reset step2 and step3, but not step1
        StepExecutionService.redoStep(stepID: step2ID, in: &task)

        // Step1 unchanged
        XCTAssertEqual(task.runs[0].steps[0].status, .done)
        XCTAssertFalse(task.runs[0].steps[0].messages.isEmpty)

        // Step2 reset
        XCTAssertEqual(task.runs[0].steps[1].status, .pending) // manual mode default
        XCTAssertTrue(task.runs[0].steps[1].messages.isEmpty)
        XCTAssertTrue(task.runs[0].steps[1].artifacts.isEmpty)

        // Step3 reset
        XCTAssertEqual(task.runs[0].steps[2].status, .pending)
        XCTAssertNil(task.runs[0].steps[2].scratchpad)
    }

    func testRedoStep_clearsAllStepData() {
        let stepID = "test_step"
        var step = makeStep(id: stepID, status: .done)
        step.messages = [StepMessage(role: .productManager, content: "Message")]
        step.artifacts = [Artifact(name: "Art")]
        step.toolCalls = [StepToolCall(name: "tool", argumentsJSON: "{}")]
        step.scratchpad = "Notes"
        step.needsSupervisorInput = true
        step.supervisorQuestion = "Question?"
        step.supervisorAnswer = "Answer"
        step.supervisorCommentForNext = "Comment"

        var task = makeTask(withSteps: [step])

        StepExecutionService.redoStep(stepID: stepID, in: &task)

        let resetStep = task.runs[0].steps[0]
        XCTAssertTrue(resetStep.messages.isEmpty)
        XCTAssertTrue(resetStep.artifacts.isEmpty)
        XCTAssertTrue(resetStep.toolCalls.isEmpty)
        XCTAssertNil(resetStep.scratchpad)
        XCTAssertFalse(resetStep.needsSupervisorInput)
        XCTAssertNil(resetStep.supervisorQuestion)
        XCTAssertNil(resetStep.supervisorAnswer)
        XCTAssertNil(resetStep.supervisorCommentForNext)
    }

    // MARK: - stepStatus Tests

    func testStepStatus_returnsCorrectStatus() {
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .running)
        let task = makeTask(withSteps: [step])

        let status = StepExecutionService.stepStatus(stepID: stepID, from: task)

        XCTAssertEqual(status, .running)
    }

    func testStepStatus_returnsNilForNonexistentStep() {
        let step = makeStep(status: .pending)
        let task = makeTask(withSteps: [step])

        let status = StepExecutionService.stepStatus(stepID: "nonexistent_step", from: task)

        XCTAssertNil(status)
    }

    func testStepStatus_returnsNilForNilTask() {
        let status = StepExecutionService.stepStatus(stepID: "test_step", from: nil)

        XCTAssertNil(status)
    }

    func testStepStatus_returnsNilForTaskWithNoRuns() {
        let task = NTMSTask(id: 0, title: "Empty", supervisorTask: "", runs: [])

        let status = StepExecutionService.stepStatus(stepID: "test_step", from: task)

        XCTAssertNil(status)
    }

    // MARK: - Edge Cases

    func testFirstStepDoesNotInjectSupervisorComment() {
        // First step (index 0) should not try to inject comment from previous step
        let stepID = "test_step"
        let step = makeStep(id: stepID, status: .pending)

        var task = makeTask(withSteps: [step])

        StepExecutionService.prepareStepForExecution(
            stepID: stepID,
            in: &task
        )

        XCTAssertTrue(task.runs[0].steps[0].messages.isEmpty)
    }

    func testOperationsOnEmptyTaskDoNotCrash() {
        var task = NTMSTask(id: 0, title: "Empty", supervisorTask: "", runs: [])
        let stepID = "test_step"

        // These should all be no-ops, not crash
        StepExecutionService.prepareStepForExecution(stepID: stepID, in: &task)
        StepExecutionService.approveStep(stepID: stepID, in: &task)
        StepExecutionService.markStepRunning(stepID: stepID, in: &task)
        StepExecutionService.pauseStep(stepID: stepID, in: &task)
        StepExecutionService.redoStep(stepID: stepID, in: &task)

        XCTAssertTrue(task.runs.isEmpty)
    }

    func testMultipleRunsUsesLatestRun() {
        let stepID = "test_step"
        let step1 = makeStep(status: .done) // Old run
        let step2 = makeStep(id: stepID, status: .pending) // New run

        let run1 = Run(id: 0, steps: [step1])
        let run2 = Run(id: 0, steps: [step2])
        var task = NTMSTask(id: 0, title: "Multi-run", supervisorTask: "", runs: [run1, run2])

        StepExecutionService.markStepRunning(stepID: stepID, in: &task)

        // Should only affect latest run
        XCTAssertEqual(task.runs[0].steps[0].status, .done)
        XCTAssertEqual(task.runs[1].steps[0].status, .running)
    }
}
