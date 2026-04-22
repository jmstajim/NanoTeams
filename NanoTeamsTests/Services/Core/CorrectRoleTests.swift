import XCTest

@testable import NanoTeams

/// Tests for `correctRole()` — Supervisor corrects an active role while the task is paused.
/// Two branches: waiting-for-input (routes via answerSupervisorQuestion) and mid-stream
/// (appends feedback + sets revisionComment + auto-resumes).
@MainActor
final class CorrectRoleTests: NTMSOrchestratorTestBase {

    // MARK: - Helpers

    private func createTaskWithPausedStep(
        roleID: String,
        needsSupervisorInput: Bool,
        llmSessionID: String? = nil
    ) async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!

        let step = StepExecution(
            id: roleID,
            role: .productManager,
            title: "PM Step",
            status: .paused,
            messages: [StepMessage(role: .productManager, content: "Working…")],
            needsSupervisorInput: needsSupervisorInput,
            supervisorQuestion: needsSupervisorInput ? "Which option?" : nil,
            llmConversation: [LLMMessage(role: .assistant, content: "Prior turn")],
            llmSessionID: llmSessionID
        )
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [step], roleStatuses: [roleID: .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        return taskID
    }

    /// Force the orchestrator's engine-state view to report `.paused` for this task.
    /// Tests can't run a real engine, so we simulate the observable state directly.
    private func markEngineStatePaused(taskID: Int) {
        sut.engineState[taskID] = .paused
    }

    // MARK: - Guards

    func testCorrectRole_guard_requiresPausedEngineState() async {
        let roleID = "pm-guard"
        let taskID = await createTaskWithPausedStep(roleID: roleID, needsSupervisorInput: false)
        // Do NOT mark paused — engine state is .pending by default.

        await sut.correctRole(taskID: taskID, roleID: roleID, comment: "Fix this")

        let messages = sut.activeTask?.runs.last?.steps.first?.messages ?? []
        XCTAssertEqual(messages.count, 1, "No feedback message should be appended when engine isn't paused")
        XCTAssertNotNil(sut.lastErrorMessage, "Should surface a user-facing error")
    }

