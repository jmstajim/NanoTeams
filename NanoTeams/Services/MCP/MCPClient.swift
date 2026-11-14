import Foundation

/// Why a call to a server failed, in this client's own words.
///
/// `rpc` is the server's own message and the main case that carries foreign text — it has
/// to, because "your argument was wrong" is only useful with the server's explanation of
/// which one. It is sanitized to one line, redacted — this server's own credentials included
/// — and capped before it reaches a reader. The others carry it second-hand and arrive clean
/// the same way: `transport` (the transport's `messageText`), the versions of
/// `unsupportedProtocolVersion` (`MCPWire`'s version cleaning, then `unsupported(…)`), and
/// `handshakeRefused`'s message (a refusal's, cleaned in `route`).
nonisolated enum MCPClientError: Error, Hashable, LocalizedError {
    case notConnected
    case transport(MCPTransportError)
    /// The server's own refusal. `data` is carried because the one error whose DATA decides
    /// what to do next is `-32022`, and because `-32602` often names the argument that was
    /// wrong — which is the only part of an "invalid params" that helps.
    case rpc(code: Int, message: String, data: JSONValue?)
    /// The server is modern and speaks no revision this client does.
    case unsupportedProtocolVersion(offered: String, serverSupports: [String])
    /// The server refused the probe with a code only the 2026-07-28 revision defines — `-32020`
    /// HeaderMismatch, `-32021` MissingRequiredClientCapability — so it is modern, and nothing in
    /// the probe can be corrected (`MCPEraVerdict`). `message` is its own words, cleaned where
    /// the refusal entered the client.
    case handshakeRefused(code: Int, message: String)
    /// A 2026-07-28 result asked for input before it would finish (`resultType:
    /// input_required`) — input this client never offers: it declares no capability and
    /// retries no call. Not read as the answer it is not.
    case inputRequired
    /// A 2026-07-28 result of a `resultType` this client does not know, which "MUST be
    /// considered invalid" — the type cleaned to one capped line and scrubbed, as every server
    /// text is. Not read.
    case unknownResultType(String)
    case timedOut(method: String)
    case cancelled
    case malformedResult(String)
    case pageLimitExceeded(Int)

    var errorDescription: String? { message }

    /// Non-optional for the same reason `MCPTransportError.message` is.
    var message: String {
        switch self {
        case .notConnected:
            return "The server is not connected. Enable it in Settings → MCP Servers, then try again."
        case .transport(let error):
            return error.message
        case .rpc(let code, let message, _):
            return "The server refused the call (\(code)): \(message)"
        case .unsupportedProtocolVersion(let offered, let serverSupports):
            let versions = serverSupports.isEmpty ? "none it named" : serverSupports.joined(separator: ", ")
            return "The server does not speak MCP \(offered) — it offers \(versions). Update the server, or use one this build supports."
        case .handshakeRefused(let code, let message):
            return "The server refused this client's connection (\(code)): \(message)"
        case .inputRequired:
            return Self.inputRequiredMessage
        case .unknownResultType(let type):
            return Self.unknownResultTypeMessage(type)
        case .timedOut(let method):
            return "The server did not answer \(method) in time. Check that it is running, then reconnect."
        case .cancelled:
            return "The call was cancelled before the server answered."
        case .malformedResult(let detail):
            return "The server's answer could not be read: \(detail)"
        case .pageLimitExceeded(let limit):
            return "The server kept paging past \(limit) pages of tools. Ask it to return a finite list."
        }
    }

    /// What a role reads when a call's result asked for input before it would finish — through
    /// the `MCP_TOOL_ERROR` envelope, whose direction says to take another approach.
    /// runtime-prompt
    static let inputRequiredMessage =
        "The server would not finish this call without more input (resultType input_required), "
            + "and this client cannot give any."

    /// What a role reads when a call's result is of a type this client does not know — through
    /// the `MCP_SERVER_UNAVAILABLE` envelope, as an answer it could not read is.
    /// runtime-prompt
    static func unknownResultTypeMessage(_ type: String) -> String {
        "The server answered with a result type this client does not know (\(type)), so its answer was not read."
    }
}

/// What a successful connect established.
nonisolated struct MCPConnection: Hashable, Sendable {
    let era: MCPProtocolEra
    let protocolVersion: String
    let serverInfo: MCPServerInfo
    /// The server's own catalogue lifetime, already floored. `nil` when it named none.
    let catalogueTTL: TimeInterval?
    /// Whether the server's handshake capabilities include `resources`.
    let advertisesResources: Bool
    /// Whether the server's handshake capabilities include `prompts`.
    let advertisesPrompts: Bool

    init(
        era: MCPProtocolEra,
        protocolVersion: String,
        serverInfo: MCPServerInfo,
        catalogueTTL: TimeInterval?,
        advertisesResources: Bool = false,
        advertisesPrompts: Bool = false
    ) {
        self.era = era
        self.protocolVersion = protocolVersion
        self.serverInfo = serverInfo
        self.catalogueTTL = catalogueTTL
        self.advertisesResources = advertisesResources
        self.advertisesPrompts = advertisesPrompts
    }
}

