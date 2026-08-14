import XCTest

@testable import NanoTeams

/// Reproduces the production scenario the other `resolveToolSchemas` suites don't
/// exercise: a STALE `ToolDefinitionRegistry.shared`. The persisted `tools.json`
/// snapshot is read verbatim on work-folder open and is only re-merged with the
/// bundled defaults on an app-version-bump reconcile (or an explicit user save). A
/// `tools.json` written before a newer tool existed (e.g. the Autovisor
/// management tools) therefore lacks that tool's record.
///
/// `resolveToolSchemas` must source tool *availability* from the live handler
/// registry (`ToolHandlerRegistry.allSchemas`), overlaying persisted *customizations*
/// on top — NOT intersect against the stale snapshot. Otherwise a role's configured
/// tools (and every tool auto-injected from `allTools` — `ask_supervisor`,
/// `conclude_meeting`, the delegation pack, the `create_managed_task` inline catalog)
/// are silently dropped, and the model calls one and hits `tool_not_authorized`.
///
/// `ToolDefinitionRegistry.shared` is a process-global singleton; setUp/tearDown reset
/// it to `[]` so this suite can't leak a populated registry into the other
/// resolveToolSchemas tests (which rely on the empty-registry → full-live fallback).
final class ResolveToolSchemasStaleRegistryTests: XCTestCase {

    /// Tools that predate the Autovisor feature — present in an old `tools.json`.
    /// Used to model the stale snapshot.
    private let preExistingToolNames: Set<String> = [
        ToolNames.readFile, ToolNames.readLines, ToolNames.listFiles,
        ToolNames.search, ToolNames.updateScratchpad,
    ]

    private let managementTools = [
        ToolNames.listTasks, ToolNames.taskStatus, ToolNames.createManagedTask,
        ToolNames.controlTask, ToolNames.manageRole, ToolNames.answerTaskQuestion,
        ToolNames.messageTask, ToolNames.scheduleTask, ToolNames.setWorkFolderContext,
        ToolNames.waitForEvents,
    ]

    private var staleSubset: [ToolDefinitionRecord] {
        ToolDefinitionRecord.defaultDefinitions().filter { preExistingToolNames.contains($0.name) }
    }

    /// Resolve the Autovisor's hidden Manager role.
    private func resolveManager(allTeams: [Team] = []) -> [ToolSchema] {
        let team = TeamTemplateFactory.autovisor()
        let managerName = team.nonSupervisorRoles.first?.name ?? "Manager"
        return LLMExecutionService.resolveToolSchemas(for: .custom(id: managerName), team: team, allTeams: allTeams)
    }

    override func setUp() {
        super.setUp()
        ToolDefinitionRegistry.shared.update([])
    }

    override func tearDown() {
        ToolDefinitionRegistry.shared.update([])
        super.tearDown()
    }

    // MARK: - A. The reported bug (+ the catalog injection it also repairs)

    func testAutovisorTools_surviveStaleRegistry() {
        // tools.json predates the Autovisor tools.
        ToolDefinitionRegistry.shared.update(staleSubset)

        // A non-hidden probe team so the create_managed_task catalog has something to list.
        let probe = Team(
            id: "catalog-probe", name: "Catalog Probe", roles: [], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        let schemas = resolveManager(allTeams: [probe])
        let names = Set(schemas.map(\.name))

        for tool in managementTools {
            XCTAssertTrue(
                names.contains(tool),
                "Autovisor tool '\(tool)' must resolve even when tools.json is stale; got \(names.sorted())"
            )
        }

        // The fix also repairs step 3.3: under a stale registry, create_managed_task
        // was absent from `allowedTools`, so the inline-team-catalog rewrite silently
        // no-op'd. Pin that the per-build catalog (not the static fallback) is shipped.
        let createManaged = schemas.first { $0.name == ToolNames.createManagedTask }
        XCTAssertTrue(
            createManaged?.description.contains("catalog-probe") ?? false,
            "create_managed_task must carry the per-build inline team catalog, not the static fallback"
        )
    }

    // MARK: - B. ask_supervisor auto-injection (the fix is not FM-specific)

    /// `ask_supervisor` is auto-injected by sourcing its schema from `allTools` (the
    /// same list the stale snapshot poisons). A stale registry that lacks
    /// `ask_supervisor` must NOT suppress the injection for a normal advisory role.
    func testAskSupervisorAutoInjection_survivesStaleRegistry() {
        ToolDefinitionRegistry.shared.update(staleSubset)   // snapshot lacks ask_supervisor

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
            "ask_supervisor auto-injection must survive a stale tool registry (sourced from the live set)"
        )
    }

