import XCTest
@testable import NanoTeams

/// Pins the fail-fast behavior in `TaskEngineStoreAdapter.resolvedTeam` for
/// child tasks that lost their team reference. The pre-fix bug was the silent
/// path through `task.generatedTeam ?? workFolder.teams[preferredID] ?? activeTeam`:
/// when the child's `generatedTeam` was nil AND `preferredTeamID` didn't
/// resolve in `workFolder.teams` (which is exactly the state for a generated
/// team — its id is ephemeral and lives only on the child's `generatedTeam`
/// slot), the chain fell through to `workFolder.activeTeam`, returning the
/// PARENT's currently-selected team. For a parent task using Coding Agent
/// (peer-level delegator), that team has `hasDelegationConfigured == true` so
/// the auto-injected delegation pack reached the child engine, which called
/// `delegate_to_team` itself, and produced the `Coding Agent.Coding Agent…`
/// infinite chain (spec #91 in `docs/delegation-feature.md`).
///
/// Post-fix invariant: child tasks (`parentTaskID != nil`) NEVER inherit the
/// parent's active team via fallback. If team resolution can't land via
/// `generatedTeam` or `workFolder.teams[preferredID]`, the adapter returns
/// `nil`. The engine's run loop transitions `.failed` on the next tick, the
/// parent's `delegate_to_team` awaiter surfaces it as `.commandFailed` —
/// loud, visible failure beats silent recursion.
///
/// Top-level tasks (no `parentTaskID`) keep the original `activeTeam`
/// fallback because they legitimately track the user's currently selected
/// team.
@MainActor
final class TaskEngineStoreAdapterChildTaskFallbackTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        TestOrchestrator.make()
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-adapter-fallback-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Child task fail-fast

    /// Direct regression for spec #91: child task with `generatedTeam == nil`
    /// AND `preferredTeamID` pointing to a generated-team id NOT in
    /// `workFolder.teams` MUST resolve to nil — NOT to parent's `activeTeam`.
    func testResolvedTeam_childTaskWithoutGeneratedTeam_returnsNil_notParentTeam() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        // Pin parent to Coding Agent — the only built-in template with delegation
        // configured. The work folder's default active team (Coding Assistant
        // since commit 8debd78) is advisory-only, so a parent created with
        // `preferredTeamID: nil` doesn't reproduce the bug surface this test
        // pins. We pin via preferredTeamID (not by mutating activeTeamID)
        // because the surgical-restore branch below relies on caller-vs-active
        // mismatch — pinning the active team would mask it.
        let parentID = await store.createTask(
            title: "Parent",
            supervisorTask: "...",
            preferredTeamID: NTMSID.from(name: "Coding Agent")
        )
        guard let parentID else { return XCTFail("parent creation failed") }

        // Sanity: parent's activeTeam is the one fallback would have returned —
        // confirm it has a delegation-enabled role so the bug surface is real.
        // Settings-driven: `hasDelegationConfigured == true` is the new trigger.
        let parentTeam = store.resolvedTeam(for: store.activeTask)
        let parentHasDelegatingRole = parentTeam.roles.contains { $0.hasDelegationConfigured }
        XCTAssertTrue(parentHasDelegatingRole,
                      "Parent template must have a delegation-enabled role — otherwise the recursion bug couldn't manifest")

        // Create child task with a preferredTeamID that's NOT in workFolder.teams
        // (mimicking the generated-team id which only lives on child.generatedTeam).
        let fakeGeneratedID = NTMSID.from(name: "fake_generated_team_\(UUID().uuidString)")
        let childID = await store.createDelegatedTask(
            parentTaskID: parentID,
            parentRoleID: "coding_agent",
            title: "Child",
            supervisorTask: "Sub-brief",
            preferredTeamID: fakeGeneratedID,
            depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }

        // Critically: do NOT call `adoptGeneratedTeam` here. We want to assert
        // what happens in the broken state — the silent failure path that
        // pre-fix would have fallen back to parent's team.
        XCTAssertNil(store.loadedTask(childID)?.generatedTeam,
                     "Test setup: child must not have generatedTeam set")

        // `createDelegatedTask` preserves the caller's original
        // `preferredTeamID` (the unresolvable generated id) so the resolver's
        // fail-fast actually has a reason to engage — without that surgical
        // restore, `taskService.createTask` would normalize the id to the
        // project's active team's id, giving the resolver a successful
        // `team(withID:)` match in its second branch and bypassing the
        // child-task guard entirely.
        XCTAssertEqual(store.loadedTask(childID)?.preferredTeamID, fakeGeneratedID,
                       "Test setup invariant: child must keep the unresolvable preferredTeamID — the fail-fast guard is below this in the resolver chain")

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: childID)

        // The behavior under test: adapter MUST return nil rather than
        // parent's activeTeam.
        XCTAssertNil(adapter.activeTeam,
                     "Child task with no generatedTeam and unknown preferredTeamID MUST resolve to nil — falling back to parent's activeTeam is the spec #91 bug surface (Coding Agent.Coding Agent recursion)")
    }

    /// Top-level tasks (no `parentTaskID`) keep the original behavior — they
    /// fall back to `workFolder.activeTeam` because that legitimately tracks
    /// the user's currently selected team.
    func testResolvedTeam_topLevelTask_stillFallsBackToActiveTeam() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: parentID)

        XCTAssertNotNil(adapter.activeTeam,
                        "Top-level task with no generatedTeam falls back to workFolder.activeTeam — this is correct, the fail-fast guard is child-only")
    }

    /// Positive control: when `generatedTeam` is properly adopted on a child,
    /// the adapter resolves to it (not to parent's team, not to nil).
    func testResolvedTeam_childTaskWithAdoptedTeam_returnsAdoptedTeam() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }

        let childID = await store.createDelegatedTask(
            parentTaskID: parentID,
            parentRoleID: "coding_agent",
            title: "Child",
            supervisorTask: "Sub-brief",
            preferredTeamID: nil,
            depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }

        let adoptedTeam = makeStrippedTeam(named: "Stripped Worker Team")
        let adopted = await store.mutateTask(taskID: childID) { task in
            task.adoptGeneratedTeam(adoptedTeam)
        }
        XCTAssertTrue(adopted, "adoptGeneratedTeam must persist for the positive control to be meaningful")

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: childID)
        XCTAssertEqual(adapter.activeTeam?.id, adoptedTeam.id,
                       "Adopted generated team MUST be resolved by the adapter — no fallback should kick in here")
    }

    // MARK: - Helpers

    private func makeStrippedTeam(named name: String) -> Team {
        let supervisor = TeamRoleDefinition(
            id: "gen_supervisor", name: "Supervisor",
            prompt: "", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let worker = TeamRoleDefinition(
            id: "gen_worker", name: "Worker",
            prompt: "", toolIDs: [ToolNames.readFile, ToolNames.writeFile],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        return Team(
            id: NTMSID.from(name: "\(name)_\(UUID().uuidString)"),
            name: name,
            description: "stripped test team",
            roles: [supervisor, worker],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
    }
}
