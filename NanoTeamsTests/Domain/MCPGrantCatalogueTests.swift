import XCTest
@testable import NanoTeams

/// The catalogue answers what a snapshot structurally cannot: a server that is switched off is
/// absent from a snapshot entirely, and a tool awaiting review is indistinguishable there from
/// one that never existed. The role editor needs both, because each has a different repair.
final class MCPGrantCatalogueTests: XCTestCase {

    static let folioID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    static let investID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!

    // MARK: - Shared fixtures

    static func makeTool(
        slug: String,
        tool: String,
        pinState: MCPPinState = .approved,
        alwaysAllowed: Bool = false,
        runsUnattended: Bool = false,
        isRejected: Bool = false
    ) throws -> MCPGrantCatalogue.Tool {
        let name = try XCTUnwrap(MCPToolNaming.modelFacingName(slug: slug, toolName: tool))
        return MCPGrantCatalogue.Tool(
            descriptor: MCPToolDescriptorTests.makeDescriptor(originalName: tool, modelFacingName: name),
            pinState: pinState,
            alwaysAllowed: alwaysAllowed,
            runsUnattended: runsUnattended,
            isRejected: isRejected)
    }

    static func makeServer(
        slug: String,
        id: UUID,
        status: MCPServerStatus = .connected(era: .modern),
        standing: MCPServerStanding? = nil,
        approvalMode: MCPApprovalMode = .manual,
        isTrusted: Bool = false,
        tools: [MCPGrantCatalogue.Tool] = [],
        catalogueUnverified: Bool = false,
        nothingOffered: Bool = false,
        refused: Set<String> = []
    ) throws -> MCPGrantCatalogue.Server {
        MCPGrantCatalogue.Server(
            id: id,
            slug: try XCTUnwrap(MCPServerSlug(slug)),
            displayName: slug,
            status: status,
            standing: standing,
            approvalMode: approvalMode,
            isTrusted: isTrusted,
            tools: tools,
            catalogueUnverified: catalogueUnverified,
            nothingItPublishesCanBeOffered: nothingOffered,
            refusedToolNames: refused)
    }

