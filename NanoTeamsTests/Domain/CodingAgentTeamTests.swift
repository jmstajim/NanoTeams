import XCTest
@testable import NanoTeams

/// User-path: the Coding Agent template ships as a hybrid — it can edit files
/// directly (write_file / edit_file / delete_file) for small local changes AND
/// delegate complex work to programming-focused built-in teams (Engineering +
/// Startup, no FAANG) without any manual setup. Commits/branches/builds remain
/// off-limits (no git-mutation or build tools).
@MainActor
final class CodingAgentTeamTests: XCTestCase {

    // MARK: - Identity

    func testCodingAgent_isInDefaultTemplates() {
        let templateIDs = Team.defaultTeams.map(\.templateID)
        XCTAssertTrue(templateIDs.contains("codingAgent"),
                      "Coding Agent must be among the bootstrapped default teams.")
    }

    func testCodingAgent_metadata_isInPicker() {
        let ids = TeamTemplateFactory.templateMetadata.map(\.id)
        XCTAssertTrue(ids.contains("codingAgent"))
    }

    // MARK: - Role configuration

    func testCodingAgent_hasSingleNonSupervisorRole_withDelegationConfigured() {
        let team = TeamTemplateFactory.codingAgent()
        let nonSup = team.nonSupervisorRoles
        XCTAssertEqual(nonSup.count, 1)
        let role = nonSup[0]
        // Delegation tools auto-inject from settings — they are NOT part of toolIDs.
        XCTAssertFalse(role.toolIDs.contains(ToolNames.delegateToTeam),
                       "delegate_to_team is auto-injected, never stored in toolIDs.")
        XCTAssertEqual(role.allowedDelegationTeamIDs.count, 2,
                       "Coding Agent must carry the default whitelist (Engineering + Startup).")
        XCTAssertTrue(role.allowDelegationToGeneratedTeams,
                      "Coding Agent must allow generated-team delegation by default.")
        XCTAssertTrue(role.hasDelegationConfigured,
                      "hasDelegationConfigured is settings-driven: any whitelist entry OR generated permission flips it true.")
    }

    func testCodingAgent_hasNoGitMutationOrBuildTools() {
        let role = TeamTemplateFactory.codingAgent().nonSupervisorRoles[0]
        let forbidden: Set<String> = [
            ToolNames.gitAdd, ToolNames.gitCommit, ToolNames.gitCheckout, ToolNames.gitMerge,
            ToolNames.gitPull, ToolNames.gitStash, ToolNames.gitBranch,
            ToolNames.runXcodebuild, ToolNames.runXcodetests,
        ]
        for forbiddenTool in forbidden {
            XCTAssertFalse(role.toolIDs.contains(forbiddenTool),
                           "Coding Agent must NOT carry \(forbiddenTool) — commits/branches/builds stay with the Supervisor or a delegated team.")
        }
    }

    func testCodingAgent_hasInvestigationAndDirectEditTools() {
        let role = TeamTemplateFactory.codingAgent().nonSupervisorRoles[0]
        // delegate_to_team is not in toolIDs — it auto-injects from delegation settings.
        let required: Set<String> = [
            ToolNames.readFile, ToolNames.readLines, ToolNames.listFiles, ToolNames.search,
            ToolNames.writeFile, ToolNames.editFile, ToolNames.deleteFile,
            ToolNames.gitStatus, ToolNames.gitDiff, ToolNames.gitLog, ToolNames.gitBranchList,
            ToolNames.askSupervisor,
        ]
        for tool in required {
            XCTAssertTrue(role.toolIDs.contains(tool),
                          "Coding Agent must carry \(tool) for investigation + direct small-edit work.")
        }
    }

    // MARK: - Default delegation whitelist

    func testCodingAgent_whitelist_includesEngineeringAndStartup() {
        let role = TeamTemplateFactory.codingAgent().nonSupervisorRoles[0]
        let engineeringID = NTMSID.from(name: "Engineering Team")
        let startupID = NTMSID.from(name: "Startup")
        XCTAssertTrue(role.allowedDelegationTeamIDs.contains(engineeringID),
                      "Engineering team must be in the default whitelist.")
        XCTAssertTrue(role.allowedDelegationTeamIDs.contains(startupID),
                      "Startup team must be in the default whitelist.")
    }

    func testCodingAgent_whitelist_excludesFAANG() {
        let role = TeamTemplateFactory.codingAgent().nonSupervisorRoles[0]
        let faangID = NTMSID.from(name: "FAANG Team")
        XCTAssertFalse(role.allowedDelegationTeamIDs.contains(faangID),
                       "FAANG must NOT be in the default whitelist (per spec).")
    }

    func testCodingAgent_whitelist_excludesSelf() {
        let team = TeamTemplateFactory.codingAgent()
        let role = team.nonSupervisorRoles[0]
        XCTAssertFalse(role.allowedDelegationTeamIDs.contains(team.id),
                       "Self-delegation is rejected by validation; whitelist should not list own team.")
    }

    func testCodingAgent_generatedTeams_areEnabledByDefault() {
        let role = TeamTemplateFactory.codingAgent().nonSupervisorRoles[0]
        XCTAssertTrue(role.allowDelegationToGeneratedTeams,
                      "Coding Agent ships with generated-team delegation ON so it can spawn tailored teams when no stored team fits.")
    }

    // MARK: - Eligibility

    func testCodingAgent_role_isTopLevelDelegator() {
        let team = TeamTemplateFactory.codingAgent()
        let role = team.nonSupervisorRoles[0]
        XCTAssertTrue(role.hasDelegationConfigured,
                      "Coding Agent has delegation settings populated — peer status is auto-derived from the settings.")
        XCTAssertNil(team.settings.hierarchy.reportsTo[role.id],
                     "Roles with delegation enabled must NOT be auto-wired as Supervisor subordinates; that's how peer-level is expressed structurally.")
        XCTAssertTrue(team.roleIsTopLevelDelegator(role),
                      "Coding Agent is peer-level with Supervisor → eligibility passes.")
        XCTAssertTrue(team.delegationEnabled(for: role),
                      "Combined predicate: peer-level + has targets → delegation enabled.")
        // codingAgent must be a built-in Role case so `Role.fromDefinition` doesn't
        // fall through to `.custom(name:)` (the source of the original ID-mismatch bug).
        XCTAssertEqual(Role.fromDefinition(role), .codingAgent,
                       "codingAgent is a built-in Role — it must not resolve to .custom.")
        XCTAssertEqual(Role.fromDefinition(role).baseID, "codingAgent",
                       "Built-in roles use systemRoleID as baseID; not the display name.")
    }

    // MARK: - Mode

    func testCodingAgent_isChatMode() {
        // No supervisor-required artifacts → chat mode (continuous dialog).
        let team = TeamTemplateFactory.codingAgent()
        XCTAssertTrue(team.isChatMode,
                      "Coding Agent operates as a dialog-first team (no required artifacts).")
    }
}
