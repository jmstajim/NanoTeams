import XCTest
@testable import NanoTeams

/// User-path: delegated child tasks are stored under their parent's directory tree
/// at `.nanoteams/tasks/{parentID}/subtasks/{childID}/...` (and recursively for
/// deeper chains). Top-level tasks remain at the original flat layout.
@MainActor
final class NestedTaskStorageTests: XCTestCase {

    var workFolderRoot: URL!
    var repository: NTMSRepository!
    var paths: NTMSPaths!

    override func setUp() async throws {
        try await super.setUp()
        workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-nested-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        repository = NTMSRepository()
        paths = NTMSPaths(workFolderRoot: workFolderRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workFolderRoot)
        repository = nil
        paths = nil
        workFolderRoot = nil
        try await super.tearDown()
    }

    // MARK: - Path computation

    func testPaths_topLevel_isFlat() {
        let url = paths.taskDir(taskID: 7)
        XCTAssertEqual(
            url.path,
            paths.tasksDir.appendingPathComponent("7", isDirectory: true).path,
            "Top-level task path is `.nanoteams/tasks/7/`"
        )
    }

    func testPaths_oneLevelChild_nestsUnderParent() {
        let url = paths.taskDir(taskID: 12, ancestors: [7])
        XCTAssertEqual(
            url.path,
            paths.tasksDir.appendingPathComponent("7", isDirectory: true)
                .appendingPathComponent("subtasks", isDirectory: true)
                .appendingPathComponent("12", isDirectory: true).path,
            "Child path is `.nanoteams/tasks/7/subtasks/12/`"
        )
    }

    func testPaths_twoLevelGrandchild_nestsRecursively() {
        let url = paths.taskDir(taskID: 33, ancestors: [7, 12])
        XCTAssertEqual(
            url.path,
            paths.tasksDir.appendingPathComponent("7", isDirectory: true)
                .appendingPathComponent("subtasks", isDirectory: true)
                .appendingPathComponent("12", isDirectory: true)
                .appendingPathComponent("subtasks", isDirectory: true)
                .appendingPathComponent("33", isDirectory: true).path,
            "Grandchild path is `.nanoteams/tasks/7/subtasks/12/subtasks/33/`"
        )
    }

    func testPaths_runDir_nestsUnderTaskPath() {
        let url = paths.runDir(taskID: 12, runID: 0, ancestors: [7])
        XCTAssertTrue(url.path.contains("/tasks/7/subtasks/12/runs/0"),
                      "Run directories live under nested task paths: \(url.path)")
    }

    func testPaths_internalTaskDir_nestsUnderInternalTree() {
        let url = paths.internalTaskDir(taskID: 12, ancestors: [7])
        XCTAssertEqual(
            url.path,
            paths.internalTasksDir.appendingPathComponent("7", isDirectory: true)
                .appendingPathComponent("subtasks", isDirectory: true)
                .appendingPathComponent("12", isDirectory: true).path,
            "Internal nesting mirrors public nesting under .nanoteams/internal/tasks/"
        )
    }

    // MARK: - TasksIndex.ancestorIDs

    func testAncestorIDs_topLevel_isEmpty() {
        var index = TasksIndex()
        index.tasks = [TaskSummary(id: 1, title: "Top", status: .running)]
        XCTAssertEqual(index.ancestorIDs(of: 1), [])
    }

