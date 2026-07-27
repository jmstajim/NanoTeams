import XCTest

@testable import NanoTeams

/// The Autovisor IS the top Supervisor — it must NOT get `ask_supervisor`
/// auto-injected into its LLM schema. Under autonomous mode the manager's own
/// `ask_supervisor` would just be auto-answered in a self-loop; the human steers
/// it by messaging it instead. Every other advisory/non-producing role still gets
/// `ask_supervisor` auto-injected.
///
/// Drives the pure `LLMExecutionService.resolveToolSchemas` (no delegate needed —
/// the instance `toolSchemas` shim early-returns `[]` without one).
final class AutovisorAskSupervisorGateTests: XCTestCase {

    func testManagerTeam_doesNotAutoInjectAskSupervisor() {
        let team = TeamTemplateFactory.autovisor()
        let managerName = team.nonSupervisorRoles.first?.name ?? "Manager"
        let schemas = LLMExecutionService.resolveToolSchemas(for: .custom(id: managerName), team: team)
        XCTAssertFalse(
            schemas.isEmpty,
            "sanity: the manager still resolves its management toolset"
        )
        XCTAssertFalse(
            schemas.contains { $0.name == ToolNames.askSupervisor },
            "the Autovisor must not get ask_supervisor auto-injected (it is the top Supervisor)"
        )
    }

    // MARK: - Hole 1: ask_supervisor planted in stored toolIDs

    func testManagerTeam_plantedAskSupervisorToolID_isStripped() {
        // A hand-edited / mid-run-injected teams.json can plant ask_supervisor in
        // the manager's stored toolIDs — the schema seeding (step 2) copies toolIDs
        // verbatim, so only the final defensive strip stands between the plant and
        // the wire. Runtime rejection follows for free: `allowedToolNames` in
        // +ToolIteration derives from this schema set, so absence here means the
        // model's hallucinated call gets `tool_not_authorized` with NO signal.
        var team = TeamTemplateFactory.autovisor()
        guard let idx = team.roles.firstIndex(where: {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        }) else { return XCTFail("manager team must carry the manager role") }
        team.roles[idx].toolIDs.append(ToolNames.askSupervisor)

        let managerName = team.roles[idx].name
        let schemas = LLMExecutionService.resolveToolSchemas(for: .custom(id: managerName), team: team)

        XCTAssertFalse(schemas.contains { $0.name == ToolNames.askSupervisor },
                       "a planted ask_supervisor in the manager's toolIDs must be stripped")
        XCTAssertTrue(schemas.contains { $0.name == ToolNames.listTasks },
                      "sanity: the strip removes ONLY ask_supervisor, not the management toolset")
    }

    // MARK: - Hole 2: role-lookup miss must not fall back to a set granting ask_supervisor

    func testManagerRoleLookupMiss_fallbackPath_hasNoAskSupervisor() {
        // When `findRole` misses (corrupted / renamed role identity), the resolver
        // falls back to `SystemTemplates.fallbackToolIDs[role.baseID]`. Before the
        // "autovisor" key existed, the manager fell through to
        // `fallbackCustomRoleToolIDs` — which GRANTS ask_supervisor — with the
        // auto-inject gate skipped entirely (it lives inside `if let roleDefinition`).
        var team = TeamTemplateFactory.autovisor()
        guard let idx = team.roles.firstIndex(where: {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        }) else { return XCTFail("manager team must carry the manager role") }
        // Perturb every identifier findRole matches on (id, systemRoleID, name).
        team.roles[idx].id = "corrupted-id"
        team.roles[idx].systemRoleID = "corrupted-system-id"
        team.roles[idx].name = "Corrupted"

        let schemas = LLMExecutionService.resolveToolSchemas(for: .autovisor, team: team)

        XCTAssertFalse(schemas.contains { $0.name == ToolNames.askSupervisor },
                       "the role-lookup-miss fallback must not grant ask_supervisor to the manager")
        XCTAssertTrue(schemas.contains { $0.name == ToolNames.listTasks },
                      "the miss degrades to the manager's real default toolset (fallbackToolIDs[\"autovisor\"]), "
                        + "not the generic custom-role set")
    }

    func testFallbackToolIDs_autovisorKey_isManagerDefaults_noAskSupervisor() {
        let key = AutovisorConstants.managerRoleSystemID
        guard let fallback = SystemTemplates.fallbackToolIDs[key] else {
            return XCTFail("fallbackToolIDs must carry an \"\(key)\" entry — without it a "
                + "role-lookup miss grants the manager fallbackCustomRoleToolIDs (incl. ask_supervisor)")
        }
        XCTAssertEqual(fallback, Set(AutovisorConstants.managerDefaultToolIDs))
        XCTAssertFalse(fallback.contains(ToolNames.askSupervisor))
    }

