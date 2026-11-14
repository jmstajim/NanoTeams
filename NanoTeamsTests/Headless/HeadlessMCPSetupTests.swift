import XCTest
@testable import NanoTeams

/// The headless MCP block. Two properties matter more than the rest: a config that says
/// nothing about MCP must leave the run exactly as it was before the feature existed, and a
/// config that DOES name a server must carry no credential — it is a file on disk.
final class HeadlessMCPSetupTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-mcp-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    private func config(servers: [HeadlessMCPServer]?) -> HeadlessConfig {
        var json: [String: Any] = [
            "projectPath": "/tmp", "taskTitle": "t", "supervisorTask": "s",
        ]
        if let servers {
            let data = try! JSONEncoder().encode(servers)
            json["mcpServers"] = try! JSONSerialization.jsonObject(with: data)
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(HeadlessConfig.self, from: data)
    }

    private func server(
        slug: String = "folio",
        url: String = "http://127.0.0.1:3845/mcp",
        approved: [String]? = ["get_screenshot"],
        tofu: Bool? = true
    ) -> HeadlessMCPServer {
        HeadlessMCPServer(
            slug: slug, displayName: nil, url: url, headers: nil,
            approvalMode: .semiAutomatic, isTrusted: true,
            approvedTools: approved, trustOnFirstUse: tofu)
    }

    // MARK: - Saying nothing

    /// The property the whole default rests on: no MCP block ⇒ no environment ⇒ the
    /// orchestrator stays on `.inert`, which cannot open a socket.
    func testAConfigWithNoMCPBlockPreparesNothing() {
        XCTAssertNil(HeadlessMCPSetup.prepare(config: config(servers: nil), directory: directory))
        XCTAssertNil(HeadlessMCPSetup.prepare(config: config(servers: []), directory: directory))
    }

    // MARK: - Round-tripping the config

    func testTheBlockRoundTripsThroughJSON() throws {
        let decoded = config(servers: [server()])

        XCTAssertEqual(decoded.mcpServers?.count, 1)
        XCTAssertEqual(decoded.mcpServers?.first?.slug, "folio")
        XCTAssertEqual(decoded.mcpServers?.first?.approvalMode, .semiAutomatic)

        let reencoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(HeadlessConfig.self, from: reencoded)
        XCTAssertEqual(again.mcpServers, decoded.mcpServers)
    }

    /// Structural, not a wish: the shape has no token field, so a headless config cannot
    /// carry one however it is written.
    func testTheServerShapeHasNoCredentialField() throws {
        let encoded = try JSONEncoder().encode(server())
        let keys = Set((try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]).keys)

