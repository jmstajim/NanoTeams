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

    /// Team settings are reset wholesale to the bundled value. Pinned because the
    /// arm is unconditional-overwrite by design: a user edit to a system team's
    /// settings is a documented casualty of a version bump, and a test that only
    /// ever saw the equal case could not tell that apart from the arm being dead.
    func testStaleTeamSettings_areReplacedByTheBundledDefaults() throws {
        var stored = try bundledFAANG()
        let bundledSettings = stored.settings
        stored.settings.supervisorMode = (bundledSettings.supervisorMode == .manual)
            ? .autonomous : .manual
        var teams = [stored]
        var tools = ToolDefinitionRecord.defaultDefinitions()

        let result = reconcile(teams: &teams, tools: &tools)

        XCTAssertTrue(result.touched)
        XCTAssertEqual(teams[0].settings, bundledSettings)
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
