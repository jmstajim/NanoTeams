import XCTest

@testable import NanoTeams

/// Tests for `finishAdvisoryRole()` — immediate advisory role completion.
/// Advisory roles have no output artifacts but have input artifacts (`isAdvisory`).
/// Finish sets step→.done + role→.done directly, no intermediate states.
@MainActor
final class FinishAdvisoryRoleTests: NTMSOrchestratorTestBase {

    // MARK: - Helpers

    /// Creates a task with a run containing the given step and role status.
    private func createTaskWithRun(
        step: StepExecution? = nil,
        roleID: String,
        roleStatus: RoleExecutionStatus
    ) async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!

        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(
                id: 0,
                steps: step.map { [$0] } ?? [],
                roleStatuses: [roleID: roleStatus]
            )
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        return taskID
    }

    /// Wait briefly for the fire-and-forget `Task { }` in `finishAdvisoryRole` to complete.
    private func waitForFinish() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Running Step

    func testFinishAdvisoryRole_withRunningStep_setsStepDone() async {
        let roleID = "reviewer-123"
        let step = StepExecution(
            id: roleID,
            role: .codeReviewer,
            title: "Review",
            status: .running
        )
        let taskID = await createTaskWithRun(
            step: step, roleID: roleID, roleStatus: .working
        )

        sut.finishAdvisoryRole(taskID: taskID, roleID: roleID)
        await waitForFinish()

        let run = sut.activeTask?.runs.last
        XCTAssertEqual(run?.roleStatuses[roleID], .done)

        let updatedStep = run?.steps.first
        XCTAssertEqual(updatedStep?.status, .done)
        XCTAssertNotNil(updatedStep?.completedAt)
    }

    // MARK: - NeedsSupervisorInput Step

    func testFinishAdvisoryRole_withSupervisorInputStep_setsStepDone() async {
        let roleID = "reviewer-456"
        let step = StepExecution(
            id: roleID,
            role: .codeReviewer,
            title: "Review",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Should I continue?"
        )
        let taskID = await createTaskWithRun(
            step: step, roleID: roleID, roleStatus: .working
        )

        sut.finishAdvisoryRole(taskID: taskID, roleID: roleID)
        await waitForFinish()

        let run = sut.activeTask?.runs.last
        XCTAssertEqual(run?.roleStatuses[roleID], .done)
        XCTAssertEqual(run?.steps.first?.status, .done)
        XCTAssertNotNil(run?.steps.first?.completedAt)
    }

    // MARK: - No Step (Ready Role)

    func testFinishAdvisoryRole_withoutStep_marksRoleDone() async {
        let roleID = "reviewer-789"
        let taskID = await createTaskWithRun(
            step: nil, roleID: roleID, roleStatus: .ready
        )

        sut.finishAdvisoryRole(taskID: taskID, roleID: roleID)
        await waitForFinish()

        let run = sut.activeTask?.runs.last
        XCTAssertEqual(run?.roleStatuses[roleID], .done)
        XCTAssertTrue(run?.steps.isEmpty ?? false)
    }

    // MARK: - Pending Step

    func testFinishAdvisoryRole_withPendingStep_setsStepDone() async {
        let roleID = "reviewer-pending"
        let step = StepExecution(
            id: roleID,
            role: .codeReviewer,
            title: "Review",
            status: .pending
        )
        let taskID = await createTaskWithRun(
            step: step, roleID: roleID, roleStatus: .ready
        )

        sut.finishAdvisoryRole(taskID: taskID, roleID: roleID)
        await waitForFinish()

        let run = sut.activeTask?.runs.last
        XCTAssertEqual(run?.roleStatuses[roleID], .done)
        XCTAssertEqual(run?.steps.first?.status, .done)
    }

    // MARK: - Edge Cases

    func testFinishAdvisoryRole_nonExistentTask_doesNotCrash() async {
        await sut.openWorkFolder(tempDir)

        sut.finishAdvisoryRole(taskID: Int(), roleID: "fake")
        await waitForFinish()

        // Should not crash — method returns early
    }

    func testFinishAdvisoryRole_noRuns_doesNotCrash() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!

        // Remove all runs
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = []
        }

        sut.finishAdvisoryRole(taskID: taskID, roleID: "whatever")
        await waitForFinish()

        // Should not crash
    }

    // MARK: - Does Not Affect Other Roles

    func testFinishAdvisoryRole_doesNotAffectOtherRoles() async {
        let advisoryRoleID = "reviewer-a"
        let otherRoleID = "engineer-b"
        let advisoryStep = StepExecution(
            id: advisoryRoleID,
            role: .codeReviewer,
            title: "Review",
            status: .running
        )
        let otherStep = StepExecution(
            id: otherRoleID,
            role: .softwareEngineer,
            title: "Implement",
            status: .running
        )

        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!

        await sut.mutateTask(taskID: taskID) { task in
            let run = Run(
                id: 0,
                steps: [advisoryStep, otherStep],
                roleStatuses: [
                    advisoryRoleID: .working,
                    otherRoleID: .working,
                ]
            )
            task.runs = [run]
        }

        sut.finishAdvisoryRole(taskID: taskID, roleID: advisoryRoleID)
        await waitForFinish()

        let run = sut.activeTask?.runs.last
        // Advisory role finished
        XCTAssertEqual(run?.roleStatuses[advisoryRoleID], .done)
        XCTAssertEqual(run?.steps.first(where: { $0.effectiveRoleID == advisoryRoleID })?.status, .done)

        // Other role untouched
        XCTAssertEqual(run?.roleStatuses[otherRoleID], .working)
        XCTAssertEqual(run?.steps.first(where: { $0.effectiveRoleID == otherRoleID })?.status, .running)
    }

    // MARK: - CompletedAt Timestamp

    func testFinishAdvisoryRole_setsCompletedAtTimestamp() async {
        let roleID = "reviewer-ts"
        let step = StepExecution(
            id: roleID,
            role: .codeReviewer,
            title: "Review",
            status: .running
        )
        let taskID = await createTaskWithRun(
            step: step, roleID: roleID, roleStatus: .working
        )

        let beforeFinish = MonotonicClock.shared.now()

        sut.finishAdvisoryRole(taskID: taskID, roleID: roleID)
        await waitForFinish()

        let completedAt = sut.activeTask?.runs.last?.steps.first?.completedAt
        XCTAssertNotNil(completedAt)
        XCTAssertGreaterThan(completedAt!, beforeFinish)
    }
}
