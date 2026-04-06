import XCTest

@testable import NanoTeams

final class StepMessagingServiceTests: XCTestCase {

    // MARK: - Test Fixtures

    private func createTaskWithStep() -> (task: NTMSTask, stepID: String) {
        var task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Test goal")

        // Create a run with a step
        var run = Run(id: 0)
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Software Engineer",
            status: .running
        )
        run.steps.append(step)
        task.runs.append(run)

        return (task, step.id)
    }

    // MARK: - setSupervisorCommentForNext Tests

    func testSetSupervisorCommentForNext_setsComment() {
        var (task, stepID) = createTaskWithStep()
        let comment = "Please focus on error handling"

        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: comment, in: &task)

        let step = task.runs[0].steps[0]
        XCTAssertEqual(step.supervisorCommentForNext, comment)
    }

    func testSetSupervisorCommentForNext_trimsWhitespace() {
        var (task, stepID) = createTaskWithStep()
        let comment = "   Trim this comment   \n\n"

        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: comment, in: &task)

        let step = task.runs[0].steps[0]
        XCTAssertEqual(step.supervisorCommentForNext, "Trim this comment")
    }

    func testSetSupervisorCommentForNext_emptyCommentSetsNil() {
        var (task, stepID) = createTaskWithStep()

        // First set a comment
        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: "Initial comment", in: &task)
        XCTAssertNotNil(task.runs[0].steps[0].supervisorCommentForNext)

        // Then clear it with empty string
        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: "", in: &task)
        XCTAssertNil(task.runs[0].steps[0].supervisorCommentForNext)
    }

    func testSetSupervisorCommentForNext_whitespaceOnlyCommentSetsNil() {
        var (task, stepID) = createTaskWithStep()

        // First set a comment
        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: "Initial", in: &task)

        // Then "clear" it with whitespace
        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: "   \n\t  ", in: &task)
        XCTAssertNil(task.runs[0].steps[0].supervisorCommentForNext)
    }

    func testSetSupervisorCommentForNext_invalidStepID_noEffect() {
        var (task, _) = createTaskWithStep()
        let invalidStepID = "invalid_step_id"

        // Should not crash, just no effect
        StepMessagingService.setSupervisorCommentForNext(stepID: invalidStepID, comment: "Test", in: &task)

        // Original step should be unaffected
        XCTAssertNil(task.runs[0].steps[0].supervisorCommentForNext)
    }

    func testSetSupervisorCommentForNext_updatesExistingComment() {
        var (task, stepID) = createTaskWithStep()

        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: "First comment", in: &task)
        XCTAssertEqual(task.runs[0].steps[0].supervisorCommentForNext, "First comment")

        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: "Updated comment", in: &task)
        XCTAssertEqual(task.runs[0].steps[0].supervisorCommentForNext, "Updated comment")
    }

    // MARK: - answerSupervisorQuestion Tests

    func testAnswerSupervisorQuestion_setsAnswer() {
        var (task, stepID) = createTaskWithStep()
        task.runs[0].steps[0].needsSupervisorInput = true

        StepMessagingService.answerSupervisorQuestion(stepID: stepID, answer: "Yes, proceed", in: &task)

        let step = task.runs[0].steps[0]
        XCTAssertEqual(step.supervisorAnswer, "Yes, proceed")
        XCTAssertFalse(step.needsSupervisorInput)
    }

    func testAnswerSupervisorQuestion_trimsAnswer() {
        var (task, stepID) = createTaskWithStep()
        task.runs[0].steps[0].needsSupervisorInput = true

        StepMessagingService.answerSupervisorQuestion(stepID: stepID, answer: "  Trimmed answer  \n", in: &task)

        XCTAssertEqual(task.runs[0].steps[0].supervisorAnswer, "Trimmed answer")
    }

    func testAnswerSupervisorQuestion_emptyAnswerSetsNil() {
        var (task, stepID) = createTaskWithStep()
        task.runs[0].steps[0].needsSupervisorInput = true
        task.runs[0].steps[0].supervisorAnswer = "Previous answer"

        StepMessagingService.answerSupervisorQuestion(stepID: stepID, answer: "", in: &task)

        XCTAssertNil(task.runs[0].steps[0].supervisorAnswer)
    }

    func testAnswerSupervisorQuestion_clearsNeedsSupervisorInput() {
        var (task, stepID) = createTaskWithStep()
        task.runs[0].steps[0].needsSupervisorInput = true

        StepMessagingService.answerSupervisorQuestion(stepID: stepID, answer: "Answer", in: &task)

        XCTAssertFalse(task.runs[0].steps[0].needsSupervisorInput)
    }

    func testAnswerSupervisorQuestion_setsStatusToPending() {
        var (task, stepID) = createTaskWithStep()
        task.runs[0].steps[0].status = .needsSupervisorInput
        task.runs[0].steps[0].needsSupervisorInput = true

        StepMessagingService.answerSupervisorQuestion(stepID: stepID, answer: "Answer", in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .pending)
    }

    func testAnswerSupervisorQuestion_nonNeedsSupervisorInputStatus_statusUnchanged() {
        var (task, stepID) = createTaskWithStep()
        task.runs[0].steps[0].status = .running
        task.runs[0].steps[0].needsSupervisorInput = true

        StepMessagingService.answerSupervisorQuestion(stepID: stepID, answer: "Answer", in: &task)

        // Status should remain running since it wasn't needsSupervisorInput
        XCTAssertEqual(task.runs[0].steps[0].status, .running)
    }

    func testAnswerSupervisorQuestion_invalidStepID_noEffect() {
        var (task, _) = createTaskWithStep()
        let invalidStepID = "invalid_step_id"
        task.runs[0].steps[0].needsSupervisorInput = true

        StepMessagingService.answerSupervisorQuestion(stepID: invalidStepID, answer: "Answer", in: &task)

        // Original step should be unaffected
        XCTAssertTrue(task.runs[0].steps[0].needsSupervisorInput)
        XCTAssertNil(task.runs[0].steps[0].supervisorAnswer)
    }

    // MARK: - Multi-Run Tests

    func testSetSupervisorCommentForNext_findsStepInLatestRun() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")

        // First run with a step
        var run1 = Run(id: 0)
        let step1 = StepExecution(id: "test_step", role: .softwareEngineer, title: "Software Engineer", status: .done)
        run1.steps.append(step1)
        task.runs.append(run1)

        // Second run (latest) with a step
        var run2 = Run(id: 0)
        let step2 = StepExecution(id: "test_step", role: .softwareEngineer, title: "Software Engineer", status: .running)
        run2.steps.append(step2)
        task.runs.append(run2)

        // Set comment for step in latest run
        StepMessagingService.setSupervisorCommentForNext(stepID: step2.id, comment: "Latest run comment", in: &task)

        // Step in run 2 should have the comment
        XCTAssertEqual(task.runs[1].steps[0].supervisorCommentForNext, "Latest run comment")
        // Step in run 1 should not have the comment
        XCTAssertNil(task.runs[0].steps[0].supervisorCommentForNext)
    }

    // MARK: - Edge Cases

    func testAnswerSupervisorQuestion_multilineAnswer() {
        var (task, stepID) = createTaskWithStep()
        task.runs[0].steps[0].needsSupervisorInput = true

        let multilineAnswer = "Line 1\nLine 2\nLine 3"
        StepMessagingService.answerSupervisorQuestion(stepID: stepID, answer: multilineAnswer, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].supervisorAnswer, multilineAnswer)
    }

    func testSetSupervisorCommentForNext_multilineComment() {
        var (task, stepID) = createTaskWithStep()

        let multilineComment = "Point 1\nPoint 2\nPoint 3"
        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: multilineComment, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].supervisorCommentForNext, multilineComment)
    }

    func testSetSupervisorCommentForNext_unicodeComment() {
        var (task, stepID) = createTaskWithStep()

        let unicodeComment = "Add emoji support 🎉 and i18n 日本語"
        StepMessagingService.setSupervisorCommentForNext(stepID: stepID, comment: unicodeComment, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].supervisorCommentForNext, unicodeComment)
    }
}
