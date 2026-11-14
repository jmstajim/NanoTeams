import XCTest

@testable import NanoTeams

/// Which frame answers which request, when a request has waited too long, and what this
/// client will and will not do for a server that asks it something.
final class MCPClientCorrelationTests: XCTestCase {

    private let fastTimeouts = MCPTimeouts(connect: 1, requestInactivity: 2, requestAbsolute: 4)

    private func connectedModern(
        _ transport: ScriptedTransport, timeouts: MCPTimeouts? = nil, clock: (any MCPClock)? = nil
    ) async throws -> MCPClient {
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        let client = MCPClient(
            transport: transport, log: nil, timeouts: timeouts ?? fastTimeouts, clientVersion: "1.0",
            clock: clock ?? MCPSystemClock())
        _ = try await client.connect(cachedEra: nil)
        return client
    }

    /// Returns once the client has handled every frame pushed before it: the reply to this
    /// call rides the same inbound stream, behind them. How a test on a `ManualMCPClock` knows a
    /// progress report has reached the timer before it moves the time.
    private func drain(_ client: MCPClient, _ transport: ScriptedTransport) async throws {
        transport.script("drain", [.result(.null)])
        _ = try await client.call(method: "drain")
    }

    /// Waits — bounded — until a request for `method` has gone out, and returns its id.
    @discardableResult
    private func waitUntilSent(_ method: String, on transport: ScriptedTransport) async throws -> JSONRPCID {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let id = requestID(method, on: transport) { return id }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return try XCTUnwrap(requestID(method, on: transport), "\(method) was never sent")
    }

    private func requestID(_ method: String, on transport: ScriptedTransport) -> JSONRPCID? {
        transport.sent.lazy.compactMap { frame -> JSONRPCID? in
            guard case .request(let request) = frame, request.method == method else { return nil }
            return request.id
        }.first
    }

    /// The legacy `notifications/cancelled` frames sent, by the id each names.
    private func cancellations(on transport: ScriptedTransport) -> [JSONValue] {
        transport.sent.compactMap { frame -> JSONValue? in
            guard case .notification(let notification) = frame,
                  notification.method == MCPWire.cancelledNotification else { return nil }
            return notification.params?.objectValue?["requestId"]
        }
    }

    private func connectedLegacy(
        _ transport: ScriptedTransport, timeouts: MCPTimeouts? = nil, clock: (any MCPClock)? = nil
    ) async throws -> MCPClient {
        transport.script(MCPWire.discoverMethod, [.error(code: MCPErrorCode.methodNotFound, message: "no")])
        transport.script(MCPWire.initializeMethod, [.result(.object([
            "protocolVersion": .string(MCPConstants.legacyProtocolVersion)]))])
        let client = MCPClient(
            transport: transport, log: nil, timeouts: timeouts ?? fastTimeouts, clientVersion: "1.0",
            clock: clock ?? MCPSystemClock())
        _ = try await client.connect(cachedEra: nil)
        return client
    }

    // MARK: - Correlation

    func testRequestIDsAreMonotonicPerConnection() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        transport.script("a", [.result(.string("1"))])
        transport.script("b", [.result(.string("2"))])
        _ = try await client.call(method: "a")
        _ = try await client.call(method: "b")

