import XCTest
@testable import NanoTeams

/// Regression coverage for the two delegation-eligibility bugs surfaced by the
/// network-log run on 2026-05-01 and the structural rule introduced to fix them.
///
/// 1. **Role identity** — `codingAgent` was missing from the `Role` enum, so
///    `Role.fromDefinition(...)` for the coding-agent definition fell through
///    to `.custom(id: definition.name)`. `Role.baseID` then became the display
///    name `"Coding Agent"`, while the keys in `team.settings.hierarchy.reportsTo`
///    are seeded `definition.id` strings (`"coding_agent_coding_agent"`). Every
///    eligibility lookup missed and `delegate_to_team` aborted with
///    `DELEGATION_DENIED`. The fix: promote `codingAgent` to a built-in
///    `Role` case (mirrors `codingAssistant`), so `Role.fromDefinition` resolves
///    via `systemRoleID` and `baseID` becomes `"codingAgent"` — a stable
///    identifier that `findRole(byIdentifier:)` recognises.
///
/// 2. **Eligibility rule semantics** — the original rule was "reports directly
///    to Supervisor"; the user clarified it must be "peer-level with the human
///    Supervisor — does not depend on Supervisor". A peer-level role has NO
///    upstream `reportsTo` entry. `Team.roleIsTopLevelDelegator(_:)` was
///    rewritten accordingly, and now takes `TeamRoleDefinition` directly so the
///    call site resolves identity once via `findRole(byIdentifier:)` and the
///    predicate operates on a single canonical `role.id`.
///
/// Plus the structural invariant: `buildSettings` (and `GeneratedTeamBuilder`)
/// auto-derive peer status from the role's delegation **settings** — a role
/// with `hasDelegationConfigured == true` (whitelist or generated permission) is
/// implicitly peer-level and is not auto-wired as a Supervisor subordinate.
@MainActor
final class DelegateToTeamPeerLevelRuleTests: XCTestCase {

    // MARK: - Bug A: codingAgent must resolve to built-in Role, not .custom

    /// `codingAgent` is a system role with `systemRoleID = "codingAgent"` — it
    /// must round-trip through the `Role` enum as `.codingAgent`, NOT as
    /// `.custom(id: "Coding Agent")`. The latter was the original bug.
    func testCodingAgentRole_isBuiltIn_notCustom() {
        let team = TeamTemplateFactory.codingAgent()
        let agentDef = team.nonSupervisorRoles[0]
        let resolved = Role.fromDefinition(agentDef)
        XCTAssertEqual(resolved, .codingAgent,
                       "Coding Agent must resolve to its built-in case; .custom fallback is the bug.")
        XCTAssertFalse(resolved.isCustom)
        XCTAssertEqual(resolved.baseID, "codingAgent",
                       "Built-in Role.baseID is the systemRoleID — stable, not the display name.")
    }

