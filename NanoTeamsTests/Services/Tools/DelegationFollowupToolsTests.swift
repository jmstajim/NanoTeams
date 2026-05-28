import XCTest
@testable import NanoTeams

/// Unit tests for the three companion tools auto-injected alongside
/// `delegate_to_team`: `cancel_delegation`, `resume_delegation`,
/// `forward_to_team`. Each handler is a thin signal emitter — actual
/// orchestration lives in `LLMExecutionService+DelegateToTeam.swift`. These
/// tests pin the schema contract (required args, signal shape) so the
/// service-layer handlers always receive validated input.
@MainActor
final class DelegationFollowupToolsTests: XCTestCase {

    private func makeContext() -> ToolExecutionContext {
        ToolExecutionContext(
            workFolderRoot: URL(fileURLWithPath: "/tmp"),
            taskID: 1,
            runID: 0,
            roleID: "coding_agent_coding_agent"
        )
    }

    // MARK: - cancel_delegation

    func testCancelDelegation_emitsSignalWithIDAndReason() {
        let tool = CancelDelegationTool()
        let result = tool.handle(
            context: makeContext(),
            args: ["child_task_id": 42, "reason": "looping"]
        )
        XCTAssertFalse(result.isError)
        guard case let .cancelDelegation(childID, reason) = result.signal else {
            return XCTFail("Expected .cancelDelegation signal, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(childID, 42)
        XCTAssertEqual(reason, "looping")
    }

    func testCancelDelegation_reasonOptional() {
        let tool = CancelDelegationTool()
        let result = tool.handle(context: makeContext(), args: ["child_task_id": 7])
        XCTAssertFalse(result.isError)
        guard case let .cancelDelegation(_, reason) = result.signal else {
            return XCTFail("Expected .cancelDelegation signal")
        }
        XCTAssertNil(reason, "reason is optional — handler must accept missing key")
    }

    func testCancelDelegation_missingChildID_returnsInvalidArgs() {
        let tool = CancelDelegationTool()
        let result = tool.handle(context: makeContext(), args: ["reason": "x"])
        XCTAssertTrue(result.isError, "Missing required child_task_id must surface as INVALID_ARGS")
    }

    // MARK: - resume_delegation

    func testResumeDelegation_emitsSignalWithID() {
        let tool = ResumeDelegationTool()
        let result = tool.handle(context: makeContext(), args: ["child_task_id": 99])
        XCTAssertFalse(result.isError)
        guard case let .resumeDelegation(childID) = result.signal else {
            return XCTFail("Expected .resumeDelegation signal, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(childID, 99)
    }

    func testResumeDelegation_missingChildID_returnsInvalidArgs() {
        let tool = ResumeDelegationTool()
        let result = tool.handle(context: makeContext(), args: [:])
        XCTAssertTrue(result.isError)
    }

    // MARK: - forward_to_team

    func testForwardToTeam_emitsSignalWithIDAndMessage() {
        let tool = ForwardToTeamTool()
        let result = tool.handle(
            context: makeContext(),
            args: ["child_task_id": 7, "message": "use library X instead"]
        )
        XCTAssertFalse(result.isError)
        guard case let .forwardToTeam(childID, message) = result.signal else {
            return XCTFail("Expected .forwardToTeam signal, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(childID, 7)
        XCTAssertEqual(message, "use library X instead")
    }

    func testForwardToTeam_emptyMessage_returnsInvalidArgs() {
        let tool = ForwardToTeamTool()
        let result = tool.handle(
            context: makeContext(),
            args: ["child_task_id": 7, "message": "   "]
        )
        XCTAssertTrue(result.isError,
                      "Empty message after trim must surface as INVALID_ARGS — forwarding nothing is meaningless")
    }

    func testForwardToTeam_missingMessage_returnsInvalidArgs() {
        let tool = ForwardToTeamTool()
        let result = tool.handle(context: makeContext(), args: ["child_task_id": 7])
        XCTAssertTrue(result.isError)
    }

    func testForwardToTeam_trimsLeadingTrailingWhitespace() {
        let tool = ForwardToTeamTool()
        let result = tool.handle(
            context: makeContext(),
            args: ["child_task_id": 7, "message": "  use X  \n"]
        )
        XCTAssertFalse(result.isError)
        guard case let .forwardToTeam(_, message) = result.signal else {
            return XCTFail("Expected signal")
        }
        XCTAssertEqual(message, "use X",
                       "Leading/trailing whitespace must be trimmed before signalling — keeps the injected child message clean")
    }

    // MARK: - Auto-injection

    /// All 4 delegation tools (delegate_to_team + cancel/resume/forward) must
    /// auto-inject as a unit when the role has delegation enabled (whitelist
    /// OR generated permission). Without the companions, the role would
    /// receive the `paused_by_supervisor` envelope but have no tools to act
    /// on it.
    func testAutoInjection_fullPackAppearsWhenDelegationIsEnabled() {
        let role = TeamRoleDefinition(
            id: "test_role",
            name: "Tester",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowDelegationToGeneratedTeams: true
        )
        let tools = LLMExecutionService.toolSchemasFor(roleDefinition: role)

        let names = Set(tools.map(\.name))
        XCTAssertTrue(names.contains(ToolNames.delegateToTeam),
                      "delegate_to_team auto-injects — settings-driven, never in toolIDs")
        XCTAssertTrue(names.contains(ToolNames.cancelDelegation),
                      "cancel_delegation must auto-inject — without it the role can't abort a paused delegation")
        XCTAssertTrue(names.contains(ToolNames.resumeDelegation),
                      "resume_delegation must auto-inject — without it the role can't continue a paused delegation")
        XCTAssertTrue(names.contains(ToolNames.forwardToTeam),
                      "forward_to_team must auto-inject — without it the role can't send guidance to a paused team")
    }

    /// Roles without delegation settings must NOT receive any of the 4 tools —
    /// even if `delegate_to_team` ended up in `toolIDs` (e.g. legacy data).
    /// Schema build filters delegation tools out of `toolIDs` defensively, then
    /// only injects them via the settings-driven path.
    func testAutoInjection_fullPackAbsentWithoutSettings() {
        let role = TeamRoleDefinition(
            id: "test_role",
            name: "Tester",
            prompt: "",
            toolIDs: [ToolNames.readFile, ToolNames.writeFile, ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let tools = LLMExecutionService.toolSchemasFor(roleDefinition: role)
        let names = Set(tools.map(\.name))
        XCTAssertFalse(names.contains(ToolNames.delegateToTeam),
                       "delegate_to_team must be filtered out — toolIDs membership is no longer a trigger")
        XCTAssertFalse(names.contains(ToolNames.cancelDelegation))
        XCTAssertFalse(names.contains(ToolNames.resumeDelegation))
        XCTAssertFalse(names.contains(ToolNames.forwardToTeam))
    }

    // MARK: - Empty-catalog guard (H1: settings-says-yes but catalog-says-no)

    /// `delegationEnabled` only checks `hasDelegationConfigured` (whitelist
    /// non-empty OR generated permission). It does NOT check that whitelisted
    /// teams still EXIST. If every whitelisted team has been deleted AND
    /// generated permission is off, injecting the pack would give the LLM a
    /// useless tool — every invocation hits `delegationDenied`. The runtime
    /// guard in step 7 must skip the entire pack in that case.
    func testAutoInjection_packSkipped_whenWhitelistAllDeletedAndGeneratedOff() {
        let role = TeamRoleDefinition(
            id: "test_role", name: "Tester", prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["deleted-team-id-1", "deleted-team-id-2"],
            allowDelegationToGeneratedTeams: false
        )
        // No teams in the catalog → all whitelist entries unresolvable.
        let tools = LLMExecutionService.toolSchemasFor(roleDefinition: role, allTeams: [])
        let names = Set(tools.map(\.name))
        XCTAssertFalse(names.contains(ToolNames.delegateToTeam),
                       "Whole pack must be skipped when no whitelisted team resolves and generated is off")
        XCTAssertFalse(names.contains(ToolNames.cancelDelegation),
                       "Companions are nonsensical without an active delegation entry point")
        XCTAssertFalse(names.contains(ToolNames.resumeDelegation))
        XCTAssertFalse(names.contains(ToolNames.forwardToTeam))
    }

    /// Whitelist-only role with at least ONE existing non-chat team → pack
    /// injects normally. `delegate_to_team`'s description carries the
    /// surviving team's catalog entry; companions appear too.
    func testAutoInjection_packAppears_whenAtLeastOneWhitelistedTeamExists() {
        var supervisorDeps = RoleDependencies()
        supervisorDeps.requiredArtifacts = ["Final"]
        let supervisor = TeamRoleDefinition(
            id: "alpha-sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: supervisorDeps,
            isSystemRole: true, systemRoleID: "supervisor"
        )
        let alpha = Team(
            id: "alpha-id", name: "Alpha Team", description: "Specialist",
            roles: [supervisor], artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
        let role = TeamRoleDefinition(
            id: "test_role", name: "Tester", prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["alpha-id", "deleted-id"],
            allowDelegationToGeneratedTeams: false
        )
        let tools = LLMExecutionService.toolSchemasFor(roleDefinition: role, allTeams: [alpha])
        let names = Set(tools.map(\.name))
        XCTAssertTrue(names.contains(ToolNames.delegateToTeam))
        XCTAssertTrue(names.contains(ToolNames.cancelDelegation))
        XCTAssertTrue(names.contains(ToolNames.resumeDelegation))
        XCTAssertTrue(names.contains(ToolNames.forwardToTeam))
        let delegateSchema = tools.first { $0.name == ToolNames.delegateToTeam }!
        XCTAssertTrue(delegateSchema.description.contains("Alpha Team"),
                      "Surviving whitelisted team must appear in the delegate_to_team catalog — pinning the per-role-built schema actually receives `allTeams`")
        XCTAssertFalse(delegateSchema.description.contains("deleted-id"),
                       "Deleted whitelisted team ID must be silently skipped — not surfaced to the LLM")
    }

    /// Whitelisted but chat-mode team → not delegatable (chat-mode has no
    /// completion criterion). With generated off, the guard skips the pack
    /// entirely. Without this filter, the LLM would block forever on the
    /// first delegation attempt.
    func testAutoInjection_packSkipped_whenWhitelistedTeamIsChatModeAndGeneratedOff() {
        let chatTeam = Team(
            id: "chat-id", name: "Chat Team", description: "",
            roles: [], artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
        XCTAssertTrue(chatTeam.isChatMode, "Sanity: team without supervisor required artifacts is chat-mode")
        let role = TeamRoleDefinition(
            id: "test_role", name: "Tester", prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["chat-id"],
            allowDelegationToGeneratedTeams: false
        )
        let tools = LLMExecutionService.toolSchemasFor(roleDefinition: role, allTeams: [chatTeam])
        let names = Set(tools.map(\.name))
        XCTAssertFalse(names.contains(ToolNames.delegateToTeam),
                       "Chat-mode-only whitelist with generated off → pack must be skipped")
        XCTAssertFalse(names.contains(ToolNames.cancelDelegation))
    }

    /// Generated permission alone (empty whitelist) → guard accepts: the
    /// `"generated"` sentinel is always a usable target.
    func testAutoInjection_packAppears_withGeneratedPermissionOnly() {
        let role = TeamRoleDefinition(
            id: "test_role", name: "Tester", prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowDelegationToGeneratedTeams: true
        )
        let tools = LLMExecutionService.toolSchemasFor(roleDefinition: role, allTeams: [])
        let names = Set(tools.map(\.name))
        XCTAssertTrue(names.contains(ToolNames.delegateToTeam),
                      "Generated permission alone is a usable target — pack must inject")
    }
}

// MARK: - Test helper

private extension LLMExecutionService {
    /// Driver for auto-injection logic without instantiating a full service.
    /// Mirrors `toolSchemas(for:team:)` step 3.0 (defensive strip) AND step 7
    /// (4-tool pack injection with the empty-catalog guard). The synthesized
    /// team has empty `reportsTo`, so peer status is satisfied automatically —
    /// `delegationEnabled` then only filters by `hasDelegationConfigured`.
    /// MUST stay in lock-step with the production logic in
    /// `LLMExecutionService+ToolResolution.swift`.
    static func toolSchemasFor(
        roleDefinition: TeamRoleDefinition,
        allTeams: [Team] = []
    ) -> [ToolSchema] {
        let allTools = ToolHandlerRegistry.allSchemas
        let delegationTools = ToolHandlerRegistry.delegationToolsExcludedFromToolIDs
        // Mirror step 3.0: filter delegation tools out of `toolIDs`-derived
        // schemas — they only come from auto-injection in step 7.
        let allowed = roleDefinition.toolIDs.compactMap { id -> ToolSchema? in
            guard !delegationTools.contains(id) else { return nil }
            return allTools.first(where: { $0.name == id })
        }
        var result = allowed
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "supervisor"
        )
        let team = Team(
            id: "test-team", name: "Test",
            roles: [supervisor, roleDefinition],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
        if team.delegationEnabled(for: roleDefinition) {
            // Mirror production's empty-catalog guard: skip the entire pack
            // when no whitelisted team is delegatable AND generated is off.
            let allowedSet = Set(roleDefinition.allowedDelegationTeamIDs)
            let hasUsableTeam = allTeams.contains { allowedSet.contains($0.id) && !$0.isChatMode }
            let hasUsableTarget = hasUsableTeam || roleDefinition.allowDelegationToGeneratedTeams
            guard hasUsableTarget else { return result }
            if !result.contains(where: { $0.name == ToolNames.delegateToTeam }) {
                result.append(DelegateToTeamTool.buildSchema(role: roleDefinition, allTeams: allTeams))
            }
            let companions = [
                ToolNames.cancelDelegation,
                ToolNames.resumeDelegation,
                ToolNames.forwardToTeam,
            ]
            for toolName in companions {
                guard !result.contains(where: { $0.name == toolName }) else { continue }
                guard let schema = allTools.first(where: { $0.name == toolName }) else { continue }
                result.append(schema)
            }
        }
        return result
    }
}
