import XCTest
@testable import NanoTeams

final class NTMSPathsTests: XCTestCase {

    private var paths: NTMSPaths!

    override func setUp() {
        super.setUp()
        paths = NTMSPaths(workFolderRoot: URL(fileURLWithPath: "/Users/test/MyProject"))
    }

    override func tearDown() {
        paths = nil
        super.tearDown()
    }

    // MARK: - Directory Paths

    func testNanoteamsDir() {
        XCTAssertTrue(paths.nanoteamsDir.path.hasSuffix("MyProject/.nanoteams"))
    }

    func testInternalDir() {
        XCTAssertTrue(paths.internalDir.path.hasSuffix(".nanoteams/internal"))
    }

    func testTasksDir() {
        XCTAssertTrue(paths.tasksDir.path.hasSuffix(".nanoteams/tasks"))
    }

    // MARK: - Internal Service File Paths

    func testWorkFolderJSON() {
        XCTAssertTrue(paths.workFolderJSON.path.hasSuffix(".nanoteams/internal/workfolder.json"))
    }

    func testSettingsJSON() {
        XCTAssertTrue(paths.settingsJSON.path.hasSuffix(".nanoteams/internal/settings.json"))
    }

    func testTeamsJSON() {
        XCTAssertTrue(paths.teamsJSON.path.hasSuffix(".nanoteams/internal/teams.json"))
    }

    func testToolsJSON() {
        XCTAssertTrue(paths.toolsJSON.path.hasSuffix(".nanoteams/internal/tools.json"))
    }

    func testTasksIndexJSON() {
        XCTAssertTrue(paths.tasksIndexJSON.path.hasSuffix(".nanoteams/internal/tasks_index.json"))
    }

    func testToolCallsJSONL() {
        let taskID = 0
        let runID = 0
        let url = paths.toolCallsJSONL(taskID: taskID, runID: runID)
        XCTAssertTrue(url.path.hasSuffix("tool_calls.jsonl"))
        XCTAssertTrue(url.path.contains("internal/tasks/\(taskID)/runs/\(runID)"))
    }

    func testStagedAttachmentsDir() {
        XCTAssertTrue(paths.stagedAttachmentsDir.path.hasSuffix(".nanoteams/internal/staged"))
    }

    func testHeadlessResultJSON() {
        XCTAssertTrue(paths.headlessResultJSON.path.hasSuffix(".nanoteams/internal/headless_result.json"))
    }

    // MARK: - Task Paths

    func testTaskDir() {
        let taskID = 1
        let taskDir = paths.taskDir(taskID: taskID)
        XCTAssertTrue(taskDir.path.contains(".nanoteams/tasks/\(taskID)"))
    }

    func testTaskJSON() {
        let taskID = 1
        let taskJSON = paths.taskJSON(taskID: taskID)
        XCTAssertTrue(taskJSON.path.contains(".nanoteams/internal/tasks/\(taskID)/task.json"))
    }

    func testTaskAttachmentsDir() {
        let taskID = 1
        let attachmentsDir = paths.taskAttachmentsDir(taskID: taskID)
        XCTAssertTrue(attachmentsDir.path.hasSuffix("\(taskID)/attachments"))
        // Attachments stay in the LLM-accessible area, not internal
        XCTAssertFalse(attachmentsDir.path.contains("internal"))
    }

    // MARK: - Run Paths (LLM-accessible for artifacts)

    func testRunDir() {
        let taskID = 0
        let runID = 0
        let runDir = paths.runDir(taskID: taskID, runID: runID)
        XCTAssertTrue(runDir.path.contains(".nanoteams/tasks/\(taskID)/runs/\(runID)"))
        XCTAssertFalse(runDir.path.contains("internal"))
    }

    func testRolesDir() {
        let taskID = 0
        let runID = 0
        let rolesDir = paths.rolesDir(taskID: taskID, runID: runID)
        XCTAssertTrue(rolesDir.path.hasSuffix("\(runID)/roles"))
    }

    func testRoleDir() {
        let taskID = 0
        let runID = 0
        let roleID = "faang_team_software_engineer"
        let roleDir = paths.roleDir(taskID: taskID, runID: runID, roleID: roleID)
        XCTAssertTrue(roleDir.path.contains("roles/\(roleID)"))
        // Artifact role dir is in the LLM-accessible area
        XCTAssertFalse(roleDir.path.contains("internal"))
    }

    // MARK: - Internal Log Paths

    func testConversationLogURL() {
        let taskID = 0
        let runID = 0
        let url = paths.conversationLogURL(taskID: taskID, runID: runID)
        XCTAssertTrue(url.path.contains("conversation_log.md"))
        XCTAssertTrue(url.path.contains("internal/tasks/\(taskID)/runs/\(runID)"))
    }