    func testCorrectRole_guard_rejectsEmptyComment() async {
        let roleID = "pm-empty"
        let taskID = await createTaskWithPausedStep(roleID: roleID, needsSupervisorInput: false)
        markEngineStatePaused(taskID: taskID)
        sut.lastErrorMessage = nil

        await sut.correctRole(taskID: taskID, roleID: roleID, comment: "   ")

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.messages.count, 1, "Whitespace-only comment must be a no-op")
        XCTAssertNil(step?.revisionComment)
        XCTAssertNotNil(sut.lastErrorMessage, "Empty comment must surface a user-facing error")
    }

    // MARK: - Branch B (mid-stream .running was paused)

    func testCorrectRole_branchB_appendsFeedbackAndSetsRevisionComment() async {
        let roleID = "pm-branchB"
        let taskID = await createTaskWithPausedStep(roleID: roleID, needsSupervisorInput: false)
        markEngineStatePaused(taskID: taskID)

        await sut.correctRole(taskID: taskID, roleID: roleID, comment: "Focus on mobile")

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.messages.count, 2, "Feedback message should be appended")
        XCTAssertEqual(step?.messages.last?.role, .supervisor)
        XCTAssertTrue(step?.messages.last?.content.contains("Focus on mobile") ?? false)
        XCTAssertTrue(step?.messages.last?.content.hasPrefix("Supervisor Feedback:") ?? false)
        XCTAssertEqual(step?.revisionComment, "Focus on mobile",
                       "revisionComment should be the raw trimmed comment (no prefix duplication)")
    }

    func testCorrectRole_branchB_trimsWhitespace() async {
        let roleID = "pm-trim"
        let taskID = await createTaskWithPausedStep(roleID: roleID, needsSupervisorInput: false)
        markEngineStatePaused(taskID: taskID)

        await sut.correctRole(taskID: taskID, roleID: roleID, comment: "  make it shorter  \n")

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.revisionComment, "make it shorter")
    }

    // MARK: - Branch A (was .needsSupervisorInput)

    func testCorrectRole_branchA_setsAnswerAndClearsNeedsInput() async {
        let roleID = "pm-branchA"
        let initialMessageCount = 1  // "Working…" seed message from createTaskWithPausedStep
        let taskID = await createTaskWithPausedStep(
            roleID: roleID,
            needsSupervisorInput: true,
            llmSessionID: "resp_abc123"
        )
        markEngineStatePaused(taskID: taskID)

        await sut.correctRole(taskID: taskID, roleID: roleID, comment: "Pick option B")

        let step = sut.activeTask?.runs.last?.steps.first
        // Post-state: answerSupervisorQuestion set the enriched answer.
        XCTAssertEqual(step?.supervisorAnswer, "Supervisor Feedback: Pick option B",
                       "Branch A should set the enriched answer via answerSupervisorQuestion")
        XCTAssertFalse(step?.needsSupervisorInput ?? true,
                       "answerSupervisorQuestion clears the needsSupervisorInput flag")
        // Branch A must NOT set revisionComment (session-based supervisor-continuation handles it).
        XCTAssertNil(step?.revisionComment,
                     "Branch A uses supervisor-continuation path, not revision-continuation")

        // Route-discriminating assertions — these prove we went through
        // `answerSupervisorQuestion` rather than falling through to Branch B
        // (which would append a StepMessage and set revisionComment):
        XCTAssertEqual(step?.messages.count, initialMessageCount,
                       "Branch A must NOT append a StepMessage — that's Branch B's behavior")
        XCTAssertEqual(step?.llmSessionID, "resp_abc123",
                       "Branch A must preserve llmSessionID so `previous_response_id` continuation keeps working")
        XCTAssertTrue(step?.supervisorAnswerAttachmentPaths.isEmpty ?? false,
                      "answerSupervisorQuestion clears attachment paths (Branch A passes no attachments)")
    }

    // MARK: - Silent-Failure Surfacing

    func testCorrectRole_unknownRoleID_surfacesError() async {
        let taskID = await createTaskWithPausedStep(roleID: "pm-existing", needsSupervisorInput: false)
        markEngineStatePaused(taskID: taskID)
        sut.lastErrorMessage = nil

        await sut.correctRole(taskID: taskID, roleID: "nonexistent-role", comment: "fix")

        XCTAssertNotNil(sut.lastErrorMessage,
                        "Unknown roleID must surface an error, not silently no-op")
        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.messages.count, 1,
                       "Existing step must not be mutated (still has its initial 'Working…' message)")
        XCTAssertNil(step?.revisionComment)
    }

    func testCorrectRole_nonPausedStep_surfacesError() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "G")!
        let roleID = "pm-running"
        let step = StepExecution(
            id: roleID, role: .productManager, title: "PM",
            status: .running,  // NOT .paused
            messages: []
        )
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [step], roleStatuses: [roleID: .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        markEngineStatePaused(taskID: taskID)
        sut.lastErrorMessage = nil

        await sut.correctRole(taskID: taskID, roleID: roleID, comment: "fix")

        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertTrue(sut.activeTask?.runs.last?.steps.first?.messages.isEmpty ?? false)
    }

    // MARK: - Invariants

    func testCorrectRole_doesNotTouchOtherSteps() async {
        let pmRoleID = "pm-iso"
        let sweRoleID = "swe-iso"
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!

        let pmStep = StepExecution(
            id: pmRoleID, role: .productManager, title: "PM",
            status: .paused,
            messages: [StepMessage(role: .productManager, content: "A")]
        )
        let sweStep = StepExecution(
            id: sweRoleID, role: .softwareEngineer, title: "SWE",
            status: .paused,
            messages: [StepMessage(role: .softwareEngineer, content: "B")]
        )
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [pmStep, sweStep],
                          roleStatuses: [pmRoleID: .working, sweRoleID: .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        markEngineStatePaused(taskID: taskID)

        await sut.correctRole(taskID: taskID, roleID: pmRoleID, comment: "Fix PM only")

        let run = sut.activeTask?.runs.last
        XCTAssertEqual(run?.steps.first(where: { $0.id == pmRoleID })?.messages.count, 2)
        XCTAssertEqual(run?.steps.first(where: { $0.id == sweRoleID })?.messages.count, 1,
                       "Sibling step messages must remain untouched")
        XCTAssertNil(run?.steps.first(where: { $0.id == sweRoleID })?.revisionComment)
    }
}
