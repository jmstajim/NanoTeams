import XCTest

@testable import NanoTeams

/// Step 9 of `resolveToolSchemasCore`: what a role's `mcp__…` grants expand to, where the
/// result sits in the list, and what never reaches it.
///
/// The property this suite guards hardest is the one nothing else can: an empty catalogue
/// must leave the resolver's output BYTE-identical to what it produced before MCP existed.
/// Every role in every bundled team resolves through this function on every step, so a
/// reordering here is a prompt-prefix cache miss on the first request of every run.
@MainActor
final class MCPToolResolutionTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    private static let folioID = UUID()
    private static let investID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func entry(
        slug: String,
        tool: String,
        serverID: UUID,
        runsUnattended: Bool = false
    ) throws -> MCPToolsSnapshot.Entry {
        try MCPToolsSnapshotTests.makeEntry(
            slug: slug, tool: tool, serverID: serverID, runsUnattended: runsUnattended)
    }

    /// The two-server catalogue the rest of the suite narrows: Folio with two tools, Trade-Room
    /// with one, deliberately built OUT of sorted order so a test asserting order is asserting
    /// the snapshot's sort rather than the literal.
    private func catalogue(humanPresent: Bool = true) throws -> MCPResolvedTools {
        MCPToolsSnapshot(entries: [
            try entry(slug: "trade_room", tool: "get_orders", serverID: Self.investID),
            try entry(slug: "folio", tool: "get_screenshot", serverID: Self.folioID),
            try entry(slug: "folio", tool: "get_metadata", serverID: Self.folioID, runsUnattended: true),
        ]).resolved(humanPresent: humanPresent)
    }

    private func role(id: String = "engineer", toolIDs: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: "Engineer",
            prompt: "p",
            toolIDs: toolIDs,
            usePlanningPhase: false,
            dependencies: RoleDependencies())
    }

    private func team(_ role: TeamRoleDefinition) -> Team {
        Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout())
    }

    private func resolve(
        _ role: TeamRoleDefinition, mcpTools: MCPResolvedTools = .empty
    ) -> [ToolSchema] {
        LLMExecutionService.resolveToolSchemas(
            forDefinition: role,
            team: team(role),
            approval: .available,
            mcpTools: mcpTools)
    }

    // MARK: - The empty catalogue changes nothing

    /// The whole feature has to be invisible to a run with no servers. Not "the same set" —
    /// the same ARRAY, in the same order, with the same descriptions.
    func testAnEmptyCatalogueLeavesTheResolutionByteIdentical() throws {
        let subject = role(toolIDs: ["read_file", "list_files", "write_file"])
        let withoutParameter = LLMExecutionService.resolveToolSchemas(
            forDefinition: subject, team: team(subject), approval: .available)
        let withEmpty = resolve(subject, mcpTools: .empty)
        XCTAssertEqual(withoutParameter, withEmpty)
    }

    /// A catalogue the role was granted NOTHING from is the same case one step further out:
    /// servers exist, this role holds no grant, its prompt must not move.
    func testAConnectedServerThisRoleHoldsNoGrantForChangesNothing() throws {
        let subject = role(toolIDs: ["read_file", "list_files"])
        let baseline = resolve(subject, mcpTools: .empty)
        XCTAssertEqual(resolve(subject, mcpTools: try catalogue()), baseline)
    }

    // MARK: - Grants

    func testAnExactGrantBringsThatOneTool() throws {
        let subject = role(toolIDs: ["read_file", "mcp__folio__get_metadata"])
        let names = resolve(subject, mcpTools: try catalogue()).map(\.name)
        XCTAssertEqual(names.filter { MCPToolNaming.isMCPName($0) }, ["mcp__folio__get_metadata"])
    }

    func testAWholeServerGrantBringsEveryApprovedToolOfThatServer() throws {
        let subject = role(toolIDs: ["read_file", "mcp__folio"])
        let names = resolve(subject, mcpTools: try catalogue()).map(\.name)
        XCTAssertEqual(
            names.filter { MCPToolNaming.isMCPName($0) },
            ["mcp__folio__get_metadata", "mcp__folio__get_screenshot"])
    }

    /// Namespacing is the whole defence against one server shadowing another's tool, so a
    /// grant must never reach across the boundary it draws.
    func testAGrantForOneServerBringsNothingFromAnother() throws {
        let subject = role(toolIDs: ["mcp__folio"])
        let names = resolve(subject, mcpTools: try catalogue()).map(\.name)
        XCTAssertFalse(names.contains { $0.hasPrefix("mcp__trade_room") })
    }

    func testBothKindsOfGrantCanBeHeldAtOnce() throws {
        let subject = role(toolIDs: ["mcp__folio", "mcp__trade_room__get_orders"])
        let names = resolve(subject, mcpTools: try catalogue()).map(\.name)
        XCTAssertEqual(
            names.filter { MCPToolNaming.isMCPName($0) },
            ["mcp__folio__get_metadata", "mcp__folio__get_screenshot", "mcp__trade_room__get_orders"])
    }

    /// A stale `toolIDs` entry — a server the user deleted, a tool the server stopped
    /// publishing — resolves to nothing rather than to a schema the runtime cannot honour.
    func testAGrantWithNoLiveToolBehindItShipsNothing() throws {
        let subject = role(toolIDs: ["read_file", "mcp__ghost__vanished", "mcp__ghost"])
        XCTAssertEqual(resolve(subject, mcpTools: try catalogue()), resolve(subject))
    }

    /// `mcp__` alone is not a name and not a slug; the parser must not read it as a grant for
    /// a server called "".
    func testAMalformedGrantIsIgnored() throws {
        let subject = role(toolIDs: ["mcp__", "mcp____get_metadata"])
        XCTAssertTrue(resolve(subject, mcpTools: try catalogue()).isEmpty)
    }

    // MARK: - Order

    func testMCPToolsComeAfterEveryBuiltInTool() throws {
        let subject = role(toolIDs: ["mcp__folio", "read_file", "list_files"])
        let names = resolve(subject, mcpTools: try catalogue()).map(\.name)
        let firstMCP = try XCTUnwrap(names.firstIndex { MCPToolNaming.isMCPName($0) })
        XCTAssertTrue(
            names[firstMCP...].allSatisfy { MCPToolNaming.isMCPName($0) },
            "a built-in after the MCP block would shift on every catalogue change")
    }

    /// `toolIDs` is a user-editable array with no order guarantee, and the prompt is a cache
    /// prefix — so the ORDER has to come from the catalogue, not from the grant list.
    func testGrantOrderDoesNotReachTheSchemaOrder() throws {
        let catalogue = try catalogue()
        let forward = resolve(
            role(toolIDs: ["mcp__folio__get_screenshot", "mcp__trade_room__get_orders", "mcp__folio__get_metadata"]),
            mcpTools: catalogue)
        let reversed = resolve(
            role(toolIDs: ["mcp__folio__get_metadata", "mcp__trade_room__get_orders", "mcp__folio__get_screenshot"]),
            mcpTools: catalogue)
        XCTAssertEqual(forward.map(\.name), reversed.map(\.name))
        XCTAssertEqual(
            forward.map(\.name),
            ["mcp__folio__get_metadata", "mcp__folio__get_screenshot", "mcp__trade_room__get_orders"])
    }

    // MARK: - What the schema carries

    func testTheSchemaCarriesTheDescriptorNotTheServersOwnName() throws {
        let subject = role(toolIDs: ["mcp__folio__get_metadata"])
        let schema = try XCTUnwrap(resolve(subject, mcpTools: try catalogue()).first)
        XCTAssertEqual(schema.name, "mcp__folio__get_metadata")
        XCTAssertEqual(schema.description, "Reads metadata.")
        XCTAssertEqual(schema.parameters, JSONSchema(type: "object"))
    }

    /// `PromptFormatConventionsTests` pins every rendered tool name to `[a-z0-9_]+`; a slug or
    /// a folded tool name that broke it would fail far from here.
    func testEveryShippedNameIsSpellableInThePrompt() throws {
        let subject = role(toolIDs: ["mcp__folio", "mcp__trade_room__get_orders"])
        for name in resolve(subject, mcpTools: try catalogue()).map(\.name)
            where MCPToolNaming.isMCPName(name) {
            XCTAssertTrue(
                name.allSatisfy { $0.isNumber || $0 == "_" || ($0.isLetter && $0.isLowercase && $0.isASCII) },
                name)
        }
    }

    // MARK: - Nobody to approve

    /// With no human, a tool whose every call would be held is absent from the schema rather
    /// than advertised — the model would otherwise spend a turn per iteration being refused.
    func testWithoutAHumanOnlyTheToolsThatRunUnattendedShip() throws {
        let subject = role(toolIDs: ["mcp__folio", "mcp__trade_room__get_orders"])
        let names = resolve(subject, mcpTools: try catalogue(humanPresent: false)).map(\.name)
        XCTAssertEqual(names.filter { MCPToolNaming.isMCPName($0) }, ["mcp__folio__get_metadata"])
    }

    func testAWithheldToolIsNotSimplyDroppedFromTheRun() throws {
        let withheld = try catalogue(humanPresent: false).withheldNames
        XCTAssertEqual(withheld, ["mcp__folio__get_screenshot", "mcp__trade_room__get_orders"])
    }

    // MARK: - Through the delegate

    /// The runtime path: the service reads the snapshot off the delegate and splits it with
    /// the caller's `humanPresent`, so a step gets the same answer the static resolver gives.
    func testTheServiceReadsTheCatalogueOffTheDelegate() throws {
        let subject = role(toolIDs: ["mcp__folio__get_metadata"])
        mockDelegate.mcpTools = MCPToolsSnapshot(entries: [
            try entry(slug: "folio", tool: "get_metadata", serverID: Self.folioID, runsUnattended: true),
        ])
        let names = service.toolSchemas(forDefinition: subject, team: team(subject), humanPresent: true)
            .map(\.name)
        XCTAssertEqual(names, ["mcp__folio__get_metadata"])
    }

    func testADelegateWithNoManagerResolvesToTheEmptyCatalogue() {
        let subject = role(toolIDs: ["read_file", "mcp__folio__get_metadata"])
        XCTAssertNil(mockDelegate.mcpTools)
        let names = service.toolSchemas(forDefinition: subject, team: team(subject), humanPresent: true)
            .map(\.name)
        XCTAssertEqual(names, ["read_file"])
    }

    func testTheServiceHonoursTheCallersHumanPresentAnswer() throws {
        let subject = role(toolIDs: ["mcp__folio"])
        mockDelegate.mcpTools = MCPToolsSnapshot(entries: [
            try entry(slug: "folio", tool: "get_metadata", serverID: Self.folioID, runsUnattended: true),
            try entry(slug: "folio", tool: "get_screenshot", serverID: Self.folioID),
        ])
        let unattended = service.toolSchemas(
            forDefinition: subject, team: team(subject), humanPresent: false).map(\.name)
        XCTAssertEqual(unattended, ["mcp__folio__get_metadata"])
    }

    // MARK: - The storage filters

    /// Both later stages remove NAMES from a registry set, and no `mcp__…` name is in one —
    /// so an external server survives default storage and a folder with no git repository.
    /// Asserted rather than assumed: a future filter written as an allowlist would silently
    /// delete the whole family.
    func testMCPToolsSurviveDefaultStorageAndAMissingGitRepository() throws {
        let subject = role(toolIDs: ["mcp__folio", "write_file", "git_status"])
        let shipped = EffectiveToolset.resolve(
            role: subject,
            team: team(subject),
            allTeams: [],
            storage: .defaultStorage,
            selectedScheme: nil,
            isVisionConfigured: false,
            approval: .available,
            autovisorTeamPolicy: .unrestricted,
            mcpTools: try catalogue()).map(\.name)
        XCTAssertFalse(shipped.contains("write_file"), "default storage strips the writer")
        XCTAssertEqual(
            shipped.filter { MCPToolNaming.isMCPName($0) },
            ["mcp__folio__get_metadata", "mcp__folio__get_screenshot"])
    }

    // MARK: - The role badge

    /// An `mcp__…` grant has no handler by construction, so the badge's "not installed" class
    /// — the one class that means a real problem — must never claim it.
    func testTheBadgeDoesNotCallAnUnreachableGrantNotInstalled() {
        let subject = role(toolIDs: ["read_file", "mcp__folio__get_metadata"])
        let model = RoleToolBadgePolicy.model(
            role: subject,
            team: team(subject),
            allTeams: [],
            storage: .defaultStorage,
            selectedScheme: nil,
            isVisionConfigured: false,
            approval: .available,
            autovisorTeamPolicy: .unrestricted)
        XCTAssertEqual(model.notInstalled, [])
        XCTAssertEqual(model.policyBlocked, [])
        XCTAssertEqual(model.unavailableHere[.mcpToolLive], ["mcp__folio__get_metadata"])
    }

    func testTheBadgeCountsAShippedMCPToolAsConfigured() throws {
        let subject = role(toolIDs: ["mcp__folio__get_metadata"])
        let model = badge(for: subject, mcpGrants: try grantCatalogue())
        XCTAssertEqual(model.effective, ["mcp__folio__get_metadata"])
        XCTAssertEqual(model.configured, ["mcp__folio__get_metadata"])
        XCTAssertEqual(model.autoInjected, [])
        XCTAssertTrue(model.unavailableHere.isEmpty)
    }

    /// Every repair the badge names is a place in the app, and each is a different place —
    /// that is the whole reason the residual case was split. A tool its connected server does
    /// not offer is the one repaired HERE, in the role (uncheck it), and says so instead.
    func testEveryMCPHintNamesTheServerList() {
        for requirement: ToolAvailabilityRequirement in [
            .mcpServerDisabled, .mcpServerOffInThisFolder, .mcpServerNeedsToken, .mcpServerDisconnected,
            .mcpToolUnreviewed, .mcpToolRefused, .mcpServerToolsRefused, .mcpToolNotOfferable,
            .mcpServerToolsNotOfferable, .mcpToolLive,
        ] {
            XCTAssertTrue(requirement.unmetHint.contains("Settings → MCP Servers"), "\(requirement)")
        }
        XCTAssertTrue(ToolAvailabilityRequirement.mcpToolNotOffered.unmetHint.hasSuffix("uncheck it here"))
        // Nothing to set anywhere: a server nothing runs because no folder is served starts
        // when one opens, and the words say so rather than sending the person to a switch.
        XCTAssertEqual(ToolAvailabilityRequirement.mcpServerNotRunning.unmetHint,
                       "Its MCP server is not running — it starts when a work folder opens")
    }

    /// With no catalogue every grant is unknown — which is the honest reading for a surface
    /// that was handed nothing, and the answer every pre-MCP call site still gets.
    func testWithNoCatalogueAGrantIsTheResidualCase() {
        XCTAssertEqual(
            ToolAvailabilityRequirement.governing(
                "mcp__folio__get_metadata", isDefaultStorage: true, approval: .available),
            .mcpToolLive)
    }

    // MARK: - The badge names WHICH repair

    /// The states a person can act on, each filed under its own group so the tooltip says which
    /// repair to make — a tool the connected server does not publish is the role's to drop, and
    /// only a grant naming no configured server at all is the residual.
    func testTheBadgeFilesEachGrantUnderItsOwnRepair() throws {
        let subject = role(toolIDs: [
            "mcp__folio__get_design_context", // unreviewed on a connected server
            "mcp__folio__get_variable_defs",  // connected, not published at all
            "mcp__trade_room__get_orders",      // server switched off
            "mcp__gone__x",                   // no such server
        ])
        let model = badge(for: subject, mcpGrants: try grantCatalogue())

        XCTAssertEqual(
            model.unavailableHere[.mcpToolUnreviewed], ["mcp__folio__get_design_context"])
        XCTAssertEqual(model.unavailableHere[.mcpServerDisabled], ["mcp__trade_room__get_orders"])
        XCTAssertEqual(model.unavailableHere[.mcpToolNotOffered], ["mcp__folio__get_variable_defs"])
        XCTAssertEqual(model.unavailableHere[.mcpToolLive], ["mcp__gone__x"])
        XCTAssertEqual(model.notInstalled, [])
    }

    func testAnUnreachableServerIsNamedAsUnreachableRatherThanAsAMissingTool() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(
                slug: "folio", id: Self.folioID, status: .failed(reason: "refused"),
                tools: [try MCPGrantCatalogueTests.makeTool(slug: "folio", tool: "get_metadata")]),
        ])
        let subject = role(toolIDs: ["mcp__folio__get_metadata"])

        XCTAssertEqual(
            badge(for: subject, mcpGrants: catalogue).unavailableHere[.mcpServerDisconnected],
            ["mcp__folio__get_metadata"])
    }

    /// A connected server re-reading its tool list is not "not connected": the badge files it
    /// under its own reason, whose text says the list is being read again — the Settings row
    /// beside it says Connected, and a badge sending the person to a connection that is fine
    /// is the contradiction this case exists to end.
    ///
    /// RED until 2026-09-24 (group C): filed under `.mcpServerDisconnected`.
    func testAServerRereadingItsToolsIsNamedAsSuchRatherThanAsDisconnected() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(
                slug: "folio", id: Self.folioID, status: .connected(era: .modern),
                tools: [try MCPGrantCatalogueTests.makeTool(slug: "folio", tool: "get_metadata")],
                catalogueUnverified: true),
        ])
        let subject = role(toolIDs: ["mcp__folio__get_metadata", "mcp__folio"])
        let model = badge(for: subject, mcpGrants: catalogue)

        XCTAssertEqual(
            model.unavailableHere[.mcpToolsBeingReread], ["mcp__folio", "mcp__folio__get_metadata"])
        XCTAssertNil(model.unavailableHere[.mcpServerDisconnected])
        XCTAssertEqual(ToolAvailabilityRequirement.forMCPGrant(.catalogueBeingReread), .mcpToolsBeingReread)
        XCTAssertEqual(
            ToolAvailabilityRequirement.mcpToolsBeingReread.unmetHint,
            "Its MCP server's tool list is being re-read — withheld until the read succeeds "
                + "(see Settings → MCP Servers)")
        XCTAssertNil(ToolAvailabilityRequirement.mcpToolsBeingReread.metHint)
        XCTAssertTrue(ToolAvailabilityRequirement.allCases.contains(.mcpToolsBeingReread),
                      "the tooltip iterates allCases — a case missing there never renders")
    }

    // MARK: - Badge fixtures

    private func badge(
        for subject: TeamRoleDefinition,
        mcpGrants: MCPGrantCatalogue = .empty
    ) -> RoleToolBadgePolicy.Model {
        RoleToolBadgePolicy.model(
            role: subject,
            team: team(subject),
            allTeams: [],
            storage: .defaultStorage,
            selectedScheme: nil,
            isVisionConfigured: false,
            approval: .available,
            autovisorTeamPolicy: .unrestricted,
            mcpGrants: mcpGrants)
    }

    /// The same two servers as `catalogue()`, in the shape the editor reads: Folio connected
    /// with `get_metadata` approved, Trade-Room configured and switched off.
    private func grantCatalogue() throws -> MCPGrantCatalogue {
        MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(
                slug: "trade_room", id: Self.investID, status: .disabled, standing: .switchedOff),
            try MCPGrantCatalogueTests.makeServer(slug: "folio", id: Self.folioID, tools: [
                try MCPGrantCatalogueTests.makeTool(slug: "folio", tool: "get_metadata"),
                try MCPGrantCatalogueTests.makeTool(
                    slug: "folio", tool: "get_design_context", pinState: .new),
            ]),
        ])
    }
}
