import XCTest
@testable import NanoTeams

/// A role can hold an MCP grant whose server no longer exists — the server was deleted in
/// Settings, or its slug was renamed, and the grant is now a name nothing can ever resolve.
///
/// A WARNING, and deliberately only at the SERVER level. The per-tool half is not decidable
/// from a catalogue: a tool missing from a disconnected server's listing is indistinguishable
/// from a closed Folio, and the role editor's own badge already reports per-tool liveness. A
/// dangling SLUG is the durable fault nothing else names.
final class TeamValidationMCPToolsTests: XCTestCase {

    private func makeTeam(roles: [TeamRoleDefinition]) -> Team {
        Team(name: "T", roles: roles, artifacts: [], settings: .default, graphLayout: .default)
    }

    private func makeRole(id: String, tools: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: id.capitalized, prompt: "p", toolIDs: tools,
            usePlanningPhase: false, dependencies: RoleDependencies(),
            attachedSkillIDs: [], isSystemRole: false, systemRoleID: nil)
    }

    private let folioGrant = MCPToolNaming.serverGrant(slug: "folio")

    // MARK: - The empty catalogue

    /// The same distinction the skills validator draws: an EMPTY set means "no server is
    /// configured, or the manager has not been built yet", not "every grant is dangling".
    /// Flagging here would put a row under every MCP-granted role of a folder opened before
    /// the catalogue loads.
    func testEmptyCatalogue_isTreatedAsUnknown_notAsAllDangling() {
        let team = makeTeam(roles: [makeRole(id: "eng", tools: ["mcp__folio__get_screenshot"])])

        XCTAssertTrue(TeamValidationService
            .validateMCPTools(team: team, knownMCPToolIDs: []).isEmpty)
    }

    // MARK: - What resolves

    func testAWholeServerGrantOfAConfiguredServerIsAccepted() {
        let team = makeTeam(roles: [makeRole(id: "eng", tools: [folioGrant])])

        XCTAssertTrue(TeamValidationService
            .validateMCPTools(team: team, knownMCPToolIDs: [folioGrant]).isEmpty)
    }

    func testANamedToolOfAConfiguredServerIsAccepted() {
        let team = makeTeam(roles: [makeRole(id: "eng", tools: ["mcp__folio__get_screenshot"])])

        XCTAssertTrue(TeamValidationService.validateMCPTools(
            team: team,
            knownMCPToolIDs: [folioGrant, "mcp__folio__get_screenshot"]).isEmpty)
    }

    /// The documented boundary. The server is configured but its catalogue is not in the set
    /// — it is switched off, or unreachable, or its tools are not reviewed yet. None of those
    /// is a configuration fault, and the badge already says the tool is not live.
    func testANamedToolIsAcceptedWhenOnlyItsServerIsKnown() {
        let team = makeTeam(roles: [makeRole(id: "eng", tools: ["mcp__folio__get_screenshot"])])

        XCTAssertTrue(TeamValidationService
            .validateMCPTools(team: team, knownMCPToolIDs: [folioGrant]).isEmpty)
    }

    func testABuiltInToolIsNeverLookedAt() {
        let team = makeTeam(roles: [makeRole(id: "eng", tools: [ToolNames.readFile, ToolNames.search])])

        XCTAssertTrue(TeamValidationService
            .validateMCPTools(team: team, knownMCPToolIDs: [folioGrant]).isEmpty)
    }

    // MARK: - What is flagged

    func testAGrantWhoseServerIsGoneIsFlagged() {
        let team = makeTeam(roles: [makeRole(id: "eng", tools: ["mcp__trade_room__get_quote"])])

        let issues = TeamValidationService.validateMCPTools(
            team: team, knownMCPToolIDs: [folioGrant, "mcp__folio__get_screenshot"])

        XCTAssertEqual(issues, [.unknownMCPServer(roleID: "eng", toolID: "mcp__trade_room__get_quote")])
    }

    func testAWholeServerGrantOfAGoneServerIsFlagged() {
        let gone = MCPToolNaming.serverGrant(slug: "trade_room")
        let team = makeTeam(roles: [makeRole(id: "eng", tools: [gone])])

        XCTAssertEqual(
            TeamValidationService.validateMCPTools(team: team, knownMCPToolIDs: [folioGrant]),
            [.unknownMCPServer(roleID: "eng", toolID: gone)])
    }

    /// A name that wears the prefix but carries no legal slug resolves to nothing at all —
    /// which is the same dangling grant, reached through a hand-edited team file.
    func testAnMCPNameWithNoLegalSlugIsFlagged() {
        let malformed = "mcp__NotASlug__x"
        let team = makeTeam(roles: [makeRole(id: "eng", tools: [malformed])])

        XCTAssertEqual(
            TeamValidationService.validateMCPTools(team: team, knownMCPToolIDs: [folioGrant]),
            [.unknownMCPServer(roleID: "eng", toolID: malformed)])
    }

    /// Per ROLE, not per team: two roles holding the same dead grant are two rows, because
    /// the repair is made in each role's Tools tab.
    func testTwoRolesHoldingTheSameDeadGrantAreTwoIssues() {
        let dead = "mcp__trade_room__get_quote"
        let team = makeTeam(roles: [
            makeRole(id: "eng", tools: [dead]),
            makeRole(id: "pm", tools: [dead]),
        ])

        XCTAssertEqual(TeamValidationService.validateMCPTools(
            team: team, knownMCPToolIDs: [folioGrant]).count, 2)
    }

    /// Every dead grant of ONE role is its own row — collapsing them would hide how much of
    /// the role's toolset is gone.
    func testEveryDeadGrantOfOneRoleIsItsOwnIssue() {
        let team = makeTeam(roles: [makeRole(id: "eng", tools: [
            "mcp__trade_room__get_quote", "mcp__trade_room__place_order", folioGrant,
        ])])

        XCTAssertEqual(TeamValidationService.validateMCPTools(
            team: team, knownMCPToolIDs: [folioGrant]).count, 2)
    }

    // MARK: - Severity and message

    func testItNeverErrors() {
        XCTAssertFalse(
            TeamValidationService.ValidationError
                .unknownMCPServer(roleID: "eng", toolID: "mcp__gone__x").isError)
    }

    func testTheMessageNamesTheRoleTheGrantAndTheRepair() {
        let team = makeTeam(roles: [makeRole(id: "eng", tools: [])])
        let message = TeamValidationService.ValidationError
            .unknownMCPServer(roleID: "eng", toolID: "mcp__gone__x")
            .displayMessage(in: team)

        XCTAssertTrue(message.contains("Eng"), message)
        XCTAssertTrue(message.contains("mcp__gone__x"), message)
        XCTAssertTrue(message.contains("MCP Servers"), message)
    }

    /// A grant left behind by a DELETED role still has to read as something: the raw id,
    /// never a blank.
    func testAnUnresolvableRoleIDFallsBackToTheRawID() {
        let team = makeTeam(roles: [])
        let message = TeamValidationService.ValidationError
            .unknownMCPServer(roleID: "ghost", toolID: "mcp__gone__x")
            .displayMessage(in: team)

        XCTAssertTrue(message.contains("ghost"), message)
    }
}