        let ids = transport.sent.compactMap(\.awaitedResponseID)
        XCTAssertEqual(ids, [.number(1), .number(2), .number(3)], "the probe is request 1")
    }

    /// Two calls in flight at once must not be able to take each other's answer.
    func testTwoCallsInFlightGetTheirOwnAnswers() async throws {
        let transport = ScriptedTransport()
        let clock = ManualMCPClock()
        let client = try await connectedModern(transport, clock: clock)
        transport.script("slow", [.silence])
        transport.script("fast", [.result(.string("fast result"))])

        async let slow: JSONValue = client.call(method: "slow")
        try await waitUntilSent("slow", on: transport)
        let fast = try await client.call(method: "fast")
        XCTAssertEqual(fast, .string("fast result"))

        // The slow one is still waiting; its own timeout is what ends it.
        await clock.waitForSleepers(1)
        clock.advance(by: 6)
        do {
            _ = try await slow
            XCTFail("a silent server answers nothing")
        } catch MCPClientError.timedOut(let method) {
            XCTAssertEqual(method, "slow")
        }
    }

    /// A reply for an id nobody is waiting on is dropped rather than resolving something at
    /// random — the failure a correlation table exists to prevent.
    func testAReplyForAnUnknownIDIsDropped() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        transport.push(.response(JSONRPCResponse(id: .number(4711), outcome: .result(.string("stray")))))
        transport.script("a", [.result(.string("mine"))])
        let result = try await client.call(method: "a")
        XCTAssertEqual(result, .string("mine"))
    }

    func testAServersRefusalBecomesATypedErrorCarryingItsData() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        transport.script("tools/call", [.error(
            code: MCPErrorCode.invalidParams, message: "figi is required",
            data: .object(["field": .string("figi")]))])
        do {
            _ = try await client.call(method: "tools/call")
            XCTFail("a refusal is not a result")
        } catch MCPClientError.rpc(let code, let message, let data) {
            XCTAssertEqual(code, MCPErrorCode.invalidParams)
            XCTAssertEqual(message, "figi is required")
            XCTAssertEqual(data?.objectValue?["field"], .string("figi"))
        }
    }

    /// A server's message rides into a tool result the model reads, so a credential it echoed
    /// back must not survive the trip.
    func testAServersRefusalMessageIsRedacted() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        transport.script("x", [.error(
            code: -32000, message: "rejected Bearer t.SECRET-VALUE-9f3a1c")])
        do {
            _ = try await client.call(method: "x")
            XCTFail("a refusal is not a result")
        } catch MCPClientError.rpc(_, let message, _) {
            XCTAssertFalse(message.contains("t.SECRET-VALUE-9f3a1c"), message)
        }
    }

    /// The refusal message rides into the error envelope the model reads
    /// (`ToolErrorHandler.classify(mcpClientError:)` forwards it as written), so it is cleaned
    /// HERE, where it enters the app: hidden characters out, one line (F24).
    func testAServersRefusalMessageIsSanitizedToOneLine() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        transport.script("x", [.error(
            code: -32000, message: "bad\u{202E} arg\u{E0041}\n\nsecond\u{1B}[2J line\u{200B}")])
        do {
            _ = try await client.call(method: "x")
            XCTFail("a refusal is not a result")
        } catch let error as MCPClientError {
            guard case .rpc(_, let message, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "bad arg second line")
            XCTAssertEqual(
                ToolErrorHandler.classify(mcpClientError: error).message,
                "The server refused the call (-32000): bad arg second line")
        }
    }

    /// The literal secrets this connection sends are scrubbed from the refusal wherever they
    /// appear, and so is the value after any secret header's NAME — the generic patterns know
    /// neither (F11).
    func testAnEchoedSecretIsRedactedFromTheServersRefusal() async throws {
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        let client = MCPClient(
            transport: transport, log: nil, timeouts: fastTimeouts, clientVersion: "1.0",
            credentials: { MCPRedaction.Credentials(headerNames: ["X-Workspace-Key"], values: ["wk_live_8f3a9c2d"]) })
        _ = try await client.connect(cachedEra: nil)
        transport.script("x", [.error(
            code: -32001, message: "key wk_live_8f3a9c2d rejected; X-Workspace-Key: other-9f8e7d")])
        do {
            _ = try await client.call(method: "x")
            XCTFail("a refusal is not a result")
        } catch MCPClientError.rpc(_, let message, _) {
            XCTAssertFalse(message.contains("wk_live_8f3a9c2d"), message)
            XCTAssertFalse(message.contains("other-9f8e7d"), message)
            XCTAssertTrue(message.contains(MCPRedaction.placeholder), message)
            XCTAssertTrue(message.contains("rejected"), message)
        }
    }

    // MARK: - Timers

    /// A long call stays alive by REPORTING, not by being trusted.
    ///
    /// On a `ManualMCPClock`: the test moves the time, so the budget and the reports are
    /// ordered by the test rather than raced on the wall clock. Until 2026-09-23 this raced
    /// three 1.2 s sleeps against the budget and failed on a loaded machine (item 15).
    func testProgressResetsTheInactivityBudget() async throws {
        let transport = ScriptedTransport()
        let clock = ManualMCPClock()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 5, requestAbsolute: 30), clock: clock)
        transport.script("slow", [.silence])

        async let pending: JSONValue = client.call(method: "slow")
        let id = try await waitUntilSent("slow", on: transport)
        await clock.waitForSleepers(1)
        // Three reports 4 s apart outlive a 5 s inactivity budget — 12 s in all — only if each
        // one resets it.
        for _ in 0..<3 {
            clock.advance(by: 4)
            transport.push(.notification(JSONRPCNotification(
                method: MCPWire.progressNotification,
                params: .object(["progressToken": id.jsonValue, "progress": .double(0.5)]))))
            try await drain(client, transport)
        }
        transport.push(.response(JSONRPCResponse(id: id, outcome: .result(.string("done")))))
        let result = try await pending
        XCTAssertEqual(result, .string("done"))
    }

    /// A server that reports progress forever is still a hung call from the role's point of
    /// view, which is why the absolute ceiling exists and nothing resets it.
    func testTheAbsoluteCeilingEndsACallThatKeepsReportingProgress() async throws {
        let transport = ScriptedTransport()
        let clock = ManualMCPClock()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 5, requestAbsolute: 10), clock: clock)
        transport.script("forever", [.silence])

        async let pending: JSONValue = client.call(method: "forever")
        let id = try await waitUntilSent("forever", on: transport)
        await clock.waitForSleepers(1)
        // Every report lands well inside the inactivity budget; the absolute one runs out at 10.
        for _ in 0..<4 {
            clock.advance(by: 3)
            transport.push(.notification(JSONRPCNotification(
                method: MCPWire.progressNotification, params: .object(["progressToken": id.jsonValue]))))
            try await drain(client, transport)
        }
        do {
            _ = try await pending
            XCTFail("the absolute ceiling must fire")
        } catch MCPClientError.timedOut(let method) {
            XCTAssertEqual(method, "forever")
        }
    }

    /// A report that names nothing resets nothing: otherwise a server could hold every
    /// in-flight request open by reporting progress on one.
    func testAProgressReportNamingNoRequestResetsNothing() async throws {
        let transport = ScriptedTransport()
        let clock = ManualMCPClock()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 5, requestAbsolute: 30), clock: clock)
        transport.script("slow", [.silence])

        async let pending: JSONValue = client.call(method: "slow")
        try await waitUntilSent("slow", on: transport)
        await clock.waitForSleepers(1)
        clock.advance(by: 4)
        transport.push(.notification(JSONRPCNotification(
            method: MCPWire.progressNotification, params: .object(["note": .string("working")]))))
        try await drain(client, transport)
        clock.advance(by: 2)
        do {
            _ = try await pending
            XCTFail("an anonymous progress report is not activity on this request")
        } catch MCPClientError.timedOut {
            // expected
        }
    }

    /// A per-call ceiling overrides the connection's, which is what makes the probe short
    /// without shortening every later call.
    ///
    /// On a `ManualMCPClock` (since 2026-10-28; it waited one real second before): the call's
    /// watchdog is armed at ITS ceiling — one second, where the connection's would sleep five —
    /// and the call times out when the clock passes it.
    ///
    /// Every wait here is bounded: a watchdog armed past the clock fails at the arming, and a
    /// call that never ends fails at `boundedValue` — until 2026-10-28 a watchdog
    /// armed on the connection's ceiling instead hung the run here (`absolute: nil` in `call`).
    func testACallCanCarryItsOwnCeiling() async throws {
        let clock = ManualMCPClock()
        let transport = ScriptedTransport()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 60, requestAbsolute: 600), clock: clock)
        transport.script("slow", [.silence])
        let started = Date()
        let calling = Task { try await client.call(method: "slow", timeout: 1) }
        let armed = await clock.waitForSleeper(dueIn: 1)
        XCTAssertTrue(armed, "the call's watchdog was not armed on its own one-second ceiling")
        guard armed else { return calling.cancel() }
        clock.advance(by: 1)
        do {
            _ = try await boundedValue(of: calling, "the call")
            XCTFail("the per-call ceiling must fire")
        } catch MCPClientError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        }
    }

    // MARK: - Cancellation

    /// The legacy era has a courtesy notification; the modern era dropped it, and there
    /// abandoning the stream IS the cancellation. Both happen after the call has already been
    /// settled — neither is something the caller waits for — so they are waited for here.
    func testCancellingALegacyCallTellsTheServerAndClosesTheStream() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        transport.script("slow", [.silence])

        let call = Task { try await client.call(method: "slow") }
        let id = try await waitUntilSent("slow", on: transport)
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("a cancelled call has no result")
        } catch MCPClientError.cancelled {
            // expected
        }
        let deadline = Date().addingTimeInterval(3)
        while cancellations(on: transport).isEmpty || transport.cancelled.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(cancellations(on: transport), [id.jsonValue])
        XCTAssertEqual(transport.cancelled, [id])
    }

    func testCancellingAModernCallClosesItsStreamWithoutANotification() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        transport.script("slow", [.silence])

        let call = Task { try await client.call(method: "slow") }
        try await waitUntilSent("slow", on: transport)
        call.cancel()
        _ = try? await call.value
        let deadline = Date().addingTimeInterval(3)
        while transport.cancelled.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let methods = transport.sent.compactMap(\.method)
        XCTAssertFalse(methods.contains(MCPWire.cancelledNotification))
        XCTAssertEqual(transport.cancelled, [.number(2)])
    }

    /// A `notifications/cancelled` from the server names a request the SERVER sent: its ids are
    /// its own namespace, and this client answers the server's requests at once, with nothing
    /// left to abort. A server cancelling its own `ping` 2 must not fail this client's call 2.
    ///
    /// RED until 2026-09-23 (review, missed): the notification finished the client's own call
    /// with the same id, as cancelled.
    func testAServersCancellationNamesItsOwnRequestsNotThisClients() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        transport.script("slow", [.silence])

        async let pending: JSONValue = client.call(method: "slow")
        let id = try await waitUntilSent("slow", on: transport)
        transport.push(.notification(JSONRPCNotification(
            method: MCPWire.cancelledNotification, params: .object(["requestId": id.jsonValue]))))
        transport.push(.response(JSONRPCResponse(id: id, outcome: .result(.string("done")))))
        let result = try await pending
        XCTAssertEqual(result, .string("done"))
    }

    // MARK: - Abandoning without waiting on the server

    /// Cancelling a legacy call settles it at once. The `notifications/cancelled` it owes the
    /// server is a courtesy, sent on its own, and a server too busy to take it — often the very
    /// one still working on the call — does not hold the caller.
    ///
    /// RED until 2026-09-23 (review F3): the caller waited for the courtesy POST, which could
    /// take the whole inactivity budget — Pause held for two minutes.
    func testCancellingALegacyCallDoesNotWaitForTheCancelledNotification() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        transport.script("slow", [.silence])
        transport.hangNotifications()

        let call = Task { try await client.call(method: "slow") }
        try await waitUntilSent("slow", on: transport)
        let cancelled = Date()
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("a cancelled call has no result")
        } catch MCPClientError.cancelled {
            XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2, "the courtesy POST held the caller")
        }
        await client.close(budget: 0)
    }

    /// The same for a call that timed out: `MCP_TIMED_OUT` arrives when the budget runs out,
    /// not a courtesy POST later.
    ///
    /// RED until 2026-09-23 (review F3).
    func testATimedOutLegacyCallDoesNotWaitForTheCancelledNotification() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        transport.script("slow", [.silence])
        transport.hangNotifications()

        let started = Date()
        do {
            _ = try await client.call(method: "slow", timeout: 0.3)
            XCTFail("a call past its ceiling has no answer")
        } catch MCPClientError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the courtesy POST held the caller")
        }
        await client.close(budget: 0)
    }

    /// The courtesy has a budget of its own: a server that never takes the notification does
    /// not keep its POST open for the rest of the connection.
    ///
    /// RED until 2026-09-23 (review F3): nothing ever gave up on it.
    ///
    /// On the client's `ManualMCPClock` (since 2026-10-28; it waited the two real seconds out):
    /// the courtesy's budget is armed due exactly `courtesyBudget` after the cancel — and while
    /// it sleeps nothing else can end the POST — and the POST is given up on once the clock
    /// passes it.
    func testACancelledNotificationTheServerNeverTakesIsGivenUpOn() async throws {
        let clock = ManualMCPClock()
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 600, requestAbsolute: 600), clock: clock)
        transport.script("slow", [.silence])
        transport.hangNotifications()

        let call = Task { try await client.call(method: "slow") }
        try await waitUntilSent("slow", on: transport)
        let cancelled = Date()
        call.cancel()
        _ = try? await call.value
        let budgeted = await clock.waitForSleeper(dueIn: MCPConstants.courtesyBudget)
        XCTAssertTrue(budgeted, "the courtesy POST was not put on the courtesy budget")
        XCTAssertEqual(transport.abandonedNotificationCount, 0, "the courtesy POST was given up on before its budget ran out")
        clock.advance(by: MCPConstants.courtesyBudget)
        let deadline = cancelled.addingTimeInterval(MCPConstants.courtesyBudget + 3)
        while transport.abandonedNotificationCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(transport.abandonedNotificationCount, 1, "the courtesy POST was left open")
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), MCPConstants.courtesyBudget + 2)
        await client.close(budget: 0)
    }

    /// A call cancelled before it went out is never sent — and a server is never told to cancel
    /// a request it has not seen. When the request did go out, its cancellation follows it:
    /// a legacy server ignores a cancel for an id it does not know yet, and then runs the
    /// request anyway (`send_message` sent, while the call reports cancelled).
    ///
    /// RED until 2026-09-23 (review F13): the cancel could win the race to the actor, post its
    /// courtesy notification, and let the dispatch send the request after it.
    func testACallCancelledBeforeItWentOutIsNeverSentAfterItsCancellation() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        transport.script("write", [.silence])

        for _ in 0..<400 {
            let call = Task { () async throws -> JSONValue in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await client.call(method: "write")
            }
            _ = try? await call.value
        }
        // Frames still in flight from the last calls land within the courtesy budget.
        var settled = transport.sent.count
        let deadline = Date().addingTimeInterval(MCPConstants.courtesyBudget + 1)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if transport.sent.count == settled { break }
            settled = transport.sent.count
        }

        let frames = transport.sent
        var sentAt: [JSONValue: Int] = [:]
        for (index, frame) in frames.enumerated() {
            if case .request(let request) = frame, request.method == "write" { sentAt[request.id.jsonValue] = index }
        }
        for (index, frame) in frames.enumerated() {
            guard case .notification(let notification) = frame,
                  notification.method == MCPWire.cancelledNotification,
                  let named = notification.params?.objectValue?["requestId"] else { continue }
            let request = try XCTUnwrap(sentAt[named], "cancelled \(named), which never went out")
            XCTAssertLessThan(request, index, "\(named): the cancellation went out before the request")
        }
        await client.close(budget: 0)
    }

    /// The HTTP layer giving up on a request is the call timing out, whoever noticed first — the
    /// same code for the model, and for a legacy server the same cancellation. Reported as the
    /// transport's own failure it read as "the server is unavailable, reconnect", and the
    /// server was never told to stop working on the call.
    ///
    /// RED until 2026-09-23 (review F12).
    func testAnHTTPTimeoutOnARequestIsTheCallTimingOut() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        transport.script("slow", [.silence])

        let call = Task { try await client.call(method: "slow") }
        let id = try await waitUntilSent("slow", on: transport)
        transport.pushRequestFailure(id, .timedOut)
        do {
            _ = try await call.value
            XCTFail("a request the HTTP layer gave up on has no answer")
        } catch MCPClientError.timedOut(let method) {
            XCTAssertEqual(method, "slow")
        }
        let deadline = Date().addingTimeInterval(3)
        while !cancellations(on: transport).contains(id.jsonValue), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(cancellations(on: transport), [id.jsonValue], "the server is told to stop")
        await client.close(budget: 0)
    }

    // MARK: - Answering the server off the inbound path

    /// A reply to a server's `ping` is a courtesy, answered on its own task: the stream every
    /// other frame arrives on never waits behind it. A legacy server that takes a minute to
    /// accept the reply's POST must not hold back the response to a call that already came.
    ///
    /// RED until 2026-09-23 (review F14): the inbound pump awaited the reply, and the call's
    /// response sat in the queue until the call timed out.
    func testASlowReplyToAServerRequestDoesNotHoldBackAnotherResponse() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        transport.script("slow", [.silence])

        let call = Task { try await client.call(method: "slow") }
        let id = try await waitUntilSent("slow", on: transport)
        transport.hangResponses()
        transport.push(.request(JSONRPCRequest(id: .string("p1"), method: MCPWire.pingMethod)))
        transport.push(.response(JSONRPCResponse(id: id, outcome: .result(.string("answered")))))
        let started = Date()
        let result = try await call.value
        XCTAssertEqual(result, .string("answered"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        await client.close(budget: 0)
    }

    /// And the reply itself has a budget: a server that never takes it does not keep a POST
    /// open for the rest of the connection.
    ///
    /// RED until 2026-09-23 (review F14).
    ///
    /// On the client's `ManualMCPClock` (since 2026-10-28): the reply's budget is the courtesy
    /// budget, and the POST is given up on when the clock passes it.
    func testAReplyTheServerNeverTakesIsGivenUpOn() async throws {
        let clock = ManualMCPClock()
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport, clock: clock)
        transport.hangResponses()
        transport.push(.request(JSONRPCRequest(id: .string("p1"), method: MCPWire.pingMethod)))
        let budgeted = await clock.waitForSleeper(dueIn: MCPConstants.courtesyBudget)
        XCTAssertTrue(budgeted, "the reply's POST was not put on the courtesy budget")
        XCTAssertEqual(transport.abandonedResponseCount, 0, "the reply's POST was given up on before its budget ran out")
        clock.advance(by: MCPConstants.courtesyBudget)
        let deadline = Date().addingTimeInterval(MCPConstants.courtesyBudget + 3)
        while transport.abandonedResponseCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(transport.abandonedResponseCount, 1, "the reply's POST was left open")
        await client.close(budget: 0)
    }

    /// The frames sent that are this client's replies to a server's requests.
    private func sentReplies(on transport: ScriptedTransport) -> Int {
        transport.sent.count { frame in
            if case .response = frame { return true }
            return false
        }
    }

    /// A server that floods the client with requests — thousands of `ping`s down the push
    /// channel — gets at most `maxServerRequestRepliesInFlight` replies in flight at once. The rest are
    /// dropped: a courtesy is owed, not promised, and one POST per request, each held up to the
    /// courtesy budget, is the server's flood turned into this client's. The inbound stream is
    /// never held behind them — the call's response after the flood still arrives.
    ///
    /// RED until the second review of group C (2026-09-23): each request started its own
    /// untracked task, with nothing to count or cap them.
    func testAFloodOfServerRequestsLeavesAtMostTheCapInFlight() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 30, requestAbsolute: 30))
        transport.script("slow", [.silence])
        let call = Task { try await client.call(method: "slow") }
        let id = try await waitUntilSent("slow", on: transport)
        transport.hangResponses()

        for index in 0..<200 {
            transport.push(.request(JSONRPCRequest(id: .string("p\(index)"), method: MCPWire.pingMethod)))
        }
        transport.push(.response(JSONRPCResponse(id: id, outcome: .result(.string("answered")))))
        let result = try await call.value
        XCTAssertEqual(result, .string("answered"), "the flood held back the stream")
        let deadline = Date().addingTimeInterval(2)
        while sentReplies(on: transport) < MCPConstants.maxServerRequestRepliesInFlight, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // An observation window for a reply past the cap to show itself.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sentReplies(on: transport), MCPConstants.maxServerRequestRepliesInFlight)
        await client.close(budget: 0)
    }

    /// Closing the client cancels the courtesies still in flight — they belong to a session
    /// that is over — rather than leaving each to run out its budget.
    ///
    /// RED until the second review of group C (2026-09-23): nothing held them, so a close could
    /// not reach them.
    func testClosingCancelsTheCourtesiesStillInFlight() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        transport.hangResponses()
        for index in 0..<3 {
            transport.push(.request(JSONRPCRequest(id: .string("p\(index)"), method: MCPWire.pingMethod)))
        }
        let sent = Date().addingTimeInterval(2)
        while sentReplies(on: transport) < 3, Date() < sent {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(sentReplies(on: transport), 3, "premise: three replies in flight")

        let closed = Date()
        await client.close(budget: 0)
        let deadline = closed.addingTimeInterval(1)
        while transport.abandonedResponseCount < 3, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.abandonedResponseCount, 3, "close() left them to their budget")
        XCTAssertLessThan(Date().timeIntervalSince(closed), MCPConstants.courtesyBudget)
    }

    /// The cap is on replies to the SERVER'S requests — the one kind a server can multiply. The
    /// client's own `notifications/cancelled` is bounded by its own calls, so it is never
    /// dropped: with every reply slot held by a server that sits on them, cancelling a call
    /// still tells the server to stop running it. Closing still cancels both kinds.
    ///
    /// RED until the third pass of group C's second review (2026-09-23): one cap counted both,
    /// and a cancel or a timeout that found it full was dropped without a word — a legacy
    /// server ran a call the user had cancelled, which may be a mutating one, to the end.
    func testAClientsOwnCancellationIsSentWhenTheServersRepliesFillTheCap() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 30, requestAbsolute: 30))
        transport.script("slow", [.silence])
        let call = Task { try await client.call(method: "slow") }
        let id = try await waitUntilSent("slow", on: transport)
        transport.hangResponses()
        transport.hangNotifications()
        for index in 0..<MCPConstants.maxServerRequestRepliesInFlight {
            transport.push(.request(JSONRPCRequest(id: .string("p\(index)"), method: MCPWire.pingMethod)))
        }
        let filled = Date().addingTimeInterval(2)
        while sentReplies(on: transport) < MCPConstants.maxServerRequestRepliesInFlight, Date() < filled {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(sentReplies(on: transport), MCPConstants.maxServerRequestRepliesInFlight, "premise: the cap is full")

        call.cancel()
        _ = try? await call.value
        let deadline = Date().addingTimeInterval(2)
        while cancellations(on: transport).isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(cancellations(on: transport), [id.jsonValue], "the cancellation was dropped")

        await client.close(budget: 0)
        let closed = Date().addingTimeInterval(1)
        while transport.abandonedResponseCount + transport.abandonedNotificationCount
            < MCPConstants.maxServerRequestRepliesInFlight + 1, Date() < closed {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.abandonedResponseCount, MCPConstants.maxServerRequestRepliesInFlight)
        XCTAssertEqual(transport.abandonedNotificationCount, 1, "close() left the cancellation to its budget")
    }

    // MARK: - Asking for progress

    /// Every `tools/call` names itself as its progress token, in both eras: a spec-conforming
    /// server reports progress only under a token the request supplied — the Python and TS
    /// SDKs make `report_progress` a no-op without one — so without it the inactivity reset
    /// never fires, and a working call is timed out as a silent one. Nothing else asks: the
    /// catalogue pages run on the connect budget and report nothing.
    ///
    /// RED until 2026-09-23 (review F9): no request carried a token.
    func testEveryToolCallNamesItselfAsItsProgressToken() async throws {
        for legacy in [false, true] {
            let transport = ScriptedTransport()
            let client = legacy ? try await connectedLegacy(transport) : try await connectedModern(transport)
            transport.script(MCPWire.toolsCallMethod, [.result(.object(["content": .array([])]))])
            transport.script(MCPWire.toolsListMethod, [.result(.object(["tools": .array([])]))])
            _ = try await client.callTool(originalName: "get_quote", arguments: .object(["figi": .string("X")]))
            _ = try await client.listAllTools()

            let requests = transport.sent.compactMap { frame -> JSONRPCRequest? in
                if case .request(let request) = frame { return request }
                return nil
            }
            let call = try XCTUnwrap(requests.first { $0.method == MCPWire.toolsCallMethod })
            let params = try XCTUnwrap(call.params?.objectValue)
            let meta = params["_meta"]?.objectValue
            XCTAssertEqual(meta?["progressToken"], call.id.jsonValue, "legacy: \(legacy)")
            XCTAssertEqual(params["name"], .string("get_quote"))
            XCTAssertEqual(params["arguments"], .object(["figi": .string("X")]))
            if legacy {
                XCTAssertEqual(meta?.keys.sorted(), ["progressToken"], "the legacy era carries no version meta")
            } else {
                // The spec's own spelling (2026-07-28 basic/index, "Per-request protocol fields").
                XCTAssertEqual(meta?.keys.sorted(), [
                    "io.modelcontextprotocol/clientCapabilities", "io.modelcontextprotocol/clientInfo",
                    "io.modelcontextprotocol/protocolVersion", "progressToken",
                ], "the modern meta is kept beside the token")
                XCTAssertEqual(meta?["io.modelcontextprotocol/protocolVersion"], .string("2026-07-28"))
            }
            let list = try XCTUnwrap(requests.first { $0.method == MCPWire.toolsListMethod })
            XCTAssertNil(list.params?.objectValue?["_meta"]?.objectValue?["progressToken"], "legacy: \(legacy)")
            await client.close(budget: 0)
        }
    }

    // MARK: - Connection loss

    /// One dead connection fails every waiting request at once. Letting them time out one by
    /// one would leave a role waiting two minutes for a server that is already gone.
    func testALostConnectionFailsEveryWaitingCallImmediately() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 600, requestAbsolute: 600))
        transport.script("a", [.silence])
        transport.script("b", [.silence])

        let first = Task { try await client.call(method: "a") }
        let second = Task { try await client.call(method: "b") }
        try await Task.sleep(nanoseconds: 200_000_000)
        transport.pushFailure(.network("the connection was lost"))

        for pending in [first, second] {
            do {
                _ = try await pending.value
                XCTFail("a lost connection answers nothing")
            } catch MCPClientError.transport(.network) {
                // expected
            }
        }
    }

    func testClosingFailsEveryWaitingCallAndRefusesNewOnes() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 600, requestAbsolute: 600))
        transport.script("a", [.silence])

        async let pending: JSONValue = client.call(method: "a")
        try await Task.sleep(nanoseconds: 200_000_000)
        await client.close(budget: 1)
        do {
            _ = try await pending
            XCTFail("a closed connection answers nothing")
        } catch MCPClientError.transport(.closed) {
            // expected
        }
        do {
            _ = try await client.call(method: "a")
            XCTFail("a closed client takes no new calls")
        } catch MCPClientError.notConnected {
            // expected
        }
        let budget = transport.closeBudget
        XCTAssertEqual(budget, 1)
    }

    // MARK: - Server-initiated requests

    /// The legacy era lets a server send requests. `ping` is the one this client answers.
    func testAServerPingIsAnswered() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        transport.push(.request(JSONRPCRequest(id: .string("p1"), method: MCPWire.pingMethod)))
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = client

        guard case .response(let response)? = transport.sent.last else {
            return XCTFail("a ping deserves a reply")
        }
        XCTAssertEqual(response.id, .string("p1"), "the reply echoes the id in the spelling it arrived in")
        XCTAssertEqual(response.result, .object([:]))
    }

    /// Everything else gets `methodNotFound` — the client declared no capabilities, so there
    /// is nothing a server can legitimately ask it for. Answering would mean implementing a
    /// channel the client deliberately does not have.
    func testEveryOtherServerRequestIsRefusedWithMethodNotFound() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        for method in ["sampling/createMessage", "elicitation/create", "roots/list"] {
            transport.push(.request(JSONRPCRequest(id: .string(method), method: method)))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = client

        let refusals = transport.sent.compactMap { frame -> JSONRPCError? in
            guard case .response(let response) = frame else { return nil }
            return response.error
        }
        XCTAssertEqual(refusals.count, 3)
        XCTAssertTrue(refusals.allSatisfy { $0.code == MCPErrorCode.methodNotFound })
    }

    /// In the modern era, the 2026-07-28 revision says "The client MUST NOT send JSON-RPC
    /// responses": a server-initiated request is logged on arrival and never answered (D-M9 pt. 4).
    func testAModernClientLogsServerRequestsAndSendsNoResponse() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-modern-srv-req-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("rpc_log.jsonl")
        let log = MCPRPCLog(logURL: logURL)

        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        let client = MCPClient(transport: transport, log: log, timeouts: fastTimeouts, clientVersion: "1.0")
        _ = try await client.connect(cachedEra: nil)

        for (id, method) in [("p1", MCPWire.pingMethod), ("s1", "sampling/createMessage")] {
            transport.push(.request(JSONRPCRequest(id: .string(id), method: method)))
        }
        try await drain(client, transport)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sentReplies(on: transport), 0, "the modern era never sends JSON-RPC responses")
        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains(#""kind":"serverRequest""#), logText)
        XCTAssertTrue(logText.contains(#""requestID":"p1""#), logText)
        XCTAssertTrue(logText.contains(#""requestID":"s1""#), logText)
        await client.close(budget: 0)
    }

    // MARK: - Notifications

    func testAnUnconsumedNotificationReachesTheHandler() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        let box = NotificationBox()
        await client.onNotification { box.record($0.method) }

        transport.push(.notification(JSONRPCNotification(method: "notifications/tools/list_changed")))
        transport.push(.notification(JSONRPCNotification(
            method: MCPWire.progressNotification, params: .object(["progressToken": .int(1)]))))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(box.methods, ["notifications/tools/list_changed"],
                       "progress is consumed by the timers, not forwarded")
    }

    private final class NotificationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func record(_ method: String) { lock.withLock { seen.append(method) } }
        var methods: [String] { lock.withLock { seen } }
    }

    // MARK: - After close

    /// A closed client refuses rather than reopening the conversation: the step that owned it
    /// is gone, and a request issued after teardown would correlate against an id table
    /// nothing is draining.
    func testCallingAfterCloseIsRefused() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        await client.close(budget: 0)
        do {
            _ = try await client.call(method: "tools/list")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .notConnected)
        }
    }

    /// Closing twice is what a teardown race looks like — a folder switch and
    /// `shutdownForTermination` can both arrive — and the second must be a no-op.
    func testClosingTwiceIsANoOp() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        await client.close(budget: 0)
        await client.close(budget: 0)
    }

    /// A legacy server that answers `initialize` without naming a version has agreed to the
    /// one this client offered — which is the oldest it speaks, not the newest.
    func testALegacyServerThatNamesNoVersionIsReadAsTheOldestOne() async throws {
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.error(code: MCPErrorCode.methodNotFound, message: "no")])
        transport.script(MCPWire.initializeMethod, [.result(.object(["serverInfo": .object([:])]))])
        let client = MCPClient(
            transport: transport, log: nil, timeouts: fastTimeouts, clientVersion: "1.0")
        let connection = try await client.connect(cachedEra: nil)
        XCTAssertEqual(connection.era, .legacy)
        XCTAssertEqual(connection.protocolVersion, MCPConstants.legacyProtocolVersion)
        await client.close(budget: 0)
    }

    // MARK: - One request's stream, not the connection

    /// Over HTTP every request is its own exchange. A stream that broke under ONE of them says
    /// nothing about the others, and failing them all turned one slow tool into a failed batch.
    func testABrokenRequestStreamFailsThatRequestAndNoOther() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 600, requestAbsolute: 600))
        transport.script("a", [.silence])
        transport.script("b", [.silence])

        let first = Task { try await client.call(method: "a") }
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = Task { try await client.call(method: "b") }
        try await Task.sleep(nanoseconds: 100_000_000)

        transport.pushRequestFailure(.number(2), .network("the connection was lost"))
        do {
            _ = try await first.value
            XCTFail("the request whose stream broke has no answer")
        } catch MCPClientError.transport(.network) {
            // expected
        }

        transport.push(.response(JSONRPCResponse(id: .number(3), outcome: .result(.string("still here")))))
        let survivor = try await second.value
        XCTAssertEqual(survivor, .string("still here"))
    }

    /// The legacy push channel breaking is not a request failing: nothing was waiting on it.
    func testALostPushStreamFailsNothing() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 600, requestAbsolute: 600))
        transport.script("a", [.silence])

        let call = Task { try await client.call(method: "a") }
        try await Task.sleep(nanoseconds: 100_000_000)
        transport.pushStreamLoss(.network("the connection was lost"))
        transport.push(.response(JSONRPCResponse(id: .number(2), outcome: .result(.string("answered")))))

        let result = try await call.value
        XCTAssertEqual(result, .string("answered"))
    }

    /// The transport knows the session is gone; the connection that owns the client is the one
    /// that can start a new one, so the client passes it on.
    func testALostSessionIsHandedToWhoeverOwnsTheConnection() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedLegacy(transport)
        let reported = expectation(description: "the owner hears the session is gone")
        await client.onSessionLost { reported.fulfill() }

        transport.pushSessionLost()
        await fulfillment(of: [reported], timeout: 2)
        await client.close(budget: 0)
    }

    // MARK: - Abandoning closes the request

    /// A timed-out call must stop the request that carries it. Before 2026-09-23 only a
    /// STREAM was closed; a POST still waiting for a JSON reply stayed open until the HTTP
    /// layer's own timeout, and the server went on working on a call nobody wanted.
    func testATimedOutCallCancelsItsOwnSend() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(transport)
        transport.script("slow", [.hangUntilCancelled])

        do {
            _ = try await client.call(method: "slow", timeout: 0.3)
            XCTFail("a call past its ceiling has no answer")
        } catch MCPClientError.timedOut {
            // expected
        }
        try await waitForAbandonedSends(transport, count: 1)
    }

    func testACancelledCallCancelsItsOwnSend() async throws {
        let transport = ScriptedTransport()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 600, requestAbsolute: 600))
        transport.script("slow", [.hangUntilCancelled])

        let call = Task { try await client.call(method: "slow") }
        try await Task.sleep(nanoseconds: 200_000_000)
        call.cancel()
        _ = try? await call.value
        try await waitForAbandonedSends(transport, count: 1)
    }

    private func waitForAbandonedSends(_ transport: ScriptedTransport, count: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while transport.abandonedSendCount < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(transport.abandonedSendCount, count, "the request carrying the call was left running")
    }

    // MARK: - The server's own connect budget

    /// `MCPTimeouts.connect` is the server's handshake budget. Until 2026-09-23 the handshake
    /// read the constants (10 s probe + 20 s initialize) and the per-server value was spent on
    /// the wrong thing — the HTTP idle timeout of every request.
    ///
    /// On a `ManualMCPClock` (since 2026-10-28; two real seconds before): the probe and then
    /// `initialize` each have their watchdog armed at the one-second connect budget, and each
    /// times out when the clock passes it.
    func testTheHandshakeRunsOnTheServersOwnConnectBudget() async throws {
        let clock = ManualMCPClock()
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.silence])
        transport.script(MCPWire.initializeMethod, [.silence])
        let client = MCPClient(
            transport: transport, log: nil,
            timeouts: MCPTimeouts(connect: 1, requestInactivity: 600, requestAbsolute: 600),
            clientVersion: "1.0", clock: clock)

        let started = Date()
        let connecting = Task { try await client.connect(cachedEra: nil) }
        for method in [MCPWire.discoverMethod, MCPWire.initializeMethod] {
            try await waitUntilSent(method, on: transport)
            let armed = await clock.waitForSleeper(dueIn: 1)
            XCTAssertTrue(armed, "\(method) was not given the one-second connect budget")
            guard armed else { return connecting.cancel() }
            clock.advance(by: 1)
        }
        do {
            _ = try await boundedValue(of: connecting, "the connect")
            XCTFail("a server that answers nothing cannot connect")
        } catch MCPClientError.timedOut(let method) {
            XCTAssertEqual(method, MCPWire.initializeMethod)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "probe and initialize each get one second")
        await client.close(budget: 0)
    }

    /// Paging the catalogue is part of connecting and gets the same budget.
    ///
    /// On a `ManualMCPClock` (since 2026-10-28): the page's watchdog is armed at the connect
    /// budget, and the listing times out when the clock passes it.
    func testListingToolsRunsOnTheServersOwnConnectBudget() async throws {
        let clock = ManualMCPClock()
        let transport = ScriptedTransport()
        let client = try await connectedModern(
            transport, timeouts: MCPTimeouts(connect: 1, requestInactivity: 600, requestAbsolute: 600), clock: clock)
        transport.script(MCPWire.toolsListMethod, [.silence])

        let started = Date()
        let listing = Task { try await client.listAllTools() }
        try await waitUntilSent(MCPWire.toolsListMethod, on: transport)
        let armed = await clock.waitForSleeper(dueIn: 1)
        XCTAssertTrue(armed, "the listing was not given the one-second connect budget")
        guard armed else { return listing.cancel() }
        clock.advance(by: 1)
        do {
            _ = try await boundedValue(of: listing, "the listing")
            XCTFail("a silent listing has no tools")
        } catch MCPClientError.timedOut(let method) {
            XCTAssertEqual(method, MCPWire.toolsListMethod)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        await client.close(budget: 0)
    }

    /// `notifications/initialized` is part of the handshake and runs on its budget. A server
    /// that answers `initialize` and then sits on the notification's POST fails the connect
    /// when the connect budget runs out — and the POST is closed, not left for the server.
    ///
    /// RED until 2026-09-23 (review F3): `notify` had no deadline at all, so this handshake
    /// took the request's whole inactivity budget.
    func testTheInitializedNotificationRunsOnTheConnectBudget() async throws {
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.error(code: MCPErrorCode.methodNotFound, message: "no")])
        transport.script(MCPWire.initializeMethod, [.result(.object([
            "protocolVersion": .string(MCPConstants.legacyProtocolVersion)]))])
        transport.hangNotifications()
        let clock = ManualMCPClock()
        let client = MCPClient(
            transport: transport, log: nil,
            timeouts: MCPTimeouts(connect: 1, requestInactivity: 600, requestAbsolute: 600),
            clientVersion: "1.0", clock: clock)

        // On a `ManualMCPClock` (since 2026-10-28): the notification's budget is armed due at the
        // one-second connect budget, and the connect fails when the clock passes it.
        let started = Date()
        let connecting = Task { try await client.connect(cachedEra: nil) }
        // The notification is on the wire once it is recorded: `initialize` has answered by then
        // and its own one-second watchdog is gone, so the timer found next is the notification's.
        let sentBy = Date().addingTimeInterval(5)
        while !transport.sent.contains(where: { $0.method == MCPWire.initializedNotification }), Date() < sentBy {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(transport.sent.contains { $0.method == MCPWire.initializedNotification },
                      "notifications/initialized was never sent")
        let armed = await clock.waitForSleeper(dueIn: 1)
        XCTAssertTrue(armed, "notifications/initialized was not put on the one-second connect budget")
        XCTAssertEqual(transport.abandonedNotificationCount, 0, "the notification was given up on before its budget ran out")
        guard armed else { return connecting.cancel() }
        clock.advance(by: 1)
        do {
            _ = try await boundedValue(of: connecting, "the connect")
            XCTFail("a handshake the server never finished is not a connection")
        } catch MCPClientError.timedOut(let method) {
            XCTAssertEqual(method, MCPWire.initializedNotification)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        let closed = Date().addingTimeInterval(2)
        while transport.abandonedNotificationCount == 0, Date() < closed {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(transport.abandonedNotificationCount, 1, "the notification's POST was left open")
        await client.close(budget: 0)
    }
}

/// Every failure this client can report, in the words a reader gets.
///
/// Separate class because it needs no transport: the point is that each case says what went
/// wrong AND what to do, and a case added without a message would otherwise surface to the
/// model as the bare enum name.
final class MCPClientErrorMessageTests: XCTestCase {

    func testEveryCaseNamesTheProblemAndTheRepair() {
        let cases: [MCPClientError] = [
            .notConnected,
            .transport(.timedOut),
            .rpc(code: -32602, message: "figi is required", data: nil),
            .unsupportedProtocolVersion(offered: "2026-07-28", serverSupports: ["2025-11-25"]),
            .handshakeRefused(code: -32021, message: "Missing required client capability: sampling"),
            .inputRequired,
            .unknownResultType("streaming"),
            .timedOut(method: "tools/call"),
            .cancelled,
            .malformedResult("the server repeated its page cursor"),
            .pageLimitExceeded(100),
        ]
        for error in cases {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(error)")
            XCTAssertGreaterThan(message.count, 20, "\(error): \(message)")
        }
    }

    func testTheVersionMismatchNamesWhatTheServerDoesSpeakAndSaysSoWhenItNamedNothing() {
        XCTAssertTrue(
            MCPClientError.unsupportedProtocolVersion(offered: "2026-07-28", serverSupports: ["2025-11-25"])
                .errorDescription?.contains("2025-11-25") ?? false)
        XCTAssertTrue(
            MCPClientError.unsupportedProtocolVersion(offered: "2026-07-28", serverSupports: [])
                .errorDescription?.contains("none it named") ?? false)
    }

    /// The transport's own text passes through unchanged: re-wording it here would mean two
    /// spellings of the same failure, and the transport's is the one with the detail.
    func testATransportFailureKeepsTheTransportsOwnWords() {
        XCTAssertEqual(MCPClientError.transport(.sessionLost).errorDescription,
                       MCPTransportError.sessionLost.errorDescription)
    }

    func testTheServersOwnMessageIsCarriedWithItsCode() {
        let message = MCPClientError.rpc(code: -32602, message: "figi is required", data: nil).errorDescription
        XCTAssertTrue(message?.contains("-32602") ?? false, message ?? "")
        XCTAssertTrue(message?.contains("figi is required") ?? false, message ?? "")
        // A modern server's refusal of the probe reaches the status row the same way: its code
        // and its own words.
        let refused = MCPClientError.handshakeRefused(code: -32021, message: "requires sampling").errorDescription
        XCTAssertTrue(refused?.contains("-32021") ?? false, refused ?? "")
        XCTAssertTrue(refused?.contains("requires sampling") ?? false, refused ?? "")
    }


    // MARK: - A send that fails

    /// A notification has no id, so nothing waits on it — but the failure must still reach the
    /// caller as a typed client error rather than as a raw transport one, because everything
    /// above this layer switches on `MCPClientError`.
    func testAFailedNotificationSurfacesAsAClientTransportError() async throws {
        let transport = ScriptedTransport()
        transport.failNotifications(with: .network("the socket went away"))
        let client = MCPClient(transport: transport, log: nil, timeouts: .standard)

        do {
            try await client.notify(method: "notifications/cancelled")
            XCTFail("expected the notification to fail")
        } catch let error as MCPClientError {
            guard case .transport = error else { return XCTFail("expected .transport, got \(error)") }
        }
        await client.close(budget: 0)
    }

    /// The same for a notification whose transport throws something that is not its own error:
    /// the caller still gets a typed client error.
    func testANotificationThatFailsForeignlyStillSurfacesAsAClientTransportError() async throws {
        let transport = ScriptedTransport()
        transport.failNotificationsWithAForeignError()
        let client = MCPClient(transport: transport, log: nil, timeouts: .standard)

        do {
            try await client.notify(method: "notifications/cancelled")
            XCTFail("expected the notification to fail")
        } catch let error as MCPClientError {
            guard case .transport(.network) = error else { return XCTFail("expected .transport(.network), got \(error)") }
        }
        await client.close(budget: 0)
    }

    /// The defensive arm: a transport that throws something this client has no case for still
    /// finishes the waiting call, instead of leaving it suspended until its absolute timer.
    func testASendThatThrowsAForeignErrorStillFinishesTheCall() async throws {
        let transport = ScriptedTransport()
        transport.script("tools/list", [.foreignFailure])
        let client = MCPClient(transport: transport, log: nil, timeouts: .standard)

        do {
            _ = try await client.call(method: "tools/list")
            XCTFail("expected the call to fail")
        } catch let error as MCPClientError {
            guard case .transport = error else { return XCTFail("expected .transport, got \(error)") }
        }
        await client.close(budget: 0)
    }
}
