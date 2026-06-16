import XCTest
@testable import NanoTeams

/// Corner-case coverage for the roster-swap guard in
/// `NTMSOrchestrator.findOrCreateStep` (including the LEGACY branch that infers
/// the roster from `run.steps.first` when `run.teamID == nil`) and for
/// `NTMSOrchestrator.teamIsInUseByActiveRun` (which scans the in-memory
/// `tasksIndex` by `TaskSummary.pinnedTeamID`, so it sees background, delegated-child,
/// AND paused/evicted/unloaded tasks). Sibling of `NTMSOrchestratorTeamPinGuardTests`.
@MainActor
final class TeamPinGuardCornerTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        NTMSOrchestrator(repository: NTMSRepository(), searchEmbeddingClient: StubSearchEmbeddingClient())
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-pinguard-corner-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func twoTeams(_ store: NTMSOrchestrator) -> (Team, Team)? {
        let teams = (store.workFolder?.teams ?? []).filter { !$0.isManagedSingleton }
        guard teams.count >= 2 else { return nil }
        return (teams[0], teams[1])
    }

    // MARK: - LEGACY-run roster inference (run.teamID == nil)

    /// A run with NO pinned teamID that ALREADY contains a step whose role
    /// belongs to team A: the legacy branch infers the roster from that step and
    /// refuses a FOREIGN role from team B.
    func testFindOrCreateStep_legacyRun_foreignRole_blockedViaInferredRoster() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, teamB) = twoTeams(store) else { return XCTFail("need 2 teams") }
        guard let nativeRoleID = teamA.roles.first(where: { !$0.isSupervisor })?.id else {
            return XCTFail("teamA needs a non-supervisor role")
        }
        guard let foreignRoleID = teamB.roles.first(where: { !$0.isSupervisor })?.id,
              teamA.findRole(byIdentifier: foreignRoleID) == nil else {
            return XCTFail("need a teamB role absent from teamA")
        }

        let tid = await store.createTask(title: "T", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }

        // Seed an EXISTING team-A step into a run with teamID == nil, so the
        // legacy branch has an anchor role to infer the roster from.
        let anchorStep = StepExecution(id: nativeRoleID, role: .custom(id: nativeRoleID),
                                       title: "Anchor", status: .pending)
        _ = await store.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: nil)
            run.steps = [anchorStep]
            task.runs = [run]
        }
        store.lastErrorMessage = nil

        let stepID = await store.findOrCreateStep(taskID: tid, roleID: foreignRoleID)
        XCTAssertNil(stepID,
                     "Legacy run: a role outside the inferred roster must be refused")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.count, 1,
                       "No foreign-roster step may be appended (only the anchor remains)")
        XCTAssertTrue(store.lastErrorMessage?.contains("Roster swap blocked") ?? false,
                      "Legacy roster-swap refusal must surface the 'Roster swap blocked' diagnostic")
    }

    /// A run with teamID == nil and NO existing steps: the legacy branch is
    /// skipped (no anchor role to infer a roster from), so the FIRST valid role
    /// of the resolved team is allowed.
    func testFindOrCreateStep_legacyRun_firstRole_allowed() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }
        guard let nativeRoleID = teamA.roles.first(where: { !$0.isSupervisor })?.id else {
            return XCTFail("teamA needs a non-supervisor role")
        }

        let tid = await store.createTask(title: "T", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        // Empty-steps run with no pin — the legacy inference branch has no anchor.
        _ = await store.mutateTask(taskID: tid) { $0.runs = [Run(id: 0, teamID: nil)] }

        let stepID = await store.findOrCreateStep(taskID: tid, roleID: nativeRoleID)
        XCTAssertNotNil(stepID,
                        "Legacy run with no existing steps mints the first valid role (guard's legacy branch is skipped)")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.count, 1,
                       "Exactly one step is appended")
    }

    // MARK: - Pinned team deleted

    /// A run pinned to a team id that is NOT present in the work folder: any role
    /// is refused with a 'no longer exists' diagnostic (deletion guard).
    func testFindOrCreateStep_pinnedTeamDeleted_returnsNil_setsNoLongerExists() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }
        guard let nativeRoleID = teamA.roles.first(where: { !$0.isSupervisor })?.id else {
            return XCTFail("teamA needs a non-supervisor role")
        }

        let tid = await store.createTask(title: "T", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        let bogusID = NTMSID.from(name: "deleted_\(UUID().uuidString)")
        _ = await store.mutateTask(taskID: tid) { $0.runs = [Run(id: 0, teamID: bogusID)] }
        store.lastErrorMessage = nil

        let stepID = await store.findOrCreateStep(taskID: tid, roleID: nativeRoleID)
        XCTAssertNil(stepID,
                     "A run pinned to a deleted team refuses every role")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.count, 0,
                       "No step may be appended against a deleted pinned team")
        XCTAssertTrue(store.lastErrorMessage?.contains("no longer exists") ?? false,
                      "Deleted-pinned-team refusal must surface the 'no longer exists' diagnostic")
    }

    // MARK: - Existing-step early return (guard never reached)

    /// When a run already contains a step for role X, `findOrCreateStep(role X)`
    /// returns that step's id and appends nothing — the early-return precedes the
    /// guard, so even a pin-mismatch would not matter here.
    func testFindOrCreateStep_existingStep_returnsExistingID_noDuplicate() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }
        guard let nativeRoleID = teamA.roles.first(where: { !$0.isSupervisor })?.id else {
            return XCTFail("teamA needs a non-supervisor role")
        }

        let tid = await store.createTask(title: "T", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        let existing = StepExecution(id: nativeRoleID, role: .custom(id: nativeRoleID),
                                     title: "Existing", status: .pending)
        _ = await store.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: teamA.id)
            run.steps = [existing]
            task.runs = [run]
        }

        let stepID = await store.findOrCreateStep(taskID: tid, roleID: nativeRoleID)
        XCTAssertEqual(stepID, existing.id,
                       "An existing step for the role is returned by id (guard short-circuited)")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.count, 1,
                       "No duplicate step is appended for an already-present role")
    }

    // MARK: - teamIsInUseByActiveRun — background task

    /// A non-active (background) task whose run is pinned to team A and not
    /// closed keeps team A in use — `allLoadedTasksIncludingChildren` includes it.
    func testTeamIsInUseByActiveRun_backgroundTask_keepsTeamInUse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, teamB) = twoTeams(store) else { return XCTFail("need 2 teams") }

        // First task is pinned to team A, then pushed into the background by
        // creating a second (active) task.
        let bgID = await store.createTask(title: "BG", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let bgID else { return XCTFail("bg create failed") }
        let activeID = await store.createTask(title: "Active", supervisorTask: "...", preferredTeamID: teamB.id)
        guard let activeID else { return XCTFail("active create failed") }
        XCTAssertNotEqual(store.activeTaskID, bgID,
                          "Test setup: the first task must be in the background")

        _ = await store.mutateTask(taskID: bgID) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]
            task.closedAt = nil
        }

        XCTAssertTrue(store.teamIsInUseByActiveRun(teamA.id),
                      "A background task's open run keeps its pinned team in use")
        _ = activeID
    }

    // MARK: - teamIsInUseByActiveRun — delegated child task

    /// A delegated child task (parentTaskID != nil) whose run is pinned to team A
    /// keeps team A in use — children flow through
    /// `allLoadedTasksIncludingChildren`, not the top-level-only enumeration.
    func testTeamIsInUseByActiveRun_delegatedChild_keepsTeamInUse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent create failed") }
        let childID = await store.createDelegatedTask(
            parentTaskID: parentID,
            parentRoleID: "coding_agent",
            title: "Child",
            supervisorTask: "Sub-brief",
            preferredTeamID: nil,
            depth: 1
        )
        guard let childID else { return XCTFail("child create failed") }
        XCTAssertEqual(store.loadedTask(childID)?.parentTaskID, parentID,
                       "Test setup: child must be a delegated descendant")

        _ = await store.mutateTask(taskID: childID) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]
            task.closedAt = nil
        }

        XCTAssertTrue(store.teamIsInUseByActiveRun(teamA.id),
                      "A delegated child's open run keeps its pinned team in use (children are scanned)")
    }

    // MARK: - teamIsInUseByActiveRun — mixed closed/open on same team

    /// Two tasks pinned to the same team — one closed, one open — keeps the team
    /// in use; closing BOTH releases it.
    func testTeamIsInUseByActiveRun_oneClosedOneOpen_thenAllClosed() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let closedID = await store.createTask(title: "Closed", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let closedID else { return XCTFail("closed create failed") }
        let openID = await store.createTask(title: "Open", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let openID else { return XCTFail("open create failed") }

        _ = await store.mutateTask(taskID: closedID) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]
            task.closedAt = MonotonicClock.shared.now()
        }
        _ = await store.mutateTask(taskID: openID) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]
            task.closedAt = nil
        }

        XCTAssertTrue(store.teamIsInUseByActiveRun(teamA.id),
                      "The still-open task keeps the team in use despite a sibling being closed")

        _ = await store.mutateTask(taskID: openID) { task in
            task.closedAt = MonotonicClock.shared.now()
        }
        XCTAssertFalse(store.teamIsInUseByActiveRun(teamA.id),
                       "Once every pinned task is closed, the team is no longer in use")
    }

    // MARK: - teamIsInUseByActiveRun — authoritative over EVICTED (unloaded) tasks

    /// THE deletion-guard hole this fix closes: a paused/background task can be
    /// dropped from `loadedTasks` by `evictIfReclaimable`. A loaded-only scan would
    /// then report the team as "not in use" and allow a destructive delete that
    /// strands the task on resume. The index-based scan (`TaskSummary.pinnedTeamID`)
    /// stays authoritative even after eviction.
    func testTeamIsInUseByActiveRun_authoritativeAfterEviction() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, teamB) = twoTeams(store) else { return XCTFail("need 2 teams") }

        // Background task pinned to team A (open), pushed to background by a 2nd task.
        let bgID = await store.createTask(title: "BG", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let bgID else { return XCTFail("bg create failed") }
        _ = await store.mutateTask(taskID: bgID) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]
            task.closedAt = nil
        }
        let activeID = await store.createTask(title: "Active", supervisorTask: "...", preferredTeamID: teamB.id)
        guard activeID != nil else { return XCTFail("active create failed") }

        // Evict the background task (no active engine → reclaimable).
        store.evictIfReclaimable(bgID)
        XCTAssertNil(store.loadedTask(bgID),
                     "Precondition: the background task must be evicted from loadedTasks")

        XCTAssertTrue(store.teamIsInUseByActiveRun(teamA.id),
                      "Deletion guard must remain authoritative for an EVICTED (unloaded) non-closed task — the index scan sees it; a loaded-only scan would have missed it and allowed the destructive delete")
    }
}
