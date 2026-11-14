import Foundation
import Network

/// Errors surfaced when starting `HostedMCPListener` (§7.1).
nonisolated enum HostedMCPListenerError: Error, Sendable, Equatable {
    case portInUse(UInt16)
    case bindFailed(String)

    var message: String {
        switch self {
        case .portInUse:
            return "Port in use"
        case .bindFailed(let detail):
            return "Could not start the server: \(detail)"
        }
    }
}

/// Lifecycle state of `HostedMCPListener` (§7.1).
nonisolated enum HostedMCPListenerState: Sendable, Equatable {
    case stopped
    case starting
    case listening(port: UInt16)
    case failed(HostedMCPListenerError)
}

/// Loopback-only HTTP/1.1 MCP listener built on `Network.framework` (`127.0.0.1` and `[::1]`, §7.1).
///
/// Enforces:
/// - "Both or neither" dual-stack startup (`127.0.0.1` + `[::1]`): if either address cannot bind,
///   both listeners are closed and `.portInUse` is surfaced.
/// - `maxOpenConnections = 32` with eviction of the oldest connection still in the header-reading
///   phase, plus `reservedNonWaitConnections = 8` so `wait_for_events` long-polls can never starve
///   short control requests (`503 Retry-After: 2`).
/// - `503 Retry-After: 1` during work-folder transitions when an older folder generation was active.
/// - A `ProcessInfo` `.userInitiatedAllowingIdleSystemSleep` activity held only while at least one
///   dispatched `POST /mcp` request is in flight (§13.2 п.6), never merely while listening.
nonisolated final class HostedMCPListener: @unchecked Sendable {

    nonisolated struct Configuration: Sendable, Equatable {
        var maxOpenConnections: Int
        var reservedNonWaitConnections: Int
        var headDeadline: Duration
        var bodyDeadline: Duration

        init(
            maxOpenConnections: Int = HostedMCPConstants.maxOpenConnections,
            reservedNonWaitConnections: Int = HostedMCPConstants.reservedNonWaitConnections,
            headDeadline: Duration = .seconds(HostedMCPConstants.requestHeaderDeadlineSeconds),
            bodyDeadline: Duration = .seconds(HostedMCPConstants.requestBodyDeadlineSeconds)
        ) {
            self.maxOpenConnections = max(2, maxOpenConnections)
            self.reservedNonWaitConnections = max(1, min(reservedNonWaitConnections, self.maxOpenConnections - 1))
            self.headDeadline = headDeadline
            self.bodyDeadline = bodyDeadline
        }
    }

    private final class ActiveConnection: @unchecked Sendable {
        let id: UUID
        let acceptedSequence: UInt64
        let nwConnection: NWConnection
        let driver: HostedMCPHTTPConnectionDriver
        var dispatchTask: Task<Void, Never>?

        init(id: UUID, acceptedSequence: UInt64, nwConnection: NWConnection, driver: HostedMCPHTTPConnectionDriver) {
            self.id = id
            self.acceptedSequence = acceptedSequence
            self.nwConnection = nwConnection
            self.driver = driver
        }
    }

    private let agentStore: HostedMCPAgentStore
    private let dispatcher: HostedMCPDispatcher
    private let frameLog: HostedMCPFrameLog
    private let configuration: Configuration
    private let isFolderTransitionGateActive: @Sendable () -> Bool

    private let queue = DispatchQueue(label: "com.nanoteams.hostedmcp.listener", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _state: HostedMCPListenerState = .stopped
    private var _boundPort: UInt16?
    private var _appNapActivity: NSObjectProtocol?

    // Accessed exclusively on `queue`
    private var v4Listener: NWListener?
    private var v6Listener: NWListener?
    private var connections: [UUID: ActiveConnection] = [:]
    private var nextConnectionSequence: UInt64 = 0
    /// Dispatched `POST /mcp` requests whose dispatcher task has not finished, keyed by a
    /// sequence that never repeats across restarts; the value says whether the request holds a
    /// `wait_for_events` slot. `stop()` empties it, so a request it abandoned that finishes
    /// late finds nothing to end.
    private var inFlightRequests: [UInt64: Bool] = [:]
    private var nextRequestSequence: UInt64 = 0
    private var activeWaitCount: Int = 0
    private var pendingGracefulCloseCount: Int = 0
    private var isStopped: Bool = true

    var state: HostedMCPListenerState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    var boundPort: UInt16? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _boundPort
    }

    /// True while the listener holds a `ProcessInfo` `.userInitiatedAllowingIdleSystemSleep`
    /// activity assertion so macOS App Nap does not throttle SSE keepalives, `wait_for_events`,
    /// or tool execution when all windows are closed (§13.2 п.6) — that is, while at least one
    /// dispatched `POST /mcp` request is in flight. An idle listener holds none, and `stop()`,
    /// a failed `start` (which stops first) and `deinit` end it.
    var hasActiveAppNapActivity: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _appNapActivity != nil
    }

    #if DEBUG
    func _testOpenConnectionCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.connections.count) }
        }
    }
    #endif

    init(
        agentStore: HostedMCPAgentStore,
        dispatcher: HostedMCPDispatcher,
        frameLog: HostedMCPFrameLog = HostedMCPFrameLog(),
        configuration: Configuration = Configuration(),
        isFolderTransitionGateActive: @escaping @Sendable () -> Bool = { false }
    ) {
        self.agentStore = agentStore
        self.dispatcher = dispatcher
        self.frameLog = frameLog
        self.configuration = configuration
        self.isFolderTransitionGateActive = isFolderTransitionGateActive

        agentStore.addInvalidationHandler { [weak self] agentID in
            self?.handleAgentInvalidated(agentID)
        }
    }

    deinit {
        if let activity = _appNapActivity {
            _appNapActivity = nil
            ProcessInfo.processInfo.endActivity(activity)
        }
        v4Listener?.cancel()
        v6Listener?.cancel()
    }

    /// Starts both `127.0.0.1` and `[::1]` listeners on `port` (or an ephemeral port when `port == 0` in tests).
    /// Returns the actual bound port.
    @discardableResult
    func start(port: UInt16 = HostedMCPConstants.defaultPort) async throws -> UInt16 {
        await stop(gracePeriod: .zero)
        setState(.starting, boundPort: nil)

        let maxAttempts = port == 0 ? 5 : 1
        var lastPort = port
        for _ in 0..<maxAttempts {
            guard let v4Pair = try? await startSingleListener(host: .ipv4(.loopback), port: port) else {
                break
            }
            let assignedPort = port > 0 ? port : v4Pair.1
            lastPort = assignedPort
            if let v6Pair = try? await startSingleListener(host: .ipv6(.loopback), port: assignedPort) {
                await installActiveListeners(v4: v4Pair.0, v6: v6Pair.0, port: assignedPort)
                return assignedPort
            }
            await cancelListenerAndWait(v4Pair.0)
        }
        let err = HostedMCPListenerError.portInUse(lastPort)
        setState(.failed(err), boundPort: nil)
        throw err
    }

    /// Stops both listeners, allows any woken in-flight responses up to `gracePeriod` to flush,
    /// and then cancels remaining dispatcher requests and connections.
    func stop(gracePeriod: Duration = .milliseconds(250)) async {
        let (oldV4, oldV6, hasDrainingWork): (NWListener?, NWListener?, Bool) = await withCheckedContinuation { continuation in
            queue.async {
                self.isStopped = true
                let v4 = self.v4Listener
                let v6 = self.v6Listener
                self.v4Listener = nil
                self.v6Listener = nil
                let headerOnlyIDs = self.connections.values
                    .filter { $0.driver.isReadingHead }
                    .map(\.id)
                for id in headerOnlyIDs {
                    self.evictConnection(id: id)
                }
                let needsDrain = !self.connections.isEmpty || self.pendingGracefulCloseCount > 0
                continuation.resume(returning: (v4, v6, needsDrain))
            }
        }

        if let oldV4 {
            await cancelListenerAndWait(oldV4)
        }
        if let oldV6 {
            await cancelListenerAndWait(oldV6)
        }

        if hasDrainingWork && gracePeriod > .zero {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: gracePeriod)
            while clock.now < deadline {
                let drained: Bool = await withCheckedContinuation { continuation in
                    queue.async {
                        continuation.resume(
                            returning: self.connections.isEmpty && self.pendingGracefulCloseCount == 0
                        )
                    }
                }
                if drained { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        dispatcher.cancelAllRequests()

        let remainingConns: [ActiveConnection] = await withCheckedContinuation { continuation in
            queue.async {
                let conns = Array(self.connections.values)
                self.connections.removeAll()
                self.abandonInFlightRequests()
                continuation.resume(returning: conns)
            }
        }

        for conn in remainingConns {
            conn.dispatchTask?.cancel()
            conn.nwConnection.forceCancel()
        }
        setState(.stopped, boundPort: nil)
    }

    // MARK: - Private Listener Setup

    private func setState(_ newState: HostedMCPListenerState, boundPort: UInt16?) {
        stateLock.lock()
        _state = newState
        _boundPort = boundPort
        stateLock.unlock()
    }

    // MARK: - In-Flight Requests & App Nap (§13.2 п.6)

    private func beginInFlightRequest(holdingWaitSlot: Bool) -> UInt64 {
        dispatchPrecondition(condition: .onQueue(queue))
        nextRequestSequence &+= 1
        inFlightRequests[nextRequestSequence] = holdingWaitSlot
        if holdingWaitSlot {
            activeWaitCount += 1
        }
        if inFlightRequests.count == 1 {
            setAppNapActivityHeld(true)
        }
        return nextRequestSequence
    }

    private func endInFlightRequest(_ sequence: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let heldWaitSlot = inFlightRequests.removeValue(forKey: sequence) else { return }
        if heldWaitSlot {
            activeWaitCount -= 1
        }
        if inFlightRequests.isEmpty {
            setAppNapActivityHeld(false)
        }
    }

    private func abandonInFlightRequests() {
        dispatchPrecondition(condition: .onQueue(queue))
        inFlightRequests.removeAll()
        activeWaitCount = 0
        setAppNapActivityHeld(false)
    }

    private func setAppNapActivityHeld(_ held: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if held {
            guard _appNapActivity == nil else { return }
            _appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "NanoTeams Hosted MCP request in flight"
            )
        } else if let activity = _appNapActivity {
            _appNapActivity = nil
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private func installActiveListeners(v4: NWListener, v6: NWListener, port: UInt16) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.isStopped = false
                self.v4Listener = v4
                self.v6Listener = v6
                self.setState(.listening(port: port), boundPort: port)
                continuation.resume()
            }
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = false
        func tryConsume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if consumed { return false }
            consumed = true
            return true
        }
    }

    /// Whether nothing else is bound to `host:port`, probed with a throwaway socket before the
    /// real `NWListener` binds (D11: a port-squatter must surface as "port in use").
    ///
    /// The probe sets `SO_REUSEADDR`, as `allowLocalEndpointReuse` does for the listener itself.
    /// Without it, a connection this server answered and closed first — its end in TIME_WAIT
    /// for 2×MSL — read as "in use" and refused the immediate re-bind after `stop()`. With it, the
    /// probe catches a socket bound to the same loopback ADDRESS only: next to a wildcard
    /// listener (`0.0.0.0:P`, or a dual-stack `[::]:P`) a `SO_REUSEADDR` bind of `127.0.0.1:P`
    /// succeeds (measured 2026-11-07). A wildcard squatter still surfaces as "port in use" because
    /// the `NWListener`'s own bind then fails — `testAWildcardSquatterOnThePortStillSurfacesPortInUse`.
    private static func isLoopbackPortAvailable(host: NWEndpoint.Host, port: UInt16) -> Bool {
        guard port > 0 else { return true }
        var reuseAddress: Int32 = 1
        if case .ipv4 = host {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { return false }
            defer { Darwin.close(fd) }
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return res == 0
        }
        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))
        var v6Only: Int32 = 1
        _ = Darwin.setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return res == 0
    }

    private func startSingleListener(host: NWEndpoint.Host, port: UInt16) async throws -> (NWListener, UInt16) {
        try await withCheckedThrowingContinuation { continuation in
            // Strong for the start itself, which resumes the continuation whatever happens; the
            // listener's handlers below hold `self` weakly.
            queue.async { [self] in
                if port > 0, !Self.isLoopbackPortAvailable(host: host, port: port) {
                    continuation.resume(throwing: HostedMCPListenerError.portInUse(port))
                    return
                }
                let tcpOptions = NWProtocolTCP.Options()
                tcpOptions.noDelay = true
                let params = NWParameters(tls: nil, tcp: tcpOptions)
                params.allowLocalEndpointReuse = true
                params.requiredInterfaceType = .loopback
                let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
                params.requiredLocalEndpoint = .hostPort(host: host, port: endpointPort)

                guard let listener = try? NWListener(using: params) else {
                    continuation.resume(throwing: HostedMCPListenerError.portInUse(port))
                    return
                }

                listener.newConnectionHandler = { [weak self] nwConn in
                    self?.handleIncomingConnection(nwConn)
                }

                let once = OnceFlag()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let actualPort = listener.port?.rawValue ?? port
                        if once.tryConsume() {
                            continuation.resume(returning: (listener, actualPort))
                        }
                    case .failed, .waiting, .cancelled:
                        if once.tryConsume() {
                            listener.cancel()
                            continuation.resume(throwing: HostedMCPListenerError.portInUse(port))
                        }
                    default:
                        break
                    }
                }

                listener.start(queue: self.queue)
            }
        }
    }

    private func cancelListenerAndWait(_ listener: NWListener) async {
        await withCheckedContinuation { continuation in
            queue.async {
                let once = OnceFlag()
                let finish: @Sendable () -> Void = {
                    if once.tryConsume() {
                        continuation.resume()
                    }
                }
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state {
                        finish()
                    }
                }
                listener.cancel()
                self.queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                    finish()
                }
            }
        }
    }

    // MARK: - Connection Handling on `queue`

    private func handleIncomingConnection(_ nwConn: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopped, let currentPort = boundPort else {
            nwConn.forceCancel()
            return
        }

        if connections.count >= configuration.maxOpenConnections {
            if let victimID = oldestHeaderPhaseConnectionID() {
                evictConnection(id: victimID)
            } else {
                rejectBusyConnection(nwConn)
                return
            }
        }

        let connID = UUID()
        let parserConfig = HostedMCPHTTPRequestParser.Configuration(
            headDeadline: configuration.headDeadline,
            bodyDeadline: configuration.bodyDeadline
        )

        let driver = HostedMCPHTTPConnectionDriver(
            queue: queue,
            serverPort: currentPort,
            configuration: parserConfig,
            verifyToken: { [weak self] token in
                guard let self else { return .invalidToken }
                let verification = self.agentStore.verifyBearerToken(token)
                if case .authenticated = verification {
                    self.frameLog.registerSensitiveToken(token)
                }
                return verification
            },
            sendBytes: { data in
                nwConn.send(content: data, completion: .contentProcessed { _ in })
            },
            closeConnection: { [weak self] in
                self?.closeAndRemoveConnection(id: connID, graceful: true)
            },
            onRejection: { [weak self] rejection in
                self?.recordGuardRejection(rejection)
            },
            onParseError: { [weak self] parseError in
                self?.recordParseError(parseError)
            },
            onRequest: { [weak self] route, request, respond in
                self?.handleAcceptedRequest(connID: connID, route: route, request: request, respond: respond)
            }
        )

        nextConnectionSequence &+= 1
        let active = ActiveConnection(
            id: connID,
            acceptedSequence: nextConnectionSequence,
            nwConnection: nwConn,
            driver: driver
        )
        connections[connID] = active

        nwConn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.closeAndRemoveConnection(id: connID, graceful: false)
            default:
                break
            }
        }

        driver.start()
        nwConn.start(queue: queue)
        receiveNextChunk(connID: connID, nwConn: nwConn, driver: driver)
    }

    private func receiveNextChunk(
        connID: UUID,
        nwConn: NWConnection,
        driver: HostedMCPHTTPConnectionDriver
    ) {
        nwConn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            guard self.connections[connID] != nil else { return }

            if let content, !content.isEmpty {
                driver.receive(content)
            }

            if error != nil || (isComplete && (driver.isReadingHead || content == nil || content?.isEmpty == true)) {
                self.closeAndRemoveConnection(id: connID, graceful: false)
                return
            }

            if !isComplete, self.connections[connID] != nil {
                self.receiveNextChunk(connID: connID, nwConn: nwConn, driver: driver)
            }
        }
    }

    private func oldestHeaderPhaseConnectionID() -> UUID? {
        dispatchPrecondition(condition: .onQueue(queue))
        var oldestID: UUID?
        var oldestSeq = UInt64.max
        for (id, conn) in connections where conn.driver.isReadingHead {
            if conn.acceptedSequence < oldestSeq {
                oldestSeq = conn.acceptedSequence
                oldestID = id
            }
        }
        return oldestID
    }

    private func evictConnection(id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let active = connections.removeValue(forKey: id) else { return }
        active.dispatchTask?.cancel()
        active.driver.cancel()
        active.nwConnection.forceCancel()
    }

    private func closeAndRemoveConnection(id: UUID, graceful: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let active = connections.removeValue(forKey: id) else { return }
        let nwConn = active.nwConnection
        if graceful {
            pendingGracefulCloseCount += 1
            let once = OnceFlag()
            let finishClose: @Sendable () -> Void = { [weak self] in
                guard once.tryConsume() else { return }
                nwConn.cancel()
                guard let self else { return }
                self.queue.async {
                    self.pendingGracefulCloseCount = max(0, self.pendingGracefulCloseCount - 1)
                }
            }
            nwConn.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    finishClose()
                }
            )
            queue.asyncAfter(deadline: .now() + .milliseconds(200)) {
                finishClose()
            }
        } else {
            active.dispatchTask?.cancel()
            nwConn.cancel()
        }
    }

    private func rejectBusyConnection(_ nwConn: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        let response = HostedMCPHTTPResponse.json(
            statusCode: 503,
            headers: [("Retry-After", "\(HostedMCPConstants.busyRetryAfterSeconds)")],
            body: Data(#"{"error":"server_busy","message":"Too many active connections."}"#.utf8)
        )
        frameLog.record(
            agent: nil,
            method: "CONNECT",
            tool: nil,
            statusCode: 503,
            durationMs: 0,
            refusalReason: "connection_cap_exceeded",
            agentTextVersion: dispatcher.agentTextVersion
        )
        nwConn.start(queue: queue)
        nwConn.send(
            content: response.serialized(),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in nwConn.cancel() }
        )
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { nwConn.cancel() }
    }

    func cancelConnections(forAgent agentID: UUID) {
        handleAgentInvalidated(agentID)
    }

    private func handleAgentInvalidated(_ agentID: UUID) {
        dispatcher.cancelAllRequests(forAgent: agentID)
        queue.async {
            for (id, conn) in self.connections where conn.driver.authenticatedAgentID == agentID {
                self.evictConnection(id: id)
            }
        }
    }

    // MARK: - Route Dispatching

    private func handleAcceptedRequest(
        connID: UUID,
        route: HostedMCPRoute,
        request: HostedMCPHTTPRequest,
        respond: @escaping @Sendable (HostedMCPHTTPResponse) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let startTime = Date()

        switch route {
        case .identify(let shortID, let nonceHex):
            let result = agentStore.identify(shortID: shortID, nonceHex: nonceHex)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let (response, refusalReason): (HostedMCPHTTPResponse, String?)
            switch result {
            case .success(let payload):
                let body = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
                response = .json(statusCode: 200, body: body)
                refusalReason = nil
            case .invalidNonce:
                response = .empty(statusCode: 400)
                refusalReason = "invalid_nonce"
            case .agentNotFound:
                response = .empty(statusCode: 404)
                refusalReason = "agent_not_found"
            case .storageFailure(let detail):
                response = .empty(
                    statusCode: 503,
                    headers: [("Retry-After", "\(HostedMCPConstants.busyRetryAfterSeconds)")]
                )
                refusalReason = "keychain_unavailable:\(detail)"
            }
            frameLog.record(
                timestamp: startTime,
                agent: nil,
                method: "GET /identify",
                tool: nil,
                statusCode: response.statusCode,
                durationMs: durationMs,
                refusalReason: refusalReason,
                agentTextVersion: dispatcher.agentTextVersion
            )
            respond(response)

        case .mcp(let agent):
            if isFolderTransitionGateActive() {
                let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
                frameLog.record(
                    timestamp: startTime,
                    agent: agent,
                    method: "POST /mcp",
                    tool: nil,
                    statusCode: 503,
                    durationMs: durationMs,
                    refusalReason: "folder_transition_in_progress",
                    agentTextVersion: dispatcher.agentTextVersion
                )
                respond(.json(
                    statusCode: 503,
                    headers: [("Retry-After", "\(HostedMCPConstants.folderTransitionRetryAfterSeconds)")],
                    body: Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32018,"message":"folder_transition_in_progress"}}"#.utf8)
                ))
                return
            }

            let (rpcMethod, toolName) = Self.extractMethodAndTool(from: request.body)
            let isWaitRequest = (rpcMethod == "tools/call" && toolName == ExternalAutovisorToolNames.waitForEvents)
            let maxConcurrentWaits = max(1, configuration.maxOpenConnections - configuration.reservedNonWaitConnections)

            if isWaitRequest, activeWaitCount >= maxConcurrentWaits {
                let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
                frameLog.record(
                    timestamp: startTime,
                    agent: agent,
                    method: rpcMethod,
                    tool: toolName,
                    statusCode: 503,
                    durationMs: durationMs,
                    refusalReason: "wait_slots_exhausted",
                    agentTextVersion: dispatcher.agentTextVersion
                )
                respond(.json(
                    statusCode: 503,
                    headers: [("Retry-After", "\(HostedMCPConstants.busyRetryAfterSeconds)")],
                    body: Data(#"{"error":"wait_slots_exhausted","message":"All wait_for_events slots are currently in use."}"#.utf8)
                ))
                return
            }
            let requestSequence = beginInFlightRequest(holdingWaitSlot: isWaitRequest)

            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.queue.async {
                        self.endInFlightRequest(requestSequence)
                    }
                }

                let outcome = await self.dispatcher.dispatch(
                    request: request,
                    agent: agent,
                    onSSEHead: { [weak self] headBytes in
                        guard let self else { return }
                        self.queue.async {
                            self.connections[connID]?.driver.sendStreamChunk(headBytes)
                        }
                    },
                    onSSEChunk: { [weak self] chunk in
                        guard let self else { return }
                        self.queue.async {
                            self.connections[connID]?.driver.sendStreamChunk(chunk)
                        }
                    }
                )

                let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
                switch outcome {
                case .httpResponse(let response):
                    self.frameLog.record(
                        timestamp: startTime,
                        agent: agent,
                        method: rpcMethod,
                        tool: toolName,
                        statusCode: response.statusCode,
                        durationMs: durationMs,
                        refusalReason: response.statusCode >= 400 ? "http_\(response.statusCode)" : nil,
                        agentTextVersion: self.dispatcher.agentTextVersion
                    )
                    respond(response)
                case .sse:
                    self.frameLog.record(
                        timestamp: startTime,
                        agent: agent,
                        method: rpcMethod,
                        tool: toolName,
                        statusCode: 200,
                        durationMs: durationMs,
                        refusalReason: nil,
                        agentTextVersion: self.dispatcher.agentTextVersion
                    )
                    self.queue.async {
                        self.connections[connID]?.driver.finishStream()
                    }
                }
            }
            connections[connID]?.dispatchTask = task
        }
    }

    private func recordGuardRejection(_ rejection: HostedMCPGuardRejection) {
        let reason = rejection.rejectedOrigin.map { "\(rejection.reason):\($0)" } ?? rejection.reason
        frameLog.record(
            agent: nil,
            method: "HTTP",
            tool: nil,
            statusCode: rejection.response.statusCode,
            durationMs: 0,
            refusalReason: reason,
            agentTextVersion: dispatcher.agentTextVersion
        )
    }

    private func recordParseError(_ error: HostedMCPHTTPError) {
        frameLog.record(
            agent: nil,
            method: "HTTP",
            tool: nil,
            statusCode: error.statusCode,
            durationMs: 0,
            refusalReason: "parse_error",
            agentTextVersion: dispatcher.agentTextVersion
        )
    }

    private static func extractMethodAndTool(from body: Data) -> (method: String, tool: String?) {
        guard !body.isEmpty,
              let json = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .object(let root) = json,
              case .string(let method) = root["method"]
        else {
            return ("POST /mcp", nil)
        }
        if method == "tools/call",
           case .object(let params) = root["params"],
           case .string(let toolName) = params["name"] {
            return (method, toolName)
        }
        return (method, nil)
    }
}
