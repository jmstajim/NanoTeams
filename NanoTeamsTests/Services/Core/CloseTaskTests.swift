import XCTest

@testable import NanoTeams

/// Tests for closeTask — step finalization, LLM cancellation, meeting cleanup.
@MainActor
final class CloseTaskTests: NTMSOrchestratorTestBase {

    // MARK: - Chat Mode: Step Finalization

    func testCloseTask_chatMode_runningStep_becomeDone() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        // Inject a running step (simulates chat advisory role mid-execution)
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .running),
            ], roleStatuses: ["assistant": .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        let task = sut.activeTask!
        XCTAssertNotNil(task.closedAt)
        XCTAssertEqual(task.runs.last?.steps.first?.status, .done)
        XCTAssertNotNil(task.runs.last?.steps.first?.completedAt)
        XCTAssertEqual(task.runs.last?.roleStatuses["assistant"], .done)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    func testCloseTask_chatMode_pausedStep_becomesDone() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .paused),
            ], roleStatuses: ["assistant": .working])]
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .done)
        XCTAssertEqual(sut.activeTask?.derivedStatusFromActiveRun(), .done)
    }

    func testCloseTask_chatMode_needsSupervisorInputStep_becomesDone() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .needsSupervisorInput),
            ], roleStatuses: ["assistant": .working])]
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .done)
        XCTAssertEqual(sut.activeTask?.derivedStatusFromActiveRun(), .done)
    }

    // MARK: - Non-Chat Mode: No-Op for Already-Done Steps

    func testCloseTask_nonChatMode_doneSteps_unchanged() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Task", supervisorTask: "Build")!

        let completedAt = MonotonicClock.shared.now()
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "pm", role: .productManager, title: "PM", status: .done, completedAt: completedAt),
                StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .done, completedAt: completedAt),
            ], roleStatuses: ["pm": .done, "swe": .done])]
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        let steps = sut.activeTask!.runs.last!.steps
        // completedAt should be preserved (not overwritten by closeTask)
        XCTAssertEqual(steps[0].completedAt, completedAt)
        XCTAssertEqual(steps[1].completedAt, completedAt)
    }

    // MARK: - Preserves Failed/Pending Steps

    func testCloseTask_failedStep_preservesFailedStatus() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .failed),
            ], roleStatuses: ["assistant": .failed])]
        }

        _ = await sut.closeTask(taskID: taskID)

        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .failed,
                        "Failed steps should preserve their status for diagnostics")
    }

    func testCloseTask_pendingStep_preservesPendingStatus() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .pending),
            ])]
        }

        _ = await sut.closeTask(taskID: taskID)

        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .pending,
                        "Pending steps (never started) should not be marked done")
    }

    // MARK: - Multiple Steps Mixed Statuses

    func testCloseTask_multipleSteps_finalizesOnlyNonTerminal() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "role_a", role: .custom(id: "a"), title: "A", status: .running),
                StepExecution(id: "role_b", role: .custom(id: "b"), title: "B", status: .done),
                StepExecution(id: "role_c", role: .custom(id: "c"), title: "C", status: .paused),
                StepExecution(id: "role_d", role: .custom(id: "d"), title: "D", status: .failed),
            ], roleStatuses: ["role_a": .working, "role_b": .done, "role_c": .working, "role_d": .failed])]
        }

        _ = await sut.closeTask(taskID: taskID)

        let steps = sut.activeTask!.runs.last!.steps
        XCTAssertEqual(steps[0].status, .done, "Running → done")
        XCTAssertEqual(steps[1].status, .done, "Done stays done")
        XCTAssertEqual(steps[2].status, .done, "Paused → done")
        XCTAssertEqual(steps[3].status, .failed, "Failed stays failed")

        let roles = sut.activeTask!.runs.last!.roleStatuses
        XCTAssertEqual(roles["role_a"], .done)
        XCTAssertEqual(roles["role_b"], .done)
        XCTAssertEqual(roles["role_c"], .done)
        XCTAssertEqual(roles["role_d"], .failed, "Failed role status preserved")
    }

    // MARK: - Engine & Meeting Cleanup

    func testCloseTask_stopsEngineAndClearsMeetingParticipants() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        // Simulate active engine + meeting participants
        sut.engineState[taskID] = .running
        sut.engineState.setMeetingParticipants(["role_a", "role_b"], for: taskID)

        _ = await sut.closeTask(taskID: taskID)

        XCTAssertNil(sut.taskEngineStates[taskID], "Engine state should be removed")
        XCTAssertNil(sut.engineState.activeMeetingParticipants[taskID],
                     "Meeting participants should be cleared")
    }

    func testStopEngine_clearsMeetingParticipants() {
        sut.engineState[0] = .running
        sut.engineState.setMeetingParticipants(["a", "b"], for: 0)

        sut.stopEngine(for: 0)

        XCTAssertNil(sut.engineState.activeMeetingParticipants[0])
    }

    func testRemoveAllEngines_clearsMeetingParticipants() {
        sut.engineState[0] = .running
        sut.engineState[1] = .paused
        sut.engineState.setMeetingParticipants(["a"], for: 0)
        sut.engineState.setMeetingParticipants(["b"], for: 1)

        sut.engineState.removeAllEngines()

        XCTAssertTrue(sut.engineState.activeMeetingParticipants.isEmpty)
        XCTAssertTrue(sut.engineState.taskEngineStates.isEmpty)
    }

    // MARK: - Empty Runs

    func testCloseTask_noRuns_stillSetsClosedAt() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Help")!

        // Remove all runs
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = []
        }

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        XCTAssertNotNil(sut.activeTask?.closedAt)
    }
}
