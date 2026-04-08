import XCTest
@testable import NanoTeams

/// Tests for NTMSRepository persistence layer.
final class NTMSRepositoryTests: XCTestCase {

    var sut: NTMSRepository!
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sut = NTMSRepository()
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        sut = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Creates a project root directory and returns its URL.
    private func makeProjectRoot() throws -> URL {
        let root = tempDir.appendingPathComponent("project_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Returns NTMSPaths for a given project root.
    private func paths(for root: URL) -> NTMSPaths {
        NTMSPaths(workFolderRoot: root)
    }

    // MARK: - 1. openOrCreateWorkFolder_createsNanoteamsDirectory

    func testOpenOrCreateProject_createsNanoteamsDirectory() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let p = paths(for: root)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: p.nanoteamsDir.path, isDirectory: &isDir)
        XCTAssertTrue(exists, ".nanoteams directory should exist")
        XCTAssertTrue(isDir.boolValue, ".nanoteams should be a directory")
    }

    // MARK: - 2. openOrCreateWorkFolder_createsProjectJSON

    func testOpenOrCreateProject_createsProjectJSON() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let p = paths(for: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.workFolderJSON.path),
                       "project.json should exist after openOrCreateWorkFolder")
    }

    // MARK: - 3. openOrCreateWorkFolder_createsTasksIndexJSON

    func testOpenOrCreateProject_createsTasksIndexJSON() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let p = paths(for: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.tasksIndexJSON.path),
                       "tasks_index.json should exist after openOrCreateWorkFolder")
    }

    // MARK: - 4. openOrCreateWorkFolder_createsToolsJSON

    func testOpenOrCreateProject_createsToolsJSON() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let p = paths(for: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.toolsJSON.path),
                       "tools.json should exist after openOrCreateWorkFolder")
    }

    // MARK: - 5. openOrCreateWorkFolder_returnsProjectWithDefaultTeams

    func testOpenOrCreateProject_returnsProjectWithDefaultTeams() throws {
        let root = try makeProjectRoot()
        let context = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertFalse(context.workFolder.teams.isEmpty,
                        "Work folder should have default bootstrap teams")
        // Default defaultTeams should include at least one team
        XCTAssertGreaterThanOrEqual(context.workFolder.teams.count, 1,
                                     "Work folder should have at least one default team")
    }

    // MARK: - 6. openOrCreateWorkFolder_idempotent

    func testOpenOrCreateProject_idempotent() throws {
        let root = try makeProjectRoot()

        let first = try sut.openOrCreateWorkFolder(at: root)
        let second = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertEqual(first.workFolder.id, second.workFolder.id,
                        "Calling openOrCreateWorkFolder twice should return the same project")
        XCTAssertEqual(first.workFolder.name, second.workFolder.name)
        XCTAssertEqual(first.tasksIndex.tasks.count, second.tasksIndex.tasks.count)
    }

    // MARK: - 7. openOrCreateWorkFolder_invalidFolder_throws

    func testOpenOrCreateProject_invalidFolder_throws() throws {
        let nonExistent = tempDir.appendingPathComponent("no_such_folder", isDirectory: true)

        XCTAssertThrowsError(try sut.openOrCreateWorkFolder(at: nonExistent)) { error in
            guard let repoError = error as? NTMSRepositoryError else {
                XCTFail("Expected NTMSRepositoryError, got \(type(of: error))")
                return
            }
            if case .invalidProjectFolder(let url) = repoError {
                XCTAssertEqual(url, nonExistent)
            } else {
                XCTFail("Expected invalidProjectFolder, got \(repoError)")
            }
        }
    }

    // MARK: - 8. createTask_createsTaskFile

    func testCreateTask_createsTaskFile() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let context = try sut.createTask(at: root, title: "My Task", supervisorTask: "Build it")
        let taskID = context.activeTask!.id

        let p = paths(for: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.taskJSON(taskID: taskID).path),
                       "task.json should be created for the new task")
    }

    // MARK: - 9. createTask_updatesTasksIndex

    func testCreateTask_updatesTasksIndex() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let context = try sut.createTask(at: root, title: "Indexed Task", supervisorTask: "Goal")

        XCTAssertEqual(context.tasksIndex.tasks.count, 1,
                        "Tasks index should contain the new task")
        XCTAssertEqual(context.tasksIndex.tasks.first?.title, "Indexed Task")
    }

    // MARK: - 10. createTask_setsActiveTask

    func testCreateTask_setsActiveTask() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let context = try sut.createTask(at: root, title: "Active Task", supervisorTask: "Goal")

        XCTAssertNotNil(context.activeTaskID, "activeTaskID should be set after createTask")
        XCTAssertNotNil(context.activeTask, "activeTask should be set after createTask")
        XCTAssertEqual(context.activeTask?.title, "Active Task")
        XCTAssertEqual(context.activeTaskID, context.activeTask?.id)
    }

    // MARK: - 11. createTask_returnsContextWithTask

    func testCreateTask_returnsContextWithTask() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let context = try sut.createTask(at: root, title: "Context Task", supervisorTask: "The goal")

        XCTAssertNotNil(context.activeTask)
        XCTAssertEqual(context.activeTask?.title, "Context Task")
        XCTAssertEqual(context.activeTask?.supervisorTask, "The goal")
        XCTAssertFalse(context.toolDefinitions.isEmpty, "Context should include tool definitions")
        XCTAssertFalse(context.workFolder.teams.isEmpty, "Context should include teams")
    }

    // MARK: - 12. setActiveTask_updatesActiveID

    func testSetActiveTask_updatesActiveID() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let ctx1 = try sut.createTask(at: root, title: "Task A", supervisorTask: "A")
        let ctx2 = try sut.createTask(at: root, title: "Task B", supervisorTask: "B")
        let taskA = ctx1.activeTask!
        let taskB = ctx2.activeTask!

        // Active should be task B now
        XCTAssertEqual(ctx2.activeTaskID, taskB.id)

        // Switch to task A
        let switched = try sut.setActiveTask(at: root, taskID: taskA.id)
        XCTAssertEqual(switched.activeTaskID, taskA.id)
        XCTAssertEqual(switched.activeTask?.title, "Task A")
    }

    // MARK: - 13. setActiveTask_nilID_clearsActive

    func testSetActiveTask_nilID_clearsActive() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)
        _ = try sut.createTask(at: root, title: "Some Task", supervisorTask: "Goal")

        let context = try sut.setActiveTask(at: root, taskID: nil)

        XCTAssertNil(context.activeTaskID, "activeTaskID should be nil after clearing")
        XCTAssertNil(context.activeTask, "activeTask should be nil after clearing")
    }

    // MARK: - 14. setActiveTask_nonExistentTask_throws

    func testSetActiveTask_nonExistentTask_throws() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let fakeID = 999
        XCTAssertThrowsError(try sut.setActiveTask(at: root, taskID: fakeID)) { error in
            guard let repoError = error as? NTMSRepositoryError else {
                XCTFail("Expected NTMSRepositoryError, got \(type(of: error))")
                return
            }
            if case .taskNotFound(let id) = repoError {
                XCTAssertEqual(id, fakeID)
            } else {
                XCTFail("Expected taskNotFound, got \(repoError)")
            }
        }
    }

    // MARK: - 15. deleteTask_removesTaskFile

    func testDeleteTask_removesTaskFile() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let created = try sut.createTask(at: root, title: "Doomed Task", supervisorTask: "Goal")
        let taskID = created.activeTask!.id

        let p = paths(for: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.taskDir(taskID: taskID).path),
                       "Task directory should exist before deletion")

        _ = try sut.deleteTask(at: root, taskID: taskID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: p.taskDir(taskID: taskID).path),
                        "Task directory should be removed after deletion")
    }

    // MARK: - 16. deleteTask_removesFromIndex

    func testDeleteTask_removesFromIndex() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let created = try sut.createTask(at: root, title: "Indexed Doom", supervisorTask: "Goal")
        let taskID = created.activeTask!.id
        XCTAssertTrue(created.tasksIndex.tasks.contains(where: { $0.id == taskID }))

        let afterDelete = try sut.deleteTask(at: root, taskID: taskID)

        XCTAssertFalse(afterDelete.tasksIndex.tasks.contains(where: { $0.id == taskID }),
                        "Task should be removed from index after deletion")
    }

    // MARK: - 17. deleteTask_activeTask_picksFallback

    func testDeleteTask_activeTask_picksFallback() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let ctx1 = try sut.createTask(at: root, title: "Task A", supervisorTask: "A")
        let taskA = ctx1.activeTask!

        let ctx2 = try sut.createTask(at: root, title: "Task B", supervisorTask: "B")
        let taskB = ctx2.activeTask!

        // Delete the active task (Task B)
        let afterDelete = try sut.deleteTask(at: root, taskID: taskB.id)

        // Should have picked a fallback active task (Task A)
        XCTAssertNotNil(afterDelete.activeTaskID,
                         "Should pick a fallback active task when the active one is deleted")
        XCTAssertEqual(afterDelete.activeTaskID, taskA.id,
                        "Fallback should be the remaining task")
    }

    // MARK: - 18. deleteTask_nonExistentTask_throws

    func testDeleteTask_nonExistentTask_throws() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let fakeID = 999
        XCTAssertThrowsError(try sut.deleteTask(at: root, taskID: fakeID)) { error in
            guard let repoError = error as? NTMSRepositoryError else {
                XCTFail("Expected NTMSRepositoryError, got \(type(of: error))")
                return
            }
            if case .taskNotFound(let id) = repoError {
                XCTAssertEqual(id, fakeID)
            } else {
                XCTFail("Expected taskNotFound, got \(repoError)")
            }
        }
    }

    // MARK: - 19. updateTaskOnly_persistsTask

    func testUpdateTaskOnly_persistsTask() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let created = try sut.createTask(at: root, title: "Original Title", supervisorTask: "Goal")
        var task = created.activeTask!

        task.title = "Updated Title"
        task.supervisorTask = "Updated Goal"
        try sut.updateTaskOnly(at: root, task: task)

        // Verify by loading from disk
        let loaded = try sut.loadTask(at: root, taskID: task.id)
        XCTAssertEqual(loaded.title, "Updated Title")
        XCTAssertEqual(loaded.supervisorTask, "Updated Goal")
    }

    // MARK: - 20. updateTaskOnly_updatesIndex

    func testUpdateTaskOnly_updatesIndex() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let created = try sut.createTask(at: root, title: "Before Update", supervisorTask: "Goal")
        var task = created.activeTask!

        task.title = "After Update"
        try sut.updateTaskOnly(at: root, task: task)

        // Re-read the context to check the index
        let reloaded = try sut.openOrCreateWorkFolder(at: root)
        let summary = reloaded.tasksIndex.tasks.first(where: { $0.id == task.id })
        XCTAssertNotNil(summary, "Task should still be in index after updateTaskOnly")
        XCTAssertEqual(summary?.title, "After Update",
                        "Index should reflect the updated title")
    }

    // MARK: - 21. updateTaskOnly_nonExistentTask_throws

    func testUpdateTaskOnly_nonExistentTask_throws() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let fakeTask = NTMSTask(id: 0, title: "Ghost", supervisorTask: "Does not exist on disk")

        XCTAssertThrowsError(try sut.updateTaskOnly(at: root, task: fakeTask)) { error in
            guard let repoError = error as? NTMSRepositoryError else {
                XCTFail("Expected NTMSRepositoryError, got \(type(of: error))")
                return
            }
            if case .taskNotFound(let id) = repoError {
                XCTAssertEqual(id, fakeTask.id)
            } else {
                XCTFail("Expected taskNotFound, got \(repoError)")
            }
        }
    }

    // MARK: - 22. loadTask_returnsTask

    func testLoadTask_returnsTask() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let created = try sut.createTask(at: root, title: "Loadable Task", supervisorTask: "Load me")
        let taskID = created.activeTask!.id

        let loaded = try sut.loadTask(at: root, taskID: taskID)
        XCTAssertEqual(loaded.id, taskID)
        XCTAssertEqual(loaded.title, "Loadable Task")
        XCTAssertEqual(loaded.supervisorTask, "Load me")
    }

    // MARK: - 23. loadTask_nonExistent_throws

    func testLoadTask_nonExistent_throws() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let fakeID = 999
        XCTAssertThrowsError(try sut.loadTask(at: root, taskID: fakeID)) { error in
            guard let repoError = error as? NTMSRepositoryError else {
                XCTFail("Expected NTMSRepositoryError, got \(type(of: error))")
                return
            }
            if case .taskNotFound(let id) = repoError {
                XCTAssertEqual(id, fakeID)
            } else {
                XCTFail("Expected taskNotFound, got \(repoError)")
            }
        }
    }

    // MARK: - 24. persistStepArtifactFile_writesFile

    func testPersistStepArtifactFile_writesFile() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let runID = 0
        let roleID = "test_role"
        let content = "# Product Requirements\n\nThis is the artifact content."

        _ = try sut.persistStepArtifactFile(
            at: root,
            taskID: 0,
            runID: runID,
            roleID: roleID,
            artifactName: "Product Requirements",
            content: content
        )

        // Verify file was written
        let p = paths(for: root)
        let stepDir = p.roleDir(taskID: 0, runID: runID, roleID: roleID)
        let slug = Artifact.slugify("Product Requirements")
        let fileURL = stepDir.appendingPathComponent("artifact_\(slug).md", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                       "Artifact file should be written to disk")

        let readBack = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(readBack.contains("Product Requirements"),
                       "Written file should contain the artifact content")
    }

    // MARK: - 25. persistStepArtifactFile_returnsRelativePath

    func testPersistStepArtifactFile_returnsRelativePath() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let runID = 0
        let roleID = "test_role"

        let relativePath = try sut.persistStepArtifactFile(
            at: root,
            taskID: 0,
            runID: runID,
            roleID: roleID,
            artifactName: "Design Spec",
            content: "Some design content"
        )

        // Should be relative to .nanoteams/, starting with "tasks/..."
        XCTAssertTrue(relativePath.hasPrefix("tasks/"),
                       "Relative path should start with 'tasks/', got: \(relativePath)")
        XCTAssertTrue(relativePath.contains(String(runID)),
                       "Relative path should contain the run ID")
        XCTAssertTrue(relativePath.contains("roles/\(roleID)"),
                       "Relative path should contain the role ID")
        let slug = Artifact.slugify("Design Spec")
        XCTAssertTrue(relativePath.hasSuffix("artifact_\(slug).md"),
                       "Relative path should end with the artifact filename")
    }

    // MARK: - 26. persistStepArtifactFile_stripsControlTokens

    func testPersistStepArtifactFile_stripsControlTokens() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let runID = 0
        let roleID = "test_role"
        let contentWithTokens = """
        <|channel|> assistant
        # Engineering Notes
        <|start|>functions.write_file
        Here is the actual content.
        <|end|>
        <|call|>
        <|message|>
        <|constrain|> json
        """

        _ = try sut.persistStepArtifactFile(
            at: root,
            taskID: 0,
            runID: runID,
            roleID: roleID,
            artifactName: "Engineering Notes",
            content: contentWithTokens
        )

        // Read back and verify tokens are stripped
        let p = paths(for: root)
        let stepDir = p.roleDir(taskID: 0, runID: runID, roleID: roleID)
        let slug = Artifact.slugify("Engineering Notes")
        let fileURL = stepDir.appendingPathComponent("artifact_\(slug).md", isDirectory: false)
        let readBack = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertFalse(readBack.contains("<|channel|>"), "Control token <|channel|> should be stripped")
        XCTAssertFalse(readBack.contains("<|start|>"), "Control token <|start|> should be stripped")
        XCTAssertFalse(readBack.contains("<|end|>"), "Control token <|end|> should be stripped")
        XCTAssertFalse(readBack.contains("<|call|>"), "Control token <|call|> should be stripped")
        XCTAssertFalse(readBack.contains("<|message|>"), "Control token <|message|> should be stripped")
        XCTAssertFalse(readBack.contains("<|constrain|>"), "Control token <|constrain|> should be stripped")
        XCTAssertTrue(readBack.contains("Here is the actual content."),
                       "Non-control content should be preserved")
    }

    // MARK: - persistStepArtifactBinary

    func testPersistStepArtifactBinary_writesFileWithCorrectExtension() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let data = Data("PDF binary content".utf8)
        let relativePath = try sut.persistStepArtifactBinary(
            at: root, taskID: 0, runID: 0, roleID: "test_role",
            artifactName: "Final Report", data: data, fileExtension: "pdf"
        )

        // Verify file exists with .pdf extension
        let p = paths(for: root)
        let slug = Artifact.slugify("Final Report")
        let fileURL = p.roleDir(taskID: 0, runID: 0, roleID: "test_role")
            .appendingPathComponent("artifact_\(slug).pdf", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let readBack = try Data(contentsOf: fileURL)
        XCTAssertEqual(readBack, data)
        XCTAssertTrue(relativePath.contains("artifact_\(slug).pdf"))
    }

    func testPersistStepArtifactBinary_rtfExtension() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let data = Data("{\\rtf1 Hello}".utf8)
        let relativePath = try sut.persistStepArtifactBinary(
            at: root, taskID: 0, runID: 0, roleID: "test_role",
            artifactName: "Notes", data: data, fileExtension: "rtf"
        )

        XCTAssertTrue(relativePath.hasSuffix("artifact_notes.rtf"))
    }

    // MARK: - 27. updateWorkFolderDescription_updatesDescription

    func testUpdateProjectDescription_updatesDescription() throws {
        let root = try makeProjectRoot()
        let initial = try sut.openOrCreateWorkFolder(at: root)
        XCTAssertEqual(initial.workFolder.settings.description, "", "Initial description should be empty")

        let updated = try sut.updateWorkFolderDescription(at: root, description: "A cool project")
        XCTAssertEqual(updated.workFolder.settings.description, "A cool project",
                        "Description should be updated")

        // Verify persistence by re-reading
        let reloaded = try sut.openOrCreateWorkFolder(at: root)
        XCTAssertEqual(reloaded.workFolder.settings.description, "A cool project",
                        "Description should persist across reloads")
    }

    // MARK: - 28. resetWorkFolderSettings_recreatesDefaults

    func testResetProjectSettings_recreatesDefaults() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Modify the project description so we can detect a reset
        _ = try sut.updateWorkFolderDescription(at: root, description: "Custom description")

        // Create a task so there is data to reset
        _ = try sut.createTask(at: root, title: "Will be lost", supervisorTask: "Goal")

        // Reset
        let resetContext = try sut.resetWorkFolderSettings(at: root)

        // The project should be fresh with defaults
        XCTAssertEqual(resetContext.workFolder.settings.description, "",
                        "Description should be reset to default empty string")
        XCTAssertTrue(resetContext.tasksIndex.tasks.isEmpty,
                       "Tasks index should be empty after reset")
        XCTAssertNil(resetContext.activeTaskID,
                      "Active task should be nil after reset")
        XCTAssertNil(resetContext.activeTask,
                      "Active task should be nil after reset")
        XCTAssertFalse(resetContext.workFolder.teams.isEmpty,
                        "Default teams should be bootstrapped after reset")

        // Verify .nanoteams directory still exists (recreated)
        let p = paths(for: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.nanoteamsDir.path),
                       ".nanoteams directory should be recreated after reset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.workFolderJSON.path),
                       "project.json should be recreated after reset")
    }

    // MARK: - Additional Edge Case Tests

    func testCreateMultipleTasks_allInIndex() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        _ = try sut.createTask(at: root, title: "Task 1", supervisorTask: "G1")
        _ = try sut.createTask(at: root, title: "Task 2", supervisorTask: "G2")
        let ctx3 = try sut.createTask(at: root, title: "Task 3", supervisorTask: "G3")

        XCTAssertEqual(ctx3.tasksIndex.tasks.count, 3,
                        "All three tasks should be in the index")
    }

    func testDeleteTask_lastTask_clearsActiveToNil() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let created = try sut.createTask(at: root, title: "Only Task", supervisorTask: "Goal")
        let taskID = created.activeTask!.id

        let afterDelete = try sut.deleteTask(at: root, taskID: taskID)

        XCTAssertTrue(afterDelete.tasksIndex.tasks.isEmpty,
                       "Index should be empty after deleting the last task")
        XCTAssertNil(afterDelete.activeTaskID,
                      "Active task ID should be nil when no tasks remain")
    }

    func testUpdateTask_persistsAndReloads() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let created = try sut.createTask(at: root, title: "Mutable Task", supervisorTask: "Goal")
        var task = created.activeTask!

        task.title = "Mutated Task"
        let updated = try sut.updateTask(at: root, task: task)

        XCTAssertEqual(updated.activeTask?.title, "Mutated Task",
                        "updateTask should return context with the updated task")

        // Verify persistence
        let loaded = try sut.loadTask(at: root, taskID: task.id)
        XCTAssertEqual(loaded.title, "Mutated Task")
    }

    func testUpdateProject_persistsTeamChanges() throws {
        let root = try makeProjectRoot()
        let initial = try sut.openOrCreateWorkFolder(at: root)

        var settings = initial.workFolder.settings
        settings.description = "Modified via updateProject"

        let updated = try sut.updateSettings(at: root) { $0 = settings }

        XCTAssertEqual(updated.workFolder.settings.description, "Modified via updateProject")

        // Verify persistence
        let reloaded = try sut.openOrCreateWorkFolder(at: root)
        XCTAssertEqual(reloaded.workFolder.settings.description, "Modified via updateProject")
    }

    func testOpenOrCreateProject_setsProjectNameToFolderName() throws {
        let root = try makeProjectRoot()
        let context = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertEqual(context.workFolder.name, root.lastPathComponent,
                        "Work folder name should default to the folder name")
    }

    func testOpenOrCreateProject_returnsToolDefinitions() throws {
        let root = try makeProjectRoot()
        let context = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertFalse(context.toolDefinitions.isEmpty,
                        "Tool definitions should be populated with defaults")
    }

    func testOpenOrCreateProject_noActiveTaskInitially() throws {
        let root = try makeProjectRoot()
        let context = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertNil(context.activeTaskID,
                      "No active task should exist for a fresh project")
        XCTAssertNil(context.activeTask)
    }

    func testDeleteTask_nonActiveTask_doesNotChangeActive() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let ctx1 = try sut.createTask(at: root, title: "Task A", supervisorTask: "A")
        let taskA = ctx1.activeTask!

        let ctx2 = try sut.createTask(at: root, title: "Task B", supervisorTask: "B")
        let taskB = ctx2.activeTask!

        // Active is Task B, delete Task A (non-active)
        let afterDelete = try sut.deleteTask(at: root, taskID: taskA.id)

        XCTAssertEqual(afterDelete.activeTaskID, taskB.id,
                        "Deleting a non-active task should not change the active task")
    }

    func testPersistStepArtifactFile_createsStepDirectory() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let runID = 0
        let roleID = "test_role"

        _ = try sut.persistStepArtifactFile(
            at: root,
            taskID: 0,
            runID: runID,
            roleID: roleID,
            artifactName: "Test Artifact",
            content: "Content"
        )

        let p = paths(for: root)
        let stepDir = p.roleDir(taskID: 0, runID: runID, roleID: roleID)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: stepDir.path, isDirectory: &isDir)
        XCTAssertTrue(exists, "Step directory should be created")
        XCTAssertTrue(isDir.boolValue, "Step path should be a directory")
    }

    func testUpdateTaskOnly_doesNotChangeActiveTask() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let ctx1 = try sut.createTask(at: root, title: "Task A", supervisorTask: "A")
        let taskA = ctx1.activeTask!

        let ctx2 = try sut.createTask(at: root, title: "Task B", supervisorTask: "B")
        // Active is now Task B

        // Update Task A via hot path — should not affect active task
        var mutatedA = taskA
        mutatedA.title = "Task A Updated"
        try sut.updateTaskOnly(at: root, task: mutatedA)

        // Re-read context — active should still be Task B
        let reloaded = try sut.openOrCreateWorkFolder(at: root)
        XCTAssertEqual(reloaded.activeTaskID, ctx2.activeTask!.id)
    }

    // MARK: - openOrCreateWorkFolder merges missing bootstrap teams

    func testOpenOrCreateProject_addsMissingBootstrapTeams() throws {
        let root = try makeProjectRoot()
        let initial = try sut.openOrCreateWorkFolder(at: root)

        // Remove one bootstrap team (simulate project saved before Engineering team existed)
        var wf = initial.workFolder
        let engineeringIndex = wf.teams.firstIndex { $0.templateID == "engineering" }
        XCTAssertNotNil(engineeringIndex, "Engineering team should exist in bootstrap defaults")
        wf.teams.remove(at: engineeringIndex!)
        XCTAssertEqual(wf.teams.count, Team.defaultTeams.count - 1)

        _ = try sut.updateTeams(at: root) { $0 = wf.teams }

        // Re-open — missing team should be merged back
        let reopened = try sut.openOrCreateWorkFolder(at: root)
        XCTAssertEqual(reopened.workFolder.teams.count, Team.defaultTeams.count)
        XCTAssertTrue(reopened.workFolder.teams.contains { $0.templateID == "engineering" },
                       "Engineering team should be merged on open")
    }

    // MARK: - System Role Dependency Sync

    func testOpenOrCreateProject_syncsAddedRequiredArtifact_whenProducerExists() throws {
        let root = try makeProjectRoot()
        let initial = try sut.openOrCreateWorkFolder(at: root)

        // Find Quest Party and its EncounterArchitect — remove "NPC Compendium" from required
        var wf = initial.workFolder
        guard let teamIdx = wf.teams.firstIndex(where: { $0.templateID == "questParty" }) else {
            XCTFail("Quest Party team should exist")
            return
        }
        guard let roleIdx = wf.teams[teamIdx].roles.firstIndex(where: {
            $0.systemRoleID == "encounterArchitect"
        }) else {
            XCTFail("EncounterArchitect should exist")
            return
        }

        wf.teams[teamIdx].roles[roleIdx].dependencies.requiredArtifacts = ["World Compendium"]
        _ = try sut.updateTeams(at: root) { $0 = wf.teams }

        // Re-open — sync should add "NPC Compendium" back (producer exists in team)
        let reopened = try sut.openOrCreateWorkFolder(at: root)
        let team = reopened.workFolder.teams.first { $0.templateID == "questParty" }!
        let role = team.roles.first { $0.systemRoleID == "encounterArchitect" }!
        XCTAssertTrue(role.dependencies.requiredArtifacts.contains("World Compendium"))
        XCTAssertTrue(role.dependencies.requiredArtifacts.contains("NPC Compendium"),
                       "NPC Compendium should be synced from template because producer exists in team")
    }

    func testOpenOrCreateProject_doesNotAddRequiredArtifact_whenProducerMissing() throws {
        let root = try makeProjectRoot()
        let initial = try sut.openOrCreateWorkFolder(at: root)

        // Engineering team TL: template has ["Supervisor Task", "Product Requirements"]
        // but PM is absent in Engineering team — "Product Requirements" has no producer
        let reopened = try sut.openOrCreateWorkFolder(at: root)
        guard let team = reopened.workFolder.teams.first(where: { $0.templateID == "engineering" }) else {
            XCTFail("Engineering team should exist")
            return
        }
        let tl = team.roles.first { $0.systemRoleID == "techLead" }!
        XCTAssertFalse(tl.dependencies.requiredArtifacts.contains("Product Requirements"),
                        "Product Requirements should NOT be added — PM is absent from Engineering team")
    }

    func testOpenOrCreateProject_syncsProducesArtifacts() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Tamper: remove an artifact from a role's producesArtifacts
        var teamsFile = try AtomicJSONStore().read(TeamsFile.self, from: paths(for: root).teamsJSON)
        guard let teamIdx = teamsFile.teams.firstIndex(where: { $0.templateID == "questParty" }),
              let roleIdx = teamsFile.teams[teamIdx].roles.firstIndex(where: {
                  $0.systemRoleID == "loreMaster"
              }) else {
            XCTFail("Quest Party LoreMaster should exist")
            return
        }
        teamsFile.teams[teamIdx].roles[roleIdx].dependencies.producesArtifacts = []
        try AtomicJSONStore().write(teamsFile, to: paths(for: root).teamsJSON)

        // Re-open — producesArtifacts should be restored
        let reopened = try sut.openOrCreateWorkFolder(at: root)
        let lm = reopened.workFolder.teams.first { $0.templateID == "questParty" }!
            .roles.first { $0.systemRoleID == "loreMaster" }!
        XCTAssertEqual(lm.dependencies.producesArtifacts, ["World Compendium"])
    }

    func testOpenOrCreateProject_skipsSupervisorDependencySync() throws {
        let root = try makeProjectRoot()
        let initial = try sut.openOrCreateWorkFolder(at: root)

        // FAANG Supervisor requires ["Release Notes"] (per-team, not from generic template)
        let reopened = try sut.openOrCreateWorkFolder(at: root)
        let faang = reopened.workFolder.teams.first { $0.templateID == "faang" }!
        let supervisor = faang.roles.first { $0.systemRoleID == "supervisor" }!
        XCTAssertEqual(supervisor.dependencies.requiredArtifacts, ["Release Notes"],
                        "Supervisor requiredArtifacts should NOT be overwritten by generic template")
    }

    func testOpenOrCreateProject_dependencySyncIsIdempotent() throws {
        let root = try makeProjectRoot()
        let first = try sut.openOrCreateWorkFolder(at: root)

        // Capture timestamps
        let questParty1 = first.workFolder.teams.first { $0.templateID == "questParty" }!
        let ea1 = questParty1.roles.first { $0.systemRoleID == "encounterArchitect" }!

        // Re-open (no changes needed)
        let second = try sut.openOrCreateWorkFolder(at: root)
        let questParty2 = second.workFolder.teams.first { $0.templateID == "questParty" }!
        let ea2 = questParty2.roles.first { $0.systemRoleID == "encounterArchitect" }!

        XCTAssertEqual(ea1.updatedAt, ea2.updatedAt,
                        "No unnecessary timestamp update when dependencies already match")
    }

    func testOpenOrCreateProject_skipsCustomRoles() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Add a custom role to Quest Party with arbitrary dependencies
        var teamsFile = try AtomicJSONStore().read(TeamsFile.self, from: paths(for: root).teamsJSON)
        guard let teamIdx = teamsFile.teams.firstIndex(where: { $0.templateID == "questParty" }) else {
            XCTFail("Quest Party should exist")
            return
        }
        let customRole = TeamRoleDefinition(
            id: UUID().uuidString,
            name: "Custom Role",
            prompt: "test",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Fake Artifact"], producesArtifacts: ["Custom Output"]),
            isSystemRole: false,
            systemRoleID: nil
        )
        teamsFile.teams[teamIdx].roles.append(customRole)
        try AtomicJSONStore().write(teamsFile, to: paths(for: root).teamsJSON)

        // Re-open — custom role should not be modified
        let reopened = try sut.openOrCreateWorkFolder(at: root)
        let team = reopened.workFolder.teams.first { $0.templateID == "questParty" }!
        let custom = team.roles.first { $0.name == "Custom Role" }!
        XCTAssertEqual(custom.dependencies.requiredArtifacts, ["Fake Artifact"])
        XCTAssertEqual(custom.dependencies.producesArtifacts, ["Custom Output"])
    }

    // MARK: - Attachment Staging

    func testStageAttachment_copiesIntoDraftDirAndReturnsProjectRelativePath() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let sourceURL = tempDir.appendingPathComponent("capture-notes.txt", isDirectory: false)
        try "captured".write(to: sourceURL, atomically: true, encoding: .utf8)

        let draftID = UUID()
        let relativePath = try sut.stageAttachment(
            at: root,
            draftID: draftID,
            sourceURL: sourceURL
        )

        XCTAssertEqual(relativePath, ".nanoteams/internal/staged/\(draftID.uuidString)/capture-notes.txt")

        let stagedURL = root.appendingPathComponent(relativePath, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try String(contentsOf: stagedURL), "captured")
    }

    func testFinalizeAttachments_copiesIntoTaskAttachmentsDirAndReturnsProjectRelativePath() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let sourceURL = tempDir.appendingPathComponent("quick-capture.md", isDirectory: false)
        try "# Context".write(to: sourceURL, atomically: true, encoding: .utf8)

        let draftID = UUID()
        let stagedPath = try sut.stageAttachment(
            at: root,
            draftID: draftID,
            sourceURL: sourceURL
        )

        let taskID = 0
        let finalizedPaths = try sut.finalizeAttachments(
            at: root,
            taskID: taskID,
            stagedEntries: [(path: stagedPath, isProjectReference: false)]
        )

        XCTAssertEqual(finalizedPaths.count, 1)
        XCTAssertEqual(finalizedPaths[0], ".nanoteams/tasks/\(String(taskID))/attachments/quick-capture.md")

        let finalizedURL = root.appendingPathComponent(finalizedPaths[0], isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalizedURL.path))
        XCTAssertEqual(try String(contentsOf: finalizedURL), "# Context")
    }

    func testFinalizeAttachments_projectReference_skipsAndReturnsOriginalPath() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let projectFile = root.appendingPathComponent("Sources/main.swift", isDirectory: false)
        try FileManager.default.createDirectory(
            at: projectFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "import Foundation".write(to: projectFile, atomically: true, encoding: .utf8)

        let taskID = 0
        let finalizedPaths = try sut.finalizeAttachments(
            at: root,
            taskID: taskID,
            stagedEntries: [(path: "Sources/main.swift", isProjectReference: true)]
        )

        XCTAssertEqual(finalizedPaths, ["Sources/main.swift"])

        // No copy should exist in task attachments dir
        let attachmentsDir = paths(for: root).taskAttachmentsDir(taskID: taskID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentsDir.path))

        // Original file should still be present and unchanged
        XCTAssertEqual(try String(contentsOf: projectFile), "import Foundation")
    }

    func testFinalizeAttachments_mixedReferencesAndCopies() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Create a project file (reference)
        let projectFile = root.appendingPathComponent("README.md", isDirectory: false)
        try "# Hello".write(to: projectFile, atomically: true, encoding: .utf8)

        // Create a staged file (copy)
        let sourceURL = tempDir.appendingPathComponent("external.txt", isDirectory: false)
        try "external content".write(to: sourceURL, atomically: true, encoding: .utf8)
        let draftID = UUID()
        let stagedPath = try sut.stageAttachment(at: root, draftID: draftID, sourceURL: sourceURL)

        let taskID = 0
        let finalizedPaths = try sut.finalizeAttachments(
            at: root,
            taskID: taskID,
            stagedEntries: [
                (path: "README.md", isProjectReference: true),
                (path: stagedPath, isProjectReference: false)
            ]
        )

        XCTAssertEqual(finalizedPaths.count, 2)
        XCTAssertEqual(finalizedPaths[0], "README.md")
        XCTAssertTrue(finalizedPaths[1].contains("attachments/external.txt"))
    }

    func testFinalizeAttachments_appendsNumericSuffixWhenDestinationExists() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let sourceURL = tempDir.appendingPathComponent("spec.txt", isDirectory: false)
        try "draft spec".write(to: sourceURL, atomically: true, encoding: .utf8)

        let draftID = UUID()
        let stagedPath = try sut.stageAttachment(
            at: root,
            draftID: draftID,
            sourceURL: sourceURL
        )

        let taskID = 0
        let attachmentsDir = paths(for: root).taskAttachmentsDir(taskID: taskID)
        try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        let existingURL = attachmentsDir.appendingPathComponent("spec.txt", isDirectory: false)
        try "existing".write(to: existingURL, atomically: true, encoding: .utf8)

        let finalizedPaths = try sut.finalizeAttachments(
            at: root,
            taskID: taskID,
            stagedEntries: [(path: stagedPath, isProjectReference: false)]
        )

        XCTAssertEqual(finalizedPaths, [".nanoteams/tasks/\(String(taskID))/attachments/spec-2.txt"])

        let finalizedURL = root.appendingPathComponent(finalizedPaths[0], isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalizedURL.path))
        XCTAssertEqual(try String(contentsOf: finalizedURL), "draft spec")
    }

    func testCleanupQuickCaptureDraft_removesDraftDirectory() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let sourceURL = tempDir.appendingPathComponent("draft.txt", isDirectory: false)
        try "temp".write(to: sourceURL, atomically: true, encoding: .utf8)

        let draftID = UUID()
        _ = try sut.stageAttachment(
            at: root,
            draftID: draftID,
            sourceURL: sourceURL
        )

        let draftDir = paths(for: root).stagedAttachmentDir(draftID: draftID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftDir.path))

        try sut.cleanupStagedDraft(at: root, draftID: draftID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDir.path))
    }

    func testFinalizeAttachments_emptyStagedPaths_returnsEmpty() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let result = try sut.finalizeAttachments(
            at: root,
            taskID: Int(),
            stagedEntries: []
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testRemoveQuickCaptureItem_nonexistentFile_doesNotThrow() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertNoThrow(
            try sut.removeStagedItem(at: root, relativePath: ".nanoteams/staged/gone.txt")
        )
    }

    func testCleanupQuickCaptureDraft_nonexistentDraft_doesNotThrow() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertNoThrow(
            try sut.cleanupStagedDraft(at: root, draftID: UUID())
        )
    }

    func testCleanupAllQuickCaptureDrafts_removesAllDrafts() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let source1 = tempDir.appendingPathComponent("a.txt", isDirectory: false)
        try "a".write(to: source1, atomically: true, encoding: .utf8)
        let source2 = tempDir.appendingPathComponent("b.txt", isDirectory: false)
        try "b".write(to: source2, atomically: true, encoding: .utf8)

        let draftID1 = UUID()
        let draftID2 = UUID()
        _ = try sut.stageAttachment(at: root, draftID: draftID1, sourceURL: source1)
        _ = try sut.stageAttachment(at: root, draftID: draftID2, sourceURL: source2)

        let draftsDir = paths(for: root).stagedAttachmentsDir
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftsDir.path))

        try sut.cleanupAllStagedDrafts(at: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: draftsDir.path))
    }

    func testStageAttachment_multipleFilesInSameDraft() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let source1 = tempDir.appendingPathComponent("file1.txt", isDirectory: false)
        try "one".write(to: source1, atomically: true, encoding: .utf8)
        let source2 = tempDir.appendingPathComponent("file2.txt", isDirectory: false)
        try "two".write(to: source2, atomically: true, encoding: .utf8)

        let draftID = UUID()
        let path1 = try sut.stageAttachment(at: root, draftID: draftID, sourceURL: source1)
        let path2 = try sut.stageAttachment(at: root, draftID: draftID, sourceURL: source2)

        XCTAssertNotEqual(path1, path2)
        XCTAssertTrue(path1.contains(draftID.uuidString))
        XCTAssertTrue(path2.contains(draftID.uuidString))

        let stagedURL1 = root.appendingPathComponent(path1, isDirectory: false)
        let stagedURL2 = root.appendingPathComponent(path2, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL2.path))
    }

    func testResolvedProjectRelativeURL_pathTraversal_throws() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertThrowsError(
            try sut.removeStagedItem(at: root, relativePath: "../../../etc/passwd")
        )
    }

    func testResolvedProjectRelativeURL_emptyPath_throws() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertThrowsError(
            try sut.removeStagedItem(at: root, relativePath: "")
        )
    }

    func testFinalizeAttachments_rollbackOnFailure() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Stage two files
        let source1 = tempDir.appendingPathComponent("good.txt", isDirectory: false)
        try "good".write(to: source1, atomically: true, encoding: .utf8)
        let source2 = tempDir.appendingPathComponent("bad.txt", isDirectory: false)
        try "bad".write(to: source2, atomically: true, encoding: .utf8)

        let draftID = UUID()
        let path1 = try sut.stageAttachment(at: root, draftID: draftID, sourceURL: source1)
        let path2 = try sut.stageAttachment(at: root, draftID: draftID, sourceURL: source2)

        // Delete the second staged file so finalization will fail on it
        let stagedURL2 = root.appendingPathComponent(path2, isDirectory: false)
        try FileManager.default.removeItem(at: stagedURL2)

        let taskID = 0
        XCTAssertThrowsError(
            try sut.finalizeAttachments(at: root, taskID: taskID, stagedEntries: [(path: path1, isProjectReference: false), (path: path2, isProjectReference: false)])
        )

        // The first file that was successfully copied should be rolled back (cleaned up)
        let attachmentsDir = paths(for: root).taskAttachmentsDir(taskID: taskID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentsDir.path), "Attachments dir should exist after eager creation")
        let contents = try FileManager.default.contentsOfDirectory(atPath: attachmentsDir.path)
        XCTAssertTrue(contents.isEmpty, "Rolled-back finalization should leave no files in attachments dir")
    }

    func testStageAttachment_sameNameTwice_addsSuffix() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let source = tempDir.appendingPathComponent("notes.txt", isDirectory: false)
        try "v1".write(to: source, atomically: true, encoding: .utf8)

        let draftID = UUID()
        let path1 = try sut.stageAttachment(at: root, draftID: draftID, sourceURL: source)

        // Rewrite source content to differentiate
        try "v2".write(to: source, atomically: true, encoding: .utf8)
        let path2 = try sut.stageAttachment(at: root, draftID: draftID, sourceURL: source)

        XCTAssertNotEqual(path1, path2)
        XCTAssertTrue(path1.hasSuffix("notes.txt"))
        XCTAssertTrue(path2.contains("notes-2.txt"), "Second file with same name should get -2 suffix")

        // Verify both files exist with correct content
        let url1 = root.appendingPathComponent(path1, isDirectory: false)
        let url2 = root.appendingPathComponent(path2, isDirectory: false)
        XCTAssertEqual(try String(contentsOf: url1), "v1")
        XCTAssertEqual(try String(contentsOf: url2), "v2")
    }

    func testConcurrentDrafts_doNotInterfere() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let source1 = tempDir.appendingPathComponent("draft1.txt", isDirectory: false)
        try "one".write(to: source1, atomically: true, encoding: .utf8)
        let source2 = tempDir.appendingPathComponent("draft2.txt", isDirectory: false)
        try "two".write(to: source2, atomically: true, encoding: .utf8)

        let draftID1 = UUID()
        let draftID2 = UUID()
        let path1 = try sut.stageAttachment(at: root, draftID: draftID1, sourceURL: source1)
        let path2 = try sut.stageAttachment(at: root, draftID: draftID2, sourceURL: source2)

        XCTAssertTrue(path1.contains(draftID1.uuidString))
        XCTAssertTrue(path2.contains(draftID2.uuidString))

        // Cleanup one draft should not affect the other
        try sut.cleanupStagedDraft(at: root, draftID: draftID1)

        let url2 = root.appendingPathComponent(path2, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path), "Other draft's files should still exist")
    }
}