        XCTAssertTrue(keys.isDisjoint(with: ["token", "bearer", "secret", "authorization", "password"]),
                      "\(keys)")
    }

    // MARK: - Preparing

    func testEachServerBecomesAnEnabledCatalogueEntry() throws {
        let prepared = try XCTUnwrap(
            HeadlessMCPSetup.prepare(config: config(servers: [server()]), directory: directory))

        let stored = try XCTUnwrap(prepared.catalogueStore.servers.first)
        XCTAssertEqual(stored.slug.rawValue, "folio")
        XCTAssertTrue(stored.isEnabled, "a headless run has no UI to switch it on")
        XCTAssertEqual(stored.approvalMode, .semiAutomatic)
        XCTAssertTrue(stored.isTrusted)
    }

    /// The environment reaches a real socket — a headless run is supposed to talk to the
    /// server it names — but never a Keychain, because this config has no credential to put
    /// there and a store that could read one would only find a developer's.
    ///
    /// Half of what the launch sweep's safety rests on (`MCPEnvironment`): the headless runner
    /// borrows ONLY `.live`'s transport factory — its storage is its own and empty, and it does
    /// not sweep — so the `.live` value itself reaches a manager only through the app's
    /// composition root.
    func testTheEnvironmentCanReachASocketButNotACredential() throws {
        let prepared = try XCTUnwrap(
            HeadlessMCPSetup.prepare(config: config(servers: [server()]), directory: directory))

        // Checked before anything is asked of the storage, so a regression that handed the
        // runner a Keychain fails here instead of reading the real one.
        guard prepared.environment.secretStorage is EmptySecureTokenStorage else {
            return XCTFail("a headless run holds storage that can keep a secret: "
                + "\(type(of: prepared.environment.secretStorage))")
        }
        XCTAssertNil(try prepared.environment.secretStorage.loadToken(forKey: "anything"))
        XCTAssertEqual(prepared.environment.trustDirectory, directory)
        XCTAssertTrue(prepared.environment.writesRPCLog, "the run's audit trail is the point")
        XCTAssertFalse(prepared.environment.sweepsOrphanedSecrets, "a headless run never deletes from a Keychain")
    }

    /// A malformed slug names no server, so the row is skipped and the run finds no tools —
    /// louder than inventing a slug and silently measuring the wrong thing.
    func testAMalformedSlugIsSkippedRatherThanFolded() {
        XCTAssertNil(HeadlessMCPSetup.makeConfig(server(slug: "Folio Desktop")))

        let prepared = HeadlessMCPSetup.prepare(
            config: config(servers: [server(slug: "NOPE")]), directory: directory)
        XCTAssertEqual(prepared?.catalogueStore.servers.count, 0)
    }

    func testTheDisplayNameFallsBackToTheSlug() throws {
        let config = try XCTUnwrap(HeadlessMCPSetup.makeConfig(server()))

        XCTAssertEqual(config.displayName, "folio")
    }

    func testHeadersRideAndAuthenticationIsAlwaysNone() throws {
        var row = server()
        row.headers = ["X-Tenant": "acme"]
        let config = try XCTUnwrap(HeadlessMCPSetup.makeConfig(row))

        XCTAssertEqual(config.transport.http.headers, ["X-Tenant": "acme"])
        XCTAssertEqual(config.transport.http.authorization, .none)
        XCTAssertTrue(config.transport.http.secretHeaderNames.isEmpty)
    }

    // MARK: - Approving

    /// Without `trustOnFirstUse` nothing is pinned, so every tool stays unreviewed and
    /// reaches no prompt — the control arm of a measurement about the approval path.
    @MainActor
    func testWithoutTrustOnFirstUseNothingIsApproved() async throws {
        let prepared = try XCTUnwrap(HeadlessMCPSetup.prepare(
            config: config(servers: [server(tofu: false)]), directory: directory))
        let manager = MCPServerManager(
            catalogueStore: prepared.catalogueStore, environment: .inert)

        let approved = HeadlessMCPSetup.approveConfiguredTools(
            manager: manager, servers: prepared.servers)

        XCTAssertTrue(approved.isEmpty)
    }

    /// A server that never answers publishes nothing, so there is nothing to pin — and the
    /// approval step must report that rather than claim a success.
    @MainActor
    func testAToolTheServerNeverPublishedIsNotApproved() async throws {
        let prepared = try XCTUnwrap(HeadlessMCPSetup.prepare(
            config: config(servers: [server()]), directory: directory))
        let manager = MCPServerManager(
            catalogueStore: prepared.catalogueStore, environment: .inert)
        await manager.reload()

        let approved = HeadlessMCPSetup.approveConfiguredTools(
            manager: manager, servers: prepared.servers)

        XCTAssertEqual(approved["folio"], [])
        await manager.shutdown(budget: 0)
    }

    /// The wait ends on its budget rather than spinning: an inert transport never leaves
    /// `.connecting`, which is exactly the shape of a server that is simply not there.
    @MainActor
    func testTheWaitGivesUpOnItsBudget() async throws {
        let prepared = try XCTUnwrap(HeadlessMCPSetup.prepare(
            config: config(servers: [server()]), directory: directory))
        let manager = MCPServerManager(
            catalogueStore: prepared.catalogueStore, environment: .inert)
        await manager.reload()

        let started = Date()
        await HeadlessMCPSetup.waitForCatalogues(manager: manager, budget: 0.4)

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        await manager.shutdown(budget: 0)
    }

    /// Trust on first use pins each configured tool at ITS OWN hash, with its own text — the
    /// one the server sent this run — and leaves everything the config did not name new.
    @MainActor
    func testTrustOnFirstUsePinsEachConfiguredToolAtItsOwnHash() async throws {
        let url = "https://tofu.test/mcp"
        let row = server(url: url, approved: ["get_screenshot", "get_metadata", "not_published"])
        let prepared = try XCTUnwrap(HeadlessMCPSetup.prepare(config: config(servers: [row]), directory: directory))
        let scripted = ScriptedMCPEnvironment(trustDirectory: directory)
        scripted.register(url: url, transport: await ScriptedMCPEnvironment.modernTransport(
            toolNames: ["get_metadata", "get_screenshot", "delete_file"]))
        let manager = MCPServerManager(catalogueStore: prepared.catalogueStore, environment: scripted.environment)
        await manager.reload()
        await HeadlessMCPSetup.waitForCatalogues(manager: manager, budget: 3)

        let approved = HeadlessMCPSetup.approveConfiguredTools(manager: manager, servers: prepared.servers)

        XCTAssertEqual(approved["folio"], ["get_screenshot", "get_metadata"],
                       "the config's order, and a name the server never sent is not claimed")
        let connection = try XCTUnwrap(manager.connections.first)
        for descriptor in connection.descriptors where descriptor.originalName != "delete_file" {
            let pin = try XCTUnwrap(MCPTrustStore(directory: directory)
                .pin(serverID: connection.config.id, tool: descriptor.originalName))
            XCTAssertEqual(pin.hash, descriptor.pinHash)
            XCTAssertEqual(pin.approvedCanonicalJSON, MCPPinHasher.canonicalForm(rawTool: descriptor.rawTool))
        }
        XCTAssertEqual(connection.pinState(of: "delete_file"), .new)
        await manager.shutdown(budget: 0)
    }

    // MARK: - Auto mode & judgeStrictness (D-M14)

    func testAutoModeAndJudgeStrictnessRoundTripAndPrepareServerConfig() throws {
        var autoDefault = server()
        autoDefault.approvalMode = .auto
        autoDefault.judgeStrictness = nil

        let defaultConfig = try XCTUnwrap(HeadlessMCPSetup.makeConfig(autoDefault))
        XCTAssertEqual(defaultConfig.approvalMode, .auto)
        XCTAssertEqual(defaultConfig.judgeStrictness, .standard, "defaults to .standard when omitted")

        for strictness in MCPJudgeStrictness.allCases {
            var explicit = server()
            explicit.approvalMode = .auto
            explicit.judgeStrictness = strictness

            let decoded = config(servers: [explicit])
            XCTAssertEqual(decoded.mcpServers?.first?.approvalMode, .auto)
            XCTAssertEqual(decoded.mcpServers?.first?.judgeStrictness, strictness)

            let subDirectory = directory.appendingPathComponent(strictness.rawValue, isDirectory: true)
            let prepared = try XCTUnwrap(HeadlessMCPSetup.prepare(config: decoded, directory: subDirectory))
            let stored = try XCTUnwrap(prepared.catalogueStore.servers.first)
            XCTAssertEqual(stored.approvalMode, .auto)
            XCTAssertEqual(stored.judgeStrictness, strictness)
        }
    }

    func testGrantConfiguredServersAddsAllToolsGrantToEveryRoleIdempotently() throws {
        var team = try XCTUnwrap(Team.defaultTeams.first { $0.templateID == "assistant" })
        XCTAssertTrue(team.roles.contains(where: \.isSupervisor))
        XCTAssertTrue(team.roles.contains(where: { !$0.isSupervisor }))
        for role in team.roles {
            XCTAssertFalse(role.toolIDs.contains("mcp__folio"))
        }

        let servers = [
            server(slug: "folio"),
            server(slug: "INVALID SLUG"),
            server(slug: "folio"),
        ]
        HeadlessMCPSetup.grantConfiguredServers(to: &team, servers: servers)
        HeadlessMCPSetup.grantConfiguredServers(to: &team, servers: servers)

        for role in team.roles {
            if role.isSupervisor {
                XCTAssertFalse(role.toolIDs.contains("mcp__folio"),
                               "Supervisor is the human user and must not receive MCP server grants")
            } else {
                XCTAssertEqual(role.toolIDs.filter { $0 == "mcp__folio" }.count, 1)
            }
            XCTAssertFalse(role.toolIDs.contains { $0.contains("INVALID") })
        }
    }
}
