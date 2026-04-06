import XCTest
@testable import NanoTeams

/// Tests for the .nanoteams/internal/ layout creation on fresh work folders.
final class InternalLayoutCreationTests: XCTestCase {

    var sut: NTMSRepository!
    var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sut = NTMSRepository()
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fm.removeItem(at: tempDir)
        }
        sut = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeProjectRoot() throws -> URL {
        let root = tempDir.appendingPathComponent("proj_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Fresh Work Folder Creates Internal Layout

    func testOpenOrCreateProject_createsInternalDir() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)
        XCTAssertTrue(fm.fileExists(atPath: paths.internalDir.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.internalTasksDir.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.internalTasksDir.path))
    }

    func testOpenOrCreateProject_writesWorkFolderJSONToInternal() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)
        XCTAssertTrue(fm.fileExists(atPath: paths.workFolderJSON.path))
        XCTAssertTrue(paths.workFolderJSON.path.contains("/internal/"))
    }

    func testOpenOrCreateProject_writesSettingsJSONToInternal() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)
        XCTAssertTrue(fm.fileExists(atPath: paths.settingsJSON.path))
        XCTAssertTrue(paths.settingsJSON.path.contains("/internal/"))
    }

    func testOpenOrCreateProject_writesTeamsJSONToInternal() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)
        XCTAssertTrue(fm.fileExists(atPath: paths.teamsJSON.path))
        XCTAssertTrue(paths.teamsJSON.path.contains("/internal/"))
    }

    func testOpenOrCreateProject_writesToolsJSONToInternal() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)
        XCTAssertTrue(fm.fileExists(atPath: paths.toolsJSON.path))
        XCTAssertTrue(paths.toolsJSON.path.contains("/internal/"))
    }

    func testOpenOrCreateProject_writesTasksIndexToInternal() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)
        XCTAssertTrue(fm.fileExists(atPath: paths.tasksIndexJSON.path))
        XCTAssertTrue(paths.tasksIndexJSON.path.contains("/internal/"))
    }

    // MARK: - Permissions

    func testEnsureLayout_setsRestrictivePermissionsOnInternalDir() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)
        let attrs = try fm.attributesOfItem(atPath: paths.internalDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700, "internal/ should have owner-only permissions")

        let tasksDirAttrs = try fm.attributesOfItem(atPath: paths.internalTasksDir.path)
        let tasksPerms = (tasksDirAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(tasksPerms, 0o700, "internal/tasks/ should have owner-only permissions")
    }

    func testEnsureLayout_fixesExistingPermissions() throws {
        let root = try makeProjectRoot()
        let paths = NTMSPaths(workFolderRoot: root)

        // Pre-create with world-readable permissions (simulating existing installation)
        try fm.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.internalTasksDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.internalDir.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.internalTasksDir.path)

        // Opening project should fix permissions
        _ = try sut.openOrCreateWorkFolder(at: root)

        let attrs = try fm.attributesOfItem(atPath: paths.internalDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700, "existing internal/ permissions should be fixed to 700")
    }

    // MARK: - Gitignore

    func testEnsureLayout_createsGitignoreInProjectFolder() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let gitignoreURL = NTMSPaths(workFolderRoot: root).nanoteamsDir
            .appendingPathComponent(".gitignore")
        XCTAssertTrue(fm.fileExists(atPath: gitignoreURL.path), ".gitignore should be created")

        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        XCTAssertTrue(content.contains("internal/"), ".gitignore should exclude internal/")
    }

    func testEnsureLayout_skipsGitignoreInDefaultStorage() throws {
        // Use a path under Application Support to simulate default storage
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            XCTFail("No Application Support directory"); return
        }
        let root = appSupport
            .appendingPathComponent("NanoTeamsTest_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        _ = try sut.openOrCreateWorkFolder(at: root)

        let gitignoreURL = NTMSPaths(workFolderRoot: root).nanoteamsDir
            .appendingPathComponent(".gitignore")
        XCTAssertFalse(fm.fileExists(atPath: gitignoreURL.path),
                        ".gitignore should NOT be created in Application Support")
    }

    // MARK: - Backup & Spotlight Exclusion

    func testEnsureLayout_setsBackupExclusion() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)
        let values = try paths.internalDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true,
                        "internal/ should be excluded from Time Machine backups")
    }

    func testEnsureLayout_createsSpotlightMarker() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let marker = NTMSPaths(workFolderRoot: root).internalDir
            .appendingPathComponent(".metadata_never_index")
        XCTAssertTrue(fm.fileExists(atPath: marker.path),
                       ".metadata_never_index should exist inside internal/")
    }

    // MARK: - Task Directory Permissions

    func testCreateTask_setsPermissionsOnInternalTaskDir() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)
        _ = try sut.createTask(at: root, title: "Test", supervisorTask: "Goal")

        let taskDir = paths.internalTaskDir(taskID: 0)
        let attrs = try fm.attributesOfItem(atPath: taskDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700, "internal task dir should have owner-only permissions")
    }

    // MARK: - Staged Attachments Permissions

    func testStageAttachment_setsPermissionsOnStagedDir() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Create a file to stage
        let sourceFile = tempDir.appendingPathComponent("test_file.txt")
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let draftID = UUID()
        _ = try sut.stageAttachment(at: root, draftID: draftID, sourceURL: sourceFile)

        let paths = NTMSPaths(workFolderRoot: root)
        let draftDir = paths.stagedAttachmentDir(draftID: draftID)
        let attrs = try fm.attributesOfItem(atPath: draftDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700, "staged attachment dir should have owner-only permissions")
    }

    // MARK: - Public Directories Are NOT Restricted

    func testPublicDirs_haveDefaultPermissions() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)

        let paths = NTMSPaths(workFolderRoot: root)

        // .nanoteams/ root should be normal (not restricted)
        let rootAttrs = try fm.attributesOfItem(atPath: paths.nanoteamsDir.path)
        let rootPerms = (rootAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertNotEqual(rootPerms, 0o700, ".nanoteams/ root should NOT be owner-only")

        // .nanoteams/tasks/ (LLM-accessible) should be normal
        let tasksAttrs = try fm.attributesOfItem(atPath: paths.tasksDir.path)
        let tasksPerms = (tasksAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertNotEqual(tasksPerms, 0o700, ".nanoteams/tasks/ should NOT be owner-only")
    }

    func testPublicTaskDir_hasDefaultPermissions() throws {
        let root = try makeProjectRoot()
        _ = try sut.openOrCreateWorkFolder(at: root)
        _ = try sut.createTask(at: root, title: "Test", supervisorTask: "Goal")

        let paths = NTMSPaths(workFolderRoot: root)
        let publicTaskDir = paths.taskDir(taskID: 0)
        let attrs = try fm.attributesOfItem(atPath: publicTaskDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertNotEqual(perms, 0o700, "public task dir should NOT be owner-only")
    }

    // MARK: - Gitignore Preserves Existing

    func testEnsureLayout_doesNotOverwriteExistingGitignore() throws {
        let root = try makeProjectRoot()
        let paths = NTMSPaths(workFolderRoot: root)
        let gitignoreURL = paths.nanoteamsDir.appendingPathComponent(".gitignore")

        // Pre-create .nanoteams/ and a custom .gitignore
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let customContent = "# Custom gitignore\n*\n"
        try customContent.write(to: gitignoreURL, atomically: true, encoding: .utf8)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        XCTAssertEqual(content, customContent, "existing .gitignore should not be overwritten")
    }

    // MARK: - Orphan Cleanup

    func testOpenOrCreateProject_removesLegacyProjectJSON() throws {
        let root = try makeProjectRoot()
        let nanoteamsDir = root.appendingPathComponent(".nanoteams", isDirectory: true)
        let internalDir = nanoteamsDir.appendingPathComponent("internal", isDirectory: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)

        // Pre-seed a legacy project.json (monolithic file from pre-split schema)
        let legacyProjectJSON = internalDir.appendingPathComponent("project.json")
        try "{}".write(to: legacyProjectJSON, atomically: true, encoding: .utf8)
        XCTAssertTrue(fm.fileExists(atPath: legacyProjectJSON.path))

        _ = try sut.openOrCreateWorkFolder(at: root)

        // Legacy file must be cleaned up during bootstrap
        XCTAssertFalse(fm.fileExists(atPath: legacyProjectJSON.path),
                       "Legacy project.json should be removed on bootstrap")
    }
}
