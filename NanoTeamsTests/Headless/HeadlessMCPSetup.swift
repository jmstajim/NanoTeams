import Foundation
@testable import NanoTeams

/// One MCP server a headless run may talk to.
///
/// **No secrets.** A headless config is a plain file, usually one a harness generates, so this
/// shape carries only non-secret headers and no token field at all. A run that needs a
/// credential is a run that belongs in the app, where the Keychain is.
struct HeadlessMCPServer: Codable, Equatable {
    /// `^[a-z0-9][a-z0-9_]{0,31}$` — the prefix every tool of this server wears.
    var slug: String
    var displayName: String?
    var url: String
    /// Non-secret request headers: a version pin, a tenant id.
    var headers: [String: String]?
    /// Default `.manual`, like the app. A measurement that wants tools to actually RUN
    /// unattended says `semiAutomatic` and marks the server trusted, or `auto` to route
    /// non-fast-path calls through `MCPJudgeService`.
    var approvalMode: MCPApprovalMode?
    var judgeStrictness: MCPJudgeStrictness?
    var isTrusted: Bool?
    /// The server's OWN names for the tools this run may use. Anything else it publishes stays
    /// unreviewed and reaches no prompt — which is the property a headless measurement of the
    /// approval path is actually measuring.
    var approvedTools: [String]?
    /// Whether to pin `approvedTools` at whatever hash the server sends on this run. Without
    /// it nothing is approved and every tool is withheld — useful as the control arm.
    var trustOnFirstUse: Bool?
}

/// Turning the config's MCP block into the two seams the orchestrator takes, and applying the
/// trust-on-first-use approvals once the servers answer.
///
/// Separate from `HeadlessRunner` so both halves are testable without a server: the setup is
/// pure, and the approval step takes a manager rather than reaching for one.
enum HeadlessMCPSetup {

    struct Prepared {
        let environment: MCPEnvironment
        let catalogueStore: MCPServerCatalogueStore
        let servers: [HeadlessMCPServer]
        /// Where trust.json and servers.json were written. Kept so a test can read them.
        let directory: URL
    }

    /// `nil` when the config names no server — which leaves the orchestrator on `.inert` and
    /// a run byte-identical to one from before this feature existed.
    static func prepare(config: HeadlessConfig, directory: URL? = nil) -> Prepared? {
        let servers = config.mcpServers ?? []
        guard !servers.isEmpty else { return nil }

        let root = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("nanoteams-headless-mcp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = MCPServerCatalogueStore(directory: root)
        for server in servers {
            guard let config = makeConfig(server) else { continue }
            try? store.upsert(config)
        }

        return Prepared(
            environment: MCPEnvironment(
                // A REAL transport: a headless run is supposed to reach the server it names,
                // exactly as a headless LLM run reaches its model server.
                makeTransport: MCPEnvironment.live.makeTransport,
                // …and no Keychain: this config carries no credential, so a store that can
                // read one would only be able to pick up a developer's.
                secretStorage: EmptySecureTokenStorage(),
                trustDirectory: root,
                writesRPCLog: true),
            catalogueStore: store,
            servers: servers,
            directory: root)
    }

    /// `nil` when the row cannot name a server — a malformed slug is a config error, and
    /// skipping the row is louder than inventing a slug for it (the run then finds no tools).
    static func makeConfig(_ server: HeadlessMCPServer) -> MCPServerConfig? {
        guard let slug = MCPServerSlug(server.slug) else { return nil }
        return MCPServerConfig(
            slug: slug,
            displayName: server.displayName ?? server.slug,
            transport: .http(MCPHTTPConfig(
                urlString: server.url,
                headers: server.headers ?? [:],
                authorization: .none)),
            isEnabled: true,
            isTrusted: server.isTrusted ?? false,
            approvalMode: server.approvalMode ?? .manual,
            judgeStrictness: server.judgeStrictness ?? .standard)
    }

    /// Pins the named tools once their catalogue has arrived — each at ITS OWN hash, with its
    /// own text: the descriptor the server sent this run is the thing approved, exactly as a
    /// person approves the text on the review sheet.
    ///
    /// Returns what it approved, per slug and in the config's order, so the runner can PRINT
    /// it: a measurement whose toolset is silently empty reads exactly like one whose model
    /// ignored the tools.
    @MainActor
    static func approveConfiguredTools(
        manager: MCPServerManager, servers: [HeadlessMCPServer]
    ) -> [String: [String]] {
        let connectionsBySlug = Dictionary(
            manager.connections.map { ($0.config.slug.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        var approved: [String: [String]] = [:]
        for server in servers where server.trustOnFirstUse == true {
            guard let connection = connectionsBySlug[server.slug] else { continue }
            let published = Dictionary(
                connection.descriptors.map { ($0.originalName, $0) }, uniquingKeysWith: { first, _ in first })
            var names: [String] = []
            for tool in server.approvedTools ?? [] {
                guard let descriptor = published[tool] else { continue }
                if (try? connection.approve(reviewed: descriptor)) != nil { names.append(tool) }
            }
            approved[server.slug] = names
        }
        return approved
    }

    /// Grants every valid configured server's namespace (`mcp__<slug>`) to each non-Supervisor
    /// role of `team` that does not already hold it, so a headless run on a freshly opened work
    /// folder (whose bundled template roles list only built-in tools) can actually resolve the
    /// servers' approved tools (`MCPToolsSnapshot.granted(by:)`). The Supervisor is the human
    /// user and never executes model steps, so it is excluded. A server with
    /// `trustOnFirstUse != true` still ships zero tools because `approveConfiguredTools` leaves
    /// its pins unreviewed.
    static func grantConfiguredServers(to team: inout Team, servers: [HeadlessMCPServer]) {
        let grants = servers.compactMap { MCPServerSlug($0.slug).map { MCPToolNaming.serverGrant(slug: $0.rawValue) } }
        guard !grants.isEmpty else { return }
        for idx in team.roles.indices where !team.roles[idx].isSupervisor {
            for grant in grants where !team.roles[idx].toolIDs.contains(grant) {
                team.roles[idx].toolIDs.append(grant)
            }
        }
    }

    /// Waits until every configured server has either connected or given up, so the approvals
    /// below are applied to a catalogue that has actually arrived.
    ///
    /// Polling rather than a notification because the manager exposes no signal, and a
    /// headless run has a budget it is allowed to spend: the alternative — approving against
    /// an empty catalogue — silently produces a run with no tools.
    @MainActor
    static func waitForCatalogues(
        manager: MCPServerManager, budget: TimeInterval, clock: @Sendable () -> Date = { Date() }
    ) async {
        let deadline = clock().addingTimeInterval(budget)
        while clock() < deadline {
            let settled = manager.connections.allSatisfy { connection in
                switch connection.status {
                case .connecting: false
                case .connected, .disabled, .failed, .needsAuth, .unsupportedTransport, .incompatible: true
                }
            }
            if settled, !manager.connections.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
