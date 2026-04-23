import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **Settings → Reset to Defaults** — the
/// destructive button that wipes `.nanoteams/` and re-bootstraps the work
/// folder with default teams.
///
/// User scenario: "I've messed up my teams / tools / description and want
/// to start fresh — but keep my actual project files intact."
///
/// Pinned behaviors:
/// 1. Reset wipes `.nanoteams/` entirely, including all tasks.
/// 2. Project-root files (user's actual code) are NOT touched.
/// 3. After reset, default teams are re-bootstrapped.
/// 4. After reset, project description is cleared (back to default prompt).
/// 5. Active pointers (activeTaskID, activeTeamID) are reset.
/// 6. Tasks index is empty.
/// 7. Reset + reopen is idempotent (second reset == first reset).
/// 8. Reset recovers from corruption (e.g. unreadable settings.json).
@MainActor
final class EndToEndResetWorkFolderSettingsTests: NTMSOrchestratorTestBase {

    // MARK: - Scenario 1: Reset wipes .nanoteams tasks

    func testReset_wipesAllTasks() async {
        await sut.openWorkFolder(tempDir)
        _ = await sut.createTask(title: "Task A", supervisorTask: "x")!
        _ = await sut.createTask(title: "Task B", supervisorTask: "y")!
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 2)

        await sut.resetWorkFolderSettings()

        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0,
                       "Reset must wipe all tasks from the index")
        XCTAssertNil(sut.activeTaskID,
                     "Reset must clear activeTaskID")
    }

    // MARK: - Scenario 2: User's real project files are untouched

    func testReset_preservesProjectRootFiles() async throws {
        // Create user file at project root (outside .nanoteams/)
        let sourcesDir = tempDir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: sourcesDir, withIntermediateDirectories: true
        )
        let userFile = sourcesDir.appendingPathComponent("Main.swift")
        try "print(\"keep me\")".data(using: .utf8)!.write(to: userFile)

        await sut.openWorkFolder(tempDir)
        await sut.resetWorkFolderSettings()

        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path),
                      "Reset must NOT touch files outside .nanoteams/")
        let content = try String(contentsOf: userFile, encoding: .utf8)
        XCTAssertEqual(content, "print(\"keep me\")",
                       "User file content must be unchanged")
    }

    // MARK: - Scenario 3: Default teams re-bootstrap

    func testReset_reBootstrapsDefaultTeams() async {
        await sut.openWorkFolder(tempDir)
        let countBefore = sut.workFolder?.teams.count ?? 0
        XCTAssertGreaterThan(countBefore, 0, "Precondition: bootstrap produces teams")

        // Delete a team
        if let teams = sut.workFolder?.teams, teams.count >= 2 {
            await sut.mutateWorkFolder { proj in
                proj.removeTeam(teams[0].id)
            }
        }

        await sut.resetWorkFolderSettings()

        XCTAssertEqual(sut.workFolder?.teams.count, countBefore,
                       "Reset must restore the full default team set")
    }

    // MARK: - Scenario 4: Project description cleared

    func testReset_clearsProjectDescription() async {
        await sut.openWorkFolder(tempDir)
        await sut.updateWorkFolderDescription("Custom description — should be wiped")

        await sut.resetWorkFolderSettings()

        XCTAssertEqual(sut.workFolder?.settings.description, "",
                       "Reset must clear the project description")
    }

    func testReset_restoresDefaultPromptTemplate() async {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder { proj in
            proj.settings.descriptionPrompt = "MY CUSTOM PROMPT"
        }

        await sut.resetWorkFolderSettings()

        XCTAssertEqual(sut.workFolder?.settings.descriptionPrompt,
                       AppDefaults.workFolderDescriptionPrompt,
                       "Reset must restore default descriptionPrompt")
    }

    // MARK: - Scenario 5: Idempotent

    func testReset_twiceInARow_producesSameState() async {
        await sut.openWorkFolder(tempDir)
        await sut.resetWorkFolderSettings()

        let firstTeamsCount = sut.workFolder?.teams.count ?? 0
        let firstTasksCount = sut.snapshot?.tasksIndex.tasks.count ?? -1

        await sut.resetWorkFolderSettings()

        XCTAssertEqual(sut.workFolder?.teams.count, firstTeamsCount)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, firstTasksCount)
    }

    // MARK: - Scenario 6: Reset after task with attachments removes attachment files

    func testReset_removesTaskAttachmentDirs() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let attachmentsDir = paths.taskAttachmentsDir(taskID: taskID)
        try FileManager.default.createDirectory(
            at: attachmentsDir, withIntermediateDirectories: true
        )
        let file = attachmentsDir.appendingPathComponent("x.txt")
        try "content".data(using: .utf8)!.write(to: file)

        await sut.resetWorkFolderSettings()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "Reset must remove orphaned task attachments (part of .nanoteams/)")
    }

    // MARK: - Scenario 7: Reset survives after corruption

    /// User's settings.json gets corrupted somehow (power loss mid-write,
    /// manual edit gone wrong). Reset should recover gracefully.
    func testReset_afterCorruption_recoversCleanly() async throws {
        await sut.openWorkFolder(tempDir)

        // Corrupt settings.json
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try "{this is not valid JSON".data(using: .utf8)!.write(to: paths.settingsJSON)

        await sut.resetWorkFolderSettings()

        XCTAssertNotNil(sut.workFolder,
                        "Work folder context must be usable after reset-from-corruption")
        XCTAssertEqual(sut.workFolder?.settings.description, "",
                       "Settings restored to defaults")
    }
}
