import XCTest

@testable import NanoTeams

/// The catalogue a step freezes at entry, and the two ways it is narrowed afterwards: by what
/// a role was granted, and by whether anybody is there to approve a call.
final class MCPToolsSnapshotTests: XCTestCase {

    // MARK: - Fixtures

    private static let folioID = UUID()
    private static let investID = UUID()

    /// Shared with `MCPToolResolutionTests`, which needs the same fixture to drive the
    /// schema resolver — one builder so the two suites cannot disagree on what an entry is.
    static func makeEntry(
        slug: String,
        tool: String,
        serverID: UUID,
        approvalMode: MCPApprovalMode = .manual,
        serverTrusted: Bool = false,
        alwaysAllowed: Bool = false,
        runsUnattended: Bool = false
    ) throws -> MCPToolsSnapshot.Entry {
        let validSlug = try XCTUnwrap(MCPServerSlug(slug))
        let name = try XCTUnwrap(MCPToolNaming.modelFacingName(slug: slug, toolName: tool))
        return MCPToolsSnapshot.Entry(
            serverID: serverID,
            slug: validSlug,
            serverDisplayName: slug,
            approvalMode: approvalMode,
            serverTrusted: serverTrusted,
            alwaysAllowed: alwaysAllowed,
            runsUnattended: runsUnattended,
            descriptor: MCPToolDescriptorTests.makeDescriptor(originalName: tool, modelFacingName: name), era: .modern)
    }

    // MARK: - Ordering

