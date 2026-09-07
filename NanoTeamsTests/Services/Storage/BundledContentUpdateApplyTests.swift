import XCTest

@testable import NanoTeams

/// The *apply* half of `applyBundledContentUpdates` — the six mutation arms that
/// run once a team has passed the deferral gate.
///
/// The existing reconcile suites all drive the pass end-to-end through a real
/// work folder, which exercises the gate thoroughly and the arms behind it barely:
/// a fresh folder's teams are already byte-identical to the bundled ones, so every
/// `if stored != bundled` is false and the bodies never run. That is exactly
/// backwards from where the risk lives — these arms are what actually rewrite a
/// user's `teams.json` on a version bump, and an arm that silently stops firing
/// means a shipped prompt/tool/role fix never reaches an installed folder, with
/// no error anywhere.
///
/// So this suite calls the method DIRECTLY with a deliberately-stale stored team.
/// The scan runs against an empty `TasksIndex`, so nothing is ever busy and the
/// deferral gate is out of the way.
final class BundledContentUpdateApplyTests: XCTestCase {

    private var sut: NTMSRepository!
    private var tempDir: URL!
    private var paths: NTMSPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-apply-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        paths = NTMSPaths(workFolderRoot: tempDir)
        sut = NTMSRepository()
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        sut = nil
        tempDir = nil
        paths = nil
        try super.tearDownWithError()
    }

    // MARK: - Harness

    /// The bundled FAANG team, which is the richest fixture available: multiple
    /// system roles, multiple system artifacts, and a non-generic prompt trio.
    private func bundledFAANG() throws -> Team {
        let team = try XCTUnwrap(
            Team.defaultTeams.first(where: { $0.templateID == "faang" }),
            "the FAANG template is the fixture every arm below is staged from")
        return team
    }

    @discardableResult
    private func reconcile(
        teams: inout [Team], tools: inout [ToolDefinitionRecord]
    ) -> NTMSRepository.BundledReconcileResult {
        sut.applyBundledContentUpdates(
            teams: &teams,
            tools: &tools,
            tasksIndex: TasksIndex(),
            activeTeamID: nil,
            paths: paths)
    }

    // MARK: - Tools merge

    /// The tool merge is additive and version-keyed. With an EMPTY stored set it
    /// must repopulate every bundled definition and report `toolsTouched` — the
    /// flag the caller uses to decide whether to write `tools.json` at all.
    func testToolsMerge_fromEmpty_repopulatesDefaultsAndReportsTouched() throws {
        var teams: [Team] = []
        var tools: [ToolDefinitionRecord] = []

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.toolsTouched)
        XCTAssertFalse(tools.isEmpty)
        XCTAssertEqual(
            tools.count, ToolDefinitionRecord.defaultDefinitions().count,
            "the merge is the only thing that seeds tools.json on a version bump")
    }

    /// The idempotence half: a second pass over an already-merged set must report
    /// nothing, or every launch rewrites `tools.json` for no reason.
    func testToolsMerge_alreadyCurrent_reportsNothing() {
        var teams: [Team] = []
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertFalse(result.toolsTouched)
    }

    /// A scoped retry deliberately skips the merge — it already ran on the pass
    /// that deferred these teams, and re-running it would rewrite `tools.json`
    /// on every retry open.
    func testToolsMerge_isSkippedOnAScopedRetry() {
        var teams: [Team] = []
        var tools: [ToolDefinitionRecord] = []

        let result = sut.applyBundledContentUpdates(
            teams: &teams, tools: &tools, tasksIndex: TasksIndex(),
            activeTeamID: nil, scope: .only([]), paths: paths)

        XCTAssertFalse(result.toolsTouched)
        XCTAssertTrue(tools.isEmpty)
    }

    // MARK: - Prompt templates

    /// Prompt templates are the payload version bumps most often carry, and a
    /// stored team keeps its own copies. All three must be re-applied.
    func testStalePromptTemplates_allThreeAreRestoredFromTheBundledConfig() throws {
        var stored = try bundledFAANG()
        stored.systemPromptTemplate = "STALE SYSTEM"
        stored.consultationPromptTemplate = "STALE CONSULTATION"
        stored.meetingPromptTemplate = "STALE MEETING"
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched)
        let cfg = try XCTUnwrap(SystemTemplates.templateConfigs["faang"])
        XCTAssertEqual(teams[0].systemPromptTemplate, cfg.system)
        XCTAssertEqual(teams[0].consultationPromptTemplate, cfg.consultation)
        XCTAssertEqual(teams[0].meetingPromptTemplate, cfg.meeting)
    }

    // MARK: - Team settings

    /// Team settings are the user's after first creation: a bump never rewrites a value
    /// the editor can change. Pinned on fields the bundle used to own (acceptance mode,
    /// limits) — and on `touched`, which must stay false when settings are the ONLY
    /// difference, or `teams.json` would be rewritten on every bump for nothing. Until
    /// 2026-09-07 step 3 overwrote every setting but three.
    ///
    /// RED: restore the step-3 overwrite → `touched` flips and the settings equal the bundle.
    func testStaleTeamSettings_areLeftAsTheUserSetThem() throws {
        var stored = try bundledFAANG()
        let bundledSettings = stored.settings
        stored.settings.defaultAcceptanceMode = (bundledSettings.defaultAcceptanceMode == .finalOnly)
            ? .afterEachRole : .finalOnly
        stored.settings.limits = TeamLimits(maxConsultationsPerStep: 9, maxMeetingTurns: 1)
        let userSettings = stored.settings
        XCTAssertNotEqual(userSettings, bundledSettings, "premise: the stored values really differ from the bundle")
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertFalse(result.touched, "settings alone are not a change the bundle makes")
        XCTAssertEqual(teams[0].settings, userSettings, "not one setting moved")
    }

    /// Every user-set field survives a bump that IS rewriting something else (a stale
    /// prompt template), so the preservation is tested against a firing pass rather than
    /// an equal-case no-op. Includes a `reportsTo` edge the user removed: step 4 wires only
    /// a role it re-adds, never an existing one. Until 2026-09-06 a bump reset everything;
    /// until 2026-09-07 all but `meetingsEnabled`, `supervisorMode` and a live coordinator.
    func testEveryUserSetting_survivesABumpThatRewritesOtherThings() throws {
        var stored = try bundledFAANG()
        let bundledSettings = stored.settings
        let roleIDs = stored.nonSupervisorRoles.map(\.id)
        let userCoordinator = try XCTUnwrap(roleIDs.first { $0 != bundledSettings.meetingCoordinatorRoleID })
        let unwired = try XCTUnwrap(roleIDs.last)
        stored.settings.meetingsEnabled = false
        stored.settings.supervisorMode = .off
        stored.settings.meetingCoordinatorRoleID = userCoordinator
        stored.settings.defaultAcceptanceMode = .afterEachArtifact
        stored.settings.acceptanceCheckpoints = [userCoordinator]
        stored.settings.limits = TeamLimits(maxConsultationsPerStep: 9, maxMeetingTurns: 1)
        stored.settings.invitableRoles = [userCoordinator]
        stored.settings.hierarchy.reportsTo.removeValue(forKey: unwired)
        let userSettings = stored.settings
        stored.systemPromptTemplate = "STALE SYSTEM"   // bundle-owned, so the pass fires
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched)
        XCTAssertNotEqual(teams[0].systemPromptTemplate, "STALE SYSTEM", "premise: the pass rewrote the template")
        XCTAssertEqual(teams[0].settings, userSettings, "not one setting moved")
        XCTAssertNil(teams[0].settings.hierarchy.reportsTo[unwired],
                     "an existing role's removed edge is not re-wired — only a re-added role's is")
    }

    /// The BUNDLED coordinator itself can be a role the user deleted and tombstoned: nothing
    /// restores the bundled id (settings are the user's), step 4 does not resurrect the
    /// tombstoned role, and step 5's heal is the only thing standing between the file and a
    /// coordinator id that names nobody.
    func testTombstonedBundledCoordinator_isHealedToALiveRoleByStepFive() throws {
        let bundled = try bundledFAANG()
        let bundledCoordinatorID = try XCTUnwrap(bundled.settings.meetingCoordinatorRoleID)
        let victim = try XCTUnwrap(bundled.roles.first { $0.id == bundledCoordinatorID })
        let victimSystemID = try XCTUnwrap(victim.systemRoleID)
        var stored = bundled
        stored.roles.removeAll { $0.id == victim.id }
        stored.deletedSystemRoleIDs.append(victimSystemID)
        // The stored pick names nobody either — the shape after the user deleted both roles.
        stored.settings.meetingCoordinatorRoleID = "ghost-of-a-custom-role"
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched)
        XCTAssertFalse(teams[0].roles.contains { $0.id == victim.id }, "the tombstone holds")
        let healed = try XCTUnwrap(teams[0].settings.meetingCoordinatorRoleID)
        XCTAssertNotEqual(healed, bundledCoordinatorID, "the bundled pick names a deleted role")
        XCTAssertTrue(teams[0].roles.contains { $0.id == healed && !$0.isSupervisor },
                      "step 5 settles the coordinator on a live non-Supervisor role")
        XCTAssertEqual(healed, TeamSettings.defaultCoordinatorID(among: teams[0].roles))
    }

    /// `meetingGuidance` is a bundle-owned scalar like `prompt`: a stale body is overwritten
    /// on a bump, and a pre-1.9.8 file (no key → `nil`) receives the body — the arm keys on
    /// inequality, and `nil != body`.
    func testStaleOrMissingMeetingGuidance_isRestoredFromTheBundledRole() throws {
        let bundled = try bundledFAANG()
        let pm = try XCTUnwrap(bundled.roles.firstIndex { $0.systemRoleID == "productManager" })
        let tl = try XCTUnwrap(bundled.roles.firstIndex { $0.systemRoleID == "techLead" })
        let pmBody = try XCTUnwrap(bundled.roles[pm].meetingGuidance, "fixture: the PM has a bundled body")
        var stored = bundled
        stored.roles[pm].meetingGuidance = "stale body"
        stored.roles[tl].meetingGuidance = nil
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched)
        XCTAssertEqual(teams[0].roles[pm].meetingGuidance, pmBody)
        XCTAssertEqual(teams[0].roles[tl].meetingGuidance, bundled.roles[tl].meetingGuidance)
    }

    /// A stored coordinator whose role is gone is healed by step 5 to the default rule —
    /// never `nil`. Nothing writes the bundled pick back (settings are the user's); on a
    /// fresh FAANG the rule and the bundled pick coincide, which is why the assertion names
    /// the RULE. The heal is a real change, so the pass reports it.
    func testOrphanCoordinator_healsToTheDefaultRule() throws {
        var stored = try bundledFAANG()
        stored.settings.meetingCoordinatorRoleID = "ghost-of-deleted-role"
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched, "the heal is a write")
        XCTAssertEqual(teams[0].settings.meetingCoordinatorRoleID,
                       TeamSettings.defaultCoordinatorID(among: teams[0].roles))
        XCTAssertEqual(teams[0].settings.meetingCoordinatorRoleID, teams[0].meetingCoordinatorID)
        XCTAssertTrue(teams[0].roles.contains { $0.id == teams[0].settings.meetingCoordinatorRoleID })
    }

    // MARK: - Additive structure

    /// A system role dropped from a stored team (an older build that never
    /// shipped it, or a corrupted file) is restored, together with its
    /// `reportsTo` wiring — without that second half the role comes back as a
    /// peer of the Supervisor and silently gains delegation-shaped semantics.
    func testMissingSystemRole_isReAddedWithItsHierarchyEdge() throws {
        var stored = try bundledFAANG()
        let bundled = try bundledFAANG()
        let victim = try XCTUnwrap(
            bundled.roles.first(where: { $0.isSystemRole && !$0.isSupervisor }))
        stored.roles.removeAll { $0.id == victim.id }
        XCTAssertFalse(stored.roles.contains(where: { $0.id == victim.id }))
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched)
        XCTAssertTrue(
            teams[0].roles.contains(where: { $0.id == victim.id }),
            "a bundled system role missing from storage must be restored")
        if let expected = bundled.settings.hierarchy.reportsTo[victim.id] {
            XCTAssertEqual(teams[0].settings.hierarchy.reportsTo[victim.id], expected)
        }
    }

    /// The editor's `Team.removeRole` drops the role from `invitableRoles` too, so a system
    /// role that comes back on a bump must be re-admitted to an EXPLICIT invite list —
    /// otherwise it returns silently un-invitable. Settings are otherwise the user's; this
    /// is the one settings write the bundle still makes, and it is additive.
    ///
    /// RED: drop the `invitableRoles.insert` in step 4 → the restored role is not invitable.
    func testReAddedSystemRole_joinsAnExplicitInvitableRolesSet() throws {
        let bundled = try bundledFAANG()
        var stored = bundled
        let victim = try XCTUnwrap(bundled.roles.first { $0.isSystemRole && !$0.isSupervisor })
        stored.removeRole(victim.id)
        stored.deletedSystemRoleIDs.removeAll()          // the user re-enabled it: no tombstone
        XCTAssertFalse(stored.settings.invitableRoles.contains(victim.id), "premise: removeRole dropped it")
        XCTAssertFalse(stored.settings.invitableRoles.isEmpty, "premise: the list is explicit")
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched)
        XCTAssertTrue(teams[0].roles.contains { $0.id == victim.id })
        XCTAssertTrue(teams[0].settings.invitableRoles.contains(victim.id), "re-added ⇒ re-admitted")
        XCTAssertEqual(teams[0].settings.hierarchy.reportsTo[victim.id],
                       bundled.settings.hierarchy.reportsTo[victim.id])
    }

    /// An EMPTY invite list means "everyone" and must stay empty: inserting the re-added
    /// role would turn "everyone" into "only this one".
    ///
    /// RED: make the step-4 insert unconditional → the list becomes `[victim]`.
    func testReAddedSystemRole_leavesAnEmptyInvitableRolesSetAlone() throws {
        var stored = try bundledFAANG()
        let victim = try XCTUnwrap(stored.roles.first { $0.isSystemRole && !$0.isSupervisor })
        stored.removeRole(victim.id)
        stored.deletedSystemRoleIDs.removeAll()
        stored.settings.invitableRoles = []
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(teams[0].roles.contains { $0.id == victim.id })
        XCTAssertTrue(teams[0].settings.invitableRoles.isEmpty, "\"everyone\" stays \"everyone\"")
    }

    /// The tombstone is the user's explicit "I deleted this" and outranks the
    /// additive restore. Without it, every version bump resurrects a role the
    /// user removed in the editor.
    func testTombstonedSystemRole_isNotResurrected() throws {
        var stored = try bundledFAANG()
        let victim = try XCTUnwrap(
            stored.roles.first(where: { $0.isSystemRole && !$0.isSupervisor }))
        let sid = try XCTUnwrap(victim.systemRoleID)
        stored.roles.removeAll { $0.id == victim.id }
        stored.deletedSystemRoleIDs = [sid]
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        reconcile(teams: &teams, tools: &tools)

        XCTAssertFalse(teams[0].roles.contains(where: { $0.id == victim.id }))
    }

    /// Same rule for artifacts: a missing system artifact is re-added.
    func testMissingSystemArtifact_isReAdded() throws {
        var stored = try bundledFAANG()
        let victim = try XCTUnwrap(stored.artifacts.first(where: { $0.isSystemArtifact }))
        stored.artifacts.removeAll { $0.id == victim.id }
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched)
        XCTAssertTrue(teams[0].artifacts.contains(where: { $0.id == victim.id }))
    }

    func testTombstonedSystemArtifact_isNotResurrected() throws {
        var stored = try bundledFAANG()
        let victim = try XCTUnwrap(stored.artifacts.first(where: { $0.isSystemArtifact }))
        stored.artifacts.removeAll { $0.id == victim.id }
        stored.deletedSystemArtifactIDs = [victim.id]
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        reconcile(teams: &teams, tools: &tools)

        XCTAssertFalse(teams[0].artifacts.contains(where: { $0.id == victim.id }))
    }

    // MARK: - Orphan prune

    /// The rename case the prune exists for: a system artifact whose name the
    /// bundled team no longer ships and that no role references is a ghost in the
    /// team editor's picker — selectable, never produced.
    func testOrphanSystemArtifact_isPrunedByTheReconcilePass() throws {
        var stored = try bundledFAANG()
        stored.artifacts.append(
            TeamArtifact(
                id: "code_review", name: "Code Review", icon: "doc", mimeType: "text/markdown",
                description: "legacy name from before the rename", isSystemArtifact: true))
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched)
        XCTAssertFalse(
            teams[0].artifacts.contains(where: { $0.name == "Code Review" }),
            "an unreferenced system artifact absent from the bundled team is a ghost")
    }

    // MARK: - Skips

    /// A generated team is transient and task-owned; the pass must not touch it
    /// even though it carries a `templateID`.
    func testGeneratedTemplate_isSkippedEntirely() throws {
        var stored = try bundledFAANG()
        stored.templateID = "generated"
        stored.systemPromptTemplate = "STALE SYSTEM"
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertFalse(result.touched)
        XCTAssertEqual(teams[0].systemPromptTemplate, "STALE SYSTEM")
    }

    /// A custom team (`templateID == nil`) has no bundled counterpart — every
    /// team created through the New Team sheet is one of these, because
    /// `Team.duplicate` clears the id.
    func testCustomTeamWithNoTemplateID_isLeftAlone() throws {
        var stored = try bundledFAANG()
        stored.templateID = nil
        stored.systemPromptTemplate = "USER'S OWN"
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertFalse(result.touched)
        XCTAssertEqual(teams[0].systemPromptTemplate, "USER'S OWN")
    }

    /// A scoped retry names the teams it may touch; everything else already
    /// reconciled at this app version and must not be rewritten again.
    func testScopedRetry_touchesOnlyTheNamedTeam() throws {
        var a = try bundledFAANG()
        a.systemPromptTemplate = "STALE A"
        var b = try XCTUnwrap(Team.defaultTeams.first(where: { $0.templateID == "startup" }))
        b.systemPromptTemplate = "STALE B"
        var teams = [a, b]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = sut.applyBundledContentUpdates(
            teams: &teams, tools: &tools, tasksIndex: TasksIndex(),
            activeTeamID: nil, scope: .only([a.id]), paths: paths)

        XCTAssertTrue(result.touched)
        XCTAssertNotEqual(teams[0].systemPromptTemplate, "STALE A")
        XCTAssertEqual(
            teams[1].systemPromptTemplate, "STALE B",
            "a team outside the retry scope must not be rewritten a second time")
    }

    // MARK: - Idempotence

    /// The property the whole pass rests on: a second run over its own output
    /// must report nothing. If it does not, `teams.json` is rewritten on every
    /// launch and `updatedAt` churns, which is itself a cache-invalidation event
    /// for anything keyed on it.
    func testSecondPassOverItsOwnOutput_reportsNoChange() throws {
        var stored = try bundledFAANG()
        stored.systemPromptTemplate = "STALE SYSTEM"
        stored.artifacts.removeFirst()
        var teams = [stored]
        var tools: [ToolDefinitionRecord] = []

        let first = reconcile(teams: &teams, tools: &tools)
        XCTAssertTrue(first.touched)

        let second = reconcile(teams: &teams, tools: &tools)

        XCTAssertFalse(second.touched, "reconcile must be idempotent over its own output")
        XCTAssertFalse(second.toolsTouched)
    }
}
