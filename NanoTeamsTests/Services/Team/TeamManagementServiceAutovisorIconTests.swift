import XCTest
@testable import NanoTeams

/// Pins `TeamManagementService.syncAutovisorTeamToTemplate` — the pure helper behind
/// the open-time migration that keeps the hidden Autovisor team's template invariants
/// (Manager role icon + mandatory tools + Auto meeting coordinator) in lock-step with
/// the template (the parts the user never customizes). Extracted from `ensureAutovisorTask`
/// so the matching + idempotency logic is unit-testable without starting the engine.
final class TeamManagementServiceAutovisorIconTests: XCTestCase {

    /// The single source of truth for the Manager role's icon — sourced from the
    /// template so this test never hardcodes the literal and tracks future renames.
    private var templateIcon: String {
        SystemTemplates.roles[AutovisorConstants.managerRoleSystemID]?.icon ?? ""
    }

    private func managerRoleIcon(in team: Team) -> String? {
        team.roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.icon
    }

    /// A Autovisor team whose Manager role still carries the pre-rename icon,
    /// simulating a team persisted by an older build.
    private func staleManagerTeam() -> Team {
        var team = TeamTemplateFactory.autovisor()
        let idx = team.roles.firstIndex { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }
        if let idx { team.roles[idx].icon = "slider.horizontal.3" }
        return team
    }

    func testSync_updatesStaleIconToTemplate() {
        XCTAssertFalse(templateIcon.isEmpty, "fixture precondition: template defines a Manager role icon")
        var teams = [staleManagerTeam()]
        XCTAssertEqual(managerRoleIcon(in: teams[0]), "slider.horizontal.3", "fixture precondition")

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertTrue(changed, "a stale icon must report a change so the diff-based persist fires")
        XCTAssertEqual(managerRoleIcon(in: teams[0]), templateIcon)
    }

    func testSync_isNoopWhenAlreadyMatchesTemplate() {
        // A freshly-built team already carries the template icon.
        var teams = [TeamTemplateFactory.autovisor()]
        let before = managerRoleIcon(in: teams[0])
        XCTAssertEqual(before, templateIcon, "fixture precondition")

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertFalse(changed, "no change → no write (idempotent)")
        XCTAssertEqual(managerRoleIcon(in: teams[0]), before)
        // Explicit strip-idempotency: the factory toolset is fully inside the allowed set,
        // so the out-of-set prune must touch nothing. Pins the intent directly (rather than
        // leaving it implied by the icon-only `changed == false`), so a factory default that
        // ever drifts outside `mandatory ∪ optional` fails HERE with a toolset message.
        XCTAssertEqual(
            Set(teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.toolIDs ?? []),
            Set(AutovisorConstants.managerDefaultToolIDs),
            "fresh factory toolset is entirely allowed → the strip must not remove anything")
    }

