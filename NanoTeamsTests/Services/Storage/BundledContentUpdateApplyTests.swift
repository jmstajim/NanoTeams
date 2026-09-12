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

// MARK: - Retiring a system role the bundle dropped

/// Renaming a bundled system role has never been possible in this project, because
/// reconciliation is additive by contract: "existing entries (including roles no longer
/// present in the bundled template) are never removed". That invariant protects the USER's
/// roles; applied to a role the BUNDLE retired, it produces a chimera rather than caution.
///
/// Ultra Team's three renames (2026-09-11) are the first case. Without step 4a a stored copy
/// ends with THIRTEEN roles — the seven stored (four shared ids the additive pass matches
/// and never doubles, plus three under retired ids) and the six the bundle appends: two
/// planners, both holding `ask_supervisor` — ONE ASKER broken, the human interrupted twice —
/// and two engineers, both holding `write_file`/`edit_file`/`delete_file` on one shared
/// tree, which is ONE WRITER broken and the silent-corruption failure mode the pin exists
/// for. The ONE WRITER pin stays GREEN through all of it: it asserts over
/// `TeamTemplateFactory.ultraTeam()`, the fresh template, never over disk.
///
/// These tests are written against a stored team built from the PREVIOUS roster, so they
/// fail on 13 roles rather than merely describing 10.
final class RetiredSystemRoleReconcileTests: XCTestCase {