/// One server's JSON-RPC conversation: correlation, timeouts, cancellation, and the era probe.
///
/// **Everything the transport does not own lives here, and the split is by what varies.** The
/// transport knows bytes and HTTP; this knows which frame answers which request, when a
/// request has waited too long, and what the two eras' handshakes look like. Swap the
/// transport for a scripted one and every rule in this file is still exercised.
///
/// **Two timers, not one.** A per-request inactivity budget that every
/// `notifications/progress` resets, and an absolute ceiling that nothing resets. A single
/// inactivity timer would let a server hold a role forever by reporting progress; a single
/// absolute one would kill a genuinely long call that is reporting honestly. A server reports
/// progress only under a token the request supplied, so every `tools/call` supplies its own id
/// as one (`callTool`); without it the first timer never reset against a conforming server.
///
/// **Nothing the server is slow to take holds a caller.** A cancellation, a timeout and the
/// inbound stream settle their own work first; what they owe the server — the legacy
/// `notifications/cancelled`, the reply to its `ping` — goes out on its own task, under
/// `MCPConstants.courtesyBudget` (`MCPBudget`), and is cancelled when the client closes. Replies
/// to the server's requests are capped (`MCPConstants.maxServerRequestRepliesInFlight`); this
/// client's own cancellations never are.
actor MCPClient {

    private let transport: any MCPTransport
    private let log: MCPRPCLog?
    /// The server's own budgets. Not `private`: paging the catalogue (`+Tools`) is part of
    /// connecting and runs on the same connect budget.
    let timeouts: MCPTimeouts
    private let clientVersion: String
    /// What this connection sends (`MCPAuthorizer.credentialsToRedact`), read — never held —
    /// whenever foreign text leaves this actor: a server's refusal (`route`) and a tool's
    /// result (`callTool`, in `+Tools`, hence not `private`). A server can echo its own secret
    /// into either.
    let credentials: @Sendable () -> MCPRedaction.Credentials
    /// What the request timers read the time from and wait on (`MCPClock`).
    private let clock: any MCPClock

    private var era: MCPProtocolEra?
    private var protocolVersion = MCPConstants.modernProtocolVersion
    private var serverAdvertisesResources = false
    private var serverAdvertisesPrompts = false
    nonisolated let listedExtras = ListedExtrasBox()

    nonisolated final class ListedExtrasBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resources: [JSONValue] = []
        private var resourceTemplates: [JSONValue] = []
        private var prompts: [JSONValue] = []

        func store(resources: [JSONValue], resourceTemplates: [JSONValue], prompts: [JSONValue]) {
            lock.withLock {
                self.resources = resources
                self.resourceTemplates = resourceTemplates
                self.prompts = prompts
            }
        }

        func load() -> (resources: [JSONValue], resourceTemplates: [JSONValue], prompts: [JSONValue]) {
            lock.withLock { (resources, resourceTemplates, prompts) }
        }
    }
    private var nextRequestNumber = 1
    private var inFlight: [JSONRPCID: InFlightRequest] = [:]
    private var pump: Task<Void, Never>?
    private var isClosed = false
    /// Replies to the server's own requests in flight (`answerServerRequest`), each by a number
    /// of its own — the one courtesy a server can multiply, so the one the cap counts. Held so
    /// there can be a cap on them and so `close()` can cancel them.
    private var serverRequestReplies: [Int: Task<Void, Never>] = [:]
    /// This client's own legacy `notifications/cancelled` in flight (`abandon`) — one per call it
    /// abandoned, so bounded by its own calls and never capped. Held so `close()` can cancel
    /// them.
    private var cancellations: [Int: Task<Void, Never>] = [:]
    private var nextCourtesy = 0

    /// Which of the two a courtesy frame is — which decides whether it is capped.
    private enum Courtesy {
        case replyToServerRequest
        case cancellation
    }

    /// Called for every notification this client does not consume itself. The manager hangs
    /// the catalogue refresh off it.
    private var notificationHandler: (@Sendable (JSONRPCNotification) -> Void)?
    /// Called when the transport learns the server forgot the session. Starting a new one
    /// means re-listing and re-pinning, which is the connection's work, not this actor's.
    private var sessionLostHandler: (@Sendable () -> Void)?

    private final class InFlightRequest {
        let method: String
        let startedAt: Date
        var lastActivity: Date
        var continuation: CheckedContinuation<JSONValue, any Error>?
        var watchdog: Task<Void, Never>?
        /// The task sending the request. A POST waiting for its reply runs inside it, so
        /// cancelling it is what closes that request on the wire.
        var dispatch: Task<Void, Never>?
        /// Set the moment the request is handed to the transport. A request abandoned before
        /// that never reached the server, and a server is not told to cancel a request it has
        /// not seen (F13).
        var wasSent = false
        /// Whether the request names itself as its progress token (`_meta.progressToken`).
        let reportsProgress: Bool
        /// Whether it goes out as a 2026-07-28 request (`framesModern`) — decided once, when it
        /// is made, and read twice: for its envelope, and for whether its result says what it is
        /// (`answer(_:to:)`).
        let isModern: Bool
        /// The `MCP-Protocol-Version` header value this request carries on the wire, or `nil`
        /// for the legacy opening `initialize` (which precedes version negotiation).
        let protocolVersion: String?

        init(method: String, now: Date, reportsProgress: Bool, isModern: Bool, protocolVersion: String?) {
            self.method = method
            self.startedAt = now
            self.lastActivity = now
            self.reportsProgress = reportsProgress
            self.isModern = isModern
            self.protocolVersion = protocolVersion
        }

        /// Resumes exactly once. Every path that can end a request — the reply, a timeout, a
        /// transport failure, cancellation, close — goes through here, so a double resume is
        /// impossible by construction rather than by care.
        func settle(_ result: Result<JSONValue, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            watchdog?.cancel()
            watchdog = nil
            continuation.resume(with: result)
        }
    }

    init(
        transport: any MCPTransport,
        log: MCPRPCLog? = nil,
        timeouts: MCPTimeouts = .standard,
        clientVersion: String = AppVersion.current,
        credentials: @escaping @Sendable () -> MCPRedaction.Credentials = { .none },
        clock: any MCPClock = MCPSystemClock()
    ) {
        self.credentials = credentials
        self.clock = clock
        self.transport = transport
        self.log = log
        self.timeouts = timeouts
        self.clientVersion = clientVersion
    }

    func onNotification(_ handler: @escaping @Sendable (JSONRPCNotification) -> Void) {
        notificationHandler = handler
    }

    func onSessionLost(_ handler: @escaping @Sendable () -> Void) {
        sessionLostHandler = handler
    }

    // MARK: - Connecting

    /// Opens the connection and settles the era.
    ///
    /// `cachedEra` is a hint from the trust record, never a belief: a server can be upgraded
    /// under the app, so a cached legacy connection that fails its handshake falls through to
    /// the probe exactly once rather than reporting a failure.
    ///
    /// The probe is `server/discover`, the 2026-07-28 handshake, and what its answer means is
    /// `MCPEraVerdict`'s alone: a result is adopted by the revisions it names, a recognized
    /// modern refusal fails in the server's words or retries a revision it names, and only what
    /// identifies a legacy server — every other refusal, no answer at all — falls back to
    /// `initialize`. Until 2026-10-28 the rule was spread over three functions here and fell
    /// back on everything but a `-32022`.
    func connect(cachedEra: MCPProtocolEra?) async throws -> MCPConnection {
        guard !isClosed else { throw MCPClientError.notConnected }
        do {
            try await transport.connect()
        } catch let error as MCPTransportError {
            throw MCPClientError.transport(error)
        }
        startPump()

        if cachedEra == .legacy, let connection = try? await legacyHandshake() {
            return connection
        }
        var asking = MCPConstants.modernProtocolVersion
        var retried = false
        while true {
            switch MCPEraVerdict.of(await probe(at: asking), asked: asking, retried: retried) {
            case .modern(let version, let result):
                return await adoptModern(result: result, version: version)
            case .retry(let version):
                // A server refusing a revision it lists as supported is contradicting itself —
                // which it does while it starts up or rolls a config. Asked once more; a second
                // refusal is a refusal.
                log?.noteEra(.modern, protocolVersion: version,
                             how: "server/discover refused a version it lists as supported — retrying once")
                asking = version
                retried = true
            case .legacy:
                return try await legacyHandshake()
            case .fail(.unsupported(let versions)):
                throw unsupported(offered: asking, serverSupports: versions)
            case .fail(.refused(let code, let message)):
                throw MCPClientError.handshakeRefused(code: code, message: message)
            case .fail(.inputRequired):
                throw MCPClientError.inputRequired
            case .fail(.unknownResultType(let type)):
                throw MCPClientError.unknownResultType(type)
            }
        }
    }

    /// `server/discover` at `version`, read into what the era verdict needs. Never longer than
    /// the server's own connect budget: the probe is part of connecting.
    private func probe(at version: String) async -> MCPEraVerdict.ProbeAnswer {
        protocolVersion = version
        do {
            return .result(try await call(
                method: MCPWire.discoverMethod, params: nil, hints: .none,
                timeout: min(MCPConstants.probeTimeout, timeouts.connect)))
        } catch MCPClientError.rpc(let code, let message, let data) {
            return .refused(code: code, message: message, data: data)
        } catch MCPClientError.inputRequired {
            return .result(.object(["resultType": .string(MCPWire.inputRequiredResultType)]))
        } catch MCPClientError.unknownResultType(let type) {
            return .result(.object(["resultType": .string(type)]))
        } catch {
            return .noAnswer
        }
    }

    /// The revision the verdict chose, which goes back in every request's `MCP-Protocol-Version`
    /// header and envelope — one this client speaks, never a server's capped spelling, whose
    /// `…` is not a header byte (until 2026-09-23 any answer was adopted). When the server's
    /// `DiscoverResult` advertises push capabilities (`subscriptions` or `listChanged: true`),
    /// also opens the modern `subscriptions/listen` notification stream.
    private func adoptModern(result: JSONValue, version: String) async -> MCPConnection {
        protocolVersion = version
        era = .modern
        serverAdvertisesResources = MCPWire.advertisesResources(inHandshakeResult: result)
        serverAdvertisesPrompts = MCPWire.advertisesPrompts(inHandshakeResult: result)
        await transport.adopt(era: .modern, protocolVersion: version)
        log?.noteEra(.modern, protocolVersion: version, how: "server/discover answered")
        if MCPWire.advertisesSubscriptions(inDiscoverResult: result) {
            await openModernSubscriptionStream(version: version)
        }
        return MCPConnection(
            era: .modern, protocolVersion: version,
            serverInfo: MCPServerInfo(result: result),
            catalogueTTL: flooredTTL(MCPWire.catalogueTTL(from: result)),
            advertisesResources: serverAdvertisesResources,
            advertisesPrompts: serverAdvertisesPrompts)
    }

    /// Opens the modern era's server-to-client notification stream (`POST subscriptions/listen`)
    /// with `MCPSendHints(expectsLongLivedStream: true)`. `StreamableHTTPTransport` detaches
    /// its SSE reader under `timeouts.requestAbsolute` and returns as soon as the response
    /// headers arrive, so the subscription stream is open for the life of the connection
    /// without a per-call inactivity watchdog (`DEBTS.md` D-M7(a)).
    private func openModernSubscriptionStream(version: String) async {
        guard !isClosed else { return }
        let id = allocateID()
        let frame = MCPOutgoingFrame.request(JSONRPCRequest(
            id: id,
            method: MCPWire.subscriptionsListenMethod,
            params: outgoingParams(MCPWire.subscriptionsListenParams(), progressToken: nil, modern: true)))
        log?.noteOutgoing(frame)
        let transport = self.transport
        let hints = MCPSendHints(expectsLongLivedStream: true, protocolVersion: version)
        let budget = timeouts.connect
        let clock = self.clock
        _ = try? await MCPBudget.run(within: budget, clock: clock) {
            _ = try await transport.send(frame, hints: hints)
        }
    }

    /// `initialize` → `notifications/initialized`, with the version checked against the set
    /// this client accepts. A server answering `2024-11-05` is refused rather than guessed at:
    /// that revision is a DIFFERENT TRANSPORT (HTTP+SSE), not a dialect, and speaking to it
    /// over Streamable HTTP would fail later in a way nothing points at.
    private func legacyHandshake() async throws -> MCPConnection {
        protocolVersion = MCPConstants.legacyProtocolVersion
        let result = try await call(
            method: MCPWire.initializeMethod,
            params: MCPWire.initializeParams(
                protocolVersion: MCPConstants.legacyProtocolVersion, clientVersion: clientVersion),
            hints: .none,
            timeout: timeouts.connect)

        let negotiated = MCPWire.negotiatedProtocolVersion(from: result) ?? MCPConstants.legacyProtocolVersion
        guard MCPConstants.acceptedLegacyProtocolVersions.contains(negotiated) else {
            throw unsupported(offered: MCPConstants.legacyProtocolVersion, serverSupports: [negotiated])
        }
        protocolVersion = negotiated
        era = .legacy
        serverAdvertisesResources = MCPWire.advertisesResources(inHandshakeResult: result)
        serverAdvertisesPrompts = MCPWire.advertisesPrompts(inHandshakeResult: result)
        await transport.adopt(era: .legacy, protocolVersion: negotiated)
        try await notify(method: MCPWire.initializedNotification, params: nil, timeout: timeouts.connect)
        log?.noteEra(.legacy, protocolVersion: negotiated, how: "initialize answered")
        return MCPConnection(
            era: .legacy, protocolVersion: negotiated,
            serverInfo: MCPServerInfo(result: result),
            catalogueTTL: flooredTTL(MCPWire.catalogueTTL(from: result)),
            advertisesResources: serverAdvertisesResources,
            advertisesPrompts: serverAdvertisesPrompts)
    }

    /// The refusal of a server that speaks no revision this client does. The versions it names
    /// are server text on their way to the status row: `MCPWire` has already put each on one
    /// visible line and capped them, and this scrubs them of what THIS server is sent, as
    /// every other message it can reach that row with is.
    private func unsupported(offered: String, serverSupports: [String]) -> MCPClientError {
        let credentials = credentials()
        return .unsupportedProtocolVersion(offered: offered, serverSupports: serverSupports.map(credentials.text))
    }

    /// A server naming 100 ms would re-list its catalogue between every tool call.
    private func flooredTTL(_ ttl: TimeInterval?) -> TimeInterval? {
        ttl.map { max($0, MCPConstants.minimumCatalogueTTL) }
    }

    // MARK: - Calling

    /// `reportsProgress`: the request names itself as its progress token, so a server may keep
    /// it alive by reporting (`callTool` asks; a catalogue page, on the connect budget, does
    /// not).
    @discardableResult
    func call(
        method: String,
        params: JSONValue? = nil,
        hints: MCPSendHints = .none,
        timeout: TimeInterval? = nil,
        reportsProgress: Bool = false
    ) async throws -> JSONValue {
        guard !isClosed else { throw MCPClientError.notConnected }
        let id = allocateID()
        let record = InFlightRequest(
            method: method, now: clock.now(), reportsProgress: reportsProgress,
            isModern: framesModern,
            protocolVersion: method == MCPWire.initializeMethod ? nil : protocolVersion)
        inFlight[id] = record

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                record.continuation = continuation
                record.watchdog = makeWatchdog(id: id, absolute: timeout)
                record.dispatch = Task { await self.dispatch(id: id, method: method, params: params, hints: hints) }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    /// Sends a notification, waiting for the server to take it no longer than `timeout` —
    /// by default the request inactivity budget. Past it the POST is closed and the send fails
    /// as `.timedOut`. The handshake's `notifications/initialized` runs on the connect budget:
    /// until 2026-09-23 no notification had a deadline, and a server that answered
    /// `initialize` and then sat on this POST held the connect for two minutes (F3).
    func notify(method: String, params: JSONValue? = nil, timeout: TimeInterval? = nil) async throws {
        guard !isClosed else { throw MCPClientError.notConnected }
        let frame = MCPOutgoingFrame.notification(JSONRPCNotification(
            method: method, params: outgoingParams(params, progressToken: nil, modern: framesModern)))
        log?.noteOutgoing(frame)
        let transport = self.transport
        let frameHints = MCPSendHints(protocolVersion: protocolVersion)
        let finished: Bool
        do {
            finished = try await MCPBudget.run(within: timeout ?? timeouts.requestInactivity, clock: clock) {
                _ = try await transport.send(frame, hints: frameHints)
            }
        } catch let error as MCPTransportError {
            throw MCPClientError.transport(error)
        } catch {
            throw MCPClientError.transport(.network("the request failed"))
        }
        guard finished else { throw MCPClientError.timedOut(method: method) }
    }

    private func dispatch(id: JSONRPCID, method: String, params: JSONValue?, hints: MCPSendHints) async {
        // Abandoned before it went out — a cancel that won the race to this actor. Sending it
        // now would start a call nobody is waiting for.
        guard let record = inFlight[id], !Task.isCancelled else { return }
        let frame = MCPOutgoingFrame.request(JSONRPCRequest(
            id: id, method: method,
            params: outgoingParams(
                params, progressToken: record.reportsProgress ? id : nil, modern: record.isModern)))
        log?.noteOutgoing(frame)
        record.wasSent = true
        let frameHints = hints.protocolVersion == nil ? hints.withProtocolVersion(record.protocolVersion) : hints
        do {
            _ = try await transport.send(frame, hints: frameHints)
        } catch let error as MCPTransportError {
            await fail(id: id, with: error)
        } catch {
            finish(id: id, with: .failure(MCPClientError.transport(.network("the request failed"))))
        }
    }

    /// The modern era carries version and capabilities in `_meta` on EVERY request; the legacy
    /// era carried them once, in `initialize`, and must not see them again. A progress token
    /// goes in `_meta` in both eras, beside whatever else is there.
    private func outgoingParams(_ params: JSONValue?, progressToken: JSONRPCID?, modern: Bool) -> JSONValue? {
        let tokened = progressToken.map { MCPWire.withProgressToken(params, $0) } ?? params
        guard modern else { return tokened }
        return MCPWire.withModernMeta(
            tokened, protocolVersion: protocolVersion, clientVersion: clientVersion)
    }

    /// Whether a frame made NOW is a 2026-07-28 one. The second condition covers the handshake
    /// itself: `legacyHandshake` sets the legacy version before it sends `initialize`, so the era
    /// is still unsettled but the version already says which frames these are.
    private var framesModern: Bool {
        era != .legacy && !MCPConstants.acceptedLegacyProtocolVersions.contains(protocolVersion)
    }

    private func allocateID() -> JSONRPCID {
        defer { nextRequestNumber += 1 }
        return .number(nextRequestNumber)
    }

    private func finish(id: JSONRPCID, with result: Result<JSONValue, any Error>) {
        guard let record = inFlight.removeValue(forKey: id) else { return }
        record.settle(result)
    }

    // MARK: - Timers

    /// One task per request, checking both budgets. Sleeps to whichever deadline is nearer and
    /// re-checks, so a `notifications/progress` that pushed the inactivity deadline out is
    /// picked up without the notification having to touch the timer itself.
    private func makeWatchdog(id: JSONRPCID, absolute: TimeInterval?) -> Task<Void, Never> {
        let inactivityBudget = timeouts.requestInactivity
        let absoluteBudget = absolute ?? timeouts.requestAbsolute
        let clock = self.clock
        return Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let sleep = await self.secondsUntilDeadline(
                    id: id, inactivityBudget: inactivityBudget, absoluteBudget: absoluteBudget)
                else { return }
                if sleep <= 0 {
                    await self.timeOut(id: id)
                    return
                }
                await clock.sleep(until: clock.now().addingTimeInterval(min(sleep, 5)))
            }
        }
    }

    /// `nil` once the request is gone — the watchdog stops rather than polling a dead id.
    private func secondsUntilDeadline(
        id: JSONRPCID, inactivityBudget: TimeInterval, absoluteBudget: TimeInterval
    ) -> TimeInterval? {
        guard let record = inFlight[id] else { return nil }
        let now = clock.now()
        let inactivityDeadline = record.lastActivity.addingTimeInterval(inactivityBudget)
        let absoluteDeadline = record.startedAt.addingTimeInterval(absoluteBudget)
        return min(inactivityDeadline, absoluteDeadline).timeIntervalSince(now)
    }

    private func timeOut(id: JSONRPCID) async {
        guard let record = inFlight[id] else { return }
        log?.noteFailure(MCPClientError.timedOut(method: record.method), method: record.method, requestID: id)
        await abandon(id: id, reason: "timed out", failing: .timedOut(method: record.method))
    }

    /// One request's exchange failed. The HTTP layer giving up on it IS the call timing out —
    /// the same code for the model and, for a legacy server, the same cancellation — whoever
    /// noticed first: reported as a transport failure it read as "the server is unavailable,
    /// reconnect", and the server was never told to stop (F12).
    private func fail(id: JSONRPCID, with error: MCPTransportError) async {
        guard let record = inFlight[id] else { return }
        if error == .timedOut {
            await timeOut(id: id)
            return
        }
        log?.noteFailure(error, method: record.method, requestID: id)
        finish(id: id, with: .failure(MCPClientError.transport(error)))
    }

    // MARK: - Cancellation

    private func cancelRequest(id: JSONRPCID) async {
        await abandon(id: id, reason: "cancelled by the client", failing: .cancelled)
    }

    /// Ends one request: settles the caller, then tells the server to stop in the only way its
    /// era offers, and closes the stream the reply would have come back on. The legacy
    /// notification is a courtesy the modern era dropped: there, abandoning the stream IS the
    /// cancellation.
    ///
    /// Everything that ends the CALL happens before the first await — the record goes, the
    /// caller is resumed, the task sending the request is cancelled — so a request cancelled
    /// before it went out is never sent (its dispatch finds no record), and the caller never
    /// waits on the server. Until 2026-09-23 the courtesy POST came first and was awaited: a
    /// cancel or a timeout held the caller for as long as a busy server took to accept it —
    /// up to the whole inactivity budget (F3) — and a cancel that won the race to this actor
    /// let the request go out AFTER its own cancellation, which a legacy server ignores and
    /// then runs the request anyway (F13).
    private func abandon(id: JSONRPCID, reason: String, failing error: MCPClientError) async {
        guard let record = inFlight.removeValue(forKey: id) else { return }
        record.settle(.failure(error))
        // Both halves: a POST still waiting for its first byte is closed by cancelling the task
        // that sent it, and a reply already streaming is closed by the transport below. Until
        // 2026-09-23 only the second happened, and the server kept working on a call nobody
        // wanted until the HTTP layer's own timeout.
        record.dispatch?.cancel()
        if era == .legacy, record.wasSent {
            let frame = MCPOutgoingFrame.notification(JSONRPCNotification(
                method: MCPWire.cancelledNotification,
                params: MCPWire.cancelledParams(requestID: id, reason: reason)))
            sendCourtesy(frame, .cancellation)
        }
        await transport.cancel(requestID: id)
    }

    /// A frame the server is owed but nobody waits on — the legacy `notifications/cancelled`,
    /// the reply to a server's `ping` — on its own task, under `MCPConstants.courtesyBudget`:
    /// a server too busy to take it within that does not get it, and holds no caller meanwhile.
    /// Every one is tracked, and `close()` cancels them: until the second review of group C
    /// (2026-09-23) each was an untracked task, and a closed client's POSTs ran on to the end
    /// of their budget.
    ///
    /// Replies to the server's requests are capped, and dropped past the cap: at most
    /// `MCPConstants.maxServerRequestRepliesInFlight` at once. They are the flood vector — a
    /// server streaming requests down the push channel had this client open one POST per
    /// request with nothing to slow it. A dropped reply costs the server a reply it was owed,
    /// which is what it asked for by flooding; never written to the frame log, since a line per
    /// dropped request would be the same flood in the log.
    ///
    /// This client's own cancellations are NOT capped: each follows a call this client made
    /// and abandoned, so they are bounded by its own calls, and dropping one leaves a legacy
    /// server running a call the user cancelled — a mutating one, maybe — to the end. Until the
    /// third pass of that review one cap counted both, and a server holding every reply slot
    /// had a Pause's cancellations dropped without a word.
    private func sendCourtesy(_ frame: MCPOutgoingFrame, _ kind: Courtesy) {
        guard !isClosed else { return }
        if kind == .replyToServerRequest,
           serverRequestReplies.count >= MCPConstants.maxServerRequestRepliesInFlight { return }
        log?.noteOutgoing(frame)
        let transport = self.transport
        let frameHints = MCPSendHints(protocolVersion: protocolVersion)
        let clock = self.clock
        let number = nextCourtesy
        nextCourtesy += 1
        // The task cannot end before it is recorded: its last step runs on this actor, which
        // is busy with this call until the assignment below.
        let task = Task { [weak self] in
            _ = try? await MCPBudget.run(within: MCPConstants.courtesyBudget, clock: clock) {
                _ = try await transport.send(frame, hints: frameHints)
            }
            await self?.courtesyEnded(number, kind)
        }
        switch kind {
        case .replyToServerRequest: serverRequestReplies[number] = task
        case .cancellation: cancellations[number] = task
        }
    }

    private func courtesyEnded(_ number: Int, _ kind: Courtesy) {
        switch kind {
        case .replyToServerRequest: serverRequestReplies.removeValue(forKey: number)
        case .cancellation: cancellations.removeValue(forKey: number)
        }
    }

    // MARK: - Inbound

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            for await event in await self.transport.events() {
                await self.handle(event)
            }
            await self.failEverythingInFlight(with: .transport(.closed))
        }
    }

    private func handle(_ event: MCPIncomingEvent) async {
        switch event {
        case .frame(let frame):
            log?.noteIncoming(frame)
            await route(frame)
        case .failed(let error):
            log?.noteFailure(error)
            // One dead connection fails every waiting request at once. Letting them time out
            // one by one would leave a role waiting two minutes for a server that is already
            // gone — a stall the user cannot explain.
            failEverythingInFlight(with: .transport(error))
        case .requestFailed(let id, let error):
            await fail(id: id, with: error)
        case .streamLost(let error):
            // Nothing was waiting on it, so nothing fails; the transport reopens it.
            log?.noteFailure(error)
        case .sessionLost:
            log?.noteFailure(MCPTransportError.sessionLost)
            sessionLostHandler?()
        case .closed:
            failEverythingInFlight(with: .transport(.closed))
        }
    }

    private func route(_ frame: JSONRPCIncoming) async {
        switch frame {
        case .response(let response):
            switch response.outcome {
            case .result(let value):
                finish(id: response.id, with: answer(value, to: response.id))
            case .failure(let error):
                // Cleaned where it enters the app: the message rides into the error envelope
                // the model reads (`ToolErrorHandler.classify(mcpClientError:)` forwards it) and
                // into the status row. One line, nothing hidden — then scrubbed, so a secret
                // split by an invisible character is whole again when the redaction looks.
                finish(id: response.id, with: .failure(MCPClientError.rpc(
                    code: error.code,
                    message: credentials().excerpt(MCPTextSanitizer.singleLine(error.message), limit: 500),
                    data: error.data)))
            }
        case .notification(let notification):
            routeNotification(notification)
        case .request(let request):
            answerServerRequest(request)
        }
    }

    /// A result, as the request it answers may read it. A 2026-07-28 request's result says what
    /// it is (basic/index, "ResultType") and is the answer only when it says it is one — absent
    /// or `"complete"`. `input_required` asks for input this client never offers, and any type
    /// it does not know "MUST be considered invalid": both fail the request, closed, rather than
    /// reaching its caller as an answer — an `input_required` call read as one was an empty,
    /// successful tool result (until 2026-10-28). One rule for every modern request: the
    /// probe (an unfinished one is no `DiscoverResult`), a catalogue page, a call. A legacy
    /// request's result is read as it is: its revision has no `resultType`.
    private func answer(_ value: JSONValue, to id: JSONRPCID) -> Result<JSONValue, any Error> {
        guard inFlight[id]?.isModern == true else { return .success(value) }
        switch MCPWire.resultType(of: value) {
        case .complete:
            return .success(value)
        case .inputRequired:
            return .failure(MCPClientError.inputRequired)
        case .unrecognized(let type):
            return .failure(MCPClientError.unknownResultType(credentials().text(type)))
        }
    }

    private func routeNotification(_ notification: JSONRPCNotification) {
        switch notification.method {
        case MCPWire.progressNotification:
            touchActivity(for: notification)
        case MCPWire.cancelledNotification:
            // The server cancelling a request IT sent: a cancellation names a request issued in
            // the same direction, and the server's ids are its own namespace. This client
            // answers the server's requests at once and has nothing to abort. Until 2026-09-23
            // the id was looked up among this client's own requests, and a server cancelling
            // its `ping` 3 failed this client's `tools/call` 3.
            break
        default:
            notificationHandler?(notification)
        }
    }

    /// A progress report resets ONE request's inactivity budget — the one it names. A report
    /// that names nothing resets nothing: otherwise a server could hold every in-flight
    /// request open by reporting progress on one.
    private func touchActivity(for notification: JSONRPCNotification) {
        guard let token = MCPWire.progressToken(from: notification.params),
              let id = inFlight.keys.first(where: { $0.description == token }) else { return }
        inFlight[id]?.lastActivity = clock.now()
    }

    /// The legacy era lets a server send requests; in the modern era "The client MUST NOT send
    /// JSON-RPC responses", so the incoming frame is logged by `route` and left unanswered.
    /// Legacy requests are answered in two ways: `ping` gets an empty result, and everything
    /// else gets `methodNotFound` — because this client declared no capabilities, so there is
    /// nothing else a server can legitimately ask for.
    ///
    /// Off the inbound stream, as a courtesy: the reply is a POST, and until 2026-09-23 the pump
    /// awaited it — a server slow to accept it held back every response and progress report
    /// behind it, and a call whose reply had already arrived timed out waiting in the
    /// queue (F14).
    private func answerServerRequest(_ request: JSONRPCRequest) {
        guard era == .legacy else { return }
        let outcome: JSONRPCResponse.Outcome = request.method == MCPWire.pingMethod
            ? .result(.object([:]))
            : .failure(JSONRPCError(
                code: MCPErrorCode.methodNotFound,
                message: "This client declares no capabilities, so it cannot serve \(request.method)."))
        sendCourtesy(.response(JSONRPCResponse(id: request.id, outcome: outcome)), .replyToServerRequest)
    }

    private func failEverythingInFlight(with error: MCPClientError) {
        let records = inFlight
        inFlight.removeAll()
        for (_, record) in records { record.settle(.failure(error)) }
    }

    // MARK: - Closing

    func close(budget: TimeInterval = MCPConstants.shutdownBudget) async {
        guard !isClosed else { return }
        isClosed = true
        failEverythingInFlight(with: .transport(.closed))
        // Owed to a session that is over — both kinds.
        for courtesy in serverRequestReplies.values { courtesy.cancel() }
        for courtesy in cancellations.values { courtesy.cancel() }
        serverRequestReplies.removeAll()
        cancellations.removeAll()
        await transport.close(budget: budget)
        pump?.cancel()
        pump = nil
        log?.noteClose(reason: "the connection was closed")
    }

    // MARK: - Reading state

    /// Written by `listAllTools`, which lives in an extension and so cannot reach the log
    /// directly.
    func noteListed(toolCount: Int, pages: Int) {
        log?.noteList(toolCount: toolCount, pages: pages)
    }

    var currentEra: MCPProtocolEra? { era }
    var negotiatedProtocolVersion: String { protocolVersion }
    var advertisesResources: Bool { serverAdvertisesResources }
    var advertisesPrompts: Bool { serverAdvertisesPrompts }
    var inFlightCount: Int { inFlight.count }
}
