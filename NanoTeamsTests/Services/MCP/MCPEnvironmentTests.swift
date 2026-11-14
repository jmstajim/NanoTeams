import XCTest

@testable import NanoTeams

/// The DI seam, and the two production types that make an un-passed environment harmless.
final class MCPEnvironmentTests: XCTestCase {

    // MARK: - Inert

    /// A test or a preview that forgets the seam must get a process that CANNOT open a socket,
    /// rather than one that quietly does.
    func testTheInertTransportRefusesAtTheFirstStep() async {
        let transport = NeverConnectingTransport()
        do {
            try await transport.connect()
            XCTFail("the inert transport must not connect")
        } catch let error as MCPTransportError {
            guard case .endpointRefused = error else { return XCTFail("expected a refusal, got \(error)") }
        } catch {
            XCTFail("expected an MCPTransportError, got \(error)")
        }
    }

    func testTheInertTransportCarriesNothingAndEndsItsStreamAtOnce() async {
        let transport = NeverConnectingTransport()
        await transport.adopt(era: .modern, protocolVersion: MCPConstants.modernProtocolVersion)
        do {
            _ = try await transport.send(
                .notification(JSONRPCNotification(method: "x")), hints: .none)
            XCTFail("the inert transport carries nothing")
        } catch {
            XCTAssertEqual(error as? MCPTransportError, .notConnected)
        }
        var events: [MCPIncomingEvent] = []
        for await event in await transport.events() { events.append(event) }
        XCTAssertTrue(events.isEmpty)
        await transport.cancel(requestID: .number(1))
        await transport.close(budget: 0)
    }

    /// Distinct from `InMemorySecureTokenStorage`, which REMEMBERS: a preview that
    /// accidentally saves a token here loses it immediately, which is the point.
    func testTheInertStorageForgetsEverythingImmediately() throws {
        let storage = EmptySecureTokenStorage()
        try storage.setToken("t.SECRET", forKey: "k")
        XCTAssertNil(try storage.loadToken(forKey: "k"))
        XCTAssertNil(storage.token(forKey: "k"))
    }

    func testTheInertEnvironmentWritesNoLogAndHandsOutTheRefusingTransport() {
        let environment = MCPEnvironment.inert
        XCTAssertFalse(environment.writesRPCLog)
        XCTAssertFalse(environment.sweepsOrphanedSecrets, "a test or a preview never deletes from a Keychain")
        XCTAssertTrue(environment.secretStorage is EmptySecureTokenStorage)
        let transport = environment.makeTransport(
            MCPHTTPConfig(urlString: "https://x/mcp"), NoAuthorizer(), .standard)
        XCTAssertTrue(transport is NeverConnectingTransport)
    }

    // MARK: - Live

    /// The live environment is what the running app uses, so its pieces are asserted rather
    /// than assumed: a Keychain scoped to MCP's own service, a real Streamable HTTP transport,
    /// and the frame log on.
    func testTheLiveEnvironmentUsesTheRealPieces() throws {
        let environment = MCPEnvironment.live
        XCTAssertTrue(environment.writesRPCLog)
        XCTAssertTrue(environment.sweepsOrphanedSecrets, "the app's own manager sweeps what no server reads")
        let keychain = try XCTUnwrap(environment.secretStorage as? KeychainSecureTokenStorage)
        XCTAssertEqual(keychain.service, MCPConstants.keychainService)
        XCTAssertEqual(environment.trustDirectory, MCPServerCatalogueStore.defaultDirectory)
        let transport = environment.makeTransport(
            MCPHTTPConfig(urlString: "https://x/mcp"), NoAuthorizer(), .standard)
        XCTAssertTrue(transport is StreamableHTTPTransport)
    }

    // MARK: - Registry

    /// The invoker is not the manager: a tool call runs off the main actor, and routing it
    /// through observable UI state would put a main-actor hop in every call.
    /// A server with no route has no session a call could reach — reconnecting, failing,
    /// switched off. Not an `MCPClientError`: nothing was sent and no server answered.
    func testTheRegistryRefusesACallForAServerItDoesNotHold() async {
        let registry = MCPClientRegistry()
        XCTAssertTrue(registry.connectedServerIDs.isEmpty)
        await assertRefused(
            registry, MCPToolCall(
                serverID: UUID(), toolName: "x", expectedHash: "h", arguments: .object([:]),
                headerParameters: [:], era: nil),
            as: .serverNotConnected)
    }

