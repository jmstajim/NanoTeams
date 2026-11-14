import CryptoKit
import Foundation

/// Streamable HTTP, both eras, over one endpoint.
///
/// **What this actor is responsible for, and what it deliberately is not.** It owns the
/// bytes: which headers go out, what a status code means, how an SSE body becomes frames,
/// and the legacy session id. It owns no correlation — which request a frame answers, what a
/// timeout means, whether to retry — because those are the same on every transport and live
/// in `MCPClient`.
///
/// **One inbound channel.** Every frame the server sends reaches `events()`, whether it came
/// back on the POST that asked for it, on the legacy GET stream, or on a stream that outlives
/// the request. `send` answers only "did this connection carry the reply" (`.answered`) or
/// "the server took it and will answer elsewhere" (`.accepted`); the reply itself is never a
/// return value, because Streamable HTTP has three ways to deliver one and a return value can
/// express only the first.
actor StreamableHTTPTransport: MCPTransport {

    private let config: MCPHTTPConfig
    private let authorizer: any MCPAuthorizer
    private let session: any MCPHTTPSession
    private let timeouts: MCPTimeouts
    /// Delays before reopening the legacy push stream, walked like the reconnect backoff.
    /// Injected so a test does not wait a real second per reopen.
    private let pushStreamRetryDelays: [TimeInterval]
    /// What the push channel's reopen delays are measured and waited on (`MCPClock`). A test
    /// moves it itself, so "asked again on the next tick" and "not asked again on any tick"
    /// are ordered by the test rather than read off the wall clock.
    private let clock: any MCPClock
    /// The frame ceiling, at all four places a body is read: a JSON body, a non-2xx body read for
    /// its JSON-RPC error, the SSE parser's completed `data:` lines, and an SSE line that never
    /// ends. `MCPConstants.maxFrameBytes` wherever the app builds one (`MCPEnvironment.live`); a
    /// test passes a small one, so proving the ceiling does not mean pushing 64 MiB through a
    /// per-byte read (7.7 s until 2026-10-28).
    nonisolated let frameLimit: Int

    private var endpoint: URL?
    private var era: MCPProtocolEra?
    /// The version string that goes in `MCP-Protocol-Version`. The modern one before the
    /// handshake, because the probe IS a modern request; whatever the server named afterwards.
    private var protocolVersion = MCPConstants.modernProtocolVersion
    /// Legacy only, memory only, never written to disk. A session id in a file is a session
    /// anyone with the file can resume.
    private var sessionID: String?

    private var stream: AsyncStream<MCPIncomingEvent>?
    private var continuation: AsyncStream<MCPIncomingEvent>.Continuation?
    private var handedOutStream = false

    /// Readers for streams that are still open, keyed so `cancel(requestID:)` can reach one.
    private var readers: [JSONRPCID: Task<Void, Never>] = [:]
    /// Readers with no request behind them: a stream that answered a notification.
    private var anonymousReaders: [Task<Void, Never>] = []
    /// The legacy push channel's open → read → reopen loop. One per connection.
    private var pushStream: Task<Void, Never>?
    /// The session whose push GET was last answered with an event stream. A 404 on that
    /// session's channel is the server forgetting the session; a 404 on a session that never
    /// had a stream is a server with no channel (`PushStreamEnd`).
    private var sessionWithPushStream: String?
    private var isClosed = false

    init(
        config: MCPHTTPConfig,
        authorizer: any MCPAuthorizer,
        session: any MCPHTTPSession,
        timeouts: MCPTimeouts = .standard,
        pushStreamRetryDelays: [TimeInterval] = MCPConstants.reconnectBackoff,
        clock: any MCPClock = MCPSystemClock(),
        frameLimit: Int = MCPConstants.maxFrameBytes
    ) {
        self.config = config
        self.authorizer = authorizer
        self.session = session
        self.timeouts = timeouts
        self.pushStreamRetryDelays = pushStreamRetryDelays.isEmpty ? [0] : pushStreamRetryDelays
        self.clock = clock
        self.frameLimit = frameLimit
    }

    // MARK: - Lifecycle

    /// Validates the address and opens the inbound channel. Makes no request: which request
    /// comes first is the era probe's decision, and a connect that guessed would cost a
    /// round trip on the path that works.
    func connect() async throws {
        guard !isClosed else { throw MCPTransportError.closed }
        do {
            endpoint = try MCPEndpointPolicy.validate(config.urlString)
        } catch let failure as MCPEndpointPolicy.Failure {
            throw MCPTransportError.endpointRefused(failure.message)
        }
        if continuation == nil {
            let (stream, continuation) = AsyncStream<MCPIncomingEvent>.makeStream(
                bufferingPolicy: .unbounded)
            self.stream = stream
            self.continuation = continuation
        }
    }

    /// The handshake's outcome. For the legacy era this is also when the server's own push
    /// channel is opened — before the handshake there is no session for it to belong to.
    func adopt(era: MCPProtocolEra, protocolVersion: String) async {
        self.era = era
        self.protocolVersion = protocolVersion
        if era == .legacy, sessionID != nil {
            openLegacyServerStream()
        }
    }

    func events() async -> AsyncStream<MCPIncomingEvent> {
        guard let stream, !handedOutStream else {
            // The frames have an owner already; a second reader would silently steal half of
            // them, so this one is empty rather than competing.
            return AsyncStream { $0.finish() }
        }
        handedOutStream = true
        return stream
    }

    func cancel(requestID: JSONRPCID) async {
        readers.removeValue(forKey: requestID)?.cancel()
    }

    func close(budget: TimeInterval) async {
        guard !isClosed else { return }
        isClosed = true
        for task in readers.values { task.cancel() }
        readers.removeAll()
        for task in anonymousReaders { task.cancel() }
        anonymousReaders.removeAll()
        pushStream?.cancel()
        pushStream = nil

        // Releasing the legacy session is a courtesy to the server, so it is given a budget
        // and never allowed to hold up a quit.
        if era == .legacy, let sessionID, let endpoint {
            _ = try? await MCPBudget.run(within: budget, clock: clock) { [weak self] in
                await self?.sendSessionDelete(endpoint: endpoint, sessionID: sessionID)
            }
        }
        sessionID = nil
        session.invalidate()
        continuation?.yield(.closed)
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Sending

    @discardableResult
    func send(_ frame: MCPOutgoingFrame, hints: MCPSendHints) async throws -> MCPSendOutcome {
        guard !isClosed else { throw MCPTransportError.closed }
        guard let endpoint else { throw MCPTransportError.notConnected }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = encode(frame)
        // The longest the HTTP layer waits for the NEXT byte — not for the connection, which
        // is what the name suggests and what this line said until 2026-09-23: with the 20 s
        // connect budget here, a tool that took 21 s to answer failed as "did not answer in
        // time" while its documented budget was 120 s. Strictly ABOVE the inactivity budget
        // (`httpIdleTimeout`): `MCPClient`'s watchdog owns that budget, and when the HTTP layer
        // fired first a timed-out call read as "server unavailable" and a legacy server was
        // never told to stop. Long-lived notification streams (`subscriptions/listen`,
        // `hints.expectsLongLivedStream`) wait on `requestAbsolute` just like the legacy GET
        // push channel so silence is not treated as an idle POST.
        request.timeoutInterval = hints.expectsLongLivedStream
            ? timeouts.requestAbsolute
            : timeouts.httpIdleTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both are offered on every POST: the server picks a single JSON reply or a stream,
        // and which one it picks can differ per request even on one connection.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        applyConfiguredHeaders(to: &request)
        applyProtocolHeaders(to: &request, frame: frame, hints: hints)

        let authorized = try await authorizer.authorized(request)
        return try await perform(authorized, awaiting: frame.awaitedResponseID, hints: hints)
    }

    private func encode(_ frame: MCPOutgoingFrame) -> Data {
        switch frame {
        case .request(let request): return JSONRPCCodec.encode(request)
        case .notification(let notification): return JSONRPCCodec.encode(notification)
        case .response(let response): return JSONRPCCodec.encode(response)
        }
    }

    private func applyConfiguredHeaders(to request: inout URLRequest) {
        for (name, value) in config.headers.sorted(by: { $0.key < $1.key }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// The era decides which headers exist at all.
    ///
    /// `initialize` is the legacy opening, sent before `adopt(era: .legacy, …)` has a
    /// negotiated version or a session to record: the 2025-11-25 specification requires
    /// `MCP-Protocol-Version` only on subsequent requests, and a strict legacy server
    /// (`modelcontextprotocol/go-sdk` v1.0.0) rejects an opening carrying an unknown version or
    /// `Mcp-Method` with 400 before reading the body. Every other frame writes the revision
    /// `hints.protocolVersion` names for it, or the connection's adopted `protocolVersion`.
    ///
    /// The legacy era has none of the modern request metadata — no `Mcp-Method`, no `Mcp-Name`,
    /// and no `Mcp-Param-*` header: it has no header channel for a tool's parameters, so the
    /// coercion keeps every argument in the body for it and hands this no header parameter
    /// (`MCPArgumentCoercion.coerce`).
    private func applyProtocolHeaders(to request: inout URLRequest, frame: MCPOutgoingFrame, hints: MCPSendHints) {
        guard frame.method != MCPWire.initializeMethod else { return }

        request.setValue(
            hints.protocolVersion ?? protocolVersion,
            forHTTPHeaderField: MCPConstants.protocolVersionHeader)

        if era == .legacy {
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            return
        }

        // 2026-07-28 mirrors selected body fields into headers so an intermediary can read them
        // without parsing JSON. The body remains authoritative: a server rejects a request whose
        // header does not match its body.
        if let method = frame.method {
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        }
        if let name = hints.name, !name.isEmpty {
            request.setValue(Self.headerValue(name), forHTTPHeaderField: "Mcp-Name")
        }
        for (header, value) in hints.headerParameters.sorted(by: { $0.key < $1.key }) {
            request.setValue(Self.headerValue(value), forHTTPHeaderField: header)
        }
    }

    /// A value for `Mcp-Name` or an `Mcp-Param-*` header, spelled as the 2026-07-28 revision
    /// requires (Streamable HTTP, "Value Encoding"): as itself when it is a plain header value,
    /// and otherwise as `=?base64?<its UTF-8 in Base64>?=` — "When a value cannot be safely
    /// represented as a plain ASCII header value (e.g., it contains non-ASCII characters, control
    /// characters, or has leading/trailing whitespace), clients MUST use Base64 encoding of the
    /// UTF-8 representation", and "clients MUST also Base64-encode any plain-ASCII value that
    /// matches the sentinel pattern". Plain is visible ASCII and the space, with neither end a
    /// space; a tab, which RFC 9110 allows in a field value but which is a control character, is
    /// encoded. A server decodes the sentinel before comparing the header with the body. Until 2026-10-28 a parameter's value was written raw, and a
    /// non-token tool name went as `base64:` + Base64 — a spelling no server decodes.
    static func headerValue(_ value: String) -> String {
        let isPlain = value.rangeOfCharacter(from: plainHeaderCharacters.inverted) == nil
            && value.first != " " && value.last != " "
            && !(value.hasPrefix("=?base64?") && value.hasSuffix("?="))
        return isPlain ? value : "=?base64?" + Data(value.utf8).base64EncodedString() + "?="
    }

    /// Visible ASCII and the space, U+0020–U+007E: what a header value may hold as itself.
    private static let plainHeaderCharacters = CharacterSet(charactersIn: Unicode.Scalar(0x20)...Unicode.Scalar(0x7E))

    // MARK: - Performing

    /// `requestID`: the id of the reply this POST awaits — `nil` for one that awaits none, a
    /// notification or this client's own reply (`MCPOutgoingFrame.awaitedResponseID`).
    private func perform(
        _ request: URLRequest, awaiting requestID: JSONRPCID?, hints: MCPSendHints = .none
    ) async throws -> MCPSendOutcome {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.sessionBytes(for: request)
        } catch {
            throw Self.classify(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw malformedFrame("the server's reply was not an HTTP response")
        }
        captureSessionID(from: http)

        switch http.statusCode {
        case 202:
            await Self.drain(bytes)
            return .accepted
        case 200, 201:
            break
        case 300...399:
            await Self.drain(bytes)
            throw refusedRedirect(of: request, answeredWith: http)
        case 401, 403:
            let challenge = authorizer.challenge(
                status: http.statusCode,
                wwwAuthenticate: http.value(forHTTPHeaderField: "WWW-Authenticate"))
            await Self.drain(bytes)
            throw MCPTransportError.unauthorized(status: http.statusCode, challenge: challenge?.reason)
        case 404 where era == .legacy && sessionID != nil:
            // The server forgot the session — usually, it restarted. This request fails; the
            // event tells whoever owns the connection to start a new session, so the NEXT
            // call does not fail the same way.
            await Self.drain(bytes)
            sessionID = nil
            continuation?.yield(.sessionLost)
            throw MCPTransportError.sessionLost
        case 400...499:
            // A JSON-RPC ERROR answering THIS request is the server's answer, whatever the status
            // it came under: the 2026-07-28 revision has a modern server refuse with `400 Bad
            // Request` and a JSON-RPC error — `HeaderMismatch` (-32020), an unsupported protocol
            // version (-32022), a missing capability ("Server Validation") — and with `404` and
            // `-32601` for a method it lacks, and tells the client to read the body ("Backward
            // Compatibility": "the client SHOULD inspect the response body"). Delivered as the
            // frame it is, the caller reads the error by its code. Anything else stays the HTTP
            // failure it was — and a POST that awaits no answer is answered by nothing: a
            // notification's refusal, or a refusal of this client's reply to a server's request,
            // whose echoed id is the server's own. Until 2026-10-28 every 4xx was an HTTP
            // failure, and a HeaderMismatch answered the spec's way never re-read the tool list.
            let body = (try? await Self.take(bytes, limit: frameLimit)) ?? Data()
            if let requestID, let answer = Self.errorAnswer(in: body, to: requestID) {
                continuation?.yield(.frame(.response(answer)))
                return .answered
            }
            throw MCPTransportError.httpStatus(
                code: http.statusCode,
                body: messageText(String(data: body.prefix(Self.excerptLimit), encoding: .utf8) ?? ""))
        default:
            throw MCPTransportError.httpStatus(
                code: http.statusCode, body: messageText(await Self.collectExcerpt(bytes)))
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            startStreamReader(
                bytes,
                requestID: requestID,
                expectsLongLivedStream: hints.expectsLongLivedStream,
                protocolVersion: hints.protocolVersion ?? protocolVersion)
            return .answered
        }
        let data = try await Self.collectBody(bytes, limit: frameLimit)
        guard !data.isEmpty else { return .accepted }
        return try deliverFrame(data, awaiting: requestID) ? .answered : .accepted
    }

    /// A 3xx the session did not follow — it leaves the origin — as the failure that says where
    /// the server tried to send us. Both addresses can be the server's choice — the target
    /// always, the source on a chain — so both are server text on the way to a message.
    private func refusedRedirect(of request: URLRequest, answeredWith http: HTTPURLResponse) -> MCPTransportError {
        let refused = session.takeRefusedRedirect()
        return .redirectRefused(
            from: messageText(refused?.from ?? request.url.map(MCPRedaction.url) ?? "the server"),
            to: messageText(refused?.to ?? http.value(forHTTPHeaderField: "Location") ?? "another address"))
    }

    /// Legacy servers hand out the session id on the `initialize` reply and expect it on every
    /// later request. Captured from whichever response carries it, because a server is free to
    /// rotate it.
    private func captureSessionID(from response: HTTPURLResponse) {
        guard let value = response.value(forHTTPHeaderField: "Mcp-Session-Id"),
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sessionID = value
    }

    /// A single JSON body, onto the event stream — unless it is a reply and the POST awaited
    /// none: the spec has a server answer a notification or a reply "202 Accepted with no body",
    /// and a reply in such a body answers nothing this client asked, while its id can only
    /// collide with one of this client's own. `false` when nothing was delivered.
    private func deliverFrame(_ data: Data, awaiting requestID: JSONRPCID?) throws(MCPTransportError) -> Bool {
        let frame: JSONRPCIncoming
        do {
            frame = try JSONRPCCodec.decode(data, errorFallbackID: requestID)
        } catch {
            // Typed: `decode` fails in exactly one way, so there is no second arm to write
            // for an error it cannot produce.
            throw malformedFrame(error.message)
        }
        if case .response = frame, requestID == nil { return false }
        continuation?.yield(.frame(frame))
        return true
    }

    /// Server text on its way into a message the model, the status row and the frame log all
    /// read — an error body, a redirect's address, a malformed frame's quoted member: one line
    /// with nothing hidden, then scrubbed of what THIS server was sent (a server echoing its
    /// own secret header matches no generic pattern), then capped. Cleaned before it is
    /// scrubbed, so a secret split by an invisible character is whole when the scrub looks.
    private func messageText(_ serverText: String) -> String {
        authorizer.credentialsToRedact().excerpt(MCPTextSanitizer.singleLine(serverText))
    }

    /// Every `malformedFrame` this transport raises goes through `messageText`: the codec's
    /// refusal quotes the server's own `jsonrpc` value, and until 2026-09-23 that reached the
    /// model and the status row unscrubbed.
    private func malformedFrame(_ detail: String) -> MCPTransportError {
        .malformedFrame(messageText(detail))
    }

    // MARK: - Streams

    /// How a stream stopped being read.
    private enum StreamOutcome {
        /// The connection closed it, or the request it served was abandoned.
        case cancelled
        /// The reply it was carrying arrived. What happened to the stream afterwards no
        /// longer concerns anybody.
        case answered
        /// It ended cleanly, carrying the last non-empty SSE `id:` seen on the stream (if any).
        case ended(lastEventID: String?)
        case failed(MCPTransportError)
    }

    /// Reads an SSE body into frames until it ends. Runs detached from `send` so a stream that
    /// outlives its request — progress notifications, `subscriptions/listen` — does not hold
    /// the caller. A stream answering a POST that awaits no reply is keyed by nothing, and a
    /// reply on it is not delivered (`deliverFrame(_:awaiting:)`'s rule). When an awaited
    /// request's stream ends cleanly after emitting an event `id:`, `resumeStream` reopens the
    /// stream via `GET` with `Last-Event-ID` up to `MCPConstants.maxStreamResumptionAttempts`
    /// times.
    private func startStreamReader(
        _ bytes: URLSession.AsyncBytes,
        requestID: JSONRPCID?,
        expectsLongLivedStream: Bool = false,
        protocolVersion: String? = nil
    ) {
        let version = protocolVersion ?? self.protocolVersion
        let task = Task { [weak self] in
            guard let self else { return }
            let initial = await self.readStream(
                bytes,
                awaiting: expectsLongLivedStream ? nil : requestID,
                dropsReplies: requestID == nil)
            let outcome = await self.resumeIfNeeded(
                outcome: initial,
                awaiting: expectsLongLivedStream ? nil : requestID,
                protocolVersion: version,
                remainingAttempts: MCPConstants.maxStreamResumptionAttempts)
            await self.finishReader(
                requestID: requestID,
                expectsLongLivedStream: expectsLongLivedStream,
                outcome: outcome)
        }
        if let requestID {
            readers[requestID] = task
        } else {
            anonymousReaders.append(task)
        }
    }

    private func resumeIfNeeded(
        outcome: StreamOutcome,
        awaiting requestID: JSONRPCID?,
        protocolVersion: String,
        remainingAttempts: Int
    ) async -> StreamOutcome {
        guard case .ended(let eventID?) = outcome,
              let requestID,
              remainingAttempts > 0,
              !Task.isCancelled
        else {
            return outcome
        }
        let next = await resumeStream(
            awaiting: requestID,
            lastEventID: eventID,
            protocolVersion: protocolVersion)
        return await resumeIfNeeded(
            outcome: next,
            awaiting: requestID,
            protocolVersion: protocolVersion,
            remainingAttempts: remainingAttempts - 1)
    }

    /// Reopens a request's SSE stream via `GET` with `Last-Event-ID` (and `Mcp-Session-Id` in
    /// the legacy era) when the server closed the previous stream cleanly after emitting an
    /// event `id:` but before delivering the reply.
    private func resumeStream(
        awaiting requestID: JSONRPCID,
        lastEventID: String,
        protocolVersion: String
    ) async -> StreamOutcome {
        guard !isClosed, !Task.isCancelled, let endpoint else { return .cancelled }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeouts.httpIdleTimeout
        request.setValue(protocolVersion, forHTTPHeaderField: MCPConstants.protocolVersionHeader)
        request.setValue(
            MCPTextSanitizer.singleLine(lastEventID),
            forHTTPHeaderField: MCPConstants.lastEventIDHeader)
        if era == .legacy, let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        applyConfiguredHeaders(to: &request)

        let resumedBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            let authorized = try await authorizer.authorized(request)
            (resumedBytes, response) = try await session.sessionBytes(for: authorized)
        } catch {
            return Task.isCancelled ? .cancelled : .failed(Self.classify(error))
        }
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream")
        else {
            await Self.drain(resumedBytes)
            return .ended(lastEventID: nil)
        }
        captureSessionID(from: http)
        return await readStream(resumedBytes, awaiting: requestID, initialEventID: lastEventID)
    }

    /// **Not `bytes.lines`.** `AsyncLineSequence` drops empty lines, and in SSE the empty
    /// line IS the event boundary: fed through it, a stream carrying a progress notification
    /// and then the result arrives as ONE frame whose data is both JSON documents joined by a
    /// newline — which then fails to parse, so the reply the request was waiting for is lost.
    /// Measured 2026-09-20 against a three-line fixture: `lines` yielded 3 lines where the
    /// body had 4, and the parser produced 1 frame instead of 2.
    ///
    /// `dropsReplies`: the stream answers a POST that awaited no reply, so a reply on it answers
    /// nothing this client asked. The legacy push channel is read with it off: by 2025-11-25 a
    /// server sends no reply on a standalone GET without resumption, and a reply there is
    /// delivered safely because its id is still an id this client issued.
    private func readStream(
        _ bytes: URLSession.AsyncBytes,
        awaiting requestID: JSONRPCID?,
        dropsReplies: Bool = false,
        initialEventID: String? = nil
    ) async -> StreamOutcome {
        var parser = SSEFrameParser(byteLimit: frameLimit, lastEventID: initialEventID)
        var pending: [UInt8] = []
        var answered = false
        func deliver(_ frame: SSEFrameParser.Frame?) throws {
            guard let frame, let incoming = try decode(frame, awaiting: requestID) else { return }
            if case .response(let response) = incoming {
                if dropsReplies { return }
                if response.id == requestID { answered = true }
            }
            continuation?.yield(.frame(incoming))
        }
        do {
            for try await byte in bytes {
                if Task.isCancelled { break }
                guard byte != Self.newline else {
                    try deliver(parser.consume(line: Self.take(&pending)))
                    continue
                }
                pending.append(byte)
                // The parser's ceiling counts completed `data:` lines. A server that never
                // sends a newline at all would otherwise grow this buffer without limit.
                guard pending.count <= frameLimit else {
                    throw SSEFrameParser.Failure.frameTooLarge(
                        bytes: pending.count, limit: frameLimit)
                }
            }
            if !Task.isCancelled {
                if !pending.isEmpty { try deliver(parser.consume(line: Self.take(&pending))) }
                try deliver(parser.finish())
            }
        } catch let failure as SSEFrameParser.Failure {
            switch failure {
            case .frameTooLarge(let bytes, let limit):
                return answered ? .answered : .failed(.frameTooLarge(bytes: bytes, limit: limit))
            }
        } catch let failure as MCPTransportError {
            return answered ? .answered : .failed(failure)
        } catch {
            if Task.isCancelled { return .cancelled }
            return answered ? .answered : .failed(Self.classify(error))
        }
        if Task.isCancelled { return .cancelled }
        let eventID = (parser.lastEventID?.isEmpty == false) ? parser.lastEventID : nil
        return answered ? .answered : .ended(lastEventID: eventID)
    }

    /// An SSE frame whose `data` is not a JSON-RPC message ends the stream with a reported
    /// failure rather than being skipped: a server emitting keep-alive comments produces no
    /// frame at all (the parser handles that), so anything that reaches here and does not
    /// parse is a real protocol error.
    private func decode(_ frame: SSEFrameParser.Frame, awaiting requestID: JSONRPCID?) throws -> JSONRPCIncoming? {
        guard !frame.data.isEmpty else { return nil }
        do {
            return try JSONRPCCodec.decode(Data(frame.data.utf8), errorFallbackID: requestID)
        } catch {
            throw malformedFrame(error.message)
        }
    }

    /// A request's stream that ended without its reply (and after any `Last-Event-ID`
    /// resumption attempts) fails THAT request, so the watchdog does not hold the role for its
    /// whole inactivity budget. A long-lived notification stream (`subscriptions/listen`) or a
    /// stream with no request behind it fails no request when it ends cleanly.
    private func finishReader(
        requestID: JSONRPCID?,
        expectsLongLivedStream: Bool = false,
        outcome: StreamOutcome
    ) {
        if let requestID { readers.removeValue(forKey: requestID) }
        guard !isClosed else { return }
        if expectsLongLivedStream {
            if case .failed(let error) = outcome, error != .timedOut {
                continuation?.yield(.streamLost(error))
            }
            return
        }
        switch (requestID, outcome) {
        case (let id?, .ended):
            continuation?.yield(.requestFailed(id, .streamEnded))
        case (let id?, .failed(let error)):
            continuation?.yield(.requestFailed(id, error))
        case (nil, .failed(let error)):
            continuation?.yield(.streamLost(error))
        case (_, .cancelled), (_, .answered), (nil, .ended):
            break
        }
    }

    private static let newline = UInt8(0x0A)

    /// Decodes and clears the buffer. Invalid UTF-8 becomes replacement characters rather
    /// than ending the stream: one bad byte in a comment line must not cost the reply.
    private static func take(_ buffer: inout [UInt8]) -> String {
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }

    #if DEBUG
    /// Returns once the legacy push channel's open → read → reopen loop has ended, having yielded
    /// whatever its last GET called for (a lost session) — how a test knows a channel answered
    /// "not offered" decided, rather than waiting for a decision it could not see.
    func _testPushChannelEnded() async { await pushStream?.value }

    /// Returns once every stream reader started so far — a POST's SSE body, awaited or not — has
    /// ended, having yielded whatever it read: what a test settles before it asserts on the
    /// events a stream did NOT carry.
    func _testReadersFinished() async {
        for reader in Array(readers.values) + anonymousReaders { await reader.value }
    }
    #endif

    /// The legacy era's server→client channel: a GET the server holds open. A server that does
    /// not offer one answers `405` — or `404`, when it routes only `POST` — which is not an
    /// error: the POST replies carry everything on a server like that. Asked again only when
    /// asking again can help (`PushStreamEnd`) — a refused credential only once the credential
    /// changed. A `404` on a channel that DID stream for this session is the other thing a 404
    /// means — the session is gone.
    private func openLegacyServerStream() {
        guard pushStream == nil, endpoint != nil, era == .legacy else { return }
        pushStream = Task { [weak self] in
            await self?.keepLegacyServerStreamOpen()
            return
        }
    }

    /// How one GET on the push channel ended.
    private enum PushStreamEnd {
        /// The server has no push channel: 405, a 2xx with something that is not an event
        /// stream, or a 404 on a session whose channel never streamed. Not asked again, and
        /// nothing to record.
        ///
        /// That 404 is NOT a lost session. A server that keeps sessions but routes only
        /// `POST /mcp` answers every GET 404 while the session is alive; a real loss is reported
        /// by the next POST (`perform`). Until 2026-09-23 a GET 404 reported the session lost,
        /// the connection reconnected, the new session's GET got 404 again — a new session every
        /// few milliseconds until the app quit (F1).
        case notOffered
        /// A 404 on a session whose channel DID stream: the server has forgotten the session —
        /// usually, it restarted. Reported as a POST 404 is, so the connection dials a new one
        /// on its backoff (which is what now bounds the F1 storm: a lost session is a counted
        /// failure, `MCPServerConnection.run`). Until the second review of group C (2026-09-23)
        /// it read as "not offered", and a restarted server went unnoticed until a tool call
        /// failed on it.
        case sessionLost
        /// The server refused the channel in a way asking again cannot change for this session:
        /// a 4xx other than a timeout, a 425, a 429 or a refused credential (a stateless server's
        /// 400, a 410), a redirect to another origin, an address this client will not reach.
        /// Recorded once and not asked again: until the review of 2026-09-23 each of them was
        /// asked again every thirty seconds for the life of the session, a line in the frame
        /// log each time.
        case refused(MCPTransportError)
        /// The server refused the credential this GET carried (401, 403) — `credential` is its
        /// digest (`credentialDigest`). Recorded once, and asked again only with ANOTHER
        /// credential: the authorizer reads the Keychain per request, so a token rotated in
        /// Settings, a secret header re-entered, or a token a LOCKED Keychain could not give
        /// this once — read as no token, so that GET went out bare — is on a later tick's GET,
        /// and the same credential is not sent again (`credentialUnchanged`). A credential the
        /// server refuses on every path is surfaced by the POST path too, `needsAuth` at
        /// connect and the call's own error after it.
        ///
        /// Until the second review of group C (2026-09-23) a 401 or a 403 ended the channel for
        /// the session, and a Keychain locked during a reopen ended it for good; after it, until
        /// the third pass of that review, the same credential was asked again on every tick — a
        /// gateway that answers every GET 403 while the POSTs work cost a request and a frame-log
        /// line every thirty seconds for the life of the session.
        case credentialRefused(MCPTransportError, credential: String)
        /// Not sent: the credential it would carry is the one the server refused. Nothing to
        /// record — the refusal already was — and the channel keeps waiting on the backoff for
        /// a credential that differs.
        case credentialUnchanged
        /// This one GET ended — cleanly, broken, or refused for now: a 5xx from a proxy, a 408,
        /// a 425 or a 429. The channel is asked again on the backoff: until 2026-09-23 every such
        /// refusal ended the loop for good, and `list_changed` stopped arriving until someone
        /// pressed Reconnect (F6).
        case ended(MCPTransportError?)
    }

    /// Opens the push channel and reopens it whenever it ends, for as long as the session
    /// lives. A server, a proxy or the HTTP layer's own ceiling may end the GET at any time;
    /// until 2026-09-23 nothing reopened it, so after the first end `list_changed` stopped
    /// arriving and a rewritten tool went unnoticed until the next reconnect.
    private func keepLegacyServerStreamOpen() async {
        var quickEnds = 0
        // The digest of the last credential the server refused on this channel, if any.
        var refusedCredential: String?
        while !isClosed, !Task.isCancelled, era == .legacy, let sessionID, let endpoint {
            let opened = clock.now()
            switch await readLegacyServerStreamOnce(
                endpoint: endpoint, sessionID: sessionID, unlessCarrying: refusedCredential) {
            case .notOffered:
                return
            case .sessionLost:
                guard !isClosed, !Task.isCancelled else { return }
                // Only the session the 404 was about: a POST may have captured a rotated id
                // meanwhile, and that one is not known to be gone.
                if self.sessionID == sessionID { self.sessionID = nil }
                continuation?.yield(.sessionLost)
                return
            case .refused(let failure):
                if !isClosed, !Task.isCancelled { continuation?.yield(.streamLost(failure)) }
                return
            case .credentialRefused(let failure, let credential):
                guard !isClosed, !Task.isCancelled else { return }
                // One line per refused credential: a tick that would carry it again sends
                // nothing and records nothing (`credentialUnchanged`).
                refusedCredential = credential
                continuation?.yield(.streamLost(failure))
            case .credentialUnchanged:
                break
            case .ended(let failure):
                guard !isClosed, !Task.isCancelled else { return }
                // A quiet server lets the idle ceiling end the GET; that is the stream doing
                // its job, not a failure worth a log line.
                if let failure, failure != .timedOut { continuation?.yield(.streamLost(failure)) }
            }
            quickEnds = clock.now().timeIntervalSince(opened) >= MCPConstants.pushStreamHealthyAfter ? 0 : quickEnds + 1
            let delay = pushStreamRetryDelays[min(quickEnds, pushStreamRetryDelays.count - 1)]
            await clock.sleep(until: clock.now().addingTimeInterval(delay))
        }
    }

    /// One GET on the push channel — built through the authorizer first, and not sent at all
    /// when the credential it would carry is `refusedCredential`, the one the server refused.
    private func readLegacyServerStreamOnce(
        endpoint: URL, sessionID: String, unlessCarrying refusedCredential: String?
    ) async -> PushStreamEnd {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeouts.requestAbsolute
        request.setValue(protocolVersion, forHTTPHeaderField: MCPConstants.protocolVersionHeader)
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        applyConfiguredHeaders(to: &request)

        let credential: String
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            let authorized = try await authorizer.authorized(request)
            credential = Self.credentialDigest(of: authorized, over: request)
            guard credential != refusedCredential else { return .credentialUnchanged }
            (bytes, response) = try await session.sessionBytes(for: authorized)
        } catch {
            // A failure retrying cannot repair — the address refused, a redirect off the origin —
            // refuses the channel; anything else — the network — ends this one GET. (No
            // production authorizer throws: a Keychain that cannot be read gives no token, and
            // the GET goes out bare and comes back 401 — a refused credential, below.)
            let failure = Self.classify(error)
            return failure.isRetryable ? .ended(failure) : .refused(failure)
        }
        guard let http = response as? HTTPURLResponse else {
            await Self.drain(bytes)
            return .ended(malformedFrame("the server's reply was not an HTTP response"))
        }
        switch http.statusCode {
        case 200...299:
            guard (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream")
            else {
                await Self.drain(bytes)
                return .notOffered
            }
            sessionWithPushStream = sessionID
        case 404:
            await Self.drain(bytes)
            return sessionWithPushStream == sessionID ? .sessionLost : .notOffered
        case 405:
            await Self.drain(bytes)
            return .notOffered
        case 300...399:
            await Self.drain(bytes)
            return .refused(refusedRedirect(of: request, answeredWith: http))
        case 401, 403:
            return .credentialRefused(
                .httpStatus(code: http.statusCode, body: messageText(await Self.collectExcerpt(bytes))),
                credential: credential)
        case 408, 425, 429, 500...:
            return .ended(.httpStatus(code: http.statusCode, body: messageText(await Self.collectExcerpt(bytes))))
        default:
            return .refused(.httpStatus(code: http.statusCode, body: messageText(await Self.collectExcerpt(bytes))))
        }
        switch await readStream(bytes, awaiting: nil) {
        case .failed(let error): return .ended(error)
        case .cancelled, .answered, .ended: return .ended(nil)
        }
    }

    /// What the authorizer put on `authorized` — every header field it added or changed over
    /// `unauthorized`, the `Authorization` and the secret headers alike — as a SHA-256 digest:
    /// enough to tell whether the next GET would carry the credential the server refused, and
    /// never the credential itself, which this actor does not keep. A request the authorizer
    /// added nothing to digests as `none`.
    private static func credentialDigest(of authorized: URLRequest, over unauthorized: URLRequest) -> String {
        let added = (authorized.allHTTPHeaderFields ?? [:])
            .filter { unauthorized.value(forHTTPHeaderField: $0.key) != $0.value }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
        guard !added.isEmpty else { return "none" }
        var hash = SHA256()
        for (name, value) in added {
            // NUL cannot occur in a header, so no name and value pair can be read as another.
            hash.update(data: Data("\(name.lowercased())\u{0}\(value)\u{0}".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `DELETE` with the session id — the legacy way to tell a server it may forget us. Best
    /// effort by construction: a server that has already dropped the session answers 404, and
    /// that is the outcome we wanted anyway.
    private func sendSessionDelete(endpoint: URL, sessionID: String) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = MCPConstants.shutdownBudget
        request.setValue(protocolVersion, forHTTPHeaderField: MCPConstants.protocolVersionHeader)
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        applyConfiguredHeaders(to: &request)
        guard let authorized = try? await authorizer.authorized(request) else { return }
        _ = try? await session.sessionData(for: authorized)
    }

    // MARK: - Byte helpers

    /// Reads the whole body, refusing at the ceiling rather than truncating. A truncated
    /// JSON-RPC frame is indistinguishable from a malformed one, and half a tool result would
    /// reach the model as a plausible-looking whole answer.
    private static func collectBody(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    throw MCPTransportError.frameTooLarge(bytes: data.count, limit: limit)
                }
            }
        } catch let error as MCPTransportError {
            throw error
        } catch {
            throw classify(error)
        }
        return data
    }

    /// How much of an error body reaches a message.
    private static let excerptLimit = 4096

    /// The JSON-RPC error response to `requestID` in a non-2xx body (including one whose `id` is
    /// omitted or `null`), or `nil` when the body is anything else — not JSON-RPC, a result, or a
    /// response to another request.
    private static func errorAnswer(in body: Data, to requestID: JSONRPCID) -> JSONRPCResponse? {
        guard case .response(let response)? = try? JSONRPCCodec.decode(body, errorFallbackID: requestID),
              response.id == requestID, response.error != nil
        else { return nil }
        return response
    }

    /// A bounded read for a body nobody will parse — an error page, a 202's empty body.
    private static func collectExcerpt(_ bytes: URLSession.AsyncBytes, limit: Int = excerptLimit) async -> String {
        var data = Data()
        // Errors are swallowed: this is already the failure path, and failing to read the
        // explanation must not replace the status code with a network message.
        if let collected = try? await take(bytes, limit: limit) { data = collected }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Consumes and discards, so the connection is released rather than left half-read.
    private static func drain(_ bytes: URLSession.AsyncBytes) async {
        _ = try? await take(bytes, limit: 64 * 1024)
    }

    private static func take(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    /// Foreign errors never reach a message. `URLError` is classified by CODE into this
    /// client's own English, because a localized system string in a tool result is a defect
    /// this app has already fixed once.
    static func classify(_ error: Error) -> MCPTransportError {
        if let transport = error as? MCPTransportError { return transport }
        if error is CancellationError { return .closed }
        guard let urlError = error as? URLError else { return .network("the request failed") }
        switch urlError.code {
        case .timedOut: return .timedOut
        case .cannotFindHost, .dnsLookupFailed: return .network("the hostname could not be resolved")
        case .cannotConnectToHost: return .network("the connection was refused")
        case .networkConnectionLost: return .network("the connection was lost")
        case .notConnectedToInternet: return .network("this machine is offline")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .network("the TLS connection could not be established")
        case .httpTooManyRedirects: return .network("the server redirected too many times")
        case .cancelled: return .closed
        default: return .network("the request failed")
        }
    }
}
