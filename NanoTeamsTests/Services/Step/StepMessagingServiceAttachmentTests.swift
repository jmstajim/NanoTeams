import XCTest

@testable import NanoTeams

final class StepMessagingServiceAttachmentTests: XCTestCase {

    // MARK: - Fixtures

    private func createTaskWithSupervisorQuestion() -> (task: NTMSTask, stepID: String) {
        var task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Test goal")
        var run = Run(id: 0)
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Software Engineer",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Should I proceed?"
        )
        run.steps.append(step)
        task.runs.append(run)
        return (task, step.id)
    }

    // MARK: - Attachment Paths

    func testAnswerWithAttachments_storesAttachmentPaths() {
        var (task, stepID) = createTaskWithSupervisorQuestion()
        let paths = [
            ".nanoteams/tasks/abc/attachments/screenshot.png",
            ".nanoteams/tasks/abc/attachments/design.pdf",
        ]

        StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "See attached", attachmentPaths: paths, in: &task
        )

        let step = task.runs[0].steps[0]
        XCTAssertEqual(step.supervisorAnswer, "See attached")
        XCTAssertEqual(step.supervisorAnswerAttachmentPaths, paths)
        XCTAssertFalse(step.needsSupervisorInput)
        XCTAssertEqual(step.status, .pending)
    }

    func testAnswerWithEmptyAttachments_storesEmptyArray() {
        var (task, stepID) = createTaskWithSupervisorQuestion()

        StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "Just text", attachmentPaths: [], in: &task
        )

        let step = task.runs[0].steps[0]
        XCTAssertEqual(step.supervisorAnswer, "Just text")
        XCTAssertTrue(step.supervisorAnswerAttachmentPaths.isEmpty)
    }

    func testAnswerWithDefaultAttachments_omitsParameter() {
        var (task, stepID) = createTaskWithSupervisorQuestion()

        // Calling without attachmentPaths parameter (uses default [])
        StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "Answer", in: &task
        )

        let step = task.runs[0].steps[0]
        XCTAssertEqual(step.supervisorAnswer, "Answer")
        XCTAssertTrue(step.supervisorAnswerAttachmentPaths.isEmpty)
    }

    func testAnswerWithAttachments_clearsExistingAttachments() {
        var (task, stepID) = createTaskWithSupervisorQuestion()
        task.runs[0].steps[0].supervisorAnswerAttachmentPaths = ["old/path.png"]

        StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "New answer", attachmentPaths: ["new/path.png"], in: &task
        )

        XCTAssertEqual(task.runs[0].steps[0].supervisorAnswerAttachmentPaths, ["new/path.png"])
    }

    func testEmptyAnswerWithAttachments_setsNilAnswer() {
        var (task, stepID) = createTaskWithSupervisorQuestion()

        StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "", attachmentPaths: ["file.png"], in: &task
        )

        let step = task.runs[0].steps[0]
        // Answer text is nil (trimmed empty), but attachments are stored
        XCTAssertNil(step.supervisorAnswer)
        XCTAssertEqual(step.supervisorAnswerAttachmentPaths, ["file.png"])
        XCTAssertFalse(step.needsSupervisorInput)
    }

    func testAnswerClearsStaleAttachmentPaths_onNewQuestion() {
        var (task, stepID) = createTaskWithSupervisorQuestion()
        // Simulate a previous answer with attachments
        task.runs[0].steps[0].supervisorAnswer = "Old answer"
        task.runs[0].steps[0].supervisorAnswerAttachmentPaths = ["old/file.png"]
        task.runs[0].steps[0].needsSupervisorInput = true
        task.runs[0].steps[0].status = .needsSupervisorInput

        // New answer without attachments should clear old paths
        StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: "New answer", in: &task
        )

        let step = task.runs[0].steps[0]
        XCTAssertEqual(step.supervisorAnswer, "New answer")
        XCTAssertTrue(step.supervisorAnswerAttachmentPaths.isEmpty)
    }

    func testInvalidStepID_noEffect() {
        var (task, _) = createTaskWithSupervisorQuestion()
        let invalidID = "invalid_step_id"

        StepMessagingService.answerSupervisorQuestion(
            stepID: invalidID, answer: "Answer", attachmentPaths: ["file.png"], in: &task
        )

        let step = task.runs[0].steps[0]
        XCTAssertTrue(step.needsSupervisorInput)
        XCTAssertNil(step.supervisorAnswer)
        XCTAssertTrue(step.supervisorAnswerAttachmentPaths.isEmpty)
    }
}
