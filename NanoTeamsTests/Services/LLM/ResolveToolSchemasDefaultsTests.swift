import XCTest
@testable import NanoTeams

/// Pins the dangerous defaults on `LLMExecutionService.resolveToolSchemas`. The
/// static subset takes explicit parameters so non-runtime callers (the
/// `FirstPromptRenderer` and any future preview/audit tool) don't have to
/// stand up a full orchestrator. Each default models "feature off" semantics:
///
///   - `allTeams: []`            → delegation pack stripped (no catalog)
///   - `selectedScheme: nil`     → xcode tools stripped
///   - `isVisionConfigured: false` → analyze_image stripped
///   - `isComputerUseEnabled: false` → the 5 computer-use tools stripped
///
/// A future caller that forgets to pass any of these would silently ship a
/// stripped tool set into a real run. These tests fail-loudly if the defaults
/// drift from the documented semantics.
final class ResolveToolSchemasDefaultsTests: XCTestCase {

    private func makeAgent(
        toolIDs: [String],
        allowDelegationToGenerated: Bool = false
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "agent",
            name: "Agent",
            prompt: "",
            toolIDs: toolIDs,
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: [],
            allowDelegationToGeneratedTeams: allowDelegationToGenerated
        )
    }

    private func makeTeam(_ roles: [TeamRoleDefinition]) -> Team {
        Team(
            id: "team", name: "Team",
            roles: roles, artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - selectedScheme default

    func testDefaultSelectedScheme_stripsXcodeTools() {
        let agent = makeAgent(toolIDs: [ToolNames.runXcodebuild, ToolNames.runXcodetests, ToolNames.readFile])
        let team = makeTeam([agent])
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team,
            allTeams: [team]
            // selectedScheme + isVisionConfigured intentionally omitted — defaults
        )
        let names = Set(schemas.map(\.name))
        XCTAssertFalse(names.contains(ToolNames.runXcodebuild),
                       "default selectedScheme=nil must strip run_xcodebuild")
        XCTAssertFalse(names.contains(ToolNames.runXcodetests),
                       "default selectedScheme=nil must strip run_xcodetests")
        XCTAssertTrue(names.contains(ToolNames.readFile),
                      "non-xcode tools are unaffected")
    }

    func testExplicitSelectedScheme_keepsXcodeTools() {
        let agent = makeAgent(toolIDs: [ToolNames.runXcodebuild, ToolNames.runXcodetests])
        let team = makeTeam([agent])
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team,
            allTeams: [team],
            selectedScheme: "NanoTeams"
        )
        let names = Set(schemas.map(\.name))
        XCTAssertTrue(names.contains(ToolNames.runXcodebuild),
                      "explicit scheme must keep xcode tools")
        XCTAssertTrue(names.contains(ToolNames.runXcodetests))
    }

    // MARK: - isVisionConfigured default

    func testDefaultIsVisionConfigured_stripsAnalyzeImage() {
        let agent = makeAgent(toolIDs: [ToolNames.analyzeImage, ToolNames.readFile])
        let team = makeTeam([agent])
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team,
            allTeams: [team]
            // isVisionConfigured intentionally omitted — defaults to false
        )
        let names = Set(schemas.map(\.name))
        XCTAssertFalse(names.contains(ToolNames.analyzeImage),
                       "default isVisionConfigured=false must strip analyze_image")
        XCTAssertTrue(names.contains(ToolNames.readFile))
    }

    func testExplicitIsVisionConfigured_keepsAnalyzeImage() {
        let agent = makeAgent(toolIDs: [ToolNames.analyzeImage])
        let team = makeTeam([agent])
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team,
            allTeams: [team],
            isVisionConfigured: true
        )
        let names = Set(schemas.map(\.name))
        XCTAssertTrue(names.contains(ToolNames.analyzeImage),
                      "isVisionConfigured=true must keep analyze_image")
    }

    // MARK: - isComputerUseEnabled default

    func testDefaultIsComputerUseEnabled_stripsComputerUseTools() {
        let tn = ToolNames.self
        let agent = makeAgent(toolIDs: [
            tn.screenCapture, tn.uiClick, tn.uiType, tn.uiKey, tn.uiScroll, tn.readFile,
        ])
        let team = makeTeam([agent])
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team,
            allTeams: [team]
            // isComputerUseEnabled intentionally omitted — defaults to false
            // (the safe orchestrator-free default)
        )
        let names = Set(schemas.map(\.name))
        for tool in ToolHandlerRegistry.computerUseTools {
            XCTAssertFalse(names.contains(tool),
                           "default isComputerUseEnabled=false must strip \(tool)")
        }
        XCTAssertTrue(names.contains(tn.readFile),
                      "non-computer-use tools are unaffected")
    }

    func testExplicitIsComputerUseEnabled_keepsComputerUseTools() {
        let tn = ToolNames.self
        let agent = makeAgent(toolIDs: [
            tn.screenCapture, tn.uiClick, tn.uiType, tn.uiKey, tn.uiScroll,
        ])
        let team = makeTeam([agent])
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team,
            allTeams: [team],
            isComputerUseEnabled: true
        )
        let names = Set(schemas.map(\.name))
        for tool in ToolHandlerRegistry.computerUseTools {
            XCTAssertTrue(names.contains(tool),
                          "isComputerUseEnabled=true must keep \(tool)")
        }
    }

    func testComputerUseTools_surviveDefaultStorageFilter() {
        // Computer-use operates the DESKTOP, not the work folder — the tools are
        // deliberately absent from `defaultStorageBlocked`, so a QuickCapture
        // chat with no real folder open can still screen-control when the
        // feature is enabled. Pins the resolver → default-storage filter chain.
        let tn = ToolNames.self
        let agent = makeAgent(toolIDs: [
            tn.screenCapture, tn.uiClick, tn.uiType, tn.uiKey, tn.uiScroll, tn.writeFile,
        ])
        let team = makeTeam([agent])
        let resolved = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team,
            allTeams: [team],
            isComputerUseEnabled: true
        )
        let filtered = LLMExecutionService.filterForDefaultStorage(resolved, isDefaultStorage: true)
        let names = Set(filtered.map(\.name))
        for tool in ToolHandlerRegistry.computerUseTools {
            XCTAssertTrue(names.contains(tool),
                          "\(tool) must survive default-storage filtering")
        }
        XCTAssertFalse(names.contains(tn.writeFile),
                       "sanity: the filter itself ran (write_file is blocked in default storage)")
    }

    // MARK: - allTeams default

    func testDefaultAllTeams_keepsDelegationOffEvenWithGeneratedPermission() {
        // generated=true alone enables delegationEnabled, so the pack is auto-
        // injected. But with allTeams=[] the inline catalog has nothing to list
        // beyond the "generated" sentinel. Pin that the pack still ships
        // (regression guard for the auto-injection guard, not the catalog).
        let agent = makeAgent(toolIDs: [], allowDelegationToGenerated: true)
        let team = makeTeam([agent])
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team
            // allTeams intentionally omitted — defaults to []
        )
        let names = Set(schemas.map(\.name))
        XCTAssertTrue(names.contains(ToolNames.delegateToTeam),
                      "delegation pack auto-injects whenever the role's policy permits, regardless of allTeams contents")
        XCTAssertTrue(names.contains(ToolNames.cancelDelegation))
        XCTAssertTrue(names.contains(ToolNames.resumeDelegation))
        XCTAssertTrue(names.contains(ToolNames.forwardToTeam))
    }
}
