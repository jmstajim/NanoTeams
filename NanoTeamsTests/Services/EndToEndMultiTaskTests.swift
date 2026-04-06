import XCTest

@testable import NanoTeams

/// E2E tests for multi-task concurrent execution: engine isolation, task switching,
/// background task preservation, and adapter routing.
@MainActor
final class EndToEndMultiTaskTests: NTMSOrchestratorTestBase {

    // MARK: - Test 1: Two tasks created successfully

    func testMultiTask_twoTasksCreated() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "Task A", supervisorTask: "Build A")
        XCTAssertNotNil(idA)

        let idB = await sut.createTask(title: "Task B", supervisorTask: "Build B")
        XCTAssertNotNil(idB)

        // Both should be different IDs
        XCTAssertNotEqual(idA, idB)
    }

    // MARK: - Test 2: Task switch preserves background task

    func testMultiTask_switchPreservesBackgroundTask() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "Task A", supervisorTask: "Build A")!
        _ = await sut.createTask(title: "Task B", supervisorTask: "Build B")!

        // Switch to task A
        await sut.switchTask(to: idA)
        XCTAssertEqual(sut.activeTaskID, idA)

        // Active task should be A
        XCTAssertEqual(sut.activeTask?.title, "Task A")
    }

    // MARK: - Test 3: Background mutation is isolated

    func testMultiTask_backgroundMutationIsolated() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "Task A", supervisorTask: "Build A")!
        let idB = await sut.createTask(title: "Task B", supervisorTask: "Build B")!

        await sut.switchTask(to: idA)

        // Mutate task A
        await sut.mutateTask(taskID: idA) { task in
            task.status = .paused
        }

        // Switch to B — B's status should not be affected
        await sut.switchTask(to: idB)
        XCTAssertNotEqual(sut.activeTask?.status, .paused,
                          "Task B should not be affected by Task A mutation")
    }

    // MARK: - Test 4: Close active task while background exists

    func testMultiTask_closeActiveWhileBackgroundExists() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "Task A", supervisorTask: "Build A")!
        let idB = await sut.createTask(title: "Task B", supervisorTask: "Build B")!

        // Close task A
        await sut.switchTask(to: idA)
        await sut.mutateTask(taskID: idA) { task in
            task.closedAt = MonotonicClock.shared.now()
            task.status = .done
        }

        XCTAssertNotNil(sut.activeTask?.closedAt)

        // Switch to B — should be accessible
        await sut.switchTask(to: idB)
        XCTAssertEqual(sut.activeTaskID, idB)
        XCTAssertNil(sut.activeTask?.closedAt, "Task B should not be closed")
    }

    // MARK: - Test 5: Engine state is per-task isolated

    func testMultiTask_engineStateIsolated() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "Task A", supervisorTask: "Build A")!
        let idB = await sut.createTask(title: "Task B", supervisorTask: "Build B")!

        // Set engine states independently
        sut.engineState[idA] = .running
        sut.engineState[idB] = .paused

        XCTAssertEqual(sut.engineState[idA], .running)
        XCTAssertEqual(sut.engineState[idB], .paused)

        // Remove one engine — other unaffected
        sut.engineState.removeEngine(for: idA)
        XCTAssertNil(sut.engineState[idA])
        XCTAssertEqual(sut.engineState[idB], .paused,
                       "Removing engine A should not affect engine B")
    }

    // MARK: - Test 6: Adapter routes mutations to correct task

    func testMultiTask_adapterRoutesToCorrectTask() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "Task A", supervisorTask: "Build A")!
        let idB = await sut.createTask(title: "Task B", supervisorTask: "Build B")!

        // Mutate each task independently
        await sut.mutateTask(taskID: idA) { task in
            task.supervisorTask = "Updated A"
        }
        await sut.mutateTask(taskID: idB) { task in
            task.supervisorTask = "Updated B"
        }

        // Verify
        await sut.switchTask(to: idA)
        XCTAssertEqual(sut.activeTask?.supervisorTask, "Updated A")

        await sut.switchTask(to: idB)
        XCTAssertEqual(sut.activeTask?.supervisorTask, "Updated B")
    }
}
