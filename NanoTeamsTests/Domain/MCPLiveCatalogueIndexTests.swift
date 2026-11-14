import XCTest

@testable import NanoTeams

/// Where a tool a step was set up with stands in the live catalogue — the one rule the
/// iteration's drift check and the MCP gate both read. Driven end to end by
/// `MCPDriftWithholdingTests`, `MCPGateTests` and `MCPToolIterationDriftTests`; this suite pins
/// the rule itself, case by case.
final class MCPLiveCatalogueIndexTests: XCTestCase {

    private static let folioID = UUID()
    private static let otherID = UUID()

    private func entry(
        serverID: UUID? = nil, approvalMode: MCPApprovalMode = .manual, hash: String = "h1",
        era: MCPProtocolEra = .modern, headerParams: [MCPHeaderParam] = [], callShapeDependsOnEra: Bool? = nil
    ) throws -> MCPToolsSnapshot.Entry {
        let plain = MCPToolDescriptorTests.makeDescriptor(
            originalName: "get_metadata", modelFacingName: "mcp__folio__get_metadata", pinHash: hash)
        return MCPToolsSnapshot.Entry(
            serverID: serverID ?? Self.folioID,
            slug: try XCTUnwrap(MCPServerSlug("folio")),
            serverDisplayName: "Folio",
            approvalMode: approvalMode,
            serverTrusted: false,
            alwaysAllowed: false,
            runsUnattended: false,
            descriptor: MCPToolDescriptor(
                originalName: plain.originalName, modelFacingName: plain.modelFacingName,
                displayDescription: plain.displayDescription, inputSchema: plain.inputSchema,
                outputSchema: nil, annotations: plain.annotations, headerParams: headerParams,
                callShapeDependsOnEra: callShapeDependsOnEra ?? !headerParams.isEmpty,
                pinHash: hash, rawTool: plain.rawTool, strippedHiddenCharacters: false),
            era: era)
    }

    private func index(
        _ entries: [MCPToolsSnapshot.Entry], statuses: [UUID: MCPServerStatus], revision: Int = 3
    ) -> MCPLiveCatalogueIndex {
        MCPLiveCatalogueIndex(MCPToolsSnapshot(
            entries: entries, statusByServerID: statuses, revision: revision))
    }

    private let connected = MCPServerStatus.connected(era: .modern)

    // MARK: - Published

    /// Same name, same server: the LIVE entry is handed back — it carries the policy the call
    /// runs under now, not the one the step froze.
    func testAToolItsServerStillPublishesStandsAsTheLiveEntry() throws {
        let live = try entry(approvalMode: .semiAutomatic)
        let standing = index([live], statuses: [Self.folioID: connected])
            .standing(of: try entry(approvalMode: .manual))
        XCTAssertEqual(standing, .published(current: live))
    }

    /// The text is the reader's to compare: the drift check compares the hashes and the gate
    /// hands both to the policy, whose step 0 denies a mismatch.
    func testARewrittenToolStillStandsAsPublished() throws {
        let live = try entry(hash: "h2")
        let standing = index([live], statuses: [Self.folioID: connected])
            .standing(of: try entry(hash: "h1"))
        XCTAssertEqual(standing, .published(current: live))
    }