    private var sut: NTMSRepository!
    private var tempDir: URL!
    private var paths: NTMSPaths!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retired-role-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        paths = NTMSPaths(workFolderRoot: tempDir)
        sut = NTMSRepository()
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        sut = nil
        tempDir = nil
        paths = nil
        try await super.tearDown()
    }

    // MARK: - Fixture: an Ultra Team as it stood before the rename

    /// The bundled team with the three renamed roles put back under their OLD system ids,
    /// their old toolsets and the old artifact name — i.e. exactly what is on disk in a work
    /// folder that ran the previous build.
    private func storedPreRenameUltra() throws -> Team {
        var team = try XCTUnwrap(Team.defaultTeams.first { $0.templateID == "ultra" })
        // Drop the new roles that replaced them, so the stored team has no knowledge of them.
        for systemID in ["changePlanner", "changeEngineer", "changeVerifier",
                         "briefCritic", "diffReviewer"] {
            if let role = team.roles.first(where: { $0.systemRoleID == systemID }) {
                team.removeRole(role.id)
            }
        }
        // `isSystemRole: true`, as a role seeded from the bundle is on disk — it is what
        // makes the editor's `removeRole` record a tombstone for it, which the tombstone
        // test below depends on.
        func legacy(_ systemID: String, _ name: String, tools: [String],
                    requires: [String], produces: [String]) -> TeamRoleDefinition {
            TeamRoleDefinition(
                id: "legacy_\(systemID)", name: name, prompt: "old prompt", toolIDs: tools,
                usePlanningPhase: systemID == "featureEngineer",
                dependencies: RoleDependencies(requiredArtifacts: requires,
                                               producesArtifacts: produces),
                isSystemRole: true, systemRoleID: systemID)
        }
        team.roles.append(legacy(
            "featurePlanner", "Feature Planner",
            tools: [ToolNames.readFile, ToolNames.askSupervisor, ToolNames.askSupervisorForm],
            requires: [SystemTemplates.supervisorTaskArtifactName], produces: ["Feature Brief"]))
        team.roles.append(legacy(
            "featureEngineer", "Feature Engineer",
            tools: [ToolNames.writeFile, ToolNames.editFile, ToolNames.deleteFile],
            requires: ["Feature Brief"], produces: ["Implementation Notes"]))
        team.roles.append(legacy(
            "buildVerifier", "Build Verifier",
            tools: [ToolNames.runXcodebuild, ToolNames.runXcodetests],
            requires: ["Feature Brief", "Implementation Notes"], produces: ["Verification Report"]))
        // The artifacts the new roles produce did not exist before the rename either.
        let newArtifacts: Set<String> = ["Change Brief", "Brief Critique", "Diff Review"]
        team.artifacts.removeAll { newArtifacts.contains($0.name) }
        team.artifacts.append(TeamArtifact(
            id: "feature_brief", name: "Feature Brief", icon: "list.clipboard",
            mimeType: "text/markdown", description: "legacy", isSystemArtifact: true))
        team.settings.meetingCoordinatorRoleID = "legacy_buildVerifier"
        // `removeRole` records a tombstone, and a tombstone means "the USER deleted this" —
        // which would suppress the additive pass. A folder written by the previous build
        // never knew these roles, so it carries no tombstone for them.
        team.deletedSystemRoleIDs = []
        team.deletedSystemArtifactIDs = []
        return team
    }

    @discardableResult
    private func reconcile(
        _ teams: inout [Team], tasksIndex: TasksIndex = TasksIndex()
    ) -> NTMSRepository.BundledReconcileResult {
        var tools: [ToolDefinitionRecord] = []
        return sut.applyBundledContentUpdates(
            teams: &teams, tools: &tools, tasksIndex: tasksIndex,
            activeTeamID: nil, paths: paths)
    }

    /// Writes one task under `paths` and returns the index the scan reads. The task is
    /// pinned to the team by `preferredTeamID` and `run.teamID`, the order the engine and
    /// the reconcile scan resolve by.
    private func seedTask(
        id: Int = 1,
        team: Team,
        steps: [StepExecution],
        roleStatuses: [String: RoleExecutionStatus],
        closedAt: Date? = nil
    ) throws -> TasksIndex {
        let task = NTMSTask(
            id: id, title: "Old-shape run", supervisorTask: "fixture",
            status: closedAt == nil ? .paused : .done,
            runs: [Run(id: 0, steps: steps, roleStatuses: roleStatuses, teamID: team.id)],
            closedAt: closedAt, preferredTeamID: team.id)
        try FileManager.default.createDirectory(
            at: paths.internalTaskDir(taskID: id), withIntermediateDirectories: true)
        try AtomicJSONStore().write(task, to: paths.taskJSON(taskID: id))
        return TasksIndex(
            schemaVersion: 1,
            tasks: [TaskSummary(id: id, title: task.title, status: task.status)],
            nextTaskID: id + 1)
    }

    // MARK: - Tests

    /// RED without step 4a: 13 roles, and both invariant assertions below fail.
    func testStoredUltraTeam_endsWithTheNewRoster_notAChimera() throws {
        var teams = [try storedPreRenameUltra()]
        XCTAssertEqual(teams[0].nonSupervisorRoles.count, 7,
                       "premise: the fixture is the OLD roster — four unrenamed roles plus the "
                           + "three under their retired ids")
        reconcile(&teams)

        let ultra = teams[0]
        XCTAssertEqual(ultra.nonSupervisorRoles.count, 9, "the new roster, not both rosters")
        let systemIDs = Set(ultra.nonSupervisorRoles.compactMap(\.systemRoleID))
        for retired in SystemTemplates.retiredSystemRoleIDs {
            XCTAssertFalse(systemIDs.contains(retired), "\(retired) survived the rename")
        }
    }

    // MARK: - Fixture: an Ultra Team as it stood at 1.9.20, with the Feasibility Critic

    /// The bundled team with the retired role put BACK, holding the toolset and the edges it
    /// carried at 1.9.20 — i.e. what a work folder opened on the previous build has on disk.
    private func storedUltraWithFeasibilityCritic() throws -> Team {
        var team = try XCTUnwrap(Team.defaultTeams.first { $0.templateID == "ultra" })
        team.artifacts.append(TeamArtifact(
            id: "feasibility_report", name: "Feasibility Report",
            icon: "wrench.and.screwdriver", mimeType: "text/markdown",
            description: "legacy", isSystemArtifact: true))
        team.roles.append(TeamRoleDefinition(
            id: "legacy_feasibilityCritic", name: "Feasibility Critic",
            prompt: "old prompt",
            toolIDs: [ToolNames.readFile, ToolNames.runXcodebuild,
                      ToolNames.writeFile, ToolNames.deleteFile, ToolNames.requestChanges],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Approach A", "Approach B"],
                producesArtifacts: ["Feasibility Report"]),
            isSystemRole: true, systemRoleID: "feasibilityCritic"))
        // The three roles that consumed its report still name it, as they did on disk.
        for systemID in ["specCritic", "regressionCritic", "changeEngineer"] {
            guard let i = team.roles.firstIndex(where: { $0.systemRoleID == systemID }) else {
                throw XCTSkip("roster changed")
            }
            team.roles[i].dependencies.requiredArtifacts.append("Feasibility Report")
        }
        // A folder written by the previous build carries no tombstone for a role it was given.
        team.deletedSystemRoleIDs = []
        team.deletedSystemArtifactIDs = []
        return team
    }

    /// **A system artifact's DESCRIPTION is shipped content, and until 2026-09-12 it reached no
    /// existing work folder at any version.** Step 4 skipped every artifact it already had, so
    /// the two halves of one deliverable's contract drifted apart: step 1 rewrote the role's
    /// prompt from the bundle, the description beside it on the wire
    /// (`PromptBuilder+TeamContext`) stayed whatever the folder was created with. The failure is
    /// silent in the worst way — the prompt half visibly updates, so the folder looks current.
    ///
    /// RED: restore the `if storedArtifactIDs.contains(bundledArt.id) { continue }` skip → the
    /// stale description survives the reconcile.
    func testStoredSystemArtifact_getsItsDescriptionRefreshedFromTheBundle() throws {
        var team = try XCTUnwrap(Team.defaultTeams.first { $0.templateID == "ultra" })
        let i = try XCTUnwrap(team.artifacts.firstIndex { $0.name == "Verification Report" })
        let bundledDescription = team.artifacts[i].description
        team.artifacts[i].description = "stale text from an older build"
        team.artifacts[i].icon = "questionmark"
        var teams = [team]

        reconcile(&teams)

        let after = try XCTUnwrap(teams[0].artifacts.first { $0.name == "Verification Report" })
        XCTAssertEqual(after.description, bundledDescription,
                       "the description rides the wire beside the prompt; both halves must move")
        XCTAssertEqual(after.icon, "checkmark.seal")
    }

    /// The ownership half of the same loop: it is `isSystemArtifact`-gated, so a user's own
    /// artifact is not rewritten by a version bump — the rule step 1 already follows for roles.
    func testUserArtifact_isNotRewrittenByTheRefresh() throws {
        var team = try XCTUnwrap(Team.defaultTeams.first { $0.templateID == "ultra" })
        team.artifacts.append(TeamArtifact(
            id: "my_notes", name: "My Notes", icon: "pencil",
            mimeType: "text/markdown", description: "mine", isSystemArtifact: false))
        var teams = [team]

        reconcile(&teams)

        let mine = try XCTUnwrap(teams[0].artifacts.first { $0.id == "my_notes" })
        XCTAssertEqual(mine.description, "mine")
        XCTAssertEqual(mine.icon, "pencil")
    }

    /// A tombstoned system artifact stays deleted through the refresh, not just through the add.
    func testTombstonedSystemArtifact_isNotResurrectedByTheRefresh() throws {
        var team = try XCTUnwrap(Team.defaultTeams.first { $0.templateID == "ultra" })
        let id = try XCTUnwrap(team.artifacts.first { $0.name == "Diff Review" }?.id)
        team.artifacts.removeAll { $0.id == id }
        team.deletedSystemArtifactIDs = [id]
        var teams = [team]

        reconcile(&teams)

        XCTAssertFalse(teams[0].artifacts.contains { $0.id == id },
                       "the tombstone is the user's mark and outranks the bundle")
    }

    /// **The 1.9.21 retirement, asserted where it actually fails.** Reconciliation is additive
    /// by design, so removing the Feasibility Critic from the bundle does NOTHING to a stored
    /// folder on its own: the role stays, holding `write_file` + `delete_file` on the tree the
    /// engineer writes — a second writer, which is the silent-corruption failure ONE WRITER
    /// exists to prevent — while every pin over the fresh template stays green. Step 4a is what
    /// removes it, and its input is `retiredSystemRoleIDs`.
    ///
    /// RED: drop `"feasibilityCritic"` from that set → 10 roles, two writers, and the artifact
    /// still required by three of them.
    func testStoredUltraTeam_dropsTheRetiredFeasibilityCritic() throws {
        var teams = [try storedUltraWithFeasibilityCritic()]
        XCTAssertEqual(teams[0].nonSupervisorRoles.count, 10, "premise: the 1.9.20 roster")
        reconcile(&teams)

        let ultra = teams[0]
        XCTAssertEqual(ultra.nonSupervisorRoles.count, 9)
        XCTAssertFalse(ultra.nonSupervisorRoles.contains { $0.systemRoleID == "feasibilityCritic" })

        let writers = ultra.nonSupervisorRoles.filter { $0.toolIDs.contains(ToolNames.writeFile) }
        XCTAssertEqual(writers.compactMap(\.systemRoleID), ["changeEngineer"],
                       "a surviving probe writer is a second writer on one tree")
    }

    /// The graph-consistency half. An artifact left in three `requiredArtifacts` after its only
    /// producer is gone blocks those roles forever, and the run dies with "Execution stalled:
    /// roles […] blocked. Check artifact dependencies in Team Editor" — the app blaming the user
    /// for our omission.
    ///
    /// It is a GUARD, not a discriminator, and the mutation run says so: with
    /// `"feasibilityCritic"` removed from `retiredSystemRoleIDs` this test still passes, because
    /// step 4 rewrites a system role's dependencies from the bundle and the producer survives to
    /// keep the artifact defined. What it catches is the other way round — an edge or an artifact
    /// removed from the bundle without its partner.
    func testStoredUltraTeam_leavesNoRoleWaitingOnTheRetiredArtifact() throws {
        var teams = [try storedUltraWithFeasibilityCritic()]
        reconcile(&teams)

        let defined = Set(teams[0].artifacts.map(\.name))
        for role in teams[0].nonSupervisorRoles {
            XCTAssertFalse(role.dependencies.requiredArtifacts.contains("Feasibility Report"),
                           "\(role.name) waits on an artifact nobody produces")
            for name in role.dependencies.requiredArtifacts {
                XCTAssertTrue(defined.contains(name),
                              "\(role.name) requires '\(name)', which the team does not define")
            }
        }
    }

    /// The chair is read by `Team.meetingCoordinatorID`, and step 4a runs before the additive
    /// pass: a retirement that removed the seated chair would heal to "the first role holding
    /// `request_team_meeting`, else the first non-Supervisor role" and silently reseat the
    /// pipeline. The retired role was not the chair — this asserts that it stayed that way. Like
    /// the test above it is a guard: it does not go red on the retirement alone.
    func testStoredUltraTeam_keepsThePlannerInTheChair() throws {
        var teams = [try storedUltraWithFeasibilityCritic()]
        reconcile(&teams)

        let chairID = try XCTUnwrap(teams[0].meetingCoordinatorID)
        let chair = try XCTUnwrap(teams[0].roles.first { $0.id == chairID })
        XCTAssertEqual(chair.systemRoleID, "changePlanner")
        XCTAssertFalse(chair.toolIDs.contains(ToolNames.requestChanges))
    }

    /// The two invariants the chimera breaks, asserted over the STORED team rather than over
    /// the fresh template — which is precisely the gap the existing pins leave.
    func testStoredUltraTeam_keepsOneWriterAndOneAsker() throws {
        var teams = [try storedPreRenameUltra()]
        reconcile(&teams)

        let writers = teams[0].nonSupervisorRoles.filter {
            $0.toolIDs.contains(ToolNames.editFile)
        }
        XCTAssertEqual(writers.count, 1, "two engineers on one tree: \(writers.map(\.name))")

        let askers = teams[0].nonSupervisorRoles.filter {
            !Set($0.toolIDs).isDisjoint(with: ToolNames.supervisorAskTools)
        }
        XCTAssertEqual(askers.count, 1, "the human would be interrupted twice: \(askers.map(\.name))")
    }

    /// The retired roles' artifact loses its only producer and is taken by the existing
    /// orphan prune — no separate machinery, and no ghost in the artifact picker.
    func testTheRetiredRolesArtifactIsPruned() throws {
        var teams = [try storedPreRenameUltra()]
        reconcile(&teams)
        XCTAssertFalse(teams[0].artifacts.contains { $0.name == "Feature Brief" },
                       "an artifact nobody produces is a selectable ghost in the team editor")
        XCTAssertTrue(teams[0].artifacts.contains { $0.name == "Change Brief" })
    }

    /// `Team.removeRole` heals the coordinator itself, and its rule is "first non-Supervisor
    /// role in STORED order" — while reconciliation appends new roles at the END. On a stored
    /// Ultra Team that lands the chair on the Solution Architect, a role that IS a repair
    /// target, which is the seat `coordinatorIndex: 1` exists to keep clear. The retirement
    /// step carries the BUNDLE's own choice across instead, matched by `systemRoleID`.
    ///
    /// RED: delete the step-4b carry-over → the chair heals to `solutionArchitect` and the
    /// `systemRoleID == "changePlanner"` assertion fails. (Asserting merely that the chair
    /// CHANGED would pass under that mutation, which is why this asserts who it became.)
    func testTheChairIsCarriedAcross_notLeftToTheHealRule() throws {
        var teams = [try storedPreRenameUltra()]
        reconcile(&teams)

        let chairID = try XCTUnwrap(teams[0].settings.meetingCoordinatorRoleID)
        let chair = try XCTUnwrap(teams[0].roles.first { $0.id == chairID })
        XCTAssertEqual(chair.systemRoleID, "changePlanner",
                       "the chair must be the planner — not whoever the default rule lands on")
    }

    // MARK: - Corner cases

    /// Matching is by `systemRoleID`, so a role the user RENAMED in the editor is still the
    /// same system role and is still retired.
    func testARoleTheUserRenamed_isStillRetired() throws {
        var team = try storedPreRenameUltra()
        let index = try XCTUnwrap(team.roles.firstIndex { $0.systemRoleID == "featureEngineer" })
        team.roles[index].name = "My Implementer"
        var teams = [team]
        reconcile(&teams)
        XCTAssertFalse(teams[0].roles.contains { $0.name == "My Implementer" })
    }

    /// A retired role the user had ALREADY deleted leaves nothing to remove — and the
    /// user's tombstone is the ONLY one on the team afterwards: retirement records none.
    /// (`touched` is true regardless — the additive pass appends the six new roles — so the
    /// assertion that means something is on the tombstones and the roster delta.)
    func testATombstonedRetiredRole_leavesNothingToDo() throws {
        var team = try storedPreRenameUltra()
        for role in team.roles where role.systemRoleID == "buildVerifier" {
            team.removeRole(role.id)   // the USER's door — records the tombstone
        }
        team.settings.meetingCoordinatorRoleID = "legacy_featurePlanner"
        XCTAssertEqual(team.deletedSystemRoleIDs, ["buildVerifier"], "premise: the user's tombstone")
        XCTAssertEqual(team.nonSupervisorRoles.count, 6, "premise: four shared + two retired ids")
        var teams = [team]
        reconcile(&teams)
        XCTAssertFalse(teams[0].roles.contains { $0.systemRoleID == "buildVerifier" })
        XCTAssertEqual(teams[0].deletedSystemRoleIDs, ["buildVerifier"],
                       "the two retirements this pass DID make left no tombstone beside the user's")
        XCTAssertEqual(teams[0].nonSupervisorRoles.count, 9, "four shared + five appended")
    }

    /// Retirement is the bundle's decision and must not be recorded under user-deletion
    /// semantics: `deletedSystemRoleIDs` documents "the user removed this via the editor",
    /// and a later bundle that revives one of these ids would be refused on this folder
    /// alone — with the editor's Restore, which erases every real tombstone too, as the
    /// only way out.
    ///
    /// RED: retire through `Team.removeRole` → three tombstones the user never made.
    func testRetirementLeavesNoUserTombstone() throws {
        var teams = [try storedPreRenameUltra()]
        reconcile(&teams)
        XCTAssertEqual(teams[0].deletedSystemRoleIDs, [])
        XCTAssertEqual(teams[0].deletedSystemArtifactIDs, [])
    }

    /// Step 4b carries the bundle's chair across only when the STORED chair was retired. A
    /// chair the user picked among the surviving roles is the user's and stays.
    func testAUserPickedChairThatIsNotRetired_survivesStep4b() throws {
        var team = try storedPreRenameUltra()
        let architect = try XCTUnwrap(team.roles.first { $0.systemRoleID == "solutionArchitect" })
        team.settings.meetingCoordinatorRoleID = architect.id
        var teams = [team]
        reconcile(&teams)
        XCTAssertEqual(teams[0].settings.meetingCoordinatorRoleID, architect.id,
                       "a user's choice among live roles is never overwritten by the bundle's")
    }

    /// The retired roles' artifact survives the orphan prune while a USER role still reads
    /// it — the prune spares anything a role references, and a user's role is a reference.
    func testAUserRoleThatReadsTheRetiredArtifact_keepsIt() throws {
        var team = try storedPreRenameUltra()
        team.roles.append(TeamRoleDefinition(
            id: "user_auditor", name: "Brief Auditor", prompt: "mine", toolIDs: [ToolNames.readFile],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Feature Brief"],
                                           producesArtifacts: ["Audit"])))
        var teams = [team]
        reconcile(&teams)
        XCTAssertTrue(teams[0].artifacts.contains { $0.name == "Feature Brief" },
                      "an artifact a user's role requires is not an orphan")
        XCTAssertTrue(teams[0].roles.contains { $0.id == "user_auditor" })
    }

    // MARK: - An unclosed task still holding a retired role defers the retirement

    /// Retiring a role from under an UNCLOSED task orphans that task's steps. A `.paused`
    /// step of a role no longer on the roster pins the derived status at Paused with
    /// nothing to resume — `parkedRoleIDs` restarts `.working` roles only, and status
    /// recovery has already demoted the parked one to `.idle` — so the task reads Paused
    /// until closed and its review card never appears. The pass defers the team instead,
    /// exactly as it defers a busy one, and the banner names the task to close.
    ///
    /// RED: drop `retiredRoleIDsInUse` from the scan → 10 roles and nothing deferred.
    func testAnUnclosedTaskHoldingARetiredRole_defersTheRetirement() throws {
        let team = try storedPreRenameUltra()
        let index = try seedTask(
            team: team,
            steps: [StepExecution(id: "legacy_featureEngineer", role: .changeEngineer,
                                  title: "Feature Engineer", status: .paused)],
            roleStatuses: ["legacy_featureEngineer": .idle])
        var teams = [team]
        let result = reconcile(&teams, tasksIndex: index)

        XCTAssertEqual(teams[0].nonSupervisorRoles.count, 7, "the old roster stays whole")
        XCTAssertEqual(result.deferredTeamIDs, [team.id])
        let deferred = try XCTUnwrap(result.report.deferred.first)
        XCTAssertEqual(deferred.reason, .retiredRoleInUnclosedTask)
        XCTAssertEqual(deferred.roleNames, ["Feature Engineer"])
        XCTAssertEqual(deferred.taskID, 1)
        let banner = try XCTUnwrap(result.report.bannerMessage)
        XCTAssertTrue(banner.contains("retires"), banner)
        XCTAssertTrue(banner.contains("Close that task"), banner)
    }

    /// The other half of the same defect, and the worse one: a `.done` step of the retired
    /// engineer keeps its ARTIFACTS in the run's produced pool (`computeProducedArtifactNames`
    /// reads every `.done` step regardless of roster), so after a retirement the new Diff
    /// Reviewer would be ready in wave 1 on "Implementation Notes" the new engineer never
    /// wrote — and `hasBlockingUpstream` could not see it, because the roster's producer of
    /// that artifact is a role with no status. A done step is a reference too.
    func testAnUnclosedTaskWithTheRetiredEngineersDoneStep_defersToo() throws {
        let team = try storedPreRenameUltra()
        let index = try seedTask(
            team: team,
            steps: [StepExecution(
                id: "legacy_featureEngineer", role: .changeEngineer, title: "Feature Engineer",
                status: .done, completedAt: MonotonicClock.shared.now(),
                artifacts: [Artifact(name: "Implementation Notes", mimeType: "text/markdown",
                                     relativePath: "notes.md")])],
            roleStatuses: ["legacy_featureEngineer": .done])
        var teams = [team]
        let result = reconcile(&teams, tasksIndex: index)
        XCTAssertEqual(teams[0].nonSupervisorRoles.count, 7)
        XCTAssertEqual(result.report.deferred.first?.reason, .retiredRoleInUnclosedTask)
    }

    /// A role status alone — no step yet — is a reference as well.
    func testARoleStatusAloneForARetiredRole_defersToo() throws {
        let team = try storedPreRenameUltra()
        let index = try seedTask(
            team: team, steps: [], roleStatuses: ["legacy_buildVerifier": .ready])
        var teams = [team]
        let result = reconcile(&teams, tasksIndex: index)
        XCTAssertEqual(result.report.deferred.first?.roleNames, ["Build Verifier"])
    }

    /// A CLOSED task cannot run again: its steps stay as history under raw slugs and the
    /// retirement proceeds. This is the way out the banner names.
    func testAClosedTaskHoldingARetiredRole_doesNotBlockTheRetirement() throws {
        let team = try storedPreRenameUltra()
        let index = try seedTask(
            team: team,
            steps: [StepExecution(id: "legacy_featureEngineer", role: .changeEngineer,
                                  title: "Feature Engineer", status: .paused)],
            roleStatuses: ["legacy_featureEngineer": .idle],
            closedAt: MonotonicClock.shared.now())
        var teams = [team]
        let result = reconcile(&teams, tasksIndex: index)
        XCTAssertEqual(teams[0].nonSupervisorRoles.count, 9)
        XCTAssertTrue(result.report.deferred.isEmpty)
    }

    /// A retired role that is LIVE (`.working` with a `.running` step) is deferred by the
    /// busy rule as well; the retirement reason wins the copy, because a busy task ends on
    /// its own and this one does not.
    func testAWorkingRetiredRole_isDeferred_andTheRetirementReasonNamesIt() throws {
        let team = try storedPreRenameUltra()
        let index = try seedTask(
            team: team,
            steps: [StepExecution(id: "legacy_featureEngineer", role: .changeEngineer,
                                  title: "Feature Engineer", status: .running)],
            roleStatuses: ["legacy_featureEngineer": .working])
        var teams = [team]
        let result = reconcile(&teams, tasksIndex: index)
        XCTAssertEqual(teams[0].nonSupervisorRoles.count, 7)
        XCTAssertEqual(result.report.deferred.count, 1)
        XCTAssertEqual(result.report.deferred.first?.reason, .retiredRoleInUnclosedTask)
        XCTAssertEqual(result.report.deferred.first?.otherBlockingTaskCount, 0,
                       "one task under two reasons is one task, not two")
    }

    /// A task that references only SURVIVING roles does not hold the retirement up — the
    /// second reason is about retired ids, not about tasks in general (the paused-task
    /// rule of the busy scan stays as narrow as it is pinned).
    func testAnUnclosedTaskHoldingOnlySurvivingRoles_doesNotDefer() throws {
        let team = try storedPreRenameUltra()
        let architect = try XCTUnwrap(team.roles.first { $0.systemRoleID == "solutionArchitect" })
        let index = try seedTask(
            team: team,
            steps: [StepExecution(id: architect.id, role: .solutionArchitect,
                                  title: "Architect", status: .paused)],
            roleStatuses: [architect.id: .idle])
        var teams = [team]
        let result = reconcile(&teams, tasksIndex: index)
        XCTAssertEqual(teams[0].nonSupervisorRoles.count, 9)
        XCTAssertTrue(result.report.deferred.isEmpty)
    }

    /// A folder with no Ultra Team at all: the roster finds nothing and the pass is clean.
    func testAFolderWithoutUltraTeam_isUntouchedByTheRoster() throws {
        var teams = [try XCTUnwrap(Team.defaultTeams.first { $0.templateID == "faang" })]
        let before = teams[0].roles.map(\.id)
        reconcile(&teams)
        XCTAssertEqual(teams[0].roles.map(\.id), before)
    }
}
