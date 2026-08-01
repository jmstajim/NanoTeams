import XCTest
@testable import NanoTeams

/// Coverage for the running-role deferral predicate in
/// `NTMSRepository+Reconcile.scanRunningTeamRoles` / `pinsTeamAsBusy`.
///
/// Lives beside `NTMSRepositoryReconcileTests` (already ~680 lines) rather than
/// inside it, matching the `TeamIsInUseByActiveRunCornerTests` precedent.
///
/// ## Why the predicate is this narrow
///
/// Deferral is only ever meant to be TEMPORARY — the banner literally promises
/// "will retry on next open". That promise only holds if something HEALS the
/// status that caused the deferral, and only two healers exist:
///
///  * `openWorkFolder` recovers the ACTIVE task, and
///  * `recoverStaleStatusesAcrossIndex` recovers every task whose *derived
///    summary* status is `.running` / `.needsSupervisorInput`.
///
/// So the busy set must be a subset of "what recovery parks", or a deferral
/// becomes PERMANENT and the team's prompts never update again. Three ordinary
/// states used to fall outside it (pinned below): a paused task, a task sitting
/// at Review, and a closed task with a stranded role.
///
/// `ReconcileDeferralEquivalenceTests` pins the subset relation itself; the
/// tests here pin the end-to-end consequence through a real work folder.
final class NTMSRepositoryReconcileDeferralTests: XCTestCase {

    var sut: NTMSRepository!
    var tempDir: URL!
    var root: URL!
    private let fm = FileManager.default
    private var paths: NTMSPaths { NTMSPaths(workFolderRoot: root) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()
        tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        root = tempDir.appendingPathComponent("proj", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        sut = NTMSRepository()
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        sut = nil
        tempDir = nil
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private struct Fixture {
        let teamID: NTMSID
        let roleID: String
        let bundledPrompt: String
    }

    private static let staleEdit = "STALE USER EDIT"

    /// Seeds FAANG's Software Engineer prompt with a sentinel the reconcile is
    /// expected to overwrite, and returns the ids needed to fabricate a task.
    private func seedStaleFAANGPrompt() throws -> Fixture {
        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let teamIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "faang" })
        let roleIdx = try XCTUnwrap(
            teamsFile.teams[teamIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        let fixture = Fixture(
            teamID: teamsFile.teams[teamIdx].id,
            roleID: teamsFile.teams[teamIdx].roles[roleIdx].id,
            bundledPrompt: teamsFile.teams[teamIdx].roles[roleIdx].prompt
        )
        teamsFile.teams[teamIdx].roles[roleIdx].prompt = Self.staleEdit
        try store.write(teamsFile, to: paths.teamsJSON)
        return fixture
    }

    /// Writes one task + a matching index entry, then rewinds the watermark so
    /// the next open runs a reconcile pass.
    private func seedTask(
        _ task: NTMSTask,
        summaryStatus: TaskStatus
    ) throws {
        let store = AtomicJSONStore()
        try fm.createDirectory(
            at: paths.internalTaskDir(taskID: task.id), withIntermediateDirectories: true
        )
        try store.write(task, to: paths.taskJSON(taskID: task.id))
        try store.write(
            TasksIndex(
                schemaVersion: 1,
                tasks: [TaskSummary(id: task.id, title: task.title, status: summaryStatus)],
                nextTaskID: task.id + 1
            ),
            to: paths.tasksIndexJSON
        )
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        // The fabricated task is deliberately NOT the active task: `openWorkFolder`
        // always recovers the active one, which would mask every permanent-freeze
        // case these tests exist to catch.
        state.activeTaskID = nil
        try store.write(state, to: paths.workFolderJSON)
    }

    private func makeTask(
        id: Int = 0,
        title: String,
        roleStatuses: [String: RoleExecutionStatus],
        steps: [StepExecution],
        teamID: NTMSID,
        status: TaskStatus = .running,
        closedAt: Date? = nil
    ) -> NTMSTask {
        NTMSTask(
            id: id,
            title: title,
            supervisorTask: "fixture",
            status: status,
            runs: [Run(id: 0, steps: steps, roleStatuses: roleStatuses, teamID: teamID)],
            closedAt: closedAt,
            preferredTeamID: teamID
        )
    }

    private func reopenAndReadSEPrompt() throws -> String {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let after = try AtomicJSONStore().read(TeamsFile.self, from: paths.teamsJSON)
        let faang = try XCTUnwrap(after.teams.first { $0.templateID == "faang" })
        let se = try XCTUnwrap(faang.roles.first { $0.systemRoleID == "softwareEngineer" })
        return se.prompt
    }

    // MARK: - P0-a: a PAUSED task must not freeze its team

    /// `pauseRun` cancels executions and moves steps to `.paused`, but it never
    /// touches `roleStatuses` — so the role stays `.working`. The task's derived
    /// summary status is then `.paused`, which `recoverStaleStatusesAcrossIndex`
    /// filters OUT (`.running` / `.needsSupervisorInput` only), so unless it is
    /// the active task nothing ever heals the role.
    ///
    /// Treating that as "busy" is therefore a PERMANENT freeze, not a deferral:
    /// pause a task, update the app, and that team's prompts never move again.
    func testPausedTask_doesNotDeferReconcile() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Paused",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .paused)],
                teamID: f.teamID,
                status: .paused
            ),
            summaryStatus: .paused
        )

