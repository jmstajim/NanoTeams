import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **switching the ACTIVE task's team mid-run**
/// — Supervisor looks at a running task, realizes they picked the wrong
/// team, and changes it via the team picker. Tests the full `switchTeam`
/// workflow that writes the new `activeTeamID`, pauses the engine if
/// active, updates the task's `preferredTeamID`, and rebuilds roleStatuses
/// for the new team.
///
/// Note: this complements `EndToEndTeamSwitchingTests` (which covers
/// `mutateWorkFolder { proj.setActiveTeam }` — the Settings-level swap
/// that doesn't touch the task). `switchTeam` is the task-coupled swap.
///
/// Pinned behaviors:
/// 1. switchTeam updates both workFolder.activeTeamID AND
///    task.preferredTeamID.
/// 2. Active task's run.roleStatuses is recomputed for the new team.
/// 3. Steps for roles not in the new team are removed from the run.
/// 4. Steps for roles still in the new team are preserved.
/// 5. Unknown team ID is a silent no-op.
/// 6. Switching to the currently active team is idempotent.
/// 7. If engine was running, switchTeam pauses it first (cancels in-flight).
@MainActor
final class EndToEndSwitchTeamOnRunningTaskTests: NTMSOrchestratorTestBase {

    // MARK: - Scenario 1: Updates both work-folder and task pointers

    func testSwitchTeam_updatesWorkFolderAndTaskPointers() async {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }
        let team1ID = teams[0].id
        let team2ID = teams[1].id

        await sut.mutateWorkFolder { proj in proj.setActiveTeam(team1ID) }

        let taskID = await sut.createTask(title: "T", supervisorTask: "x",
                                           preferredTeamID: team1ID)!
        await sut.switchTask(to: taskID)

        await sut.switchTeam(to: team2ID)

        XCTAssertEqual(sut.workFolder?.activeTeamID, team2ID,
                       "switchTeam must update work-folder activeTeamID")
        XCTAssertEqual(sut.activeTask?.preferredTeamID, team2ID,
                       "switchTeam must update the active task's preferredTeamID")
    }

    // MARK: - Scenario 2: Unknown team ID is a silent no-op

    func testSwitchTeam_unknownID_noop() async {
        await sut.openWorkFolder(tempDir)
        guard let original = sut.workFolder?.activeTeamID else { return XCTFail() }
        let taskID = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.switchTask(to: taskID)
        let originalTaskPreferred = sut.activeTask?.preferredTeamID

        await sut.switchTeam(to: "ghost_team_id")

        XCTAssertEqual(sut.workFolder?.activeTeamID, original,
                       "Unknown team ID must not change work-folder state")
        XCTAssertEqual(sut.activeTask?.preferredTeamID, originalTaskPreferred,
                       "Unknown team ID must not change task state either")
    }

    // MARK: - Scenario 3: Idempotent on same team

    func testSwitchTeam_sameTeam_roleStatusesStillRebuild() async {
        await sut.openWorkFolder(tempDir)
        guard let activeID = sut.workFolder?.activeTeamID else { return XCTFail() }

        let taskID = await sut.createTask(title: "T", supervisorTask: "x",
                                           preferredTeamID: activeID)!
        await sut.switchTask(to: taskID)

        // Seed some run state
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [], roleStatuses: ["stale_role": .done])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        await sut.switchTeam(to: activeID)

        // Run should still exist, role statuses recomputed for active team
        XCTAssertNotNil(sut.activeTask?.runs.last)
        let stale = sut.activeTask?.runs.last?.roleStatuses["stale_role"]
        XCTAssertNil(stale,
                     "switchTeam always rebuilds roleStatuses — stale key gone even for same team")
    }

    // MARK: - Scenario 4: Steps for roles not in new team are dropped

    func testSwitchTeam_dropsStepsForRolesNotInNewTeam() async throws {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }
        let team1 = teams[0]
        let team2 = teams[1]

        let taskID = await sut.createTask(title: "T", supervisorTask: "x",
                                           preferredTeamID: team1.id)!
        await sut.switchTask(to: taskID)

        // Add a step for a role that exists in team1 but not team2
        let team1OnlyRoles = team1.roles.map(\.id).filter { rid in
            !team2.roles.contains(where: { $0.id == rid })
        }
        guard let doomedRoleID = team1OnlyRoles.first else {
            // Teams have overlapping roles — skip the test rather than fabricate
            throw XCTSkip("Teams 0 and 1 share all roles — can't test step-drop semantics")
        }

        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: doomedRoleID, role: .softwareEngineer,
                title: "Doomed", status: .pending
            )
            var run = Run(id: 0, steps: [step], roleStatuses: [doomedRoleID: .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        await sut.switchTeam(to: team2.id)

        let survivingStepIDs = Set(sut.activeTask?.runs.last?.steps.map(\.id) ?? [])
        XCTAssertFalse(survivingStepIDs.contains(doomedRoleID),
                       "Step for role `\(doomedRoleID)` not in team2 must be dropped")
    }

    // MARK: - Scenario 5: Steps preserved for overlapping roles

    func testSwitchTeam_preservesStepsForRolesInBothTeams() async throws {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }
        let team1 = teams[0]
        let team2 = teams[1]

        // Find a role in BOTH teams
        let sharedRoleIDs = team1.roles.map(\.id).filter { rid in
            team2.roles.contains(where: { $0.id == rid })
        }
        guard let sharedRoleID = sharedRoleIDs.first else {
            throw XCTSkip("No shared role between teams 0 and 1")
        }

        let taskID = await sut.createTask(title: "T", supervisorTask: "x",
                                           preferredTeamID: team1.id)!
        await sut.switchTask(to: taskID)

        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: sharedRoleID, role: .softwareEngineer,
                title: "Shared", status: .done
            )
            var run = Run(id: 0, steps: [step],
                          roleStatuses: [sharedRoleID: .done])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        await sut.switchTeam(to: team2.id)

        let survivingStepIDs = Set(sut.activeTask?.runs.last?.steps.map(\.id) ?? [])
        XCTAssertTrue(survivingStepIDs.contains(sharedRoleID),
                      "Step for shared role must survive team switch")
    }

    // MARK: - Scenario 6: No active task — updates work folder only

    func testSwitchTeam_noActiveTask_updatesWorkFolderOnly() async {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }

        await sut.switchTask(to: nil)
        XCTAssertNil(sut.activeTaskID)

        await sut.switchTeam(to: teams[1].id)

        XCTAssertEqual(sut.workFolder?.activeTeamID, teams[1].id,
                       "Work-folder active team must update even without active task")
    }

    // MARK: - Scenario 7: Persists across restart

    func testSwitchTeam_persistsAcrossRestart() async {
        await sut.openWorkFolder(tempDir)
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }
        let newID = teams[1].id

        let taskID = await sut.createTask(title: "T", supervisorTask: "x",
                                           preferredTeamID: teams[0].id)!
        await sut.switchTask(to: taskID)
        await sut.switchTeam(to: newID)

        // Restart
        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: taskID)

        XCTAssertEqual(sut.workFolder?.activeTeamID, newID)
        XCTAssertEqual(sut.activeTask?.preferredTeamID, newID,
                       "Task's preferredTeamID persists the switch across restart")
    }
}