    func testFactory_managerToolset_includesAnalyzeImage() {
        let team = TeamTemplateFactory.autovisor()
        let mgr = team.roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }
        XCTAssertTrue(mgr?.toolIDs.contains(ToolNames.analyzeImage) ?? false,
                      "the Autovisor role's default toolset includes analyze_image")
    }

    /// A FRESH manager gets the runners from the factory, and the open-time strip —
    /// which is what used to remove them — must now leave them alone. Both halves in
    /// one test, because either one alone passes with the feature half-wired.
    func testFactory_managerToolset_includesXcodeRunners_andSyncKeepsThem() {
        var teams = [TeamTemplateFactory.autovisor()]
        let runners = [ToolNames.runXcodebuild, ToolNames.runXcodetests]

        let seeded = Set(teams[0].roles
            .first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.toolIDs ?? [])
        for tool in runners {
            XCTAssertTrue(seeded.contains(tool), "factory must seed \(tool)")
        }

        _ = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        let afterSync = Set(teams[0].roles
            .first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.toolIDs ?? [])
        for tool in runners {
            XCTAssertTrue(afterSync.contains(tool),
                          "\(tool) is allowed-optional now — the out-of-set strip must not take it")
        }
    }

    func testSync_unionEnforcesMissingMandatoryTool() {
        var team = TeamTemplateFactory.autovisor()
        // Simulate a team persisted by an older build missing a mandatory management tool.
        if let idx = team.roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
            team.roles[idx].toolIDs.removeAll { $0 == ToolNames.listTasks }
        }
        var teams = [team]

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertTrue(changed, "a missing mandatory tool must report a change so the persist fires")
        let mgr = teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }
        XCTAssertTrue(mgr?.toolIDs.contains(ToolNames.listTasks) ?? false,
                      "mandatory management tools are union-enforced")
    }

    func testSync_doesNotRevertRemovedOptionalTool() {
        var team = TeamTemplateFactory.autovisor()
        // The user toggled off analyze_image (optional, default-on) — must NOT be re-added.
        if let idx = team.roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
            team.roles[idx].toolIDs.removeAll { $0 == ToolNames.analyzeImage }
        }
        var teams = [team]

        _ = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        let mgr = teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }
        XCTAssertFalse(mgr?.toolIDs.contains(ToolNames.analyzeImage) ?? true,
                       "optional tools the user switched off are preserved (additive sync is mandatory-only)")
    }

    /// The manager is read-only: a team seeded by an older build that carried repo-mutation
    /// tools — file-write (write_file/edit_file/delete_file) AND git-write
    /// (add/commit/pull/checkout/merge/stash/branch) — must have them stripped on open
    /// (they're outside the allowed set, `mandatory ∪ optional`), while read + management
    /// tools survive. This is how the existing manager is demoted to read-only (the
    /// version-bump reconcile deliberately preserves stored toolIDs, so the prune lives in sync).
    func testSync_stripsWriteTools_keepsReadAndManagement() {
        var team = TeamTemplateFactory.autovisor()
        let writeTools = [ToolNames.writeFile, ToolNames.editFile, ToolNames.deleteFile,
                          ToolNames.gitAdd, ToolNames.gitCommit, ToolNames.gitPull,
                          ToolNames.gitCheckout, ToolNames.gitMerge, ToolNames.gitStash, ToolNames.gitBranch]
        if let idx = team.roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
            team.roles[idx].toolIDs.append(contentsOf: writeTools)
        }
        var teams = [team]

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertTrue(changed, "stripping disallowed write tools must report a change so the persist fires")
        let ids = Set(teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.toolIDs ?? [])
        for t in writeTools {
            XCTAssertFalse(ids.contains(t), "write tool \(t) must be stripped (manager is read-only)")
        }
        for t in [ToolNames.readFile, ToolNames.listFiles, ToolNames.search,
                  ToolNames.gitStatus, ToolNames.gitLog, ToolNames.gitDiff, ToolNames.gitBranchList,
                  ToolNames.listTasks, ToolNames.createManagedTask, ToolNames.waitForEvents] {
            XCTAssertTrue(ids.contains(t), "allowed read/management tool \(t) must survive the strip")
        }
    }

    /// Order-safety: when a single sync must BOTH re-add a missing mandatory tool AND strip a
    /// disallowed write tool, the two operations must not fight. The mandatory union-enforce
    /// runs first (adding tools that are all in the allowed set), then the out-of-set prune —
    /// so the re-added mandatory tool survives while the disallowed tool is removed. Pins the
    /// `Order-safe` comment on the strip block so a future reorder can't silently break it.
    func testSync_stripsDisallowed_andUnionEnforcesMissing_inOneCall() {
        var team = TeamTemplateFactory.autovisor()
        if let idx = team.roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
            team.roles[idx].toolIDs.removeAll { $0 == ToolNames.listTasks }   // missing mandatory
            team.roles[idx].toolIDs.append(ToolNames.gitCommit)               // disallowed write
        }
        var teams = [team]

        XCTAssertTrue(TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams))

        let ids = Set(teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.toolIDs ?? [])
        XCTAssertTrue(ids.contains(ToolNames.listTasks),
                      "union-enforce re-adds the mandatory tool, and the strip must NOT remove it")
        XCTAssertFalse(ids.contains(ToolNames.gitCommit),
                       "the disallowed git-write tool is stripped in the same pass")
    }

    /// The manager IS the top Supervisor: a planted `ask_supervisor` (hand-edited
    /// teams.json / older build) is outside `mandatory ∪ optional` and must be
    /// stripped on open — the persisted layer of the same invariant the schema
    /// resolver enforces at request time (`AutovisorAskSupervisorGateTests`).
    func testSync_stripsPlantedAskSupervisorFromManagerToolIDs() {
        var team = TeamTemplateFactory.autovisor()
        if let idx = team.roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
            team.roles[idx].toolIDs.append(ToolNames.askSupervisor)
        }
        var teams = [team]

        XCTAssertTrue(TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams),
                      "stripping a planted ask_supervisor must report a change so the persist fires")

        let ids = Set(teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.toolIDs ?? [])
        XCTAssertFalse(ids.contains(ToolNames.askSupervisor),
                       "ask_supervisor must be stripped from the manager's stored toolIDs")

        // Idempotence: a second run has nothing left to change.
        XCTAssertFalse(TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams),
                       "second sync is a no-op (idempotent)")
    }

    /// The strip is GENERAL — it removes any tool outside the allowed set, not only file/git
    /// write. delegate_to_team and create_team don't apply to the manager (it IS the top
    /// Supervisor, and it commissions work through `create_managed_task`), so a manager that
    /// somehow carried them must be pruned.
    ///
    /// Previously this planted `run_xcodebuild`, on the rationale that the manager "has no
    /// build step". That rationale is retired: the runners are now allowed-optional, because
    /// verifying whether the repo compiles is triage, not implementation. A tool that is
    /// genuinely out-of-set had to take its place, or the test would have asserted the strip
    /// removes something the strip is now required to keep.
    func testSync_stripsDisallowedNonWriteTools_delegationAndTeamCreation() {
        var team = TeamTemplateFactory.autovisor()
        let disallowed = [ToolNames.delegateToTeam, ToolNames.createTeam]
        if let idx = team.roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
            team.roles[idx].toolIDs.append(contentsOf: disallowed)
        }
        var teams = [team]

        XCTAssertTrue(TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams))

        let ids = Set(teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.toolIDs ?? [])
        for t in disallowed {
            XCTAssertFalse(ids.contains(t), "out-of-set tool \(t) must be stripped (strip is not git/file-specific)")
        }
        XCTAssertTrue(ids.contains(ToolNames.createManagedTask), "allowed management tool survives the strip")
    }

    /// Degenerate input: a manager seeded with an EMPTY toolset (corrupted / hand-edited json).
    /// The union-enforce restores every mandatory tool and the strip leaves nothing out-of-set,
    /// so the manager recovers to exactly the allowed set (optional tools are NOT resurrected —
    /// the union is mandatory-only).
    func testSync_emptyToolset_recoversMandatory_andStaysInSet() {
        var team = TeamTemplateFactory.autovisor()
        if let idx = team.roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
            team.roles[idx].toolIDs = []
        }
        var teams = [team]

        XCTAssertTrue(TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams))

        let ids = Set(teams[0].roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.toolIDs ?? [])
        for t in AutovisorConstants.managerMandatoryToolIDs {
            XCTAssertTrue(ids.contains(t), "mandatory tool \(t) must be union-enforced onto an empty toolset")
        }
        let allowed = Set(AutovisorConstants.managerMandatoryToolIDs)
            .union(AutovisorConstants.managerOptionalToolIDs)
        XCTAssertTrue(ids.isSubset(of: allowed), "no out-of-set tool may be present after sync")
    }

    func testFactory_coordinatorIsAuto() {
        let team = TeamTemplateFactory.autovisor()
        XCTAssertNil(team.settings.meetingCoordinatorRoleID,
                     "the Autovisor team defaults to Auto (nil) coordinator")
    }

    func testSync_normalizesNonAutoCoordinatorToNil() {
        var team = TeamTemplateFactory.autovisor()
        // Simulate a team persisted by an older build that pinned the Manager role.
        team.settings.meetingCoordinatorRoleID = team.roles.first {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        }?.id
        XCTAssertNotNil(team.settings.meetingCoordinatorRoleID, "fixture precondition")
        var teams = [team]

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertTrue(changed, "a non-Auto coordinator must report a change so the persist fires")
        XCTAssertNil(teams[0].settings.meetingCoordinatorRoleID, "coordinator normalized to Auto")
    }

    func testSync_isNoopWithoutAutovisorTeam() {
        // Bundled defaults never include the hidden Autovisor team.
        var teams = Team.defaultTeams
        XCTAssertFalse(teams.contains { $0.templateID == AutovisorConstants.teamTemplateID },
                       "fixture precondition: no Autovisor team present")

        let changed = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)

        XCTAssertFalse(changed)
    }
}
