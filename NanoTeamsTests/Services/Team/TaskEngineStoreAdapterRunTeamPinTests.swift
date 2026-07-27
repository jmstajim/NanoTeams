import XCTest
@testable import NanoTeams

/// Pins the run-team PIN behavior added to `TeamResolution.resolve` (consumed by
/// `TaskEngineStoreAdapter.resolvedTeam`). A STARTED run is bound to its
/// `Run.teamID`; a team deleted mid-run must fail LOUDLY (nil → engine `.failed`)
/// rather than silently falling back to `workFolder.activeTeam` and commingling a
/// second roster into the run (the "two Tech Lead" bug).
@MainActor
final class TaskEngineStoreAdapterRunTeamPinTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        TestOrchestrator.make()
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-runpin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Two distinct real teams from the bootstrapped work folder.
    private func twoTeams(_ store: NTMSOrchestrator) -> (Team, Team)? {
        let teams = (store.workFolder?.teams ?? []).filter { !$0.isManagedSingleton }
        guard teams.count >= 2 else { return nil }
        return (teams[0], teams[1])
    }

    // MARK: - Pin honored

    /// A started run resolves via `run.teamID` and stays stable even when the
    /// task's `preferredTeamID` is changed underneath it.
    func testResolvedTeam_runTeamIDResolves_returnsPinnedTeam_stableAcrossPreferredChange() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, teamB) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let tid = await store.createTask(title: "T", supervisorTask: "...", preferredTeamID: teamB.id)
        guard let tid else { return XCTFail("create failed") }

        // Pin the run to teamA, then change preferredTeamID to teamB.
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]
            task.preferredTeamID = teamB.id
        }

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: tid)
        XCTAssertEqual(adapter.activeTeam?.id, teamA.id,
                       "Pinned run.teamID must win over a changed preferredTeamID")
    }

    // MARK: - Core regression: deleted pinned team

    /// THE core regression. A run pinned to a team that no longer exists must
    /// resolve to nil + set a diagnostic — NOT silently swap to activeTeam.
    func testResolvedTeam_pinnedTeamDeleted_returnsNil_noActiveTeamFallback() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard store.workFolder?.activeTeam != nil else { return XCTFail("need active team") }

        let tid = await store.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        let bogusID = NTMSID.from(name: "deleted_team_\(UUID().uuidString)")
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: bogusID)]
        }
        store.lastErrorMessage = nil

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: tid)
        XCTAssertNil(adapter.activeTeam,
                     "A run pinned to a deleted team must resolve to nil — NOT silently swap to activeTeam (the two-roster commingling bug)")
        XCTAssertTrue(store.lastErrorMessage?.contains("pinned") ?? false,
                      "A loud diagnostic must be surfaced for the deleted pinned team")
    }

    // MARK: - Legacy (no pinned teamID)

    /// A legacy run with no `teamID` falls back to `preferredTeamID`.
    func testResolvedTeam_legacyRunNoTeamID_fallsBackToPreferred() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let tid = await store.createTask(title: "T", supervisorTask: "...", preferredTeamID: teamA.id)
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: nil)]  // legacy run
        }

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: tid)
        XCTAssertEqual(adapter.activeTeam?.id, teamA.id,
                       "Legacy run (no teamID) resolves via preferredTeamID")
    }

    /// A legacy run with no `teamID` AND no `preferredTeamID` match falls back to
    /// `activeTeam` for a ROOT task (the original, still-correct behavior).
    func testResolvedTeam_legacyRunNoTeamID_noPreferred_rootFallsBackToActiveTeam() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        let activeID = store.workFolder?.activeTeam?.id
        XCTAssertNotNil(activeID)

        let tid = await store.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: nil)]
            task.preferredTeamID = nil
        }

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: tid)
        XCTAssertEqual(adapter.activeTeam?.id, activeID,
                       "Root task with no pin and no preferred resolves to activeTeam")
    }

    // MARK: - generatedTeam precedence

    /// `generatedTeam` wins even when a conflicting `run.teamID` is pinned.
    func testResolvedTeam_generatedTeamWins_overRunTeamID() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let (teamA, _) = twoTeams(store) else { return XCTFail("need 2 teams") }

        let tid = await store.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        let generated = Team(
            id: NTMSID.from(name: "gen_\(UUID().uuidString)"),
            name: "Gen",
            description: "",
            roles: [TeamRoleDefinition(id: "gen_w", name: "Worker", prompt: "", toolIDs: [],
                                       usePlanningPhase: false, dependencies: RoleDependencies())],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
        _ = await store.mutateTask(taskID: tid) { task in
            task.runs = [Run(id: 0, teamID: teamA.id)]  // conflicting pin
            task.adoptGeneratedTeam(generated)
        }

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: tid)
        XCTAssertEqual(adapter.activeTeam?.id, generated.id,
                       "generatedTeam must take precedence over a pinned run.teamID")
    }
}