    /// A tool whose schema carries `x-mcp-header` (`callShapeDependsOnEra`) is called
    /// differently in the two eras — only the modern one has the header channel — header
    /// parameters or not (a legacy listing admits none: the next test), so a step's frozen entry
    /// for it cannot be sent on a session that has since negotiated another era: gone for the
    /// step, as dispatch answers it. A tool whose schema carries none is called the same way in
    /// both, and stands as published.
    ///
    /// RED until 2026-10-28: the era was on nothing a step froze.
    func testAToolWithAHeaderIsChangedWhenItsServerNowSpeaksAnotherEra() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let legacy = MCPServerStatus.connected(era: .legacy)
        let liveWithHeader = try entry(era: .legacy, headerParams: [account])
        XCTAssertEqual(
            index([liveWithHeader], statuses: [Self.folioID: legacy])
                .standing(of: try entry(era: .modern, headerParams: [account])),
            .refused(.toolChanged))
        XCTAssertEqual(
            index([liveWithHeader], statuses: [Self.folioID: legacy])
                .standing(of: try entry(era: .legacy, headerParams: [account])),
            .published(current: liveWithHeader), "the same era stands as published")
        let livePlain = try entry(era: .legacy)
        XCTAssertEqual(
            index([livePlain], statuses: [Self.folioID: legacy]).standing(of: try entry(era: .modern)),
            .published(current: livePlain), "a tool with no header is called the same in both eras")
        // While its tool list is read again, too: a re-read cannot bring back a call assembled
        // for the other era.
        let rereading = MCPLiveCatalogueIndex(MCPToolsSnapshot(
            entries: [], statusByServerID: [Self.folioID: legacy],
            lastCommittedApprovalsOfUnverifiedServers: [Self.folioID: ["mcp__folio__get_metadata": "h1"]],
            revision: 3))
        XCTAssertEqual(rereading.standing(of: try entry(era: .modern, headerParams: [account])), .refused(.toolChanged))
        XCTAssertEqual(rereading.standing(of: try entry(era: .legacy, headerParams: [account])),
                       .refused(.toolsBeingReread))
    }

    /// A tool listed in a LEGACY session with an `x-mcp-header` annotation has no header
    /// parameter there — the keyword is the modern revision's — and is still called differently
    /// by era: once its server's session speaks the modern era, a step's frozen legacy entry is
    /// gone for the step, however the live entry reads (its pin is the same hash, since it is
    /// over what the server sent).
    ///
    /// RED until 2026-10-28: the era dependence was read off the header parameters, which a
    /// legacy listing no longer has, so the frozen body-only call went to a modern session — a
    /// request "Client omits header but value is in body".
    func testALegacyListedHeaderToolIsChangedOnceItsServerSpeaksModern() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let modernLive = try entry(era: .modern, headerParams: [account])
        let frozenLegacy = try entry(era: .legacy, headerParams: [], callShapeDependsOnEra: true)
        XCTAssertEqual(
            index([modernLive], statuses: [Self.folioID: connected]).standing(of: frozenLegacy),
            .refused(.toolChanged))
        let legacyLive = try entry(era: .legacy, headerParams: [], callShapeDependsOnEra: true)
        XCTAssertEqual(
            index([legacyLive], statuses: [Self.folioID: .connected(era: .legacy)]).standing(of: frozenLegacy),
            .published(current: legacyLive), "the same era stands as published")
    }

    /// The name agreeing is not enough: on another server it is another tool.
    func testTheSameNameOnAnotherServerIsRefusedAsChanged() throws {
        let impostor = try entry(serverID: Self.otherID)
        let standing = index(
            [impostor], statuses: [Self.folioID: connected, Self.otherID: connected])
            .standing(of: try entry())
        XCTAssertEqual(standing, .refused(.toolChanged))
    }

    // MARK: - Not published

    func testAToolItsConnectedServerNoLongerOffersIsRefusedAsChanged() throws {
        let standing = index([], statuses: [Self.folioID: connected]).standing(of: try entry())
        XCTAssertEqual(standing, .refused(.toolChanged))
    }

    /// Removed: its id never comes back, so the tool is gone for the rest of the step.
    func testAToolOfARemovedServerIsRefusedAsChanged() throws {
        let standing = index([], statuses: [Self.otherID: connected]).standing(of: try entry())
        XCTAssertEqual(standing, .refused(.toolChanged))
    }

    /// Between sessions, or failing in a way the connection retries on its own: `.connecting`,
    /// and `.failed`, which since 2026-09-23 always retries — a server failing at once, every
    /// time, is slowed to the backoff's last step, never stopped. These come back without
    /// anyone touching the server's settings, so the refusal leaves a later call open.
    ///
    /// The same for a frozen tool whose call shape depends on the era — a modern one with a
    /// header parameter, a legacy-listed one with the annotation: a server with no session speaks
    /// NO era, so there is nothing to compare its call against, and the refusal is the status's,
    /// never "changed" — which would withhold every such tool of a server for the rest of the
    /// step through a transient reconnect while dispatch answers "not connected".
    func testAToolOfAServerWithNoSessionIsRefusedAsNotConnected() throws {
        let statuses: [MCPServerStatus] = [.connecting, .failed(reason: "r")]
        for status in statuses {
            for frozen in try eraShapedEntries() {
                let standing = index([], statuses: [Self.folioID: status]).standing(of: frozen)
                XCTAssertEqual(standing, .refused(.serverNotConnected), "\(status), \(frozen.era)")
            }
        }
    }

    /// A plain frozen entry, a modern one with a header parameter, and a legacy-listed one whose
    /// call shape still depends on the era — the three a status refusal must answer alike.
    private func eraShapedEntries() throws -> [MCPToolsSnapshot.Entry] {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        return [
            try entry(),
            try entry(era: .modern, headerParams: [account]),
            try entry(era: .legacy, headerParams: [], callShapeDependsOnEra: true),
        ]
    }

    /// A rejected credential, a refused address, and a server that speaks nothing this client
    /// does — a protocol revision it cannot adopt, a catalogue past the frame ceiling or one
    /// that never stops paging — are terminal until a person edits the server: the connection
    /// retries none of them (`MCPServerConnection.recordFailure(_:)`). "Not connected — call it again later in this
    /// step" would invite a call that cannot succeed.
    ///
    /// RED until 2026-09-23 (A2 verification) for the first two; for `.incompatible` until the
    /// status could say so (group C, item 13) — it was a `.failed` like any other.
    func testAToolOfAServerThatNeedsAPersonIsRefusedAsNeedingAttention() throws {
        let statuses: [MCPServerStatus] = [
            .needsAuth(reason: "401"), .unsupportedTransport(reason: "http"), .incompatible(reason: "2027-01-01"),
        ]
        for status in statuses {
            for frozen in try eraShapedEntries() {
                let standing = index([], statuses: [Self.folioID: status]).standing(of: frozen)
                XCTAssertEqual(standing, .refused(.serverNeedsAttention), "\(status), \(frozen.era)")
            }
        }
    }

    /// `.disabled` is a person's switch: the manager reads it only for a server switched off
    /// app-wide or in this folder — a connection being restarted or replaced reads
    /// `.connecting` (`MCPServerManager`). Nothing in the step switches it back on.
    ///
    /// RED until 2026-09-23 (group C, item 13): a reconnect passed through `.disabled` too, so
    /// the rule could not tell the two apart and invited a later call to a server a person had
    /// switched off.
    func testAToolOfAServerSwitchedOffIsRefusedAsNeedingAttention() throws {
        for frozen in try eraShapedEntries() {
            let standing = index([], statuses: [Self.folioID: .disabled]).standing(of: frozen)
            XCTAssertEqual(standing, .refused(.serverNeedsAttention), "\(frozen.era)")
        }
    }

    // MARK: - A tool list being read again (group C, 2026-09-24)

    /// `rereading`: each server whose list is being read again, with what its last committed
    /// listing approved — model-facing name → pin hash.
    private func rereading(
        _ entries: [MCPToolsSnapshot.Entry], statuses: [UUID: MCPServerStatus],
        rereading: [UUID: [String: String]]
    ) -> MCPLiveCatalogueIndex {
        MCPLiveCatalogueIndex(MCPToolsSnapshot(
            entries: entries, statusByServerID: statuses,
            lastCommittedApprovalsOfUnverifiedServers: rereading, revision: 3))
    }

    private static let approvedAtH1 = ["mcp__folio__get_metadata": "h1"]

    /// A listing asked after the server's `list_changed`, or once its stated catalogue lifetime
    /// ran out, failed: none of its tools ships, and the rule says why — its list is being read
    /// again, and a listing that finds the tool unchanged brings it back within the step. Not
    /// `toolChanged`, which the connected-and-absent arm would give it.
    ///
    /// RED until 2026-09-24 (group C): refused as `toolChanged`.
    func testAToolOfAServerRereadingItsToolsIsRefusedAsBeingReread() throws {
        let standing = rereading([], statuses: [Self.folioID: connected], rereading: [Self.folioID: Self.approvedAtH1])
            .standing(of: try entry())
        XCTAssertEqual(standing, .refused(.toolsBeingReread))
    }

    /// Read BEFORE the published and changed checks: while the list is being read again nothing
    /// says which text the server serves, so an entry that still reads as published is not a
    /// policy a call may run under.
    func testTheRereadOutranksAnEntryThatStillReadsAsPublished() throws {
        let standing = rereading(
            [try entry()], statuses: [Self.folioID: connected], rereading: [Self.folioID: Self.approvedAtH1])
            .standing(of: try entry())
        XCTAssertEqual(standing, .refused(.toolsBeingReread))
    }

    // MARK: - Answered from the last committed listing (group C, C-5)

    /// While the list is being read again the answer is the verdict the app last COMMITTED: a
    /// tool that listing approved at the very text the step froze is being read again — a
    /// re-read that finds it unchanged brings it back within the step.
    func testAToolTheLastCommitApprovedAtTheFrozenTextIsBeingReread() throws {
        let standing = rereading(
            [], statuses: [Self.folioID: connected],
            rereading: [Self.folioID: ["mcp__folio__get_metadata": "h1"]])
            .standing(of: try entry(hash: "h1"))
        XCTAssertEqual(standing, .refused(.toolsBeingReread))
    }

    /// The last commit approved the name at ANOTHER text: the server had already rewritten it
    /// out of the approval the step froze, and the step had been told so. The re-read cannot
    /// make that call run in this step, so it stays changed rather than being invited back.
    ///
    /// RED until 2026-09-24 (group C, C-5): read as `toolsBeingReread` — "call it again later"
    /// about a tool already withheld for the rest of the step — then as changed again.
    func testAToolTheLastCommitApprovedAtAnotherTextStaysChanged() throws {
        let standing = rereading(
            [], statuses: [Self.folioID: connected],
            rereading: [Self.folioID: ["mcp__folio__get_metadata": "h2"]])
            .standing(of: try entry(hash: "h1"))
        XCTAssertEqual(standing, .refused(.toolChanged))
    }

    /// The last commit did not approve it at all — withdrawn by the server, awaiting review, or
    /// revoked by a person: changed, as it was before the list went into a re-read.
    ///
    /// RED until 2026-09-24 (group C, C-5).
    func testAToolTheLastCommitDidNotApproveStaysChanged() throws {
        let standing = rereading([], statuses: [Self.folioID: connected], rereading: [Self.folioID: [:]])
            .standing(of: try entry())
        XCTAssertEqual(standing, .refused(.toolChanged))
    }

    /// The name approved for ANOTHER server is another tool: only the called server's own
    /// last commit speaks for it.
    ///
    /// RED until 2026-09-24 (group C, C-5).
    func testTheSameNameApprovedForAnotherServerDoesNotHoldThisOne() throws {
        let standing = rereading(
            [], statuses: [Self.folioID: connected, Self.otherID: connected],
            rereading: [Self.folioID: [:], Self.otherID: Self.approvedAtH1])
            .standing(of: try entry())
        XCTAssertEqual(standing, .refused(.toolChanged))
    }

    /// Another server re-reading its list touches nothing of this one's.
    func testAnotherServersRereadLeavesThisToolPublished() throws {
        let live = try entry()
        let standing = rereading(
            [live], statuses: [Self.folioID: connected, Self.otherID: connected],
            rereading: [Self.otherID: [:]])
            .standing(of: try entry())
        XCTAssertEqual(standing, .published(current: live))
    }

    /// No live catalogue at all is a catalogue with no servers in it.
    func testTheEmptyCatalogueRefusesEveryToolAsChanged() throws {
        let standing = MCPLiveCatalogueIndex(.empty).standing(of: try entry())
        XCTAssertEqual(standing, .refused(.toolChanged))
    }

    /// The revision is carried, so a reader holding an index knows in one comparison whether
    /// the manager has rebuilt since.
    func testTheIndexCarriesTheRevisionItWasBuiltFrom() {
        XCTAssertEqual(index([], statuses: [:], revision: 41).revision, 41)
        XCTAssertEqual(MCPLiveCatalogueIndex(.empty).revision, MCPToolsSnapshot.empty.revision)
    }
}
