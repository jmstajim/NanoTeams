import XCTest
@testable import NanoTeams

/// Verifies `GeneratedTeamBuilder.applyForcedDefaults(to:supervisorMode:acceptanceMode:)`:
/// `nil` arguments leave the team untouched; non-nil arguments pin the team settings
/// to the user-chosen values, overriding whatever the LLM emitted.
@MainActor
final class GeneratedTeamBuilderForcedDefaultsTests: XCTestCase {

    // MARK: - Helpers

    private func makeConfig(
        supervisorMode: SupervisorMode?,
        acceptanceMode: AcceptanceMode?
    ) -> GeneratedTeamConfig {
        GeneratedTeamConfig(
            name: "Sample Team",
            description: "desc",
            supervisorMode: supervisorMode,
            acceptanceMode: acceptanceMode,
            roles: [
                GeneratedTeamConfig.RoleConfig(
                    name: "Engineer",
                    prompt: "do the work",
                    producesArtifacts: ["Engineering Notes"],
                    requiresArtifacts: ["Supervisor Task"]
                )
            ],
            artifacts: [
                GeneratedTeamConfig.ArtifactConfig(
                    name: "Engineering Notes", description: "out", icon: nil
                )
            ],
            supervisorRequires: ["Engineering Notes"]
        )
    }

    // MARK: - No-op path

    func testApplyForcedDefaults_bothNil_leavesTeamUntouched() {
        let config = makeConfig(supervisorMode: .autonomous, acceptanceMode: .afterEachArtifact)
        let original = GeneratedTeamBuilder.build(from: config)

        let result = GeneratedTeamBuilder.applyForcedDefaults(
            to: original, supervisorMode: nil, acceptanceMode: nil
        )

        XCTAssertEqual(result.team.settings.supervisorMode, .autonomous)
        XCTAssertEqual(result.team.settings.defaultAcceptanceMode, .afterEachArtifact)
        XCTAssertEqual(result.warnings, original.warnings)
    }

    // MARK: - Individual overrides

    func testApplyForcedDefaults_overridesSupervisorModeOnly() {
        // LLM chose .autonomous; user forces .manual — acceptance mode must be preserved.
        let config = makeConfig(supervisorMode: .autonomous, acceptanceMode: .afterEachArtifact)
        let original = GeneratedTeamBuilder.build(from: config)

        let result = GeneratedTeamBuilder.applyForcedDefaults(
            to: original, supervisorMode: .manual, acceptanceMode: nil
        )

        XCTAssertEqual(result.team.settings.supervisorMode, .manual)
        XCTAssertEqual(result.team.settings.defaultAcceptanceMode, .afterEachArtifact)
    }

    func testApplyForcedDefaults_overridesAcceptanceModeOnly() {
        // LLM chose .afterEachArtifact; user forces .finalOnly — supervisor mode preserved.
        let config = makeConfig(supervisorMode: .autonomous, acceptanceMode: .afterEachArtifact)
        let original = GeneratedTeamBuilder.build(from: config)

        let result = GeneratedTeamBuilder.applyForcedDefaults(
            to: original, supervisorMode: nil, acceptanceMode: .finalOnly
        )

        XCTAssertEqual(result.team.settings.supervisorMode, .autonomous)
        XCTAssertEqual(result.team.settings.defaultAcceptanceMode, .finalOnly)
    }

    func testApplyForcedDefaults_overridesBoth() {
        let config = makeConfig(supervisorMode: .autonomous, acceptanceMode: .afterEachArtifact)
        let original = GeneratedTeamBuilder.build(from: config)

        let result = GeneratedTeamBuilder.applyForcedDefaults(
            to: original, supervisorMode: .manual, acceptanceMode: .finalOnly
        )

        XCTAssertEqual(result.team.settings.supervisorMode, .manual)
        XCTAssertEqual(result.team.settings.defaultAcceptanceMode, .finalOnly)
    }

    // MARK: - Builder-fallback scenario