        XCTAssertEqual(
            try reopenAndReadSEPrompt(), f.bundledPrompt,
            "a paused task has no live tool loop and is never swept by status recovery — "
            + "deferring on it freezes the team's prompts permanently"
        )
    }

    // MARK: - P0-b: a task at Review must not freeze its team

    /// `RoleStepReconciler` returns `.noAction` for `.needsAcceptance` by design
    /// (it is a live Supervisor gate), so status recovery will NEVER heal it.
    /// The step underneath is terminal, so there is no tool loop to protect.
    func testNeedsAcceptanceRole_doesNotDeferReconcile() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "At review",
                roleStatuses: [f.roleID: .needsAcceptance],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .done)],
                teamID: f.teamID
            ),
            summaryStatus: .needsSupervisorAcceptance
        )

        XCTAssertEqual(
            try reopenAndReadSEPrompt(), f.bundledPrompt,
            "a role parked at Review is never healed by recovery — deferring on it is permanent"
        )
    }

    /// Same reasoning: `.revisionRequested` is `.noAction` in the reconciler, and
    /// its step is re-run by the engine only AFTER the folder is open, so a fresh
    /// tool schema is built either way.
    func testRevisionRequestedRole_doesNotDeferReconcile() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Revision",
                roleStatuses: [f.roleID: .revisionRequested],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .pending)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )

        XCTAssertEqual(try reopenAndReadSEPrompt(), f.bundledPrompt)
    }

    // MARK: - P1-c: a closed task must not pin its team

    /// `closeTask` normalizes role statuses via `finalizeRoleStatusesForClose`,
    /// but a folder closed by a build whose close pass only finalized
    /// `.needsAcceptance` can carry `closedAt` alongside a stranded `.working`.
    /// Nothing sweeps a closed task (it derives `.done`), so that is permanent.
    func testClosedTask_doesNotPinItsTeam() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Closed",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .running)],
                teamID: f.teamID,
                status: .done,
                closedAt: MonotonicClock.shared.now()
            ),
            summaryStatus: .done
        )

        XCTAssertEqual(
            try reopenAndReadSEPrompt(), f.bundledPrompt,
            "a closed task cannot be executing — resumeRun refuses it and createNewRun clears closedAt"
        )
    }

    // MARK: - Negatives — the predicate must not become a no-op

    /// The one shape that genuinely holds a live tool loop. This is also the
    /// shape recovery parks (`.running` step → `.paused`, `.working` role →
    /// `.idle`), so the deferral self-heals on the following open.
    func testWorkingRoleWithRunningStep_stillDefers() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Busy",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .running)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )

        XCTAssertEqual(
            try reopenAndReadSEPrompt(), Self.staleEdit,
            "a role mid-run must still be protected from a toolIDs rewrite"
        )
    }

    /// `.needsSupervisorInput` is the other half of the parked set — the step is
    /// suspended and will replay its `wireTranscript`, so its advertised tool
    /// catalog must not drift out from under it.
    func testWorkingRoleWithNeedsSupervisorInputStep_stillDefers() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Asking",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .needsSupervisorInput)],
                teamID: f.teamID
            ),
            summaryStatus: .needsSupervisorInput
        )

        XCTAssertEqual(try reopenAndReadSEPrompt(), Self.staleEdit)
    }

    /// A `.pending` step has not started, so it will build a fresh schema from
    /// whatever `toolIDs` says when it does. Nothing to protect.
    func testWorkingRoleWithPendingStep_doesNotDefer() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Not started",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .pending)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )

        XCTAssertEqual(try reopenAndReadSEPrompt(), f.bundledPrompt)
    }

    /// A role flipped to `.working` before its step exists. Excluded from the
    /// busy set for the SAME reason as `.pending` — but note the subtle case
    /// that forced it: paired with a `.paused` sibling step the task derives
    /// `.paused`, which recovery skips, so counting it busy would be permanent.
    func testWorkingRoleWithNoStep_doesNotDefer() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "No step yet",
                roleStatuses: [f.roleID: .working],
                steps: [],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )

        XCTAssertEqual(try reopenAndReadSEPrompt(), f.bundledPrompt)
    }

    // MARK: - Scan corners

    /// The index can name a task whose file was deleted out from under it. That
    /// is not evidence of anything, so it must neither defer nor fail closed.
    func testIndexEntryWithNoTaskFile_isSkipped() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        let store = AtomicJSONStore()
        try store.write(
            TasksIndex(
                schemaVersion: 1,
                tasks: [TaskSummary(id: 99, title: "Ghost", status: .running)],
                nextTaskID: 100
            ),
            to: paths.tasksIndexJSON
        )
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        state.activeTaskID = nil
        try store.write(state, to: paths.workFolderJSON)

        XCTAssertEqual(try reopenAndReadSEPrompt(), f.bundledPrompt)
    }

    func testEmptyTasksIndex_reconcilesEverything() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        let store = AtomicJSONStore()
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        XCTAssertEqual(try reopenAndReadSEPrompt(), f.bundledPrompt)
    }

    /// A busy DELEGATED child lives at `tasks/{parent}/subtasks/{child}/`, so the
    /// scan has to resolve its path through `TasksIndex.ancestorIDs`. If it
    /// silently read the flat path instead, the file wouldn't exist and a
    /// genuinely running child team would be reconciled mid-run.
    func testBusyDelegatedChild_defersItsTeam() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        let store = AtomicJSONStore()
        // Parent: idle, root. Child: busy, nested under the parent.
        try fm.createDirectory(
            at: paths.internalTaskDir(taskID: 0), withIntermediateDirectories: true
        )
        try store.write(
            makeTask(id: 0, title: "Parent", roleStatuses: [:], steps: [], teamID: f.teamID),
            to: paths.taskJSON(taskID: 0)
        )
        try fm.createDirectory(
            at: paths.internalTaskDir(taskID: 1, ancestors: [0]), withIntermediateDirectories: true
        )
        var child = makeTask(
            id: 1,
            title: "Child",
            roleStatuses: [f.roleID: .working],
            steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                  title: "SE", status: .running)],
            teamID: f.teamID
        )
        child = NTMSTask(
            id: 1, title: child.title, supervisorTask: child.supervisorTask,
            status: .running, runs: child.runs, preferredTeamID: f.teamID,
            parentTaskID: 0, parentRoleID: "parent_role", delegationDepth: 1
        )
        try store.write(child, to: paths.taskJSON(taskID: 1, ancestors: [0]))

        try store.write(
            TasksIndex(
                schemaVersion: 1,
                tasks: [
                    TaskSummary(id: 0, title: "Parent", status: .running),
                    TaskSummary(id: 1, title: "Child", status: .running, parentTaskID: 0)
                ],
                nextTaskID: 2
            ),
            to: paths.tasksIndexJSON
        )
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        state.activeTaskID = nil
        try store.write(state, to: paths.workFolderJSON)

        XCTAssertEqual(
            try reopenAndReadSEPrompt(), Self.staleEdit,
            "a nested child's task.json must be found via its ancestor path"
        )
    }

    /// Several tasks blocking one team fold into ONE reported entry, with the
    /// extra tasks counted rather than dropped and the role names deduped.
    func testSeveralTasksBlockingOneTeam_foldIntoOneReport() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        let store = AtomicJSONStore()
        for id in 0...2 {
            try fm.createDirectory(
                at: paths.internalTaskDir(taskID: id), withIntermediateDirectories: true
            )
            try store.write(
                makeTask(
                    id: id,
                    title: "Busy \(id)",
                    roleStatuses: [f.roleID: .working],
                    steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                          title: "SE", status: .running)],
                    teamID: f.teamID
                ),
                to: paths.taskJSON(taskID: id)
            )
        }
        try store.write(
            TasksIndex(
                schemaVersion: 1,
                tasks: (0...2).map { TaskSummary(id: $0, title: "Busy \($0)", status: .running) },
                nextTaskID: 3
            ),
            to: paths.tasksIndexJSON
        )
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        state.activeTaskID = nil
        try store.write(state, to: paths.workFolderJSON)

        let ctx = try sut.openOrCreateWorkFolder(at: root)
        let report = try XCTUnwrap(ctx.bundledUpdate)

        XCTAssertEqual(report.deferred.count, 1, "one team, not one entry per task")
        let entry = try XCTUnwrap(report.deferred.first)
        XCTAssertEqual(entry.otherBlockingTaskCount, 2, "the other two must be counted, not dropped")
        XCTAssertEqual(entry.roleNames, ["Software Engineer"], "the same role must not repeat")
        XCTAssertEqual(entry.teamID, f.teamID)

        let after = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertEqual(after.pendingReconcileTeamIDs, [f.teamID],
                       "one id, not one per blocking task")
    }

    /// A team pinned by `task.generatedTeam` (delegation / Generated Team) is
    /// never templated, so it must not appear as a deferral — but it also must
    /// not be mistaken for the task's `preferredTeamID` team.
    func testGeneratedTeamTask_doesNotDeferTheStoredTeam() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        let generated = TeamTemplateFactory.empty(name: "Gen Worker")
        var task = makeTask(
            title: "Delegated",
            roleStatuses: [f.roleID: .working],
            steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                  title: "SE", status: .running)],
            teamID: f.teamID
        )
        task.adoptGeneratedTeam(generated)
        try seedTask(task, summaryStatus: .running)

        XCTAssertEqual(
            try reopenAndReadSEPrompt(), f.bundledPrompt,
            "the busy team is the generated one — FAANG is not running and must reconcile"
        )
    }

    // MARK: - P1-b: the scan must use the run pin, not preferredTeamID

    /// A task whose `preferredTeamID` names a team deleted before its first run
    /// gets pinned to whatever `TeamResolution` fell back to. The scan used to
    /// read `preferredTeamID` directly, so it deferred a team that wasn't running
    /// (freezing it) and left the team that WAS running free to have its
    /// `toolIDs` rewritten mid-flight — the exact hazard deferral exists for.
    func testScanUsesRunPin_whenPreferredTeamIDIsStale() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)

        // FAANG is the team actually running; Startup must stay untouched-by-deferral.
        let faangIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "faang" })
        let faangID = teamsFile.teams[faangIdx].id
        let seIdx = try XCTUnwrap(
            teamsFile.teams[faangIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        let seRoleID = teamsFile.teams[faangIdx].roles[seIdx].id
        teamsFile.teams[faangIdx].roles[seIdx].prompt = Self.staleEdit

        let startupIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "startup" })
        let startupSEIdx = try XCTUnwrap(
            teamsFile.teams[startupIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        let startupBundledPrompt = teamsFile.teams[startupIdx].roles[startupSEIdx].prompt
        teamsFile.teams[startupIdx].roles[startupSEIdx].prompt = Self.staleEdit
        try store.write(teamsFile, to: paths.teamsJSON)

        // The run is PINNED to FAANG while `preferredTeamID` still names a team
        // that no longer exists.
        var task = makeTask(
            title: "Pinned to FAANG",
            roleStatuses: [seRoleID: .working],
            steps: [StepExecution(id: seRoleID, role: .softwareEngineer,
                                  title: "SE", status: .running)],
            teamID: faangID
        )
        task.preferredTeamID = "deleted_team"
        try seedTask(task, summaryStatus: .running)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let faang = try XCTUnwrap(after.teams.first { $0.templateID == "faang" })
        let faangSE = try XCTUnwrap(faang.roles.first { $0.systemRoleID == "softwareEngineer" })
        XCTAssertEqual(faangSE.prompt, Self.staleEdit,
                       "the run-pinned team is the one actually running — it must defer")

        let startup = try XCTUnwrap(after.teams.first { $0.templateID == "startup" })
        let startupSE = try XCTUnwrap(startup.roles.first { $0.systemRoleID == "softwareEngineer" })
        XCTAssertEqual(startupSE.prompt, startupBundledPrompt,
                       "an unrelated team must not be dragged into the deferral")

        let state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertEqual(state.pendingReconcileTeamIDs, [faangID])
    }

    /// The scan's `activeTeamID` fallback, exercised DIRECTLY.
    ///
    /// The end-to-end path can't reach it: `loadOrRecoverFiles` repairs a
    /// dangling `activeTeamID` to `teams.first` and writes it back before
    /// `migrateIfNeeded` ever runs, so an integration test of this would pass
    /// because of the repair, not because of the fallback. Calling the scan
    /// directly is the only way to assert the mirror of
    /// `WorkFolderProjection.activeTeam` actually holds.
    func testScan_unresolvableActiveTeamID_fallsBackToFirstTeam() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        let teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let firstTeam = try XCTUnwrap(teamsFile.teams.first)
        let roleID = try XCTUnwrap(firstTeam.roles.first { !$0.isSupervisor }?.id)

        // Legacy shape: no generatedTeam, no run pin, no preferredTeamID.
        let legacy = NTMSTask(
            id: 0,
            title: "Legacy",
            supervisorTask: "fixture",
            status: .running,
            runs: [Run(id: 0,
                       steps: [StepExecution(id: roleID, role: .softwareEngineer,
                                             title: "R", status: .running)],
                       roleStatuses: [roleID: .working],
                       teamID: nil)],
            preferredTeamID: nil
        )
        try fm.createDirectory(
            at: paths.internalTaskDir(taskID: 0), withIntermediateDirectories: true
        )
        try store.write(legacy, to: paths.taskJSON(taskID: 0))

        let index = TasksIndex(
            schemaVersion: 1,
            tasks: [TaskSummary(id: 0, title: "Legacy", status: .running)],
            nextTaskID: 1
        )

        let result = sut.scanRunningTeamRoles(
            tasksIndex: index,
            teams: teamsFile.teams,
            activeTeamID: "team_that_no_longer_exists",
            paths: paths
        )
        guard case .clean(let byTeam) = result else {
            return XCTFail("expected a clean scan, got \(result)")
        }
        XCTAssertEqual(
            Set(byTeam.keys), [firstTeam.id],
            "an unresolvable activeTeamID must fall back to teams.first, mirroring "
            + "WorkFolderProjection.activeTeam"
        )
    }

    /// The same legacy shape end to end. This one passes through the upstream
    /// `loadOrRecoverFiles` repair, so it proves the no-pin task defers the
    /// ACTIVE team — not the fallback itself (see the test above for that).
    func testLegacyTaskWithNoPin_defersTheActiveTeam() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        // Whatever team is first is what `activeTeam` resolves to.
        let firstIdx = 0
        let firstTeamID = teamsFile.teams[firstIdx].id
        let roleIdx = try XCTUnwrap(
            teamsFile.teams[firstIdx].roles.firstIndex { !$0.isSupervisor }
        )
        let roleID = teamsFile.teams[firstIdx].roles[roleIdx].id
        teamsFile.teams[firstIdx].roles[roleIdx].prompt = Self.staleEdit
        try store.write(teamsFile, to: paths.teamsJSON)

        // No generatedTeam, no run pin, no preferredTeamID — the legacy shape.
        let legacy = NTMSTask(
            id: 0,
            title: "Legacy",
            supervisorTask: "fixture",
            status: .running,
            runs: [Run(id: 0,
                       steps: [StepExecution(id: roleID, role: .softwareEngineer,
                                             title: "R", status: .running)],
                       roleStatuses: [roleID: .working],
                       teamID: nil)],
            preferredTeamID: nil
        )
        try fm.createDirectory(
            at: paths.internalTaskDir(taskID: 0), withIntermediateDirectories: true
        )
        try store.write(legacy, to: paths.taskJSON(taskID: 0))
        try store.write(
            TasksIndex(
                schemaVersion: 1,
                tasks: [TaskSummary(id: 0, title: "Legacy", status: .running)],
                nextTaskID: 1
            ),
            to: paths.tasksIndexJSON
        )

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        state.activeTeamID = "team_that_no_longer_exists"
        state.activeTaskID = nil
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let firstTeam = try XCTUnwrap(after.teams.first { $0.id == firstTeamID })
        let role = try XCTUnwrap(firstTeam.roles.first { $0.id == roleID })
        XCTAssertEqual(
            role.prompt, Self.staleEdit,
            "the busy team is whatever `activeTeam` resolves to — here, teams.first"
        )
    }

    // MARK: - P1-a: a deferral must not hold the watermark

    /// The watermark advances even when a team defers; the outstanding team is
    /// carried in `pendingReconcileTeamIDs` instead.
    func testDeferral_advancesWatermark_andRecordsPendingTeam() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Busy",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .running)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )

        _ = try sut.openOrCreateWorkFolder(at: root)

        let state = try AtomicJSONStore().read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertFalse(state.lastAppliedAppVersion.isEmpty,
                       "watermark must advance so other teams aren't re-reconciled every launch")
        XCTAssertEqual(state.pendingReconcileTeamIDs, [f.teamID],
                       "the deferred team must be carried for a scoped retry")
    }

    /// The payoff: with the watermark advancing, a team that already reconciled
    /// keeps a later user edit instead of having it clobbered on every launch by
    /// a full re-run triggered by some OTHER team's deferral.
    func testDeferral_doesNotReclobberOtherTeamsOnNextOpen() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Busy",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .running)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )
        _ = try sut.openOrCreateWorkFolder(at: root)

        // FAANG deferred. Now edit a DIFFERENT team that did reconcile.
        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let otherIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "startup" })
        let otherRoleIdx = try XCTUnwrap(
            teamsFile.teams[otherIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        teamsFile.teams[otherIdx].roles[otherRoleIdx].prompt = "MY DELIBERATE EDIT"
        try store.write(teamsFile, to: paths.teamsJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let startup = try XCTUnwrap(after.teams.first { $0.templateID == "startup" })
        let se = try XCTUnwrap(startup.roles.first { $0.systemRoleID == "softwareEngineer" })
        XCTAssertEqual(
            se.prompt, "MY DELIBERATE EDIT",
            "a still-deferred sibling must not drag every other team through a full re-reconcile"
        )
    }

    /// Once the busy task settles, the scoped retry lands without a version bump.
    func testPendingSet_retriesScopedPass_withoutVersionBump() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Busy",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .running)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        XCTAssertEqual(try reopenAndReadSEPrompt(), Self.staleEdit, "still busy → still deferred")

        // Simulate what status recovery does once the run is no longer live.
        var task = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: 0))
        task.runs[0].steps[0].status = .paused
        task.runs[0].roleStatuses[f.roleID] = .idle
        try store.write(task, to: paths.taskJSON(taskID: 0))

        // No version rewind: the pending set alone must reopen the gate.
        XCTAssertEqual(try reopenAndReadSEPrompt(), f.bundledPrompt)

        let state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertTrue(state.pendingReconcileTeamIDs.isEmpty,
                      "a settled retry must clear the pending set")
    }

    /// A deferred team the user later deletes must not keep the gate open forever.
    func testPendingSet_prunesIDsForDeletedTeams() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Busy",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .running)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        teamsFile.teams.removeAll { $0.id == f.teamID }
        try store.write(teamsFile, to: paths.teamsJSON)
        // Tombstone it too, or bootstrap re-adds the template on the next open.
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.deletedTeamTemplateIDs.append("faang")
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertTrue(after.pendingReconcileTeamIDs.isEmpty,
                      "an id for a deleted team must be pruned, not retried forever")
    }

    /// A scoped retry must touch ONLY the teams that still owe a pass. This is
    /// the whole safety of decoupling the watermark: if a `.only` pass silently
    /// widened to everything, it would re-clobber edits on teams that already
    /// reconciled — the exact damage the pending set exists to stop.
    func testScopedRetry_leavesOutOfScopeTeamsAlone() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        // Defer FAANG so the pending set is non-empty.
        try seedTask(
            makeTask(
                title: "Busy",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .running)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Now dirty an out-of-scope team AND leave FAANG busy.
        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let otherIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "engineering" })
        let otherRoleIdx = try XCTUnwrap(
            teamsFile.teams[otherIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        teamsFile.teams[otherIdx].roles[otherRoleIdx].prompt = "OUT OF SCOPE EDIT"
        try store.write(teamsFile, to: paths.teamsJSON)

        // No version rewind — only the pending set reopens the gate.
        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let engineering = try XCTUnwrap(after.teams.first { $0.templateID == "engineering" })
        let se = try XCTUnwrap(engineering.roles.first { $0.systemRoleID == "softwareEngineer" })
        XCTAssertEqual(
            se.prompt, "OUT OF SCOPE EDIT",
            "a scoped retry must not reach a team that already reconciled at this version"
        )
    }

    /// A version bump while teams are still pending must run the FULL pass —
    /// the new version's content applies to everything, not just the stragglers.
    func testVersionBump_whilePending_runsAFullPass() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Busy",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .running)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let otherIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "engineering" })
        let otherRoleIdx = try XCTUnwrap(
            teamsFile.teams[otherIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        let bundled = TeamTemplateFactory.engineering().roles
            .first { $0.systemRoleID == "softwareEngineer" }?.prompt
        teamsFile.teams[otherIdx].roles[otherRoleIdx].prompt = "STALE"
        try store.write(teamsFile, to: paths.teamsJSON)

        // Rewind the watermark → this is a bump, so scope widens to everything.
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let engineering = try XCTUnwrap(after.teams.first { $0.templateID == "engineering" })
        let se = try XCTUnwrap(engineering.roles.first { $0.systemRoleID == "softwareEngineer" })
        XCTAssertEqual(se.prompt, bundled, "a version bump re-applies every templated team")
    }

    /// A still-busy team stays pending across repeated opens without the set
    /// growing or the watermark flapping.
    func testStillBusyTeam_staysPending_idempotently() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        try seedTask(
            makeTask(
                title: "Busy",
                roleStatuses: [f.roleID: .working],
                steps: [StepExecution(id: f.roleID, role: .softwareEngineer,
                                      title: "SE", status: .running)],
                teamID: f.teamID
            ),
            summaryStatus: .running
        )

        let store = AtomicJSONStore()
        var stamped: String?
        for _ in 0..<3 {
            _ = try sut.openOrCreateWorkFolder(at: root)
            let state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
            XCTAssertEqual(state.pendingReconcileTeamIDs, [f.teamID])
            if let stamped {
                XCTAssertEqual(state.lastAppliedAppVersion, stamped, "watermark must not flap")
            }
            stamped = state.lastAppliedAppVersion
        }
    }

    // MARK: - P0-c: the scan must not be poisoned by one bad file

    /// Nothing ever auto-recovers an individual `task.json`, so fail-closing the
    /// whole pass on one froze bundled updates for EVERY team in the folder,
    /// permanently. A task that won't decode also cannot be running — `loadTask`,
    /// `createNewRun` and `resumeRun` all bail on it — so it is safe to skip.
    func testUndecodableTaskJSON_skipsThatTaskOnly() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        let store = AtomicJSONStore()
        // Task 0: garbage. Task 1: perfectly readable and idle.
        try fm.createDirectory(
            at: paths.internalTaskDir(taskID: 0), withIntermediateDirectories: true
        )
        try Data("this is not json".utf8).write(to: paths.taskJSON(taskID: 0))
        try fm.createDirectory(
            at: paths.internalTaskDir(taskID: 1), withIntermediateDirectories: true
        )
        try store.write(
            makeTask(id: 1, title: "Idle", roleStatuses: [f.roleID: .done],
                     steps: [], teamID: f.teamID),
            to: paths.taskJSON(taskID: 1)
        )
        try store.write(
            TasksIndex(
                schemaVersion: 1,
                tasks: [TaskSummary(id: 0, title: "Broken", status: .running),
                        TaskSummary(id: 1, title: "Idle", status: .done)],
                nextTaskID: 2
            ),
            to: paths.tasksIndexJSON
        )
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        state.activeTaskID = nil
        try store.write(state, to: paths.workFolderJSON)

        XCTAssertEqual(
            try reopenAndReadSEPrompt(), f.bundledPrompt,
            "one undecodable task.json must not freeze bundled updates for the whole folder"
        )
    }

    /// A corrupt index is recovered by `loadOrRecoverFile` in the SAME open, so
    /// hoisting that load above `migrateIfNeeded` lets the reconcile land
    /// immediately instead of costing an extra launch.
    func testCorruptTasksIndex_reconcilesInOneOpen() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        let store = AtomicJSONStore()
        try Data("this is not json".utf8).write(to: paths.tasksIndexJSON)
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        XCTAssertEqual(
            try reopenAndReadSEPrompt(), f.bundledPrompt,
            "the index is recovered in this same open — the scan must see the recovered copy"
        )
        let after = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertFalse(after.lastAppliedAppVersion.isEmpty,
                       "nothing was deferred, so the watermark must advance")
    }

    /// An I/O failure (here: a directory where `task.json` should be) says nothing
    /// about whether the task is running, so the pass stays fail-closed — but the
    /// Autovisor carve-out and the additive tools merge must still apply.
    func testUnreadableTaskJSON_failsClosed_butStillReconcilesAutovisor() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        var autovisor = TeamTemplateFactory.autovisor()
        let mgrIdx = try XCTUnwrap(autovisor.roles.firstIndex {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        })
        let bundledManagerPrompt = autovisor.roles[mgrIdx].prompt
        autovisor.roles[mgrIdx].prompt = "OLD BUILD PROMPT"
        teamsFile.teams.append(autovisor)
        try store.write(teamsFile, to: paths.teamsJSON)

        // A directory at the task.json path → `Data(contentsOf:)` throws a
        // CocoaError, not a DecodingError.
        try fm.createDirectory(
            at: paths.taskJSON(taskID: 0), withIntermediateDirectories: true
        )
        try store.write(
            TasksIndex(
                schemaVersion: 1,
                tasks: [TaskSummary(id: 0, title: "Unreadable", status: .running)],
                nextTaskID: 1
            ),
            to: paths.tasksIndexJSON
        )
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        state.activeTaskID = nil
        try store.write(state, to: paths.workFolderJSON)

        XCTAssertEqual(
            try reopenAndReadSEPrompt(), Self.staleEdit,
            "an I/O error must stay fail-closed for ordinary teams"
        )

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let afterAutovisor = try XCTUnwrap(
            after.teams.first { $0.templateID == AutovisorConstants.teamTemplateID }
        )
        let afterMgr = try XCTUnwrap(afterAutovisor.roles.first {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        })
        XCTAssertEqual(
            afterMgr.prompt, bundledManagerPrompt,
            "the Autovisor carve-out must apply in the fail-closed arm too, or an enabled "
            + "Autovisor holds the watermark on every open"
        )
    }

    /// The exact shape that makes the `nil`-step exclusion load-bearing: the
    /// busy role has no step, a sibling step is `.paused`, so the task derives
    /// `.paused` and recovery never visits it.
    func testWorkingRoleWithNoStep_besidePausedSibling_doesNotDefer() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let f = try seedStaleFAANGPrompt()

        let store = AtomicJSONStore()
        let teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let faang = try XCTUnwrap(teamsFile.teams.first { $0.templateID == "faang" })
        let otherRoleID = try XCTUnwrap(
            faang.roles.first { $0.systemRoleID == "codeReviewer" }?.id
        )

        try seedTask(
            makeTask(
                title: "Paused sibling",
                roleStatuses: [f.roleID: .working, otherRoleID: .working],
                steps: [StepExecution(id: otherRoleID, role: .codeReviewer,
                                      title: "CR", status: .paused)],
                teamID: f.teamID,
                status: .paused
            ),
            summaryStatus: .paused
        )

        XCTAssertEqual(try reopenAndReadSEPrompt(), f.bundledPrompt)
    }
}
