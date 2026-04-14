import XCTest
@testable import NanoTeams

final class GeneratedTeamBuilderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Helpers

    private func makeConfig(
        name: String = "Test Team",
        roles: [GeneratedTeamConfig.RoleConfig] = [],
        artifacts: [GeneratedTeamConfig.ArtifactConfig] = [],
        supervisorRequires: [String] = [],
        supervisorMode: SupervisorMode? = nil,
        acceptanceMode: AcceptanceMode? = nil
    ) -> GeneratedTeamConfig {
        GeneratedTeamConfig(
            name: name,
            description: "Test description",
            supervisorMode: supervisorMode,
            acceptanceMode: acceptanceMode,
            roles: roles,
            artifacts: artifacts,
            supervisorRequires: supervisorRequires
        )
    }

    private func makeRoleConfig(
        name: String = "Worker",
        produces: [String] = ["Output"],
        requires: [String] = ["Supervisor Task"],
        tools: [String] = ["read_file"],
        icon: String? = nil,
        iconBackground: String? = nil
    ) -> GeneratedTeamConfig.RoleConfig {
        GeneratedTeamConfig.RoleConfig(
            name: name,
            prompt: "Do work for \(name)",
            producesArtifacts: produces,
            requiresArtifacts: requires,
            tools: tools,
            usePlanningPhase: nil,
            icon: icon,
            iconBackground: iconBackground
        )
    }

    private func makeArtifactConfig(name: String = "Output") -> GeneratedTeamConfig.ArtifactConfig {
        GeneratedTeamConfig.ArtifactConfig(name: name, description: "Test artifact", icon: nil)
    }

    // MARK: - buildTeam: Basic Structure

    func testBuildTeam_hasSupervisorAsFirstRole() {
        let config = makeConfig(roles: [makeRoleConfig()])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertTrue(team.roles[0].isSupervisor)
    }

    func testBuildTeam_roleCountIncludesSupervisor() {
        let config = makeConfig(roles: [
            makeRoleConfig(name: "A"),
            makeRoleConfig(name: "B"),
        ])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertEqual(team.roles.count, 3) // Supervisor + A + B
    }

    func testBuildTeam_usesConfigName() {
        let config = makeConfig(name: "Custom Team Name")
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertEqual(team.name, "Custom Team Name")
    }

    func testBuildTeam_teamIDIsUnique() {
        let config = makeConfig(name: "Test")
        let team1 = GeneratedTeamBuilder.buildTeam(from: config)
        let team2 = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertNotEqual(team1.id, team2.id, "Each generation should produce a unique team ID")
        XCTAssertTrue(team1.id.contains("gen"), "Team ID should have a generation suffix")
    }

    // MARK: - buildTeam: Roles

    func testBuildTeam_roleHasUUIDBasedID() {
        let config = makeConfig(roles: [makeRoleConfig()])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        let workerRole = team.roles[1]
        // UUID().uuidString produces uppercase hex with dashes
        XCTAssertTrue(workerRole.id.contains("-"), "Role ID should be UUID-based")
    }

    func testBuildTeam_roleDependenciesSet() {
        let config = makeConfig(roles: [
            makeRoleConfig(produces: ["Spec"], requires: ["Supervisor Task"]),
        ])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        let role = team.roles[1]
        XCTAssertEqual(role.dependencies.producesArtifacts, ["Spec"])
        XCTAssertEqual(role.dependencies.requiredArtifacts, ["Supervisor Task"])
    }

    func testBuildTeam_rolePromptSet() {
        let config = makeConfig(roles: [makeRoleConfig(name: "Coder")])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertEqual(team.roles[1].prompt, "Do work for Coder")
    }

    func testBuildTeam_roleIconApplied() {
        let roleConfig = makeRoleConfig(icon: "star.fill", iconBackground: "#FF0000")

        let config = makeConfig(roles: [roleConfig])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertEqual(team.roles[1].icon, "star.fill")
        XCTAssertEqual(team.roles[1].iconBackground, "#FF0000")
    }

    // MARK: - buildTeam: Tool Validation

    func testBuildTeam_filtersInvalidToolNames() {
        let config = makeConfig(roles: [
            makeRoleConfig(tools: ["read_file", "nonexistent_tool", "write_file"]),
        ])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        let tools = team.roles[1].toolIDs
        XCTAssertTrue(tools.contains("read_file"))
        XCTAssertTrue(tools.contains("write_file"))
        XCTAssertFalse(tools.contains("nonexistent_tool"))
    }

    func testBuildTeam_allInvalidTools_emptyToolIDs() {
        let config = makeConfig(roles: [
            makeRoleConfig(tools: ["fake_tool_1", "fake_tool_2"]),
        ])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertTrue(team.roles[1].toolIDs.isEmpty)
    }

    // MARK: - buildTeam: Artifacts

    func testBuildTeam_includesSupervisorTaskArtifact() {
        let config = makeConfig(
            roles: [makeRoleConfig()],
            artifacts: [makeArtifactConfig()]
        )
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        let artifactNames = team.artifacts.map(\.name)
        XCTAssertTrue(artifactNames.contains(SystemTemplates.supervisorTaskArtifactName))
    }

    func testBuildTeam_includesConfigArtifacts() {
        let config = makeConfig(
            roles: [makeRoleConfig()],
            artifacts: [
                makeArtifactConfig(name: "Spec"),
                makeArtifactConfig(name: "Code"),
            ]
        )
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        let artifactNames = team.artifacts.map(\.name)
        XCTAssertTrue(artifactNames.contains("Spec"))
        XCTAssertTrue(artifactNames.contains("Code"))
    }

    // MARK: - buildTeam: Settings

    func testBuildTeam_supervisorRequiresSet() {
        let config = makeConfig(
            roles: [makeRoleConfig()],
            supervisorRequires: ["Output"]
        )
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        let supervisor = team.roles[0]
        XCTAssertEqual(supervisor.dependencies.requiredArtifacts, ["Output"])
    }

    func testBuild_supervisorRequiresUnproduced_filteredWithWarning() {
        // A5 remaining-gap regression (gemma sessions 9–10): model requested a
        // supervisor deliverable that no role actually produces. Left in place the
        // Supervisor role would wait forever. Builder now drops the unproduced
        // entry from the Supervisor's dependencies and surfaces it via warnings.
        let config = makeConfig(
            roles: [
                makeRoleConfig(name: "Producer", produces: ["Real Output"], requires: ["Supervisor Task"]),
            ],
            artifacts: [
                makeArtifactConfig(name: "Real Output"),
                makeArtifactConfig(name: "Phantom Output"),
            ],
            supervisorRequires: ["Real Output", "Phantom Output"]
        )
        let result = GeneratedTeamBuilder.build(from: config)
        let supervisor = result.team.roles[0]
        XCTAssertEqual(
            supervisor.dependencies.requiredArtifacts,
            ["Real Output"],
            "Supervisor should only wait for artifacts some role actually produces."
        )
        XCTAssertTrue(
            result.warnings.contains { $0.contains("Phantom Output") && $0.contains("no role produces") },
            "Dropped supervisor requirement should surface in warnings — got: \(result.warnings)"
        )
    }

    func testBuild_supervisorRequiresAllProduced_noFilterWarning() {
        let config = makeConfig(
            roles: [makeRoleConfig(produces: ["Output"], requires: ["Supervisor Task"])],
            supervisorRequires: ["Output"]
        )
        let result = GeneratedTeamBuilder.build(from: config)
        XCTAssertEqual(result.team.roles[0].dependencies.requiredArtifacts, ["Output"])
        XCTAssertFalse(
            result.warnings.contains { $0.contains("supervisor requirement") },
            "No filter warning when every sup_require has a producer — got: \(result.warnings)"
        )
    }

    func testBuildTeam_hierarchyAllReportToSupervisor() {
        let config = makeConfig(roles: [
            makeRoleConfig(name: "A"),
            makeRoleConfig(name: "B"),
            makeRoleConfig(name: "C"),
        ])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        let supervisorID = team.roles[0].id
        for role in team.roles where !role.isSupervisor {
            XCTAssertEqual(
                team.settings.hierarchy.reportsTo[role.id], supervisorID,
                "\(role.name) should report to Supervisor"
            )
        }
    }

    func testBuildTeam_supervisorModeAutonomous() {
        let config = makeConfig(
            roles: [makeRoleConfig()],
            supervisorMode: .autonomous
        )
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertEqual(team.settings.supervisorMode, .autonomous)
    }

    func testBuildTeam_supervisorModeDefaultManual() {
        let config = makeConfig(roles: [makeRoleConfig()])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertEqual(team.settings.supervisorMode, .manual)
    }

    func testBuildTeam_acceptanceModeAfterEachRole() {
        let config = makeConfig(
            roles: [makeRoleConfig()],
            acceptanceMode: .afterEachRole
        )
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertEqual(team.settings.defaultAcceptanceMode, .afterEachRole)
    }

    func testBuildTeam_acceptanceModeDefaultFinalOnly() {
        let config = makeConfig(roles: [makeRoleConfig()])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertEqual(team.settings.defaultAcceptanceMode, .finalOnly)
    }

    // MARK: - buildTeam: Graph Layout

    func testBuildTeam_graphLayoutHasPositionsForAllRoles() {
        let config = makeConfig(roles: [
            makeRoleConfig(name: "A"),
            makeRoleConfig(name: "B"),
        ])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        let positionRoleIDs = Set(team.graphLayout.nodePositions.map(\.roleID))
        for role in team.roles {
            XCTAssertTrue(positionRoleIDs.contains(role.id), "Missing position for role: \(role.name)")
        }
    }

    // MARK: - buildTeam: Chat Mode

    func testBuildTeam_chatMode_emptySupervisorRequires() {
        let config = makeConfig(
            roles: [makeRoleConfig(produces: [], requires: ["Supervisor Task"])],
            supervisorRequires: []
        )
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertTrue(team.isChatMode, "Team with empty supervisorRequires should be chat mode")
    }

    func testBuildTeam_producingTeam_notChatMode() {
        let config = makeConfig(
            roles: [makeRoleConfig(produces: ["Output"])],
            artifacts: [makeArtifactConfig()],
            supervisorRequires: ["Output"]
        )
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        XCTAssertFalse(team.isChatMode)
    }

    // MARK: - seedRoleStatuses

    func testSeedRoleStatuses_supervisorDone() {
        let config = makeConfig(roles: [makeRoleConfig()])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        var run = Run(id: 0, steps: [], roleStatuses: [:])
        GeneratedTeamBuilder.seedRoleStatuses(
            for: team, existingRun: &run,
            producedArtifacts: ["Supervisor Task"]
        )

        let supervisorID = team.roles[0].id
        XCTAssertEqual(run.roleStatuses[supervisorID], .done)
    }

    func testSeedRoleStatuses_dependencySatisfied_ready() {
        let config = makeConfig(roles: [
            makeRoleConfig(requires: ["Supervisor Task"]),
        ])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        var run = Run(id: 0, steps: [], roleStatuses: [:])
        GeneratedTeamBuilder.seedRoleStatuses(
            for: team, existingRun: &run,
            producedArtifacts: ["Supervisor Task"]
        )

        let workerID = team.roles[1].id
        XCTAssertEqual(run.roleStatuses[workerID], .ready)
    }

    func testSeedRoleStatuses_dependencyNotSatisfied_idle() {
        let config = makeConfig(roles: [
            makeRoleConfig(requires: ["Missing Artifact"]),
        ])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        var run = Run(id: 0, steps: [], roleStatuses: [:])
        GeneratedTeamBuilder.seedRoleStatuses(
            for: team, existingRun: &run,
            producedArtifacts: ["Supervisor Task"]
        )

        let workerID = team.roles[1].id
        XCTAssertEqual(run.roleStatuses[workerID], .idle)
    }

    func testSeedRoleStatuses_preservesExistingEntries() {
        let config = makeConfig(roles: [makeRoleConfig()])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        let existingRoleID = "team_creator_existing"
        var run = Run(id: 0, steps: [], roleStatuses: [existingRoleID: .done])

        GeneratedTeamBuilder.seedRoleStatuses(
            for: team, existingRun: &run,
            producedArtifacts: ["Supervisor Task"]
        )

        XCTAssertEqual(run.roleStatuses[existingRoleID], .done, "Existing entries should be preserved")
    }

    func testSeedRoleStatuses_chainDependencies_firstReadyRestIdle() {
        let config = makeConfig(roles: [
            makeRoleConfig(name: "First", produces: ["A"], requires: ["Supervisor Task"]),
            makeRoleConfig(name: "Second", produces: ["B"], requires: ["A"]),
            makeRoleConfig(name: "Third", produces: ["C"], requires: ["B"]),
        ])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        var run = Run(id: 0, steps: [], roleStatuses: [:])
        GeneratedTeamBuilder.seedRoleStatuses(
            for: team, existingRun: &run,
            producedArtifacts: ["Supervisor Task"]
        )

        XCTAssertEqual(run.roleStatuses[team.roles[1].id], .ready, "First role should be ready")
        XCTAssertEqual(run.roleStatuses[team.roles[2].id], .idle, "Second role should be idle")
        XCTAssertEqual(run.roleStatuses[team.roles[3].id], .idle, "Third role should be idle")
    }

    func testSeedRoleStatuses_noDependencies_ready() {
        let roleConfig = makeRoleConfig(requires: [])
        let config = makeConfig(roles: [roleConfig])
        let team = GeneratedTeamBuilder.buildTeam(from: config)

        var run = Run(id: 0, steps: [], roleStatuses: [:])
        GeneratedTeamBuilder.seedRoleStatuses(
            for: team, existingRun: &run,
            producedArtifacts: []
        )

        let workerID = team.roles[1].id
        XCTAssertEqual(run.roleStatuses[workerID], .ready,
                       "Role with no dependencies should be ready immediately")
    }

    // MARK: - build (BuildResult): warnings

    func testBuild_droppedTools_reportedInWarnings() {
        let config = makeConfig(roles: [
            makeRoleConfig(name: "Eng", tools: ["read_file", "fake_tool", "another_fake"]),
        ])
        let result = GeneratedTeamBuilder.build(from: config)

        XCTAssertEqual(result.team.roles[1].toolIDs, ["read_file"])
        XCTAssertFalse(result.warnings.isEmpty)
        let joined = result.warnings.joined()
        XCTAssertTrue(joined.contains("Eng"), "Warning should name the role: \(joined)")
        XCTAssertTrue(joined.contains("fake_tool"), "Warning should name dropped tool")
        XCTAssertTrue(joined.contains("another_fake"))
    }

    func testBuild_noDroppedTools_noWarnings() {
        let config = makeConfig(roles: [makeRoleConfig(tools: ["read_file"])])
        let result = GeneratedTeamBuilder.build(from: config)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testBuild_LLMEmittedSupervisor_filteredWithWarning() {
        // The LLM sometimes includes a "Supervisor" role even though we always add one.
        // It must be filtered out — otherwise the team has two Supervisors.
        let config = makeConfig(roles: [
            makeRoleConfig(name: "Supervisor"),
            makeRoleConfig(name: "Engineer"),
        ])
        let result = GeneratedTeamBuilder.build(from: config)

        let supervisorCount = result.team.roles.filter { $0.isSupervisor }.count
        XCTAssertEqual(supervisorCount, 1, "Should have exactly one Supervisor (the auto-injected one)")
        XCTAssertEqual(result.team.roles.count, 2, "Supervisor + Engineer (LLM Supervisor dropped)")
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.warnings.joined().lowercased().contains("supervisor"))
    }

    func testBuild_LLMEmittedSupervisor_caseInsensitiveFilter() {
        // Filter is case- and whitespace-tolerant.
        let config = makeConfig(roles: [
            makeRoleConfig(name: "  SUPERVISOR "),
            makeRoleConfig(name: "Eng"),
        ])
        let result = GeneratedTeamBuilder.build(from: config)
        XCTAssertEqual(result.team.roles.filter { $0.isSupervisor }.count, 1)
        XCTAssertEqual(result.team.roles.count, 2)
    }

    // MARK: - Team ID uniqueness

    func testBuild_teamID_hasGenSuffix() {
        let config = makeConfig(name: "Cool Team", roles: [makeRoleConfig()])
        let team = GeneratedTeamBuilder.buildTeam(from: config)
        XCTAssertTrue(team.id.contains("_gen_"),
                      "Team ID must include `_gen_<suffix>` to disambiguate regenerations: got \(team.id)")
    }

    func testBuild_teamIDs_uniqueAcrossManyGenerations() {
        // Sanity: 100 generations of the same name should produce 100 unique IDs.
        let config = makeConfig(name: "Same Name", roles: [makeRoleConfig()])
        var seen = Set<String>()
        for _ in 0..<100 {
            seen.insert(GeneratedTeamBuilder.buildTeam(from: config).id)
        }
        XCTAssertEqual(seen.count, 100, "All 100 generations should have unique IDs")
    }

    // MARK: - Strong-typed mode passthrough

    func testBuild_typedSupervisorMode_passesThrough() {
        let auto = GeneratedTeamBuilder.buildTeam(from: makeConfig(
            roles: [makeRoleConfig()], supervisorMode: .autonomous
        ))
        let manual = GeneratedTeamBuilder.buildTeam(from: makeConfig(
            roles: [makeRoleConfig()], supervisorMode: .manual
        ))
        XCTAssertEqual(auto.settings.supervisorMode, .autonomous)
        XCTAssertEqual(manual.settings.supervisorMode, .manual)
    }

    func testBuild_typedAcceptanceMode_passesThrough() {
        let modes: [AcceptanceMode] = [.finalOnly, .afterEachRole, .afterEachArtifact]
        for mode in modes {
            let team = GeneratedTeamBuilder.buildTeam(from: makeConfig(
                roles: [makeRoleConfig()], acceptanceMode: mode
            ))
            XCTAssertEqual(team.settings.defaultAcceptanceMode, mode,
                          "Acceptance mode \(mode) should pass through")
        }
    }

    // MARK: - Convenience buildTeam wrapper

    func testBuildTeam_discardsWarnings() {
        // Convenience wrapper for callers that don't care about warnings (notably tests).
        // Same team produced as the BuildResult API.
        let config = makeConfig(roles: [makeRoleConfig(tools: ["read_file", "fake"])])
        let team = GeneratedTeamBuilder.buildTeam(from: config)
        let result = GeneratedTeamBuilder.build(from: config)
        XCTAssertEqual(team.roles.count, result.team.roles.count)
    }
}