    func testNetworkLogJSON() {
        let taskID = 0
        let runID = 0
        let url = paths.networkLogJSON(taskID: taskID, runID: runID)
        XCTAssertTrue(url.path.contains("network_log.json"))
        XCTAssertTrue(url.path.contains("internal/tasks/\(taskID)/runs/\(runID)"))
    }

    // MARK: - Internal Build Diagnostic Paths

    func testBuildDiagnosticsJSON() {
        let taskID = 0
        let runID = 0
        let roleID = "test_engineer"
        let url = paths.buildDiagnosticsJSON(taskID: taskID, runID: runID, roleID: roleID)
        XCTAssertTrue(url.path.hasSuffix("build_diagnostics.json"))
        XCTAssertTrue(url.path.contains("internal"))
        XCTAssertTrue(url.path.contains("roles/\(roleID)"))
    }

    func testBuildExcerptsTXT() {
        let taskID = 0
        let runID = 0
        let roleID = "test_engineer"
        let url = paths.buildExcerptsTXT(taskID: taskID, runID: runID, roleID: roleID)
        XCTAssertTrue(url.path.hasSuffix("build_excerpts.txt"))
        XCTAssertTrue(url.path.contains("internal"))
        XCTAssertTrue(url.path.contains("roles/\(roleID)"))
    }

    // MARK: - relativePathWithinNanoteams

    func testRelativePathWithinNanoteams_pathInsideNanoteams() {
        let absoluteURL = paths.nanoteamsDir
            .appendingPathComponent("tasks")
            .appendingPathComponent("abc")
            .appendingPathComponent("task.json")
        let relative = paths.relativePathWithinNanoteams(for: absoluteURL)
        XCTAssertEqual(relative, "tasks/abc/task.json")
    }

    func testRelativePathWithinNanoteams_internalPath() {
        let absoluteURL = paths.internalDir
            .appendingPathComponent("runs")
            .appendingPathComponent("abc")
            .appendingPathComponent("network_log.json")
        let relative = paths.relativePathWithinNanoteams(for: absoluteURL)
        XCTAssertEqual(relative, "internal/runs/abc/network_log.json")
    }

    func testRelativePathWithinNanoteams_pathOutsideNanoteams_returnsLastComponent() {
        let outsideURL = URL(fileURLWithPath: "/tmp/random/file.json")
        let relative = paths.relativePathWithinNanoteams(for: outsideURL)
        XCTAssertEqual(relative, "file.json")
    }

    func testStagedAttachmentDir() {
        let draftID = UUID()
        let draftDir = paths.stagedAttachmentDir(draftID: draftID)
        XCTAssertTrue(draftDir.path.hasSuffix(".nanoteams/internal/staged/\(draftID.uuidString)"))
    }

    func testRelativePathFromProjectRoot_pathInsideProject() {
        let absoluteURL = paths.workFolderRoot
            .appendingPathComponent(".nanoteams/tasks/abc/attachments/file.txt", isDirectory: false)
        let relative = paths.relativePathFromProjectRoot(for: absoluteURL)

        XCTAssertEqual(relative, ".nanoteams/tasks/abc/attachments/file.txt")
    }

    // MARK: - isInternalURL

    func testIsInternalURL_trueForInternalPath() {
        let url = paths.internalDir.appendingPathComponent("project.json")
        XCTAssertTrue(paths.isInternalURL(url))
    }

    func testIsInternalURL_trueForInternalDir() {
        XCTAssertTrue(paths.isInternalURL(paths.internalDir))
    }

    func testIsInternalURL_falseForAttachments() {
        let taskID = 1
        let url = paths.taskAttachmentsDir(taskID: taskID).appendingPathComponent("file.png")
        XCTAssertFalse(paths.isInternalURL(url))
    }

    func testIsInternalURL_falseForArtifacts() {
        let taskID = 0
        let runID = 0
        let roleID = "test_role"
        let url = paths.roleDir(taskID: taskID, runID: runID, roleID: roleID).appendingPathComponent("artifact_foo.md")
        XCTAssertFalse(paths.isInternalURL(url))
    }

    // MARK: - Hashable

    func testHashable_samePath_equal() {
        let paths1 = NTMSPaths(workFolderRoot: URL(fileURLWithPath: "/Users/test/MyProject"))
        let paths2 = NTMSPaths(workFolderRoot: URL(fileURLWithPath: "/Users/test/MyProject"))
        XCTAssertEqual(paths1, paths2)
    }

    func testHashable_differentPath_notEqual() {
        let paths1 = NTMSPaths(workFolderRoot: URL(fileURLWithPath: "/Users/test/Project1"))
        let paths2 = NTMSPaths(workFolderRoot: URL(fileURLWithPath: "/Users/test/Project2"))
        XCTAssertNotEqual(paths1, paths2)
    }
}