    func testManagerBuiltinRole_teamNil_noAskSupervisor() {
        // team == nil (team resolution failed entirely): the strip's templateID arm
        // can't fire, so the role.baseID arm + the fallback key must hold the line.
        let schemas = LLMExecutionService.resolveToolSchemas(for: .autovisor, team: nil)
        XCTAssertFalse(schemas.contains { $0.name == ToolNames.askSupervisor },
                       "the builtin .autovisor role must never resolve ask_supervisor, even with no team")
        XCTAssertTrue(schemas.contains { $0.name == ToolNames.listTasks },
                      "sanity: the manager's fallback toolset still resolves without a team")
    }

    // MARK: - Hole 3: templateID lost on a stored team must not fail open

    func testManagerTeam_templateIDLost_stillStripsAskSupervisor() {
        // A stored autovisor team whose templateID was lost (corruption, clone):
        // the role definition IS found and `shouldAutoInjectAskSupervisor` is true
        // for the advisory manager, so the templateID-keyed auto-inject gate fails
        // open. The final strip's `role.baseID == "autovisor"` arm must still fire
        // (the builtin id survives templateID loss via systemRoleID resolution).
        var team = TeamTemplateFactory.autovisor()
        team.templateID = nil
        guard let idx = team.roles.firstIndex(where: {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        }) else { return XCTFail("manager team must carry the manager role") }
        team.roles[idx].toolIDs.append(ToolNames.askSupervisor)

        let schemas = LLMExecutionService.resolveToolSchemas(for: .autovisor, team: team)

        XCTAssertFalse(schemas.contains { $0.name == ToolNames.askSupervisor },
                       "templateID loss must not re-open the ask_supervisor gate (Hole 3)")
        XCTAssertTrue(schemas.contains { $0.name == ToolNames.listTasks },
                      "sanity: management toolset survives the strip")
    }

    // MARK: - Hole 4: the strip held, but the NUDGES named the stripped tool anyway

    /// The gap that let the reported defect ship: every test above pins that
    /// `ask_supervisor` is absent from the manager's schema, and none pinned that the
    /// flow-control nudges respect that. They did not — `handleNoToolCalls` had no
    /// access to the schema at all and unconditionally told the manager to "send it via
    /// ask_supervisor". Observed in production: the manager replied with reasoning and
    /// no tool call, got pointed at a tool it does not have, then emitted two empty
    /// turns and burned its whole recovery budget.
    ///
    /// Drives the REAL resolved schema (not a hand-listed set) so the pin cannot drift
    /// from what actually ships on the wire.
    func testManagerSchema_noNudgeNamesAskSupervisor() {
        let team = TeamTemplateFactory.autovisor()
        let allowed = Set(
            LLMExecutionService.resolveToolSchemas(for: .autovisor, team: team).map(\.name))
        XCTAssertFalse(allowed.contains(ToolNames.askSupervisor), "precondition: the strip held")

        let nudges = [
            LLMExecutionService.noToolCallNudge(allowedToolNames: allowed),
            LLMExecutionService.repetitiveNonToolNudge(count: 3, allowedToolNames: allowed),
            LLMExecutionService.toolNameExamples(allowedToolNames: allowed) ?? "",
            LLMExecutionService.loopWarningMessage(
                loopDetection: .repetitiveTool(
                    tool: ToolNames.listTasks, count: 3, message: "repeated list_tasks"),
                allowedToolNames: allowed),
        ]
        for nudge in nudges {
            XCTAssertFalse(
                nudge.contains(ToolNames.askSupervisor),
                "a nudge named a tool the manager's schema does not carry: \(nudge)")
        }
    }

    /// …and the positive half: the manager IS steered at the tool it actually has.
    /// Without this the fix could degrade to "names nothing", which is safe but leaves
    /// the model with no way to end its pass.
    func testManagerSchema_genericNudgeSteersToWaitForEvents() {
        let team = TeamTemplateFactory.autovisor()
        let allowed = Set(
            LLMExecutionService.resolveToolSchemas(for: .autovisor, team: team).map(\.name))
        XCTAssertTrue(allowed.contains(ToolNames.waitForEvents),
                      "precondition: wait_for_events is the manager's pass terminal")

        let nudge = LLMExecutionService.noToolCallNudge(allowedToolNames: allowed)
        XCTAssertTrue(nudge.contains(ToolNames.waitForEvents), "got: \(nudge)")
    }

    func testNormalAdvisoryRole_stillAutoInjectsAskSupervisor() {
        // Minimal non-manager chat team with an advisory role (input dep, no outputs).
        let advisory = TeamRoleDefinition(
            id: "assistant", name: "Assistant", prompt: "", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"], producesArtifacts: []),
            isSystemRole: true, systemRoleID: "assistant"
        )
        let team = Team(
            id: "t", name: "T", roles: [advisory], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        let schemas = LLMExecutionService.resolveToolSchemas(for: .custom(id: "Assistant"), team: team)
        XCTAssertTrue(
            schemas.contains { $0.name == ToolNames.askSupervisor },
            "a normal advisory role must still get ask_supervisor auto-injected"
        )
    }
}
