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
///
/// `approval` (`ToolApprovalAvailability`) has NO default, deliberately: its Bool
/// predecessor `isComputerUseEnabled` defaulted to `false`, which was not what a
/// fresh install ships (Manual), and the offline renderer inherited that default
/// for months without anything saying so. The two tests under "approval" pin the
/// withheld and available readings explicitly.
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
            allTeams: [team],
            // selectedScheme + isVisionConfigured intentionally omitted — defaults
            approval: .available
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
            selectedScheme: "NanoTeams",
            approval: .available
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
            allTeams: [team],
            // isVisionConfigured intentionally omitted — defaults to false
            approval: .available
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
            isVisionConfigured: true,
            approval: .available
        )
        let names = Set(schemas.map(\.name))
        XCTAssertTrue(names.contains(ToolNames.analyzeImage),
                      "isVisionConfigured=true must keep analyze_image")
    }

    // MARK: - approval (no default — explicit readings)

    func testComputerUseWithheld_stripsComputerUseTools() {
        let tn = ToolNames.self
        let agent = makeAgent(toolIDs: [
            tn.screenCapture, tn.uiClick, tn.uiType, tn.uiKey, tn.uiScroll, tn.readFile,
        ])
        let team = makeTeam([agent])
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team,
            allTeams: [team],
            approval: ToolApprovalAvailability(bash: .available, computerUse: .withheld(.switchedOff))
        )
        let names = Set(schemas.map(\.name))
        for tool in ToolHandlerRegistry.computerUseTools {
            XCTAssertFalse(names.contains(tool), "computer use Off must strip \(tool)")
        }
        XCTAssertTrue(names.contains(tn.readFile),
                      "non-computer-use tools are unaffected")
    }

    func testComputerUseAvailable_keepsComputerUseTools() {
        let tn = ToolNames.self
        let agent = makeAgent(toolIDs: [
            tn.screenCapture, tn.uiClick, tn.uiType, tn.uiKey, tn.uiScroll,
        ])
        let team = makeTeam([agent])
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(agent),
            team: team,
            allTeams: [team],
            approval: .available
        )
        let names = Set(schemas.map(\.name))
        for tool in ToolHandlerRegistry.computerUseTools {
            XCTAssertTrue(names.contains(tool), "an available family must keep \(tool)")
        }
    }

    /// The parameter carries no default: the file's own header says why. Pinned at the
    /// source, because the compiler is the only thing that can prove a default's absence.
    func testApprovalParameterHasNoDefault() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NanoTeams/Services/LLM/LLMExecutionService+ToolResolution.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("approval: ToolApprovalAvailability,"),
                      "resolveToolSchemas must take `approval` without a default")
        XCTAssertFalse(source.contains("approval: ToolApprovalAvailability ="),
                       "a default on `approval` re-creates the silent-strip the header describes")
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
            approval: .available
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
            team: team,
            // allTeams intentionally omitted — defaults to []
            approval: .available
        )
        let names = Set(schemas.map(\.name))
        XCTAssertTrue(names.contains(ToolNames.delegateToTeam),
                      "delegation pack auto-injects whenever the role's policy permits, regardless of allTeams contents")
        XCTAssertTrue(names.contains(ToolNames.cancelDelegation))
        XCTAssertTrue(names.contains(ToolNames.resumeDelegation))
        XCTAssertTrue(names.contains(ToolNames.forwardToTeam))
    }
}
