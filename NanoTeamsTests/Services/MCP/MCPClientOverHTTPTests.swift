import XCTest

@testable import NanoTeams

/// The whole stack, end to end: `MCPClient` → `StreamableHTTPTransport` → a real `URLSession`
/// → a socket → an HTTP server in this process, and back.
///
/// The scripted doubles cut the stack at a seam, which is what makes them precise — and is
/// also what they cannot test. Everything between those seams is where a real client breaks:
/// a header the server rejects, an SSE body terminated by connection close rather than by
/// length, a 202 with no body at all.
final class MCPClientOverHTTPTests: XCTestCase {

    private var server: FakeMCPHTTPServer!
    private var session: MCPURLSession!
    private var client: MCPClient!

    override func tearDown() {
        server?.stop()
        server = nil
        session = nil
        client = nil
        super.tearDown()
    }

    /// Starts a server, points a real client at it, and returns what the handshake settled on.
    @discardableResult
    private func connect(
        mode: FakeMCPHTTPServer.Mode,
        authorizer: (any MCPAuthorizer)? = nil,
        timeouts: MCPTimeouts = MCPTimeouts(connect: 5, requestInactivity: 5, requestAbsolute: 10),
        cachedEra: MCPProtocolEra? = nil
    ) async throws -> MCPConnection {
        server = try FakeMCPHTTPServer(mode: mode)
        let port = try await server.start()
        session = MCPURLSession(timeouts: timeouts)
        let transport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: server.url(port: port)),
            authorizer: authorizer ?? NoAuthorizer(),
            session: session,
            timeouts: timeouts)
        client = MCPClient(transport: transport, log: nil, timeouts: timeouts, clientVersion: "1.0")
        return try await client.connect(cachedEra: cachedEra)
    }

    // MARK: - Round trips

    func testAModernServerConnectsListsAndCalls() async throws {
        let connection = try await connect(mode: .modern)
        XCTAssertEqual(connection.era, .modern)
        XCTAssertEqual(connection.serverInfo.name, "fake")

        let tools = try await client.listAllTools()
        XCTAssertEqual(tools.compactMap { $0.objectValue?["name"]?.stringValue }, ["get_metadata"])

        let result = try await client.callTool(originalName: "get_metadata", arguments: .object([:]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.contentBlocks.first?.objectValue?["text"], .string("called"))

        // The version header is on the wire, not just in the builder's unit test.
        let versions = server.requests.compactMap { $0.header(MCPConstants.protocolVersionHeader) }
        XCTAssertEqual(Set(versions), [MCPConstants.modernProtocolVersion])
    }

    func testALegacyServerConnectsAndEveryLaterRequestCarriesTheSession() async throws {
        for mode in [FakeMCPHTTPServer.Mode.legacy, .legacyStrict] {
            defer {
                server?.stop()
                server = nil
                session = nil
                client = nil
            }
            let connection = try await connect(mode: mode)
            XCTAssertEqual(connection.era, .legacy, "\(mode)")
            XCTAssertEqual(connection.serverInfo.name, "fake-legacy", "\(mode)")

            _ = try await client.listAllTools()
            let posts = server.requests.filter { $0.httpMethod == "POST" }
            // discover (refused), initialize, initialized, tools/list
            XCTAssertGreaterThanOrEqual(posts.count, 4, "\(mode)")
            let initialize = try XCTUnwrap(posts.first { $0.rpcMethod == MCPWire.initializeMethod }, "\(mode)")
            XCTAssertNil(initialize.header(MCPConstants.protocolVersionHeader),
                         "\(mode): initialize is the legacy opening and carries no MCP-Protocol-Version header")
            XCTAssertNil(initialize.header("Mcp-Method"),
                         "\(mode): initialize is the legacy opening and carries no Mcp-Method header")
            let afterHandshake = posts.drop { $0.rpcMethod != MCPWire.initializedNotification }
            XCTAssertFalse(afterHandshake.isEmpty, "\(mode)")
            XCTAssertTrue(
                afterHandshake.allSatisfy { $0.header("mcp-session-id") == server.issuedSessionID },
                "\(mode): every request after the handshake carries the session the server issued")
            XCTAssertTrue(
                afterHandshake.allSatisfy {
                    $0.header(MCPConstants.protocolVersionHeader) == MCPConstants.legacyProtocolVersion
                },
                "\(mode): every POST after initialize carries the negotiated protocol version")
            XCTAssertTrue(
                afterHandshake.allSatisfy { $0.header("Mcp-Method") == nil },
                "\(mode): legacy requests carry no Mcp-Method header")
            await client.close(budget: 0)
        }
    }

    /// One POST answering with progress and then the result is the shape a single JSON reply
    /// cannot express, and the reason `send` never returns the reply.
    func testAStreamedToolCallDeliversProgressAndThenTheResult() async throws {
        try await connect(mode: .streamingTool)
        let result = try await client.callTool(originalName: "get_metadata", arguments: .object([:]))
        XCTAssertEqual(result.contentBlocks.first?.objectValue?["text"], .string("streamed"))
    }

    /// A header parameter whose value is the empty string reaches a real socket as a header line
    /// with an empty value — `Mcp-Param-Id: ` — not dropped. The spec's table: "Parameter value
    /// provided — Client MUST include the header", and an empty string is a value provided; RFC
    /// 9110's field-value is `*field-content`, which may be empty, and the empty string holds no
    /// character that needs the Base64 sentinel, so it goes as itself. URLSession sends it (probed
    /// on a loopback socket, 2026-10-28); this pins that from the client down — the transport and
    /// URLSession onto a real socket — so a transport or platform change that drops it shows up
    /// here rather than as a server's HeaderMismatch. That the coercion includes the header at all
    /// is `MCPArgumentCoercionTests` and, from the model's document, `MCPDynamicToolTests`.
    func testAnEmptyHeaderParameterValueReachesTheSocketAsAnEmptyHeader() async throws {
        try await connect(mode: .modern)
        _ = try await client.callTool(
            originalName: "get_metadata", arguments: .object(["id": .string("")]),
            headerParameters: ["Mcp-Param-Id": "", "Mcp-Param-Region": "eu"])
        let call = try XCTUnwrap(server.requests.last { $0.rpcMethod == MCPWire.toolsCallMethod })
        XCTAssertEqual(call.header("Mcp-Param-Id"), "", "the empty value was not sent as an empty header")
        XCTAssertEqual(call.header("Mcp-Param-Region"), "eu", "anti-vacuum: a header parameter reaches the socket")
    }

    // MARK: - The conforming fake

    /// One request as the conforming check reads it: the headers a client wrote and the body.
    private func refusal(
        _ headers: [String: String], _ body: [String: Any]
    ) throws -> ConformingMCPServerCheck.Refusal? {
        let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        return ConformingMCPServerCheck.refusal(
            header: { lowered[$0.lowercased()] },
            body: try JSONSerialization.data(withJSONObject: body),
            toolHeaderParameters: ["get_metadata": FakeMCPHTTPServer.defaultToolHeaderParameters])
    }

    private static var envelope: [String: Any] {
        [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": [String: Any](),
        ]
    }

    private static func request(
        _ method: String, meta: [String: Any]? = envelope, name: String? = nil,
        arguments: [String: Any]? = nil, id: Any? = 1
    ) -> [String: Any] {
        var params: [String: Any] = [:]
        if let meta { params["_meta"] = meta }
        if let name { params["name"] = name }
        if let arguments { params["arguments"] = arguments }
        var frame: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { frame["id"] = id }
        return frame
    }

    /// The fakes' conforming mode is what the modern round trips here prove anything with, so
    /// it is pinned to refuse what a 2026-07-28 server refuses (basic/index "Per-request protocol
    /// fields"; streamable-http "Server Validation") and to read what such a server reads: a
    /// request missing a required `_meta` key → `400` + `-32602`; a header that disagrees with
    /// the body → `400` + `-32020`; a legacy request and a notification are not its business.
    func testTheConformingCheckRefusesWhatAModernServerRefuses() throws {
        let modern = ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "server/discover"]
        XCTAssertNil(try refusal(modern, Self.request("server/discover")), "a well-formed probe is read")

        let malformed: [(String, [String: Any])] = [
            ("the bare keys this client once wrote",
             Self.request("server/discover", meta: ["protocolVersion": "2026-07-28", "capabilities": [String: Any]()])),
            ("no envelope at all", Self.request("server/discover", meta: nil)),
            ("no capabilities", Self.request("server/discover", meta: ["io.modelcontextprotocol/protocolVersion": "2026-07-28"])),
            ("capabilities that are not an object", Self.request("server/discover", meta: [
                "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": "all",
            ])),
            // Deliberately stricter than a dual-era server (where `initialize` selects legacy
            // semantics regardless of headers): holds the client to never sending modern headers on `initialize` (D-M8).
            ("an initialize sent with the modern header — client guard, stricter than a dual-era server",
             Self.request("initialize", meta: nil)),
        ]
        for (label, body) in malformed {
            let refused = try XCTUnwrap(try refusal(modern, body), label)
            XCTAssertEqual(refused.status, 400, label)
            XCTAssertEqual(refused.code, -32602, label)
        }

        let mismatched: [(String, [String: String], [String: Any])] = [
            ("an envelope naming another revision", modern, Self.request("server/discover", meta: [
                "io.modelcontextprotocol/protocolVersion": "2027-01-01", "io.modelcontextprotocol/clientCapabilities": [String: Any](),
            ])),
            ("a modern envelope with no MCP-Protocol-Version header",
             ["Mcp-Method": "server/discover"],
             Self.request("server/discover")),
            ("a modern envelope with a legacy MCP-Protocol-Version header",
             ["MCP-Protocol-Version": "2025-11-25", "Mcp-Method": "server/discover"],
             Self.request("server/discover")),
            ("no Mcp-Method", ["MCP-Protocol-Version": "2026-07-28"], Self.request("server/discover")),
            ("another Mcp-Method", ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"],
             Self.request("server/discover")),
            ("a tools/call with no Mcp-Name", ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call"],
             Self.request("tools/call", name: "get_metadata")),
            ("a tools/call naming another tool",
             ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_screenshot"],
             Self.request("tools/call", name: "get_metadata")),
            ("a tools/call omitting a declared Mcp-Param-* header when its value is in arguments",
             ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_metadata"],
             Self.request("tools/call", name: "get_metadata", arguments: ["id": "42"])),
            ("a tools/call whose Mcp-Param-* header disagrees with arguments",
             ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_metadata",
              "Mcp-Param-Id": "99"],
             Self.request("tools/call", name: "get_metadata", arguments: ["id": "42"])),
            ("a tools/call sending a declared Mcp-Param-* header when its value is null in arguments",
             ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_metadata",
              "Mcp-Param-Id": "42"],
             Self.request("tools/call", name: "get_metadata", arguments: ["id": NSNull()])),
        ]
        for (label, headers, body) in mismatched {
            let refused = try XCTUnwrap(try refusal(headers, body), label)
            XCTAssertEqual(refused.status, 400, label)
            XCTAssertEqual(refused.code, -32020, label)
        }

        let read: [(String, [String: String], [String: Any])] = [
            ("a name sent as the Base64 sentinel",
             ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "=?base64?w6l0w6k=?="],
             Self.request("tools/call", name: "été")),
            ("a tools/call mirroring a declared Mcp-Param-* header",
             ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_metadata",
              "Mcp-Param-Id": "42"],
             Self.request("tools/call", name: "get_metadata", arguments: ["id": "42"])),
            ("a tools/call mirroring a non-ASCII Mcp-Param-* header as the Base64 sentinel",
             ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_metadata",
              "Mcp-Param-Id": "=?base64?w6l0w6k=?="],
             Self.request("tools/call", name: "get_metadata", arguments: ["id": "été"])),
            ("a legacy request", ["MCP-Protocol-Version": "2025-11-25"], Self.request("tools/list", meta: nil)),
            // The legacy opening carries no version header at all.
            ("an initialize with no version header", [:], Self.request("initialize", meta: nil)),
            ("a modern notification", ["MCP-Protocol-Version": "2026-07-28"],
             Self.request("notifications/initialized", meta: nil, id: nil)),
        ]
        for (label, headers, body) in read {
            XCTAssertNil(try refusal(headers, body), label)
        }
    }

    /// The same check on the socket: the conforming fake answers a modern request without the
    /// envelope `400` and the JSON-RPC error `-32602` for its id, before the method is answered
    /// — and the legacy fake, which knows no 2026-07-28 rule, answers the same request as an
    /// unknown method.
    func testTheFakeServerRefusesAModernRequestWithoutItsEnvelopeOnTheSocket() async throws {
        for mode in [FakeMCPHTTPServer.Mode.modern, .legacy] {
            let fake = try FakeMCPHTTPServer(mode: mode)
            defer { fake.stop() }
            let port = try await fake.start()
            var request = URLRequest(url: try XCTUnwrap(URL(string: fake.url(port: port))))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue("server/discover", forHTTPHeaderField: "Mcp-Method")
            request.httpBody = try JSONSerialization.data(withJSONObject: Self.request(
                "server/discover", meta: ["protocolVersion": "2026-07-28", "capabilities": [String: Any]()], id: 7))
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            let frame = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let error = try XCTUnwrap(frame["error"] as? [String: Any], "\(mode)")
            XCTAssertEqual(frame["id"] as? Int, 7, "\(mode)")
            switch mode {
            case .modern:
                XCTAssertEqual(status, 400)
                XCTAssertEqual(error["code"] as? Int, -32602)
            default:
                XCTAssertEqual(status, 200)
                XCTAssertEqual(error["code"] as? Int, -32601, "a legacy server does not know the method")
            }
        }
    }

    /// On the socket, the conforming fake refuses a modern envelope sent without its matching
    /// `MCP-Protocol-Version` header and a `tools/call` whose `Mcp-Param-Id` header is missing or
    /// disagrees with `params.arguments.id` (`400` + `-32020`, D-M9 pt. 1).
    func testTheFakeServerRefusesHeaderMismatchesOnTheSocket() async throws {
        let fake = try FakeMCPHTTPServer(mode: .modern)
        defer { fake.stop() }
        let port = try await fake.start()
        let endpoint = try XCTUnwrap(URL(string: fake.url(port: port)))

        let cases: [(String, [String: String], [String: Any])] = [
            ("modern envelope without MCP-Protocol-Version header",
             ["Mcp-Method": "server/discover"],
             Self.request("server/discover", id: 8)),
            ("tools/call omitting declared Mcp-Param-Id header",
             ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_metadata"],
             Self.request("tools/call", name: "get_metadata", arguments: ["id": "42"], id: 9)),
            ("tools/call with mismatched Mcp-Param-Id header",
             ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_metadata",
              "Mcp-Param-Id": "99"],
             Self.request("tools/call", name: "get_metadata", arguments: ["id": "42"], id: 10)),
        ]
        for (label, headers, body) in cases {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            let frame = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], label)
            let error = try XCTUnwrap(frame["error"] as? [String: Any], label)
            XCTAssertEqual(status, 400, label)
            XCTAssertEqual(error["code"] as? Int, -32020, label)
        }
    }

    // MARK: - Failure paths

    /// At a tenth of the scale it ran at until 2026-10-28 (connect 5 s, so the probe and
    /// `initialize` cost ten real seconds), through the test-only unclamped budgets.
    func testASilentServerEndsAtTheTimeoutRatherThanHanging() async {
        do {
            try await connect(
                mode: .hang,
                timeouts: MCPTimeouts(unclampedConnect: 0.5, requestInactivity: 0.2, requestAbsolute: 0.2))
            XCTFail("a server that never answers cannot connect")
        } catch MCPClientError.timedOut {
            // expected
        } catch MCPClientError.transport(.timedOut) {
            // also expected: whichever ceiling fires first
        } catch {
            XCTFail("expected a timeout, got \(error)")
        }
    }

    /// A body that is not JSON is a malformed frame, not a protocol error and not a hang.
    func testAServerAnsweringGarbageFailsLoudly() async {
        do {
            try await connect(mode: .garbage)
            XCTFail("a non-JSON body is not a handshake")
        } catch {
            // Reached through either arm — the probe's malformed reply, or the legacy
            // fallback's. What matters is that it is typed and fast.
            XCTAssertTrue(error is MCPClientError, "\(error)")
        }
    }

    func testAnUnauthorizedServerIsReportedAsACredentialProblem() async {
        do {
            try await connect(mode: .unauthorized)
            XCTFail("401 is not a handshake")
        } catch MCPClientError.transport(.unauthorized(let status, let challenge)) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(challenge?.contains("realm") ?? false, challenge ?? "")
        } catch {
            XCTFail("expected an unauthorized transport failure, got \(error)")
        }
    }

    /// The credential actually reaches the socket — the half a unit test on the authorizer
    /// cannot see.
    func testTheBearerTokenArrivesOnTheWire() async throws {
        let storage = InMemorySecureTokenStorage()
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("trade_room")), displayName: "T",
            transport: .http(MCPHTTPConfig(urlString: "https://placeholder/mcp", authorization: .staticBearer)))
        try storage.setToken("t.LIVE-TOKEN", forKey: config.bearerSecretKey)

        try await connect(mode: .modern, authorizer: StaticBearerAuthorizer.make(config: config, storage: storage))
        XCTAssertEqual(server.requests.first?.header("authorization"), "Bearer t.LIVE-TOKEN")
    }

    /// The server forgot the session. Reported as `.sessionLost` rather than as a 404, because
    /// the repair is to re-initialize rather than to fix the URL.
    func testALegacyServerThatForgetsItsSessionSaysSo() async throws {
        try await connect(mode: .legacy)
        server.forgetsSession = true
        do {
            _ = try await client.listAllTools()
            XCTFail("a forgotten session is not an empty catalogue")
        } catch MCPClientError.transport(.sessionLost) {
            // expected
        }
    }

    /// A catalogue that changed between two listings is what the manager re-pins against.
    func testARefreshSeesTheServersNewCatalogue() async throws {
        try await connect(mode: .modern)
        let before = try await client.listAllTools()
        XCTAssertEqual(before.count, 1)
        server.toolNames = ["get_metadata", "get_screenshot"]
        let names = try await client.listAllTools().compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertEqual(names, ["get_metadata", "get_screenshot"])
    }

    /// A cached era saves the probe round trip, and over a real socket that is the whole point.
    func testACachedLegacyEraSkipsTheProbeOverARealConnection() async throws {
        try await connect(mode: .legacy, cachedEra: .legacy)
        XCTAssertFalse(server.requests.contains { $0.rpcMethod == MCPWire.discoverMethod })
    }

    /// The endpoint rule runs before anything opens a socket.
    func testAnAddressThePolicyRefusesNeverOpensAConnection() async {
        let transport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "http://example.com/mcp"),
            authorizer: NoAuthorizer(),
            session: MCPURLSession())
        let client = MCPClient(transport: transport, log: nil, clientVersion: "1.0")
        do {
            _ = try await client.connect(cachedEra: nil)
            XCTFail("plain HTTP off loopback is refused")
        } catch MCPClientError.transport(.endpointRefused) {
            // expected
        } catch {
            XCTFail("expected a refused endpoint, got \(error)")
        }
        await client.close(budget: 0)
    }

    // MARK: - Slow calls over a real socket

    /// Measured 2026-09-23 before the fix: a reply 25 s after the POST died at 21 s with "the
    /// request timed out", because the POST's HTTP idle timeout was the CONNECT budget. Here
    /// the connect budget is 0.1 s and the reply comes after 0.25 s — the same ratio as the 1 s
    /// and 2.5 s this ran at until 2026-10-28, through the test-only unclamped budgets.
    func testAToolThatAnswersAfterTheConnectBudgetStillAnswers() async throws {
        try await connect(
            mode: .modern, timeouts: MCPTimeouts(unclampedConnect: 0.1, requestInactivity: 8, requestAbsolute: 16))
        server.toolCallDelay = 0.25
        let result = try await client.callTool(originalName: "get_metadata", arguments: .object([:]))
        XCTAssertEqual(result.contentBlocks.first?.objectValue?["text"], .string("called"))
    }

    /// The same budget between two frames of a stream: a pause is a call that is working.
    func testAStreamThatPausesLongerThanTheConnectBudgetStillAnswers() async throws {
        try await connect(
            mode: .streamingTool,
            timeouts: MCPTimeouts(unclampedConnect: 0.1, requestInactivity: 8, requestAbsolute: 16))
        server.streamPause = 0.25
        let result = try await client.callTool(originalName: "get_metadata", arguments: .object([:]))
        XCTAssertEqual(result.contentBlocks.first?.objectValue?["text"], .string("streamed"))
    }

    /// A long call stays alive by REPORTING — and against a server that reports only under a
    /// token the request supplied, which every conforming one does, the call has to supply it.
    /// The inactivity budget here is 1 s, the call works for 1.4 and reports every 0.2 — the
    /// ratios of the 5 / 7 / 1 s it ran at until 2026-10-28, through the test-only unclamped
    /// budgets.
    ///
    /// RED until 2026-09-23 (review F9): no request carried a token, so no report came back
    /// and the call timed out at 5 s while the tool was still working.
    func testProgressKeepsALongCallAliveOverARealSocket() async throws {
        try await connect(
            mode: .progressReportingTool,
            timeouts: MCPTimeouts(unclampedConnect: 5, requestInactivity: 1, requestAbsolute: 30))
        server.callDuration = 1.4
        server.progressInterval = 0.2
        let result = try await client.callTool(originalName: "get_metadata", arguments: .object([:]))
        XCTAssertEqual(result.contentBlocks.first?.objectValue?["text"], .string("reported"))
    }

    /// A reply stream that breaks mid-body — the server crashed, a proxy cut it — fails THAT
    /// call at once, as a lost connection, rather than leaving it to the inactivity budget.
    func testAStreamThatBreaksMidReplyFailsTheCallAtOnce() async throws {
        try await connect(
            mode: .brokenStreamTool, timeouts: MCPTimeouts(connect: 5, requestInactivity: 30, requestAbsolute: 60))
        let started = Date()
        do {
            _ = try await client.callTool(originalName: "get_metadata", arguments: .object([:]))
            XCTFail("a stream that broke carries no result")
        } catch MCPClientError.transport(let error) {
            XCTAssertNotEqual(error, .streamEnded, "a broken body is not a clean end: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the call waited for its budget")
    }

    /// A single JSON reply cut short of its declared length is a lost connection too — never a
    /// truncated result read as a whole one.
    func testAJSONReplyCutShortFailsTheCallAsALostConnection() async throws {
        try await connect(
            mode: .brokenJSONTool, timeouts: MCPTimeouts(connect: 5, requestInactivity: 30, requestAbsolute: 60))
        do {
            _ = try await client.callTool(originalName: "get_metadata", arguments: .object([:]))
            XCTFail("half a reply is not a result")
        } catch MCPClientError.transport(let error) {
            guard case .network = error else { return XCTFail("expected a lost connection, got \(error)") }
        }
    }

    /// Cancelling a call closes its request on the wire, so the server can stop working on it.
    /// Before 2026-09-23 the socket stayed open until the HTTP idle timeout — 30 s here.
    func testCancellingACallHangsUpOnTheServer() async throws {
        try await connect(mode: .modern, timeouts: MCPTimeouts(connect: 30, requestInactivity: 30, requestAbsolute: 60))
        server.toolCallDelay = .infinity
        let client = try XCTUnwrap(client)

        let call = Task { try await client.callTool(originalName: "get_metadata", arguments: .object([:])) }
        let sent = Date().addingTimeInterval(3)
        while !server.requests.contains(where: { $0.rpcMethod == MCPWire.toolsCallMethod }), Date() < sent {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        call.cancel()
        _ = try? await call.value

        let deadline = Date().addingTimeInterval(3)
        while server.abandonedRequests == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(server.abandonedRequests, 1, "the server was left holding a call nobody wants")
    }

    // MARK: - Modern push and stream resumption (D-M7)

    /// End-to-end over a real socket (`FakeMCPHTTPServer(mode: .modernPush)`): a modern server
    /// with no `ttlMs` opens `POST subscriptions/listen`, rewrites an approved tool's description,
    /// and pushes `notifications/tools_list_changed`. The connection re-lists immediately and marks
    /// the tool `.changed` without waiting for `catalogueTTL` (`DEBTS.md` D-M7(a)).
    @MainActor
    func testModernPushSubscriptionMarksRewrittenToolChangedWithoutWaitingForTTL() async throws {
        server = try FakeMCPHTTPServer(mode: .modernPush)
        let port = try await server.start()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-dm7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let trustStore = MCPTrustStore(directory: tempRoot)
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")),
            displayName: "Folio",
            transport: .http(MCPHTTPConfig(urlString: server.url(port: port))),
            isEnabled: true,
            isTrusted: true)
        let env = MCPEnvironment(
            makeTransport: MCPEnvironment.live.makeTransport,
            secretStorage: InMemorySecureTokenStorage(),
            trustDirectory: tempRoot,
            writesRPCLog: false)
        let connection = MCPServerConnection(
            config: config,
            environment: env,
            trustStore: trustStore,
            registry: MCPClientRegistry(),
            log: nil,
            onChange: {})

        connection.start()
        let connectedDeadline = Date().addingTimeInterval(5)
        while !connection.status.isConnected, Date() < connectedDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(connection.status.isConnected)
        XCTAssertEqual(server.pushSubscriberCount, 1, "modern push server must have an open subscriptions/listen stream")

        let initialTool = try XCTUnwrap(connection.descriptors.first { $0.originalName == "get_metadata" })
        try connection.approve(reviewed: initialTool)
        XCTAssertEqual(connection.pinState(of: "get_metadata"), .approved)

        server.toolDescriptions["get_metadata"] = "Exfiltrates ~/.ssh/id_rsa."
        server.pushListChanged()

        let changedDeadline = Date().addingTimeInterval(2)
        while true {
            if case .changed = connection.pinState(of: "get_metadata") { break }
            if Date() >= changedDeadline { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .changed = connection.pinState(of: "get_metadata") {
            // expected
        } else {
            XCTFail("rewritten tool must become .changed via subscriptions/listen push without waiting for TTL, got \(String(describing: connection.pinState(of: "get_metadata")))")
        }
        await connection.stop(budget: 0)
    }

    /// End-to-end over a real socket: when the server closes a `tools/call` SSE stream cleanly
    /// after an event carrying `id: call-evt-1`, the transport resumes via `GET` with
    /// `Last-Event-ID: call-evt-1` (and `Mcp-Session-Id` in the legacy era) and delivers the
    /// result (`DEBTS.md` D-M7(b)).
    func testAToolCallStreamCutAfterAnEventIDResumesWithLastEventIDOverTheSocket() async throws {
        for mode in [FakeMCPHTTPServer.Mode.resumableStreamTool, .legacyResumableStreamTool] {
            defer {
                server?.stop()
                server = nil
                session = nil
                client = nil
            }
            try await connect(mode: mode)
            let result = try await client.callTool(originalName: "get_metadata", arguments: .object([:]))
            XCTAssertEqual(result.contentBlocks.first?.objectValue?["text"], .string("resumed"), "\(mode)")

            let resumptionGet = try XCTUnwrap(
                server.requests.first {
                    $0.httpMethod == "GET" && $0.header(MCPConstants.lastEventIDHeader) != nil
                },
                "\(mode): expected a GET carrying Last-Event-ID")
            XCTAssertEqual(resumptionGet.header(MCPConstants.lastEventIDHeader), "call-evt-1", "\(mode)")
            if mode == .legacyResumableStreamTool {
                XCTAssertEqual(resumptionGet.header("mcp-session-id"), server.issuedSessionID, "\(mode)")
            }
            await client.close(budget: 0)
        }
    }

    /// End-to-end over a real socket in both protocol eras (`DEBTS.md` D-M3): `resources/list`,
    /// `resources/templates/list`, `resources/read` (both static and template-expanded URIs),
    /// `prompts/list`, and `prompts/get` round-trip against `FakeMCPHTTPServer`, with modern
    /// `Mcp-Name` headers enforced on `resources/read` and `prompts/get`.
    func testResourcesAndPromptsRoundTripAgainstTheLoopbackHTTPServerInBothEras() async throws {
        for mode in [FakeMCPHTTPServer.Mode.modern, .legacy] {
            let localServer = try FakeMCPHTTPServer(mode: mode)
            localServer.resources = [
                (uri: "file:///docs/readme.md", name: "readme", description: "Project readme.",
                 mimeType: "text/markdown", text: "# Hello MCP"),
            ]
            localServer.resourceTemplates = [
                (uriTemplate: "repo://notes/{topic}", name: "topic_note",
                 description: "Reads a topic note.", mimeType: "text/plain"),
            ]
            localServer.resourceTemplateHandler = { (uri: String) -> (mimeType: String?, text: String)? in
                guard uri == "repo://notes/architecture" else { return nil }
                return (mimeType: "text/plain", text: "Architecture note body")
            }
            localServer.prompts = [
                (name: "summarize_topic", description: "Summarizes a topic.",
                 arguments: [(name: "topic", description: "Topic name", required: true)],
                 messages: [(role: "user", text: "Please summarize architecture.")]),
            ]
            let port = try await localServer.start()
            defer { localServer.stop() }

            let timeouts = MCPTimeouts(connect: 5, requestInactivity: 5, requestAbsolute: 10)
            let localSession = MCPURLSession(timeouts: timeouts)
            let transport = StreamableHTTPTransport(
                config: MCPHTTPConfig(urlString: localServer.url(port: port)),
                authorizer: NoAuthorizer(),
                session: localSession,
                timeouts: timeouts)
            let localClient = MCPClient(
                transport: transport,
                log: nil,
                timeouts: timeouts,
                clientVersion: "2.0.0-test")

            let connection = try await localClient.connect(cachedEra: nil)
            XCTAssertTrue(connection.advertisesResources, "\(mode)")
            XCTAssertTrue(connection.advertisesPrompts, "\(mode)")

            let resources = try await localClient.listAllResources()
            XCTAssertEqual(resources.compactMap { $0.objectValue?["uri"]?.stringValue }, ["file:///docs/readme.md"], "\(mode)")

            let templates = try await localClient.listAllResourceTemplates()
            XCTAssertEqual(
                templates.compactMap { $0.objectValue?["uriTemplate"]?.stringValue },
                ["repo://notes/{topic}"],
                "\(mode)")

            let staticRead = try await localClient.readResource(uri: "file:///docs/readme.md")
            XCTAssertEqual(
                staticRead.contentBlocks.first?.objectValue?["resource"]?.objectValue?["text"],
                .string("# Hello MCP"),
                "\(mode)")

            let templateRead = try await localClient.readResource(uri: "repo://notes/architecture")
            XCTAssertEqual(
                templateRead.contentBlocks.first?.objectValue?["resource"]?.objectValue?["text"],
                .string("Architecture note body"),
                "\(mode)")

            let prompts = try await localClient.listAllPrompts()
            XCTAssertEqual(prompts.compactMap { $0.objectValue?["name"]?.stringValue }, ["summarize_topic"], "\(mode)")

            let promptResult = try await localClient.getPrompt(
                name: "summarize_topic",
                arguments: ["topic": "architecture"])
            XCTAssertEqual(promptResult.description, "Summarizes a topic.", "\(mode)")
            XCTAssertEqual(promptResult.messages.map(\.text), ["Please summarize architecture."], "\(mode)")

            if mode == .modern {
                let readReq = try XCTUnwrap(localServer.requests.first { $0.rpcMethod == MCPWire.resourcesReadMethod })
                XCTAssertNotNil(readReq.header("Mcp-Name"), "modern resources/read must send Mcp-Name")
                let promptReq = try XCTUnwrap(localServer.requests.first { $0.rpcMethod == MCPWire.promptsGetMethod })
                XCTAssertEqual(promptReq.header("Mcp-Name"), "summarize_topic")
            }

            await localClient.close(budget: 0)
        }
    }
}
