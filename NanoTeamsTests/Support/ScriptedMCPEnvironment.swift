import Foundation

@testable import NanoTeams

/// An `MCPEnvironment` whose transports are scripted, keyed by the URL a server is configured
/// with.
///
/// The manager's rules — which servers start, what a failure does to the backoff, when the
/// snapshot moves — are all about lifecycle, not about bytes. Scripting at the transport seam
/// is what lets a test say "this server answers, that one refuses" without a socket, a port or
/// a wait.
final class ScriptedMCPEnvironment: @unchecked Sendable {

    private let lock = NSLock()
    private var transports: [String: ScriptedTransport] = [:]
    private var factories: [String: @Sendable () -> ScriptedTransport] = [:]
    private var builtTransports: [String: [ScriptedTransport]] = [:]
    private var built: [String] = []
    private var policy: MCPReconnectPolicy = .standard
    private var environmentClock: any MCPClock = MCPSystemClock()

    let secretStorage = InMemorySecureTokenStorage()
    let trustDirectory: URL

    init(trustDirectory: URL? = nil) {
        self.trustDirectory = trustDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-scripted-mcp-\(UUID().uuidString)", isDirectory: true)
    }

    /// Registers the transport a given URL answers with. A URL with none gets one that
    /// refuses to connect, which is what an unscripted server should look like.
    func register(url: String, transport: ScriptedTransport) {
        lock.withLock { transports[url] = transport }
    }

    /// A FRESH transport for every connect attempt at `url` — what a real server hands a
    /// client that reconnects, and the only way a test can ask which of the attempts' transports
    /// are still open (`transports(builtFor:)`). Takes precedence over `register(url:transport:)`.
    func register(url: String, factory: @escaping @Sendable () -> ScriptedTransport) {
        lock.withLock { factories[url] = factory }
    }

    /// Every transport a factory built for `url`, in the order the attempts asked for them.
    func transports(builtFor url: String) -> [ScriptedTransport] {
        lock.withLock { builtTransports[url] ?? [] }
    }

    /// The reconnect policy every connection built from `environment` retries under. A test
    /// that wants to watch the backoff and the crash-loop window work without waiting real
    /// seconds shortens it here.
    var reconnectPolicy: MCPReconnectPolicy {
        get { lock.withLock { policy } }
        set { lock.withLock { policy = newValue } }
    }

    /// The clock every connection built from `environment` schedules its retries on, and its
    /// clients time their requests on. A test that asserts WHEN the loop dials again hands it a
    /// `ManualMCPClock` and moves the time itself, instead of reading gaps off the wall clock.
    var clock: any MCPClock {
        get { lock.withLock { environmentClock } }
        set { lock.withLock { environmentClock = newValue } }
    }

    /// A transport that answers a modern handshake and lists `toolNames`.
    static func modernTransport(toolNames: [String]) async -> ScriptedTransport {
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.result(.object([
            "protocolVersion": .string(MCPConstants.modernProtocolVersion),
            "serverInfo": .object(["name": .string("scripted")]),
        ]))])
        transport.script(MCPWire.toolsListMethod, [.result(.object([
            "tools": .array(toolNames.map { name in
                .object([
                    "name": .string(name),
                    "description": .string("Does \(name)."),
                    "inputSchema": .object(["type": .string("object")]),
                ])
            }),
        ]))])
        return transport
    }

    /// A transport whose connect fails the way a switched-off server does.
    static func refusingTransport(_ error: MCPTransportError = .network("the connection was refused"))
        async -> ScriptedTransport {
        let transport = ScriptedTransport()
        transport.setConnectError(error)
        return transport
    }

    /// Which URLs the manager actually asked for a transport, in order — how a test sees a
    /// disabled server never being started.
    var builtURLs: [String] { lock.withLock { built } }

    var environment: MCPEnvironment {
        MCPEnvironment(
            makeTransport: { [self] config, _, _ in
                let url = config.urlString
                let factory: (@Sendable () -> ScriptedTransport)? = lock.withLock {
                    built.append(url)
                    return factories[url]
                }
                if let factory {
                    let fresh = factory()
                    lock.withLock { builtTransports[url, default: []].append(fresh) }
                    return fresh
                }
                return lock.withLock { transports[url] } ?? NeverConnectingTransport()
            },
            secretStorage: secretStorage,
            trustDirectory: trustDirectory,
            writesRPCLog: false,
            reconnectPolicy: reconnectPolicy,
            clock: clock)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: trustDirectory)
    }
}
