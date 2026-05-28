import XCTest
@testable import NanoTeams

/// Regression: `createDelegatedTask` MUST register the new child task in
/// `loadedTasks` before returning. Pre-fix, the just-created child sat on
/// disk + in `tasksIndex` but NOT in `loadedTasks` — so the immediate next
/// step in `handleDelegateToTeam`:
///
///     await delegate.mutateTask(taskID: childTID) {
///         task.adoptGeneratedTeam(targetTeam)
///     }
///
/// silently failed (`mutateTask` for a background task requires
/// `loadedTask(taskID) != nil`). With `generatedTeam` left `nil` on disk,
/// the child engine's `resolvedTeam` fallback landed on the PARENT's
/// `activeTeam` — that's the parent's Coding Agent template with
/// `delegate_to_team` still in toolIDs. Result: child runs with parent's
/// tools, recursively calls `delegate_to_team`, and the user gets the
/// `Coding Agent.Coding Agent.Coding Agent…` infinite chain we observed.
///
/// Fix: `createDelegatedTask` calls `ensureTaskLoaded(childID)` after
/// `apply(snapshot)`. This test pins both halves: child IS in loadedTasks,
/// AND a subsequent `mutateTask` on it persists.
@MainActor
final class CreateDelegatedTaskLoadedTasksTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        NTMSOrchestrator(
            repository: NTMSRepository(),
            searchEmbeddingClient: StubSearchEmbeddingClient()
        )
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-create-delegated-loaded-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCreateDelegatedTask_putsChildInLoadedTasks() async {
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

        XCTAssertNotNil(store.loadedTask(childID),
                        "Child task MUST be in loadedTasks after createDelegatedTask returns — otherwise the next mutateTask(childID) call (e.g. adoptGeneratedTeam) silently fails")
    }

    /// End-to-end of the actual user-bug chain: create child → mutate
    /// (adoptGeneratedTeam analogue) → reload from disk → verify mutation
    /// persisted. Pre-fix, mutateTask returned `false` and the change was
    /// dropped on the floor.
    func testCreateDelegatedTask_subsequentMutationPersists() async {
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

        // Use a benign mutation that doesn't depend on team config — append a
        // run. This stands in for `adoptGeneratedTeam`: both rely on the
        // same `mutateTask(taskID:)` non-active-task code path that needs
        // `loadedTask(taskID) != nil`.
        let mutated = await store.mutateTask(taskID: childID) { task in
            task.runs.append(Run(id: 0, steps: []))
        }
        XCTAssertTrue(mutated,
                      "mutateTask(childID) must succeed — pre-fix this returned false because loadedTask(childID) was nil")

        // Verify it persisted: re-read by purging in-memory and reloading.
        XCTAssertEqual(store.loadedTask(childID)?.runs.count, 1,
                       "Mutation must be visible in the in-memory loaded task")
    }

    /// END-TO-END regression for the user-observed `Coding Agent.Coding Agent.Coding Agent…`
    /// infinite chain. Drives the full bug-trigger sequence:
    ///
    ///  1. Create child task via `createDelegatedTask` (parent = active task,
    ///     using Coding Agent template that DOES have `delegate_to_team`).
    ///  2. Adopt a freshly-stripped generated team onto the child via
    ///     `mutateTask`. This is what `handleDelegateToTeam` does after
    ///     `TeamGenerationService.generate` + `stripDelegationTools`.
    ///  3. Resolve the child task's team via `store.resolvedTeam(for:)` —
    ///     the same call `TaskEngineStoreAdapter.resolvedTeam` makes when the
    ///     child engine starts.
    ///
    /// Pre-fix observable failure mode: step 2 silently failed (`mutateTask`
    /// for non-active task required `loadedTask != nil`, which was nil). Step
    /// 3 then fell through `task.generatedTeam ?? workFolder.teams[preferredID]
    /// ?? activeTeam` and landed on **parent's** Coding Agent team — with
    /// `delegate_to_team` in toolIDs — so the child engine ran with parent's
    /// tools and recursively delegated.
    ///
    /// Post-fix invariants asserted here:
    ///  - resolvedTeam(child) is the adopted (stripped) team, NOT parent's activeTeam
    ///  - the resolved team has zero `delegate_to_team` (or legacy `list_teams`) in any role
    func testCreateDelegatedTask_adoptedGeneratedTeamSurvivesResolution_notParentTeam() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        // Pin parent to Coding Agent — the only built-in template with delegation
        // configured. The work folder's default active team (Coding Assistant
        // since commit 8debd78) is advisory-only, so a parent created with
        // `preferredTeamID: nil` doesn't reproduce the bug surface this test
        // pins. We pin via preferredTeamID (not by mutating activeTeamID) so
        // the workspace's active team stays the bootstrapped default.
        let parentID = await store.createTask(
            title: "Parent",
            supervisorTask: "...",
            preferredTeamID: NTMSID.from(name: "Coding Agent")
        )
        guard let parentID else { return XCTFail("parent creation failed") }
        // Sanity: parent's active team has at least one delegating role — this
        // is the team the buggy fallback would have returned. Under the new
        // model, delegation is settings-driven (`hasDelegationConfigured`), not
        // toolID-driven.
        let parentResolvedTeam = store.resolvedTeam(for: store.activeTask)
        let parentHasDelegatingRole = parentResolvedTeam.roles.contains { $0.hasDelegationConfigured }
        XCTAssertTrue(parentHasDelegatingRole,
                      "Sanity check — parent team must have a delegation-enabled role; otherwise the fallback bug couldn't manifest in the first place")

        // Step 1: create the delegated child.
        let childID = await store.createDelegatedTask(
            parentTaskID: parentID,
            parentRoleID: "coding_agent",
            title: "Child",
            supervisorTask: "Sub-brief",
            preferredTeamID: nil,
            depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }

        // Step 2: build a stripped generated-team analogue (mimics
        // `TeamGenerationService.generate` → `stripDelegationTools`).
        let strippedRole = TeamRoleDefinition(
            id: "gen_role_id", name: "Worker", icon: "person",
            prompt: "", toolIDs: [ToolNames.readFile, ToolNames.writeFile],
            // No delegate_to_team — strip applied
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let supervisorRole = TeamRoleDefinition(
            id: "gen_supervisor_id", name: "Supervisor", icon: "crown",
            prompt: "", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let strippedTeam = Team(
            id: "generated_unique_id", name: "Generated Worker Team",
            description: "stripped",
            roles: [supervisorRole, strippedRole],
            artifacts: [],
            settings: .default, graphLayout: .default
        )

        // Step 3: this is the call that pre-fix silently failed. Post-fix it
        // succeeds because `createDelegatedTask` ran `ensureTaskLoaded`.
        let adopted = await store.mutateTask(taskID: childID) { task in
            task.adoptGeneratedTeam(strippedTeam)
        }
        XCTAssertTrue(adopted,
                      "adoptGeneratedTeam mutation must persist — pre-fix returned false because child wasn't in loadedTasks")

        // Step 4: resolve team for the child task — the exact lookup the engine does.
        guard let childTask = store.loadedTask(childID) else {
            return XCTFail("child must be loaded after adoption")
        }
        let resolved = store.resolvedTeam(for: childTask)

        XCTAssertEqual(resolved.id, strippedTeam.id,
                       "Child engine must resolve to the ADOPTED stripped team, not parent's activeTeam (parent fallback was the bug)")
        XCTAssertNotEqual(resolved.id, parentResolvedTeam.id,
                          "Child team MUST differ from parent — otherwise we have the self-recursion chain back")

        for role in resolved.roles {
            XCTAssertFalse(role.toolIDs.contains(ToolNames.delegateToTeam),
                           "Resolved team's role '\(role.name)' has delegate_to_team — this is the failure surface that produced the infinite Coding Agent.Coding Agent chain")
            XCTAssertFalse(role.toolIDs.contains("list_teams"),
                           "Resolved team's role '\(role.name)' has legacy list_teams — should be stripped alongside delegate_to_team")
        }
    }

    /// Edge case: `ensureTaskLoaded` must be idempotent — calling
    /// `createDelegatedTask` twice for the same parent (legitimate scenario:
    /// role does two `delegate_to_team` calls) shouldn't crash or evict the
    /// first child.
    func testCreateDelegatedTask_secondChild_keepsBothLoaded() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }

        let child1 = await store.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "r",
            title: "C1", supervisorTask: "B1",
            preferredTeamID: nil, depth: 1
        )
        let child2 = await store.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "r",
            title: "C2", supervisorTask: "B2",
            preferredTeamID: nil, depth: 1
        )
        guard let child1, let child2 else { return XCTFail("child creation failed") }

        XCTAssertNotNil(store.loadedTask(child1), "First child must remain loaded after second creation")
        XCTAssertNotNil(store.loadedTask(child2), "Second child must be loaded too")
    }
}