    /// Folio connected with one approved and one unreviewed tool; Trade-Room configured and off.
    private func catalogue() throws -> MCPGrantCatalogue {
        MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "trade_room", id: Self.investID, status: .disabled, standing: .switchedOff),
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
                try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .new),
            ]),
        ], revision: 7)
    }

    // MARK: - Order

    /// Both sorts exist for the same reason the snapshot's does: the picker's sections and
    /// rows must not reorder between rebuilds, and a grant's position is how a person finds it.
    func testServersSortBySlugAndToolsByName() throws {
        let catalogue = try catalogue()

        XCTAssertEqual(catalogue.servers.map(\.slug.rawValue), ["folio", "trade_room"])
        XCTAssertEqual(
            catalogue.server(slug: "folio")?.tools.map(\.modelFacingName),
            ["mcp__folio__get_metadata", "mcp__folio__get_screenshot"])
    }

    // MARK: - Where a grant stands

    func testAReviewedToolOfAConnectedServerIsLive() throws {
        XCTAssertEqual(try catalogue().state(ofGrant: "mcp__folio__get_screenshot", humanPresent: true), .live)
    }

    func testAnUnreviewedToolIsNamedAsSuch() throws {
        XCTAssertEqual(try catalogue().state(ofGrant: "mcp__folio__get_metadata", humanPresent: true), .toolUnreviewed)
    }

    /// An approved tool the server has since rewritten is withheld exactly like a new one —
    /// the text a person approved is no longer the text on the server.
    func testARewrittenToolReadsAsUnreviewed() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot", pinState: .changed(approvedHash: "old")),
            ]),
        ])

        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: true), .toolUnreviewed)
    }

    /// The one per-tool fault that IS decidable: the server is answering and does not offer it.
    func testAToolAConnectedServerDoesNotPublishIsMissing() throws {
        XCTAssertEqual(try catalogue().state(ofGrant: "mcp__folio__get_variable_defs", humanPresent: true), .toolMissing)
    }

    func testASwitchedOffServerIsNamedAsSwitchedOff() throws {
        XCTAssertEqual(try catalogue().state(ofGrant: "mcp__trade_room__get_orders", humanPresent: true), .serverDisabled)
        XCTAssertEqual(try catalogue().state(ofGrant: "mcp__trade_room", humanPresent: true), .serverDisabled)
    }

    /// Connecting, refused, unauthenticated and address-refused all read the same from the
    /// role editor — come back when it connects. The server list is where the reason is.
    /// Every status short of a session and short of a person's switch reads as unreachable —
    /// for a tool grant and a whole-server grant alike. `.incompatible` among them: a server
    /// that speaks nothing this client does is not one a person switched off, and the role
    /// editor saying so sent them to the wrong repair (a gap the mutation run of group C's
    /// second review found: the arm could be moved to `.serverDisabled` with every test green).
    func testEveryNonConnectedStatusReadsAsUnreachable() throws {
        for status: MCPServerStatus in [
            .connecting, .failed(reason: "refused"), .needsAuth(reason: "401"),
            .unsupportedTransport(reason: "plain http"), .incompatible(reason: "2027-01-01"),
        ] {
            let catalogue = MCPGrantCatalogue(servers: [
                try Self.makeServer(slug: "folio", id: Self.folioID, status: status, tools: [
                    try Self.makeTool(slug: "folio", tool: "get_screenshot"),
                ]),
            ])
            XCTAssertEqual(
                catalogue.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: true), .serverUnreachable,
                "\(status)")
            XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: true), .serverUnreachable, "whole server, \(status)")
        }
    }

    /// A grant of a server that runs nothing names WHY — the standing the manager computed
    /// (`MCPServerStanding`), because each cause has its own repair: the server's switch, this
    /// folder's switch, nothing at all until a folder opens, or the token. A server that
    /// connected without the token its configuration declares ships its tools, and its grants
    /// read as any connected server's. For a tool grant and a whole-server grant alike.
    ///
    /// RED until 2026-10-28: every server that ran nothing read `.serverDisabled` — "switched
    /// off — turn it on" — the folder's rule and a shut-down manager included, and a server
    /// missing its token read `.serverUnreachable`.
    func testAGrantOfAServerThatRunsNothingNamesWhy() throws {
        let rows: [(MCPServerStanding, MCPServerStatus, MCPGrantState)] = [
            (.switchedOff, .disabled, .serverDisabled),
            (.offInThisFolder, .disabled, .serverOffInThisFolder),
            (.notRunning, .disabled, .serverNotRunning),
            (.needsToken, .connecting, .serverNeedsToken),
            (.needsToken, .needsAuth(reason: "401"), .serverNeedsToken),
            (.needsToken, .disabled, .serverNeedsToken),
            (.of(hasRequiredSecrets: false, status: .connected(era: .modern)), .connected(era: .modern), .live),
            (.running(.failed(reason: "refused")), .failed(reason: "refused"), .serverUnreachable),
            (.running(.connected(era: .legacy)), .connected(era: .legacy), .live),
        ]
        for (standing, status, expected) in rows {
            let catalogue = MCPGrantCatalogue(servers: [
                try Self.makeServer(slug: "folio", id: Self.folioID, status: status, standing: standing, tools: [
                    try Self.makeTool(slug: "folio", tool: "get_screenshot"),
                ]),
            ])
            XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: true), expected,
                           "\(standing)")
            XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: true), expected,
                           "whole server, \(standing)")
        }
        // The runtime reads the status, not the standing: what ships is the connected server's.
        let connectedWithoutItsToken = MCPGrantCatalogue(servers: [
            try Self.makeServer(
                slug: "folio", id: Self.folioID, status: .connected(era: .modern),
                standing: .of(hasRequiredSecrets: false, status: .connected(era: .modern)),
                tools: [try Self.makeTool(slug: "folio", tool: "get_screenshot")]),
        ])
        XCTAssertEqual(connectedWithoutItsToken.shippedEntries.map(\.descriptor.originalName), ["get_screenshot"])
        // A server built with no standing reads the same rule MCPServerRow does: `.disabled` as notRunning.
        XCTAssertEqual(try Self.makeServer(slug: "folio", id: Self.folioID, status: .disabled).standing, .notRunning)
        XCTAssertEqual(try Self.makeServer(slug: "folio", id: Self.folioID, status: .connecting).standing,
                       .running(.connecting))
    }

    func testAGrantOfAnAbsentServerIsUnknown() throws {
        XCTAssertEqual(try catalogue().state(ofGrant: "mcp__gone__x", humanPresent: true), .unknownServer)
    }

    /// A whole-server grant brings the server's APPROVED tools. A connected server that
    /// publishes tools and has not one approved — new, or rewritten since approval — brings
    /// nothing until someone reviews one, and the grant says so exactly as a grant of one of
    /// those tools would.
    ///
    /// RED until 2026-09-24: it read `.live` ("a whole-server grant asks only that the server
    /// answer"), so the role held `mcp__folio`, a run gave it no tool, and the badge said nothing.
    func testAWholeServerGrantOfAServerWithNothingApprovedWaitsForReview() throws {
        for pinState: MCPPinState in [.new, .changed(approvedHash: "old")] {
            let catalogue = MCPGrantCatalogue(servers: [
                try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                    try Self.makeTool(slug: "folio", tool: "get_screenshot", pinState: pinState),
                    try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .new),
                ]),
            ])
            for humanPresent in [true, false] {
                XCTAssertEqual(
                    catalogue.state(ofGrant: "mcp__folio", humanPresent: humanPresent), .toolUnreviewed,
                    "\(pinState), humanPresent: \(humanPresent)")
            }
        }
    }

    // MARK: - A refused text (2026-10-28)

    /// A per-tool grant of a text the person refused is not waiting for anyone: it is refused —
    /// a new tool's text or a rewrite's alike, whoever is there to approve, and ahead of a
    /// re-read exactly as a text waiting for review is. A refusal of an OLDER text does not
    /// cover the one the server publishes now: that one is waiting.
    ///
    /// RED until 2026-10-28: the catalogue carried no refusal, so the grant read
    /// `.toolUnreviewed` — "Waiting for review" — while the Settings list counted it apart.
    func testAPerToolGrantOfARefusedTextIsRefusedNotWaiting() throws {
        for pinState: MCPPinState in [.new, .changed(approvedHash: "old")] {
            for unverified in [false, true] {
                let catalogue = MCPGrantCatalogue(servers: [
                    try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                        try Self.makeTool(slug: "folio", tool: "get_screenshot"),
                        try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: pinState, isRejected: true),
                        try Self.makeTool(slug: "folio", tool: "get_file", pinState: pinState),
                    ], catalogueUnverified: unverified),
                ])
                for humanPresent in [true, false] {
                    let context = "\(pinState), unverified: \(unverified), humanPresent: \(humanPresent)"
                    XCTAssertEqual(
                        catalogue.state(ofGrant: "mcp__folio__get_metadata", humanPresent: humanPresent),
                        .toolRefused, context)
                    XCTAssertEqual(
                        catalogue.state(ofGrant: "mcp__folio__get_file", humanPresent: humanPresent),
                        .toolUnreviewed, context)
                }
            }
        }
    }

    /// A whole-server grant of a server that publishes tools, has none approved, and has none
    /// waiting either — every text refused — is refused, in its whole-server form, with a person
    /// there or not. The list says "0 approved" and nothing to review of that server, and the
    /// grant says the same thing.
    ///
    /// RED until 2026-10-28: it read `.toolUnreviewed`, badging "Waiting for review" a server
    /// the list showed nothing to review on.
    func testAWholeServerGrantOfAServerWhoseEveryTextWasRefusedSaysSo() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot", pinState: .new, isRejected: true),
                try Self.makeTool(
                    slug: "folio", tool: "get_metadata", pinState: .changed(approvedHash: "old"), isRejected: true),
            ]),
        ])
        XCTAssertEqual(catalogue.server(slug: "folio")?.toolTally.toReview, 0, "premise: the list shows nothing to review")
        for humanPresent in [true, false] {
            XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: humanPresent), .everyToolRefused,
                           "\(humanPresent)")
        }
    }

    /// Some texts refused and one waiting, none approved: the grant waits for review — there is
    /// something to read. One approved beside refused texts: the grant brings it, live.
    func testAWholeServerGrantWithSomethingWaitingOrApprovedIsNotRefused() throws {
        let waiting = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot", pinState: .new, isRejected: true),
                try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .new),
            ]),
        ])
        let approved = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot", pinState: .new, isRejected: true),
                try Self.makeTool(slug: "folio", tool: "get_metadata"),
            ]),
        ])
        XCTAssertEqual(waiting.state(ofGrant: "mcp__folio", humanPresent: true), .toolUnreviewed)
        XCTAssertEqual(approved.state(ofGrant: "mcp__folio", humanPresent: true), .live)
    }

    /// A REWRITE waits for review as a new tool does: a whole-server grant of a server with
    /// nothing approved, whose only unrefused text is one the server rewrote since it was
    /// approved, is waiting — the Settings list counts that rewrite "to review" (`MCPToolTally`) —
    /// and never reads as every text refused.
    ///
    /// RED until 2026-10-28: if only a NEW text counted as waiting, no test
    /// held a server whose waiting text was a rewrite.
    func testAWholeServerGrantWhoseOnlyWaitingTextIsARewriteWaitsForReview() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot", pinState: .new, isRejected: true),
                try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .changed(approvedHash: "old")),
            ]),
        ])
        let tally = try XCTUnwrap(catalogue.server(slug: "folio")).toolTally
        XCTAssertEqual(tally.approved, 0, "premise: nothing approved")
        XCTAssertEqual(tally.new, 0, "premise: no new text")
        XCTAssertGreaterThan(tally.toReview, 0, "premise: the rewrite is to review")
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: true), .toolUnreviewed)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: false), .toolUnreviewed)
    }

    // MARK: - The app's refusal is not the server's (2026-10-28)

    /// A per-tool grant naming an entry of a listing that COLLIDED — two names folding to one,
    /// the whole namespace refused, `tools` empty — is the app's refusal: the server publishes
    /// it. A name the listing did not publish at all is still missing.
    ///
    /// RED until 2026-10-28: both read `.toolMissing` — "does not offer this tool, uncheck
    /// it here".
    func testAPerToolGrantOfACollidedEntryIsNotOfferableNotMissing() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(
                slug: "orders", id: Self.folioID, nothingOffered: true,
                refused: ["mcp__orders__get_orders", "mcp__orders__list_items"]),
        ])
        for humanPresent in [true, false] {
            XCTAssertEqual(catalogue.state(ofGrant: "mcp__orders__get_orders", humanPresent: humanPresent), .toolNotOfferable)
            XCTAssertEqual(catalogue.state(ofGrant: "mcp__orders__list_items", humanPresent: humanPresent), .toolNotOfferable)
            XCTAssertEqual(catalogue.state(ofGrant: "mcp__orders__gone", humanPresent: humanPresent), .toolMissing,
                           "a name the listing did not publish is missing")
        }
    }

    /// A whole-server grant of a server that published tools the app can offer none of brings
    /// nothing, and says so — ahead of `.live`, whoever is there to approve, and even while its
    /// tool list is being read again (nothing of the last committed listing could ship).
    ///
    /// RED until 2026-10-28: it read `.live`, and the role list showed no badge.
    func testAWholeServerGrantOfAServerThatCanOfferNothingSaysSo() throws {
        for unverified in [false, true] {
            let catalogue = MCPGrantCatalogue(servers: [
                try Self.makeServer(
                    slug: "orders", id: Self.folioID, catalogueUnverified: unverified, nothingOffered: true,
                    refused: ["mcp__orders__get_orders"]),
            ])
            for humanPresent in [true, false] {
                XCTAssertEqual(catalogue.state(ofGrant: "mcp__orders", humanPresent: humanPresent), .noToolOfferable,
                               "unverified \(unverified), human \(humanPresent)")
            }
            XCTAssertTrue(catalogue.shippedEntries.isEmpty, "the words change; what ships does not")
        }
        // A server that publishes nothing at all has nothing to refuse, and stays quiet.
        let empty = MCPGrantCatalogue(servers: [try Self.makeServer(slug: "orders", id: Self.folioID)])
        XCTAssertEqual(empty.state(ofGrant: "mcp__orders", humanPresent: true), .live)
    }

    /// A server with some entries refused and some offered: a per-tool grant of the refused one
    /// is the app's refusal, a grant of a good one reads as it always did, and the whole-server
    /// grant is not refused whole — its good tools decide it.
    func testAPartlyRefusedServerAnswersEachGrantByItsOwnEntry() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
                try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .new),
            ], refused: ["mcp__folio__get_chart"]),
        ])
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_chart", humanPresent: true), .toolNotOfferable)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: true), .live)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_metadata", humanPresent: true), .toolUnreviewed)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: true), .live)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__gone", humanPresent: true), .toolMissing)
        XCTAssertEqual(catalogue.shippedEntries.map(\.modelFacingName), ["mcp__folio__get_screenshot"],
                       "a refused entry never ships")
    }

    /// A server that is not connected is that first: the app's refusal is read only off a
    /// listing the server is serving.
    func testAnUnreachableServersRefusalsAreNotItsStanding() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(
                slug: "orders", id: Self.folioID, status: .connecting, nothingOffered: true,
                refused: ["mcp__orders__get_orders"]),
        ])
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__orders__get_orders", humanPresent: true), .serverUnreachable)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__orders", humanPresent: true), .serverUnreachable)
    }

    /// One approved tool is enough: the grant brings it, and the unreviewed rest are the
    /// picker's rows to act on, not a fault in the grant.
    func testAWholeServerGrantWithOneApprovedToolIsLive() throws {
        XCTAssertEqual(try catalogue().state(ofGrant: "mcp__folio", humanPresent: true), .live)
    }

    /// A server that publishes no tools at all has nothing to review and nothing withheld: the
    /// grant brings nothing, and whatever the server publishes and a person approves later
    /// rides in on it. Quiet, because no repair exists — "waiting for review" would send the
    /// person to a Settings page with nothing on it.
    func testAWholeServerGrantOfAServerThatPublishesNothingIsQuiet() throws {
        let catalogue = MCPGrantCatalogue(servers: [try Self.makeServer(slug: "folio", id: Self.folioID)])
        for humanPresent in [true, false] {
            XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: humanPresent), .live, "\(humanPresent)")
        }
    }

    /// While a list is being read again, a whole-server grant whose last committed listing
    /// approved nothing is waiting for review — the read would bring nothing back — exactly as
    /// a per-tool grant of an unreviewed tool is (`testAPerToolGrantOfAListBeingReadAgainIs…`).
    func testAWholeServerGrantOfARereadServerWithNothingApprovedWaitsForReview() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot", pinState: .new),
            ], catalogueUnverified: true),
        ])
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: true), .toolUnreviewed)
    }

    /// A built-in name is not a grant at all. Answering `.live` would be the worse lie: the
    /// badge would stop reporting a tool the catalogue knows nothing about.
    func testABuiltInToolNameIsNotLive() throws {
        XCTAssertEqual(try catalogue().state(ofGrant: ToolNames.readFile, humanPresent: true), .unknownServer)
    }

    func testAnEmptyCatalogueKnowsNothing() {
        XCTAssertEqual(MCPGrantCatalogue.empty.state(ofGrant: "mcp__folio__x", humanPresent: true), .unknownServer)
        XCTAssertTrue(MCPGrantCatalogue.empty.isEmpty)
        XCTAssertTrue(MCPGrantCatalogue.empty.grantableToolIDs.isEmpty)
    }

    // MARK: - What a role may hold

    /// The switched-off server's grants are in the set: turning a server off is reversible and
    /// does not make a role that grants its tools wrong. Unreviewed tools are in it too — an
    /// unreviewed tool is a grant waiting on a click.
    func testGrantableIDsCoverEveryConfiguredServerAndEveryPublishedTool() throws {
        XCTAssertEqual(try catalogue().grantableToolIDs, [
            "mcp__folio", "mcp__folio__get_screenshot", "mcp__folio__get_metadata",
            "mcp__trade_room",
        ])
    }

    // MARK: - What would ship

    func testOnlyReviewedToolsOfReachableServersShip() throws {
        XCTAssertEqual(
            try catalogue().shippedEntries.map(\.modelFacingName),
            ["mcp__folio__get_screenshot"])
    }

    /// Each shipped entry carries the era its OWN server's session speaks — a legacy server's are
    /// legacy, a modern server's modern, side by side — so a legacy server's tool with a header
    /// parameter is split for the body alone, and the live index does not read it as changed.
    ///
    /// Pins that every shipped entry carries its own server's era rather than stamping `.modern`.
    func testAShippedEntryCarriesItsOwnServersEra() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, status: .connected(era: .legacy), tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
                try Self.makeTool(slug: "folio", tool: "get_metadata"),
            ]),
            try Self.makeServer(slug: "trade_room", id: Self.investID, status: .connected(era: .modern), tools: [
                try Self.makeTool(slug: "trade_room", tool: "get_quote"),
            ]),
        ], revision: 1)
        let entries = catalogue.shippedEntries
        XCTAssertEqual(entries.count, 3, "premise: every reviewed tool ships")
        XCTAssertTrue(entries.filter { $0.serverID == Self.folioID }.allSatisfy { $0.era == .legacy })
        XCTAssertEqual(entries.filter { $0.serverID == Self.investID }.map(\.era), [.modern])
    }

    /// A connected server whose catalogue is unverified — a listing asked after its
    /// `list_changed`, or once its stated catalogue lifetime ran out, failed — ships none of its
    /// tools, reviewed or not, and a grant of it or of a tool it had reviewed reads as a tool
    /// list being read again: the tools come back when a listing does. The snapshot carries the
    /// server's last committed approvals, so the live catalogue reads a step's frozen entry
    /// with the refusal dispatch gives the same call, and the gate holds no card for it.
    ///
    /// RED until 2026-09-24 (group C): the grant read `.serverUnreachable` — "not connected" —
    /// beside a Settings row that said Connected, and the live catalogue read `.toolChanged`.
    func testAnUnverifiedCatalogueShipsNothingAndItsToolsReadAsBeingReread() throws {
        let verified = try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
            try Self.makeTool(slug: "folio", tool: "get_screenshot"),
        ])
        let frozen = try XCTUnwrap(MCPGrantCatalogue(servers: [verified]).shippedEntries.first)
        let status = MCPServerStatus.connected(era: .modern)
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, status: status, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
            ], catalogueUnverified: true),
        ])

        XCTAssertTrue(catalogue.shippedEntries.isEmpty)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: true), .catalogueBeingReread)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: true), .catalogueBeingReread)
        XCTAssertEqual(
            catalogue.lastCommittedApprovalsOfUnverifiedServers,
            [Self.folioID: [frozen.modelFacingName: frozen.descriptor.pinHash]])
        let live = MCPToolsSnapshot(
            entries: catalogue.shippedEntries, statusByServerID: [Self.folioID: status],
            lastCommittedApprovalsOfUnverifiedServers: catalogue.lastCommittedApprovalsOfUnverifiedServers)
        XCTAssertEqual(MCPLiveCatalogueIndex(live).standing(of: frozen), .refused(.toolsBeingReread))
    }

    /// The mark is about a LIVE session's list: a server that is not connected is refused for
    /// that — its own grant state, and not in the set the snapshot carries.
    func testTheRereadMarkOfAServerThatIsNotConnectedIsNotItsStanding() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, status: .connecting, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
            ], catalogueUnverified: true),
        ])
        XCTAssertEqual(catalogue.lastCommittedApprovalsOfUnverifiedServers, [:])
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: true), .serverUnreachable)
    }

    // MARK: - The last committed approvals of a list being read again (group C, C-5)

    /// What the live catalogue answers from while a list is being read again: per connected
    /// server whose catalogue is unverified, the REVIEWED tools of its last committed listing,
    /// each at its approved hash. An unreviewed tool is not in it; a verified server and a
    /// server with no session are not keys; a server whose last commit approved nothing is a
    /// key with an empty table — the keys are the unverified set.
    func testTheLastCommittedApprovalsHoldTheReviewedToolsOfConnectedUnverifiedServersOnly() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
                try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .changed(approvedHash: "old")),
                try Self.makeTool(slug: "folio", tool: "get_whiteboard", pinState: .new),
            ], catalogueUnverified: true),
            try Self.makeServer(slug: "trade_room", id: Self.investID, tools: [
                try Self.makeTool(slug: "trade_room", tool: "get_quote", pinState: .new),
            ], catalogueUnverified: true),
            try Self.makeServer(slug: "verified", id: UUID(), tools: [
                try Self.makeTool(slug: "verified", tool: "get_price"),
            ]),
            try Self.makeServer(slug: "offline", id: UUID(), status: .connecting, tools: [
                try Self.makeTool(slug: "offline", tool: "get_price"),
            ], catalogueUnverified: true),
        ])
        let screenshot = try XCTUnwrap(
            catalogue.server(slug: "folio")?.tools.first { $0.modelFacingName == "mcp__folio__get_screenshot" })

        XCTAssertEqual(catalogue.lastCommittedApprovalsOfUnverifiedServers, [
            Self.folioID: ["mcp__folio__get_screenshot": screenshot.descriptor.pinHash],
            Self.investID: [:],
        ])
        XCTAssertEqual(catalogue.shippedEntries.map(\.modelFacingName), ["mcp__verified__get_price"])
    }

    /// The table is a verdict to answer a frozen tool with, never a tool list: nothing that
    /// ships reads it — not the catalogue's shipped entries or split, not the snapshot's
    /// entries, lookups, grants or split, so neither the picker's run view nor a prompt can
    /// reach an approved tool of a server whose list is being read again through it.
    func testTheLastCommittedApprovalsAreNeverShipped() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot", runsUnattended: true),
                try Self.makeTool(slug: "folio", tool: "get_metadata"),
            ], catalogueUnverified: true),
        ])
        XCTAssertEqual(catalogue.lastCommittedApprovalsOfUnverifiedServers[Self.folioID]?.count, 2, "premise")

        XCTAssertTrue(catalogue.shippedEntries.isEmpty)
        for humanPresent in [true, false] {
            XCTAssertTrue(catalogue.resolvedTools(humanPresent: humanPresent).isEmpty, "\(humanPresent)")
        }
        let live = MCPToolsSnapshot(
            entries: catalogue.shippedEntries,
            statusByServerID: [Self.folioID: .connected(era: .modern)],
            lastCommittedApprovalsOfUnverifiedServers: catalogue.lastCommittedApprovalsOfUnverifiedServers)
        XCTAssertTrue(live.isEmpty)
        XCTAssertNil(live.entry(named: "mcp__folio__get_screenshot"))
        XCTAssertTrue(live.entriesByName.isEmpty)
        XCTAssertTrue(live.modelFacingNames.isEmpty)
        XCTAssertTrue(live.entries(grantedBy: ["mcp__folio", "mcp__folio__get_screenshot"]).isEmpty)
        for humanPresent in [true, false] {
            XCTAssertTrue(live.resolved(humanPresent: humanPresent).isEmpty, "\(humanPresent)")
        }
    }

    /// A per-tool grant of a server whose list is being read again is answered from its last
    /// committed listing, the one the live catalogue answers a call from: not published there
    /// → missing, published and unreviewed → unreviewed, reviewed → being read again. A
    /// whole-server grant asks only about the server, and brings nothing until the read ends.
    ///
    /// RED until 2026-09-24 (group C, C-5): every grant read `.catalogueBeingReread`, so a tool
    /// waiting for review — or one the server no longer offers — was badged as coming back on
    /// its own when the read succeeded.
    func testAPerToolGrantOfAListBeingReadAgainIsAnsweredFromTheLastCommit() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
                try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .changed(approvedHash: "old")),
            ], catalogueUnverified: true),
        ])

        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: true), .catalogueBeingReread)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_metadata", humanPresent: true), .toolUnreviewed)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_whiteboard", humanPresent: true), .toolMissing)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: true), .catalogueBeingReread)
    }

    /// The approval decision is NOT re-made here — it rides on the tool exactly as the manager
    /// computed it, which is what keeps `resolved(humanPresent:)` a pure split.
    func testTheUnattendedSplitFollowsTheToolsOwnVerdict() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_metadata", runsUnattended: true),
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
            ]),
        ])

        let unattended = catalogue.resolvedTools(humanPresent: false)
        XCTAssertEqual(unattended.shippedNames, ["mcp__folio__get_metadata"])
        XCTAssertEqual(unattended.withheldNames, ["mcp__folio__get_screenshot"])
        XCTAssertEqual(catalogue.resolvedTools(humanPresent: true).shippedNames.count, 2)
    }

    /// The revision rides through, so a memoised reader can compare one integer instead of
    /// walking the tree.
    func testTheRevisionRidesIntoTheResolvedSplit() throws {
        XCTAssertEqual(try catalogue().resolvedTools(humanPresent: true).revision, 7)
    }
    // MARK: - Identity and counts

    /// Every row the picker draws is keyed by the model-facing name — the one string that is
    /// unique across servers by construction, unlike the server's own tool name.
    func testAToolIsIdentifiedByTheNameTheModelSees() throws {
        let tool = try Self.makeTool(slug: "folio", tool: "get_screenshot")

        XCTAssertEqual(tool.id, "mcp__folio__get_screenshot")
        XCTAssertEqual(tool.id, tool.modelFacingName)
    }

    /// A server's tools are counted by the rule the Settings list counts the same server's with
    /// (`MCPToolTally`): a refused text is decided — counted apart, never as waiting for review,
    /// whether it was new or a rewrite. Until 2026-10-28 the catalogue carried its own count
    /// (`unreviewedCount`, new + rewritten), which only a test read and which counted a refused
    /// text as waiting — disagreeing with the list's "to review".
    func testAServerCountsItsToolsByTheSettingsListsRule() throws {
        let server = try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
            try Self.makeTool(slug: "folio", tool: "get_screenshot"),
            try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .new),
            try Self.makeTool(slug: "folio", tool: "get_whiteboard", pinState: .changed(approvedHash: "old")),
            try Self.makeTool(slug: "folio", tool: "get_file", pinState: .new, isRejected: true),
            try Self.makeTool(slug: "folio", tool: "get_node", pinState: .changed(approvedHash: "old"), isRejected: true),
        ])

        XCTAssertEqual(server.toolTally, MCPToolTally(approved: 1, new: 1, changed: 1, rejected: 2))
        XCTAssertEqual(server.toolTally.toReview, 2)
        XCTAssertEqual(server.reviewedTools.map(\.modelFacingName), ["mcp__folio__get_screenshot"])
    }

    /// The Settings row is keyed by the SERVER's id, not by its slug: a slug can be renamed
    /// and the pins and the Keychain accounts follow the id.
    func testASettingsRowIsIdentifiedByTheServerID() throws {
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "Folio",
            transport: .http(MCPHTTPConfig(urlString: "http://127.0.0.1:3845/mcp")))
        let row = MCPServerRow(
            config: config, status: .disabled, isAllowedInThisFolder: true, hasRequiredSecrets: true)

        XCTAssertEqual(row.id, config.id)
    }


    // MARK: - A run with nobody to approve (F46)

    /// Folio in Manual mode — nothing of it runs unattended — with one approved and one
    /// unreviewed tool; Trade-Room trusted, Semi-automatic, whose read-only `get_orders` runs
    /// unattended and whose `place_order` does not; Lab switched off.
    private func unattendedCatalogue() throws -> MCPGrantCatalogue {
        MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, approvalMode: .manual, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
                try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .new),
            ]),
            try Self.makeServer(
                slug: "trade_room", id: Self.investID, approvalMode: .semiAutomatic, isTrusted: true, tools: [
                    try Self.makeTool(slug: "trade_room", tool: "get_orders", runsUnattended: true),
                    try Self.makeTool(slug: "trade_room", tool: "place_order"),
                ]),
            try Self.makeServer(slug: "lab", id: UUID(), status: .disabled, standing: .switchedOff),
        ])
    }

    /// An approved tool whose every call would be held is withheld from a run with nobody to
    /// answer — exactly as `MCPToolsSnapshot.resolved(humanPresent: false)` withholds it — and
    /// with a person there it is live.
    ///
    /// RED until 2026-09-24: presence was not a question the catalogue answered, and the role
    /// editor read every such tool as live (F46).
    func testAToolThatWouldBeHeldNeedsAnApproverOnlyWhenNobodyIsThere() throws {
        let catalogue = try unattendedCatalogue()
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: false), .needsApprover)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__trade_room__place_order", humanPresent: false), .needsApprover)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: true), .live)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__trade_room__place_order", humanPresent: true), .live)
    }

    func testAToolThatRunsUnattendedIsLiveWithNobodyThere() throws {
        XCTAssertEqual(
            try unattendedCatalogue().state(ofGrant: "mcp__trade_room__get_orders", humanPresent: false), .live)
    }

    /// A whole-server grant needs an approver only when not one of the server's approved tools
    /// could run: one that brings SOMETHING to an unattended run is live, and a server with no
    /// approved tool at all brings nothing for a nearer reason than the missing person — it is
    /// waiting for review.
    func testAWholeServerGrantNeedsAnApproverOnlyWhenNothingOfItCouldRun() throws {
        let catalogue = try unattendedCatalogue()
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: false), .needsApprover)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__trade_room", humanPresent: false), .live)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio", humanPresent: true), .live)

        let nothingApproved = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_metadata", pinState: .new),
            ]),
        ])
        XCTAssertEqual(nothingApproved.state(ofGrant: "mcp__folio", humanPresent: false), .toolUnreviewed)
    }

    /// The missing person is the LAST reason, never one that hides a nearer one: a tool that is
    /// off, unreviewed, gone or being re-read is that first, whoever is there.
    func testTheMissingPersonNeverHidesANearerReason() throws {
        let catalogue = try unattendedCatalogue()
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_metadata", humanPresent: false), .toolUnreviewed)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__folio__get_whiteboard", humanPresent: false), .toolMissing)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__lab__x", humanPresent: false), .serverDisabled)
        XCTAssertEqual(catalogue.state(ofGrant: "mcp__gone__x", humanPresent: false), .unknownServer)

        let rereading = MCPGrantCatalogue(servers: [
            try Self.makeServer(slug: "folio", id: Self.folioID, tools: [
                try Self.makeTool(slug: "folio", tool: "get_screenshot"),
            ], catalogueUnverified: true),
        ])
        XCTAssertEqual(rereading.state(ofGrant: "mcp__folio__get_screenshot", humanPresent: false), .catalogueBeingReread)
        XCTAssertEqual(rereading.state(ofGrant: "mcp__folio", humanPresent: false), .catalogueBeingReread)
    }

    /// The editor's split and the runtime's are one split: what `resolvedTools(humanPresent:)`
    /// withholds is exactly what reads `.needsApprover`.
    func testWhatTheSplitWithholdsIsWhatNeedsAnApprover() throws {
        let catalogue = try unattendedCatalogue()
        let resolved = catalogue.resolvedTools(humanPresent: false)
        let needing = Set(catalogue.servers.flatMap(\.tools).map(\.modelFacingName)
            .filter { catalogue.state(ofGrant: $0, humanPresent: false) == .needsApprover })
        XCTAssertEqual(resolved.withheldNames, needing)
        XCTAssertEqual(resolved.shippedNames, ["mcp__trade_room__get_orders"])
        XCTAssertEqual(catalogue.resolvedTools(humanPresent: true).withheldNames, [])
    }
}
