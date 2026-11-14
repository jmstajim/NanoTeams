import SwiftUI
import XCTest
@testable import NanoTeams

/// The Team Editor's own write actions — Delete, Restore Default Teams, Duplicate, Import, New
/// Team, a team picked in the selector — against a real orchestrator and the disk
/// (2026-11-08 review, finding 4).
///
/// They dropped `mutateWorkFolder`'s outcome, so a refused write reached only the error banner of
/// the MAIN window, behind Settings — the window the person was working in showed nothing. Each
/// write is now a static function of `TeamEditorView` that records a refusal in
/// `TeamEditCommitQueue.perform`, which the editor's banner reads
/// (`TeamEditorView.bannerIssues` → `TeamEditorValidation.bannerIssues`). These tests read the
/// banner rows the same way.
@MainActor
final class TeamEditorActionsTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var otherDir: URL!
    private var repo: SelectivelyFailingRepository!
    private var sut: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = Self.makeDir("team-editor-actions")
        otherDir = Self.makeDir("team-editor-actions-other")
        repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(repository: repo)
        await sut.openWorkFolder(tempDir)
    }

    override func tearDown() async throws {
        await sut?.teamEdits.settleAll()
        sut?.stopAllEngines()
        sut = nil
        repo = nil
        for dir in [tempDir, otherDir].compactMap({ $0 }) { try? FileManager.default.removeItem(at: dir) }
        tempDir = nil
        otherDir = nil
        try await super.tearDown()
    }

    // MARK: - A refused action is in the editor's banner

    /// RED: let `deleteTeam` call `mutateWorkFolder` beside `perform` (the pre-fix handler, which
    /// read no outcome) → no row for the refusal; the team is deleted nowhere either way.
    func testARefusedDelete_isARowInTheEditorsBanner() async throws {
        let startup = try startupTeam()
        repo.failUpdateTeams = true

        let outcome = await TeamEditorView.deleteTeam(startup, in: sut, editedIn: sut.currentFolderLifecycle)

        try assertRefusal(outcome, touching: "teams.json")
        XCTAssertTrue(sut.workFolder?.teams.contains { $0.id == startup.id } == true, "nothing was deleted")
    }

    /// A team a task runs on cannot be deleted — and the editor says so, not only the main window.
    ///
    /// RED: refuse in the handler with `lastErrorMessage` alone (the pre-fix check) → no row.
    func testADeleteOfATeamATaskRunsOn_isRefused_inTheEditorsBanner() async throws {
        let startup = try startupTeam()
        let created = await sut.createTask(title: "Runs on Startup", supervisorTask: "…", preferredTeamID: startup.id)
        let taskID = try XCTUnwrap(created)
        // A run on Startup — what pins a task to a team (`TeamIsInUseByActiveRunCornerTests`).
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, teamID: startup.id)]
            task.closedAt = nil
        }
        XCTAssertTrue(sut.teamIsInUseByActiveRun(startup.id), "precondition: Startup backs a live task")
        let teamsBefore = try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).teamsJSON)

        let outcome = await TeamEditorView.deleteTeam(startup, in: sut, editedIn: sut.currentFolderLifecycle)

        try assertRefusal(outcome, touching: startup.name)
        XCTAssertEqual(try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).teamsJSON), teamsBefore)
    }

    func testARefusedRestoreOfTheDefaultTeams_isARowInTheEditorsBanner() async throws {
        let startup = try startupTeam()
        await sut.mutateWorkFolder { projection in
            guard let index = projection.teams.firstIndex(where: { $0.id == startup.id }) else { return }
            projection.teams[index].description = "changed, so the restore has something to write"
        }
        repo.failUpdateTeams = true

        let outcome = await TeamEditorView.restoreDefaultTeams(in: sut, editedIn: sut.currentFolderLifecycle)

        try assertRefusal(outcome, touching: "teams.json")
    }

    func testARefusedDuplicate_isARowInTheEditorsBanner() async throws {
        let startup = try startupTeam()
        repo.failUpdateTeams = true

        let outcome = await TeamEditorView.duplicateTeam(startup, in: sut, editedIn: sut.currentFolderLifecycle)

        try assertRefusal(outcome, touching: "teams.json")
        XCTAssertFalse(sut.workFolder?.teams.contains { $0.name == "\(startup.name) Copy" } ?? true)
    }

    func testARefusedImport_isARowInTheEditorsBanner() async throws {
        repo.failUpdateTeams = true

        let outcome = await TeamEditorView.importTeam(
            TeamTemplateFactory.empty(name: "Imported Team"), in: sut, editedIn: sut.currentFolderLifecycle)

        try assertRefusal(outcome, touching: "teams.json")
    }

    func testARefusedNewTeam_isARowInTheEditorsBanner() async throws {
        repo.failUpdateTeams = true

        let outcome = await TeamEditorView.createTeam(
            name: "Brand New", templateID: TeamTemplateFactory.emptyTemplateID, in: sut,
            editedIn: sut.currentFolderLifecycle)

        try assertRefusal(outcome, touching: "teams.json")
    }

    /// Picking a team writes `workfolder.json`, not `teams.json`.
    func testARefusedTeamPick_isARowInTheEditorsBanner() async throws {
        let startup = try startupTeam()
        repo.failUpdateWorkFolderState = true

        let outcome = await TeamEditorView.selectTeam(startup.id, in: sut, editedIn: sut.currentFolderLifecycle)

        try assertRefusal(outcome, touching: "workfolder.json")
    }

    /// The row stays until the next action lands, then goes.
    func testTheRow_goesWhenTheNextActionLands() async throws {
        let startup = try startupTeam()
        let lifecycle = sut.currentFolderLifecycle
        repo.failUpdateTeams = true
        _ = await TeamEditorView.duplicateTeam(startup, in: sut, editedIn: lifecycle)
        XCTAssertNotNil(sut.teamEdits.actionFailure(editedIn: lifecycle))

        repo.failUpdateTeams = false
        let outcome = await TeamEditorView.duplicateTeam(startup, in: sut, editedIn: lifecycle)

        XCTAssertNil(outcome.failureReason)
        XCTAssertNil(sut.teamEdits.actionFailure(editedIn: lifecycle))
        XCTAssertTrue(bannerRows(in: lifecycle).isEmpty)
    }

    // MARK: - An action stays in the folder it began in

    /// Delete clicked in folder A, written after folder B opened — B's Startup team has the same
    /// id. Nothing is deleted there.
    ///
    /// RED: drop the lifecycle guard in `TeamEditorView.write` → B's Startup team is deleted.
    func testADelete_begunInAFolderThatIsNoLongerOpen_deletesNothing() async throws {
        let startup = try startupTeam()
        let folderA = sut.currentFolderLifecycle
        await sut.openWorkFolder(otherDir)
        let teamsBefore = try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON)
        XCTAssertTrue(sut.workFolder?.teams.contains { $0.id == startup.id } == true,
                      "precondition: folder B has a team with the same id")

        let outcome = await TeamEditorView.deleteTeam(startup, in: sut, editedIn: folderA)

        XCTAssertEqual(outcome, .failed(reason: TeamEditCommitQueue.actionFolderChangedReason))
        XCTAssertEqual(try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON), teamsBefore)
        XCTAssertNil(sut.teamEdits.actionFailure(editedIn: sut.currentFolderLifecycle),
                     "folder A's refusal is not folder B's banner")
    }

    // MARK: - Helpers

    private func startupTeam() throws -> Team {
        try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
    }

    /// The editor banner's rows as `TeamEditorView.bannerIssues` builds them, with no write failure
    /// and no validation: only the actions'.
    private func bannerRows(in lifecycle: WorkFolderLifecycle) -> [TeamEditorValidation.Issue] {
        TeamEditorValidation.bannerIssues(
            writeFailure: nil, actionFailure: sut.teamEdits.actionFailure(editedIn: lifecycle), validation: [])
    }

    private func assertRefusal(
        _ outcome: WorkFolderMutationOutcome, touching file: String,
        line: UInt = #line
    ) throws {
        let reason = try XCTUnwrap(outcome.failureReason, "the write must be refused", line: line)
        XCTAssertTrue(reason.contains(file), reason, line: line)
        let lifecycle = sut.currentFolderLifecycle
        XCTAssertEqual(sut.teamEdits.actionFailure(editedIn: lifecycle), reason, line: line)
        let rows = bannerRows(in: lifecycle)
        XCTAssertEqual(rows.map(\.message), [reason], "the editor's banner must say why", line: line)
        XCTAssertEqual(rows.first?.isError, true, line: line)
    }

    private static func makeDir(_ prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
