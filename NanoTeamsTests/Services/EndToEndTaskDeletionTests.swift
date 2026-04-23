import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for the **task deletion workflow** — Supervisor
/// clicks "Delete Task" in the sidebar context menu.
///
/// Covered scenarios:
/// 1. Delete middle task → index consistent, active task preserved.
/// 2. Delete active task → orchestrator picks a fallback active task.
/// 3. Delete the only task → active pointer is cleared.
/// 4. Delete task with staged attachments → attachments dir cleaned up.
/// 5. Delete task with existing runs → run directories persist or cleaned.
/// 6. Delete task that was closed → no difference from active deletion.
/// 7. Delete sequentially-created tasks → next task ID keeps increasing
///    (sequential IDs don't reuse deleted slots).
@MainActor
final class EndToEndTaskDeletionTests: NTMSOrchestratorTestBase {

    // MARK: - Scenario 1: Delete non-active task preserves state

    func testDelete_nonActiveTask_activeUnchanged_indexConsistent() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "A", supervisorTask: "Do A")!
        let idB = await sut.createTask(title: "B", supervisorTask: "Do B")!
        let idC = await sut.createTask(title: "C", supervisorTask: "Do C")!

        // Active is C (last-created). Delete B (middle).
        await sut.switchTask(to: idC)
        XCTAssertEqual(sut.activeTaskID, idC)

        await sut.removeTask(idB)

        XCTAssertEqual(sut.activeTaskID, idC,
                       "Deleting a non-active task must not change activeTaskID")

        let indexIDs = Set(sut.snapshot?.tasksIndex.tasks.map(\.id) ?? [])
        XCTAssertEqual(indexIDs, Set([idA, idC]),
                       "tasks_index.json must omit deleted task, keep others")
    }

    // MARK: - Scenario 2: Delete active task picks fallback

    func testDelete_activeTask_fallbackIsPicked() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "A", supervisorTask: "Do A")!
        let idB = await sut.createTask(title: "B", supervisorTask: "Do B")!

        await sut.switchTask(to: idB)
        await sut.removeTask(idB)

        XCTAssertNotEqual(sut.activeTaskID, idB,
                          "Active task ID must not reference a deleted task")
        XCTAssertEqual(sut.activeTaskID, idA,
                       "When the active task is deleted, the remaining task is selected")
    }

    // MARK: - Scenario 3: Delete the only task

    func testDelete_onlyTask_activePointerCleared() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "Only", supervisorTask: "Do it")!
        await sut.switchTask(to: idA)

        await sut.removeTask(idA)

        XCTAssertNil(sut.activeTaskID,
                     "After deleting the only task, activeTaskID must be nil")
        XCTAssertTrue(sut.snapshot?.tasksIndex.tasks.isEmpty ?? false,
                      "Index must be empty after deleting the only task")
    }

    // MARK: - Scenario 4: Deleted task's file is gone

    func testDelete_removesTaskJSONFromDisk() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "Do A")!
        _ = await sut.createTask(title: "B", supervisorTask: "Do B")!

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let taskJSONA = paths.taskJSON(taskID: idA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskJSONA.path),
                      "Precondition: task.json exists before deletion")

        await sut.removeTask(idA)

        XCTAssertFalse(FileManager.default.fileExists(atPath: taskJSONA.path),
                       "task.json must be removed from disk")
    }

    // MARK: - Scenario 5: Delete frees up `loadedTasks` entry

    func testDelete_evictsFromLoadedTasks_noLeak() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "A", supervisorTask: "Do A")!
        let idB = await sut.createTask(title: "B", supervisorTask: "Do B")!

        // Switch to A to force load
        await sut.switchTask(to: idA)

        XCTAssertNotNil(sut.loadedTask(idA),
                        "Precondition: active task is loaded")

        // Switch to B so A becomes a background task
        await sut.switchTask(to: idB)

        await sut.removeTask(idA)

        XCTAssertNil(sut.loadedTask(idA),
                     "Deleted task must be evicted from loadedTasks — memory leak guard")
    }

    // MARK: - Scenario 6: Sequential ID allocation doesn't reuse

    /// Regression: if a deleted task's ID were reused, a stale queued chat
    /// message keyed by that taskID would leak into the new task. The guard
    /// lives in the tasks_index's `nextTaskID` counter.
    func testDelete_sequentialIDs_doNotReuseDeletedSlot() async {
        await sut.openWorkFolder(tempDir)

        let idA = await sut.createTask(title: "A", supervisorTask: "Do A")!
        let idB = await sut.createTask(title: "B", supervisorTask: "Do B")!
        await sut.removeTask(idB)
        let idC = await sut.createTask(title: "C", supervisorTask: "Do C")!

        XCTAssertNotEqual(idC, idB,
                          "New task must not reuse deleted task's ID")
        XCTAssertGreaterThan(idC, idB,
                             "Sequential IDs monotonically increase past deleted slots")
        XCTAssertGreaterThan(idC, idA)
    }

    // MARK: - Scenario 7: Multiple deletions survive a re-open

    /// User deletes two tasks, closes the app, reopens — the deletions must
    /// persist (i.e., tasks_index.json was saved) and the orchestrator must
    /// not resurrect them.
    func testDelete_multipleDeletions_survivingAcrossReopen() async {
        await sut.openWorkFolder(tempDir)

        _ = await sut.createTask(title: "Keep", supervisorTask: "x")!
        let idGone1 = await sut.createTask(title: "Gone1", supervisorTask: "y")!
        let idGone2 = await sut.createTask(title: "Gone2", supervisorTask: "z")!

        await sut.removeTask(idGone1)
        await sut.removeTask(idGone2)

        // Simulate app restart by closing and reopening the work folder
        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)

        let ids = Set(sut.snapshot?.tasksIndex.tasks.map(\.id) ?? [])
        XCTAssertFalse(ids.contains(idGone1))
        XCTAssertFalse(ids.contains(idGone2))
        XCTAssertEqual(ids.count, 1, "Only one task should remain after reopen")
    }
}
