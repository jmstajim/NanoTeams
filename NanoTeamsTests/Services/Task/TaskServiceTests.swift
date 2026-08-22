import XCTest

@testable import NanoTeams

@MainActor
final class TaskServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var repository: NTMSRepository!
    private var service: TaskService!

    override func setUp() async throws {
        try await super.setUp()
        // Use standardizedFileURL to resolve symlinks (/var -> /private/var on macOS)
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repository = NTMSRepository()
        service = TaskService(repository: repository)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    private func initializeProject() throws -> WorkFolderContext {
        try repository.openOrCreateWorkFolder(at: tempDir)
    }

    // MARK: - Create Task Tests

    func testCreateTaskReturnsUpdatedContext() throws {
        _ = try initializeProject()

        let (result, _) = try service.createTask(
            at: tempDir,
            title: "My First Task",
            supervisorTask: "Build something great"
        )

        XCTAssertEqual(result.tasksIndex.tasks.count, 1)
        XCTAssertEqual(result.tasksIndex.tasks[0].title, "My First Task")
        XCTAssertNotNil(result.activeTask)
        XCTAssertEqual(result.activeTask?.title, "My First Task")
        XCTAssertEqual(result.activeTask?.supervisorTask, "Build something great")
    }

    func testCreateMultipleTasks() throws {
        _ = try initializeProject()

        _ = try service.createTask(at: tempDir, title: "Task 1", supervisorTask: "Goal 1")
        let (result, _) = try service.createTask(at: tempDir, title: "Task 2", supervisorTask: "Goal 2")

        XCTAssertEqual(result.tasksIndex.tasks.count, 2)
        // Most recent task is the active one
        XCTAssertEqual(result.activeTask?.title, "Task 2")
    }

    func testCreateTaskWithEmptyTitle() throws {
        _ = try initializeProject()

        let (result, _) = try service.createTask(at: tempDir, title: "", supervisorTask: "Goal")
        XCTAssertEqual(result.activeTask?.title, "")
    }

    func testCreateTaskWithEmptyCeoGoal() throws {
        _ = try initializeProject()

        let (result, _) = try service.createTask(at: tempDir, title: "Task", supervisorTask: "")
        XCTAssertEqual(result.activeTask?.supervisorTask, "")
    }

    // MARK: - Switch Task Tests

    func testSwitchTaskToExisting() throws {
        _ = try initializeProject()

        let (ctx1, _) = try service.createTask(at: tempDir, title: "Task 1", supervisorTask: "Goal 1")
        let task1ID = ctx1.activeTask!.id

        _ = try service.createTask(at: tempDir, title: "Task 2", supervisorTask: "Goal 2")

        let result = try service.switchTask(at: tempDir, to: task1ID)

        XCTAssertEqual(result.activeTask?.id, task1ID)
        XCTAssertEqual(result.activeTask?.title, "Task 1")
    }

    func testSwitchTaskToNil() throws {
        _ = try initializeProject()
        _ = try service.createTask(at: tempDir, title: "Task 1", supervisorTask: "Goal 1")

        let result = try service.switchTask(at: tempDir, to: nil)

        XCTAssertNil(result.activeTask)
    }

    func testSwitchTaskToNonExistent() throws {
        _ = try initializeProject()
        _ = try service.createTask(at: tempDir, title: "Task 1", supervisorTask: "Goal 1")

        let nonExistentID = 999

        // Should throw taskNotFound error (repository validates existence)
        XCTAssertThrowsError(try service.switchTask(at: tempDir, to: nonExistentID)) { error in
            if case NTMSRepositoryError.taskNotFound(let id) = error {
                XCTAssertEqual(id, nonExistentID)
            } else {
                XCTFail("Expected taskNotFound error, got \(error)")
            }
        }
    }

    // MARK: - Remove Task Tests

    func testRemoveTask() throws {
        _ = try initializeProject()

        let (ctx, _) = try service.createTask(at: tempDir, title: "Task to Remove", supervisorTask: "Goal")
        let taskID = ctx.activeTask!.id

        let result = try service.removeTask(at: tempDir, taskID: taskID)

        XCTAssertTrue(result.tasksIndex.tasks.isEmpty)
        XCTAssertNil(result.activeTask)
    }

    func testRemoveOneOfMultipleTasks() throws {
        _ = try initializeProject()

        let (ctx1, _) = try service.createTask(at: tempDir, title: "Task 1", supervisorTask: "Goal 1")
        let task1ID = ctx1.activeTask!.id

        _ = try service.createTask(at: tempDir, title: "Task 2", supervisorTask: "Goal 2")

        let result = try service.removeTask(at: tempDir, taskID: task1ID)

        XCTAssertEqual(result.tasksIndex.tasks.count, 1)
        XCTAssertEqual(result.tasksIndex.tasks[0].title, "Task 2")
    }

    func testRemoveNonExistentTask() throws {
        _ = try initializeProject()
        _ = try service.createTask(at: tempDir, title: "Task 1", supervisorTask: "Goal 1")

        let nonExistentID = 999

        XCTAssertThrowsError(try service.removeTask(at: tempDir, taskID: nonExistentID)) { error in
            if case NTMSRepositoryError.taskNotFound(let id) = error {
                XCTAssertEqual(id, nonExistentID)
            } else {
                XCTFail("Expected taskNotFound error")
            }
        }
    }

    // MARK: - Task Summaries Filtering Tests

    /// The sidebar's "newest first" order is established ONCE, on the write side, by
    /// `TasksIndex.upsert` — `taskSummaries` only filters. This drives the real path
    /// (create → `updateTaskOnly` → `upsert` → read back from disk) so the chain is pinned
    /// where it actually holds, now that neither `taskSummaries` nor
    /// `TaskManagementState.filteredTasks` re-sorts on every read.
    ///
    /// RED: revert `TasksIndex.upsert` to append-without-slot -> the touched task no
    /// longer leads and the descending check fails.
    func testTaskSummaries_orderIsMaintainedByTheIndex_notReDerivedOnRead() throws {
        _ = try initializeProject()

        var ids: [Int] = []
        for title in ["First", "Second", "Third", "Fourth"] {
            let created = try service.createTask(at: tempDir, title: title, supervisorTask: "Goal")
            ids.append(created.taskID)
        }

        // Touch the OLDEST task through the ordinary persistence path.
        var oldest = try repository.loadTask(at: tempDir, taskID: ids[0])
        oldest.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: tempDir, task: oldest)

        let freshContext = try repository.openOrCreateWorkFolder(at: tempDir)
        let summaries = service.taskSummaries(from: freshContext, filter: .all)

        XCTAssertEqual(summaries.count, 4, "anti-vacuum: all four rows are present")
        XCTAssertEqual(
            summaries.first?.id, ids[0],
            "the just-touched task must lead — that is what `upsert` moved it for")
        XCTAssertEqual(
            summaries.map(\.updatedAt), summaries.map(\.updatedAt).sorted(by: >),
            "the read path does not sort, so this order came from the index itself")
    }

    func testTaskSummariesFilterAll() throws {
        _ = try initializeProject()

        // Create tasks with different statuses by manipulating the task directly
        _ = try service.createTask(at: tempDir, title: "Running Task", supervisorTask: "Goal")
        _ = try service.createTask(at: tempDir, title: "Another Task", supervisorTask: "Goal")

        let freshContext = try repository.openOrCreateWorkFolder(at: tempDir)
        let summaries = service.taskSummaries(from: freshContext, filter: .all)

        XCTAssertEqual(summaries.count, 2)
    }

    func testTaskSummariesFilterRunning() throws {
        _ = try initializeProject()

        _ = try service.createTask(at: tempDir, title: "Task 1", supervisorTask: "Goal")
        _ = try service.createTask(at: tempDir, title: "Task 2", supervisorTask: "Goal")

        let freshContext = try repository.openOrCreateWorkFolder(at: tempDir)
        let summaries = service.taskSummaries(from: freshContext, filter: .running)

        // New tasks default to running status
        XCTAssertEqual(summaries.count, 2)
        for summary in summaries {
            XCTAssertNotEqual(summary.status, .done)
        }
    }

    func testTaskSummariesFilterDone() throws {
        _ = try initializeProject()

        _ = try service.createTask(at: tempDir, title: "Task 1", supervisorTask: "Goal")

        let freshContext = try repository.openOrCreateWorkFolder(at: tempDir)
        let summaries = service.taskSummaries(from: freshContext, filter: .done)

        // No tasks are done yet
        XCTAssertEqual(summaries.count, 0)
    }

    func testTaskSummariesWithNilSnapshot() {
        let summaries = service.taskSummaries(from: nil, filter: .all)
        XCTAssertTrue(summaries.isEmpty)
    }

    func testTaskSummariesSortedByUpdatedAt() throws {
        _ = try initializeProject()

        // Create tasks with small delay to ensure different updatedAt
        _ = try service.createTask(at: tempDir, title: "Old Task", supervisorTask: "Goal")
        Thread.sleep(forTimeInterval: 0.01)
        _ = try service.createTask(at: tempDir, title: "New Task", supervisorTask: "Goal")

        let freshContext = try repository.openOrCreateWorkFolder(at: tempDir)
        let summaries = service.taskSummaries(from: freshContext, filter: .all)

        XCTAssertEqual(summaries.count, 2)
        // Should be sorted by updatedAt descending (newest first)
        XCTAssertEqual(summaries[0].title, "New Task")
        XCTAssertEqual(summaries[1].title, "Old Task")
    }

    // MARK: - Edge Cases

    func testCreateTaskPersistsToFileSystem() throws {
        _ = try initializeProject()

        let (ctx, _) = try service.createTask(at: tempDir, title: "Persistent Task", supervisorTask: "Goal")
        let taskID = ctx.activeTask!.id

        // Verify file exists
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let taskJSONPath = paths.taskJSON(taskID: taskID)
        XCTAssertTrue(fileManager.fileExists(atPath: taskJSONPath.path))

        // Re-open project and verify task is still there
        let freshContext = try repository.openOrCreateWorkFolder(at: tempDir)
        XCTAssertEqual(freshContext.tasksIndex.tasks.count, 1)
        XCTAssertEqual(freshContext.tasksIndex.tasks[0].title, "Persistent Task")
    }

    func testRemoveTaskDeletesFromFileSystem() throws {
        _ = try initializeProject()

        let (ctx, _) = try service.createTask(at: tempDir, title: "Task to Delete", supervisorTask: "Goal")
        let taskID = ctx.activeTask!.id

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let taskJSONPath = paths.taskJSON(taskID: taskID)
        XCTAssertTrue(fileManager.fileExists(atPath: taskJSONPath.path))

        _ = try service.removeTask(at: tempDir, taskID: taskID)

        // File should be deleted
        XCTAssertFalse(fileManager.fileExists(atPath: taskJSONPath.path))
    }
}
