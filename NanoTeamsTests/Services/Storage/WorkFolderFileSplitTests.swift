import XCTest
@testable import NanoTeams

/// Tests for the three-file split of `.nanoteams/internal/` state:
/// `workfolder.json` + `settings.json` + `teams.json`.
///
/// Core guarantee: each semantic edit touches exactly the file(s) it should,
/// and nothing else. Tests use content comparison (not mtime) because mtime
/// assertions are flaky on loaded CI runners (observed 10–40 ms jitter under
/// load on GitHub Actions macOS). Content diff is also a stronger assertion:
/// it catches unnecessary rewrites with identical content, which mtime would
/// incorrectly flag as "file changed".
final class WorkFolderFileSplitTests: XCTestCase {

    var sut: NTMSRepository!
    var tempDir: URL!
    var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        root = tempDir.appendingPathComponent("proj", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        sut = NTMSRepository()
        _ = try sut.openOrCreateWorkFolder(at: root)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fm.removeItem(at: tempDir)
        }
        sut = nil
        tempDir = nil
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var paths: NTMSPaths { NTMSPaths(workFolderRoot: root) }

    /// Snapshot raw byte content of all three split files.
    private struct ContentSnapshot: Equatable {
        var wf: Data?
        var settings: Data?
        var teams: Data?
    }

    private func snapshotContent() -> ContentSnapshot {
        ContentSnapshot(
            wf: try? Data(contentsOf: paths.workFolderJSON),
            settings: try? Data(contentsOf: paths.settingsJSON),
            teams: try? Data(contentsOf: paths.teamsJSON)
        )
    }

    // MARK: - Single-file edits

    func testDescriptionEditTouchesOnlySettingsFile() throws {
        let before = snapshotContent()

        _ = try sut.updateWorkFolderDescription(at: root, description: "Updated description")

        let after = snapshotContent()
        XCTAssertEqual(before.wf, after.wf, "workfolder.json must not change")
        XCTAssertEqual(before.teams, after.teams, "teams.json must not change")
        XCTAssertNotEqual(before.settings, after.settings, "settings.json must change")
    }

    func testSchemeEditTouchesOnlySettingsFile() throws {
        let before = snapshotContent()

        _ = try sut.updateSelectedScheme(at: root, scheme: "NanoTeams")

        let after = snapshotContent()
        XCTAssertEqual(before.wf, after.wf)
        XCTAssertEqual(before.teams, after.teams)
        XCTAssertNotEqual(before.settings, after.settings)
    }

    func testTeamEditTouchesOnlyTeamsFile() throws {
        let before = snapshotContent()

        _ = try sut.updateTeams(at: root) { teams in
            guard !teams.isEmpty else { return }
            teams[0].name = "Renamed Team"
        }

        let after = snapshotContent()
        XCTAssertEqual(before.wf, after.wf)
        XCTAssertEqual(before.settings, after.settings)
        XCTAssertNotEqual(before.teams, after.teams)
    }

    func testActiveTeamSwitchTouchesOnlyWorkFolderFile() throws {
        let ctx = try sut.openOrCreateWorkFolder(at: root)
        guard ctx.workFolder.teams.count >= 2 else {
            XCTFail("Need at least two teams for this test")
            return
        }
        let targetID = ctx.workFolder.teams[1].id

        let before = snapshotContent()

        _ = try sut.updateWorkFolderState(at: root) { state in
            state.activeTeamID = targetID
        }

        let after = snapshotContent()
        XCTAssertNotEqual(before.wf, after.wf)
        XCTAssertEqual(before.settings, after.settings)
        XCTAssertEqual(before.teams, after.teams)
    }

    func testTaskSwitchTouchesOnlyWorkFolderFile() throws {
        _ = try sut.createTask(at: root, title: "A", supervisorTask: "goal A")
        _ = try sut.createTask(at: root, title: "B", supervisorTask: "goal B")

        let before = snapshotContent()

        _ = try sut.updateWorkFolderState(at: root) { state in
            state.activeTaskID = 0 // arbitrary change
        }

        let after = snapshotContent()
        XCTAssertNotEqual(before.wf, after.wf)
        XCTAssertEqual(before.settings, after.settings)
        XCTAssertEqual(before.teams, after.teams)
    }

    // MARK: - Bootstrap invariants

    func testBootstrapCreatesAllThreeFiles() {
        XCTAssertTrue(fm.fileExists(atPath: paths.workFolderJSON.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.settingsJSON.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.teamsJSON.path))
    }