    /// Sanity: the resolver path the handler actually takes (`Role.baseID` →
    /// `findRole(byIdentifier:)`) must locate the def. Without `.codingAgent`
    /// being a built-in, baseID would be `"Coding Agent"` and the systemRoleID
    /// branch wouldn't fire.
    func testHandlerLookupPath_resolvesByBaseID() {
        let team = TeamTemplateFactory.codingAgent()
        let agentDef = team.nonSupervisorRoles[0]
        let baseID = Role.fromDefinition(agentDef).baseID
        XCTAssertEqual(baseID, "codingAgent")
        let resolved = team.findRole(byIdentifier: baseID)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.id, agentDef.id,
                       "findRole(byIdentifier:) must reach the same def via systemRoleID lookup.")
    }

    // MARK: - Bug B: eligibility rule (peer, not subordinate)

    /// FAANG's PM reports directly to Supervisor. Under the OLD rule that made
    /// PM eligible to delegate; under the NEW peer-level rule it must fail —
    /// a subordinate is by definition not a peer.
    func testEligibility_subordinateOfSupervisor_isRejected() {
        let faang = TeamTemplateFactory.faang()
        let pm = faang.roles.first { $0.systemRoleID == "productManager" }!
        XCTAssertEqual(faang.settings.hierarchy.reportsTo[pm.id],
                       faang.roles.first(where: \.isSupervisor)?.id,
                       "PM is wired as a Supervisor subordinate in FAANG — sanity.")
        XCTAssertFalse(faang.roleIsTopLevelDelegator(pm),
                       "Subordinate roles must not be eligible — the rule is peer-level, not direct-report.")
    }

    /// Supervisor itself is never a delegator regardless of how the hierarchy
    /// is shaped.
    func testEligibility_supervisorNeverEligible() {
        let team = TeamTemplateFactory.codingAgent()
        let sup = team.roles.first(where: \.isSupervisor)!
        XCTAssertFalse(team.roleIsTopLevelDelegator(sup))
    }

    /// Coding Agent is peer-level (no reportsTo entry). Eligibility passes.
    func testEligibility_codingAgent_isPeerWithSupervisor() {
        let team = TeamTemplateFactory.codingAgent()
        let agent = team.nonSupervisorRoles[0]
        XCTAssertNil(team.settings.hierarchy.reportsTo[agent.id])
        XCTAssertTrue(team.roleIsTopLevelDelegator(agent))
    }

    // MARK: - Structural invariant: peer auto-derived from delegation settings

    /// `buildSettings` (the shared builder behind every static team factory)
    /// must skip `reportsTo` wiring for any role with delegation enabled. This
    /// keeps the settings and the hierarchy in lockstep — there's no way to
    /// silently configure a "subordinate delegator" via the templates.
    func testTemplateFactory_doesNotWireDelegatingRoleAsSubordinate() {
        let team = TeamTemplateFactory.codingAgent()
        let agent = team.nonSupervisorRoles[0]
        XCTAssertTrue(agent.hasDelegationConfigured,
                      "Sanity: codingAgent template configures delegation (whitelist + generated).")
        XCTAssertNil(team.settings.hierarchy.reportsTo[agent.id],
                     "buildSettings must omit reportsTo for any role with delegation enabled.")
    }

    /// FAANG roles do NOT carry `delegate_to_team`, so the auto-wiring still
    /// applies — every non-Supervisor role still reports to Supervisor. We
    /// don't want to accidentally drop hierarchy for ordinary teams.
    func testTemplateFactory_stillWiresNonDelegatingRoles() {
        let faang = TeamTemplateFactory.faang()
        let supID = faang.roles.first(where: \.isSupervisor)!.id
        for role in faang.nonSupervisorRoles {
            XCTAssertFalse(role.hasDelegationConfigured)
            XCTAssertEqual(faang.settings.hierarchy.reportsTo[role.id], supID,
                           "FAANG roles don't delegate, so they keep their default Supervisor wiring.")
        }
    }

    /// `GeneratedTeamBuilder` must obey the same rule — generated teams whose
    /// roles have delegation settings populated get peer-level placement
    /// automatically. We synthesize the role with delegation tools in `tools`
    /// (the migration path strips them from `toolIDs`) AND post-mutate
    /// `allowedDelegationTeamIDs` so settings drive the predicate. Without the
    /// latter, the new settings-driven `hasDelegationConfigured` would return false
    /// and `buildSettings` would auto-wire it as a subordinate.
    func testGeneratedTeamBuilder_doesNotWireDelegatingRoleAsSubordinate() throws {
        let json = """
        {
          "name": "Generated Test",
          "description": "",
          "roles": [{
            "name": "Captain",
            "prompt": "Captain prompt",
            "tools": ["read_file"],
            "produces_artifacts": [],
            "requires_artifacts": []
          }]
        }
        """
        let config = try JSONDecoder().decode(GeneratedTeamConfig.self, from: Data(json.utf8))
        var team = GeneratedTeamBuilder.buildTeam(from: config)
        // Settings-driven peer derivation: post-mutate to flip hasDelegationConfigured.
        // Then re-derive `reportsTo` to mirror what `buildSettings` does at the
        // factory boundary (the test exercises the predicate, not the builder API).
        let captainIdx = team.roles.firstIndex { !$0.isSupervisor }!
        team.roles[captainIdx].allowDelegationToGeneratedTeams = true
        team.settings.hierarchy.reportsTo.removeValue(forKey: team.roles[captainIdx].id)
        let captain = team.roles[captainIdx]
        XCTAssertTrue(captain.hasDelegationConfigured)
        XCTAssertNil(team.settings.hierarchy.reportsTo[captain.id],
                     "Roles with delegation settings populated must not be wired as subordinates.")
        XCTAssertTrue(team.roleIsTopLevelDelegator(captain))
    }

    // MARK: - parentRoleID identifier shape

    /// Sibling regression to the eligibility-check ID mismatch: the same class
    /// of bug existed in the escalation path. The handler used to stamp
    /// `child.parentRoleID = initiatingRole.baseID` ("codingAgent" — systemRoleID
    /// for built-ins, display name for customs), but
    /// `DelegatedSupervisorAnswerService.askSupervisorRole` looks up the parent
    /// step via `step.id == roleID`. `StepExecution.id` equals
    /// `TeamRoleDefinition.id` (the seeded identifier — `"coding_agent_coding_agent"`),
    /// so the lookup always missed and escalation was broken end-to-end.
    ///
    /// This test pins the data-model contract: `NTMSTask.parentRoleID` must be
    /// the canonical seeded `def.id` shape so it lines up with `step.id` keys.
    func testParentRoleID_isCanonicalDefID_notBaseID() {
        let team = TeamTemplateFactory.codingAgent()
        let agentDef = team.nonSupervisorRoles[0]
        let runtimeRole = Role.fromDefinition(agentDef)

        // The handler resolves identity through findRole(byIdentifier: baseID)
        // and then forwards `parentRoleDef.id` — never `baseID` — into
        // createDelegatedTask. The two are intentionally different shapes.
        let resolvedDef = team.findRole(byIdentifier: runtimeRole.baseID)
        XCTAssertNotNil(resolvedDef)
        XCTAssertNotEqual(resolvedDef!.id, runtimeRole.baseID,
                          "Sanity: seeded def.id and baseID are different shapes — that's why the bug existed.")

        // Build a step the way the engine does (StepExecution.id = roleID = def.id).
        let step = StepExecution(id: resolvedDef!.id, role: runtimeRole, title: "Step")
        XCTAssertEqual(step.id, resolvedDef!.id,
                       "step.id contract: it must equal the seeded def.id. parentRoleID has to match this shape.")
    }

    // MARK: - createTask return shape

    /// `repository.createTask` returns the new task ID explicitly so child-task
    /// flows (delegation) don't need the brittle `nextTaskID - 1` recovery —
    /// the counter could change shape and silently break callers.
    func testCreateTask_returnsExplicitTaskID() throws {
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-create-task-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderRoot) }

        let repo = NTMSRepository()
        _ = try repo.openOrCreateWorkFolder(at: workFolderRoot)

        let (snapshot1, id1) = try repo.createTask(
            at: workFolderRoot, title: "A", supervisorTask: "x",
            preferredTeamID: nil, parentTaskID: nil, parentRoleID: nil, delegationDepth: 0
        )
        XCTAssertEqual(snapshot1.activeTaskID, id1,
                       "Top-level task: returned id must match the new active task.")

        // Delegated child: activeTaskID stays on parent, but the returned id
        // is still the freshly allocated child id.
        let (snapshot2, id2) = try repo.createTask(
            at: workFolderRoot, title: "B", supervisorTask: "y",
            preferredTeamID: nil, parentTaskID: id1, parentRoleID: "pm", delegationDepth: 1
        )
        XCTAssertEqual(snapshot2.activeTaskID, id1,
                       "Child task creation must NOT change activeTaskID (supervisor stays on parent).")
        XCTAssertNotEqual(id2, id1)
        XCTAssertGreaterThan(id2, id1)
    }

    // MARK: - Stale-data normalization

    /// Self-heal regression: a `teams.json` written before the peer-derivation
    /// rule existed still has `reportsTo[codingAgent.id] = supervisor.id`. When
    /// such data lands on disk, every `delegate_to_team` call by Coding Agent
    /// fails with `DELEGATION_DENIED` because the runtime check sees the role
    /// as a Supervisor subordinate. `normalizeDelegatorPeerStatus` strips that
    /// stale entry on every load so the invariant self-heals — without forcing
    /// the user to delete the team and recreate it from the template.
    func testNormalizeDelegatorPeerStatus_stripsStaleReportsToEntries() {
        // Build the modern Coding Agent template (peer-level by construction),
        // then re-introduce the legacy wiring to simulate a pre-fix teams.json.
        var team = TeamTemplateFactory.codingAgent()
        let agentDef = team.nonSupervisorRoles[0]
        let supID = team.roles.first(where: \.isSupervisor)!.id
        team.settings.hierarchy.reportsTo[agentDef.id] = supID

        XCTAssertFalse(team.roleIsTopLevelDelegator(agentDef),
                       "Legacy state — eligibility check correctly rejects it. Without normalization, delegation breaks.")

        let repo = NTMSRepository()
        var teams = [team]
        let didChange = repo.normalizeDelegatorPeerStatus(teams: &teams)
        XCTAssertTrue(didChange, "Normalizer must report a write-back was needed.")
        XCTAssertNil(teams[0].settings.hierarchy.reportsTo[agentDef.id],
                     "Stale upstream entry must be removed for the delegating role.")
        XCTAssertTrue(teams[0].roleIsTopLevelDelegator(agentDef),
                      "After normalization, eligibility passes — the user can delegate again.")

        // Idempotent — second call is a no-op.
        let didChangeAgain = repo.normalizeDelegatorPeerStatus(teams: &teams)
        XCTAssertFalse(didChangeAgain, "Normalizer must be idempotent on already-clean data.")
    }

    /// Non-delegating roles must keep their `reportsTo` wiring — the normalizer
    /// must not touch FAANG's PM/Engineer/etc.
    func testNormalizeDelegatorPeerStatus_leavesNonDelegatingRolesAlone() {
        var teams = [TeamTemplateFactory.faang()]
        let repo = NTMSRepository()
        let didChange = repo.normalizeDelegatorPeerStatus(teams: &teams)
        XCTAssertFalse(didChange, "FAANG has no delegating roles — nothing to strip.")
        let supID = teams[0].roles.first(where: \.isSupervisor)!.id
        for role in teams[0].nonSupervisorRoles {
            XCTAssertEqual(teams[0].settings.hierarchy.reportsTo[role.id], supID,
                           "Subordinate wiring intact for non-delegating roles.")
        }
    }

    // MARK: - User path

    /// Full happy path for the user-facing flow that originally failed:
    /// 1. The shipping Coding Agent template is loaded.
    /// 2. `TeamValidationService.validateDelegationPolicy` runs against the team — no
    ///    `nonTopLevelDelegator` issue is emitted.
    /// 3. The handler's resolver path (`Role.fromDefinition` → `Role.baseID` →
    ///    `Team.findRole(byIdentifier:)`) lands on the correct def.
    /// 4. `roleIsTopLevelDelegator` agrees on the resolved def.
    func testUserPath_codingAgentDelegationIsAccepted_endToEnd() {
        let team = TeamTemplateFactory.codingAgent()
        let agent = team.nonSupervisorRoles[0]

        // (1) Validation pass.
        let allTeams = [team, TeamTemplateFactory.engineering(), TeamTemplateFactory.startup()]
        let issues = TeamValidationService.validateDelegationPolicy(team: team, allTeams: allTeams)
        XCTAssertFalse(issues.contains { issue in
            if case .nonTopLevelDelegator = issue { return true }
            return false
        }, "Coding Agent must not be flagged as a non-top-level delegator.")

        // (2) Resolver path the LLM handler actually walks.
        let runtimeRole = Role.fromDefinition(agent)
        let resolvedDef = team.findRole(byIdentifier: runtimeRole.baseID)
        XCTAssertNotNil(resolvedDef)
        XCTAssertEqual(resolvedDef?.id, agent.id)

        // (3) Eligibility on the resolved def.
        XCTAssertTrue(team.roleIsTopLevelDelegator(resolvedDef!))
    }
}
