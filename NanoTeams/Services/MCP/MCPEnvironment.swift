import Foundation

/// Everything the MCP manager needs from the outside world, in one injectable value.
///
/// The seam exists for the same reason `computerUse: .system` does: a test or a preview that
/// forgets to pass it must get a process that CANNOT open a socket or touch the Keychain,
/// rather than one that quietly does. The `.live` VALUE is handed to a manager in exactly one
/// place — the app's composition root, `NanoTeamsApp`, which gives it to the production
/// `NTMSOrchestrator`. Everything else takes `.inert` or builds its own: the headless runner
/// (`HeadlessMCPSetup`) borrows only `.live`'s transport factory, with storage of its own that
/// holds nothing and no sweep, and `MCPEnvironmentTests` reads `.live`'s pieces without handing
/// it on. That narrower claim is the one the launch sweep's safety rests on.
nonisolated struct MCPEnvironment: Sendable {

    /// Builds the transport for one server. A closure rather than a protocol because the two
    /// implementations differ only in what they construct.
    let makeTransport: @Sendable (MCPHTTPConfig, any MCPAuthorizer, MCPTimeouts) -> any MCPTransport
    let secretStorage: any SecureTokenStorage
    /// Where `trust.json` lives. Separate from the catalogue store's directory only so a test
    /// can point both at a temp folder.
    let trustDirectory: URL
    /// Whether a per-server frame log is written. Off for previews and tests, where the log
    /// would be written into whatever directory the harness happened to pick.
    let writesRPCLog: Bool
    /// When a connection that failed dials again. Injected so a test can watch the backoff and
    /// the crash-loop window work in milliseconds rather than in the thirty-second steps the
    /// app waits.
    var reconnectPolicy: MCPReconnectPolicy = .standard
    /// What every connection's reconnect schedule and its clients' request timers run on.
    /// Injected for the same reason as the policy: a test orders the attempts itself
    /// (`ManualMCPClock`) instead of reading gaps off the wall clock, which on a loaded machine
    /// says as much about the machine as about the rule.
    var clock: any MCPClock = MCPSystemClock()
    /// Whether the manager deletes, once, every MCP secret no configured server reads
    /// (`MCPServerManager`'s launch sweep). ON for `.live` and nowhere else: the opt-in rides the
    /// one value only the app's composition root hands to a manager, so a test, a preview or a
    /// headless run — which build their own environment or take `.inert` — can never delete
    /// from a Keychain, above all the real one.
    var sweepsOrphanedSecrets = false

    static let live = MCPEnvironment(
        makeTransport: { config, authorizer, timeouts in
            StreamableHTTPTransport(
                config: config,
                authorizer: authorizer,
                session: MCPURLSession(timeouts: timeouts),
                timeouts: timeouts)
        },
        secretStorage: KeychainSecureTokenStorage(service: MCPConstants.keychainService),
        trustDirectory: MCPServerCatalogueStore.defaultDirectory,
        writesRPCLog: true,
        sweepsOrphanedSecrets: true)

    /// A process that cannot reach a server or a credential.
    ///
    /// Belt and braces rather than the only defence: a test orchestrator is also given an
    /// empty catalogue in a temp directory, so there is nothing to connect to in the first
    /// place. This is what makes a test that DOES add a server still incapable of opening a
    /// socket.
    static let inert = MCPEnvironment(
        makeTransport: { _, _, _ in NeverConnectingTransport() },
        secretStorage: EmptySecureTokenStorage(),
        trustDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("nanoteams-inert-mcp", isDirectory: true),
        writesRPCLog: false)
}

/// When a connection that failed dials again.
///
/// A value, not three constants read in place, because a test has to be able to shorten it: the
/// rule it carries — back off along a table, and slow to the table's last step, never to a
/// stop, once failures bunch up — only shows over several attempts.
nonisolated struct MCPReconnectPolicy: Sendable, Hashable {
    /// Delays before each retry, in order; the last one repeats.
    let backoff: [TimeInterval]
    /// This many failures inside `crashLoopWindow` is a server failing at once, every time.
    let crashLoopFailureCount: Int
    let crashLoopWindow: TimeInterval

    init(backoff: [TimeInterval], crashLoopFailureCount: Int, crashLoopWindow: TimeInterval) {
        self.backoff = backoff.isEmpty ? [0] : backoff
        self.crashLoopFailureCount = max(1, crashLoopFailureCount)
        self.crashLoopWindow = crashLoopWindow
    }

    static let standard = MCPReconnectPolicy(
        backoff: MCPConstants.reconnectBackoff,
        crashLoopFailureCount: MCPConstants.crashLoopFailureCount,
        crashLoopWindow: MCPConstants.crashLoopWindow)

    /// The delay before retry number `index` (from 0), the last step repeating.
    func delay(afterFailure index: Int) -> TimeInterval {
        backoff[min(max(0, index), backoff.count - 1)]
    }

    /// The table's last step — where a crash-looping server settles.
    var longestDelay: TimeInterval { backoff[backoff.count - 1] }
}

/// A transport that refuses at the first step.
///
/// Production code, not `#if DEBUG`: it is what `MCPEnvironment.inert` hands out, and the
/// inert environment is named by `PreviewStore` as well as by tests. A `#if DEBUG` type here
/// would break the release build of the previews.
nonisolated final class NeverConnectingTransport: MCPTransport, @unchecked Sendable {

    init() {}

    func connect() async throws {
        throw MCPTransportError.endpointRefused(
            "This process does not connect to MCP servers. Run the app to use them.")
    }

    func adopt(era: MCPProtocolEra, protocolVersion: String) async {}

    @discardableResult
    func send(_ frame: MCPOutgoingFrame, hints: MCPSendHints) async throws -> MCPSendOutcome {
        throw MCPTransportError.notConnected
    }

    func events() async -> AsyncStream<MCPIncomingEvent> {
        AsyncStream { $0.finish() }
    }

    func cancel(requestID: JSONRPCID) async {}

    func close(budget: TimeInterval) async {}
}

/// Secret storage with nothing in it and nowhere to put anything.
///
/// Distinct from `InMemorySecureTokenStorage`, which REMEMBERS what it was given: a preview
/// or a test that accidentally saves a token here loses it immediately, which is the point.
/// Production code for the same reason `NeverConnectingTransport` is.
nonisolated struct EmptySecureTokenStorage: SecureTokenStorage {

    init() {}

    func setToken(_ token: String?, forKey key: String) throws {}

    func loadToken(forKey key: String) throws -> String? { nil }

    func accountNames(withPrefix prefix: String) throws -> [String] { [] }
}
