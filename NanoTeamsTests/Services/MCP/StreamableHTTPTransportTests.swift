import XCTest

@testable import NanoTeams

/// The bytes half of the client: which headers go out, what each status code means, how an SSE
/// body becomes frames, and what happens to the legacy session id.
final class StreamableHTTPTransportTests: XCTestCase {

    private var session: ScriptedMCPHTTPSession!
    private var storage: InMemorySecureTokenStorage!

    override func setUp() {
        super.setUp()
        session = ScriptedMCPHTTPSession()
        storage = InMemorySecureTokenStorage()
    }

    override func tearDown() {
        session = nil
        storage = nil
        super.tearDown()
    }

    private func makeTransport(
        url: String = "https://example.com/mcp",
        headers: [String: String] = [:],
        authorizer: (any MCPAuthorizer)? = nil,
        frameLimit: Int = MCPConstants.maxFrameBytes
    ) -> StreamableHTTPTransport {
        StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: url, headers: headers),
            authorizer: authorizer ?? NoAuthorizer(),
            session: session, frameLimit: frameLimit)
    }

    /// The frame ceiling the ceiling tests below inject: small enough that proving it costs no
    /// 64 MiB read, large enough to sit far above every honest frame in this suite.
    private static let testFrameLimit = 64 * 1024

    /// What may still be yielding when a test reads the events a transport carried.
    private enum Settle {
        /// Nothing: every event was yielded inside the call that caused it (a JSON body).
        case nothing
        /// The POSTs' stream readers.
        case readers
        /// The legacy push channel, which ends on a GET it will not ask again.
        case pushChannel
    }

    /// Every event `transport` yielded before it was closed — read to the stream's END, not for
    /// a window. `settling` names what could still yield; it is awaited (bounded: a push channel
    /// that never ends is a channel asked again, which fails here), then the transport is closed,
    /// which yields `.closed` and ends the stream; that `.closed` is dropped. Until 2026-10-28
    /// each such read was a 0.2–0.5 s window a late event had to fall into.
    private func eventsUntilClosed(
        _ transport: StreamableHTTPTransport, _ events: AsyncStream<MCPIncomingEvent>,
        settling: Settle, file: StaticString = #filePath, line: UInt = #line
    ) async -> [MCPIncomingEvent] {
        switch settling {
        case .nothing:
            break
        case .readers:
            if await !settled(transport, within: 5, { await transport._testReadersFinished() }) {
                XCTFail("a stream reader did not end within 5 s", file: file, line: line)
            }
        case .pushChannel:
            if await !settled(transport, within: 5, { await transport._testPushChannelEnded() }) {
                XCTFail("the push channel did not end within 5 s: it is asked again", file: file, line: line)
            }
        }
        await transport.close(budget: 0)
        var collected: [MCPIncomingEvent] = []
        for await event in events { collected.append(event) }
        if collected.last == .closed { collected.removeLast() }
        return collected
    }

    /// Runs `operation` against a ceiling; past it the transport is closed — which ends every
    /// reader and the push channel, so the operation returns — and the answer is `false`.
    private func settled(
        _ transport: StreamableHTTPTransport, within seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await operation(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            if !first { await transport.close(budget: 0) }
            group.cancelAll()
            return first
        }
    }

    private func ping() -> MCPOutgoingFrame {
        .request(JSONRPCRequest(id: .number(1), method: "tools/call", params: .object([:])))
    }

    private func transportError(_ error: Error, file: StaticString = #filePath, line: UInt = #line)
        -> MCPTransportError? {
        guard let transport = error as? MCPTransportError else {
            XCTFail("expected an MCPTransportError, got \(error)", file: file, line: line)
            return nil
        }
        return transport
    }

    // MARK: - Connecting

    /// The endpoint rule runs at connect, before any request, so a refused address costs no
    /// round trip and the reason reaches the server row intact.
    func testConnectRefusesAnAddressThePolicyRejects() async {
        let transport = makeTransport(url: "http://example.com/mcp")
        do {
            try await transport.connect()
            XCTFail("plain HTTP off loopback must be refused")
        } catch {
            guard case .endpointRefused(let reason)? = transportError(error) else { return }
            XCTAssertTrue(reason.contains("https://"), reason)
        }
        XCTAssertTrue(session.requests.isEmpty, "a refused address costs no request")
    }

    func testSendingBeforeConnectIsRefused() async {
        let transport = makeTransport()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("the transport has no endpoint yet")
        } catch {
            XCTAssertEqual(transportError(error), .notConnected)
        }
    }

    /// The frames have an owner already; a second reader would silently steal half of them.
    func testOnlyTheFirstCallerGetsTheEventStream() async throws {
        let transport = makeTransport()
        try await transport.connect()
        _ = await transport.events()
        var second: [MCPIncomingEvent] = []
        for await event in await transport.events() { second.append(event) }
        XCTAssertTrue(second.isEmpty)
    }

    // MARK: - Headers

    /// Before the handshake the transport writes the MODERN version, because the probe IS a
    /// modern request.
    func testTheProbeGoesOutAsAModernRequest() async throws {
        session.replies = [.accepted]
        let transport = makeTransport()
        try await transport.connect()
        _ = try await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: "server/discover")), hints: .none)

        XCTAssertEqual(session.header(MCPConstants.protocolVersionHeader), MCPConstants.modernProtocolVersion)
        XCTAssertEqual(session.header("Mcp-Method"), "server/discover")
        XCTAssertEqual(session.header("Content-Type"), "application/json")
        XCTAssertEqual(session.header("Accept"), "application/json, text/event-stream")
        XCTAssertNil(session.header("Mcp-Session-Id"), "the modern era has no sessions")
    }

    /// 2026-07-28 mirrors routing metadata into headers so an intermediary can read it
    /// without parsing JSON.
    func testModernRequestsCarryTheNameAndTheDeclaredHeaderParameters() async throws {
        session.replies = [.accepted]
        let transport = makeTransport()
        try await transport.connect()
        _ = try await transport.send(ping(), hints: MCPSendHints(
            name: "get_design_context", headerParameters: ["Mcp-Param-Tenant": "acme"]))
        XCTAssertEqual(session.header("Mcp-Name"), "get_design_context")
        XCTAssertEqual(session.header("Mcp-Param-Tenant"), "acme")
    }

    /// A tool name and a parameter's value are the model's or the server's and may hold anything;
    /// an HTTP header value may not. A plain value goes as itself, so an intermediary matching on
    /// it keeps working; anything else goes as the specification's Base64 sentinel, which a server
    /// decodes before comparing it with the body — non-ASCII text, a control character, a space at
    /// either end, a tab anywhere, and a plain value that itself looks like the sentinel.
    ///
    /// RED until 2026-10-28: a parameter's value was written raw, and a non-token name went
    /// as `base64:` + Base64, a spelling no server decodes.
    func testAHeaderValueGoesAsItselfOrAsTheSpecsBase64Sentinel() {
        func sentinel(_ value: String) -> String { "=?base64?" + Data(value.utf8).base64EncodedString() + "?=" }
        for plain in ["get_metadata", "us-west1", "a b", "a,b;c", ""] {
            XCTAssertEqual(StreamableHTTPTransport.headerValue(plain), plain, plain)
        }
        for encoded in ["Получить", "Hello, 世界", " padded ", "trailing ", "\tlead", "in\tside", "line1\nline2",
                        "a\r\nX-Evil: 1", "=?base64?literal?=", "bell\u{7}"] {
            XCTAssertEqual(StreamableHTTPTransport.headerValue(encoded), sentinel(encoded), encoded)
        }
        // The specification's own examples.
        XCTAssertEqual(StreamableHTTPTransport.headerValue("Hello, 世界"), "=?base64?SGVsbG8sIOS4lueVjA==?=")
        XCTAssertEqual(StreamableHTTPTransport.headerValue(" padded "), "=?base64?IHBhZGRlZCA=?=")
        XCTAssertEqual(StreamableHTTPTransport.headerValue("line1\nline2"), "=?base64?bGluZTEKbGluZTI=?=")
        XCTAssertEqual(StreamableHTTPTransport.headerValue("=?base64?literal?="), "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
    }

    /// The name and every parameter header go out in that spelling.
    func testTheNameAndTheParameterHeadersAreSentInTheSpecsSpelling() async throws {
        session.replies = [.accepted]
        let transport = makeTransport()
        try await transport.connect()
        _ = try await transport.send(ping(), hints: MCPSendHints(
            name: "Получить", headerParameters: ["Mcp-Param-City": "Zürich", "Mcp-Param-Tenant": "acme"]))
        XCTAssertEqual(session.header("Mcp-Name"), StreamableHTTPTransport.headerValue("Получить"))
        XCTAssertEqual(session.header("Mcp-Param-City"), "=?base64?" + Data("Zürich".utf8).base64EncodedString() + "?=")
        XCTAssertEqual(session.header("Mcp-Param-Tenant"), "acme")
    }


    /// `initialize` is the legacy opening and goes out with no `MCP-Protocol-Version` and no
    /// `Mcp-Method`; after the handshake the legacy era writes the negotiated version and the
    /// session id, and stops writing the modern routing headers — a legacy server has no use
    /// for them.
    func testTheLegacyEraSwitchesHeadersAfterTheHandshake() async throws {
        session.replies = [
            .json("{}", headers: ["Mcp-Session-Id": "sess-1"]),
            .accepted,
        ]
        let transport = makeTransport()
        try await transport.connect()
        _ = try? await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: "initialize")), hints: .none)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)
        _ = try await transport.send(ping(), hints: MCPSendHints(name: "x"))

        let first = session.requests(method: "POST")[0]
        XCTAssertNil(first.value(forHTTPHeaderField: MCPConstants.protocolVersionHeader),
                     "initialize is the legacy opening and carries no version header")
        XCTAssertNil(first.value(forHTTPHeaderField: "Mcp-Method"),
                     "initialize is the legacy opening and carries no Mcp-Method header")

        let second = session.requests(method: "POST")[1]
        XCTAssertEqual(second.value(forHTTPHeaderField: MCPConstants.protocolVersionHeader),
                       MCPConstants.legacyProtocolVersion)
        XCTAssertEqual(second.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1")
        XCTAssertNil(second.value(forHTTPHeaderField: "Mcp-Method"))
        XCTAssertNil(second.value(forHTTPHeaderField: "Mcp-Name"))
    }

    /// Before `adopt` has run, a frame that names its own `protocolVersion` in `MCPSendHints`
    /// writes that revision on the wire rather than waiting for `adopt` — so a retried
    /// `server/discover` probe at another modern revision carries the version it asks for.
    func testAFrameWithAnExplicitProtocolVersionHintWritesThatVersionBeforeAdopt() async throws {
        session.replies = [.accepted]
        let transport = makeTransport()
        try await transport.connect()
        _ = try await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: "server/discover")),
            hints: MCPSendHints(protocolVersion: "2027-01-15"))

        XCTAssertEqual(session.header(MCPConstants.protocolVersionHeader), "2027-01-15")
        XCTAssertEqual(session.header("Mcp-Method"), "server/discover")
    }

    /// The transport's OWN half of the legacy contract: a session adopted for the legacy era
    /// writes no `Mcp-Param-*` header, whatever header parameters it is handed — that revision
    /// has no header channel. (The coercion hands a legacy call none: this pins the transport
    /// even if something else ever did.)
    ///
    /// Pins that the legacy branch does not write the parameters as headers.
    func testALegacySessionWritesNoParameterHeaderWhateverItIsHanded() async throws {
        session.replies = [
            .json("{}", headers: ["Mcp-Session-Id": "sess-1"]),
            .accepted,
        ]
        let transport = makeTransport()
        try await transport.connect()
        _ = try? await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: "initialize")), hints: .none)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)
        _ = try await transport.send(ping(), hints: MCPSendHints(
            name: "get_design_context", headerParameters: ["Mcp-Param-Tenant": "acme", "Mcp-Param-Region": "eu"]))

        let call = try XCTUnwrap(session.requests(method: "POST").last)
        let parameterHeaders = (call.allHTTPHeaderFields ?? [:]).keys
            .filter { $0.lowercased().hasPrefix(MCPHeaderParam.prefix.lowercased()) }
        XCTAssertEqual(parameterHeaders, [], "a legacy session wrote \(parameterHeaders)")
        XCTAssertEqual(call.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1", "premise: the legacy branch ran")
    }

    func testConfiguredHeadersRideEveryRequest() async throws {
        session.replies = [.accepted]
        let transport = makeTransport(headers: ["X-Tenant": "acme"])
        try await transport.connect()
        _ = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(session.header("X-Tenant"), "acme")
    }

    func testTheAuthorizerGetsTheLastWordOnTheRequest() async throws {
        session.replies = [.accepted]
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("trade_room")), displayName: "T",
            transport: .http(MCPHTTPConfig(urlString: "https://example.com/mcp", authorization: .staticBearer)))
        try storage.setToken("t.SECRET", forKey: config.bearerSecretKey)
        let transport = StreamableHTTPTransport(
            config: config.transport.http,
            authorizer: StaticBearerAuthorizer.make(config: config, storage: storage),
            session: session)
        try await transport.connect()
        _ = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(session.header("Authorization"), "Bearer t.SECRET")
    }

    // MARK: - Status ladder

    func testATwoOhTwoIsAcceptedAndCarriesNoFrame() async throws {
        session.replies = [.accepted]
        let transport = makeTransport()
        try await transport.connect()
        let outcome = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(outcome, .accepted)
    }

    func testAJSONReplyArrivesOnTheEventStream() async throws {
        session.replies = [.json(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        let outcome = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(outcome, .answered)

        let collected = await collectMCPEvents(events, count: 1)
        guard case .frame(.response(let response))? = collected.first else {
            return XCTFail("expected a response frame, got \(collected)")
        }
        XCTAssertEqual(response.id, .number(1))
        XCTAssertEqual(response.result?.objectValue?["ok"], .bool(true))
    }

    /// One POST can answer with a stream carrying progress notifications and then the result.
    /// That is why `send` never returns the reply.
    func testAnSSEReplyYieldsEveryFrameInOrder() async throws {
        session.replies = [.sse("""
        event: message
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0.5}}
        
        data: {"jsonrpc":"2.0","id":1,"result":{"content":[]}}
        
        """)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        let outcome = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(outcome, .answered)

        let collected = await collectMCPEvents(events, count: 2)
        XCTAssertEqual(collected.count, 2)
        guard case .frame(.notification(let notification))? = collected.first else {
            return XCTFail("expected the progress notification first, got \(collected)")
        }
        XCTAssertEqual(notification.method, "notifications/progress")
        guard case .frame(.response(let response)) = collected[1] else {
            return XCTFail("expected the result second")
        }
        XCTAssertEqual(response.id, .number(1))
    }

    /// The regression that `bytes.lines` caused: it drops empty lines, and in SSE the empty
    /// line IS the event boundary, so two events arrived as one unparseable frame.
    func testTheBlankLineBetweenTwoEventsIsNotSwallowed() async throws {
        session.replies = [.sse("""
        data: {"jsonrpc":"2.0","method":"a"}
        
        data: {"jsonrpc":"2.0","method":"b"}
        
        """)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)

        let collected = await collectMCPEvents(events, count: 2)
        let methods: [String] = collected.compactMap {
            guard case .frame(.notification(let notification)) = $0 else { return nil }
            return notification.method
        }
        XCTAssertEqual(methods, ["a", "b"])
    }

    /// A server that closes cleanly without a trailing blank line still owes the reply the
    /// request is waiting for.
    func testAStreamThatEndsWithoutABlankLineStillDeliversItsLastFrame() async throws {
        session.replies = [.sse(#"data: {"jsonrpc":"2.0","id":1,"result":{}}"#)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)

        let collected = await collectMCPEvents(events, count: 1)
        guard case .frame(.response(let response))? = collected.first else {
            return XCTFail("the last frame of a stream must not be dropped, got \(collected)")
        }
        XCTAssertEqual(response.id, .number(1))
    }

    /// Comments are the keep-alive a server sends to hold the connection open; they carry no
    /// event and must not produce one.
    func testKeepAliveCommentsProduceNoFrames() async throws {
        session.replies = [.sse("""
        : keep-alive
        
        : another
        
        data: {"jsonrpc":"2.0","method":"a"}
        
        """)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)

        let collected = await collectMCPEvents(events, count: 1)
        XCTAssertEqual(collected.count, 1)
        guard case .frame(.notification(let notification))? = collected.first else {
            return XCTFail("expected exactly the one real event, got \(collected)")
        }
        XCTAssertEqual(notification.method, "a")
    }

    /// A stream answering a NOTIFICATION has no request behind it, so it cannot be cancelled
    /// by id — it is tracked separately and torn down with the connection.
    func testAStreamAnsweringANotificationIsStillRead() async throws {
        session.replies = [.sse("""
        data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
        
        """)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(
            .notification(JSONRPCNotification(method: "notifications/initialized")), hints: .none)

        let collected = await collectMCPEvents(events, count: 1)
        guard case .frame(.notification(let notification))? = collected.first else {
            return XCTFail("a stream with no request behind it must still be read, got \(collected)")
        }
        XCTAssertEqual(notification.method, "notifications/tools/list_changed")
        await transport.close(budget: 0)
    }

    /// The parser's ceiling counts completed `data:` lines. A server that never sends a
    /// newline at all would otherwise grow the line buffer without limit.
    ///
    /// At the injected ceiling (`testFrameLimit`): until 2026-10-28 this pushed 64 MiB + 16 bytes
    /// through the per-byte read, 7.7 s, to prove the same line. That the app's transport carries
    /// the real constant is `testTheFrameCeilingIsTheConstantWhereverTheAppBuildsATransport`'s.
    func testAStreamThatNeverEndsALineIsRefusedAtTheCeiling() async throws {
        session.replies = [.sse(String(repeating: "x", count: Self.testFrameLimit + 16))]
        let transport = makeTransport(frameLimit: Self.testFrameLimit)
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)

        let collected = await collectMCPEvents(events, count: 1, timeout: 60)
        guard case .requestFailed(.number(1), .frameTooLarge(_, let limit))? = collected.first else {
            return XCTFail("an unterminated line must fail its request, got \(collected)")
        }
        XCTAssertEqual(limit, Self.testFrameLimit, "the line was refused at a ceiling other than the transport's")
    }

    /// The parser's half of the stream ceiling: a frame of COMPLETED `data:` lines — each one
    /// under the ceiling, so the unterminated-line guard above never trips — whose total is past
    /// it fails its request at the transport's ceiling.
    func testAStreamFrameOfManyLinesPastTheCeilingIsRefused() async throws {
        let line = "data: " + String(repeating: "z", count: Self.testFrameLimit / 4) + "\n"
        session.replies = [.sse(String(repeating: line, count: 6) + "\n")]
        let transport = makeTransport(frameLimit: Self.testFrameLimit)
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)

        let collected = await collectMCPEvents(events, count: 1)
        guard case .requestFailed(.number(1), .frameTooLarge(_, let limit))? = collected.first else {
            return XCTFail("a frame past the ceiling must fail its request, got \(collected)")
        }
        XCTAssertEqual(limit, Self.testFrameLimit)
    }

    /// A JSON body past the ceiling fails the connection loudly rather than truncating: a
    /// truncated frame is indistinguishable from a malformed one, and half a tool result
    /// would reach the model as a plausible whole answer.
    func testAJSONBodyPastTheCeilingIsRefusedRatherThanTruncated() async throws {
        let transport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: NoAuthorizer(), session: session)
        session.replies = [.json("{\"padding\":\"" + String(repeating: "y", count: 4096) + "\"}")]
        try await transport.connect()
        // Under the default ceiling (64 MiB — asserting against it would mean allocating one)
        // the body is read and the request went out.
        _ = try? await transport.send(ping(), hints: .none)
        XCTAssertFalse(session.requests.isEmpty)

        // And the refusal itself, at an injected ceiling below the body (since 2026-10-28, when
        // the ceiling became the transport's own): the send fails as a frame too large, at the
        // transport's ceiling, and nothing reaches the inbound stream.
        let small = makeTransport(frameLimit: 1024)
        session.replies = [.json("{\"padding\":\"" + String(repeating: "y", count: 4096) + "\"}")]
        try await small.connect()
        do {
            _ = try await small.send(ping(), hints: .none)
            XCTFail("a JSON body past the ceiling must fail the send")
        } catch MCPTransportError.frameTooLarge(let bytes, let limit) {
            XCTAssertEqual(limit, 1024)
            XCTAssertGreaterThan(bytes, 1024)
        }
    }

    /// The non-2xx half of the ceiling: a 4xx body is read only up to the transport's ceiling, so
    /// a JSON-RPC error that WOULD answer the request but runs past it is not read whole as the
    /// answer — it stays the HTTP failure it came under, and nothing reaches the inbound stream.
    /// Under the default ceiling the same body IS the answer, which is what makes this a test of
    /// the ceiling rather than of the body. At the injected ceiling (`testFrameLimit`).
    ///
    /// RED until 2026-10-28: nothing reached this site past a ceiling, so it
    /// could read `MCPConstants.maxFrameBytes`, or no ceiling at all, with the suite green.
    func testAFourHundredBodyPastTheCeilingIsNotReadAsTheAnswer() async throws {
        let padding = String(repeating: "p", count: Self.testFrameLimit)
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"Header mismatch","data":""#
            + padding + #""}}"#
        session.replies = [.json(body, status: 400)]
        let whole = makeTransport()
        try await whole.connect()
        let answered = try await whole.send(ping(), hints: .none)
        XCTAssertEqual(answered, .answered, "premise: under the default ceiling the body is the request's answer")
        await whole.close(budget: 0)

        session.replies = [.json(body, status: 400)]
        let transport = makeTransport(frameLimit: Self.testFrameLimit)
        try await transport.connect()
        let events = await transport.events()
        do {
            let outcome = try await transport.send(ping(), hints: .none)
            XCTFail("a body past the ceiling was read whole as the answer (\(outcome))")
        } catch {
            guard case .httpStatus(let code, _)? = transportError(error) else { return }
            XCTAssertEqual(code, 400)
        }
        let collected = await eventsUntilClosed(transport, events, settling: .nothing)
        XCTAssertEqual(collected, [], "a frame past the ceiling reached the inbound stream")
    }

    /// The ceiling the app's transports read at is `MCPConstants.maxFrameBytes` — the init's own
    /// default and the transport `MCPEnvironment.live` builds — whatever the tests above inject.
    ///
    /// RED: give `frameLimit` any other default → both assertions name it.
    func testTheFrameCeilingIsTheConstantWhereverTheAppBuildsATransport() throws {
        XCTAssertEqual(makeTransport().frameLimit, MCPConstants.maxFrameBytes, "the init's default")
        let live = try XCTUnwrap(MCPEnvironment.live.makeTransport(
            MCPHTTPConfig(urlString: "https://x/mcp"), NoAuthorizer(), .standard) as? StreamableHTTPTransport)
        XCTAssertEqual(live.frameLimit, MCPConstants.maxFrameBytes, "the app's transport")
    }

    /// A server that offers no push channel answers 405, and that is not an error — a server
    /// like that carries everything on its POST replies.
    func testALegacyServerWithoutAPushChannelIsNotAFailure() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"]), .accepted]
        session.getReplies = [.status(405)]
        let transport = makeTransport()
        try await transport.connect()
        _ = try? await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: "initialize")), hints: .none)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(session.requests(method: "GET").count, 1)
        let outcome = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(outcome, .accepted, "the connection is fine without a push channel")
    }

    /// Every `URLError` this client classifies, by CODE — a localized system string in a tool
    /// result is the failure this app already fixed once.
    func testEveryClassifiedNetworkCodeHasItsOwnEnglish() {
        let expected: [URLError.Code: MCPTransportError] = [
            .timedOut: .timedOut,
            .cancelled: .closed,
            .cannotFindHost: .network("the hostname could not be resolved"),
            .dnsLookupFailed: .network("the hostname could not be resolved"),
            .cannotConnectToHost: .network("the connection was refused"),
            .networkConnectionLost: .network("the connection was lost"),
            .notConnectedToInternet: .network("this machine is offline"),
            .secureConnectionFailed: .network("the TLS connection could not be established"),
            .serverCertificateUntrusted: .network("the TLS connection could not be established"),
            .serverCertificateHasBadDate: .network("the TLS connection could not be established"),
            .serverCertificateNotYetValid: .network("the TLS connection could not be established"),
            .serverCertificateHasUnknownRoot: .network("the TLS connection could not be established"),
            .httpTooManyRedirects: .network("the server redirected too many times"),
        ]
        for (code, transportError) in expected {
            XCTAssertEqual(StreamableHTTPTransport.classify(URLError(code)), transportError, "\(code)")
        }
    }

    /// The legacy era's server→client channel. A server that offers one holds a GET open and
    /// pushes frames down it; nothing correlates them to a request, so they arrive as
    /// notifications.
    func testTheLegacyPushChannelIsReadWhenTheServerOffersOne() async throws {
        session.replies = [
            .json("{}", headers: ["Mcp-Session-Id": "sess-1"]),
            .sse("""
            data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
            
            """),
        ]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try? await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: "initialize")), hints: .none)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)

        let collected = await collectMCPEvents(events, count: 1)
        guard case .frame(.notification(let notification))? = collected.first else {
            return XCTFail("the push channel must be read, got \(collected)")
        }
        XCTAssertEqual(notification.method, "notifications/tools/list_changed")

        let gets = session.requests(method: "GET")
        XCTAssertEqual(gets.first?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(gets.first?.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1")
        await transport.close(budget: 0)
    }

    /// By 2025-11-25 a standalone GET push stream carries no replies without resumption, which
    /// this client does not implement; `readStream` still reads it with `dropsReplies: false`, so
    /// a non-conforming legacy server that sends a JSON-RPC reply on the GET stream closes the
    /// client request whose id it carries (`D-M9` pt. 3, `D-M11` pt. 1).
    func testAReplySentOnTheLegacyPushChannelAnswersItsPendingRequest() async throws {
        session.repliesByRPCMethod[MCPWire.initializeMethod] = .json(
            #"{"jsonrpc":"2.0","id":{{id}},"result":{"protocolVersion":"2025-11-25"}}"#,
            headers: ["Mcp-Session-Id": "sess-1"])
        session.repliesByRPCMethod[MCPWire.initializedNotification] = .accepted
        session.repliesByRPCMethod[MCPWire.toolsListMethod] = .accepted
        session.getReplies = [
            .sse("""
            data: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"via_push","description":"d","inputSchema":{"type":"object"}}]}}
            
            """),
            .status(405),
        ]
        // The reply goes out only after the request it answers, as a real server's would: the
        // push channel opens on its own task, and an unmatched reply is dropped (rightly).
        session.getRepliesAwaitRPCMethod = MCPWire.toolsListMethod
        let transport = makeTransport()
        // Ceilings for a failure only — the reply ends the wait the moment it lands — wide enough
        // that the parallel instrumented run cannot outlast them on a green path.
        let client = MCPClient(
            transport: transport, log: nil,
            timeouts: MCPTimeouts(unclampedConnect: 5, requestInactivity: 5, requestAbsolute: 10),
            clientVersion: "1.0")
        _ = try await client.connect(cachedEra: .legacy)
        let tools = try await client.listAllTools()
        XCTAssertEqual(tools.compactMap { $0.objectValue?["name"]?.stringValue }, ["via_push"])
        await client.close(budget: 0)
    }

    func testAnEmptyBodyOnTwoHundredReadsAsAccepted() async throws {
        session.replies = [.json("")]
        let transport = makeTransport()
        try await transport.connect()
        let outcome = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(outcome, .accepted)
    }

    func testAnUnauthorizedReplyCarriesTheAuthorizersOwnReason() async throws {
        session.replies = [.status(401, headers: ["WWW-Authenticate": "Bearer realm=\"mcp\""])]
        let transport = makeTransport()
        try await transport.connect()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("401 must not read as success")
        } catch {
            guard case .unauthorized(let status, let challenge)? = transportError(error) else { return }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(challenge?.contains("realm") ?? false, challenge ?? "")
        }
    }

    /// A 401 is a credential problem, not a connection problem, so reconnecting cannot help.
    func testWhichFailuresAreWorthRetrying() {
        XCTAssertFalse(MCPTransportError.unauthorized(status: 401, challenge: nil).isRetryable)
        XCTAssertFalse(MCPTransportError.endpointRefused("x").isRetryable)
        XCTAssertFalse(MCPTransportError.redirectRefused(from: "a", to: "b").isRetryable)
        XCTAssertTrue(MCPTransportError.sessionLost.isRetryable)
        XCTAssertTrue(MCPTransportError.timedOut.isRetryable)
    }

    /// The server forgot the session. Not a failure to report — the client re-initializes,
    /// re-lists and re-pins.
    func testAFourOhFourWithASessionMeansTheSessionIsGone() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"]), .status(404)]
        session.getReplies = [.status(405)]
        let transport = makeTransport()
        try await transport.connect()
        _ = try? await transport.send(.request(JSONRPCRequest(id: .number(1), method: "initialize")), hints: .none)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("404 with a session must be reported as a lost session")
        } catch {
            XCTAssertEqual(transportError(error), .sessionLost)
        }
    }

    /// Without a session, 404 is an ordinary wrong-URL answer and must keep saying so.
    func testAFourOhFourWithoutASessionIsAnOrdinaryHTTPFailure() async throws {
        session.replies = [.status(404, body: "no such endpoint")]
        let transport = makeTransport()
        try await transport.connect()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("404 must not read as success")
        } catch {
            guard case .httpStatus(let code, _)? = transportError(error) else { return }
            XCTAssertEqual(code, 404)
        }
    }

    /// A `400 Bad Request` carrying the JSON-RPC error that answers the request IS that
    /// request's answer: the 2026-07-28 revision has a modern server refuse with 400 and a JSON-RPC
    /// error — `HeaderMismatch` (-32020), `UnsupportedProtocolVersionError`, a missing capability
    /// ("Server Validation"; "Backward Compatibility": "the client SHOULD inspect the response
    /// body") — and 404 with `-32601` for a method it does not have. The frame goes out on the
    /// event stream, as a 200's would, so the caller reads the server's error by its code.
    ///
    /// RED until 2026-10-28: every such reply was an HTTP failure, `httpStatus(400)`, so a
    /// HeaderMismatch never re-read the tool list and a -32022 was never read as one.
    func testAJSONRPCErrorAnsweringTheRequestOnAFourHundredIsTheAnswer() async throws {
        let bodies: [(String, Int, String)] = [
            ("400 echoed id", 400, #"{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"Header mismatch"}}"#),
            ("404 echoed id", 404, #"{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"Header mismatch"}}"#),
            ("422 echoed id", 422, #"{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"Header mismatch"}}"#),
            ("400 omitted id", 400, #"{"jsonrpc":"2.0","error":{"code":-32020,"message":"Header mismatch"}}"#),
            ("400 null id", 400, #"{"jsonrpc":"2.0","id":null,"error":{"code":-32020,"message":"Header mismatch"}}"#),
        ]
        for (label, status, body) in bodies {
            session.replies = [.json(body, status: status)]
            let transport = makeTransport()
            try await transport.connect()
            let events = await transport.events()
            let outcome = try await transport.send(ping(), hints: .none)
            XCTAssertEqual(outcome, .answered, label)
            let collected = await collectMCPEvents(events, count: 1)
            guard case .frame(.response(let response))? = collected.first else {
                return XCTFail("\(label): expected the error response as a frame, got \(collected)")
            }
            XCTAssertEqual(response.id, .number(1), label)
            XCTAssertEqual(response.error?.code, -32020, label)
            await transport.close(budget: 0)
        }
    }

    /// This client's reply to a server's request #7 — a legacy server's `ping` — whose `7` is the
    /// SERVER's id, not one of this client's own: the two namespaces only share their spelling.
    private func reply(to id: Int = 7) -> MCPOutgoingFrame {
        .response(JSONRPCResponse(id: .number(id), outcome: .result(.object([:]))))
    }

    private func initialized() -> MCPOutgoingFrame {
        .notification(JSONRPCNotification(method: "notifications/initialized"))
    }

    /// Not every 4xx body is an answer, and only a REQUEST awaits one. By outgoing frame:
    /// - a request: a body that is not JSON-RPC, one answering ANOTHER request, a result rather
    ///   than an error, an error with a non-scalar id — and a 5xx, whatever it carries;
    /// - a notification: its refusal "MAY comprise a JSON-RPC error response that has no id"
    ///   (2025-11-25, Sending Messages) — and one that names an id answers nothing either;
    /// - this client's reply to a server's request: the body echoing the reply's id is a
    ///   non-conforming server refusing the reply, and that id is the SERVER's — read as an
    ///   answer it was delivered to this client's own in-flight request #7, which failed with
    ///   the refusal while its real answer was dropped later (the same class as a server's
    ///   `notifications/cancelled`, which names the server's own requests).
    /// Each stays the HTTP failure it is, and no frame reaches the event stream.
    ///
    /// RED until 2026-10-28 for the reply rows: the transport keyed the answer it awaited on
    /// the frame's own id, which for a reply is the server's. Until then, too, a row's
    /// unexpected failure was skipped with `continue` rather than reported.
    func testAFourHundredThatAnswersNothingIsStillAnHTTPFailure() async throws {
        let cases: [(String, MCPOutgoingFrame, Int, String)] = [
            ("a request answered in plain text", ping(), 400, "bad request"),
            ("a request answered with another request's error", ping(), 400,
             #"{"jsonrpc":"2.0","id":7,"error":{"code":-32020,"message":"x"}}"#),
            ("a request answered with a result", ping(), 400, #"{"jsonrpc":"2.0","id":1,"result":{}}"#),
            ("a request answered with a non-scalar id error", ping(), 400,
             #"{"jsonrpc":"2.0","id":[1],"error":{"code":-32600,"message":"x"}}"#),
            ("a request answered 500", ping(), 500, #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"x"}}"#),
            ("a notification refused with no id", initialized(), 400,
             #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"x"}}"#),
            ("a notification refused with null id", initialized(), 400,
             #"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"x"}}"#),
            ("a notification refused naming id 1", initialized(), 400,
             #"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"x"}}"#),
            ("a reply refused echoing its id", reply(), 400,
             #"{"jsonrpc":"2.0","id":7,"error":{"code":-32600,"message":"Invalid Request"}}"#),
            ("a reply refused with no id", reply(), 400,
             #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"}}"#),
            ("a reply refused as an unknown method", reply(), 404,
             #"{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Method not found"}}"#),
            ("a reply refused 422", reply(), 422,
             #"{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"x"}}"#),
        ]
        for (label, frame, status, body) in cases {
            session.replies = [.json(body, status: status)]
            let transport = makeTransport()
            try await transport.connect()
            let events = await transport.events()
            do {
                let outcome = try await transport.send(frame, hints: .none)
                XCTFail("\(label): read as an answer (\(outcome))")
            } catch {
                guard case .httpStatus(let code, _)? = transportError(error) else {
                    XCTFail("\(label): \(error)")
                    await transport.close(budget: 0)
                    continue
                }
                XCTAssertEqual(code, status, label)
            }
            let frames = await eventsUntilClosed(transport, events, settling: .nothing)
                .filter { if case .frame = $0 { true } else { false } }
            XCTAssertEqual(frames, [], "\(label): a refusal that answers nothing reached the event stream")
            await transport.close(budget: 0)
        }
    }

    /// A POST that awaits no answer — a notification, this client's reply to a server's request —
    /// answered 200 with a body anyway (the server "MUST return HTTP status code 202 Accepted with
    /// no body"): a REPLY in that body answers nothing this client asked, and its id can only
    /// collide with one of this client's own, so it is not delivered — as a single JSON object or
    /// on a stream. What else a body carries still is: a server's notification. A request's
    /// reply, on its own POST, is the answer it always was.
    ///
    /// RED until 2026-10-28: every frame of such a body was delivered, and a reply echoing
    /// the server's id #7 settled this client's own request #7.
    func testAReplyOnAPostThatAwaitsNoAnswerIsNotDelivered() async throws {
        let stray = #"{"jsonrpc":"2.0","id":7,"result":{}}"#
        let notice = #"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}"#
        let cases: [(String, MCPOutgoingFrame, ScriptedMCPHTTPSession.Reply)] = [
            ("a reply answered with a JSON reply", reply(), .json(stray)),
            ("a notification answered with a JSON reply", initialized(), .json(stray)),
            ("a reply answered with a stream carrying a reply", reply(), .sse("data: \(stray)\n\n")),
            ("a notification answered with a stream carrying a reply", initialized(), .sse("data: \(stray)\n\n")),
        ]
        for (label, frame, answer) in cases {
            session.replies = [answer]
            let transport = makeTransport()
            try await transport.connect()
            let events = await transport.events()
            _ = try await transport.send(frame, hints: .none)
            let replies = await eventsUntilClosed(transport, events, settling: .readers).filter {
                if case .frame(.response) = $0 { true } else { false }
            }
            XCTAssertEqual(replies, [], "\(label): a reply nobody awaited was delivered")
            await transport.close(budget: 0)
        }

        // What else such a body carries is still read, and a request's own reply still arrives.
        session.replies = [.sse("data: \(notice)\n\n")]
        let noticed = makeTransport()
        try await noticed.connect()
        let noticeEvents = await noticed.events()
        _ = try await noticed.send(reply(), hints: .none)
        let read = await collectMCPEvents(noticeEvents, count: 1)
        guard case .frame(.notification(let notification))? = read.first else {
            return XCTFail("a server's notification on such a stream is still read, got \(read)")
        }
        XCTAssertEqual(notification.method, "notifications/message")
        await noticed.close(budget: 0)
    }

    /// The stream answering this client's reply to the server's request #7 is not request #7's
    /// stream: when it ends without a reply — it never carries one — no request fails. Keyed by
    /// the reply's id, it took the place of the client's own request #7's reader and its end
    /// failed that request (`requestFailed(7, streamEnded)`), whose answer was still to come.
    ///
    /// RED until 2026-10-28: `readers[requestID]` was keyed on the reply's own id.
    func testTheStreamAnsweringAReplyFailsNoRequestWhenItEnds() async throws {
        session.replies = [.sse(#"data: {"jsonrpc":"2.0","method":"notifications/message","params":{}}"# + "\n\n")]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(reply(), hints: .none)
        let collected = await eventsUntilClosed(transport, events, settling: .readers)
        XCTAssertFalse(collected.contains { if case .requestFailed = $0 { true } else { false } },
                       "a reply's stream failed a request: \(collected)")
        XCTAssertTrue(collected.contains { if case .frame(.notification) = $0 { true } else { false } },
                      "anti-vacuum: the stream was read: \(collected)")
        await transport.close(budget: 0)
    }

    func testAServerErrorBodyIsRedactedAndExcerptedIntoTheMessage() async throws {
        session.replies = [.status(500, body: "upstream rejected Bearer t.SECRET-VALUE-123")]
        let transport = makeTransport()
        try await transport.connect()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("500 must not read as success")
        } catch {
            guard case .httpStatus(let code, let body)? = transportError(error) else { return }
            XCTAssertEqual(code, 500)
            XCTAssertFalse(body.contains("t.SECRET-VALUE-123"), body)
            XCTAssertTrue(body.contains("upstream rejected"), body)
        }
    }

    // MARK: - Secrets this server was given (F11)

    private let workspaceKey = "wk_live_8f3a9c2d"

    /// A transport over a server configured with one secret header and a bearer token, both
    /// saved — the authorizer knows exactly what it sends.
    private func transportWithSecrets(workspaceKey: String? = nil) throws -> StreamableHTTPTransport {
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("chat")), displayName: "Chat",
            transport: .http(MCPHTTPConfig(
                urlString: "https://example.com/mcp", secretHeaderNames: ["X-Workspace-Key"],
                authorization: .staticBearer)))
        try storage.setToken(workspaceKey ?? self.workspaceKey, forKey: config.secretKey(forHeader: "X-Workspace-Key"))
        try storage.setToken("q9Zx7kLm", forKey: config.bearerSecretKey)
        return StreamableHTTPTransport(
            config: config.transport.http,
            authorizer: StaticBearerAuthorizer.make(config: config, storage: storage),
            session: session)
    }

    private func failure(of transport: StreamableHTTPTransport) async throws -> MCPTransportError? {
        try await transport.connect()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("a refusal must not read as success")
            return nil
        } catch {
            return transportError(error)
        }
    }

    /// The server echoes the secret header it rejected. No generic pattern knows the name
    /// `X-Workspace-Key`, and the bare value matches none either — only the authorizer knows
    /// both, so the transport asks it before the body becomes a message the model, the server
    /// row and the frame log all read.
    func testAnEchoedSecretHeaderValueIsRedactedFromTheErrorMessage() async throws {
        session.replies = [.status(400, body: "Invalid X-Workspace-Key: \(workspaceKey) (also tried q9Zx7kLm)")]
        let error = try await failure(of: try transportWithSecrets())
        guard case .httpStatus(let code, let body)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(code, 400)
        XCTAssertFalse(body.contains(workspaceKey), body)
        XCTAssertFalse(body.contains("q9Zx7kLm"), body)
        XCTAssertTrue(body.contains("X-Workspace-Key"), "the NAME is the diagnostic value: \(body)")
        XCTAssertFalse(error?.message.contains(workspaceKey) ?? true)
    }

    /// The value after a secret header's NAME goes even when it is not the saved one — a server
    /// echoing what an intermediary substituted is echoing a credential too.
    func testTheValueAfterASecretHeadersNameIsRedactedWhateverItIs() async throws {
        session.replies = [.status(400, body: #"{"error":"bad header","x-workspace-key":"unknown-7d6c5b"}"#)]
        let error = try await failure(of: try transportWithSecrets())
        guard case .httpStatus(_, let body)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertFalse(body.contains("unknown-7d6c5b"), body)
    }

    /// A `WWW-Authenticate` challenge can quote the credential it refused.
    func testAnEchoedSecretIsRedactedFromTheCredentialChallenge() async throws {
        session.replies = [.status(401, headers: [
            "WWW-Authenticate": "Bearer realm=\"mcp\", error_description=\"key \(workspaceKey) revoked\"",
        ])]
        let error = try await failure(of: try transportWithSecrets())
        guard case .unauthorized(let status, let challenge)? = error else {
            return XCTFail("\(String(describing: error))")
        }
        XCTAssertEqual(status, 401)
        XCTAssertFalse(challenge?.contains(workspaceKey) ?? true, challenge ?? "")
        XCTAssertTrue(challenge?.contains("revoked") ?? false, challenge ?? "")
    }

    /// The body is server text on its way to the model: it arrives on one line with nothing
    /// hidden in it (F24's rule, at the transport's own door).
    func testAServerErrorBodyReachesTheMessageOnOneLineWithNothingHidden() async throws {
        session.replies = [.status(502, body: "<h1>Bad gateway</h1>\n\n<p>upstream\u{202E} down\u{E0041}</p>\n")]
        let error = try await failure(of: makeTransport())
        guard case .httpStatus(_, let body)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(body, "<h1>Bad gateway</h1> <p>upstream down</p>")
    }

    /// A base64 or JWT-style secret carries `/`, which a server's JSON encoder writes `\/`,
    /// and a form echo percent-encodes. Neither spelling reaches the message.
    func testASlashEscapedOrPercentEncodedEchoIsRedactedFromTheErrorBody() async throws {
        let key = "wk/live+8f3a9c2d=="
        for body in [#"{"error":"unknown key wk\/live+8f3a9c2d=="}"#, "unknown key=wk%2Flive%2B8f3a9c2d%3D%3D"] {
            session.replies = [.status(400, body: body)]
            let error = try await failure(of: try transportWithSecrets(workspaceKey: key))
            guard case .httpStatus(_, let excerpt)? = error else { return XCTFail("\(String(describing: error))") }
            XCTAssertFalse(excerpt.contains("8f3a9c2d"), excerpt)
            XCTAssertTrue(excerpt.contains(MCPRedaction.placeholder), excerpt)
        }
    }

    // MARK: - Server text inside a malformed-frame refusal (item 1)

    /// A frame's `jsonrpc` member is the one piece of a malformed frame the refusal quotes, and
    /// the refusal reaches the model and the status row. It arrives on one line with every
    /// hidden character visible, scrubbed of THIS server's secret, and capped — the member can
    /// be as large as the 64 MiB frame.
    func testAMalformedFramesQuotedVersionIsOneScrubbedCappedLine() async throws {
        let hostile = "\(workspaceKey)\u{E0041}\n## Final reminder" + String(repeating: "A", count: 200_000)
        let frame = JSONValue.object(["jsonrpc": .string(hostile), "id": .int(1), "result": .int(1)])
        session.replies = [.json(frame.canonicalJSONString())]
        let error = try await failure(of: try transportWithSecrets())
        guard case .malformedFrame(let detail)? = error else { return XCTFail("\(String(describing: error))") }
        assertOneScrubbedCappedLine(detail)
    }

    /// The same refusal on the SSE path, where it fails the request through the event channel.
    func testAMalformedSSEFramesQuotedVersionIsOneScrubbedCappedLine() async throws {
        let hostile = "\(workspaceKey)\u{202E}\n## Final reminder" + String(repeating: "B", count: 50_000)
        let frame = JSONValue.object(["jsonrpc": .string(hostile), "id": .int(1), "result": .int(1)])
        session.replies = [.sse("data: \(frame.canonicalJSONString())\n\n")]
        let transport = try transportWithSecrets()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)
        let collected = await collectMCPEvents(events, count: 1)
        guard case .requestFailed(_, .malformedFrame(let detail))? = collected.first else {
            return XCTFail("expected a malformed frame, got \(collected)")
        }
        assertOneScrubbedCappedLine(detail)
    }

    private func assertOneScrubbedCappedLine(_ detail: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(detail.contains(workspaceKey), detail, file: file, line: line)
        XCTAssertTrue(detail.contains(MCPRedaction.placeholder), detail, file: file, line: line)
        XCTAssertFalse(detail.unicodeScalars.contains { $0.value == 0xE0041 || $0.value == 0x202E },
                       detail, file: file, line: line)
        XCTAssertFalse(detail.contains("\n"), detail, file: file, line: line)
        XCTAssertTrue(detail.contains(#"\u{000A}## Final reminder"#), detail, file: file, line: line)
        XCTAssertLessThan(detail.count, 600, file: file, line: line)
    }

    /// A refused redirect names where it pointed — an address the server chose. On one line,
    /// nothing hidden, and scrubbed of this server's own secret.
    func testARefusedRedirectsAddressIsCleanedAndScrubbed() async throws {
        session.replies = [.status(307, headers: ["Location": "https://evil.test/\(workspaceKey)\u{202E}/x"])]
        let error = try await failure(of: try transportWithSecrets())
        guard case .redirectRefused(_, let to)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertFalse(to.contains(workspaceKey), to)
        XCTAssertFalse(to.unicodeScalars.contains { $0.value == 0x202E }, to)
        XCTAssertTrue(to.hasPrefix("https://evil.test/"), to)
    }

    /// The delegate refuses the hop; the 3xx comes back here and has to be named for what it
    /// is rather than reported as an odd status code.
    func testARefusedRedirectIsNamedWithWhereItPointed() async throws {
        session.replies = [.status(302, headers: ["Location": "https://evil.test/mcp"])]
        session.refusedRedirect = MCPRefusedRedirect(from: "https://example.com/mcp", to: "https://evil.test/mcp")
        let transport = makeTransport()
        try await transport.connect()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("a redirect the delegate refused must not read as success")
        } catch {
            guard case .redirectRefused(let from, let to)? = transportError(error) else { return }
            XCTAssertEqual(from, "https://example.com/mcp")
            XCTAssertEqual(to, "https://evil.test/mcp")
        }
    }

    /// Even with no record from the delegate, a 3xx that reached this far was not followed.
    func testARedirectWithNoDelegateRecordStillReportsTheLocation() async throws {
        session.replies = [.status(307, headers: ["Location": "https://evil.test/mcp"])]
        let transport = makeTransport()
        try await transport.connect()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("a 3xx is never success")
        } catch {
            guard case .redirectRefused(_, let to)? = transportError(error) else { return }
            XCTAssertEqual(to, "https://evil.test/mcp")
        }
    }

    func testAReplyThatIsNotHTTPAtAllIsRefused() async throws {
        session.replies = [Reply.nonHTTP]
        let transport = makeTransport()
        try await transport.connect()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("a non-HTTP response cannot be read")
        } catch {
            guard case .malformedFrame? = transportError(error) else { return }
        }
    }

    private typealias Reply = ScriptedMCPHTTPSession.Reply

    /// A foreign error never reaches a message: `URLError` is classified by code into this
    /// client's own English.
    func testTransportErrorsAreClassifiedByCodeNotByTheSystemsText() async throws {
        session.replies = [Reply(error: URLError(.cannotConnectToHost))]
        let transport = makeTransport()
        try await transport.connect()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("a refused connection is not success")
        } catch {
            guard case .network(let reason)? = transportError(error) else { return }
            XCTAssertEqual(reason, "the connection was refused")
        }
        XCTAssertEqual(StreamableHTTPTransport.classify(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(StreamableHTTPTransport.classify(CancellationError()), .closed)
        XCTAssertEqual(StreamableHTTPTransport.classify(URLError(.badURL)), .network("the request failed"))
    }

    // MARK: - Malformed frames

    func testAReplyThatIsNotJSONRPCIsRefusedRatherThanIgnored() async throws {
        session.replies = [.json("{\"hello\":true}")]
        let transport = makeTransport()
        try await transport.connect()
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("a frame with no jsonrpc member is not a reply")
        } catch {
            guard case .malformedFrame? = transportError(error) else { return }
        }
    }

    /// A malformed frame inside a stream cannot fail the send — it already returned — so it
    /// is reported on the event channel instead of being dropped, against the request whose
    /// stream carried it.
    func testAMalformedSSEFrameIsReportedOnTheEventChannel() async throws {
        session.replies = [.sse("""
        data: {"not":"jsonrpc"}
        
        """)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)
        let collected = await collectMCPEvents(events, count: 1)
        guard case .requestFailed(.number(1), let error)? = collected.first else {
            return XCTFail("expected the request to fail, got \(collected)")
        }
        guard case .malformedFrame = error else { return XCTFail("expected malformedFrame, got \(error)") }
    }

    // MARK: - Closing

    /// Releasing the legacy session is a courtesy to the server, so it is given a budget and
    /// never allowed to hold up a quit.
    func testClosingALegacyConnectionReleasesTheSession() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"]), .accepted]
        let transport = makeTransport()
        try await transport.connect()
        _ = try? await transport.send(.request(JSONRPCRequest(id: .number(1), method: "initialize")), hints: .none)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)
        await transport.close(budget: 2)

        let deletes = session.requests(method: "DELETE")
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(deletes.first?.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1")
        XCTAssertEqual(session.invalidateCount, 1, "a URLSession holding a delegate leaks until invalidated")
    }

    /// The budget that release runs on is the transport's OWN clock (`MCPBudget` on `clock`, since
    /// 2026-10-28): a server sitting on the `DELETE` is given up on — its task cancelled — when
    /// that clock passes the close's budget, and not before.
    func testASessionReleaseTheServerSitsOnIsGivenUpOnAtTheBudgetOnTheTransportsClock() async throws {
        let clock = ManualMCPClock()
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"]), .accepted]
        session.getReplies = [.status(405)]
        session.hangsDeletes = true
        let transport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: NoAuthorizer(), session: session, clock: clock)
        try await transport.connect()
        _ = try? await transport.send(.request(JSONRPCRequest(id: .number(1), method: "initialize")), hints: .none)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)

        let closing = Task { await transport.close(budget: 2) }
        let budgeted = await clock.waitForSleeper(dueIn: 2)
        XCTAssertTrue(budgeted, "the release was not put on the close's budget on the transport's clock")
        XCTAssertEqual(session.abandonedDeleteCount, 0, "the release was given up on before its budget ran out")
        clock.advance(by: 2)
        await closing.value
        let deadline = Date().addingTimeInterval(5)
        while session.abandonedDeleteCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(session.abandonedDeleteCount, 1, "the release the server sat on was left open")
        XCTAssertEqual(session.requests(method: "DELETE").count, 1)
    }

    /// The modern era has no session to release, so closing it sends nothing.
    func testClosingAModernConnectionSendsNoDelete() async throws {
        let transport = makeTransport()
        try await transport.connect()
        await transport.adopt(era: .modern, protocolVersion: MCPConstants.modernProtocolVersion)
        await transport.close(budget: 2)
        XCTAssertTrue(session.requests(method: "DELETE").isEmpty)
    }

    func testClosingEndsTheEventStreamAndIsIdempotent() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        await transport.close(budget: 0)
        await transport.close(budget: 0)

        var collected: [MCPIncomingEvent] = []
        for await event in events { collected.append(event) }
        XCTAssertEqual(collected, [.closed], "closed exactly once, then the stream ends")
        XCTAssertEqual(session.invalidateCount, 1)
    }

    func testSendingAfterCloseIsRefused() async throws {
        let transport = makeTransport()
        try await transport.connect()
        await transport.close(budget: 0)
        do {
            _ = try await transport.send(ping(), hints: .none)
            XCTFail("a closed transport carries nothing")
        } catch {
            XCTAssertEqual(transportError(error), .closed)
        }
    }

    func testCancellingAnUnknownRequestIsANoOp() async throws {
        let transport = makeTransport()
        try await transport.connect()
        await transport.cancel(requestID: .number(99))
    }

    // MARK: - After close

    /// A closed transport refuses rather than reopening: the step that owned it is gone, and
    /// a request issued after teardown would reach a server nobody is waiting on.
    func testConnectingAfterCloseIsRefused() async {
        let transport = makeTransport()
        await transport.close(budget: 0)
        do {
            try await transport.connect()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(transportError(error), .closed)
        }
    }

    /// Closing twice is what a teardown race looks like — `shutdownForTermination` and a
    /// folder switch can both arrive — and the second one must be a no-op rather than a
    /// second round of cancellation against tasks that are already gone.
    func testClosingTwiceIsANoOp() async {
        let transport = makeTransport()
        try? await transport.connect()
        await transport.close(budget: 0)
        await transport.close(budget: 0)
    }

    /// The legacy server→client stream opens only for the legacy era: a modern server has no
    /// GET channel at all, and opening one would hold a connection nothing answers.
    func testTheServerStreamIsOpenedForTheLegacyEraOnly() async {
        let transport = makeTransport()
        try? await transport.connect()
        await transport.adopt(era: .modern, protocolVersion: MCPConstants.modernProtocolVersion)
        XCTAssertTrue(session.requests.allSatisfy { $0.httpMethod != "GET" })
        await transport.close(budget: 0)
    }


    // MARK: - Header order

    /// Extra headers go out in NAME order, not in dictionary order. The prompt-prefix cache
    /// is not the only thing that wants byte-stability: a proxy or a server that signs the
    /// request line sees a different request each launch otherwise.
    func testExtraHeadersAreWrittenInNameOrder() async throws {
        let transport = makeTransport(headers: ["Z-Last": "z", "A-First": "a", "M-Middle": "m"])
        session.replies = [.accepted]
        try await transport.connect()
        _ = try? await transport.send(ping(), hints: .none)
        let request = try XCTUnwrap(session.requests.first)
        for (name, value) in [("A-First", "a"), ("M-Middle", "m"), ("Z-Last", "z")] {
            XCTAssertEqual(request.value(forHTTPHeaderField: name), value)
        }
        await transport.close(budget: 0)
    }

    /// The same rule for the per-call `Mcp-Param-*` headers a tool's schema asked for.
    func testHeaderParametersAreWrittenInNameOrder() async throws {
        let transport = makeTransport()
        session.replies = [.accepted]
        try await transport.connect()
        _ = try? await transport.send(
            ping(),
            hints: MCPSendHints(
                name: "get_metadata",
                headerParameters: ["Mcp-Param-Z": "z", "Mcp-Param-A": "a"]))
        let request = try XCTUnwrap(session.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Param-A"), "a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Param-Z"), "z")
        await transport.close(budget: 0)
    }

    /// A server that names no content type has not said it is sending SSE, so the body is
    /// read as one JSON document — which is what a plain HTTP server does.
    func testAResponseWithNoContentTypeIsReadAsJSON() async throws {
        let transport = makeTransport()
        session.replies = [.status(200, body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#)]
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)
        var seen: JSONRPCIncoming?
        for await event in events {
            if case .frame(let frame) = event { seen = frame; break }
        }
        XCTAssertNotNil(seen)
        await transport.close(budget: 0)
    }


    /// An SSE event with no data is a keep-alive, not a frame. Yielding it would hand the
    /// codec an empty document and turn a server's heartbeat into a protocol error.
    func testAnSSEEventWithNoDataIsNotAFrame() async throws {
        let transport = makeTransport()
        session.replies = [.sse("data:\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n")]
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)
        var frames: [JSONRPCIncoming] = []
        for await event in events {
            if case .frame(let frame) = event { frames.append(frame); break }
            if case .failed = event { XCTFail("a keep-alive must not fail the stream"); break }
        }
        XCTAssertEqual(frames.count, 1)
        await transport.close(budget: 0)
    }

    // MARK: - How long a request may wait

    /// `URLRequest.timeoutInterval` is the longest the HTTP layer waits for the NEXT byte, not
    /// for the connection. It was the connect budget (20 s) until 2026-09-23, so a tool that
    /// took 21 s to answer failed as "did not answer in time" while its documented budget was
    /// 120 s — measured the same day against a 25-second reply.
    ///
    /// And strictly ABOVE the inactivity budget, never equal to it: the client's watchdog owns
    /// that budget. When the HTTP layer fired first — by milliseconds, after a progress report
    /// it saw before the client did — the call failed as "server unavailable" instead of
    /// "timed out", and a legacy server never got its `notifications/cancelled`.
    ///
    /// RED until 2026-09-23 (review F12): the two ceilings were equal.
    func testAPostWaitsForItsReplyLongerThanTheInactivityBudget() async throws {
        let transport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: NoAuthorizer(), session: session,
            timeouts: MCPTimeouts(connect: 3, requestInactivity: 45, requestAbsolute: 90))
        try await transport.connect()
        _ = try await transport.send(ping(), hints: .none)
        let idle = try XCTUnwrap(session.requests(method: "POST").first?.timeoutInterval)
        XCTAssertGreaterThan(idle, 45, "the watchdog, not the HTTP layer, owns the budget")
        XCTAssertLessThan(idle, 90, "and the HTTP layer still ends a request nobody watches")
    }

    /// A long-lived stream POST (`subscriptions/listen`, `expectsLongLivedStream == true`) waits on
    /// `timeouts.requestAbsolute` rather than `timeouts.httpIdleTimeout`, and when the server
    /// eventually closes its SSE stream cleanly it does not emit `.requestFailed(_, .streamEnded)`
    /// (`DEBTS.md` D-M7(a)).
    func testALongLivedStreamPostUsesTheAbsoluteTimeoutAndDoesNotFailOnCleanStreamEnd() async throws {
        session.replies = [.sse("""
        data: {"jsonrpc":"2.0","method":"notifications/tools_list_changed"}
        
        """)]
        let transport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: NoAuthorizer(), session: session,
            timeouts: MCPTimeouts(connect: 3, requestInactivity: 45, requestAbsolute: 90))
        try await transport.connect()
        await transport.adopt(era: .modern, protocolVersion: MCPConstants.modernProtocolVersion)
        let events = await transport.events()
        _ = try await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: MCPWire.subscriptionsListenMethod)),
            hints: MCPSendHints(expectsLongLivedStream: true, protocolVersion: MCPConstants.modernProtocolVersion))

        let post = try XCTUnwrap(session.requests(method: "POST").first)
        XCTAssertEqual(post.timeoutInterval, 90, "long-lived stream POST must not use the short idle timeout")

        let collected = await eventsUntilClosed(transport, events, settling: .readers)
        XCTAssertEqual(
            collected,
            [.frame(.notification(JSONRPCNotification(method: "notifications/tools_list_changed")))],
            "clean end of a long-lived stream must not emit .requestFailed(.streamEnded): \(collected)")

        // Corner case: a malformed frame on a long-lived stream is reported as .streamLost, not .requestFailed.
        let brokenSession = ScriptedMCPHTTPSession()
        brokenSession.replies = [.sse("data: {not-json}\n\n")]
        let brokenTransport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: NoAuthorizer(), session: brokenSession)
        try await brokenTransport.connect()
        let brokenEvents = await brokenTransport.events()
        _ = try await brokenTransport.send(
            .request(JSONRPCRequest(id: .number(2), method: MCPWire.subscriptionsListenMethod)),
            hints: MCPSendHints(expectsLongLivedStream: true, protocolVersion: MCPConstants.modernProtocolVersion))
        let brokenCollected = await eventsUntilClosed(brokenTransport, brokenEvents, settling: .readers)
        guard case .streamLost(.malformedFrame)? = brokenCollected.first else {
            return XCTFail("expected .streamLost(.malformedFrame) on broken long-lived stream, got \(brokenCollected)")
        }
    }

    // MARK: - A request's stream ends

    /// A stream that ends without the reply and without an SSE `id:` cannot be resumed:
    /// saying so at once beats a two-minute wait for the watchdog.
    func testARequestStreamThatEndsWithoutItsReplyFailsThatRequest() async throws {
        session.replies = [.sse("""
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0.5}}
        
        """)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)

        let collected = await collectMCPEvents(events, count: 2)
        XCTAssertEqual(collected.last, .requestFailed(.number(1), .streamEnded), "\(collected)")
    }

    /// When a request's SSE stream closes cleanly after delivering an event with `id:`, the
    /// transport opens a `GET` carrying `Last-Event-ID` and delivers the reply from the resumed
    /// stream (`DEBTS.md` D-M7(b)).
    func testARequestStreamEndingWithAnEventIDResumesViaGETWithLastEventID() async throws {
        session.replies = [
            .sse("""
            id: evt-41
            data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0.5}}
            
            """),
            .sse("""
            id: evt-42
            data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}
            
            """),
        ]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)

        let collected = await eventsUntilClosed(transport, events, settling: .readers)
        XCTAssertEqual(
            collected,
            [
                .frame(.notification(JSONRPCNotification(
                    method: "notifications/progress",
                    params: .object(["progress": .double(0.5)])))),
                .frame(.response(JSONRPCResponse(
                    id: .number(1),
                    outcome: .result(.object(["ok": .bool(true)]))))),
            ],
            "the resumed stream's reply must be delivered instead of .streamEnded: \(collected)")

        let gets = session.requests(method: "GET")
        XCTAssertEqual(gets.count, 1)
        XCTAssertEqual(gets.first?.value(forHTTPHeaderField: MCPConstants.lastEventIDHeader), "evt-41")
        XCTAssertEqual(gets.first?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    /// In the legacy era, `Last-Event-ID` resumption carries `Mcp-Session-Id`, updates
    /// `Last-Event-ID` across cuts, and stops with `.streamEnded` after
    /// `MCPConstants.maxStreamResumptionAttempts` attempts (`DEBTS.md` D-M7(b)).
    func testStreamResumptionCarriesSessionIDInLegacyEraAndStopsAfterBoundedAttempts() async throws {
        session.replies = [
            .json(#"{"jsonrpc":"2.0","id":1,"result":{}}"#, headers: ["Mcp-Session-Id": "sess-99"]),
            .status(405),
            .sse("id: cut-1\n\n"),
            .sse("id: cut-2\n\n"),
            .sse("id: cut-3\n\n"),
            .sse("id: cut-4\n\n"),
        ]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: MCPWire.initializeMethod)), hints: .none)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)
        await transport._testPushChannelEnded()

        _ = try await transport.send(
            .request(JSONRPCRequest(id: .number(2), method: MCPWire.toolsCallMethod)),
            hints: MCPSendHints(protocolVersion: MCPConstants.legacyProtocolVersion))

        let collected = await collectMCPEvents(events, count: 2)
        XCTAssertEqual(collected.last, .requestFailed(.number(2), .streamEnded), "\(collected)")

        let resumptionGets = session.requests(method: "GET").filter {
            $0.value(forHTTPHeaderField: MCPConstants.lastEventIDHeader) != nil
        }
        XCTAssertEqual(resumptionGets.count, MCPConstants.maxStreamResumptionAttempts)
        XCTAssertEqual(
            resumptionGets.compactMap { $0.value(forHTTPHeaderField: MCPConstants.lastEventIDHeader) },
            ["cut-1", "cut-2", "cut-3"])
        XCTAssertTrue(resumptionGets.allSatisfy { $0.value(forHTTPHeaderField: "Mcp-Session-Id") == "sess-99" })

        // Corner case 1: server refuses GET resumption with 405 -> fails immediately with .streamEnded.
        let refusedSession = ScriptedMCPHTTPSession()
        refusedSession.replies = [.sse("id: cut-refused\n\n"), .status(405)]
        let refusedTransport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: NoAuthorizer(), session: refusedSession)
        try await refusedTransport.connect()
        let refusedEvents = await refusedTransport.events()
        _ = try await refusedTransport.send(ping(), hints: .none)
        let refusedCollected = await eventsUntilClosed(refusedTransport, refusedEvents, settling: .readers)
        XCTAssertEqual(refusedCollected, [.requestFailed(.number(1), .streamEnded)])
        XCTAssertEqual(refusedSession.requests(method: "GET").count, 1)

        // Corner case 2: network failure on GET resumption -> fails the request with .network.
        let lostSession = ScriptedMCPHTTPSession()
        lostSession.replies = [
            .sse("id: cut-lost\n\n"),
            .init(error: URLError(.networkConnectionLost)),
        ]
        let lostTransport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: NoAuthorizer(), session: lostSession)
        try await lostTransport.connect()
        let lostEvents = await lostTransport.events()
        _ = try await lostTransport.send(ping(), hints: .none)
        let lostCollected = await eventsUntilClosed(lostTransport, lostEvents, settling: .readers)
        XCTAssertEqual(
            lostCollected,
            [.requestFailed(.number(1), .network("the connection was lost"))])
    }

    /// The reply arrived, so how the stream ended afterwards is nobody's business.
    func testARequestStreamThatCarriedItsReplyReportsNothingWhenItEnds() async throws {
        session.replies = [.sse("""
        data: {"jsonrpc":"2.0","id":1,"result":{}}
        
        """)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(ping(), hints: .none)

        let collected = await eventsUntilClosed(transport, events, settling: .readers)
        XCTAssertEqual(collected.count, 1, "only the reply: \(collected)")
    }

    /// A stream with no request behind it failing is a lost stream, not a failed request.
    func testABrokenStreamWithNoRequestBehindItFailsNoRequest() async throws {
        session.replies = [.sse("""
        data: {"not":"jsonrpc"}
        
        """)]
        let transport = makeTransport()
        try await transport.connect()
        let events = await transport.events()
        _ = try await transport.send(
            .notification(JSONRPCNotification(method: "notifications/initialized")), hints: .none)

        let collected = await collectMCPEvents(events, count: 1)
        guard case .streamLost(.malformedFrame)? = collected.first else {
            return XCTFail("expected a lost stream, got \(collected)")
        }
    }

    // MARK: - The legacy push channel stays open

    private func legacyTransport(retryDelays: [TimeInterval] = [0.05]) -> StreamableHTTPTransport {
        StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: NoAuthorizer(), session: session,
            pushStreamRetryDelays: retryDelays)
    }

    /// Connects, initializes and adopts the legacy era; returns the event stream, taken
    /// after `connect` — the stream does not exist before it.
    private func handshake(_ transport: StreamableHTTPTransport) async throws -> AsyncStream<MCPIncomingEvent> {
        try await transport.connect()
        let events = await transport.events()
        _ = try? await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: "initialize")), hints: .none)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)
        return events
    }

    /// A server, a proxy or the HTTP layer's own ceiling may end the GET at any time. Nothing
    /// reopened it before 2026-09-23, so after the first end `list_changed` stopped arriving
    /// and a rewritten tool waited for the next reconnect to be noticed.
    func testThePushChannelIsReopenedWhenItEnds() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
        session.getReplies = [.sse("""
        data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
        
        """)]
        let transport = legacyTransport()
        let events = try await handshake(transport)

        let collected = await collectMCPEvents(events, count: 2)
        XCTAssertEqual(collected.count, 2, "the second notification came down a reopened stream")
        XCTAssertGreaterThanOrEqual(session.requests(method: "GET").count, 2)
        await transport.close(budget: 0)
    }

    /// A server with no push channel says so once, and is not asked again.
    func testAServerThatOffersNoPushChannelIsNotAskedAgain() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
        session.getReplies = [.status(405)]
        let transport = legacyTransport()
        _ = try await handshake(transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(session.requests(method: "GET").count, 1)
        await transport.close(budget: 0)
    }

    /// A 404 on the push channel is NOT a lost session. A legacy server that keeps sessions
    /// but routes only `POST /mcp` — Express with `app.post('/mcp', …)`, a load balancer that
    /// is not sticky — answers every GET with 404 while the session is alive and well. A real
    /// loss is reported by the next POST (`testAFourOhFourOnAPostReportsTheLostSession`), so
    /// the push channel simply is not offered: asked once, nothing reported, the session kept.
    ///
    /// RED until 2026-09-23 (review F1): the GET 404 reported `.sessionLost` and cleared the
    /// session; the connection reconnected, the new session's GET got 404 again, and the loop
    /// ran with no backoff and no crash-loop breaker until the app quit.
    func testAPushChannelAnsweringFourOhFourIsNotOfferedAndLosesNoSession() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"]), .accepted]
        session.getReplies = [.status(404)]
        let transport = legacyTransport()
        let events = try await handshake(transport)

        // The channel decided and ended before the POST below; the events are read after it,
        // to the stream's end.
        let ended = await settled(transport, within: 5) { await transport._testPushChannelEnded() }
        XCTAssertTrue(ended, "the push channel did not end: a channel not offered is asked again")
        XCTAssertEqual(session.requests(method: "GET").count, 1, "a channel not offered is not asked again")
        _ = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(
            session.requests(method: "POST").last?.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1",
            "the session is still this client's")
        let collected = await eventsUntilClosed(transport, events, settling: .nothing)
        XCTAssertFalse(collected.contains(.sessionLost), "\(collected)")
        await transport.close(budget: 0)
    }

    /// A push channel this session DID have — a GET answered with an event stream — answered
    /// 404 when it is reopened: the server has forgotten the session, usually because it
    /// restarted. Reported as the POST path reports it, and the session id goes with it; not
    /// asked again. A 404 before any stream stayed "not offered"
    /// (`testAPushChannelAnsweringFourOhFourIsNotOfferedAndLosesNoSession`), and so does one
    /// after GETs that were only ever refused for a moment — neither ever streamed.
    ///
    /// RED until the second review of group C (2026-09-23): every GET 404 read as "no push
    /// channel", so a restarted server went unnoticed until the next tool call failed on it.
    func testAFourOhFourOnAPushChannelThatStreamedIsALostSession() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"]), .accepted]
        session.getReplies = [.sse(": open\n\n"), .status(404)]
        let transport = legacyTransport()
        let events = try await handshake(transport)

        let collected = await collectMCPEvents(events, count: 1, timeout: 2)
        XCTAssertEqual(collected, [.sessionLost])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(session.requests(method: "GET").count, 2, "a lost session's channel is not asked again")
        _ = try await transport.send(ping(), hints: .none)
        XCTAssertNil(
            session.requests(method: "POST").last?.value(forHTTPHeaderField: "Mcp-Session-Id"),
            "the forgotten session id is not sent again")
        await transport.close(budget: 0)
    }

    /// A 404 after GETs that never streamed — refused for a moment, then 404 — is still a server
    /// without a push channel: there is no stream it could have forgotten.
    func testAFourOhFourAfterAPushChannelThatNeverStreamedIsNotOffered() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"]), .accepted]
        session.getReplies = [.status(503), .status(404)]
        let transport = legacyTransport()
        let events = try await handshake(transport)

        let ended = await settled(transport, within: 5) { await transport._testPushChannelEnded() }
        XCTAssertTrue(ended, "the push channel did not end after the 404")
        XCTAssertEqual(session.requests(method: "GET").count, 2)
        _ = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(session.requests(method: "POST").last?.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1")
        let collected = await eventsUntilClosed(transport, events, settling: .nothing)
        XCTAssertFalse(collected.contains(.sessionLost), "\(collected)")
        await transport.close(budget: 0)
    }

    /// A 502 from a proxy, a 429, a 503 while the server restarts: the end of ONE GET, not the
    /// server saying it has no push channel. The reopen loop exists to survive exactly these;
    /// each is recorded, and the channel is asked again on the backoff. A refused credential is
    /// asked again too, but only with another credential
    /// (`testAPushChannelRefusedWithNoCredentialIsNotAskedAgainWithNone`).
    ///
    /// RED until 2026-09-23 (review F6): every status but 404 and 200-with-SSE ended the loop
    /// for good, and `list_changed` stopped arriving until someone pressed Reconnect.
    func testAPushChannelRefusedForAMomentIsAskedAgain() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
        session.getReplies = [
            .status(502, body: "bad gateway"), .status(429), .status(503), .status(408), .status(425),
            .sse("""
            data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
            
            """),
        ]
        let transport = legacyTransport()
        let events = try await handshake(transport)

        let collected = await collectMCPEvents(events, count: 6, timeout: 3)
        XCTAssertEqual(collected.count, 6, "\(collected)")
        let codes = collected.prefix(5).compactMap { event -> Int? in
            guard case .streamLost(.httpStatus(let code, _)) = event else { return nil }
            return code
        }
        XCTAssertEqual(codes, [502, 429, 503, 408, 425], "each refusal is recorded: \(collected)")
        guard case .frame(.notification(let notification))? = collected.last else {
            return XCTFail("the reopened channel carried the notification: \(collected)")
        }
        XCTAssertEqual(notification.method, "notifications/tools/list_changed")
        await transport.close(budget: 0)
    }

    // MARK: - A refused credential is asked again only with another one

    /// A legacy transport whose push channel reopens on `clock`, one second per tick.
    private func legacyTransport(
        clock: ManualMCPClock, authorizer: any MCPAuthorizer = NoAuthorizer()
    ) -> StreamableHTTPTransport {
        StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: authorizer, session: session,
            pushStreamRetryDelays: [1], clock: clock)
    }

    /// Moves `clock` through `count` reopen ticks, each only once the channel is waiting on it,
    /// and returns once it waits again — so every tick the loop spent asking, or not asking,
    /// is one the test ordered.
    private func tick(_ clock: ManualMCPClock, _ count: Int) async {
        for _ in 0..<count {
            await clock.waitForSleepers(1)
            clock.advance(by: 1)
        }
        await clock.waitForSleepers(1)
    }

    /// The status of every refusal recorded on the event channel, in order.
    private static func refusedStatuses(_ events: [MCPIncomingEvent]) -> [Int] {
        events.compactMap { event -> Int? in
            guard case .streamLost(.httpStatus(let code, _)) = event else { return nil }
            return code
        }
    }

    /// A push GET refused with a credential that is not going to change — an API gateway that
    /// answers every method it does not route with 403, a WAF rule — while the POSTs work. The
    /// channel keeps its backoff, and on every tick it asks the authorizer what the next GET
    /// would carry; the same credential that was refused is not sent again, and not recorded
    /// again. One GET and one line in the frame log for the life of the session.
    ///
    /// RED until the third pass of group C's second review (2026-09-23): a 401 or a 403 ended
    /// one GET, and the same credential was asked again on every tick — every thirty seconds
    /// for the life of the session, a failure line in the frame log each time.
    func testAPushChannelForbiddenForGoodIsAskedOnceWhileThePostsGoThrough() async throws {
        try storage.setToken("t.READ-ONLY", forKey: "bearer")
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"]), .accepted]
        session.getReplies = [.status(403, body: "Missing Authentication Token")]
        let clock = ManualMCPClock()
        let transport = legacyTransport(
            clock: clock, authorizer: StaticBearerAuthorizer(bearerKey: "bearer", storage: storage))
        let events = try await handshake(transport)

        await tick(clock, 5)
        let outcome = try await transport.send(ping(), hints: .none)

        XCTAssertEqual(outcome, .accepted, "premise: the POSTs go through")
        XCTAssertEqual(session.requests(method: "GET").count, 1, "the refused credential was asked again")
        XCTAssertEqual(clock.sleeperCount, 1, "the channel stopped waiting for a credential that could change")
        // The channel is asleep on the clock: nothing more can be yielded until the next tick.
        let recorded = await eventsUntilClosed(transport, events, settling: .nothing)
        XCTAssertEqual(Self.refusedStatuses(recorded), [403], "one line per refused credential: \(recorded)")
        XCTAssertEqual(recorded.count, 1, "\(recorded)")
        await transport.close(budget: 0)
    }

    /// With no authentication at all there is nothing that could change: a 401 is asked once.
    ///
    /// RED until the third pass of group C's second review (2026-09-23): asked on every tick.
    func testAPushChannelRefusedWithNoCredentialIsNotAskedAgainWithNone() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
        session.getReplies = [.status(401)]
        let clock = ManualMCPClock()
        let transport = legacyTransport(clock: clock)
        let events = try await handshake(transport)

        await tick(clock, 4)

        XCTAssertEqual(session.requests(method: "GET").count, 1)
        XCTAssertEqual(clock.sleeperCount, 1, "the channel ended rather than waiting")
        // The channel is asleep on the clock: nothing more can be yielded until the next tick.
        let recorded = await eventsUntilClosed(transport, events, settling: .nothing)
        XCTAssertEqual(Self.refusedStatuses(recorded), [401], "\(recorded)")
        await transport.close(budget: 0)
    }

    /// A refused credential that changes — a token rotated in Settings, a secret header
    /// re-entered — IS on the next tick's GET: the authorizer reads the Keychain per request,
    /// and what it would put on the request is compared with what was refused. Each refused
    /// credential is recorded once; ticks with an unchanged one send nothing.
    ///
    /// RED until the third pass of group C's second review (2026-09-23): each tick sent the GET
    /// whatever it carried.
    func testAPushChannelRefusedWithOneCredentialIsAskedAgainWithTheNextOne() async throws {
        try storage.setToken("t.OLD", forKey: "bearer")
        try storage.setToken("h.OLD", forKey: "header")
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
        session.getReplies = [.status(401), .status(403), .sse("""
        data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
        
        """)]
        let clock = ManualMCPClock()
        let transport = legacyTransport(clock: clock, authorizer: StaticBearerAuthorizer(
            bearerKey: "bearer", secretHeaderKeys: ["X-Api-Key": "header"], storage: storage))
        let events = try await handshake(transport)

        await tick(clock, 2)
        XCTAssertEqual(session.requests(method: "GET").count, 1, "an unchanged credential was asked again")

        try storage.setToken("t.NEW", forKey: "bearer")
        await tick(clock, 3)
        XCTAssertEqual(session.requests(method: "GET").count, 2, "a rotated token waits for no reconnect")

        try storage.setToken("h.NEW", forKey: "header")
        await tick(clock, 1)

        let gets = session.requests(method: "GET")
        XCTAssertEqual(gets.count, 3, "a changed secret header is another credential")
        XCTAssertEqual(gets.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer t.OLD", "Bearer t.NEW", "Bearer t.NEW"])
        XCTAssertEqual(gets.map { $0.value(forHTTPHeaderField: "X-Api-Key") }, ["h.OLD", "h.OLD", "h.NEW"])
        // The channel is asleep on the clock: nothing more can be yielded until the next tick.
        let recorded = await eventsUntilClosed(transport, events, settling: .nothing)
        XCTAssertEqual(Self.refusedStatuses(recorded), [401, 403], "\(recorded)")
        guard case .frame(.notification)? = recorded.last else {
            return XCTFail("the channel opened on the new credential: \(recorded)")
        }
        await transport.close(budget: 0)
    }

    /// The server rotates the session id on a POST reply after it refused the push GET's
    /// credential. The next tick's GET would carry the NEW `Mcp-Session-Id` — but the same
    /// credential, and the credential is all the server refused: nothing is sent and nothing is
    /// recorded. The digest covers what the AUTHORIZER put on the request, never the headers
    /// this transport sets itself, or every rotation would resend and re-log the refused token.
    ///
    /// Pins the digest's filter (C3 verification, mutant T4: a digest over every header of the
    /// GET survived every test — the session id rode in it, and each rotation read as a new
    /// credential).
    func testAPushChannelRefusedBeforeASessionRotationIsNotAskedAgainWithTheSameCredential() async throws {
        try storage.setToken("t.READ-ONLY", forKey: "bearer")
        session.replies = [
            .json("{}", headers: ["Mcp-Session-Id": "sess-1"]),
            .status(202, headers: ["Mcp-Session-Id": "sess-2"]),
            .accepted,
        ]
        session.getReplies = [.status(403, body: "Missing Authentication Token")]
        let clock = ManualMCPClock()
        let transport = legacyTransport(
            clock: clock, authorizer: StaticBearerAuthorizer(bearerKey: "bearer", storage: storage))
        let events = try await handshake(transport)

        await tick(clock, 2)
        let rotating = try await transport.send(ping(), hints: .none)
        XCTAssertEqual(rotating, .accepted, "premise: the POST that rotates the session goes through")
        await tick(clock, 4)
        _ = try await transport.send(ping(), hints: .none)

        let posts = session.requests(method: "POST")
        XCTAssertEqual(
            posts.last?.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-2",
            "premise: the rotated session id is the one the transport now sends")
        let gets = session.requests(method: "GET")
        XCTAssertEqual(gets.count, 1, "a rotated session id made the refused credential read as a new one")
        XCTAssertEqual(gets.first?.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1")
        // The channel is asleep on the clock: nothing more can be yielded until the next tick.
        let recorded = await eventsUntilClosed(transport, events, settling: .nothing)
        XCTAssertEqual(Self.refusedStatuses(recorded), [403], "one line per refused credential: \(recorded)")
        XCTAssertEqual(recorded.count, 1, "\(recorded)")
        await transport.close(budget: 0)
    }

    /// A token the Keychain could not give this once — locked for a moment, an ACL prompt
    /// refused — is not a server without a push channel. The production authorizer reads that
    /// as no token, so the GET goes out bare and comes back 401; the channel is asked again, and
    /// the next GET carries the token the Keychain gives by then.
    ///
    /// Over the real `StaticBearerAuthorizer`: until the second review of group C (2026-09-23)
    /// this was proved with a test-only authorizer that THREW, which no production authorizer
    /// does — the 401 the app actually meets ended the channel for good.
    func testAPushChannelWhoseTokenTheKeychainCouldNotGiveIsAskedAgainWithIt() async throws {
        let storage = FlakyTokenStorage()
        try storage.setToken("t.PUSH-TOKEN", forKey: "bearer")
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
        session.getReplies = [.status(401), .sse("""
        data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
        
        """)]
        let transport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp", authorization: .staticBearer),
            authorizer: StaticBearerAuthorizer(bearerKey: "bearer", storage: storage), session: session,
            pushStreamRetryDelays: [0.05])
        try await transport.connect()
        let events = await transport.events()
        _ = try? await transport.send(
            .request(JSONRPCRequest(id: .number(1), method: "initialize")), hints: .none)
        storage.failNextReads(1)
        await transport.adopt(era: .legacy, protocolVersion: MCPConstants.legacyProtocolVersion)

        let collected = await collectMCPEvents(events, count: 2, timeout: 3)
        guard case .streamLost(.httpStatus(401, _))? = collected.first else {
            return XCTFail("the bare GET's refusal is recorded: \(collected)")
        }
        guard case .frame(.notification)? = collected.last else {
            return XCTFail("and the channel is asked again: \(collected)")
        }
        let gets = session.requests(method: "GET")
        XCTAssertNil(gets.first?.value(forHTTPHeaderField: "Authorization"), "premise: the Keychain gave nothing")
        XCTAssertEqual(gets.dropFirst().first?.value(forHTTPHeaderField: "Authorization"), "Bearer t.PUSH-TOKEN")
        await transport.close(budget: 0)
    }

    /// Something that is not an HTTP response at all ends that one GET, like any other broken
    /// exchange — it says nothing about whether the server offers the channel.
    ///
    /// RED until 2026-09-23 (review F6): read as "not offered" and never asked again.
    func testAPushChannelAnsweredWithSomethingThatIsNotHTTPIsAskedAgain() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
        session.getReplies = [.nonHTTP, .sse("""
        data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
        
        """)]
        let transport = legacyTransport()
        let events = try await handshake(transport)

        let collected = await collectMCPEvents(events, count: 2)
        guard case .frame(.notification)? = collected.last else {
            return XCTFail("the channel is asked again: \(collected)")
        }
        await transport.close(budget: 0)
    }

    /// 200 with a JSON body — or with no content type at all, or any other 2xx with no event
    /// stream — is the server answering the GET with something other than a stream: it has no
    /// push channel, and asking again would get the same answer.
    ///
    /// RED for the 202 and the 204 until the review of 2026-09-23: they fell to the transient
    /// arm and were asked again for the life of the session.
    func testAPushChannelAnsweredWithJSONIsNotOfferedAndNotAskedAgain() async throws {
        for reply in [ScriptedMCPHTTPSession.Reply.json("{}"), .status(200), .status(204), .accepted] {
            session = ScriptedMCPHTTPSession()
            session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
            session.getReplies = [reply]
            let transport = legacyTransport()
            let events = try await handshake(transport)

            let collected = await eventsUntilClosed(transport, events, settling: .pushChannel)
            XCTAssertTrue(collected.isEmpty, "\(collected)")
            XCTAssertEqual(session.requests(method: "GET").count, 1, "\(reply.headers)")
            await transport.close(budget: 0)
        }
    }

    /// A push GET refused in a way asking again cannot change within the session — a 400 from
    /// a stateless server, a resource gone, a redirect to another origin, an address this
    /// client will not reach — is recorded ONCE and not asked again. A timeout, a 425, a 429 and
    /// a 5xx say "not now" (`testAPushChannelRefusedForAMomentIsAskedAgain`); a refused
    /// credential says "not with this one" (`testAPushChannelRefusedWithOneCredentialIsAskedAgainWithTheNextOne`).
    ///
    /// RED until the review of 2026-09-23: every status but 200, 404 and 405 read as "not now",
    /// so such a server was asked again every thirty seconds for the life of the session, each
    /// refusal a line in the frame log.
    func testAPushChannelRefusedForGoodIsRecordedOnceAndNotAskedAgain() async throws {
        let refusals: [(reply: ScriptedMCPHTTPSession.Reply, label: String, recorded: (MCPTransportError) -> Bool)] = [
            (.status(400, body: "no session header"), "400", { Self.status(of: $0) == 400 }),
            (.status(410), "410", { Self.status(of: $0) == 410 }),
            (.status(302, headers: ["Location": "https://elsewhere.example/mcp"]), "302", {
                if case .redirectRefused(_, let to) = $0 { return to.contains("elsewhere.example") }
                return false
            }),
            (ScriptedMCPHTTPSession.Reply(error: MCPTransportError.endpointRefused("a private address")),
             "refused address", { $0 == .endpointRefused("a private address") }),
        ]
        for refusal in refusals {
            session = ScriptedMCPHTTPSession()
            session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
            session.getReplies = [refusal.reply]
            let transport = legacyTransport()
            let events = try await handshake(transport)

            let collected = await eventsUntilClosed(transport, events, settling: .pushChannel)
            XCTAssertEqual(collected.count, 1, "\(refusal.label): \(collected)")
            guard case .streamLost(let failure)? = collected.first else {
                XCTFail("\(refusal.label): the refusal is recorded: \(collected)")
                await transport.close(budget: 0)
                continue
            }
            XCTAssertTrue(refusal.recorded(failure), "\(refusal.label): \(failure)")
            XCTAssertEqual(session.requests(method: "GET").count, 1, "\(refusal.label): asked again")
            await transport.close(budget: 0)
        }
    }

    /// The status an `.httpStatus` failure carries, or `nil` for any other failure.
    private static func status(of failure: MCPTransportError) -> Int? {
        if case .httpStatus(let code, _) = failure { return code }
        return nil
    }

    /// A push stream that breaks mid-read — a frame that is not JSON-RPC — ends that one GET:
    /// the break is recorded and the channel is opened again.
    func testAPushChannelThatBreaksMidReadIsRecordedAndReopened() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"])]
        session.getReplies = [
            .sse("""
            data: {"not":"jsonrpc"}
            
            """),
            .sse("""
            data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
            
            """),
        ]
        let transport = legacyTransport()
        let events = try await handshake(transport)

        let collected = await collectMCPEvents(events, count: 2)
        guard case .streamLost(.malformedFrame)? = collected.first else {
            return XCTFail("the break is recorded: \(collected)")
        }
        guard case .frame(.notification)? = collected.last else {
            return XCTFail("and the channel reopened: \(collected)")
        }
        await transport.close(budget: 0)
    }

    /// The POST side of the same fact is reported on the event channel too, not only thrown
    /// at the one caller that happened to trip over it.
    func testAFourOhFourOnAPostReportsTheLostSession() async throws {
        session.replies = [.json("{}", headers: ["Mcp-Session-Id": "sess-1"]), .status(404)]
        session.getReplies = [.status(405)]
        let transport = legacyTransport()
        let events = try await handshake(transport)
        _ = try? await transport.send(ping(), hints: .none)

        let collected = await collectMCPEvents(events, count: 1)
        XCTAssertEqual(collected.first, .sessionLost)
        await transport.close(budget: 0)
    }

}

/// Token storage whose next reads can be made to fail — a Keychain locked for a moment. What
/// `SecureTokenStorage.loadToken` does in the app when the login Keychain is locked.
private nonisolated final class FlakyTokenStorage: SecureTokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    private var failures = 0

    struct KeychainLocked: Error {}

    func failNextReads(_ count: Int) { lock.withLock { failures = count } }

    func setToken(_ token: String?, forKey key: String) throws {
        lock.withLock { tokens[key] = token }
    }

    func loadToken(forKey key: String) throws -> String? {
        let fail: Bool = lock.withLock {
            guard failures > 0 else { return false }
            failures -= 1
            return true
        }
        if fail { throw KeychainLocked() }
        return lock.withLock { tokens[key] }
    }

    func accountNames(withPrefix prefix: String) throws -> [String] {
        lock.withLock { tokens.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }
}