    func testAncestorIDs_oneLevelChild_returnsParent() {
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 1, title: "Parent", status: .running, parentTaskID: nil),
            TaskSummary(id: 2, title: "Child", status: .running, parentTaskID: 1),
        ]
        XCTAssertEqual(index.ancestorIDs(of: 2), [1])
    }

    func testAncestorIDs_grandchild_returnsRootFirst() {
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 1, title: "Root", status: .running, parentTaskID: nil),
            TaskSummary(id: 2, title: "Mid", status: .running, parentTaskID: 1),
            TaskSummary(id: 3, title: "Leaf", status: .running, parentTaskID: 2),
        ]
        XCTAssertEqual(index.ancestorIDs(of: 3), [1, 2],
                       "Ancestor chain is root-first, excluding self.")
    }

    func testAncestorIDs_unknownTask_returnsEmpty() {
        let index = TasksIndex()
        XCTAssertEqual(index.ancestorIDs(of: 999), [],
                       "Unknown task ID treated as top-level.")
    }

    func testAncestorIDs_safetyCap_breaksCycles() {
        // Defensive: a malformed index with a cycle should not infinite-loop.
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 1, title: "A", status: .running, parentTaskID: 2),
            TaskSummary(id: 2, title: "B", status: .running, parentTaskID: 1),
        ]
        // The 32-step safety cap prevents infinite recursion; we just check it terminates.
        let chain = index.ancestorIDs(of: 1)
        XCTAssertLessThanOrEqual(chain.count, 32, "Safety cap kicks in on cycles.")
    }

    // MARK: - Repository round-trip

    func testRepository_topLevelCreate_writesAtFlatPath() throws {
        let (_, topTaskID) = try repository.createTask(
            at: workFolderRoot,
            title: "Top Task",
            supervisorTask: "Brief",
            preferredTeamID: nil,
            parentTaskID: nil,
            parentRoleID: nil,
            delegationDepth: 0
        )
        let expectedPath = paths.taskJSON(taskID: topTaskID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath.path),
                      "Top-level task.json must be at the flat path: \(expectedPath.path)")
    }

    func testRepository_childCreate_writesNestedPath_andDoesNotChangeActiveTask() throws {
        // 1. Top-level parent.
        let (parentSnapshot, parentID) = try repository.createTask(
            at: workFolderRoot,
            title: "Parent",
            supervisorTask: "Build it",
            preferredTeamID: nil,
            parentTaskID: nil,
            parentRoleID: nil,
            delegationDepth: 0
        )
        XCTAssertEqual(parentSnapshot.activeTaskID, parentID,
                       "Top-level task creation makes the new task active.")

        // 2. Delegated child — parentage supplied at creation; activeTaskID should remain parent's.
        let (childSnapshot, childID) = try repository.createTask(
            at: workFolderRoot,
            title: "Delegated",
            supervisorTask: "Sub-brief",
            preferredTeamID: nil,
            parentTaskID: parentID,
            parentRoleID: "pm",
            delegationDepth: 1
        )
        XCTAssertEqual(childSnapshot.activeTaskID, parentID,
                       "Creating a child task must NOT change activeTaskID — supervisor stays focused on parent.")

        // 3. Child's task.json must live at nested path.
        let childPath = paths.taskJSON(taskID: childID, ancestors: [parentID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: childPath.path),
                      "Child task.json must be at nested path: \(childPath.path)")

        // 4. The flat path for the child does NOT exist (we never wrote it there).
        let flatChildPath = paths.taskJSON(taskID: childID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flatChildPath.path),
                       "Child must NOT have a stale flat task.json at \(flatChildPath.path)")

        // 5. Reading the child back via repository preserves parentage.
        let reloaded = try repository.loadTask(at: workFolderRoot, taskID: childID)
        XCTAssertEqual(reloaded.parentTaskID, parentID)
        XCTAssertEqual(reloaded.parentRoleID, "pm")
        XCTAssertEqual(reloaded.delegationDepth, 1)
    }

    func testRepository_deleteParent_recursivelyClearsNestedSubtree() throws {
        // Parent + child setup
        let (_, parentID) = try repository.createTask(
            at: workFolderRoot,
            title: "Parent",
            supervisorTask: "Brief",
            preferredTeamID: nil,
            parentTaskID: nil,
            parentRoleID: nil,
            delegationDepth: 0
        )
        let (_, childID) = try repository.createTask(
            at: workFolderRoot,
            title: "Child",
            supervisorTask: "Sub-brief",
            preferredTeamID: nil,
            parentTaskID: parentID,
            parentRoleID: "pm",
            delegationDepth: 1
        )
        let childPath = paths.taskJSON(taskID: childID, ancestors: [parentID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: childPath.path),
                      "Sanity: child file exists before parent deletion.")

        // Delete parent → entire subtree disappears (rm -rf of parent dir cascades to children).
        _ = try repository.deleteTask(at: workFolderRoot, taskID: parentID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: childPath.path),
                       "Deleting the parent removes the nested child files via tree deletion.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.taskDir(taskID: parentID).path),
                       "Parent's task dir is gone.")
    }
}
