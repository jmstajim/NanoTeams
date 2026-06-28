import XCTest

@testable import NanoTeams

/// Pins `ToolNames.allNames` to the full tool set so a newly-added tool constant
/// that's forgotten in `allNames` is caught — the flat-`create_artifact`
/// inference in the Harmony parser relies on `allNames` being complete to tell a
/// real tool (`update_scratchpad`) from an artifact name.
final class ToolNamesAllNamesTests: XCTestCase {

    func testAllNames_countMatchesToolCount() {
        // Mirror of DefaultToolSchemasTests.testDefaultToolsCountIs45.
        XCTAssertEqual(ToolNames.allNames.count, 45)
    }

    func testAllNames_containsRepresentativesFromEachCategory() {
        for name in [
            ToolNames.readFile, ToolNames.gitCommit, ToolNames.runXcodebuild,
            ToolNames.askSupervisor, ToolNames.updateScratchpad, ToolNames.askTeammate,
            ToolNames.createArtifact, ToolNames.analyzeImage, ToolNames.createTeam,
            ToolNames.delegateToTeam, ToolNames.waitForEvents,
        ] {
            XCTAssertTrue(ToolNames.allNames.contains(name), "allNames missing \(name)")
        }
    }

    func testAllNames_excludesArbitraryArtifactName() {
        XCTAssertFalse(ToolNames.allNames.contains("Production Readiness"))
        XCTAssertFalse(ToolNames.allNames.contains("Design Spec"))
    }
}
