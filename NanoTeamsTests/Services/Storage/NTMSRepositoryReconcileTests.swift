import XCTest
@testable import NanoTeams

/// End-to-end tests for the version-bump reconcile pass in
/// `NTMSRepository+Bootstrap.migrateIfNeeded`. Because `AppVersion.current`
/// is driven by `CFBundleShortVersionString` and can't be easily stubbed,
/// these tests drive reconcile indirectly: a work folder opened once will
/// have `lastAppliedAppVersion == AppVersion.current`; we then rewind that
/// version on disk to simulate "bundled content has moved on since last open",
/// re-open, and assert reconcile ran. The inverse (downgrade = no-op) proves
/// the guard direction is correct.
final class NTMSRepositoryReconcileTests: XCTestCase {

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

    // MARK: - First-open reconcile

    func testFirstOpen_stampsLastAppliedAppVersion() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let state = try AtomicJSONStore().read(WorkFolderState.self, from: paths.workFolderJSON)
        // Non-empty after first reconcile. Can't assert the specific value —
        // it depends on the test bundle's CFBundleShortVersionString, which
        // may be absent in the test target's Info.plist (falls back to "0.0.0").
        XCTAssertFalse(state.lastAppliedAppVersion.isEmpty,
                       "first open must stamp the current app version")
    }

    func testFirstOpen_bumpsSchemaToCurrentVersion() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let state = try AtomicJSONStore().read(WorkFolderState.self, from: paths.workFolderJSON)
        // WorkFolderState is at schemaVersion 8 (gained `pendingReconcileTeamIDs`).
        XCTAssertEqual(state.schemaVersion, 8)
    }

    // MARK: - Version-bump triggers reconcile

    func testVersionBump_rewritesMutatedRolePrompt() throws {
        // First open — reconcile runs, everything in sync.
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Simulate user having manually edited a system role's prompt between
        // versions (via TeamEditor). Reconcile should restore it.
        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let faangIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "faang" })
        let seRoleIdx = try XCTUnwrap(
            teamsFile.teams[faangIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        let originalPrompt = teamsFile.teams[faangIdx].roles[seRoleIdx].prompt
        teamsFile.teams[faangIdx].roles[seRoleIdx].prompt = "STALE USER EDIT"
        try store.write(teamsFile, to: paths.teamsJSON)

        // Rewind recorded version — simulates "app has been upgraded since
        // this folder was last reconciled" without needing to stub
        // AppVersion.current.
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        // Re-open — reconcile pass should restore the canonical prompt.
        _ = try sut.openOrCreateWorkFolder(at: root)

        let reconciled = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let newIdx = try XCTUnwrap(reconciled.teams.firstIndex { $0.templateID == "faang" })
        let seIdx = try XCTUnwrap(
            reconciled.teams[newIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        XCTAssertEqual(reconciled.teams[newIdx].roles[seIdx].prompt, originalPrompt,
                       "reconcile must overwrite stale system-role scalar fields")
    }

    /// "bash enabled by default for code-writing roles" must reach EXISTING work
    /// folders, not just freshly-bootstrapped ones. The version-bump reconcile
    /// rewrites system-role `toolIDs` unconditionally — so a folder seeded by an
    /// older build (whose Software Engineer lacked bash) gains it on the next open
    /// after an app upgrade. Pins the migration path the default-bash change relies on.
    func testVersionBump_restoresBashToolForSoftwareEngineer() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Simulate a folder seeded by a pre-bash build: strip bash + bash_output
        // from FAANG's Software Engineer toolIDs.
        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let faangIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "faang" })
        let seIdx = try XCTUnwrap(
            teamsFile.teams[faangIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        teamsFile.teams[faangIdx].roles[seIdx].toolIDs.removeAll {
            $0 == ToolNames.bash || $0 == ToolNames.bashOutput
        }
        try store.write(teamsFile, to: paths.teamsJSON)

        // Rewind the watermark so reconcile wants to run on reopen.
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let reconciled = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let newIdx = try XCTUnwrap(reconciled.teams.firstIndex { $0.templateID == "faang" })
        let se = try XCTUnwrap(
            reconciled.teams[newIdx].roles.first { $0.systemRoleID == "softwareEngineer" }
        )
        XCTAssertTrue(se.toolIDs.contains(ToolNames.bash),
                      "version-bump reconcile must restore bash to the Software Engineer")
        XCTAssertTrue(se.toolIDs.contains(ToolNames.bashOutput),
                      "version-bump reconcile must restore bash_output to the Software Engineer")

        // A review role in the same team must stay shell-free after reconcile.
        let reviewer = try XCTUnwrap(
            reconciled.teams[newIdx].roles.first { $0.systemRoleID == "codeReviewer" }
        )
        XCTAssertFalse(reviewer.toolIDs.contains(ToolNames.bash),
                       "reconcile must not grant bash to review roles")
    }

    /// The Autovisor team is bundled but hidden (not in `Team.defaultTeams`), so the
    /// reconcile pass indexes it explicitly. A version bump must refresh the manager
    /// role's prompt to the bundled text WITHOUT resetting user-toggled optional tools
    /// — the manager's tool policy is additive by design (`syncAutovisorTeamToTemplate`
    /// union-enforces mandatory tools and never removes user-disabled optional ones).
    func testVersionBump_refreshesAutovisorManagerPrompt_preservingToolToggles() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        var autovisor = TeamTemplateFactory.autovisor()
        let managerIdx = try XCTUnwrap(autovisor.roles.firstIndex {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        })
        let bundledPrompt = autovisor.roles[managerIdx].prompt
        // Simulate a team seeded by an older build: stale prompt + the user having
        // switched OFF an optional tool (a persisted choice, NOT union-enforced).
        autovisor.roles[managerIdx].prompt = "OLD BUILD PROMPT"
        autovisor.roles[managerIdx].toolIDs.removeAll { $0 == ToolNames.analyzeImage }
        teamsFile.teams.append(autovisor)
        try store.write(teamsFile, to: paths.teamsJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let reconciled = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let teamIdx = try XCTUnwrap(reconciled.teams.firstIndex {
            $0.templateID == AutovisorConstants.teamTemplateID
        })
        let roleIdx = try XCTUnwrap(reconciled.teams[teamIdx].roles.firstIndex {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        })
        XCTAssertEqual(reconciled.teams[teamIdx].roles[roleIdx].prompt, bundledPrompt,
                       "version bump must refresh the hidden Autovisor team's manager prompt")
        XCTAssertFalse(
            reconciled.teams[teamIdx].roles[roleIdx].toolIDs.contains(ToolNames.analyzeImage),
            "reconcile must not resurrect a user-disabled optional tool"
        )
    }

    /// Group delivery for existing managers: a stored manager from a build that
    /// PREDATES an optional-tool group (zero tools of it present) receives the
    /// whole group on version bump.
    func testVersionBump_deliversNewOptionalToolGroup_toVirginManager() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        var autovisor = TeamTemplateFactory.autovisor()
        let managerIdx = try XCTUnwrap(autovisor.roles.firstIndex {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        })
        // Older build: no computer-use group at all.
        let group = try XCTUnwrap(AutovisorConstants.managerOptionalToolGroups.first)
        autovisor.roles[managerIdx].toolIDs.removeAll { group.contains($0) }
        teamsFile.teams.append(autovisor)
        try store.write(teamsFile, to: paths.teamsJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let reconciled = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let manager = try XCTUnwrap(reconciled.teams
            .first { $0.templateID == AutovisorConstants.teamTemplateID }?
            .roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID })
        XCTAssertTrue(Set(group).isSubset(of: Set(manager.toolIDs)),
                      "version bump must deliver the whole never-offered group")
    }

    /// Two consecutive version bumps must not duplicate group members: the
    /// first delivers (group absent), the second sees the group present and
    /// skips. A duplicate toolID would double-render the tool row in the
    /// role editor and silently break Set-based comparisons.
    func testVersionBump_groupDelivery_isIdempotentAcrossBumps() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        var autovisor = TeamTemplateFactory.autovisor()
        let managerIdx = try XCTUnwrap(autovisor.roles.firstIndex {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        })
        let group = try XCTUnwrap(AutovisorConstants.managerOptionalToolGroups.first)
        autovisor.roles[managerIdx].toolIDs.removeAll { group.contains($0) }
        teamsFile.teams.append(autovisor)
        try store.write(teamsFile, to: paths.teamsJSON)

        // Two rewind → reopen cycles = two version-bump reconciles.
        for _ in 0..<2 {
            var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
            state.lastAppliedAppVersion = ""
            try store.write(state, to: paths.workFolderJSON)
            _ = try sut.openOrCreateWorkFolder(at: root)
        }

        let reconciled = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let manager = try XCTUnwrap(reconciled.teams
            .first { $0.templateID == AutovisorConstants.teamTemplateID }?
            .roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID })
        for tool in group {
            XCTAssertEqual(manager.toolIDs.filter { $0 == tool }.count, 1,
                           "\(tool) must appear exactly once after repeated bumps")
        }
    }

    /// The counterpart boundary: a PARTIALLY present group means the user has
    /// seen it and pruned — the reconcile must not re-add the pruned member.
    func testVersionBump_partiallyPrunedGroup_keepsUserToggles() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        var autovisor = TeamTemplateFactory.autovisor()
        let managerIdx = try XCTUnwrap(autovisor.roles.firstIndex {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        })
        // User switched off ONE tool of the group; the rest remain.
        autovisor.roles[managerIdx].toolIDs.removeAll { $0 == ToolNames.uiScroll }
        teamsFile.teams.append(autovisor)
        try store.write(teamsFile, to: paths.teamsJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let reconciled = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let manager = try XCTUnwrap(reconciled.teams
            .first { $0.templateID == AutovisorConstants.teamTemplateID }?
            .roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID })
        XCTAssertFalse(manager.toolIDs.contains(ToolNames.uiScroll),
                       "a pruned member of a seen group must stay pruned")
        XCTAssertTrue(manager.toolIDs.contains(ToolNames.screenCapture),
                      "the remaining group members are untouched")
    }

    /// The Autovisor manager parks at `.needsSupervisorInput` at the end of every
    /// review pass while its role status stays `.working` — if that deferred
    /// reconcile like other teams, an enabled Autovisor would hold the watermark
    /// on EVERY open and bundled updates would never land anywhere. Reconciling
    /// it despite the active role is safe because the autovisor branch never
    /// rewrites toolIDs (the only thing deferral protects).
    func testRunningAutovisorRole_doesNotDeferReconcile() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        var autovisor = TeamTemplateFactory.autovisor()
        let managerIdx = try XCTUnwrap(autovisor.roles.firstIndex {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        })
        let bundledPrompt = autovisor.roles[managerIdx].prompt
        let managerRoleID = autovisor.roles[managerIdx].id
        autovisor.roles[managerIdx].prompt = "OLD BUILD PROMPT"
        let autovisorTeamID = autovisor.id
        teamsFile.teams.append(autovisor)
        try store.write(teamsFile, to: paths.teamsJSON)

        // Fabricate the parked manager task: role status .working (how a parked
        // pass persists) pointing at the autovisor team.
        try fm.createDirectory(
            at: paths.internalTaskDir(taskID: 0), withIntermediateDirectories: true
        )
        // The step must be `.needsSupervisorInput` (how a parked pass really
        // persists), not absent: `pinsTeamAsBusy` requires a LIVE step, so with
        // `steps: []` this test would pass because the predicate stopped
        // matching rather than because the Autovisor carve-out fired.
        let run = Run(
            id: 0,
            steps: [StepExecution(id: managerRoleID, role: .autovisor, title: "Review",
                                  status: .needsSupervisorInput)],
            roleStatuses: [managerRoleID: .working],
            teamID: autovisorTeamID
        )
        let task = NTMSTask(
            id: 0,
            title: "Autovisor",
            supervisorTask: "review",
            status: .running,
            runs: [run],
            preferredTeamID: autovisorTeamID
        )
        try store.write(task, to: paths.taskJSON(taskID: 0))
        let index = TasksIndex(
            schemaVersion: 1,
            tasks: [TaskSummary(id: 0, title: "Autovisor", status: .running)],
            nextTaskID: 1
        )
        try store.write(index, to: paths.tasksIndexJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        let stampedBeforeReopen = state.lastAppliedAppVersion
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let reconciled = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let team = try XCTUnwrap(reconciled.teams.first {
            $0.templateID == AutovisorConstants.teamTemplateID
        })
        let manager = try XCTUnwrap(team.roles.first {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        })
        XCTAssertEqual(manager.prompt, bundledPrompt,
                       "an active manager role must not defer the autovisor reconcile")
        let stateAfter = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertEqual(stateAfter.lastAppliedAppVersion, stampedBeforeReopen,
                       "watermark must advance — only the autovisor team was active")
    }

    func testSameVersionRerun_isNoop() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        let teamsBefore = try Data(contentsOf: paths.teamsJSON)
        let toolsBefore = try Data(contentsOf: paths.toolsJSON)
        let stateBefore = try store.read(WorkFolderState.self, from: paths.workFolderJSON)

        // Open a second time without touching any state — reconcile compares
        // `current == lastApplied` and must do nothing.
        _ = try sut.openOrCreateWorkFolder(at: root)

        let teamsAfter = try Data(contentsOf: paths.teamsJSON)
        let toolsAfter = try Data(contentsOf: paths.toolsJSON)
        let stateAfter = try store.read(WorkFolderState.self, from: paths.workFolderJSON)

        XCTAssertEqual(teamsBefore, teamsAfter, "teams.json must not be rewritten on same-version reopen")
        XCTAssertEqual(toolsBefore, toolsAfter, "tools.json must not be rewritten on same-version reopen")
        XCTAssertEqual(stateBefore.lastAppliedAppVersion, stateAfter.lastAppliedAppVersion)
    }

    // MARK: - Tombstone respect

    func testMissingBootstrap_respectsDeletedTeamTombstone() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()

        // Simulate user having deleted the "faang" template (via TeamEditor),
        // which writes into `deletedTeamTemplateIDs` AND removes the team
        // entry. On next open, `migrateIfNeeded` must NOT re-add faang.
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        teamsFile.teams.removeAll { $0.templateID == "faang" }
        try store.write(teamsFile, to: paths.teamsJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.deletedTeamTemplateIDs.append("faang")
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        XCTAssertFalse(after.teams.contains { $0.templateID == "faang" },
                       "tombstoned template must not be resurrected")
    }

    func testMissingBootstrap_addsUntombstonedTemplate() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Remove a template WITHOUT tombstoning — simulates legacy data from
        // before the tombstone feature existed. Reconcile should resurrect it.
        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        teamsFile.teams.removeAll { $0.templateID == "startup" }
        try store.write(teamsFile, to: paths.teamsJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        XCTAssertTrue(after.teams.contains { $0.templateID == "startup" },
                      "non-tombstoned missing template must be re-added")
    }

    // MARK: - Role tombstone

    func testRoleTombstone_suppressesResurrection_onVersionBump() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()

        // Remove SRE from FAANG AND record it as tombstoned. Then rewind the
        // app version — reconcile must not re-add the tombstoned role.
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let idx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "faang" })
        teamsFile.teams[idx].roles.removeAll { $0.systemRoleID == "sre" }
        teamsFile.teams[idx].deletedSystemRoleIDs.append("sre")
        try store.write(teamsFile, to: paths.teamsJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let faang = try XCTUnwrap(after.teams.first { $0.templateID == "faang" })
        XCTAssertFalse(faang.roles.contains { $0.systemRoleID == "sre" },
                       "tombstoned role must not reappear on version-bump reconcile")
    }

    // MARK: - Running-role deferral (I11 regression)

    /// A team whose role holds a live tool loop must NOT have its scalar fields
    /// overwritten by reconcile (tool-call authorization would break mid-run).
    ///
    /// The watermark now DOES advance: the outstanding team is carried in
    /// `pendingReconcileTeamIDs` instead, so one busy team can't force a full
    /// re-reconcile — and a fresh clobber of every other team's stored prompts —
    /// on every launch. The retry gate is pinned in
    /// `NTMSRepositoryReconcileDeferralTests`.
    func testRunningRole_defersReconcile_andRecordsPendingTeam() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let faangIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "faang" })
        let faangTeamID = teamsFile.teams[faangIdx].id
        let seIdx = try XCTUnwrap(
            teamsFile.teams[faangIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        let seRoleID = teamsFile.teams[faangIdx].roles[seIdx].id
        let originalPrompt = teamsFile.teams[faangIdx].roles[seIdx].prompt
        teamsFile.teams[faangIdx].roles[seIdx].prompt = "STALE USER EDIT"
        try store.write(teamsFile, to: paths.teamsJSON)

        // Fabricate a task.json + tasks_index.json entry pointing at FAANG with
        // the SE role currently .working.
        try fm.createDirectory(
            at: paths.internalTaskDir(taskID: 0), withIntermediateDirectories: true
        )
        // The `.running` step is load-bearing: `pinsTeamAsBusy` requires a
        // `.working` role beside a LIVE step, because that is the only pair
        // status recovery will heal. See `ReconcileDeferralEquivalenceTests`.
        let run = Run(
            id: 0,
            steps: [StepExecution(id: seRoleID, role: .softwareEngineer, title: "SE",
                                  status: .running)],
            roleStatuses: [seRoleID: .working],
            teamID: faangTeamID
        )
        let task = NTMSTask(
            id: 0,
            title: "Busy",
            supervisorTask: "stay running",
            status: .running,
            runs: [run],
            preferredTeamID: faangTeamID
        )
        try store.write(task, to: paths.taskJSON(taskID: 0))

        let index = TasksIndex(
            schemaVersion: 1,
            tasks: [TaskSummary(id: 0, title: "Busy", status: .running)],
            nextTaskID: 1
        )
        try store.write(index, to: paths.tasksIndexJSON)

        // Rewind watermark so reconcile wants to run.
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        let stampedBeforeReopen = state.lastAppliedAppVersion
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        // Prompt must remain the stale edit — deferred teams are not touched.
        let afterTeams = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let afterFaang = try XCTUnwrap(afterTeams.teams.first { $0.templateID == "faang" })
        let afterSE = try XCTUnwrap(afterFaang.roles.first { $0.systemRoleID == "softwareEngineer" })
        XCTAssertEqual(afterSE.prompt, "STALE USER EDIT",
                       "reconcile must NOT overwrite role fields while a role is .working")
        XCTAssertNotEqual(afterSE.prompt, originalPrompt)

        // Watermark advances; the deferred team is carried separately.
        let afterState = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertEqual(afterState.lastAppliedAppVersion, stampedBeforeReopen,
                       "watermark advances even when a team defers")
        XCTAssertEqual(afterState.pendingReconcileTeamIDs, [faangTeamID],
                       "the deferred team owes a scoped retry on the next open")
    }

    // MARK: - Corrupt tasks_index resilience (S4)

    /// A corrupt `tasks_index.json` is recovered by `loadOrRecoverFile`, which
    /// now runs BEFORE `migrateIfNeeded` — so the scan sees the recovered (empty)
    /// index and the reconcile lands in this same open.
    ///
    /// It used to fail-closed here and cost an extra launch, because the scan
    /// read the index itself, a few lines before the recovery that was already
    /// scheduled to run. The end-to-end assertion lives in
    /// `NTMSRepositoryReconcileDeferralTests.testCorruptTasksIndex_reconcilesInOneOpen`;
    /// this one keeps the no-throw guarantee.
    func testCorruptTasksIndex_doesNotThrow() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let faangIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "faang" })
        let seIdx = try XCTUnwrap(
            teamsFile.teams[faangIdx].roles.firstIndex { $0.systemRoleID == "softwareEngineer" }
        )
        teamsFile.teams[faangIdx].roles[seIdx].prompt = "STALE USER EDIT"
        try store.write(teamsFile, to: paths.teamsJSON)

        try Data("this is not json".utf8).write(to: paths.tasksIndexJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        XCTAssertNoThrow(try sut.openOrCreateWorkFolder(at: root))

        // The index was recovered before the scan ran, so nothing was deferred
        // and the stale edit is overwritten by the bundled prompt.
        let afterTeams = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let afterFaang = try XCTUnwrap(afterTeams.teams.first { $0.templateID == "faang" })
        let afterSE = try XCTUnwrap(afterFaang.roles.first { $0.systemRoleID == "softwareEngineer" })
        XCTAssertNotEqual(afterSE.prompt, "STALE USER EDIT",
                          "a recovered index must not block the reconcile")

        let afterState = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertFalse(afterState.lastAppliedAppVersion.isEmpty,
                       "nothing deferred → watermark advances")
    }

    // MARK: - Generated team immunity

    func testGeneratedTeam_notAffectedByReconcile() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Append a `generated` team with a custom prompt — reconcile must
        // leave it untouched even after a version bump.
        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let generated = Team(
            id: "generated_team_test",
            name: "GenTest",
            templateID: "generated",
            systemPromptTemplate: "CUSTOM PROMPT",
            roles: [],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
        teamsFile.teams.append(generated)
        try store.write(teamsFile, to: paths.teamsJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let gen = try XCTUnwrap(after.teams.first { $0.id == "generated_team_test" })
        XCTAssertEqual(gen.systemPromptTemplate, "CUSTOM PROMPT",
                       "generated teams must be excluded from version-bump reconcile")
    }

    /// The Autovisor team is a lazily-created `templateID == "autovisor"` singleton
    /// that persists in teams.json. A team stored under a prior app version carries
    /// the OLD generic system template; the version-bump reconcile must rewrite it
    /// to the dedicated `autovisorTemplate` (re-applied by templateID). Pins the
    /// migration path the dedicated-template change relies on for existing installs.
    func testVersionBump_rewritesStoredAutovisorTemplate() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Seed a stale Autovisor team carrying the template it used to inherit.
        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        var stale = TeamTemplateFactory.autovisor()
        stale.systemPromptTemplate = SystemTemplates.genericTemplate
        teamsFile.teams.append(stale)
        try store.write(teamsFile, to: paths.teamsJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let mgr = try XCTUnwrap(after.teams.first { $0.templateID == AutovisorConstants.teamTemplateID })
        XCTAssertEqual(mgr.systemPromptTemplate, SystemTemplates.autovisorTemplate,
                       "reconcile must rewrite a stored Autovisor team to the dedicated single-role template")
        XCTAssertFalse(mgr.systemPromptTemplate.contains("Submit each deliverable"),
                       "the stale generic deliverable Final reminder must not survive reconcile")
    }

    // MARK: - Role skills

    /// The `{roleSkills}` chip must reach EXISTING work folders, not just
    /// freshly-bootstrapped ones — that is the whole reason the version bump
    /// accompanies the template change.
    func testVersionBump_deliversRoleSkillsChip_toStoredBuiltInTeams() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        // Simulate a folder written by a build that predates the chip.
        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let faangIdx = try XCTUnwrap(teamsFile.teams.firstIndex { $0.templateID == "faang" })
        teamsFile.teams[faangIdx].systemPromptTemplate = SystemTemplates.softwareTemplate
            .replacingOccurrences(of: "\n\n        ## Skills\n        {roleSkills}", with: "")
            .replacingOccurrences(of: "\n\n## Skills\n{roleSkills}", with: "")
        XCTAssertFalse(teamsFile.teams[faangIdx].systemPromptTemplate.contains("{roleSkills}"),
                       "fixture must actually lack the chip, or the test proves nothing")
        try store.write(teamsFile, to: paths.teamsJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let faang = try XCTUnwrap(after.teams.first { $0.templateID == "faang" })
        XCTAssertTrue(faang.systemPromptTemplate.contains("{roleSkills}"),
                      "reconcile must deliver the chip to an existing built-in team")
    }

    /// The other half of the same contract: a CUSTOM team (`templateID == nil`)
    /// is never rewritten, so it can never gain the chip. That is exactly why
    /// `TemplateResolver.resolveSystemPrompt` carries the chip-less fallback —
    /// without it, skills attached on such a team would silently never ship.
    func testVersionBump_leavesCustomTeamTemplateAlone() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        let store = AtomicJSONStore()
        var teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        // Exactly what "New Team from template" produces.
        let custom = TeamTemplateFactory.faang().duplicate(withName: "My Team")
        XCTAssertNil(custom.templateID, "duplicate produces a custom team")
        teamsFile.teams.append(custom)
        try store.write(teamsFile, to: paths.teamsJSON)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        try store.write(state, to: paths.workFolderJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let after = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let mine = try XCTUnwrap(after.teams.first { $0.name == "My Team" })
        XCTAssertEqual(mine.systemPromptTemplate, custom.systemPromptTemplate,
                       "a custom team's template is the user's — reconcile must not touch it")
    }
}