    func testApplyForcedDefaults_overridesBuilderFallback() {
        // LLM omitted both fields — builder fallback is (.manual, .finalOnly).
        // User forces non-fallback values; both should take effect.
        let config = makeConfig(supervisorMode: nil, acceptanceMode: nil)
        let original = GeneratedTeamBuilder.build(from: config)
        XCTAssertEqual(original.team.settings.supervisorMode, .manual, "Builder fallback assumption")
        XCTAssertEqual(original.team.settings.defaultAcceptanceMode, .finalOnly, "Builder fallback assumption")

        let result = GeneratedTeamBuilder.applyForcedDefaults(
            to: original, supervisorMode: .autonomous, acceptanceMode: .afterEachRole
        )

        XCTAssertEqual(result.team.settings.supervisorMode, .autonomous)
        XCTAssertEqual(result.team.settings.defaultAcceptanceMode, .afterEachRole)
    }

    // MARK: - Role-eligible tools

    /// A generated role may hold only what a TEAM ROLE may hold. The ten Autovisor management
    /// tools define the manager — their signals are interpreted by its step loop alone, and
    /// `set_work_folder_context` rewrites what every role of every task reads — so a config
    /// naming one is corrected with a warning, exactly like an unknown name. Until
    /// 2026-09-06 the whole registry was valid here.
    func testBuild_dropsManagerOnlyAndDelegationTools_withAWarning() {
        let config = GeneratedTeamConfig(
            name: "Reach Team",
            description: "d",
            roles: [
                GeneratedTeamConfig.RoleConfig(
                    name: "Engineer",
                    prompt: "p",
                    producesArtifacts: ["Code"],
                    requiresArtifacts: ["Supervisor Task"],
                    tools: [ToolNames.readFile, ToolNames.controlTask, ToolNames.setWorkFolderContext,
                            ToolNames.delegateToTeam]
                )
            ],
            artifacts: [GeneratedTeamConfig.ArtifactConfig(name: "Code", description: "x", icon: nil)],
            supervisorRequires: ["Code"]
        )
        let result = GeneratedTeamBuilder.build(from: config)

        let engineer = result.team.roles.first { $0.name == "Engineer" }
        XCTAssertEqual(engineer?.toolIDs, [ToolNames.readFile])
        let warning = result.warnings.first { $0.contains("dropped unknown tool") } ?? ""
        for tool in [ToolNames.controlTask, ToolNames.setWorkFolderContext, ToolNames.delegateToTeam] {
            XCTAssertTrue(warning.contains(tool), "the warning names \(tool): \(result.warnings)")
        }
        XCTAssertFalse(GeneratedTeamBuilder.roleEligibleToolNames.contains(ToolNames.createTeam))
        XCTAssertTrue(GeneratedTeamBuilder.roleEligibleToolNames.contains(ToolNames.bash))
    }

    // MARK: - Warnings preserved

    func testApplyForcedDefaults_preservesWarnings() {
        // Use a config that triggers a warning (unknown tool in role toolset).
        let config = GeneratedTeamConfig(
            name: "Warn Team",
            description: "d",
            roles: [
                GeneratedTeamConfig.RoleConfig(
                    name: "Engineer",
                    prompt: "p",
                    producesArtifacts: ["Code"],
                    requiresArtifacts: ["Supervisor Task"],
                    tools: ["nonexistent_tool"]
                )
            ],
            artifacts: [GeneratedTeamConfig.ArtifactConfig(name: "Code", description: "x", icon: nil)],
            supervisorRequires: ["Code"]
        )
        let original = GeneratedTeamBuilder.build(from: config)
        XCTAssertFalse(original.warnings.isEmpty, "Precondition: unknown tool should produce a warning")

        let result = GeneratedTeamBuilder.applyForcedDefaults(
            to: original, supervisorMode: .manual, acceptanceMode: nil
        )

        XCTAssertEqual(result.warnings, original.warnings, "applyForcedDefaults must not modify warnings")
    }
}
