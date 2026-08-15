import XCTest
@testable import NanoTeams

/// Net-new corner cases for `NTMSOrchestrator.teamIsInUseByActiveRun`, the
/// in-use-by-active-run deletion guard that scans `snapshot.tasksIndex.tasks`
/// by `TaskSummary.pinnedTeamID == teamID && status != .done`.
///
/// `TeamPinGuardCornerTests` / `NTMSOrchestratorTeamPinGuardTests` already cover
/// background, delegated-child, mixed-closed/open, and evicted-task authority.
/// THIS file covers the orthogonal contract corners: empty index, wrong-team
/// query, the no-pin (`teamID == nil`) summary, the closed-derived (`.done`)
/// proxy, two distinct pinned teams, and the pure-id-equality semantics for a
/// synthetic (generated-team) pin that isn't present in `workFolder.teams`.
@MainActor
final class TeamIsInUseByActiveRunCornerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    private func makeOrchestrator() -> NTMSOrchestrator {
        TestOrchestrator.make()
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-teaminuse-corner-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Real (non-managed-singleton) teams in the folder.
    private func realTeams(_ store: NTMSOrchestrator) -> [Team] {
        (store.workFolder?.teams ?? []).filter { !$0.isManagedSingleton }
    }

    private func twoTeams(_ store: NTMSOrchestrator) -> (Team, Team)? {
        let teams = realTeams(store)
        guard teams.count >= 2 else { return nil }
        return (teams[0], teams[1])
    }

    /// Fetch the index summary for a task id (the scan source for the guard).
    private func summary(_ store: NTMSOrchestrator, _ taskID: Int) -> TaskSummary? {
        store.snapshot?.tasksIndex.tasks.first { $0.id == taskID }
    }

    // MARK: - Empty / no-user-task index

    /// A freshly opened work folder with NO user task pinning a given real team:
    /// the guard reports that team as not in use. (Opening may seed internal
    /// manager tasks, but none of them pins a freshly-fetched user team.)
    func testNoUserTasks_realTeamNotPinned_isFalse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let team = realTeams(store).first else { return XCTFail("need >= 1 real team") }

