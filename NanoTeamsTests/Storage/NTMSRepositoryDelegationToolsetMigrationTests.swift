import XCTest
@testable import NanoTeams

/// Pins the self-healing migration: any role's `toolIDs` containing one of
/// the 4 delegation tools (delegate_to_team, cancel_delegation,
/// resume_delegation, forward_to_team) — or the legacy `"list_teams"` literal
/// (tool was removed; catalog now embedded inline in `delegate_to_team`'s
/// description) — gets stripped on every work-folder load. Delegation tools
/// auto-inject from settings — they NEVER live in stored `toolIDs` after the
/// rewire. Idempotent.
@MainActor
final class NTMSRepositoryDelegationToolsetMigrationTests: XCTestCase {

    private var repository: NTMSRepository!

    override func setUp() {
        super.setUp()
        repository = NTMSRepository()
    }

    override func tearDown() {
        repository = nil
        super.tearDown()
    }

    private func makeRole(toolIDs: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "r-\(UUID().uuidString)",
            name: "Role",
            prompt: "",
            toolIDs: toolIDs,
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
    }

    private func makeTeam(roles: [TeamRoleDefinition]) -> Team {
        Team(
            id: NTMSID.from(name: "Team-\(UUID().uuidString)"),
            name: "Team",
            roles: roles,
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - Strips delegation tools

    func testNormalizeDelegationToolset_stripsDelegateToTeam() {
        let role = makeRole(toolIDs: [ToolNames.readFile, ToolNames.delegateToTeam, ToolNames.askSupervisor])
        var teams = [makeTeam(roles: [role])]
        let changed = repository.normalizeDelegationToolset(teams: &teams)
        XCTAssertTrue(changed, "Migration must report a mutation.")
        XCTAssertFalse(teams[0].roles[0].toolIDs.contains(ToolNames.delegateToTeam),
            "delegate_to_team must be stripped — it auto-injects from settings now.")
        XCTAssertTrue(teams[0].roles[0].toolIDs.contains(ToolNames.readFile),
            "Non-delegation tools must remain untouched.")
        XCTAssertTrue(teams[0].roles[0].toolIDs.contains(ToolNames.askSupervisor))
    }

    func testNormalizeDelegationToolset_stripsAllCompanionsAndLegacyListTeams() {
        let role = makeRole(toolIDs: [
            ToolNames.delegateToTeam,
            "list_teams",  // legacy literal — tool removed
            ToolNames.cancelDelegation,
            ToolNames.resumeDelegation,
            ToolNames.forwardToTeam,
            ToolNames.readFile,
        ])
        var teams = [makeTeam(roles: [role])]
        _ = repository.normalizeDelegationToolset(teams: &teams)
        XCTAssertEqual(teams[0].roles[0].toolIDs, [ToolNames.readFile],
            "All 4 delegation tools (+ legacy list_teams) must be stripped; non-delegation tools preserved.")
    }

    // MARK: - Idempotent

    func testNormalizeDelegationToolset_idempotent() {
        let role = makeRole(toolIDs: [ToolNames.readFile, ToolNames.delegateToTeam])
        var teams = [makeTeam(roles: [role])]
        let firstChanged = repository.normalizeDelegationToolset(teams: &teams)
        XCTAssertTrue(firstChanged)
        let secondChanged = repository.normalizeDelegationToolset(teams: &teams)
        XCTAssertFalse(secondChanged,
            "Second call must be a no-op — idempotency is the self-healing contract.")
    }

    // MARK: - Preserves settings + reportsTo

    /// Migration only touches `toolIDs`. Delegation settings
    /// (`allowedDelegationTeamIDs` / `allowDelegationToGeneratedTeams`) and
    /// hierarchy (`reportsTo`) round-trip unchanged. The user's choice of
    /// targets must survive the migration.
    func testNormalizeDelegationToolset_doesNotTouchSettingsOrHierarchy() {
        var role = makeRole(toolIDs: [ToolNames.delegateToTeam])
        role.allowedDelegationTeamIDs = ["whitelisted-team-id"]
        role.allowDelegationToGeneratedTeams = true
        var team = makeTeam(roles: [role])
        team.settings.hierarchy.reportsTo = ["someOtherRole": "sup"]
        var teams = [team]

        _ = repository.normalizeDelegationToolset(teams: &teams)

        XCTAssertEqual(teams[0].roles[0].allowedDelegationTeamIDs, ["whitelisted-team-id"],
            "Whitelist must survive migration.")
        XCTAssertTrue(teams[0].roles[0].allowDelegationToGeneratedTeams,
            "Generated permission must survive migration.")
        XCTAssertEqual(teams[0].settings.hierarchy.reportsTo, ["someOtherRole": "sup"],
            "Hierarchy untouched — only toolIDs is mutated.")
    }

    // MARK: - No-op when clean

    func testNormalizeDelegationToolset_noChangeWhenNoDelegationToolsPresent() {
        let role = makeRole(toolIDs: [ToolNames.readFile, ToolNames.askSupervisor])
        var teams = [makeTeam(roles: [role])]
        let changed = repository.normalizeDelegationToolset(teams: &teams)
        XCTAssertFalse(changed, "Clean teams must not be reported as mutated.")
    }

    // MARK: - Wired through migrateIfNeeded → openOrCreateWorkFolder

    /// The migration helper isn't enough on its own — `migrateIfNeeded` must
    /// actually call it on every work-folder open. If someone deletes the call
    /// site at `NTMSRepository+Bootstrap.swift:171-173` (block "2b"), the
    /// helper-level tests above still pass but every shipped user with a
    /// legacy `teams.json` containing `delegate_to_team` in `toolIDs` stays
    /// broken. This test seeds that exact corruption on disk and verifies it
    /// gets stripped by the time `openOrCreateWorkFolder` returns.
    func testOpenOrCreateWorkFolder_invokesNormalizeDelegationToolset() throws {
        let workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-bootstrap-strip-\(UUID().uuidString)")
        // `openOrCreateWorkFolder` does not create its parent directory; pre-create
        // the folder so the bootstrap can write `.nanoteams/internal/*.json`.
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }

        // First open — bootstraps default teams (Coding Agent included).
        let context = try repository.openOrCreateWorkFolder(at: workFolder)

        // Hand-corrupt teams.json: append `delegate_to_team` to the Coding
        // Agent's toolIDs (mimicking a legacy file written before the rewire).
        let codingAgentTeam = context.workFolder.teams.first { $0.templateID == "codingAgent" }
        XCTAssertNotNil(codingAgentTeam, "Coding Agent must bootstrap as a default team")

        try repository.updateTeams(at: workFolder) { teams in
            guard let teamIdx = teams.firstIndex(where: { $0.templateID == "codingAgent" }),
                  let roleIdx = teams[teamIdx].roles.firstIndex(where: { !$0.isSupervisor })
            else {
                XCTFail("Coding Agent role missing")
                return
            }
            // Force-inject delegate_to_team via direct toolIDs mutation, bypassing
            // any save-handler stripping. After the next open, migration must clean it up.
            if !teams[teamIdx].roles[roleIdx].toolIDs.contains(ToolNames.delegateToTeam) {
                teams[teamIdx].roles[roleIdx].toolIDs.append(ToolNames.delegateToTeam)
            }
            if !teams[teamIdx].roles[roleIdx].toolIDs.contains("list_teams") {
                teams[teamIdx].roles[roleIdx].toolIDs.append("list_teams")
            }
        }

        // Verify the corruption persisted to disk.
        let cContext = try repository.openOrCreateWorkFolder(at: workFolder)
        let role = cContext.workFolder.teams.first { $0.templateID == "codingAgent" }?
            .roles.first { !$0.isSupervisor }
        XCTAssertFalse(role?.toolIDs.contains(ToolNames.delegateToTeam) ?? true,
            "openOrCreateWorkFolder must invoke normalizeDelegationToolset and strip delegate_to_team from toolIDs.")
        XCTAssertFalse(role?.toolIDs.contains("list_teams") ?? true,
            "openOrCreateWorkFolder must strip legacy list_teams literal from toolIDs.")
        // Sanity: the role's delegation settings are NOT touched — Coding
        // Agent should still report `hasDelegationConfigured == true` from
        // its template-default whitelist.
        XCTAssertTrue(role?.hasDelegationConfigured ?? false,
            "Migration must not clear delegation settings — only toolIDs is mutated.")
    }
}
