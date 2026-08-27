import XCTest

@testable import NanoTeams

/// Base class for tests that need a fresh NTMSOrchestrator + temp directory.
/// Subclass and add test methods. setUp/tearDown are handled automatically.
///
/// Uses an in-memory `ConfigurationStorage` so each test starts with clean
/// defaults — otherwise settings (e.g. `exploratorySearchEnabled`) leak between
/// tests via `UserDefaults.standard` and the order of execution starts to
/// matter.
@MainActor
class NTMSOrchestratorTestBase: XCTestCase, @unchecked Sendable {

    var sut: NTMSOrchestrator!
    var tempDir: URL!

    /// Recording client behind the orchestrator's `embeddingLifecycle`. Tests
    /// can inspect `embeddingClient.loadUnloadCalls` for load/unload sequencing
    /// (filtered view), or `.calls` for the full sequence including the
    /// adoption-path `listLoadedInstances` calls. Pre-installed here so every
    /// existing scenario test runs without touching the real LM Studio endpoint.
    var embeddingClient: RecordingLLMClient!

    /// Stubs the chat-residency reconcile that `openWorkFolder` now runs.
    /// Tests that assert on residency inject their own client per call; this
    /// exists so the other ~700 `openWorkFolder` sites do no network I/O.
    var chatLifecycleClient: RecordingLLMClient!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        embeddingClient = RecordingLLMClient()
        chatLifecycleClient = RecordingLLMClient()
        // Through the shared factory, not inline: the base and the ~90 suites
        // that build their own orchestrator must not be able to drift on which
        // seams are stubbed. `TestOrchestratorFactory` owns that list.
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Before `stopAllEngines`, and awaited rather than cancelled: the task-creation path
        // backgrounds the run's LAUNCH phase (see `spawnBackgroundRunLaunch`), so a suspended
        // launch would resume AFTER the loop below tore its engines down and create a fresh
        // one — the very class the comment there describes, arriving by a route that verb
        // cannot see. `stopAllEngines` cancels those launches, but cancellation is
        // cooperative: only the drain proves none is left running into the next test.
        await sut?.drainRunStartLaunches()
        // The role-control primitives now perform a TOTAL wake (create + start the engine), so a
        // test that exercises one leaves a real run loop alive — `TestOrchestrator.make` injects
        // a real `TeamEngine`. Left running, it would keep mutating shared state into the next
        // test on this worker and turn green into timing-dependent.
        sut?.stopAllEngines()
        sut = nil
        embeddingClient = nil
        chatLifecycleClient = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Fixture shaping

    /// Adds any missing role ids to the active team's roster.
    ///
    /// A fixture that builds a `Run` by hand picks role ids freely (`"pm-123"`), but in
    /// production a step exists only because `findOrCreateStep(taskID:roleID:)` was driven from
    /// `team.roles` — so "a step whose role was never on its run's team" is a shape the app
    /// cannot produce. The role verbs (`restartRole`, `requestRevision`) refuse an off-roster id
    /// since 2026-08-25, because the one route that DOES produce it — deleting a role in the
    /// Team Editor while the task is live — is exactly the case where `restartRole` used to
    /// `reset()` a step and report success for a role the engine can never start again.
    ///
    /// So this is not a workaround for the guard: it makes the fixture describe a run the app
    /// could have created. The deletion case has its own owner in `RoleControlRosterGuardTests`
    /// and must not ride along here by accident.
    ///
    /// One copy, on the base every affected suite already inherits — it existed three times in
    /// three files before, which is the drift class it now cannot re-enter.
    func registerRolesOnActiveTeam(_ roleIDs: [String]) async {
        await register(roleIDs, teamID: sut.snapshot?.projection.activeTeamID)
    }

    /// Same, but onto the team the TASK is pinned to — resolved through the very
    /// `TeamResolution` the role verbs consult, so the fixture cannot drift from the guard.
    /// A task created with `preferredTeamID:` is not on the active team, and registering
    /// there would leave the verb refusing while the fixture looked correct.
    func registerRoles(_ roleIDs: [String], onTeamOf taskID: Int) async {
        guard let task = sut.loadedTask(taskID), let projection = sut.snapshot?.projection else {
            return XCTFail("registerRoles: task \(taskID) is not loaded")
        }
        guard let team = TeamResolution.team(for: task, in: projection) else {
            return XCTFail("registerRoles: no team resolves for task \(taskID)")
        }
        await register(roleIDs, teamID: team.id)
    }

    /// Defines a role FULLY (dependencies, tools, name) on the task's pinned team, replacing any
    /// stub `registerRoles` already put there.
    ///
    /// A plain `roles.append` cannot be used once a fixture has called `registerRoles`: two
    /// entries would share an id, `findRole(byIdentifier:)` returns the FIRST, and the richer
    /// definition would be shadowed by the stub — silently, with the fixture reading correctly.
    /// That is how `testRestartRole_tearsDownStaleEngineRoleTask_forDownstreamRoleToo` lost its
    /// downstream edge on 2026-08-26.
    func defineRole(_ role: TeamRoleDefinition, onTeamOf taskID: Int) async {
        guard let task = sut.loadedTask(taskID), let projection = sut.snapshot?.projection,
              let team = TeamResolution.team(for: task, in: projection)
        else { return XCTFail("defineRole: no team resolves for task \(taskID)") }
        await sut.mutateWorkFolder { projection in
            guard let index = projection.teams.firstIndex(where: { $0.id == team.id })
            else { return }
            if projection.teams[index].roles.contains(where: { $0.id == role.id }) {
                projection.teams[index].updateRole(role)
            } else {
                projection.teams[index].roles.append(role)
            }
        }
    }

    private func register(_ roleIDs: [String], teamID: NTMSID?) async {
        await sut.mutateWorkFolder { projection in
            guard let teamID,
                  let index = projection.teams.firstIndex(where: { $0.id == teamID })
            else { return }
            for roleID in Set(roleIDs)
                where projection.teams[index].findRole(byIdentifier: roleID) == nil {
                projection.teams[index].roles.append(TeamRoleDefinition(
                    id: roleID, name: roleID, prompt: "", toolIDs: [],
                    usePlanningPhase: false, dependencies: RoleDependencies()))
            }
        }
    }
}

// `StubSearchEmbeddingClient` and `InMemoryConfigurationStorage` moved to
// `NanoTeamsTests/Support/TestOrchestratorFactory.swift` — they are the
// factory's own dependencies, and leaving them here inverted the direction.