    // MARK: - C. conclude_meeting auto-injection (Auto coordinator)

    /// `conclude_meeting` is auto-injected (Auto coordinator) by sourcing its schema
    /// from `allTools` — same poisoning surface as `ask_supervisor`, distinct branch.
    func testConcludeMeetingAutoInjection_survivesStaleRegistry() {
        ToolDefinitionRegistry.shared.update(staleSubset)   // snapshot lacks conclude_meeting

        let host = TeamRoleDefinition(
            id: "host", name: "Host", prompt: "", toolIDs: [ToolNames.requestTeamMeeting],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"], producesArtifacts: []),
            isSystemRole: false, systemRoleID: nil
        )
        let team = Team(
            id: "m", name: "M", roles: [host], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()   // coordinator nil = Auto
        )
        let schemas = LLMExecutionService.resolveToolSchemas(for: .custom(id: "Host"), team: team)
        XCTAssertTrue(
            schemas.contains { $0.name == ToolNames.concludeMeeting },
            "conclude_meeting auto-injection (Auto coordinator) must survive a stale registry"
        )
    }

    // MARK: - D. delegation companion pack

    /// The 3 delegation companions (`cancel_/resume_/forward_`) are pulled from
    /// `allTools.first(where:)`; a stale registry lacking them must not suppress them
    /// for a delegation-enabled role. (`delegate_to_team` is built separately and was
    /// never vulnerable.)
    func testDelegationCompanions_surviveStaleRegistry() {
        ToolDefinitionRegistry.shared.update(staleSubset)   // snapshot lacks the delegation tools

        let agent = TeamRoleDefinition(
            id: "agent", name: "Agent", prompt: "", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: [],
            allowDelegationToGeneratedTeams: true
        )
        let team = Team(
            id: "d", name: "D", roles: [agent], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        let schemas = LLMExecutionService.resolveToolSchemas(for: Role.fromDefinition(agent), team: team)
        let names = Set(schemas.map(\.name))
        for tool in [ToolNames.delegateToTeam, ToolNames.cancelDelegation,
                     ToolNames.resumeDelegation, ToolNames.forwardToTeam] {
            XCTAssertTrue(
                names.contains(tool),
                "delegation tool '\(tool)' must survive a stale registry; got \(names.sorted())"
            )
        }
    }

    // MARK: - E. Persisted customizations still win — partial AND complete registry

    /// A user-edited description in a *partial* (stale) snapshot still overrides the
    /// live default — the fix keeps the snapshot as a customization overlay.
    func testPersistedDescription_overridesLiveDefault_partialRegistry() {
        let edited = "CUSTOM EDITED DESCRIPTION FOR READ_FILE"
        var records = staleSubset
        guard let idx = records.firstIndex(where: { $0.name == ToolNames.readFile }) else {
            return XCTFail("read_file must be in the default definitions")
        }
        records[idx].prompt = edited
        ToolDefinitionRegistry.shared.update(records)

        let schemas = resolveManager()
        XCTAssertEqual(
            schemas.first { $0.name == ToolNames.readFile }?.description, edited,
            "a user-customized tool description must override the live default (partial registry)"
        )
    }

    /// The post-version-bump production state is a COMPLETE registry (every tool
    /// present). The overlay must still apply customizations there (every tool comes
    /// from the snapshot, exercising the dictionary-hit branch uniformly) AND drop no
    /// live tool — the Manager's management tools must still all resolve.
    func testCompleteRegistry_overlaysCustomizations_andDropsNothing() {
        let edited = "CUSTOM EDITED DESCRIPTION (complete registry)"
        var records = ToolDefinitionRecord.defaultDefinitions()
        guard let idx = records.firstIndex(where: { $0.name == ToolNames.readFile }) else {
            return XCTFail("read_file must be in the default definitions")
        }
        records[idx].prompt = edited
        ToolDefinitionRegistry.shared.update(records)

        let schemas = resolveManager()
        let names = Set(schemas.map(\.name))
        for tool in managementTools {
            XCTAssertTrue(names.contains(tool),
                          "a complete registry must not drop management tool '\(tool)'")
        }
        XCTAssertEqual(
            schemas.first { $0.name == ToolNames.readFile }?.description, edited,
            "a user-customized tool description must override the live default (complete registry)"
        )
    }

    // MARK: - F. Autovisor team-generation gate (autovisorAllowTeamGeneration)

    private func resolveManager(allTeams: [Team], allowGenerated: Bool) -> [ToolSchema] {
        let team = TeamTemplateFactory.autovisor()
        let managerName = team.nonSupervisorRoles.first?.name ?? "Manager"
        return LLMExecutionService.resolveToolSchemas(
            for: .custom(id: managerName), team: team, allTeams: allTeams,
            autovisorTeamPolicy: AutovisorTeamPolicy(allowGeneration: allowGenerated)
        )
    }

    /// Default/enabled: the manager's `create_managed_task` schema advertises the
    /// `"generated"` sentinel.
    func testCreateManagedTask_generationEnabled_advertisesGeneratedSentinel() {
        let createManaged = resolveManager(allTeams: [], allowGenerated: true)
            .first { $0.name == ToolNames.createManagedTask }
        XCTAssertNotNil(createManaged)
        XCTAssertTrue(createManaged?.description.contains("generated") ?? false,
                      "generation enabled → create_managed_task must advertise the 'generated' sentinel")
    }

    /// Disabled: the `"generated"` sentinel is stripped from BOTH the inline catalog
    /// and the `team_id` param description (so the model never sees it as an option).
    func testCreateManagedTask_generationDisabled_hidesGeneratedSentinel() {
        let probe = Team(id: "catalog-probe", name: "Catalog Probe", roles: [], artifacts: [],
                         settings: TeamSettings(), graphLayout: TeamGraphLayout())
        let createManaged = resolveManager(allTeams: [probe], allowGenerated: false)
            .first { $0.name == ToolNames.createManagedTask }
        XCTAssertNotNil(createManaged, "create_managed_task must still resolve when generation is off")
        XCTAssertFalse(createManaged?.description.contains("generated") ?? true,
                       "generation disabled → the catalog must not mention 'generated'")
        XCTAssertTrue(createManaged?.description.contains("catalog-probe") ?? false,
                      "existing teams must still be listed when generation is off")
        XCTAssertFalse(createManaged?.parameters.properties?["team_id"]?.description?.contains("generated") ?? true,
                       "the team_id param description must not mention 'generated' when disabled")
    }

    /// The flag only touches `create_managed_task` (the Autovisor Manager's tool).
    /// A normal role that doesn't carry it must be completely unaffected — no
    /// create_managed_task appears whether the flag is on or off.
    func testNonAutovisorRole_generationFlag_isInert() {
        let faang = TeamTemplateFactory.faang()
        guard let pm = faang.roles.first(where: { $0.name == "Product Manager" }) else {
            return XCTFail("FAANG must have a Product Manager")
        }
        for allow in [true, false] {
            let schemas = LLMExecutionService.resolveToolSchemas(
                for: .custom(id: pm.name), team: faang,
                autovisorTeamPolicy: AutovisorTeamPolicy(allowGeneration: allow)
            )
            XCTAssertFalse(schemas.contains { $0.name == ToolNames.createManagedTask },
                           "a non-Autovisor role never gets create_managed_task (allow=\(allow))")
        }
    }
}