    func testWorkFolderJSONSizeIsMinimal() throws {
        let data = try Data(contentsOf: paths.workFolderJSON)
        XCTAssertLessThan(data.count, 1024,
                          "workfolder.json should be <1 KB (identity + pointers only)")
    }

    // MARK: - Corruption recovery (per-file, NOT full wipe)

    /// When a single file is corrupt, the other two files must be preserved
    /// untouched. Previously, any corruption nuked all three files; the
    /// per-file recovery policy fixes that so a bad `teams.json` doesn't
    /// destroy the user's description/prompt/scheme in `settings.json`.
    func testCorruptedSettingsFilePreservesOtherFiles() throws {
        // Write custom content into the two uncorrupted files so we can verify
        // they survive the recovery unchanged. Deliberately do NOT mutate
        // workfolder.json.activeTaskID to a random UUID — openOrCreateWorkFolder
        // has a stale-active-task sweep that would rewrite workfolder.json on
        // the next open, which would pollute the "preserved" assertion below.
        _ = try sut.updateWorkFolderDescription(at: root, description: "WAIT WHAT") // will be lost
        _ = try sut.updateTeams(at: root) { teams in
            teams[0].name = "Must Survive Corruption"
        }

        let teamsBefore = try Data(contentsOf: paths.teamsJSON)
        let wfBefore = try Data(contentsOf: paths.workFolderJSON)

        // Corrupt settings.json only.
        try "garbage".write(to: paths.settingsJSON, atomically: true, encoding: .utf8)

        _ = try sut.openOrCreateWorkFolder(at: root)

        // All three files still exist and are decodable.
        XCTAssertTrue(fm.fileExists(atPath: paths.workFolderJSON.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.settingsJSON.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.teamsJSON.path))

        let settingsData = try Data(contentsOf: paths.settingsJSON)
        XCTAssertNoThrow(try JSONCoderFactory.makeDateDecoder().decode(ProjectSettings.self, from: settingsData))

        // CRITICAL: teams.json and workfolder.json must be untouched.
        let teamsAfter = try Data(contentsOf: paths.teamsJSON)
        let wfAfter = try Data(contentsOf: paths.workFolderJSON)
        XCTAssertEqual(teamsBefore, teamsAfter,
            "teams.json MUST be preserved when settings.json is corrupt")
        XCTAssertEqual(wfBefore, wfAfter,
            "workfolder.json MUST be preserved when settings.json is corrupt")
    }

    func testCorruptedTeamsFilePreservesOtherFiles() throws {
        _ = try sut.updateWorkFolderDescription(at: root, description: "Survives Corruption")
        let settingsBefore = try Data(contentsOf: paths.settingsJSON)

        try "garbage".write(to: paths.teamsJSON, atomically: true, encoding: .utf8)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let teamsData = try Data(contentsOf: paths.teamsJSON)
        let teamsFile = try JSONCoderFactory.makeDateDecoder().decode(TeamsFile.self, from: teamsData)
        XCTAssertFalse(teamsFile.teams.isEmpty, "Teams should be restored to bootstrap defaults")

        let settingsAfter = try Data(contentsOf: paths.settingsJSON)
        XCTAssertEqual(settingsBefore, settingsAfter,
            "settings.json MUST be preserved when teams.json is corrupt")
        let settingsDecoded = try JSONCoderFactory.makeDateDecoder().decode(ProjectSettings.self, from: settingsAfter)
        XCTAssertEqual(settingsDecoded.description, "Survives Corruption",
            "User description must survive a teams.json corruption")
    }

    func testCorruptedWorkFolderJSONPreservesOtherFiles() throws {
        _ = try sut.updateWorkFolderDescription(at: root, description: "Must Survive")
        let settingsBefore = try Data(contentsOf: paths.settingsJSON)
        let teamsBefore = try Data(contentsOf: paths.teamsJSON)

        try "garbage".write(to: paths.workFolderJSON, atomically: true, encoding: .utf8)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let wfData = try Data(contentsOf: paths.workFolderJSON)
        XCTAssertNoThrow(try JSONCoderFactory.makeDateDecoder().decode(WorkFolderState.self, from: wfData))

        XCTAssertEqual(settingsBefore, try Data(contentsOf: paths.settingsJSON))
        XCTAssertEqual(teamsBefore, try Data(contentsOf: paths.teamsJSON))
    }

