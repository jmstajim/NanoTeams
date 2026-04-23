import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **switching the active team**.
///
/// Covered scenarios:
/// 1. Switch active team → `activeTeamID` updates and persists.
/// 2. Switch to an unknown team ID → no-op (state unchanged).
/// 3. Switch to the current active team → idempotent.
/// 4. Each task captures `preferredTeamID` at creation time; changing
///    the work-folder active team later does NOT retroactively re-assign
///    already-created tasks.
/// 5. Creating a new task AFTER switching teams uses the new team.
/// 6. Deleting the currently-active team reassigns activeTeamID to a
///    remaining team (WorkFolderProjection.removeTeam invariant) —
///    the active team pointer must never dangle.
/// 7. Switching to a custom (non-template) team persists normally.
@MainActor
final class EndToEndTeamSwitchingTests: NTMSOrchestratorTestBase {

    // MARK: - Scenario 1: Switch active team updates activeTeamID

    func testSwitch_updatesActiveTeamID() async {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Bootstrap must produce ≥ 2 teams")
        }
        let targetID = teams[1].id

        await sut.mutateWorkFolder { proj in proj.setActiveTeam(targetID) }

        XCTAssertEqual(sut.workFolder?.activeTeamID, targetID)
        XCTAssertEqual(sut.workFolder?.activeTeam?.id, targetID,
                       "activeTeam computed property must resolve to the target")
    }

    // MARK: - Scenario 2: Switch to unknown team ID is a no-op

    func testSwitch_unknownTeamID_isNoOp() async {
        await sut.openWorkFolder(tempDir)
        guard let originalID = sut.workFolder?.activeTeamID else {
            return XCTFail("Expected an initial active team after bootstrap")
        }

        await sut.mutateWorkFolder { proj in proj.setActiveTeam("nonexistent_team_id") }

        XCTAssertEqual(sut.workFolder?.activeTeamID, originalID,
                       "Switching to an unknown ID must be rejected silently")
    }

    // MARK: - Scenario 3: Switching to current team is idempotent

    func testSwitch_sameTeamID_noChange() async {
        await sut.openWorkFolder(tempDir)
        let original = sut.workFolder?.activeTeamID
        XCTAssertNotNil(original)

        await sut.mutateWorkFolder { proj in proj.setActiveTeam(original!) }

        XCTAssertEqual(sut.workFolder?.activeTeamID, original)
    }

    // MARK: - Scenario 4: preferredTeamID captured at task creation

    /// User scenario: create Task A on Team 1, switch to Team 2, create
    /// Task B — Task A must still reference Team 1.
    func testCreateTask_capturesPreferredTeam_atCreationTime() async {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }
        let team1ID = teams[0].id
        let team2ID = teams[1].id

        // Pin active team explicitly so we know what Task A's default will be
        await sut.mutateWorkFolder { proj in proj.setActiveTeam(team1ID) }

        let idA = await sut.createTask(title: "A", supervisorTask: "use team 1")!

        // Switch work-folder active team to team 2
        await sut.mutateWorkFolder { proj in proj.setActiveTeam(team2ID) }

        let idB = await sut.createTask(title: "B", supervisorTask: "use team 2")!

        // Fetch Task A — must still reference team 1
        await sut.switchTask(to: idA)
        XCTAssertEqual(sut.activeTask?.preferredTeamID, team1ID,
                       "Task A's preferredTeamID must not change retroactively")

        await sut.switchTask(to: idB)
        XCTAssertEqual(sut.activeTask?.preferredTeamID, team2ID,
                       "Task B created AFTER the switch must use team 2")
    }

    // MARK: - Scenario 5: Explicit preferredTeamID overrides active team

    func testCreateTask_withExplicitPreferredTeam_overridesActive() async {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }
        let activeID = teams[0].id
        let targetedID = teams[1].id

        await sut.mutateWorkFolder { proj in proj.setActiveTeam(activeID) }

        let taskID = await sut.createTask(
            title: "Explicit",
            supervisorTask: "use a different team",
            preferredTeamID: targetedID
        )!
        await sut.switchTask(to: taskID)

        XCTAssertEqual(sut.activeTask?.preferredTeamID, targetedID,
                       "Explicit preferredTeamID arg must override the work-folder active team")
    }

    // MARK: - Scenario 6: Removing active team reassigns pointer

    /// Settings → Teams → "Delete Team" on the currently-active team must
    /// not leave `activeTeamID` dangling at a removed team.
    func testRemoveActiveTeam_reassignsPointer() async {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }
        let doomed = teams[0]
        let doomedID = doomed.id

        await sut.mutateWorkFolder { proj in proj.setActiveTeam(doomedID) }
        XCTAssertEqual(sut.workFolder?.activeTeamID, doomedID)

        await sut.mutateWorkFolder { proj in proj.removeTeam(doomedID) }

        XCTAssertNotNil(sut.workFolder?.activeTeamID,
                        "Active team pointer must not be cleared — another team remains")
        XCTAssertNotEqual(sut.workFolder?.activeTeamID, doomedID,
                          "Active team pointer must not dangle at removed team")
        XCTAssertFalse(
            (sut.workFolder?.teams ?? []).contains { $0.id == doomedID },
            "Removed team must be gone from the teams array"
        )
    }

    // MARK: - Scenario 7: Team switch persists across reopen

    func testSwitch_persistsAcrossReopen() async {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }
        let targetID = teams[1].id

        await sut.mutateWorkFolder { proj in proj.setActiveTeam(targetID) }

        // Simulate restart
        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.workFolder?.activeTeamID, targetID,
                       "Active team selection must survive orchestrator recreation")
    }
}
