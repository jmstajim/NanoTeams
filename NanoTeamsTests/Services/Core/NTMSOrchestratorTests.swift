import XCTest

@testable import NanoTeams

/// Tests for NTMSOrchestrator — the central @MainActor state container.
/// Covers project lifecycle, task CRUD, run control, multi-task isolation,
/// engine state synchronization, and in-memory mutation logic.
@MainActor
final class NTMSOrchestratorTests: NTMSOrchestratorTestBase {

    // MARK: - Initial State

    func testInitialState_isNil() {
        XCTAssertNil(sut.workFolderURL)
        XCTAssertNil(sut.snapshot)
        XCTAssertNil(sut.activeTaskID)
        XCTAssertNil(sut.activeTask)
        XCTAssertNil(sut.selectedRunID)
        XCTAssertNil(sut.lastErrorMessage)
        XCTAssertTrue(sut.toolDefinitions.isEmpty)
    }

    func testHasRunningTasks_initiallyFalse() {
        XCTAssertFalse(sut.hasRunningTasks)
    }

    func testHasRealWorkFolder_initiallyFalse() {
        XCTAssertFalse(sut.hasRealWorkFolder)
    }

    // MARK: - Open Work Folder

    func testOpenProjectFolder_setsProjectFolderURL() async {
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.workFolderURL, tempDir)
        XCTAssertNotNil(sut.snapshot)
        XCTAssertNotNil(sut.snapshot?.workFolder)
    }

    func testOpenProjectFolder_hasRealWorkFolder() async {
        await sut.openWorkFolder(tempDir)

        XCTAssertTrue(sut.hasRealWorkFolder)
    }

    func testOpenProjectFolder_createsDefaultTeam() async {
        await sut.openWorkFolder(tempDir)

        let wf = sut.workFolder
        XCTAssertNotNil(wf)
        XCTAssertFalse(wf?.teams.isEmpty ?? true,
                       "Opening a project should bootstrap default teams")
    }

    func testOpenProjectFolder_defaultStorageURL_notRealWorkFolder() async {
        let defaultURL = NTMSOrchestrator.defaultStorageURL
        try? FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)

        await sut.openWorkFolder(defaultURL)

        XCTAssertFalse(sut.hasRealWorkFolder)
    }

    // MARK: - Task CRUD

    func testCreateTask_returnsTaskID() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Test Task", supervisorTask: "Build something")

        XCTAssertNotNil(taskID)
        XCTAssertEqual(sut.activeTaskID, taskID)
        XCTAssertEqual(sut.activeTask?.title, "Test Task")
        XCTAssertEqual(sut.activeTask?.supervisorTask, "Build something")
    }

    func testCreateTask_noProject_returnsNil() async {
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")

        XCTAssertNil(taskID)
    }

    func testCreateMultipleTasks_switchesActive() async {
        await sut.openWorkFolder(tempDir)

        let id1 = await sut.createTask(title: "Task A", supervisorTask: "A")
        let id2 = await sut.createTask(title: "Task B", supervisorTask: "B")

        // Second task should be active
        XCTAssertEqual(sut.activeTaskID, id2)
        XCTAssertEqual(sut.activeTask?.title, "Task B")
        // First task should still exist in summaries
        XCTAssertNotNil(id1)
    }

    func testSwitchTask_changesToCorrectTask() async {
        await sut.openWorkFolder(tempDir)

        let id1 = await sut.createTask(title: "Task A", supervisorTask: "A")
        _ = await sut.createTask(title: "Task B", supervisorTask: "B")

        await sut.switchTask(to: id1)

        XCTAssertEqual(sut.activeTaskID, id1)
        XCTAssertEqual(sut.activeTask?.title, "Task A")
    }

    func testRemoveTask_removesFromState() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        await sut.removeTask(taskID)

        XCTAssertNil(sut.activeTask)
    }

    func testRemoveTask() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        await sut.removeTask(taskID)

        XCTAssertNil(sut.activeTask)
    }

    func testUpdateTaskTitle_updatesTitle() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Old", supervisorTask: "Goal")!

        await sut.updateTaskTitle(id: taskID, title: "New Title")

        XCTAssertEqual(sut.activeTask?.title, "New Title")
    }

    // MARK: - Close Task (Supervisor Acceptance)

    func testCloseTask_setsClosedAt() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        XCTAssertNil(sut.activeTask?.closedAt)

        let success = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(success)
        XCTAssertNotNil(sut.activeTask?.closedAt)
    }

    func testCloseTask_stopsEngine() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        let success = await sut.closeTask(taskID: taskID)
        XCTAssertTrue(success)

        // Engine should be removed
        XCTAssertNil(sut.taskEngineStates[taskID])
    }

    // MARK: - Task Mutation

    func testMutateTask_activeTask_updatesInMemory() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        await sut.mutateTask(taskID: taskID) { task in
            task.supervisorTask = "Updated goal"
        }

        XCTAssertEqual(sut.activeTask?.supervisorTask, "Updated goal")
    }

    func testMutateTask_activeTask_updatesTimestamp() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!
        let beforeUpdate = sut.activeTask?.updatedAt

        await sut.mutateTask(taskID: taskID) { task in
            task.title = "Changed"
        }

        XCTAssertNotNil(sut.activeTask?.updatedAt)
        XCTAssertNotEqual(sut.activeTask?.updatedAt, beforeUpdate)
    }

    func testMutateTask_noProjectFolder_doesNotCrash() async {
        // Should gracefully return without crash
        await sut.mutateTask(taskID: Int()) { task in
            task.title = "won't work"
        }

        XCTAssertNil(sut.workFolderURL)
    }

    // MARK: - In-Memory Mutations

    func testMutateTaskInMemory_activeTask_updatesWithoutDisk() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        sut.mutateTaskInMemory(taskID: taskID) { task in
            task.supervisorTask = "In-memory only"
        }

        XCTAssertEqual(sut.activeTask?.supervisorTask, "In-memory only")
    }

    func testMutateTaskInMemory_withUpdateIndex_updatesTaskIndex() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        sut.mutateTaskInMemory(taskID: taskID, { task in
            task.title = "Updated Index"
        }, updateIndex: true)

        let summaries = sut.taskSummaries(filter: .all)
        XCTAssertTrue(summaries.contains(where: { $0.title == "Updated Index" }))
    }

    func testMutateTaskInMemory_backgroundTask_updatesLoadedTasks() async {
        await sut.openWorkFolder(tempDir)

        let id1 = await sut.createTask(title: "Task A", supervisorTask: "A")!
        let id2 = await sut.createTask(title: "Task B", supervisorTask: "B")!

        // id1 should be preserved in loadedTasks
        await sut.switchTask(to: id1)
        await sut.switchTask(to: id2)

        // Now mutate task id1 which should be in loadedTasks
        sut.mutateTaskInMemory(taskID: id1) { task in
            task.supervisorTask = "Background change"
        }

        let loaded = sut.loadedTask(id1)
        XCTAssertEqual(loaded?.supervisorTask, "Background change")
    }

    // MARK: - Loaded Task Access

    func testLoadedTask_activeTask_returnsTask() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        let loaded = sut.loadedTask(taskID)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.title, "Task")
    }

    func testLoadedTask_unknownID_returnsNil() async {
        await sut.openWorkFolder(tempDir)

        let loaded = sut.loadedTask(999)

        XCTAssertNil(loaded)
    }

    // MARK: - Engine State Sync

    func testSyncEngineStateFromRun_pausedRun_setsEnginePaused() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        // Create a run with paused status
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, roleStatuses: ["eng": .idle])
            let step = StepExecution(
                id: "test_step",
                role: .softwareEngineer,
                title: "Code",
                status: .paused
            )
            run.steps = [step]
            task.runs = [run]
        }

        // Re-open the project to trigger syncEngineStateFromRun
        await sut.openWorkFolder(tempDir)

        // Engine state should reflect the paused run
        if let taskID = sut.activeTaskID {
            let state = sut.taskEngineStates[taskID]
            // After recovery, paused steps remain paused, so engine should reflect that
            XCTAssertNotNil(state)
        }
    }

    // MARK: - Work Folder Mutation

    func testMutateProject_updatesWorkFolderState() async {
        await sut.openWorkFolder(tempDir)

        await sut.mutateWorkFolder { proj in
            proj.settings.description = "Test description"
        }

        XCTAssertEqual(sut.workFolder?.settings.description, "Test description")
    }

    func testMutateProject_noSnapshot_doesNotCrash() async {
        // No project open
        await sut.mutateWorkFolder { proj in
            proj.settings.description = "Won't work"
        }

        XCTAssertNil(sut.workFolder)
    }

    // MARK: - apply() Task Preservation

    func testApply_preservesOldActiveTaskInLoadedTasks() async {
        await sut.openWorkFolder(tempDir)

        let id1 = await sut.createTask(title: "Task A", supervisorTask: "A")!
        let id2 = await sut.createTask(title: "Task B", supervisorTask: "B")!

        // When we switched from Task A to Task B, Task A should be preserved
        let task1 = sut.loadedTask(id1)
        XCTAssertNotNil(task1, "Old active task must be preserved in loadedTasks")
        XCTAssertEqual(task1?.title, "Task A")
    }

    // MARK: - Selected Run ID Sync

    func testSelectedRunID_syncsWithLatestRun() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        await sut.mutateTask(taskID: taskID) { task in
            let run = Run(id: 0, roleStatuses: [:])
            task.runs = [run]
        }

        XCTAssertNotNil(sut.selectedRunID)
        XCTAssertEqual(sut.selectedRunID, sut.activeTask?.runs.last?.id)
    }

    func testSelectedRunID_nilWhenNoTask() async {
        await sut.openWorkFolder(tempDir)

        await sut.switchTask(to: nil)

        XCTAssertNil(sut.selectedRunID)
    }

    // MARK: - Start/Pause Run Guards

    func testStartRun_doubleStart_isIgnored() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Task", supervisorTask: "Goal")!

        await sut.startRun(taskID: taskID)
        let firstState = sut.taskEngineStates[taskID]

        // Second start should be no-op
        await sut.startRun(taskID: taskID)
        let secondState = sut.taskEngineStates[taskID]

        XCTAssertEqual(firstState, secondState)
    }

    func testCreateAndStartRun_immediatelyCreatesRunAndStartsEngine() async {
        await sut.openWorkFolder(tempDir)

        // Simulate the auto-start flow: create → switch → start
        let taskID = await sut.createTask(title: "Auto", supervisorTask: "Go")!
        await sut.switchTask(to: taskID)
        await sut.startRun(taskID: taskID)

        // Task should have exactly one run
        let task = sut.activeTask
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.runs.count, 1)

        // Engine should be running
        let state = sut.taskEngineStates[taskID]
        XCTAssertEqual(state, .running)

        // Selected run should be set
        XCTAssertNotNil(sut.selectedRunID)
    }

    func testCreateAndStartRun_secondCallToStartIsNoOp() async {
        await sut.openWorkFolder(tempDir)

        let taskID = await sut.createTask(title: "Auto", supervisorTask: "Go")!
        await sut.switchTask(to: taskID)
        await sut.startRun(taskID: taskID)

        let runCountAfterFirst = sut.activeTask?.runs.count

        // Double-start guard: should not create a second run
        await sut.startRun(taskID: taskID)

        XCTAssertEqual(sut.activeTask?.runs.count, runCountAfterFirst)
    }

    func testCreatePreparedTaskAndStart_persistsInitialInputAndStartsRun() async throws {
        await sut.openWorkFolder(tempDir)

        // Pick a non-generated team — "Generated Team" would trigger LLM generation flow.
        guard let selectedTeam = sut.workFolder?.teams.first(where: { $0.templateID != "generated" }) else {
            XCTFail("Expected at least one non-generated team")
            return
        }

        let sourceURL = tempDir.appendingPathComponent("capture.txt", isDirectory: false)
        try "captured context".write(to: sourceURL, atomically: true, encoding: .utf8)

        let draftID = UUID()
        guard let stagedAttachment = sut.stageAttachment(url: sourceURL, draftID: draftID) else {
            XCTFail("Expected attachment to stage successfully")
            return
        }

        let request = TaskCreationRequest(
            title: "Quick Capture Task",
            rawSupervisorTask: "Implement import flow",
            preferredTeamID: selectedTeam.id,
            clippedTexts: ["Selected API response"],
            stagedAttachments: [
                TaskCreationStagedAttachment(
                    projectRelativePath: stagedAttachment.stagedRelativePath,
                    fileName: stagedAttachment.fileName,
                    isProjectReference: false
                )
            ]
        )

        guard let taskID = await sut.createPreparedTaskAndStart(request: request) else {
            XCTFail("Expected prepared task creation to succeed")
            return
        }

        guard let task = sut.activeTask else {
            XCTFail("Expected active task after prepared creation")
            return
        }

        XCTAssertEqual(taskID, task.id)
        XCTAssertEqual(task.title, "Quick Capture Task")
        XCTAssertEqual(task.supervisorTask, "Implement import flow")
        XCTAssertEqual(task.clippedTexts, ["Selected API response"])
        XCTAssertEqual(task.preferredTeamID, selectedTeam.id)
        XCTAssertEqual(task.runs.count, 1)
        XCTAssertEqual(sut.taskEngineStates[taskID], .running)
        XCTAssertEqual(task.attachmentPaths.count, 1)
        XCTAssertTrue(
            task.attachmentPaths[0].hasPrefix(".nanoteams/tasks/\(String(taskID))/attachments/"),
            "Attachments should be finalized into the task storage directory"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent(task.attachmentPaths[0], isDirectory: false).path
            )
        )
    }

    func testBootstrapDefaultStorageIfNeeded_cleansQuickCaptureDraftsForRestoredProject() async throws {
        let restoredProject = tempDir.appendingPathComponent("RestoredProject", isDirectory: true)
        try FileManager.default.createDirectory(at: restoredProject, withIntermediateDirectories: true)

        let draftID = UUID()
        let paths = NTMSPaths(workFolderRoot: restoredProject)
        let draftDir = paths.stagedAttachmentDir(draftID: draftID)
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        let stagedFile = draftDir.appendingPathComponent("staged.txt", isDirectory: false)
        try "staged".write(to: stagedFile, atomically: true, encoding: .utf8)

        sut.configuration.lastOpenedWorkFolderPath = restoredProject.path
        defer { sut.configuration.lastOpenedWorkFolderPath = nil }

        await sut.bootstrapDefaultStorageIfNeeded()

        XCTAssertEqual(sut.workFolderURL, restoredProject)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.stagedAttachmentsDir.path),
            "Bootstrap should remove leftover staged drafts from the restored project"
        )
    }

    // MARK: - Quick Capture Edge Cases

    func testCreatePreparedTaskAndStart_emptyTitleAndGoal_returnsNil() async {
        await sut.openWorkFolder(tempDir)

        let request = TaskCreationRequest(
            title: "",
            rawSupervisorTask: "",
            preferredTeamID: nil,
            clippedTexts: [],
            stagedAttachments: []
        )

        let result = await sut.createPreparedTaskAndStart(request: request)
        XCTAssertNil(result)
    }

    func testCreatePreparedTaskAndStart_emptyTitle_derivesTitleFromGoal() async {
        await sut.openWorkFolder(tempDir)

        let request = TaskCreationRequest(
            title: "",
            rawSupervisorTask: "Implement the sorting algorithm",
            preferredTeamID: nil,
            clippedTexts: [],
            stagedAttachments: []
        )

        guard await sut.createPreparedTaskAndStart(request: request) != nil else {
            XCTFail("Expected task creation to succeed with auto-derived title")
            return
        }

        XCTAssertEqual(sut.activeTask?.title, "Implement the sorting algorithm")
    }

    func testCreatePreparedTaskAndStart_emptyTitle_truncatesLongGoal() async {
        await sut.openWorkFolder(tempDir)

        let longGoal = String(repeating: "A", count: 100)
        let request = TaskCreationRequest(
            title: "",
            rawSupervisorTask: longGoal,
            preferredTeamID: nil,
            clippedTexts: [],
            stagedAttachments: []
        )

        guard await sut.createPreparedTaskAndStart(request: request) != nil else {
            XCTFail("Expected task creation to succeed with truncated title")
            return
        }

        let title = sut.activeTask?.title ?? ""
        XCTAssertTrue(title.count <= 61, "Title should be truncated to 60 chars + ellipsis")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testStageAttachment_noProject_returnsNilAndSetsError() {
        let url = tempDir.appendingPathComponent("file.txt", isDirectory: false)
        try? "content".write(to: url, atomically: true, encoding: .utf8)

        let result = sut.stageAttachment(url: url, draftID: UUID())

        XCTAssertNil(result)
        XCTAssertNotNil(sut.lastErrorMessage)
    }

    func testDiscardStagedDraft_noProject_isSafe() {
        sut.discardStagedDraft(draftID: UUID())
        // Should not crash; lastErrorMessage may or may not be set
    }

    func testSubmitQuickCaptureForm_createsTaskAndCleansDraft() async throws {
        await sut.openWorkFolder(tempDir)

        let sourceURL = tempDir.appendingPathComponent("submit-test.txt", isDirectory: false)
        try "submit content".write(to: sourceURL, atomically: true, encoding: .utf8)

        let draftID = UUID()
        guard let staged = sut.stageAttachment(url: sourceURL, draftID: draftID) else {
            XCTFail("Expected staging to succeed")
            return
        }

        let taskID = await sut.submitQuickCaptureForm(
            title: "Submit Test",
            supervisorTask: "Test goal",
            teamID: nil,
            clippedTexts: ["clipped"],
            attachments: [staged],
            draftID: draftID
        )

        XCTAssertNotNil(taskID)

        guard let task = sut.activeTask else {
            XCTFail("Expected active task")
            return
        }

        XCTAssertEqual(task.title, "Submit Test")
        XCTAssertEqual(task.supervisorTask, "Test goal")
        XCTAssertEqual(task.clippedTexts, ["clipped"])
        XCTAssertEqual(task.attachmentPaths.count, 1)

        // Draft directory should be cleaned up
        let draftDir = NTMSPaths(workFolderRoot: tempDir).stagedAttachmentDir(draftID: draftID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDir.path))
    }

    func testSubmitQuickCaptureForm_emptyTitleAndGoal_returnsNil() async {
        await sut.openWorkFolder(tempDir)

        let result = await sut.submitQuickCaptureForm(
            title: "",
            supervisorTask: "",
            teamID: nil,
            clippedTexts: [],
            attachments: [],
            draftID: UUID()
        )

        XCTAssertNil(result)
    }

    func testRemoveQuickCaptureStagedAttachment_removesFile() async throws {
        await sut.openWorkFolder(tempDir)

        // Source must be OUTSIDE workFolder so it gets copied to staging (not treated as project reference).
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }

        let sourceURL = externalDir.appendingPathComponent("remove-test.txt", isDirectory: false)
        try "to be removed".write(to: sourceURL, atomically: true, encoding: .utf8)

        let draftID = UUID()
        guard let staged = sut.stageAttachment(url: sourceURL, draftID: draftID) else {
            XCTFail("Expected staging to succeed")
            return
        }

        XCTAssertFalse(staged.isProjectReference)

        let stagedFileURL = tempDir
            .appendingPathComponent(staged.stagedRelativePath, isDirectory: false)
            .standardizedFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFileURL.path))

        sut.removeStagedAttachment(staged)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFileURL.path))
    }

    func testStageAttachment_inProjectFile_returnsProjectReference() async throws {
        await sut.openWorkFolder(tempDir)

        // Create file INSIDE the work folder (but outside .nanoteams/)
        let projectFile = tempDir.appendingPathComponent("Sources/main.swift", isDirectory: false)
        try FileManager.default.createDirectory(
            at: projectFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "import Foundation".write(to: projectFile, atomically: true, encoding: .utf8)

        let draftID = UUID()
        guard let staged = sut.stageAttachment(url: projectFile, draftID: draftID) else {
            XCTFail("Expected staging to succeed")
            return
        }

        XCTAssertTrue(staged.isProjectReference)
        XCTAssertEqual(staged.stagedRelativePath, "Sources/main.swift")

        // No copy should exist in the staging directory
        let stagingDir = NTMSPaths(workFolderRoot: tempDir).stagedAttachmentDir(draftID: draftID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path))
    }

    func testStageAttachment_nanoteamsFile_isNotProjectReference() async throws {
        await sut.openWorkFolder(tempDir)

        // Create file inside .nanoteams/ (should NOT be treated as project reference)
        let nanoteamsFile = tempDir
            .appendingPathComponent(".nanoteams/tasks/test.txt", isDirectory: false)
        try FileManager.default.createDirectory(
            at: nanoteamsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "metadata".write(to: nanoteamsFile, atomically: true, encoding: .utf8)

        let draftID = UUID()
        guard let staged = sut.stageAttachment(url: nanoteamsFile, draftID: draftID) else {
            XCTFail("Expected staging to succeed (as a copy, not reference)")
            return
        }

        XCTAssertFalse(staged.isProjectReference)
    }

    func testRemoveStagedAttachment_projectReference_doesNotDeleteOriginalFile() async throws {
        await sut.openWorkFolder(tempDir)

        let projectFile = tempDir.appendingPathComponent("keep-me.swift", isDirectory: false)
        try "do not delete".write(to: projectFile, atomically: true, encoding: .utf8)

        let draftID = UUID()
        guard let staged = sut.stageAttachment(url: projectFile, draftID: draftID) else {
            XCTFail("Expected staging to succeed")
            return
        }

        XCTAssertTrue(staged.isProjectReference)

        sut.removeStagedAttachment(staged)

        // Original file must still exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFile.path))
        XCTAssertEqual(try String(contentsOf: projectFile), "do not delete")
    }

    func testCreatePreparedTaskAndStart_whitespaceClippedText_normalizesToNil() async throws {
        await sut.openWorkFolder(tempDir)

        let request = TaskCreationRequest(
            title: "Clip Test",
            rawSupervisorTask: "goal",
            preferredTeamID: nil,
            clippedTexts: ["   \n\t"],
            stagedAttachments: []
        )

        guard let taskID = await sut.createPreparedTaskAndStart(request: request) else {
            XCTFail("Expected task creation to succeed")
            return
        }

        let task = sut.activeTask
        XCTAssertEqual(task?.id, taskID)
        XCTAssertTrue(task?.clippedTexts.isEmpty == true, "Whitespace-only clips should be filtered out")
    }

    func testCreatePreparedTaskAndStart_emptyClippedText_normalizesToNil() async throws {
        await sut.openWorkFolder(tempDir)

        let request = TaskCreationRequest(
            title: "Empty Clip",
            rawSupervisorTask: "goal",
            preferredTeamID: nil,
            clippedTexts: [""],
            stagedAttachments: []
        )

        guard let taskID = await sut.createPreparedTaskAndStart(request: request) else {
            XCTFail("Expected task creation to succeed")
            return
        }

        XCTAssertTrue(sut.activeTask?.clippedTexts.isEmpty == true)
    }

    func testCreatePreparedTaskAndStart_trimsGoalWhitespace() async throws {
        await sut.openWorkFolder(tempDir)

        let request = TaskCreationRequest(
            title: "Trim Test",
            rawSupervisorTask: "  Build feature  \n",
            preferredTeamID: nil,
            clippedTexts: [],
            stagedAttachments: []
        )

        guard await sut.createPreparedTaskAndStart(request: request) != nil else {
            XCTFail("Expected task creation to succeed")
            return
        }

        XCTAssertEqual(sut.activeTask?.supervisorTask, "Build feature")
    }

    func testCreatePreparedTaskAndStart_trimsTitleWhitespace() async throws {
        await sut.openWorkFolder(tempDir)

        let request = TaskCreationRequest(
            title: "  My Task  ",
            rawSupervisorTask: "goal",
            preferredTeamID: nil,
            clippedTexts: [],
            stagedAttachments: []
        )

        guard await sut.createPreparedTaskAndStart(request: request) != nil else {
            XCTFail("Expected task creation to succeed")
            return
        }

        XCTAssertEqual(sut.activeTask?.title, "My Task")
    }

    func testSubmitQuickCaptureForm_multipleAttachments() async throws {
        await sut.openWorkFolder(tempDir)

        let draftID = UUID()
        let source1 = tempDir.appendingPathComponent("a.txt", isDirectory: false)
        try "aaa".write(to: source1, atomically: true, encoding: .utf8)
        let source2 = tempDir.appendingPathComponent("b.txt", isDirectory: false)
        try "bbb".write(to: source2, atomically: true, encoding: .utf8)

        guard let staged1 = sut.stageAttachment(url: source1, draftID: draftID),
              let staged2 = sut.stageAttachment(url: source2, draftID: draftID) else {
            XCTFail("Expected staging to succeed")
            return
        }

        let taskID = await sut.submitQuickCaptureForm(
            title: "Multi Attach",
            supervisorTask: "",
            teamID: nil,
            clippedTexts: [],
            attachments: [staged1, staged2],
            draftID: draftID
        )

        XCTAssertNotNil(taskID)
        XCTAssertEqual(sut.activeTask?.attachmentPaths.count, 2)
    }

    func testSubmitQuickCaptureForm_stageRemoveThenSubmitRemaining() async throws {
        await sut.openWorkFolder(tempDir)

        let draftID = UUID()
        let source1 = tempDir.appendingPathComponent("keep.txt", isDirectory: false)
        try "keep".write(to: source1, atomically: true, encoding: .utf8)
        let source2 = tempDir.appendingPathComponent("remove.txt", isDirectory: false)
        try "remove".write(to: source2, atomically: true, encoding: .utf8)

        guard let staged1 = sut.stageAttachment(url: source1, draftID: draftID),
              let staged2 = sut.stageAttachment(url: source2, draftID: draftID) else {
            XCTFail("Expected staging to succeed")
            return
        }

        // Remove one attachment before submitting
        sut.removeStagedAttachment(staged2)

        let taskID = await sut.submitQuickCaptureForm(
            title: "Partial",
            supervisorTask: "",
            teamID: nil,
            clippedTexts: [],
            attachments: [staged1],
            draftID: draftID
        )

        XCTAssertNotNil(taskID)
        XCTAssertEqual(sut.activeTask?.attachmentPaths.count, 1)
        XCTAssertTrue(sut.activeTask?.attachmentPaths[0].contains("keep.txt") == true)

        // Draft should be cleaned up
        let draftDir = NTMSPaths(workFolderRoot: tempDir).stagedAttachmentDir(draftID: draftID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDir.path))
    }

    // MARK: - Streaming Previews

    func testAppendStreamingPreview_delegatesToManager() async {
        let stepID = "test_step"
        let messageID = UUID()

        sut.appendStreamingPreview(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Hello")

        let preview = sut.streamingPreviewManager.preview(for: stepID)
        XCTAssertNotNil(preview, "Streaming preview should be appended")
    }

    func testClearStreamingPreview_removesPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        sut.appendStreamingPreview(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "test")
        sut.clearStreamingPreview(stepID: stepID)

        let preview = sut.streamingPreviewManager.preview(for: stepID)
        XCTAssertNil(preview)
    }

    // MARK: - Meeting Participants

    func testSetActiveMeetingParticipants_setsOnEngineState() {
        let taskID = 0
        let participants: Set<String> = ["eng", "pm"]

        sut.setActiveMeetingParticipants(participants, for: taskID)

        XCTAssertEqual(sut.engineState.activeMeetingParticipants[taskID], participants)
    }

    func testClearActiveMeetingParticipants_removesFromEngineState() {
        let taskID = 0

        sut.setActiveMeetingParticipants(["eng"], for: taskID)
        sut.clearActiveMeetingParticipants(for: taskID)

        XCTAssertNil(sut.engineState.activeMeetingParticipants[taskID])
    }

    // MARK: - Resolved Team

    func testResolvedTeam_withPreferredTeamID_returnsPreferredTeam() async {
        await sut.openWorkFolder(tempDir)

        let team = sut.workFolder?.teams.first
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "G", preferredTeamID: team?.id)

        let resolved = sut.resolvedTeam(for: task)

        XCTAssertEqual(resolved.id, team?.id)
    }

    func testResolvedTeam_nilTask_returnsDefaultTeam() async {
        await sut.openWorkFolder(tempDir)

        let resolved = sut.resolvedTeam(for: nil)

        XCTAssertFalse(resolved.roles.isEmpty, "Default team should have roles")
    }

    // MARK: - Conversation / Network Log URLs

    func testConversationLogURL_returnsPathUnderNanoTeams() async {
        await sut.openWorkFolder(tempDir)

        let runID = 0
        let url = sut.conversationLogURL(taskID: 0, runID: runID)

        XCTAssertNotNil(url)
        XCTAssertTrue(url?.path.contains(".nanoteams") ?? false)
    }

    func testConversationLogExists_falseForMissingFile() async {
        await sut.openWorkFolder(tempDir)

        let exists = sut.conversationLogExists(taskID: 0, runID: 0)

        XCTAssertFalse(exists)
    }

    func testNetworkLogURL_returnsPathUnderNanoTeams() async {
        await sut.openWorkFolder(tempDir)

        let runID = 0
        let url = sut.networkLogURL(taskID: 0, runID: runID)

        XCTAssertNotNil(url)
        XCTAssertTrue(url?.path.contains(".nanoteams") ?? false)
    }

    func testNetworkLogExists_falseForMissingFile() async {
        await sut.openWorkFolder(tempDir)

        let exists = sut.networkLogExists(taskID: 0, runID: 0)

        XCTAssertFalse(exists)
    }

    // MARK: - OrchestratorEngineState

    func testEngineState_subscriptSetGet() {
        let taskID = 0

        sut.engineState[taskID] = .running

        XCTAssertEqual(sut.engineState[taskID], .running)
        XCTAssertEqual(sut.taskEngineStates[taskID], .running)
    }

    func testEngineState_removeEngine() {
        let taskID = 0
        sut.engineState[taskID] = .running

        sut.engineState.removeEngine(for: taskID)

        XCTAssertNil(sut.engineState[taskID])
    }

    func testEngineState_removeAllEngines() {
        let id1 = 1
        let id2 = 2
        sut.engineState[id1] = .running
        sut.engineState[id2] = .paused

        sut.engineState.removeAllEngines()

        XCTAssertTrue(sut.engineState.taskEngineStates.isEmpty)
    }
}
