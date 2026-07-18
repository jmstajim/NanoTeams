import XCTest
@testable import NanoTeams

/// The user-reported behavior: the Autovisor's `manage_role accept` on a CHAT-MODE
/// advisory role must END the task (finish the role and close the task once nothing
/// else is active), instead of failing "Role is still working". Drives
/// `performAutovisorAction` on synthetic chat teams with known role ids so the close
/// decision (`Run.activeWorkRoles` over the resolved roster) is deterministic.
@MainActor
final class AutovisorChatRoleAcceptTests: NTMSOrchestratorTestBase {

    private let chatTeamID: NTMSID = "chat-accept-team"

    private func pinManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = mgrID }
        return mgrID
    }

    private func advisory(_ id: String) -> TeamRoleDefinition {
        // required inputs, no outputs → completionType == .advisory
        TeamRoleDefinition(id: id, name: id.capitalized, prompt: "", toolIDs: [], usePlanningPhase: false,
                           dependencies: RoleDependencies(requiredArtifacts: ["Ctx"]))
    }

    private func producing(_ id: String) -> TeamRoleDefinition {
        TeamRoleDefinition(id: id, name: id.capitalized, prompt: "", toolIDs: [], usePlanningPhase: false,
                           dependencies: RoleDependencies(producesArtifacts: ["Out"]))
    }

    /// Builds a chat-mode team (supervisor with NO required artifacts) carrying `roles`,
    /// creates a task pinned to it, and injects a run whose steps/roleStatuses use the
    /// roles' real ids. Returns the task id. Manager must be pinned first.
    private func makeChatTeamTask(
        roles: [TeamRoleDefinition],
        statuses: [String: RoleExecutionStatus]
    ) async -> Int? {
        let supervisor = TeamRoleDefinition(
            id: "supervisor", name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "supervisor")
        let team = Team(id: chatTeamID, name: "Chat Accept", roles: [supervisor] + roles,
                        artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        XCTAssertTrue(team.isChatMode, "the test team must be chat-mode")
        await sut.mutateWorkFolder { $0.teams.append(team) }
        guard let taskID = await sut.createTask(title: "Chat", supervisorTask: "help",
                                                preferredTeamID: chatTeamID, makeActive: false) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(taskID)
        let steps = roles.map {
            StepExecution(id: $0.id, role: .custom(id: $0.id), title: $0.name,
                          status: statuses[$0.id] == .working ? .running : .pending)
        }
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0, steps: steps, roleStatuses: statuses, teamID: self.chatTeamID)
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        return taskID
    }

    // MARK: - Single advisory role (the screenshot's case)

    func testManageRoleAccept_chatModeWorkingAdvisoryRole_finishesRoleAndClosesTask() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(roles: [advisory("a")], statuses: ["a": .working]) else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "a", verb: .accept))
        XCTAssertTrue(r.ok, "accept on a chat advisory role must succeed")
        XCTAssertTrue(r.message.contains("closed chat task"), "message must confirm the close")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["a"], .done)
        XCTAssertNotNil(sut.loadedTask(taskID)?.closedAt, "the single-role chat task must close")
    }

    func testManageRoleAccept_chatModeSingleRole_taskStatusBecomesDone() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(roles: [advisory("a")], statuses: ["a": .working]) else { return }
        _ = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "a", verb: .accept))
        // The user-visible requirement: the task actually ends.
        XCTAssertEqual(sut.loadedTask(taskID)?.derivedStatusFromActiveRun(), .done)
    }

    // MARK: - Multi-role chat teams (Quest Party shape)

    func testManageRoleAccept_chatModeMultiRole_finishesTargetOnly_leavesTaskOpen() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(
            roles: [advisory("a"), advisory("b")], statuses: ["a": .working, "b": .working]) else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "a", verb: .accept))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.message.contains("Still active"), "message must name the roles still working")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["a"], .done)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["b"], .working, "sibling must be untouched")
        XCTAssertNil(sut.loadedTask(taskID)?.closedAt, "task must stay open while a sibling works")
    }

    func testManageRoleAccept_chatModeMultiRole_lastRemainingRole_closesTask() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(
            roles: [advisory("a"), advisory("b")], statuses: ["a": .done, "b": .working]) else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "b", verb: .accept))
        XCTAssertTrue(r.ok)
        XCTAssertNotNil(sut.loadedTask(taskID)?.closedAt, "finishing the last active role closes the task")
    }

    func testManageRoleAccept_chatModeFailedSibling_doesNotCloseTask() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(
            roles: [advisory("a"), producing("b")], statuses: ["a": .working, "b": .failed]) else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "a", verb: .accept))
        XCTAssertTrue(r.ok)
        XCTAssertNil(sut.loadedTask(taskID)?.closedAt, "a .failed sibling is not complete → task stays open")
        XCTAssertTrue(r.message.contains("Still active"))
    }

    // MARK: - Producing / needsAcceptance roles keep ordinary semantics

    func testManageRoleAccept_chatModeProducingRole_stillWorking_rejects() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(roles: [producing("p")], statuses: ["p": .working]) else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "p", verb: .accept))
        XCTAssertFalse(r.ok, "a producing role in a chat team is not a chat finish — accept rejects it")
        XCTAssertTrue(r.message.contains("still working"))
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["p"], .working)
        XCTAssertNil(sut.loadedTask(taskID)?.closedAt)
    }

    func testManageRoleAccept_chatModeNeedsAcceptanceRole_takesOrdinaryAcceptPath() async {
        _ = await pinManager()
        // Quest Party shape: a producing role at a mid-pipeline acceptance gate in a chat team.
        guard let taskID = await makeChatTeamTask(roles: [producing("p")], statuses: ["p": .needsAcceptance]) else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "p", verb: .accept))
        XCTAssertTrue(r.ok, "a .needsAcceptance role accepts normally even in a chat team")
        XCTAssertTrue(r.message.contains("Accepted role"))
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["p"], .accepted)
        XCTAssertNil(sut.loadedTask(taskID)?.closedAt, "ordinary accept must not close the task")
    }

    func testManageRoleAccept_chatModeAlreadyDoneRole_closesTask() async {
        _ = await pinManager()
        // The advisory auto-finish zombie: role already .done, task still reads running.
        guard let taskID = await makeChatTeamTask(roles: [advisory("a")], statuses: ["a": .done]) else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "a", verb: .accept))
        XCTAssertTrue(r.ok, "an already-done chat advisory role routes to finish (idempotent) and closes")
        XCTAssertNotNil(sut.loadedTask(taskID)?.closedAt)
    }

    // MARK: - Idempotence + self-guard

    func testManageRoleAccept_chatModeAlreadyClosedTask_failsWithoutReclosing() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(roles: [advisory("a")], statuses: ["a": .working]) else { return }
        await sut.mutateTask(taskID: taskID) { $0.closedAt = MonotonicClock.shared.now() }
        let closedBefore = sut.loadedTask(taskID)?.closedAt
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "a", verb: .accept))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("already closed"))
        XCTAssertEqual(sut.loadedTask(taskID)?.closedAt, closedBefore, "closedAt must not be re-stamped")
    }

    func testManageRoleAccept_chatModeManagerOwnTask_refusedBySelfGuard() async {
        let mgrID = await pinManager()
        let r = await sut.performAutovisorAction(.manageRole(taskID: mgrID, roleID: "any", verb: .accept))
        XCTAssertFalse(r.ok, "the self-guard must refuse acting on the manager's own task")
        XCTAssertTrue(r.message.contains("#\(mgrID)"))
    }

    /// A FAILED chat advisory role must NOT be force-finished to .done and auto-closed as
    /// success — that would erase the failure. Accept rejects it (preserving .failed).
    func testManageRoleAccept_chatModeFailedRole_rejectsWithoutErasingFailure() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(roles: [advisory("a")], statuses: ["a": .failed]) else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "a", verb: .accept))
        XCTAssertFalse(r.ok, "accept must not force-finish a failed chat role")
        XCTAssertTrue(r.message.contains("failed"), "the reject must surface the failure reason")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["a"], .failed, "failure must be preserved")
        XCTAssertNil(sut.loadedTask(taskID)?.closedAt, "a failed chat task must not be auto-closed as success")
    }

    // MARK: - finish_advisory parity on a chat task

    func testManageRoleFinishAdvisory_chatModeLastRole_alsoClosesTask() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(roles: [advisory("a")], statuses: ["a": .working]) else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "a", verb: .finishAdvisory))
        XCTAssertTrue(r.ok)
        XCTAssertNotNil(sut.loadedTask(taskID)?.closedAt, "finish_advisory on the last chat role also closes")
    }

    /// finish_advisory on an already-closed chat task must report already-closed, not
    /// re-run closeTask + re-stamp closedAt with a fresh "closed" success (the guard the
    /// .finishAdvisory arm now shares with applyAcceptRole).
    func testManageRoleFinishAdvisory_chatModeAlreadyClosedTask_failsWithoutReclosing() async {
        _ = await pinManager()
        guard let taskID = await makeChatTeamTask(roles: [advisory("a")], statuses: ["a": .done]) else { return }
        await sut.mutateTask(taskID: taskID) { $0.closedAt = MonotonicClock.shared.now() }
        let closedBefore = sut.loadedTask(taskID)?.closedAt
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "a", verb: .finishAdvisory))
        XCTAssertFalse(r.ok, "finish_advisory on a closed task must report already-closed")
        XCTAssertTrue(r.message.contains("already closed"))
        XCTAssertEqual(sut.loadedTask(taskID)?.closedAt, closedBefore, "closedAt must not be re-stamped")
    }
}