    func testTheRegistryRoutesToTheClientItWasGiven() async throws {
        let (client, transport) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.publish(client, approvedHashes: ["get_metadata": "h1"], era: .modern, for: serverID)
        XCTAssertEqual(registry.connectedServerIDs, [serverID])

        let result = try await registry.callTool(call(serverID, expectedHash: "h1"))
        XCTAssertEqual(result.contentBlocks.first?.objectValue?["text"], .string("ok"))
        XCTAssertEqual(sentToolCalls(transport), 1)

        registry.removeAll()
        XCTAssertTrue(registry.connectedServerIDs.isEmpty)
    }

    // MARK: - The text a call was made against (F21)

    /// The server publishes the tool at another text than the one the call was made against:
    /// it rewrote it after the step's last check. Refused before anything is sent.
    func testTheRegistryRefusesACallMadeAgainstAnotherTextOfTheTool() async throws {
        let (client, transport) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.publish(client, approvedHashes: ["get_metadata": "h2"], era: .modern, for: serverID)

        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .toolChanged)
        XCTAssertEqual(sentToolCalls(transport), 0)
    }

    /// A call assembled for one protocol revision — the split of a tool whose schema carries
    /// `x-mcp-header` depends on it, header parameters or not — is refused on a session that
    /// negotiated another: sending it would
    /// send a shape the person did not see on the card. A call whose shape does not depend on the
    /// era (`era == nil`) goes out on either.
    ///
    /// RED until 2026-10-28: the route did not know its session's era.
    func testTheRegistryRefusesACallAssembledForAnotherEra() async throws {
        let (client, transport) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.publish(client, approvedHashes: ["get_metadata": "h1"], era: .legacy, for: serverID)

        await assertRefused(registry, call(serverID, expectedHash: "h1", era: .modern), as: .toolChanged)
        XCTAssertEqual(sentToolCalls(transport), 0, "nothing was sent")

        _ = try await registry.callTool(call(serverID, expectedHash: "h1", era: .legacy))
        _ = try await registry.callTool(call(serverID, expectedHash: "h1", era: nil))
        XCTAssertEqual(sentToolCalls(transport), 2, "the matching era and an era-free call go out")

        // The era is asked BEFORE the re-read mark: a call assembled for another era is refused as
        // changed even while the route's catalogue is being read again — the answer the live
        // index gives the gate for the same call (`MCPLiveCatalogueIndex.standing`), so the gate
        // and the dispatch agree.
        registry.publish(client, approvedHashes: ["get_metadata": "h1"], catalogueUnverified: true, era: .legacy, for: serverID)
        await assertRefused(registry, call(serverID, expectedHash: "h1", era: .modern), as: .toolChanged)
        await assertRefused(registry, call(serverID, expectedHash: "h1", era: .legacy), as: .toolsBeingReread)
        XCTAssertEqual(sentToolCalls(transport), 2, "nothing more was sent")
    }

    /// `HeaderMismatch` is the spec's `-32020`, spelled as a LITERAL here: every other test names
    /// the code by `MCPErrorCode.headerMismatch`, so a constant moved off the spec's number moved
    /// their scripts with it. The source: 2026-07-28, Streamable
    /// HTTP, "Server Validation" — "`-32020` | `HeaderMismatch` | The HTTP headers do not match the
    /// corresponding values in the request body, or required headers are missing/malformed."
    /// (modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http, read
    /// 2026-10-28). Its two neighbours the revision also allocates, likewise literal and under
    /// the spec's own names (basic/index, "Error Codes"): `-32021` is
    /// `MissingRequiredClientCapability` — named `invalidState`, "a frame the server cannot
    /// accept in its current state", until 2026-10-28 — and `-32022`
    /// `UnsupportedProtocolVersion`.
    func testTheProtocolDefinedCodesAreTheSpecsNumbers() {
        XCTAssertEqual(MCPErrorCode.headerMismatch, -32020)
        XCTAssertEqual(MCPErrorCode.missingRequiredClientCapability, -32021)
        XCTAssertEqual(MCPErrorCode.unsupportedProtocolVersion, -32022)
    }

    /// A server that answers a call `HeaderMismatch` (-32020) is asked for its tool list again —
    /// "the client SHOULD call `tools/list` to check for changes to the tool's `inputSchema`"
    /// (2026-07-28, Streamable HTTP, "Client Behavior") — through the hook its connection
    /// published with the route; the refusal itself still reaches the caller. Any other error
    /// asks nothing — its two neighbours of the revision above all: `-32021`, a capability the
    /// call needs and the client never declares, and `-32022`, a protocol version the server
    /// refuses, which it refuses on `tools/list` as well, so a re-read would only fail and
    /// withhold every tool of the server for a false reason. The codes are the spec's literals,
    /// so a constant moved off its number cannot move this table with it.
    ///
    /// RED until 2026-10-28: a HeaderMismatch read as any other tool error, and nothing
    /// looked at the list.
    func testAHeaderMismatchAsksTheConnectionToReadItsToolListAgain() async throws {
        for (code, asks) in [(-32020, true), (-32021, false), (-32022, false), (-32602, false), (-32601, false)] {
            let transport = ScriptedTransport()
            transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
            transport.script(MCPWire.toolsCallMethod, [.error(code: code, message: "header does not match body")])
            let client = MCPClient(
                transport: transport, log: nil,
                timeouts: MCPTimeouts(connect: 1, requestInactivity: 2, requestAbsolute: 2), clientVersion: "1.0")
            _ = try await client.connect(cachedEra: nil)
            let asked = MismatchCounter()
            let registry = MCPClientRegistry()
            let serverID = UUID()
            registry.publish(client, approvedHashes: ["get_metadata": "h1"], era: .modern, for: serverID,
                             onHeaderMismatch: { asked.bump() })
            do {
                _ = try await registry.callTool(call(serverID, expectedHash: "h1"))
                XCTFail("\(code): the server's refusal must reach the caller")
            } catch MCPClientError.rpc(let answered, _, _) {
                XCTAssertEqual(answered, code)
            }
            XCTAssertEqual(asked.count, asks ? 1 : 0, "\(code)")
            await client.close(budget: 0)
        }
    }

    /// Withdrawn by the server, or its approval revoked: not published as approved at all.
    func testTheRegistryRefusesACallToAToolItDoesNotPublishAsApproved() async throws {
        let (client, transport) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.publish(client, approvedHashes: [:], era: .modern, for: serverID)

        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .toolChanged)
        XCTAssertEqual(sentToolCalls(transport), 0)
    }

    /// The approvals move while the session stays: an update reaches the next call, and a
    /// server with no route is not given one by it.
    func testUpdatingTheApprovedTextsMovesTheCheckButNeverOpensARoute() async throws {
        let (client, _) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.updateApprovedHashes(["get_metadata": "h1"], for: serverID, through: client)
        XCTAssertTrue(registry.connectedServerIDs.isEmpty, "approving a tool never opens a route")

        registry.publish(client, approvedHashes: ["get_metadata": "h1"], era: .modern, for: serverID)
        registry.updateApprovedHashes([:], for: serverID, through: client)
        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .toolChanged)

        registry.updateApprovedHashes(["get_metadata": "h1"], for: serverID, through: client)
        _ = try await registry.callTool(call(serverID, expectedHash: "h1"))
    }

    /// A write through a session that is not the route's own — a connection an edit replaced,
    /// a listing that landed late — changes nothing, in either direction: the replaced
    /// session's approvals are of the text IT listed, and the server may since have rewritten
    /// it for the session that now holds the route.
    func testAnUpdateThroughAnotherSessionLeavesTheRouteAlone() async throws {
        let (client, _) = try await connectedClient()
        let (replaced, _) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.publish(client, approvedHashes: [:], era: .modern, for: serverID)

        registry.updateApprovedHashes(["get_metadata": "h1"], for: serverID, through: replaced)
        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .toolChanged)

        registry.updateApprovedHashes(["get_metadata": "h1"], for: serverID, through: client)
        registry.updateApprovedHashes([:], for: serverID, through: replaced)
        _ = try await registry.callTool(call(serverID, expectedHash: "h1"))
    }

    /// A route whose catalogue is unverified refuses every call, and sends nothing: a call at
    /// a hash its last committed listing approved as a tool list being read again. The mark is
    /// set and cleared through the session that owns the route, and only through that one, in
    /// the same write as the hashes, so no call can meet new hashes without the mark or the
    /// reverse.
    ///
    /// RED until 2026-09-24 (group C): the connection emptied the route's hashes instead, and
    /// the call was refused as `toolChanged`.
    func testAnUnverifiedRouteRefusesAnApprovedTextAsBeingRereadAndSendsNothing() async throws {
        let (client, transport) = try await connectedClient()
        let (replaced, _) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.publish(
            client, approvedHashes: ["get_metadata": "h1"], catalogueUnverified: true, era: .modern, for: serverID)

        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .toolsBeingReread)
        XCTAssertEqual(sentToolCalls(transport), 0)

        registry.updateApprovedHashes(
            ["get_metadata": "h1"], catalogueUnverified: false, for: serverID, through: replaced)
        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .toolsBeingReread)

        registry.updateApprovedHashes(
            ["get_metadata": "h1"], catalogueUnverified: false, for: serverID, through: client)
        _ = try await registry.callTool(call(serverID, expectedHash: "h1"))
        XCTAssertEqual(sentToolCalls(transport), 1)

        registry.updateApprovedHashes(
            ["get_metadata": "h1"], catalogueUnverified: true, for: serverID, through: client)
        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .toolsBeingReread)
        XCTAssertEqual(sentToolCalls(transport), 1)
    }

    /// The route keeps its last committed hashes while its list is being read again, and reads
    /// them FIRST: a call at a text that listing did not approve — rewritten out of its
    /// approval, withdrawn, revoked by a person — is refused as changed, the verdict the app
    /// had already committed and the one the gate gives it (`MCPLiveCatalogueIndex`). Only a
    /// call at an approved text is told the list is being read again, since a re-read that
    /// finds it unchanged is the only thing that lets it run within the step.
    ///
    /// RED until 2026-09-24 (group C, C-5): the mark was read first, so a tool the step had
    /// already been told was withheld for the rest of it was invited back while the list was
    /// being read — and refused as changed again the moment the read committed.
    func testAnUnverifiedRouteAnswersAHashItsLastCommitDidNotApproveAsChanged() async throws {
        let (client, transport) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.publish(
            client, approvedHashes: ["get_metadata": "h1"], catalogueUnverified: true, era: .modern, for: serverID)

        await assertRefused(registry, call(serverID, expectedHash: "h9"), as: .toolChanged)
        let absent = MCPToolCall(
            serverID: serverID, toolName: "get_whiteboard", expectedHash: "h1",
            arguments: .object([:]), headerParameters: [:], era: nil)
        await assertRefused(registry, absent, as: .toolChanged)
        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .toolsBeingReread)

        registry.updateApprovedHashes([:], catalogueUnverified: true, for: serverID, through: client)
        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .toolChanged)
        XCTAssertEqual(sentToolCalls(transport), 0)
    }

    func testWithdrawingARouteRefusesTheNextCallAsNotConnected() async throws {
        let (client, _) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.publish(client, approvedHashes: ["get_metadata": "h1"], era: .modern, for: serverID)
        registry.withdraw(serverID: serverID, through: client)
        XCTAssertTrue(registry.connectedServerIDs.isEmpty)
        await assertRefused(registry, call(serverID, expectedHash: "h1"), as: .serverNotConnected)
    }

    /// A session withdraws only the route it opened. A connection replaced by an edit ends its
    /// session late — after its successor published — and removing the route by server id
    /// alone wiped the successor's: every call to a healthy server refused as not connected.
    ///
    /// RED until 2026-09-23 (A2 verification, item 12): the withdrawal was keyed by server id.
    func testAWithdrawalThroughAnotherSessionLeavesTheRouteAlone() async throws {
        let (successor, transport) = try await connectedClient()
        let (replaced, _) = try await connectedClient()
        let registry = MCPClientRegistry()
        let serverID = UUID()
        registry.publish(successor, approvedHashes: ["get_metadata": "h1"], era: .modern, for: serverID)

        registry.withdraw(serverID: serverID, through: replaced)

        XCTAssertEqual(registry.connectedServerIDs, [serverID])
        _ = try await registry.callTool(call(serverID, expectedHash: "h1"))
        XCTAssertEqual(sentToolCalls(transport), 1, "the successor's route still carries calls")
    }

    // MARK: - The reconnect policy

    /// The app's policy is the constants', and the table's last step is where a crash-looping
    /// server settles.
    func testTheStandardPolicyIsTheConstants() {
        let policy = MCPReconnectPolicy.standard
        XCTAssertEqual(policy.backoff, MCPConstants.reconnectBackoff)
        XCTAssertEqual(policy.crashLoopFailureCount, MCPConstants.crashLoopFailureCount)
        XCTAssertEqual(policy.crashLoopWindow, MCPConstants.crashLoopWindow)
        XCTAssertEqual(policy.longestDelay, MCPConstants.reconnectBackoff.last)
        XCTAssertEqual(MCPEnvironment.live.reconnectPolicy, .standard)
        XCTAssertEqual(MCPEnvironment.inert.reconnectPolicy, .standard)
    }

    /// Past the table the last step repeats — never an index out of range, never a stop — and
    /// an index below zero reads as the first step.
    func testTheDelayWalksTheTableAndRepeatsItsLastStep() {
        let policy = MCPReconnectPolicy(backoff: [1, 2, 4], crashLoopFailureCount: 3, crashLoopWindow: 5)
        XCTAssertEqual((0..<6).map { policy.delay(afterFailure: $0) }, [1, 2, 4, 4, 4, 4])
        XCTAssertEqual(policy.delay(afterFailure: -1), 1)
    }

    /// A degenerate policy still has a step and a breaker: an empty table retries at once
    /// rather than crashing on an empty index, and a count below one is one.
    func testADegeneratePolicyIsMadeUsable() {
        let policy = MCPReconnectPolicy(backoff: [], crashLoopFailureCount: 0, crashLoopWindow: 5)
        XCTAssertEqual(policy.backoff, [0])
        XCTAssertEqual(policy.delay(afterFailure: 3), 0)
        XCTAssertEqual(policy.crashLoopFailureCount, 1)
    }

    // MARK: - Fixtures

    private func connectedClient() async throws -> (MCPClient, ScriptedTransport) {
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        transport.script(MCPWire.toolsCallMethod, [.result(.object([
            "content": .array([.object(["type": .string("text"), "text": .string("ok")])]),
        ]))])
        let client = MCPClient(
            transport: transport, log: nil,
            timeouts: MCPTimeouts(connect: 1, requestInactivity: 2, requestAbsolute: 2),
            clientVersion: "1.0")
        _ = try await client.connect(cachedEra: nil)
        return (client, transport)
    }

    private func call(_ serverID: UUID, expectedHash: String, era: MCPProtocolEra? = nil) -> MCPToolCall {
        MCPToolCall(
            serverID: serverID, toolName: "get_metadata", expectedHash: expectedHash,
            arguments: .object([:]), headerParameters: [:], era: era)
    }

    private func sentToolCalls(_ transport: ScriptedTransport) -> Int {
        transport.sent.count { $0.method == MCPWire.toolsCallMethod }
    }

    private func assertRefused(
        _ registry: MCPClientRegistry, _ call: MCPToolCall, as expected: MCPDispatchRefusal,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await registry.callTool(call)
            XCTFail("the call must be refused as \(expected)", file: file, line: line)
        } catch let refusal as MCPDispatchRefusal {
            XCTAssertEqual(refusal, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

/// Counts how often a route's HeaderMismatch hook ran — from whichever task the call ran on.
private final class MismatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}
