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
/// 4. Steps for roles still in the roster are preserved. Reachable only via a same-team
///    switch — no two teams can share a role id, since every path that mints one derives
///    it from the owning team's name (see Scenario 5).
/// 5. Unknown team ID is a silent no-op.
/// 6. Switching to the currently active team is idempotent.
/// 7. If engine was running, switchTeam pauses it first (cancels in-flight).
@MainActor
final class EndToEndSwitchTeamOnRunningTaskTests: NTMSOrchestratorTestBase, @unchecked Sendable {

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

    // MARK: - Scenario 5: Steps preserved for roles still in the roster

    /// The keep-branch of `TeamSwitchPlanner.filteredSteps`, reached the only way production
    /// can reach it: re-selecting the team the task is ALREADY on.
    ///
    /// This test used to look for a role id present in two different teams and
    /// `XCTSkip("No shared role between teams 0 and 1")` when it found none. It found none on
    /// every run ever: a template role id is `NTMSID.from(name: "\(teamSeed):\(roleName)")` and
    /// `teamSeed` is derived from the team NAME, so two distinct teams cannot collide — and
    /// every other way a team enters a folder re-mints the ids the same way (`Team.duplicate`
    /// from the copy's name, `TeamImportExportService.importTeam` from the import's name,
    /// custom roles from a fresh UUID). Measured across `Team.defaultTeams`: zero sharing pairs,
    /// with a self-intersection control proving the check could report one. So the scenario the
    /// old test described does not exist, and the skip reason — which read as a property of
    /// teams 0 and 1 — hid that it could never be satisfied by ANY pair.
    ///
    /// A same-team switch is not a degenerate stand-in: `switchTeam` has no same-team early
    /// return (see `testSwitchTeam_sameTeam_roleStatusesStillRebuild`, which pins that the
    /// status map is rebuilt anyway), so the whole path runs and `filteredSteps` is handed the
    /// full roster. It is also the only assertion here of step PRESENCE — Scenario 4 asserts
    /// absence, and the two catch opposite mutations: gutting `filteredSteps` to `[]` is
    /// invisible to Scenario 4, and dropping the filter entirely is invisible to this one.
    func testSwitchTeam_sameTeam_preservesStepsForRolesStillInRoster() async throws {
        await sut.openWorkFolder(tempDir)
        guard let team = sut.workFolder?.activeTeam else { return XCTFail("Need an active team") }
        let keptRoleID = try XCTUnwrap(
            team.nonSupervisorRoles.first?.id,
            "fixture precondition: the active team must have a non-Supervisor role to keep")

        let taskID = await sut.createTask(title: "T", supervisorTask: "x",
                                          preferredTeamID: team.id)!
        await sut.switchTask(to: taskID)

        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: keptRoleID, role: .softwareEngineer,
                title: "Kept", status: .done
            )
            var run = Run(id: 0, steps: [step],
                          roleStatuses: [keptRoleID: .done])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        await sut.switchTeam(to: team.id)

        let surviving = try XCTUnwrap(sut.activeTask?.runs.last?.steps)
        XCTAssertTrue(surviving.map(\.id).contains(keptRoleID),
                      "step for a role still in the roster must survive the switch")
        XCTAssertEqual(surviving.count, 1,
                       "the switch must preserve the step, not duplicate or re-seed it")
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
        sut = TestOrchestrator.make()
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: taskID)

        XCTAssertEqual(sut.workFolder?.activeTeamID, newID)
        XCTAssertEqual(sut.activeTask?.preferredTeamID, newID,
                       "Task's preferredTeamID persists the switch across restart")
    }
}
