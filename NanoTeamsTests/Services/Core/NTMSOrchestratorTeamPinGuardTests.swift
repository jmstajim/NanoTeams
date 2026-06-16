import XCTest
@testable import NanoTeams

/// Fix A, orchestrator side: the non-optional `resolvedTeam(for:)` pin behavior,
/// the `findOrCreateStep` roster-swap guard (the chokepoint where a second roster
/// previously entered a run), and the `teamIsInUseByActiveRun` deletion guard.
@MainActor
final class NTMSOrchestratorTeamPinGuardTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        NTMSOrchestrator(repository: NTMSRepository(), searchEmbeddingClient: StubSearchEmbeddingClient())
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-pinguard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func twoTeams(_ store: NTMSOrchestrator) -> (Team, Team)? {
        let teams = (store.workFolder?.teams ?? []).filter { !$0.isManagedSingleton }
        guard teams.count >= 2 else { return nil }
        return (teams[0], teams[1])
    }

    // MARK: - resolvedTeam(for:) non-optional pin

    /// The view-reachable non-optional resolver coalesces a pin-failure to a
    /// display fallback (`activeTeam ?? Team.default`) and — critically — does NOT
    /// mutate `lastErrorMessage`. It is called from ~7 SwiftUI `body` sites, so
    /// surfacing the error here would mutate observable state during view
    /// evaluation. The LOUD diagnostic is owned by the engine paths
    /// (`TaskEngineStoreAdapter.resolvedTeam` + `findOrCreateStep`'s guard).
    func testOrchestratorResolvedTeam_pinnedTeamDeleted_returnsFallback_doesNotSurfaceError() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)

        let tid = await store.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        let bogusID = NTMSID.from(name: "deleted_\(UUID().uuidString)")
        _ = await store.mutateTask(taskID: tid) { $0.runs = [Run(id: 0, teamID: bogusID)] }
        store.lastErrorMessage = nil

        let resolved = store.resolvedTeam(for: store.loadedTask(tid))
        XCTAssertEqual(resolved.id, store.workFolder?.activeTeam?.id ?? Team.default.id,
                       "Non-optional resolver coalesces a pin-failure to the display fallback (activeTeam ?? Team.default)")
        XCTAssertNil(store.lastErrorMessage,
                     "The view-reachable resolver must NOT mutate observable state on a pin-failure — no banner from a getter reachable in `body`")
    }

    // MARK: - findOrCreateStep roster-swap guard

    func testFindOrCreateStep_roleNotInPinnedTeam_returnsNil_blocksRosterSwap() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, teamB) = twoTeams(store) else { return XCTFail("need 2 teams") }
        guard let foreignRoleID = teamB.roles.first(where: { !$0.isSupervisor })?.id,
              teamA.findRole(byIdentifier: foreignRoleID) == nil else {
            return XCTFail("need a teamB role absent from teamA")
        }

        let tid = await store.createTask(title: "T", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { $0.runs = [Run(id: 0, teamID: teamA.id)] }
        store.lastErrorMessage = nil

        let stepID = await store.findOrCreateStep(taskID: tid, roleID: foreignRoleID)
        XCTAssertNil(stepID, "A role outside the pinned team must be refused (roster-swap guard)")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.count, 0,
                       "No foreign-roster step may be appended")
        XCTAssertTrue(store.lastErrorMessage?.contains("Roster swap blocked") ?? false)
    }

    func testFindOrCreateStep_roleInPinnedTeam_createsStep() async {
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
        _ = await store.mutateTask(taskID: tid) { $0.runs = [Run(id: 0, teamID: teamA.id)] }

        let stepID = await store.findOrCreateStep(taskID: tid, roleID: nativeRoleID)
        XCTAssertNotNil(stepID, "A role belonging to the pinned team mints a step")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.count, 1)
    }

    // MARK: - teamIsInUseByActiveRun deletion guard

    func testTeamIsInUseByActiveRun_pinnedOpenRun_true_otherTeamFalse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, teamB) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let tid = await store.createTask(title: "T", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { $0.runs = [Run(id: 0, teamID: teamA.id)] }

        XCTAssertTrue(store.teamIsInUseByActiveRun(teamA.id),
                      "Team backing an open run is in use")
        XCTAssertFalse(store.teamIsInUseByActiveRun(teamB.id),
                       "A team not backing any open run is not in use")
    }

    func testTeamIsInUseByActiveRun_closedTask_false() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let tid = await store.createTask(title: "T", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]
            task.closedAt = MonotonicClock.shared.now()
        }

        XCTAssertFalse(store.teamIsInUseByActiveRun(teamA.id),
                       "A closed task's run does not keep its team in use")
    }
}