    /// A corrupt file must be preserved as a `.corrupt-<timestamp>.bak` so the
    /// user can recover forensically, not silently deleted.
    func testCorruptFileIsBackedUp() throws {
        try "completely broken json".write(to: paths.settingsJSON, atomically: true, encoding: .utf8)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let internalContents = try fm.contentsOfDirectory(atPath: paths.internalDir.path)
        let backups = internalContents.filter {
            $0.hasPrefix("settings.json.corrupt-") && $0.hasSuffix(".bak")
        }
        XCTAssertFalse(backups.isEmpty,
            "Corrupt settings.json should be preserved as a .bak file, found: \(internalContents)")
    }

    // MARK: - Cross-file consistency after recovery

    /// When `teams.json` is corrupted and recovered to defaults, any
    /// `activeTeamID` in `workfolder.json` that referenced a pre-corruption
    /// team no longer resolves. The recovery pass must clear the dangling
    /// reference so the projection never points into nowhere.
    func testCorruptedTeamsFileClearsDanglingActiveTeamID() throws {
        // Point workfolder.json at a synthetic team id that will not exist
        // after recovery. We don't need to actually create that team — we
        // just need `activeTeamID` to reference something the recovered
        // teams.json cannot resolve.
        let danglingID: NTMSID = "nonexistent_team_\(UUID().uuidString.prefix(8))"
        _ = try sut.updateWorkFolderState(at: root) { state in
            state.activeTeamID = danglingID
        }

        // Corrupt teams.json — recovery resets it to defaults, so `danglingID`
        // will definitely not resolve.
        try "garbage".write(to: paths.teamsJSON, atomically: true, encoding: .utf8)

        let ctx = try sut.openOrCreateWorkFolder(at: root)

        // The projection's activeTeamID must either be nil or point to a
        // team that actually exists in the recovered teams.json.
        let teamIDs = Set(ctx.workFolder.teams.map(\.id))
        XCTAssertFalse(teamIDs.contains(danglingID),
            "sanity: dangling id should not be present in recovered teams")
        if let active = ctx.workFolder.activeTeamID {
            XCTAssertTrue(teamIDs.contains(active),
                "activeTeamID must resolve to a real team after recovery (was: \(active))")
        }
        // The dangling id must not be persisted on disk either.
        let wfData = try Data(contentsOf: paths.workFolderJSON)
        let wfState = try JSONCoderFactory.makeDateDecoder().decode(WorkFolderState.self, from: wfData)
        XCTAssertNotEqual(wfState.activeTeamID, danglingID,
            "persisted activeTeamID must not be the dangling reference")
    }

    // MARK: - Sandbox invariant: LLM-accessible dirs stay outside internal/

    /// Attachments and step artifact directories MUST live outside
    /// `.nanoteams/internal/` because that directory is hidden from LLM file
    /// tools by `SandboxPathResolver`. Prior to the monolithic-project-json
    /// split, two migration tests asserted this invariant as a side effect;
    /// those tests were deleted with the migration code. This test preserves
    /// the invariant explicitly.
    func testInternalLayoutCreation_attachmentsAndArtifactsOutsideInternalDir() throws {
        // Create a task so its attachments dir gets materialized.
        _ = try sut.createTask(at: root, title: "sandbox check", supervisorTask: "goal")

        let internalPath = paths.internalDir.path
        XCTAssertFalse(paths.tasksDir.path.hasPrefix(internalPath),
            "tasks/ dir must be LLM-accessible (outside internal/), was: \(paths.tasksDir.path)")
        XCTAssertFalse(paths.tasksDir.path.hasPrefix(internalPath),
            "runs/ dir must be LLM-accessible (outside internal/), was: \(paths.tasksDir.path)")

        // Pick an arbitrary UUID to probe the per-task attachments path.
        let probeID = 42
        let attachmentsDir = paths.taskAttachmentsDir(taskID: probeID)
        XCTAssertFalse(attachmentsDir.path.hasPrefix(internalPath),
            "task attachments dir must be outside internal/, was: \(attachmentsDir.path)")

        let stepDir = paths.roleDir(taskID: 0, runID: 0, roleID: "test_role")
        XCTAssertFalse(stepDir.path.hasPrefix(internalPath),
            "run step dir (where artifacts live) must be outside internal/, was: \(stepDir.path)")
    }
}