    /// The tool list is rendered into the prompt, so an order that varies between launches
    /// misses the server's prefix cache on every run.
    func testEntriesAreSortedBySlugThenName() throws {
        let snapshot = MCPToolsSnapshot(entries: [
            try Self.makeEntry(slug: "trade_room", tool: "get_orders", serverID: Self.investID),
            try Self.makeEntry(slug: "folio", tool: "get_screenshot", serverID: Self.folioID),
            try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID),
        ])
        XCTAssertEqual(snapshot.entries.map(\.modelFacingName), [
            "mcp__folio__get_metadata", "mcp__folio__get_screenshot", "mcp__trade_room__get_orders",
        ])
    }

    func testTheEmptySnapshotIsWhatARunWithoutMCPSees() {
        XCTAssertTrue(MCPToolsSnapshot.empty.isEmpty)
        XCTAssertEqual(MCPToolsSnapshot.empty.revision, 0)
        XCTAssertNil(MCPToolsSnapshot.empty.invoker)
        XCTAssertTrue(MCPToolsSnapshot.empty.resolved(humanPresent: true).isEmpty)
        XCTAssertTrue(MCPResolvedTools.empty.isEmpty)
    }

    func testLooksAToolUpByTheNameTheModelWrites() throws {
        let snapshot = MCPToolsSnapshot(entries: [try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID)])
        XCTAssertEqual(snapshot.entry(named: "mcp__folio__get_metadata")?.descriptor.originalName, "get_metadata")
        XCTAssertNil(snapshot.entry(named: "get_metadata"))
        XCTAssertEqual(snapshot.modelFacingNames, ["mcp__folio__get_metadata"])
    }

    // MARK: - Grants

    func testAWholeServerGrantBringsEveryToolOfThatServerAndNoOther() throws {
        let snapshot = MCPToolsSnapshot(entries: [
            try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID),
            try Self.makeEntry(slug: "folio", tool: "get_screenshot", serverID: Self.folioID),
            try Self.makeEntry(slug: "trade_room", tool: "get_orders", serverID: Self.investID),
        ])
        XCTAssertEqual(snapshot.entries(grantedBy: ["mcp__folio"]).map(\.modelFacingName),
                       ["mcp__folio__get_metadata", "mcp__folio__get_screenshot"])
    }

    func testAnExactGrantBringsOneTool() throws {
        let snapshot = MCPToolsSnapshot(entries: [
            try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID),
            try Self.makeEntry(slug: "folio", tool: "get_screenshot", serverID: Self.folioID),
        ])
        XCTAssertEqual(snapshot.entries(grantedBy: ["mcp__folio__get_screenshot"]).map(\.modelFacingName),
                       ["mcp__folio__get_screenshot"])
    }

    /// A role listing its grants in a different order must still produce a byte-identical
    /// prompt, so the result follows the catalogue's order rather than the grant list's.
    func testGrantOrderDoesNotReachTheResult() throws {
        let snapshot = MCPToolsSnapshot(entries: [
            try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID),
            try Self.makeEntry(slug: "trade_room", tool: "get_orders", serverID: Self.investID),
        ])
        let forward = snapshot.entries(grantedBy: ["mcp__folio", "mcp__trade_room"]).map(\.modelFacingName)
        let reverse = snapshot.entries(grantedBy: ["mcp__trade_room", "mcp__folio"]).map(\.modelFacingName)
        XCTAssertEqual(forward, reverse)
    }

    func testBuiltInToolIDsGrantNoMCPTool() throws {
        let snapshot = MCPToolsSnapshot(entries: [try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID)])
        XCTAssertTrue(snapshot.entries(grantedBy: ["read_file", "bash", "mcp__"]).isEmpty)
        XCTAssertTrue(snapshot.entries(grantedBy: []).isEmpty)
    }

    /// A grant naming a server that is not connected brings nothing rather than erroring — the
    /// role keeps working, and the badge is what tells the user the server is off.
    func testAGrantForAnAbsentServerBringsNothing() throws {
        let snapshot = MCPToolsSnapshot(entries: [try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID)])
        XCTAssertTrue(snapshot.entries(grantedBy: ["mcp__trade_room"]).isEmpty)
    }

    // MARK: - Resolution

    func testWithAHumanPresentNothingIsWithheld() throws {
        let snapshot = MCPToolsSnapshot(entries: [
            try Self.makeEntry(slug: "trade_room", tool: "place_order", serverID: Self.investID),
            try Self.makeEntry(slug: "trade_room", tool: "get_quote", serverID: Self.investID, runsUnattended: true),
        ])
        let resolved = snapshot.resolved(humanPresent: true)
        XCTAssertEqual(resolved.shipped.count, 2)
        XCTAssertTrue(resolved.withheld.isEmpty)
    }

    /// The split is per TOOL, not per server: one server's read-only tools can run in an
    /// unattended run while the ones that place orders cannot.
    func testWithoutAHumanTheSplitIsPerToolNotPerServer() throws {
        let snapshot = MCPToolsSnapshot(entries: [
            try Self.makeEntry(slug: "trade_room", tool: "place_order", serverID: Self.investID,
                      approvalMode: .semiAutomatic, serverTrusted: true),
            try Self.makeEntry(slug: "trade_room", tool: "get_quote", serverID: Self.investID,
                      approvalMode: .semiAutomatic, serverTrusted: true, runsUnattended: true),
        ])
        let resolved = snapshot.resolved(humanPresent: false)
        XCTAssertEqual(resolved.shippedNames, ["mcp__trade_room__get_quote"])
        XCTAssertEqual(resolved.withheldNames, ["mcp__trade_room__place_order"])
    }

    func testAResolvedCatalogueCarriesTheInvokerThroughBothHalves() throws {
        let invoker = RecordingInvoker()
        let snapshot = MCPToolsSnapshot(
            entries: [try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID)],
            invoker: invoker)
        XCTAssertNotNil(snapshot.resolved(humanPresent: true).invoker)
        XCTAssertNotNil(snapshot.resolved(humanPresent: false).invoker)
    }

    /// The step needs both halves: shipped goes into the schema and the registry, withheld is
    /// what the classifier recognises when the model calls one anyway.
    func testGrantingNarrowsBothHalvesAtOnce() throws {
        let snapshot = MCPToolsSnapshot(entries: [
            try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID, runsUnattended: true),
            try Self.makeEntry(slug: "trade_room", tool: "place_order", serverID: Self.investID),
            try Self.makeEntry(slug: "trade_room", tool: "get_quote", serverID: Self.investID, runsUnattended: true),
        ])
        let granted = snapshot.resolved(humanPresent: false).granted(by: ["mcp__trade_room"])
        XCTAssertEqual(granted.shippedNames, ["mcp__trade_room__get_quote"])
        XCTAssertEqual(granted.withheldNames, ["mcp__trade_room__place_order"])
        XCTAssertNil(granted.entry(named: "mcp__folio__get_metadata"))
        XCTAssertNotNil(granted.entry(named: "mcp__trade_room__get_quote"))
    }

    /// An entry is identified by the name the model calls it by — what a list keyed on entries
    /// reads.
    func testAnEntryIsIdentifiedByItsModelFacingName() throws {
        let entry = try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID)
        XCTAssertEqual(entry.id, "mcp__folio__get_metadata")
        XCTAssertEqual(entry.id, entry.modelFacingName)
    }

    func testEntryKnowsItsOwnServerGrant() throws {
        XCTAssertEqual(try Self.makeEntry(slug: "folio", tool: "x", serverID: Self.folioID).serverGrantName, "mcp__folio")
    }

    // MARK: - Status

    func testEveryStatusNamesItselfAndOnlyTheFailuresCarryAReason() {
        let statuses: [MCPServerStatus] = [
            .disabled, .connecting, .connected(era: .modern),
            .needsAuth(reason: "r"), .failed(reason: "r"), .unsupportedTransport(reason: "r"),
            .incompatible(reason: "r"),
        ]
        for status in statuses {
            XCTAssertFalse(status.displayLabel.isEmpty, "\(status)")
        }
        XCTAssertEqual(MCPServerStatus.incompatible(reason: "r").reason, "r")
        XCTAssertNil(MCPServerStatus.disabled.reason)
        XCTAssertNil(MCPServerStatus.connecting.reason)
        XCTAssertNil(MCPServerStatus.connected(era: .legacy).reason)
        XCTAssertEqual(MCPServerStatus.needsAuth(reason: "r").reason, "r")
        XCTAssertEqual(MCPServerStatus.failed(reason: "r").reason, "r")
        XCTAssertEqual(MCPServerStatus.unsupportedTransport(reason: "r").reason, "r")
    }

    /// A failure the connection retries says so, and one it does not says what kind it is: the
    /// two are repaired differently — by waiting, and by a person — and a row reading "Not
    /// connected" for both sent the second to wait.
    ///
    /// RED until 2026-09-23 (group C, item 13): both read "Not connected".
    func testARetriedFailureSaysSoAndATerminalOneSaysWhatItIs() {
        XCTAssertEqual(MCPServerStatus.failed(reason: "r").displayLabel, "Not connected — retrying")
        XCTAssertEqual(MCPServerStatus.incompatible(reason: "r").displayLabel, "Incompatible server")
    }

    /// A connected server's status says Connected and nothing else: its tools are counted by
    /// the row from the catalogue (`MCPToolTally`), and its protocol revision is a line of its
    /// own on its page. Until F47 the label read "Connected — 2025-11-25 or earlier, 2 tools" —
    /// an era a person read as a date, and a count of the APPROVED tools alone.
    func testOnlyConnectedReadsAsConnectedAndItsLabelCarriesNeitherEraNorCount() {
        XCTAssertTrue(MCPServerStatus.connected(era: .modern).isConnected)
        XCTAssertFalse(MCPServerStatus.connecting.isConnected)
        XCTAssertFalse(MCPServerStatus.needsAuth(reason: "r").isConnected)
        for era in MCPProtocolEra.allCases {
            XCTAssertEqual(MCPServerStatus.connected(era: era).displayLabel, "Connected")
        }
    }

    /// The states in which a connection tried and could not — what a policy edit retries
    /// (`MCPServerConnection.adopt(_:)`). A reconnect passes through `.disabled`, and
    /// `.connecting` is still trying: retrying either would start a second attempt.
    func testOnlyTheStatesThatTriedAndCouldNotHaveFailed() {
        XCTAssertTrue(MCPServerStatus.needsAuth(reason: "r").hasFailed)
        XCTAssertTrue(MCPServerStatus.failed(reason: "r").hasFailed)
        XCTAssertTrue(MCPServerStatus.unsupportedTransport(reason: "r").hasFailed)
        XCTAssertTrue(MCPServerStatus.incompatible(reason: "r").hasFailed)
        XCTAssertFalse(MCPServerStatus.disabled.hasFailed)
        XCTAssertFalse(MCPServerStatus.connecting.hasFailed)
        XCTAssertFalse(MCPServerStatus.connected(era: .modern).hasFailed)
    }

    func testStatusesAreCarriedPerServer() throws {
        let snapshot = MCPToolsSnapshot(
            entries: [try Self.makeEntry(slug: "folio", tool: "x", serverID: Self.folioID)],
            statusByServerID: [Self.folioID: .connected(era: .legacy),
                               Self.investID: .needsAuth(reason: "401")])
        XCTAssertEqual(snapshot.statusByServerID[Self.folioID]?.isConnected, true)
        XCTAssertEqual(snapshot.statusByServerID[Self.investID]?.reason, "401")
    }

    /// The index a caller builds once to look up every call of a batch: the same entries
    /// `entry(named:)` finds, by the same name.
    func testTheByNameIndexHoldsExactlyTheEntriesByTheirModelFacingNames() throws {
        let snapshot = MCPToolsSnapshot(entries: [
            try Self.makeEntry(slug: "folio", tool: "get_metadata", serverID: Self.folioID),
            try Self.makeEntry(slug: "trade_room", tool: "get_quote", serverID: Self.investID),
        ])
        let index = snapshot.entriesByName
        XCTAssertEqual(Set(index.keys), snapshot.modelFacingNames)
        for (name, entry) in index {
            XCTAssertEqual(snapshot.entry(named: name), entry)
        }
        XCTAssertTrue(MCPToolsSnapshot.empty.entriesByName.isEmpty)
        let resolved = snapshot.resolved(humanPresent: true)
        XCTAssertEqual(Set(resolved.shippedByName.keys), resolved.shippedNames)
    }

    // MARK: - Call shapes

    func testACallResultDefaultsToSuccessWithNoStructuredContent() {
        let result = MCPCallToolResult(contentBlocks: [.object(["type": .string("text")])])
        XCTAssertFalse(result.isError)
        XCTAssertNil(result.structuredContent)
    }

    func testTheInvokerSeamCarriesTheServersOwnNameNotTheFoldedOne() async throws {
        let invoker = RecordingInvoker()
        let call = MCPToolCall(
            serverID: Self.investID, toolName: "GetPortfolio", expectedHash: "h",
            arguments: .object(["accountId": .string("1")]), headerParameters: ["Mcp-Param-Tenant": "acme"], era: nil)
        _ = try await invoker.callTool(call)
        XCTAssertEqual(invoker.calls.first?.toolName, "GetPortfolio")
        XCTAssertEqual(invoker.calls.first?.expectedHash, "h")
        XCTAssertEqual(invoker.calls.first?.headerParameters, ["Mcp-Param-Tenant": "acme"])
    }

    /// Minimal in-memory `MCPToolInvoking` — the seam exists so the runtime can be driven
    /// without a socket.
    private final class RecordingInvoker: MCPToolInvoking, @unchecked Sendable {
        private(set) var calls: [MCPToolCall] = []
        func callTool(_ call: MCPToolCall) async throws -> MCPCallToolResult {
            calls.append(call)
            return MCPCallToolResult(contentBlocks: [])
        }
    }
}