        XCTAssertFalse(store.teamIsInUseByActiveRun(team.id),
                       "A real team that no user task pins must NOT be reported in use on a fresh folder")
    }

    // MARK: - Wrong-team query

    /// A task pinned to team A does not put team B in use — id equality is exact.
    func testPinnedToA_queryB_isFalse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, teamB) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let tid = await store.createTask(title: "A", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]
            task.closedAt = nil
        }

        XCTAssertEqual(summary(store, tid)?.pinnedTeamID, teamA.id,
                       "Test setup: the task's index summary must pin team A")
        XCTAssertTrue(store.teamIsInUseByActiveRun(teamA.id),
                      "The task's own pinned team A must be in use")
        XCTAssertFalse(store.teamIsInUseByActiveRun(teamB.id),
                       "A task pinned to A must NOT put a different team B in use")
    }

    // MARK: - No-pin run (teamID == nil)

    /// A task with an open run that carries NO `teamID`: its summary's
    /// `pinnedTeamID` is nil, so the guard reports NEITHER candidate team in use.
    func testRunWithNilTeamID_pinsNothing_isFalseForAllTeams() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, teamB) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let tid = await store.createTask(title: "NoPin", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: nil)]
            task.closedAt = nil
        }

        XCTAssertNil(summary(store, tid)?.pinnedTeamID,
                     "Test setup: a run with teamID == nil yields a nil pinnedTeamID summary")
        XCTAssertFalse(store.teamIsInUseByActiveRun(teamA.id),
                       "A no-pin run does not hold the preferred team A in use (pin comes from run.teamID, not preferredTeamID)")
        XCTAssertFalse(store.teamIsInUseByActiveRun(teamB.id),
                       "A no-pin run does not hold any other team in use either")
    }

    // MARK: - Closed-derived (.done) proxy

    /// A task pinned to team A whose derived status is `.done` (steps all `.done`
    /// + `closedAt` set) is treated as closed → team A is NOT in use. The summary
    /// status is asserted to actually be `.done` so the proxy is exercised honestly.
    func testPinnedTaskDerivesDone_isFalse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }
        guard let roleID = teamA.roles.first(where: { !$0.isSupervisor })?.id else {
            return XCTFail("teamA needs a non-supervisor role")
        }

        let tid = await store.createTask(title: "Done", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: teamA.id)
            run.steps = [StepExecution(id: roleID, role: .custom(id: roleID),
                                       title: "S", status: .done)]
            task.runs = [run]
            task.closedAt = MonotonicClock.shared.now()
        }

        XCTAssertEqual(summary(store, tid)?.status, .done,
                       "Test setup: a closed task with all-.done steps must derive status .done")
        XCTAssertEqual(summary(store, tid)?.pinnedTeamID, teamA.id,
                       "Test setup: the closed task still pins team A in its summary")
        XCTAssertFalse(store.teamIsInUseByActiveRun(teamA.id),
                       "A .done (closed) task does NOT keep its pinned team in use — closed is the not-in-use proxy")
    }

    // MARK: - Two distinct pinned teams

    /// Two open tasks pinned to DIFFERENT teams: both teams are in use, an
    /// unrelated team is not. Confirms the scan is per-summary, not first-match.
    func testTwoTasksDistinctTeams_bothInUse_unrelatedFalse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        let teams = realTeams(store)
        guard teams.count >= 3 else { return XCTFail("need 3 teams") }
        let teamA = teams[0]
        let teamB = teams[1]
        let unrelated = teams[2]

        let aID = await store.createTask(title: "A", supervisorTask: "...", preferredTeamID: teamA.id)
        let bID = await store.createTask(title: "B", supervisorTask: "...", preferredTeamID: teamB.id)
        guard let aID, let bID else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: aID) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]
            task.closedAt = nil
        }
        _ = await store.mutateTask(taskID: bID) { task in
            task.runs = [Run(id: 0, teamID: teamB.id)]
            task.closedAt = nil
        }

        XCTAssertTrue(store.teamIsInUseByActiveRun(teamA.id),
                      "Team A (pinned by an open task) must be in use")
        XCTAssertTrue(store.teamIsInUseByActiveRun(teamB.id),
                      "Team B (pinned by a distinct open task) must be in use")
        XCTAssertFalse(store.teamIsInUseByActiveRun(unrelated.id),
                       "A third team that no open task pins must NOT be in use")
    }

    // MARK: - Synthetic generated-team pin (pure id-equality contract)

    /// A run pinned to a synthetic id NOT present in `workFolder.teams` (the shape
    /// of a generated-team child whose team lives only on the task) is still
    /// reported in use — the guard is pure `pinnedTeamID == teamID`, independent
    /// of whether the team exists in the folder. A real, unpinned team stays false.
    func testSyntheticPinNotInFolder_isTrue_realTeamFalse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let realTeam = realTeams(store).first else { return XCTFail("need >= 1 real team") }
        let genID = NTMSID.from(name: "gen_x_\(UUID().uuidString)")

        let tid = await store.createTask(title: "Gen", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: genID)]
            task.closedAt = nil
        }

        XCTAssertNil(store.workFolder?.teams.first(where: { $0.id == genID }),
                     "Test setup: the synthetic id must NOT correspond to any folder team")
        XCTAssertEqual(summary(store, tid)?.pinnedTeamID, genID,
                       "Test setup: the summary pins the synthetic generated-team id")
        XCTAssertTrue(store.teamIsInUseByActiveRun(genID),
                      "A synthetic pin absent from the folder is still in use — the guard is pure id-equality")
        XCTAssertFalse(store.teamIsInUseByActiveRun(realTeam.id),
                       "A real, unpinned team remains not-in-use alongside the synthetic pin")
    }

    // MARK: - Recurrence keeps a .done task's team in use (deletion hardening)

    /// Seeds a CLOSED (derives `.done`) task pinned to `team`, with the supplied
    /// recurrence. Returns the task id.
    private func makeClosedRecurringTask(
        _ store: NTMSOrchestrator, team: Team, recurrence: TaskRecurrence?
    ) async -> Int? {
        guard let roleID = team.roles.first(where: { !$0.isSupervisor })?.id else { return nil }
        guard let tid = await store.createTask(title: "Rec", supervisorTask: "...", preferredTeamID: team.id)
        else { return nil }
        _ = await store.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: team.id)
            run.steps = [StepExecution(id: roleID, role: .custom(id: roleID), title: "S", status: .done)]
            task.runs = [run]
            task.closedAt = MonotonicClock.shared.now()
            task.recurrence = recurrence
        }
        return tid
    }

    /// A `.done` (closed) task with an ENABLED recurrence will re-run on its team
    /// on the next fire — the guard must keep the team in use so it can't be
    /// deleted out from under that future run.
    func testRecurringDoneTask_enabledRecurrence_blocksDeletion() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let recurrence = TaskRecurrence(
            rule: .interval(seconds: 3600), isEnabled: true,
            nextFireAt: Date(timeIntervalSinceNow: 3600))
        guard let tid = await makeClosedRecurringTask(store, team: teamA, recurrence: recurrence) else {
            return XCTFail("setup failed")
        }

        XCTAssertEqual(summary(store, tid)?.status, .done, "Test setup: closed task derives .done")
        XCTAssertNotNil(summary(store, tid)?.nextRecurrenceFireAt,
                        "Test setup: an enabled recurrence carries a future fire into the summary")
        XCTAssertTrue(store.teamIsInUseByActiveRun(teamA.id),
                      "A .done task with an enabled recurrence keeps its team in use — the next fire re-runs on it")
    }

    /// A `.done` task whose recurrence is DISABLED does not block deletion
    /// (`nextRecurrenceFireAt` is nil for a disabled recurrence).
    func testDoneTask_disabledRecurrence_doesNotBlock() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let recurrence = TaskRecurrence(
            rule: .interval(seconds: 3600), isEnabled: false,
            nextFireAt: Date(timeIntervalSinceNow: 3600))
        guard let tid = await makeClosedRecurringTask(store, team: teamA, recurrence: recurrence) else {
            return XCTFail("setup failed")
        }

        XCTAssertEqual(summary(store, tid)?.status, .done)
        XCTAssertNil(summary(store, tid)?.nextRecurrenceFireAt,
                     "Test setup: a disabled recurrence carries no fire into the summary")
        XCTAssertFalse(store.teamIsInUseByActiveRun(teamA.id),
                       "A .done task with a disabled recurrence does NOT keep its team in use")
    }

    /// A spent `.once` recurrence self-disables (`reschedule` → isEnabled=false,
    /// nextFireAt=nil), so a `.done` task carrying it does not block deletion.
    func testDoneTask_spentOnceRecurrence_doesNotBlock() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }

        // A `.once` whose date is in the past, then rescheduled — self-disables.
        var spent = TaskRecurrence(rule: .once(date: Date(timeIntervalSince1970: 1)), isEnabled: true)
        spent.reschedule(after: Date())
        XCTAssertFalse(spent.isEnabled, "Test setup: a past .once must self-disable on reschedule")
        XCTAssertNil(spent.nextFireAt)

        guard let tid = await makeClosedRecurringTask(store, team: teamA, recurrence: spent) else {
            return XCTFail("setup failed")
        }

        XCTAssertNil(summary(store, tid)?.nextRecurrenceFireAt)
        XCTAssertFalse(store.teamIsInUseByActiveRun(teamA.id),
                       "A spent one-shot recurrence does NOT keep its team in use after it has fired")
    }

    /// An OPEN (non-`.done`) recurring task is in use via the original
    /// `status != .done` clause — the recurrence clause is additive, not the only
    /// path. Pins that the new predicate didn't narrow the existing behavior.
    func testOpenRecurringTask_stillInUse_viaStatusClause() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let tid = await store.createTask(title: "OpenRec", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]   // open run, NOT closed
            task.closedAt = nil
            task.recurrence = TaskRecurrence(rule: .interval(seconds: 3600), isEnabled: true,
                                             nextFireAt: Date(timeIntervalSinceNow: 3600))
        }

        XCTAssertNotEqual(summary(store, tid)?.status, .done, "Test setup: the task is open, not .done")
        XCTAssertTrue(store.teamIsInUseByActiveRun(teamA.id),
                      "An open recurring task keeps its team in use via the status clause (recurrence is additive)")
    }
}
