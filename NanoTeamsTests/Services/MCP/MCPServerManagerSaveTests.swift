import XCTest

@testable import NanoTeams

/// The one seam an edit to the server list goes through — the Keychain, the approvals and the
/// list, in an order that leaves no half-saved server behind — and the two other edits that
/// write a file: removing a server and allowing it in a folder.
///
/// The catalogue and the approvals live in SEPARATE directories here, unlike in
/// `MCPServerManagerTests`: each failure below blocks exactly one of them, by making its
/// directory immutable — reads still work, every write is refused, and the store's own
/// permission hardening cannot undo it.
@MainActor
final class MCPServerManagerSaveTests: XCTestCase {

    private var root: URL!
    private var catalogueDirectory: URL!
    private var trustDirectory: URL!
    private var catalogue: MCPServerCatalogueStore!
    private var scripted: ScriptedMCPEnvironment!
    private var trustStore: MCPTrustStore!
    private var manager: MCPServerManager!
    private var frozen: [URL] = []
    /// A second manager over the same stores, whose transports report the credential every
    /// request carries (`makeProbedManager`).
    private var probed: MCPServerManager?
    private var recorder: AuthorizationRecorder?
    private var probingStorage: ProbingTokenStorage?

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-save-\(UUID().uuidString)", isDirectory: true)
        catalogueDirectory = root.appendingPathComponent("catalogue", isDirectory: true)
        trustDirectory = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogueDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: true)
        catalogue = MCPServerCatalogueStore(directory: catalogueDirectory)
        scripted = ScriptedMCPEnvironment(trustDirectory: trustDirectory)
        trustStore = MCPTrustStore(directory: trustDirectory)
        manager = MCPServerManager(
            catalogueStore: catalogue, environment: scripted.environment, trustStore: trustStore)
        frozen = []
    }

    override func tearDown() async throws {
        probingStorage?.afterWrite = nil
        await probed?.shutdown(budget: 0)
        probed = nil
        recorder = nil
        probingStorage = nil
        await manager?.shutdown(budget: 0)
        for directory in frozen {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
        }
        scripted?.cleanUp()
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        catalogueDirectory = nil
        trustDirectory = nil
        catalogue = nil
        scripted = nil
        trustStore = nil
        manager = nil
        frozen = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    private var storage: InMemorySecureTokenStorage { scripted.secretStorage }

    /// Every write into `directory` refused from here on; reads still work.
    private func freeze(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)
        frozen.append(directory)
    }

    private func config(
        id: UUID = UUID(),
        url: String = "https://a.test/mcp",
        headers: [String] = [],
        authorization: MCPAuthorizationMode = .none,
        enabled: Bool = true
    ) throws -> MCPServerConfig {
        MCPServerConfig(
            id: id,
            slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            displayName: "Trade Room",
            transport: .http(MCPHTTPConfig(
                urlString: url, secretHeaderNames: headers, authorization: authorization)),
            isEnabled: enabled)
    }

    private func saveError(
        _ config: MCPServerConfig, _ edit: MCPServerSecretEdit, on target: MCPServerManager? = nil
    ) async -> MCPServerEditError? {
        do {
            try await (target ?? manager).save(config, secrets: edit)
            return nil
        } catch {
            return error as? MCPServerEditError ?? .serversNotLoaded
        }
    }

    private func waitForConnected(
        _ serverID: UUID, on target: MCPServerManager? = nil, timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (target ?? manager).connection(for: serverID)?.status.isConnected == true { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if (target ?? manager).connection(for: serverID)?.status.isConnected == true { return }
        XCTFail("waited \(timeout) s for server \(serverID) to connect", file: file, line: line)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool, timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !condition() {
            XCTFail("waited \(timeout) s for a condition that never held", file: file, line: line)
        }
    }

    /// A manager over the same catalogue and trust stores whose every transport answers a
    /// modern handshake and REPORTS the credential each request it builds carries — through the
    /// authorizer the connection gave it, as the HTTP transport does per request — and whose
    /// Keychain can run a probe the moment a value lands.
    private func makeProbedManager() -> MCPServerManager {
        let recorder = AuthorizationRecorder()
        let storage = ProbingTokenStorage()
        let made = MCPServerManager(
            catalogueStore: catalogue,
            environment: MCPEnvironment(
                makeTransport: { http, authorizer, _ in recorder.transport(for: http.urlString, authorizer: authorizer) },
                secretStorage: storage, trustDirectory: trustDirectory, writesRPCLog: false),
            trustStore: trustStore)
        self.recorder = recorder
        self.probingStorage = storage
        self.probed = made
        return made
    }

    // MARK: - The power switch (F40)

    /// A server as the editor leaves it after a real edit: trusted, Semi-automatic, its own
    /// timeouts, a plain header and a secret one, a bearer — every field the switch must leave
    /// alone.
    private func editedServer(enabled: Bool) throws -> MCPServerConfig {
        var edited = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            displayName: "Trade Room",
            transport: .http(MCPHTTPConfig(
                urlString: "https://a.test/mcp", headers: ["X-Client": "nanoteams"],
                secretHeaderNames: ["X-Api-Key"], authorization: .staticBearer)),
            isEnabled: enabled, isTrusted: true, approvalMode: .semiAutomatic)
        edited.timeouts = MCPTimeouts(connect: 3, requestInactivity: 7, requestAbsolute: 99)
        return edited
    }

    /// The server page's switch turns the server on and off and changes nothing else: the
    /// stored row differs in `isEnabled` alone, every secret is where it was, and the server
    /// connects — and stops again when switched off.
    ///
    /// RED until 2026-09-24: there was no such switch; the only one was in the editor, whose
    /// save round-trip reset what the sheet did not show (F40, F43).
    func testThePowerSwitchChangesOnlyWhetherTheServerRuns() async throws {
        let stored = try editedServer(enabled: false)
        try catalogue.upsert(stored)
        try storage.setToken("t.SECRET", forKey: stored.bearerSecretKey)
        try storage.setToken("k.SECRET", forKey: stored.secretKey(forHeader: "X-Api-Key"))
        scripted.register(url: "https://a.test/mcp", transport: await ScriptedMCPEnvironment.modernTransport(
            toolNames: ["get_orders"]))
        await manager.setWorkFolder(paths: nil)
        XCTAssertNil(manager.connection(for: stored.id), "premise: switched off, nothing runs")

        try await manager.setServerEnabled(id: stored.id, enabled: true)

        var switchedOn = stored
        switchedOn.isEnabled = true
        XCTAssertEqual(catalogue.server(id: stored.id), switchedOn)
        XCTAssertEqual(try storage.loadToken(forKey: stored.bearerSecretKey), "t.SECRET")
        XCTAssertEqual(try storage.loadToken(forKey: stored.secretKey(forHeader: "X-Api-Key")), "k.SECRET")
        await waitForConnected(stored.id)
        XCTAssertEqual(manager.connection(for: stored.id)?.status.isConnected, true)
        XCTAssertEqual(manager.serverRows.first?.config.isEnabled, true)

        try await manager.setServerEnabled(id: stored.id, enabled: false)

        XCTAssertEqual(catalogue.server(id: stored.id), stored)
        XCTAssertNil(manager.connection(for: stored.id))
        XCTAssertEqual(manager.serverRows.first?.status, .disabled)
        XCTAssertEqual(try storage.loadToken(forKey: stored.bearerSecretKey), "t.SECRET",
                       "switching off keeps the token for the next time it is on")
    }

    /// The switch reads the server from the list on disk, not from what the page held: an
    /// edit that landed since is kept, and only the switch moves.
    func testThePowerSwitchReadsTheStoredServer() async throws {
        let stored = try editedServer(enabled: false)
        try catalogue.upsert(stored)
        await manager.setWorkFolder(paths: nil)
        var renamed = stored
        renamed.displayName = "Trade Room (renamed elsewhere)"
        try catalogue.upsert(renamed)

        try await manager.setServerEnabled(id: stored.id, enabled: true)

        XCTAssertEqual(catalogue.server(id: stored.id)?.displayName, "Trade Room (renamed elsewhere)")
        XCTAssertEqual(catalogue.server(id: stored.id)?.isEnabled, true)
    }

    /// A server removed meanwhile is not brought back by its switch.
    func testThePowerSwitchOfAServerNoLongerListedIsRefused() async throws {
        await manager.setWorkFolder(paths: nil)
        let missing = UUID()
        do {
            try await manager.setServerEnabled(id: missing, enabled: true)
            XCTFail("a switch for a server the list does not hold must be refused")
        } catch {
            XCTAssertEqual(error as? MCPServerEditError, .serverNotFound)
        }
        XCTAssertNil(catalogue.server(id: missing))
        XCTAssertTrue(catalogue.servers.isEmpty)
        XCTAssertEqual(
            MCPServerEditError.serverNotFound.message,
            "This server is no longer in the list, so there is nothing to switch.")
    }

    /// Switching to where it already is writes nothing and changes nothing.
    func testThePowerSwitchToItsCurrentPositionChangesNothing() async throws {
        let stored = try editedServer(enabled: false)
        try catalogue.upsert(stored)
        await manager.setWorkFolder(paths: nil)
        try freeze(catalogueDirectory)

        try await manager.setServerEnabled(id: stored.id, enabled: false)

        XCTAssertEqual(catalogue.server(id: stored.id), stored)
    }

    /// The list refuses the write: the switch reports it in the save's own words, and the
    /// server stays as the disk holds it — off, and not running.
    func testAPowerSwitchTheListRefusesLeavesTheServerOff() async throws {
        let stored = try editedServer(enabled: false)
        try catalogue.upsert(stored)
        scripted.register(url: "https://a.test/mcp", transport: await ScriptedMCPEnvironment.modernTransport(
            toolNames: ["get_orders"]))
        await manager.setWorkFolder(paths: nil)
        try freeze(catalogueDirectory)

        do {
            try await manager.setServerEnabled(id: stored.id, enabled: true)
            XCTFail("a refused write must be reported")
        } catch let error as MCPServerEditError {
            guard case .catalogueNotSaved = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(catalogue.server(id: stored.id)?.isEnabled, false)
        XCTAssertNil(manager.connection(for: stored.id))
        XCTAssertEqual(manager.serverRows.first?.config.isEnabled, false)
    }

    /// With no work folder open there is no folder rule to show; with one there is.
    func testTheFolderRuleExistsOnlyWithAWorkFolder() async throws {
        await manager.setWorkFolder(paths: nil)
        XCTAssertFalse(manager.hasWorkFolder)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await manager.setWorkFolder(paths: NTMSPaths(workFolderRoot: folder))
        XCTAssertTrue(manager.hasWorkFolder)
    }

    // MARK: - A failed save saves nothing (F41, F28)

    /// The Keychain refuses the token: the server is NOT added — it would otherwise run with
    /// its credential missing and 401 on its first request — and the error says why.
    func testAKeychainFailureWritesNoConfigAndNoSecret() async throws {
        let new = try config(authorization: .staticBearer)
        storage.writeFailure = { _, token in token == nil ? nil : .unhandled(-25308) }

        let error = await saveError(new, MCPServerEditSecret.bearer("t.SECRET"))

        XCTAssertEqual(error, .keychainNotSaved(undone: true))
        XCTAssertTrue(catalogue.servers.isEmpty, "no server without its credential")
        XCTAssertTrue(manager.serverRows.isEmpty)
        XCTAssertNil(try storage.loadToken(forKey: new.bearerSecretKey))
    }

    /// The list refuses the write after the token went in: the token is taken back out, so no
    /// credential is left in the Keychain for a server that does not exist (F28(4)).
    func testACatalogueFailureLeavesNoSecretOfANewServerBehind() async throws {
        try freeze(catalogueDirectory)
        let new = try config(authorization: .staticBearer)

        let error = await saveError(new, MCPServerEditSecret.bearer("t.SECRET"))

        XCTAssertEqual(error, .catalogueNotSaved(undone: true, approvalsCleared: false))
        XCTAssertNil(try storage.loadToken(forKey: new.bearerSecretKey))
        XCTAssertTrue(manager.serverRows.isEmpty, "the rows are what the disk holds")
    }

    /// Same for an edit: the token the edit replaced is put back, so the server on disk goes on
    /// running with the credential it was saved with.
    func testACatalogueFailurePutsAnEditedServersTokenBack() async throws {
        let stored = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("old", forKey: stored.bearerSecretKey)
        await manager.reload()
        try freeze(catalogueDirectory)

        let error = await saveError(stored, MCPServerEditSecret.bearer("new"))

        XCTAssertEqual(error, .catalogueNotSaved(undone: true, approvalsCleared: false))
        XCTAssertEqual(try storage.loadToken(forKey: stored.bearerSecretKey), "old")
    }

    /// The order itself, without a manager: the Keychain refuses, and neither the approvals
    /// nor the list are touched — for a re-point, the case where touching them first would
    /// cost the most.
    func testTheCoordinatorTouchesNothingAfterARefusedSecret() throws {
        let stored = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        try trustStore.approve(serverID: stored.id, tool: "get_price", canonicalForm: #"{"name":"get_price"}"#)
        let coordinator = MCPServerSaveCoordinator(
            catalogueStore: catalogue, trustStore: trustStore, secrets: MCPSecretStore(storage: storage))
        storage.writeFailure = { _, token in token == nil ? nil : .unhandled(-25308) }
        var moved = stored
        moved.transport = .http(MCPHTTPConfig(urlString: "https://b.test/mcp", authorization: .staticBearer))

        XCTAssertThrowsError(try coordinator.save(moved, secrets: MCPServerEditSecret.bearer("t"))) {
            XCTAssertEqual($0 as? MCPServerEditError, .keychainNotSaved(undone: true))
        }
        XCTAssertEqual(catalogue.server(id: stored.id)?.transport.http.urlString, "https://a.test/mcp")
        XCTAssertFalse(trustStore.record(for: stored.id).toolPins.isEmpty, "the approvals are untouched")
    }

    // MARK: - What an edit drops is cleared (F42, F28(2))

    func testSwitchingTheBearerOffClearsTheToken() async throws {
        var stored = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("t.SECRET", forKey: stored.bearerSecretKey)
        await manager.reload()

        stored.transport = .http(MCPHTTPConfig(urlString: "https://a.test/mcp", authorization: .none))
        try await manager.save(stored, secrets: MCPServerSecretEdit())

        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey))
    }

    /// A header renamed and left blank keeps the value it was sent with, under its new name;
    /// the old account is cleared.
    func testRenamingAHeaderMovesItsValue() async throws {
        var stored = try config(headers: ["X-Api-Key"])
        try catalogue.upsert(stored)
        try storage.setToken("k.SECRET", forKey: stored.secretKey(forHeader: "X-Api-Key"))
        await manager.reload()

        stored.transport = .http(MCPHTTPConfig(urlString: "https://a.test/mcp", secretHeaderNames: ["X-API-Key"]))
        try await manager.save(stored, secrets: MCPServerSecretEdit(headers: [
            .init(name: "X-API-Key", originalName: "X-Api-Key"),
        ]))

        XCTAssertEqual(try storage.loadToken(forKey: stored.secretKey(forHeader: "X-API-Key")), "k.SECRET")
        XCTAssertNil(try storage.loadToken(forKey: stored.secretKey(forHeader: "X-Api-Key")))
        XCTAssertTrue(try XCTUnwrap(manager.serverRows.first).hasRequiredSecrets)
    }

    // MARK: - A different address is a different server (F22)

    private func connectedServerWithApprovedTool(url: String) async throws -> MCPServerConfig {
        scripted.register(url: url, transport: await ScriptedMCPEnvironment.modernTransport(toolNames: ["get_price"]))
        // Semi-automatic: a standing grant is recorded only under a mode that allows one.
        var stored = try config(url: url, authorization: .staticBearer)
        stored.approvalMode = .semiAutomatic
        try catalogue.upsert(stored)
        try storage.setToken("old-host-token", forKey: stored.bearerSecretKey)
        await manager.reload()
        await waitForConnected(stored.id)
        let connection = try XCTUnwrap(manager.connection(for: stored.id))
        let tool = try XCTUnwrap(connection.newTools.first)
        try connection.approve(reviewed: tool)
        XCTAssertNoThrow(try connection.setAlwaysAllow(tool: tool.originalName, allowed: true, expectedHash: tool.pinHash))
        XCTAssertFalse(manager.snapshot.isEmpty)
        return stored
    }

    /// Re-pointed at another host, the server keeps its id and loses what the old host was
    /// given: the token, the pins and the always-allow grants. If the new host
    /// serves byte-identical tools they are still unreviewed — nobody reviewed THAT host.
    func testRepointingDropsTheTokenThePinsAndTheGrants() async throws {
        var stored = try await connectedServerWithApprovedTool(url: "https://a.test/mcp")
        let other = "https://b.test/mcp"
        scripted.register(url: other, transport: await ScriptedMCPEnvironment.modernTransport(toolNames: ["get_price"]))
        let oldBearer = stored.bearerSecretKey

        stored.transport = .http(MCPHTTPConfig(urlString: other, authorization: .staticBearer))
        try await manager.save(stored, secrets: MCPServerSecretEdit())
        await waitForConnected(stored.id)

        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey), "the old host's token is not sent to the new one")
        XCTAssertNil(try storage.loadToken(forKey: oldBearer), "nor kept for an address the server left")
        XCTAssertTrue(trustStore.record(for: stored.id).toolPins.isEmpty, "no pin follows a re-pointed server")
        XCTAssertTrue(manager.snapshot.isEmpty, "the new host's tools are unreviewed")
        XCTAssertEqual(manager.connection(for: stored.id)?.toolTally.toReview, 1)
    }

    /// A token typed with the new address is the one stored — written after the old one went.
    func testRepointingWithANewTokenStoresOnlyTheNewOne() async throws {
        var stored = try await connectedServerWithApprovedTool(url: "https://a.test/mcp")
        let oldBearer = stored.bearerSecretKey
        stored.transport = .http(MCPHTTPConfig(urlString: "https://b.test/mcp", authorization: .staticBearer))

        try await manager.save(stored, secrets: MCPServerEditSecret.bearer("new-host-token"))

        XCTAssertEqual(try storage.loadToken(forKey: stored.bearerSecretKey), "new-host-token")
        XCTAssertNil(try storage.loadToken(forKey: oldBearer))
    }

    /// A new path on the same host is the same server: nothing is cleared.
    func testAPathChangeKeepsTheTokenAndThePins() async throws {
        var stored = try await connectedServerWithApprovedTool(url: "https://a.test/mcp")
        let moved = "https://a.test/v2/mcp"
        scripted.register(url: moved, transport: await ScriptedMCPEnvironment.modernTransport(toolNames: ["get_price"]))

        stored.transport = .http(MCPHTTPConfig(urlString: moved, authorization: .staticBearer))
        try await manager.save(stored, secrets: MCPServerSecretEdit())

        XCTAssertEqual(try storage.loadToken(forKey: stored.bearerSecretKey), "old-host-token")
        XCTAssertFalse(trustStore.record(for: stored.id).toolPins.isEmpty)
    }

    /// The old address's approvals are cleared BEFORE the new address is saved — the order in
    /// which a failure can only ever cost approvals, never carry them to another host. When
    /// the list then refuses the write, the old server runs on with no approvals, and the
    /// error says so.
    func testARepointTheListRefusesHasAlreadyClearedTheApprovalsAndSaysSo() async throws {
        var stored = try await connectedServerWithApprovedTool(url: "https://a.test/mcp")
        try freeze(catalogueDirectory)
        let oldBearer = stored.bearerSecretKey

        stored.transport = .http(MCPHTTPConfig(urlString: "https://b.test/mcp", authorization: .staticBearer))
        let error = await saveError(stored, MCPServerEditSecret.bearer("new-host-token"))

        XCTAssertEqual(error, .catalogueNotSaved(undone: true, approvalsCleared: true))
        XCTAssertEqual(catalogue.server(id: stored.id)?.transport.http.urlString, "https://a.test/mcp")
        XCTAssertEqual(try storage.loadToken(forKey: oldBearer), "old-host-token",
                       "the old host keeps its own token")
        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey), "the new host's is taken back out")
        XCTAssertTrue(trustStore.record(for: stored.id).toolPins.isEmpty)
        XCTAssertTrue(manager.snapshot.isEmpty, "a tool whose approval is gone ships nowhere")
        XCTAssertTrue(try XCTUnwrap(manager.connection(for: stored.id)).approvedHashes.isEmpty,
                      "the route stops accepting the approved texts too")
    }

    /// If even the approvals cannot be cleared, the re-point stops there: nothing is saved and
    /// the token is put back.
    func testARepointWhoseApprovalsCannotBeClearedSavesNothing() async throws {
        var stored = try await connectedServerWithApprovedTool(url: "https://a.test/mcp")
        try freeze(trustDirectory)
        let oldBearer = stored.bearerSecretKey

        stored.transport = .http(MCPHTTPConfig(urlString: "https://b.test/mcp", authorization: .staticBearer))
        let error = await saveError(stored, MCPServerEditSecret.bearer("new-host-token"))

        XCTAssertEqual(error, .approvalsNotCleared(undone: true))
        XCTAssertEqual(catalogue.server(id: stored.id)?.transport.http.urlString, "https://a.test/mcp")
        XCTAssertEqual(try storage.loadToken(forKey: oldBearer), "old-host-token")
        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey))
    }

    /// A re-point stops the old address's connection, and awaits its close, before the save
    /// touches the Keychain: no request goes to the address the person is moving away from
    /// while the save runs. The ORDER is what this pins — the old connection's close returns
    /// before the save's first Keychain write — because the new host's token could not reach the
    /// old one anyway: it is written under the new origin's accounts, and the old address reads
    /// only its own (`testARepointRenamesEveryAccountAndNothingElseRenamesAny`). The probe that
    /// builds one request on every still-open transport the moment the token lands stays as
    /// the second witness.
    ///
    /// RED until the second review of group D (2026-09-24): the save wrote the Keychain first
    /// and stopped the old connection only after the list was written.
    func testARepointStopsTheOldAddressBeforeTheNewTokenIsWritten() async throws {
        let target = makeProbedManager()
        let recorder = try XCTUnwrap(recorder), storage = try XCTUnwrap(probingStorage)
        let old = "https://a.test/mcp", new = "https://b.test/mcp"
        var stored = try config(url: old, authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("old-host-token", forKey: stored.bearerSecretKey)
        await target.reload()
        await waitForConnected(stored.id, on: target)
        XCTAssertEqual(recorder.authorizations(sentTo: old).last, "Bearer old-host-token",
                       "premise: the recorder sees what the old address is sent")
        storage.afterWrite = { _, token in
            recorder.note("keychain write")
            if token == "new-host-token" { recorder.probeOpenTransports() }
        }

        stored.transport = .http(MCPHTTPConfig(urlString: new, authorization: .staticBearer))
        try await target.save(stored, secrets: MCPServerEditSecret.bearer("new-host-token"))
        storage.afterWrite = nil

        let events = recorder.events
        let closed = try XCTUnwrap(events.firstIndex(of: "closed \(old)"), "\(events)")
        let firstWrite = try XCTUnwrap(events.firstIndex(of: "keychain write"), "\(events)")
        XCTAssertLessThan(closed, firstWrite, "the save wrote the Keychain while the old address was still open: \(events)")
        XCTAssertEqual(recorder.probes, 1, "premise: the probe ran when the new token landed")
        XCTAssertFalse(recorder.authorizations(sentTo: old).contains("Bearer new-host-token"),
                       "\(recorder.authorizations(sentTo: old))")
        await waitForConnected(stored.id, on: target)
        XCTAssertEqual(recorder.authorizations(sentTo: new).last, "Bearer new-host-token",
                       "the new address is sent the new token")
    }

    /// A reload asked while a re-point save waits for the old address's close decides AFTER the
    /// save: the save holds a turn in the reload chain, so no reload can rebuild the address the
    /// person is moving away from while the save runs. Seen at the one moment that matters —
    /// the save's first Keychain write — where no connection to the old address may be running.
    ///
    /// RED under mutant M1c of the D-2 verification (the save's turn removed): the reload waited
    /// on the same close, was resumed first, read the old list and built and started a second
    /// connection to the old address, running when the save wrote. (It dials nothing: the save
    /// is resumed before that connection's lifecycle runs, and stops it in the same turn as it
    /// writes — so the transport count alone, which the D-2 verification proposed, cannot see
    /// it, and every account it could read names the old origin anyway.)
    func testAReloadAskedWhileARepointAwaitsTheOldCloseBuildsNothingForTheOldAddress() async throws {
        let target = makeProbedManager()
        let recorder = try XCTUnwrap(recorder), storage = try XCTUnwrap(probingStorage)
        let old = "https://a.test/mcp", new = "https://b.test/mcp"
        var stored = try config(url: old, authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("old-host-token", forKey: stored.bearerSecretKey)
        await target.reload()
        await waitForConnected(stored.id, on: target)
        recorder.holdCloses()

        let runningAtFirstWrite = RunningCount()
        storage.afterWrite = { [weak target] _, _ in
            guard !runningAtFirstWrite.isTaken else { return }
            runningAtFirstWrite.take(MainActor.assumeIsolated {
                target?.connections.filter { !$0.isStopped && $0.config.transport.http.urlString == old }.count ?? -1
            })
        }

        stored.transport = .http(MCPHTTPConfig(urlString: new, authorization: .staticBearer))
        let edited = stored
        let save = Task { try await target.save(edited, secrets: MCPServerEditSecret.bearer("new-host-token")) }
        await waitUntil { recorder.closesBegun(for: old) == 1 }
        let reload = Task { await target.reload() }
        // Main-actor turns for the reload to reach its first await; nothing here waits on time.
        for _ in 0..<20 { await Task.yield() }
        recorder.releaseCloses()
        try await save.value
        await reload.value
        storage.afterWrite = nil
        await waitForConnected(stored.id, on: target)

        XCTAssertEqual(runningAtFirstWrite.value, 0,
                       "a reload decided from the old list while the save ran, and started the old address again")
        XCTAssertEqual(recorder.transportsBuilt(for: old), 1, "a reload rebuilt the address being moved away from")
        XCTAssertFalse(recorder.authorizations(sentTo: old).contains("Bearer new-host-token"))
        XCTAssertEqual(recorder.authorizations(sentTo: new).last, "Bearer new-host-token")
    }

    /// A re-point the list refuses leaves the server where the disk says it is: at the OLD
    /// address, connected again on its stored terms, with the token the Keychain was put back
    /// to — the save stopped its connection before writing, so the save must bring it back.
    func testARepointTheListRefusesRunsTheOldAddressAgainOnItsOwnToken() async throws {
        let target = makeProbedManager()
        let recorder = try XCTUnwrap(recorder), storage = try XCTUnwrap(probingStorage)
        let old = "https://a.test/mcp", new = "https://b.test/mcp"
        var stored = try config(url: old, authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("old-host-token", forKey: stored.bearerSecretKey)
        await target.reload()
        await waitForConnected(stored.id, on: target)
        try freeze(catalogueDirectory)
        let oldBearer = stored.bearerSecretKey

        stored.transport = .http(MCPHTTPConfig(urlString: new, authorization: .staticBearer))
        let error = await saveError(stored, MCPServerEditSecret.bearer("new-host-token"), on: target)
        XCTAssertEqual(error, .catalogueNotSaved(undone: true, approvalsCleared: false))

        await waitForConnected(stored.id, on: target)
        let running = try XCTUnwrap(target.connection(for: stored.id))
        XCTAssertFalse(running.isStopped)
        XCTAssertTrue(running.status.isConnected, "\(running.status)")
        XCTAssertEqual(running.config.transport.http.urlString, old, "on its stored terms")
        XCTAssertEqual(recorder.authorizations(sentTo: old).last, "Bearer old-host-token")
        XCTAssertFalse(recorder.authorizations(sentTo: old).contains("Bearer new-host-token"))
        XCTAssertTrue(recorder.authorizations(sentTo: new).isEmpty, "nothing was ever built for the new address")
        XCTAssertEqual(try storage.loadToken(forKey: oldBearer), "old-host-token")
    }

    /// A re-point whose write the list refuses, on a manager that is shut down — the folder
    /// switch whose open failed: the save throws, and nothing starts — neither the old address,
    /// which the failure arm would otherwise run again, nor the new one.
    ///
    /// Pins that the failed re-point's retry does not clear the shutdown.
    func testARefusedRepointOnAShutDownManagerDialsNeitherAddress() async throws {
        let target = makeProbedManager()
        let recorder = try XCTUnwrap(recorder)
        let old = "https://a.test/mcp", new = "https://b.test/mcp"
        var stored = try config(url: old)
        try catalogue.upsert(stored)
        await target.reload()
        await waitForConnected(stored.id, on: target)
        await target.shutdown(budget: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        let dialledOld = recorder.transportsBuilt(for: old)
        try freeze(catalogueDirectory)

        stored.transport = .http(MCPHTTPConfig(urlString: new))
        let error = await saveError(stored, MCPServerSecretEdit(), on: target)
        XCTAssertNotNil(error, "the list refused the write")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(target.connections.isEmpty, "a refused re-point on a shut-down manager built a connection")
        XCTAssertEqual(recorder.transportsBuilt(for: old), dialledOld, "the old address was dialled again")
        XCTAssertEqual(recorder.transportsBuilt(for: new), 0, "the new address was dialled")
        XCTAssertEqual(catalogue.server(id: stored.id)?.transport.http.urlString, old, "premise: the disk still says old")
    }

    /// A re-point that could not LIST what the server holds saves nothing — it could not clear
    /// what it must — even from a Keychain that still reads and writes values: the error says
    /// the Keychain could not be read, the list and the old address's token are as they were,
    /// and the old address runs again.
    ///
    /// RED under mutant M5e of the D-2 verification (a refused listing read as an empty one): the
    /// re-point saved, and whatever the listing would have named stayed under the server's id.
    func testARepointTheKeychainWillNotListSavesNothingAndRunsTheOldAddressAgain() async throws {
        let target = makeProbedManager()
        let recorder = try XCTUnwrap(recorder), storage = try XCTUnwrap(probingStorage)
        let old = "https://a.test/mcp", new = "https://b.test/mcp"
        var stored = try config(url: old, authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("old-host-token", forKey: stored.bearerSecretKey)
        await target.reload()
        await waitForConnected(stored.id, on: target)
        let oldBearer = stored.bearerSecretKey
        storage.listingError = .unhandled(-25308)

        stored.transport = .http(MCPHTTPConfig(urlString: new, authorization: .staticBearer))
        let error = await saveError(stored, MCPServerEditSecret.bearer("new-host-token"), on: target)
        storage.listingError = nil

        XCTAssertEqual(error, .keychainUnreadable)
        XCTAssertEqual(catalogue.server(id: stored.id)?.transport.http.urlString, old)
        XCTAssertEqual(try storage.loadToken(forKey: oldBearer), "old-host-token")
        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey), "nothing was written for the new address")
        await waitForConnected(stored.id, on: target)
        let running = try XCTUnwrap(target.connection(for: stored.id))
        XCTAssertTrue(running.status.isConnected, "\(running.status)")
        XCTAssertEqual(running.config.transport.http.urlString, old)
        XCTAssertTrue(recorder.authorizations(sentTo: new).isEmpty)
    }

    /// A refused re-point whose Keychain undo is refused too — after the new host's token
    /// landed, the next write, the old token's restore and every delete refused — leaves the
    /// new host's token in the Keychain and the old address's account empty. The failure reload
    /// runs the old address again, and none of its requests carries the new host's token: it
    /// reads only the accounts of ITS origin, and the token was written under the new one's. The
    /// error says the token needs entering again.
    ///
    /// Until the third pass of group D's review (2026-09-24) both addresses read `<uuid>/bearer`,
    /// and only a best-effort clear — which this Keychain refuses too — stood between the new
    /// host's token and the old host.
    func testARepointWhoseKeychainUndoIsRefusedNeverSendsTheNewTokenToTheOldAddress() async throws {
        let (target, recorder, storage, stored, edited) = try await repointWithTheUndoRefused()

        let error = await saveError(edited, MCPServerSecretEdit(
            bearer: "new-host-token", headers: [.init(name: "X-Api-Key", value: "new-key")]), on: target)

        XCTAssertEqual(error, .keychainNotSaved(undone: false))
        try await assertTheOldAddressRunsWithoutTheNewToken(target, recorder, storage, stored: stored, edited: edited)
        XCTAssertTrue(error?.message.contains("enter it again") ?? false, error?.message ?? "")
    }

    /// The same when it is the LIST that refuses, after the Keychain took the new token: the
    /// undo is refused, the new token stays under the new origin's account, and the old address
    /// runs again without it.
    func testARepointTheListRefusesWhoseUndoIsRefusedNeverSendsTheNewTokenToTheOldAddress() async throws {
        let (target, recorder, storage, stored, edited) = try await repointWithTheUndoRefused()
        try freeze(catalogueDirectory)

        let error = await saveError(edited, MCPServerSecretEdit(bearer: "new-host-token"), on: target)

        XCTAssertEqual(error, .catalogueNotSaved(undone: false, approvalsCleared: false))
        try await assertTheOldAddressRunsWithoutTheNewToken(target, recorder, storage, stored: stored, edited: edited)
    }

    /// A server connected at `https://a.test/mcp` on "old-host-token", about to be re-pointed at
    /// `https://b.test/mcp` with an `X-Api-Key` header, over a Keychain that refuses every write
    /// after the new host's token lands — the next write, the old token's restore, every delete.
    private func repointWithTheUndoRefused() async throws -> (
        MCPServerManager, AuthorizationRecorder, ProbingTokenStorage, MCPServerConfig, MCPServerConfig
    ) {
        let target = makeProbedManager()
        let recorder = try XCTUnwrap(recorder), storage = try XCTUnwrap(probingStorage)
        let stored = try config(url: "https://a.test/mcp", authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("old-host-token", forKey: stored.bearerSecretKey)
        await target.reload()
        await waitForConnected(stored.id, on: target)
        var edited = stored
        edited.transport = .http(MCPHTTPConfig(
            urlString: "https://b.test/mcp", secretHeaderNames: ["X-Api-Key"], authorization: .staticBearer))
        let landed = LandedFlag()
        storage.writeFailure = { _, token in
            if token == "new-host-token" {
                landed.set()
                return nil
            }
            return landed.isSet ? .unhandled(-25308) : nil
        }
        return (target, recorder, storage, stored, edited)
    }

    private func assertTheOldAddressRunsWithoutTheNewToken(
        _ target: MCPServerManager, _ recorder: AuthorizationRecorder, _ storage: ProbingTokenStorage,
        stored: MCPServerConfig, edited: MCPServerConfig
    ) async throws {
        storage.writeFailure = nil
        XCTAssertEqual(try storage.loadToken(forKey: edited.bearerSecretKey), "new-host-token",
                       "premise: the undo was refused, and the new host's token is still there")
        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey), "premise: the old token was cleared first")
        XCTAssertEqual(catalogue.server(id: stored.id)?.transport.http.urlString, "https://a.test/mcp")
        await waitForConnected(stored.id, on: target)
        let running = try XCTUnwrap(target.connection(for: stored.id))
        XCTAssertTrue(running.status.isConnected, "\(running.status)")
        XCTAssertEqual(running.config.transport.http.urlString, "https://a.test/mcp")
        let sent = recorder.authorizations(sentTo: "https://a.test/mcp")
        XCTAssertFalse(sent.contains("Bearer new-host-token"), "\(sent)")
        XCTAssertEqual(sent.last, .some(nil), "the old address asks with no token, not with another host's: \(sent)")
    }

    /// A re-point of a server that had NO approvals, refused by the list, does not claim it
    /// cleared any.
    func testARepointOfAServerWithNoApprovalsTheListRefusesSaysNoneWereCleared() async throws {
        var stored = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("old-host-token", forKey: stored.bearerSecretKey)
        await manager.reload()
        try freeze(catalogueDirectory)

        stored.transport = .http(MCPHTTPConfig(urlString: "https://b.test/mcp", authorization: .staticBearer))
        let error = await saveError(stored, MCPServerEditSecret.bearer("new-host-token"))

        XCTAssertEqual(error, .catalogueNotSaved(undone: true, approvalsCleared: false))
        XCTAssertFalse(error?.message.contains("already cleared") ?? true)
    }

    /// A re-point clears what the Keychain holds under the server's prefix — an account no
    /// config names any more included — before the new address's values are written.
    ///
    /// RED until the second review of group D (2026-09-24): the orphan of a pre-fix rename
    /// survived the re-point, a credential of the old host kept under the server's id.
    func testARepointClearsAnAccountNoConfigNamesAnyMore() async throws {
        var stored = try config(headers: ["X-API-Key"], authorization: .staticBearer, enabled: false)
        try catalogue.upsert(stored)
        let orphan = stored.secretKey(forHeader: "X-Api-Key")
        let oldKeys = stored.allSecretKeys
        try storage.setToken("old-token", forKey: stored.bearerSecretKey)
        try storage.setToken("old-key", forKey: stored.secretKey(forHeader: "X-API-Key"))
        try storage.setToken("renamed before the fix", forKey: orphan)
        await manager.reload()

        stored.transport = .http(MCPHTTPConfig(
            urlString: "https://b.test/mcp", secretHeaderNames: ["X-API-Key"], authorization: .staticBearer))
        try await manager.save(stored, secrets: MCPServerSecretEdit(
            bearer: "new-token", headers: [.init(name: "X-API-Key", originalName: "X-API-Key", value: "new-key")]))

        XCTAssertNil(try storage.loadToken(forKey: orphan))
        for key in oldKeys { XCTAssertNil(try storage.loadToken(forKey: key), key) }
        XCTAssertEqual(try storage.accountNames(withPrefix: stored.secretAccountPrefix), stored.allSecretKeys,
                       "under the server's id: the new address's accounts, and nothing else")
        XCTAssertEqual(try storage.loadToken(forKey: stored.bearerSecretKey), "new-token")
        XCTAssertEqual(try storage.loadToken(forKey: stored.secretKey(forHeader: "X-API-Key")), "new-key")
    }

    // MARK: - A server that reads no secret, and a corrupt entry (second review of group D)

    /// A server with No authentication and no secret header is saved without the Keychain: a
    /// locked Keychain — reads and writes refused — does not refuse the save. A bearer an earlier
    /// mode left in its account stays until the server is removed; it is never sent.
    ///
    /// RED until the second review of group D (2026-09-24): the save deleted, so first read, the
    /// bearer account, and a locked Keychain refused it.
    func testSavingAServerThatReadsNoSecretNeedsNoKeychain() async throws {
        var stored = try config(authorization: .none)
        try catalogue.upsert(stored)
        try storage.setToken("left over", forKey: stored.bearerSecretKey)
        await manager.reload()
        storage.readError = .unhandled(-25308)
        storage.writeFailure = { _, _ in .unhandled(-25308) }

        stored.isEnabled = false
        try await manager.save(stored, secrets: MCPServerSecretEdit())

        XCTAssertEqual(catalogue.server(id: stored.id)?.isEnabled, false)
        storage.readError = nil
        storage.writeFailure = nil
        XCTAssertEqual(try storage.loadToken(forKey: stored.bearerSecretKey), "left over", "a save does not sweep it")
        await manager.remove(id: stored.id)
        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey), "a removal does")
        XCTAssertNil(manager.lastError)
    }

    /// A token whose Keychain entry is corrupt reads as none — the row says "Needs a token" —
    /// and the token the person then pastes REPLACES it.
    ///
    /// RED until the second review of group D (2026-09-24): the save read the entry first, the
    /// read threw, and the save was refused as an unreadable Keychain.
    func testAPastedTokenReplacesACorruptOne() async throws {
        let stored = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        storage.storeCorruptEntry(forKey: stored.bearerSecretKey)
        await manager.reload()
        XCTAssertFalse(try XCTUnwrap(manager.serverRows.first).hasRequiredSecrets)

        try await manager.save(stored, secrets: MCPServerEditSecret.bearer("t.SECRET"))

        XCTAssertEqual(try storage.loadToken(forKey: stored.bearerSecretKey), "t.SECRET")
        XCTAssertTrue(try XCTUnwrap(manager.serverRows.first).hasRequiredSecrets)
    }

    /// The same save refused by the list puts back what the account held before it — for a
    /// corrupt entry that is nothing: the pasted token is taken out and no corrupt bytes return.
    func testARefusedSaveOverACorruptTokenLeavesNothingBehind() async throws {
        let stored = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        storage.storeCorruptEntry(forKey: stored.bearerSecretKey)
        await manager.reload()
        try freeze(catalogueDirectory)

        let error = await saveError(stored, MCPServerEditSecret.bearer("t.SECRET"))

        XCTAssertEqual(error, .catalogueNotSaved(undone: true, approvalsCleared: false))
        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey), "deleted, not restored — and readable")
    }

    /// Switching a server whose token is corrupt to No authentication clears the entry.
    func testSwitchingACorruptTokenOffClearsIt() async throws {
        var stored = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        storage.storeCorruptEntry(forKey: stored.bearerSecretKey)
        await manager.reload()

        stored.transport = .http(MCPHTTPConfig(urlString: "https://a.test/mcp", authorization: .none))
        try await manager.save(stored, secrets: MCPServerSecretEdit())

        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey))
    }

    // MARK: - A retried Add (second review of group D)

    /// An Add whose Keychain write — and its undo — were refused leaves a value under the
    /// draft's id; a second press saves under the SAME id and so writes over it. Nothing is left
    /// under an id no server has.
    ///
    /// RED until the second review of group D (2026-09-24): each press minted a new id, and the
    /// first attempt's token stayed in the Keychain for good.
    func testARetriedAddWritesOverItsOwnFirstAttempt() async throws {
        var draft = MCPServerEditorState()
        draft.slugText = "trade_room"
        draft.urlString = "https://a.test/mcp"
        draft.authorization = .staticBearer
        draft.bearerToken = "t.SECRET"
        draft.headers = [.init(name: "X-Api-Key", value: "k.SECRET")]
        let first = try XCTUnwrap(draft.makeConfig(existing: []))
        let header = first.secretKey(forHeader: "X-Api-Key"), bearer = first.bearerSecretKey
        storage.writeFailure = { key, token in
            (key == header && token != nil) || (key == bearer && token == nil) ? .unhandled(-25308) : nil
        }

        let refused = await saveError(first, draft.secretEdit)
        XCTAssertEqual(refused, .keychainNotSaved(undone: false), "premise: the first attempt left its token behind")

        storage.writeFailure = nil
        let second = try XCTUnwrap(draft.makeConfig(existing: manager.serverRows.map(\.config)))
        try await manager.save(second, secrets: draft.secretEdit)

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(try storage.accountNames(withPrefix: ""),
                       [second.bearerSecretKey, second.secretKey(forHeader: "X-Api-Key")].sorted())
    }

    // MARK: - Removing (review: missed findings)

    /// The list refuses the removal: the server stays configured, so its token stays with it.
    func testARemoveTheListRefusesKeepsTheSecret() async throws {
        let stored = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("t.SECRET", forKey: stored.bearerSecretKey)
        await manager.reload()
        try freeze(catalogueDirectory)

        await manager.remove(id: stored.id)

        XCTAssertEqual(manager.lastError, MCPServerEditError.catalogueNotSaved(undone: true, approvalsCleared: false).message)
        XCTAssertEqual(try storage.loadToken(forKey: stored.bearerSecretKey), "t.SECRET")
        XCTAssertEqual(manager.serverRows.count, 1)
    }

    /// The server went; its approvals could not follow. The message says exactly that — not
    /// that the list could not be saved, which it was.
    func testApprovalsLeftBehindByARemoveGetTheirOwnMessage() async throws {
        let stored = try config()
        try catalogue.upsert(stored)
        try trustStore.approve(serverID: stored.id, tool: "get_price", canonicalForm: #"{"name":"get_price"}"#)
        await manager.reload()
        try freeze(trustDirectory)

        await manager.remove(id: stored.id)

        XCTAssertTrue(catalogue.servers.isEmpty)
        XCTAssertEqual(manager.lastError, MCPServerEditError.removedWithLeftovers(token: false, approvals: true).message)
    }

    func testATokenTheKeychainWillNotDeleteOnRemoveIsReported() async throws {
        let stored = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("t.SECRET", forKey: stored.bearerSecretKey)
        await manager.reload()
        storage.writeFailure = { _, token in token == nil ? .unhandled(-25308) : nil }

        await manager.remove(id: stored.id)

        XCTAssertTrue(catalogue.servers.isEmpty)
        XCTAssertEqual(manager.lastError, MCPServerEditError.removedWithLeftovers(token: true, approvals: false).message)
    }

    /// The list refuses the removal: the server is still configured, so its approvals stay
    /// with it too — they are forgotten only once the list no longer names it.
    func testARemoveTheListRefusesKeepsTheApprovals() async throws {
        let stored = try config()
        try catalogue.upsert(stored)
        try trustStore.approve(serverID: stored.id, tool: "get_price", canonicalForm: #"{"name":"get_price"}"#)
        let pins = trustStore.record(for: stored.id).toolPins
        await manager.reload()
        try freeze(catalogueDirectory)

        await manager.remove(id: stored.id)

        XCTAssertFalse(pins.isEmpty, "premise")
        XCTAssertEqual(trustStore.record(for: stored.id).toolPins, pins)
    }

    /// Each thing a removal can leave behind is named for what it is — never one leftover's
    /// words for another's.
    func testEachThingARemovalLeavesBehindIsNamed() {
        let token = MCPServerEditError.removedWithLeftovers(token: true, approvals: false).message
        let approvals = MCPServerEditError.removedWithLeftovers(token: false, approvals: true).message
        let both = MCPServerEditError.removedWithLeftovers(token: true, approvals: true).message

        XCTAssertEqual(Set([token, approvals, both]).count, 3)
        XCTAssertTrue(token.contains("token") && token.contains("Keychain"), token)
        XCTAssertFalse(token.contains("approvals"), token)
        XCTAssertTrue(approvals.contains("approvals"), approvals)
        XCTAssertFalse(approvals.contains("token"), approvals)
        XCTAssertTrue(both.contains("token") && both.contains("approvals"), both)

        let unreadable = MCPServerEditError.keychainUnreadable.message
        let approvalsUndone = MCPServerEditError.approvalsNotCleared(undone: true).message
        let approvalsPartial = MCPServerEditError.approvalsNotCleared(undone: false).message
        let noFolder = MCPServerEditError.noWorkFolder.message
        let notLoaded = MCPServerEditError.serversNotLoaded.message
        XCTAssertEqual(Set([unreadable, approvalsUndone, approvalsPartial, noFolder, notLoaded]).count, 5)
        XCTAssertTrue(unreadable.contains("Unlock it"), unreadable)
        XCTAssertTrue(approvalsUndone.contains("approvals could not be cleared"), approvalsUndone)
        XCTAssertTrue(approvalsPartial.contains("enter it again"), approvalsPartial)
        XCTAssertTrue(noFolder.contains("Open a work folder"), noFolder)
        XCTAssertTrue(notLoaded.contains("not loaded yet"), notLoaded)
    }

    /// Removal clears every account under the server's prefix: the header it sends, a header
    /// account a rename before the fix left behind, and a bearer from an earlier mode — and no
    /// other server's.
    ///
    /// RED until the second review of group D (2026-09-24): the renamed header's old account
    /// stayed in the Keychain after the server was gone.
    func testRemovingClearsEveryAccountUnderTheServersPrefix() async throws {
        let stored = try config(headers: ["X-API-Key"])
        let other = try config(authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("k", forKey: stored.secretKey(forHeader: "X-API-Key"))
        try storage.setToken("renamed before the fix", forKey: stored.secretKey(forHeader: "X-Api-Key"))
        try storage.setToken("left over", forKey: stored.bearerSecretKey)
        try storage.setToken("another server's", forKey: other.bearerSecretKey)
        await manager.reload()

        await manager.remove(id: stored.id)

        XCTAssertNil(manager.lastError)
        for key in [stored.secretKey(forHeader: "X-API-Key"), stored.secretKey(forHeader: "X-Api-Key"),
                    stored.bearerSecretKey] {
            XCTAssertNil(try storage.loadToken(forKey: key), key)
        }
        XCTAssertEqual(try storage.loadToken(forKey: other.bearerSecretKey), "another server's")
    }

    /// A bearer left from an earlier mode goes with the server too.
    func testRemovingClearsABearerLeftFromAnEarlierMode() async throws {
        let stored = try config(authorization: .none)
        try catalogue.upsert(stored)
        try storage.setToken("left over", forKey: stored.bearerSecretKey)
        await manager.reload()

        await manager.remove(id: stored.id)

        XCTAssertNil(try storage.loadToken(forKey: stored.bearerSecretKey))
        XCTAssertNil(manager.lastError)
    }

    // MARK: - The folder switch (review: missed finding)

    func testAFolderRuleThatCannotBeSavedIsReported() async throws {
        let stored = try config()
        try catalogue.upsert(stored)
        let paths = NTMSPaths(workFolderRoot: root.appendingPathComponent("folder", isDirectory: true))
        await manager.setWorkFolder(paths: paths)
        try freeze(paths.mcpDir)

        do {
            try await manager.setServerEnabledInThisFolder(stored.id, enabled: false)
            XCTFail("a refused write must be reported")
        } catch {
            XCTAssertEqual(error as? MCPServerEditError, .folderRuleNotSaved)
        }
        XCTAssertTrue(try XCTUnwrap(manager.serverRows.first).isAllowedInThisFolder, "the row shows what the disk holds")
    }

    /// With no folder open there is no folder rule to write; saying so beats a switch that
    /// silently snaps back.
    func testWithNoFolderOpenTheFolderSwitchSaysSo() async throws {
        let stored = try config()
        try catalogue.upsert(stored)
        await manager.setWorkFolder(paths: nil)

        do {
            try await manager.setServerEnabledInThisFolder(stored.id, enabled: false)
            XCTFail("with no folder open there is nothing to write")
        } catch {
            XCTAssertEqual(error as? MCPServerEditError, .noWorkFolder)
        }
    }

    // MARK: - A shutdown awaits every close still running (fifth pass of group D's review, 2026-09-24)
    //
    // A quit, a folder switch or a reset shuts the manager down, and the app may exit the moment
    // it returns. Every close any path began before it — each builds a request through the
    // authorizer, as a legacy server's `DELETE` does — has returned by then: an edit's, a
    // removal's, a reload's, an earlier shutdown's. Each test holds the close, gives the shutdown
    // the main-actor turns it would need to return were it not waiting, and then releases it.

    /// A connected server on the probed manager, and every close held from here on.
    private func connectedWithClosesHeld(
        url: String = "https://a.test/mcp"
    ) async throws -> (MCPServerManager, AuthorizationRecorder, MCPServerConfig) {
        let target = makeProbedManager()
        let recorder = try XCTUnwrap(recorder)
        let stored = try config(url: url)
        try catalogue.upsert(stored)
        await target.reload()
        await waitForConnected(stored.id, on: target)
        XCTAssertEqual(target.connection(for: stored.id)?.status.isConnected, true, "premise: connected")
        recorder.holdCloses()
        return (target, recorder, stored)
    }

    /// How many closes of `url` had begun, and how many had RETURNED, when a shutdown of
    /// `target` begun now returned: the shutdown gets twenty main-actor turns — what it would
    /// need to run to its end if it waited for nothing — before the held closes are released.
    /// Turns, not a delay: everything the shutdown does is on this actor.
    private func closesWhenAShutdownReturns(
        _ target: MCPServerManager, of url: String, recorder: AuthorizationRecorder
    ) async -> (begun: Int, returned: Int) {
        let shuttingDown = Task { @MainActor in
            await target.shutdown(budget: 0)
            return (recorder.closesBegun(for: url), recorder.events.count { $0 == "closed \(url)" })
        }
        for _ in 0..<20 { await Task.yield() }
        recorder.releaseCloses()
        return await shuttingDown.value
    }

    /// A removal stops the server at once and leaves its connection listed until the reload
    /// decides; a shutdown while that close is in flight returns only once it has.
    ///
    /// RED until the fifth pass of group D's review (2026-09-24): the shutdown stopped the
    /// removed connection a second time, that stop found nothing left to close, and the
    /// shutdown returned mid-`DELETE` — at quit, the app could exit with it in flight.
    func testAShutdownAfterARemovalAwaitsTheRemovedServersClose() async throws {
        let (target, recorder, stored) = try await connectedWithClosesHeld()
        let url = stored.transport.http.urlString

        let removing = Task { @MainActor in await target.remove(id: stored.id) }
        await waitUntil { recorder.closesBegun(for: url) == 1 }
        XCTAssertEqual(recorder.closesBegun(for: url), 1, "premise: the removal's close began and is held")
        let closes = await closesWhenAShutdownReturns(target, of: url, recorder: recorder)
        await removing.value

        XCTAssertEqual(closes.returned, closes.begun, "shutdown returned while the removed server's close was in flight")
        XCTAssertEqual(closes.begun, 1)
        XCTAssertTrue(target.connections.isEmpty)
    }

    /// The same for a server switched off by a save: the save stops it at once, and its reload
    /// awaits the close; a shutdown meanwhile returns only once that close has.
    ///
    /// RED until the fifth pass of group D's review (2026-09-24), as the removal above.
    func testAShutdownAfterASwitchOffAwaitsTheServersClose() async throws {
        let (target, recorder, stored) = try await connectedWithClosesHeld()
        let url = stored.transport.http.urlString
        var off = stored
        off.isEnabled = false
        let switchedOff = off

        let saving = Task { @MainActor in try await target.save(switchedOff, secrets: MCPServerSecretEdit()) }
        await waitUntil { recorder.closesBegun(for: url) == 1 }
        XCTAssertEqual(recorder.closesBegun(for: url), 1, "premise: the switch-off's close began and is held")
        let closes = await closesWhenAShutdownReturns(target, of: url, recorder: recorder)
        try await saving.value

        XCTAssertEqual(closes.returned, closes.begun, "shutdown returned while the switched-off server's close was in flight")
        XCTAssertEqual(closes.begun, 1)
        XCTAssertEqual(catalogue.servers.map(\.isEnabled), [false], "premise: the switch-off was saved")
    }

    /// A reload that stopped a server the list no longer runs is awaiting its close when the
    /// shutdown lands: the shutdown returns only once that close has, although the reload — not
    /// the shutdown — is the one waiting for it.
    ///
    /// RED until the fifth pass of group D's review (2026-09-24), as the removal above.
    func testAShutdownDuringAReloadsCloseAwaitsThatClose() async throws {
        let (target, recorder, stored) = try await connectedWithClosesHeld()
        let url = stored.transport.http.urlString
        var off = stored
        off.isEnabled = false
        try catalogue.upsert(off)

        let reloading = Task { @MainActor in await target.reload() }
        await waitUntil { recorder.closesBegun(for: url) == 1 }
        XCTAssertEqual(recorder.closesBegun(for: url), 1, "premise: the reload's close began and is held")
        XCTAssertEqual(target.connections.count { $0.isStopped }, 1, "premise: the stale connection is still listed")
        let closes = await closesWhenAShutdownReturns(target, of: url, recorder: recorder)
        await reloading.value

        XCTAssertEqual(closes.returned, closes.begun, "shutdown returned while the reload's close was in flight")
        XCTAssertEqual(closes.begun, 1)
    }

    /// A quit while a folder switch's shutdown is still closing: the first shutdown dropped every
    /// connection from the list at once, so the second has nothing listed to stop — and still
    /// returns only once the first one's close has.
    ///
    /// RED until the fifth pass of group D's review (2026-09-24): the second shutdown found an
    /// empty list and returned at once.
    func testAShutdownDuringAnEarlierShutdownsCloseAwaitsThatClose() async throws {
        let (target, recorder, stored) = try await connectedWithClosesHeld()
        let url = stored.transport.http.urlString

        let first = Task { @MainActor in await target.shutdown(budget: 0) }
        await waitUntil { recorder.closesBegun(for: url) == 1 }
        XCTAssertEqual(recorder.closesBegun(for: url), 1, "premise: the first shutdown's close began and is held")
        XCTAssertTrue(target.connections.isEmpty, "premise: the first shutdown dropped the connection")
        let closes = await closesWhenAShutdownReturns(target, of: url, recorder: recorder)
        await first.value

        XCTAssertEqual(closes.returned, closes.begun, "a second shutdown returned while the first one's close was in flight")
        XCTAssertEqual(closes.begun, 1)
    }

    /// A close begun while a reload awaits another stays where the reload and a shutdown find
    /// it: here a server is removed while a reload awaits a switched-off server's close. Back
    /// from that close, the reload lets go of what it awaited and of nothing else — so it goes
    /// on to await the removal's close, keeps the removed connection listed until that close
    /// returns, and a shutdown meanwhile awaits it too.
    ///
    /// Green on the code before the fifth pass of group D's review (2026-09-24), which emptied
    /// the list BEFORE awaiting it; pins that a close leaves `closing` only once it returned,
    /// and only the closes an awaiter saw — mutant D5M5 (every close dropped after the await)
    /// broke exactly this.
    func testACloseBegunWhileAReloadAwaitsAnotherIsAwaitedByTheReloadAndAShutdown() async throws {
        let target = makeProbedManager()
        let recorder = try XCTUnwrap(recorder)
        let switchedOffURL = "https://a.test/mcp", removedURL = "https://b.test/mcp"
        let switchedOff = try config(url: switchedOffURL)
        var removed = try config(url: removedURL)
        removed.slug = try XCTUnwrap(MCPServerSlug("ledger"))
        try catalogue.upsert(switchedOff)
        try catalogue.upsert(removed)
        await target.reload()
        await waitForConnected(switchedOff.id, on: target)
        await waitForConnected(removed.id, on: target)
        XCTAssertEqual(target.connections.count { $0.status.isConnected }, 2, "premise: both connected")
        recorder.holdCloses()

        var off = switchedOff
        off.isEnabled = false
        try catalogue.upsert(off)
        let reloading = Task { @MainActor in await target.reload() }
        await waitUntil { recorder.closesBegun(for: switchedOffURL) == 1 }
        let removing = Task { @MainActor in await target.remove(id: removed.id) }
        await waitUntil { recorder.closesBegun(for: removedURL) == 1 }
        XCTAssertEqual(recorder.closesBegun(for: removedURL), 1, "premise: the removal's close began and is held")
        recorder.releaseCloses(for: switchedOffURL)
        await waitUntil { recorder.events.contains("closed \(switchedOffURL)") }
        // Main-actor turns for the reload to come back from that close and reach its decision
        // were it not waiting for the removal's.
        for _ in 0..<20 { await Task.yield() }
        let listedWhileTheRemovalCloses = target.connections.count { $0.config.id == removed.id }
        let closes = await closesWhenAShutdownReturns(target, of: removedURL, recorder: recorder)
        await reloading.value
        await removing.value

        XCTAssertEqual(listedWhileTheRemovalCloses, 1,
                       "the reload dropped the removed connection while its close was in flight")
        XCTAssertEqual(closes.returned, closes.begun, "shutdown returned while the removal's close was in flight")
        XCTAssertEqual(closes.begun, 1)
    }

    /// A reload asked while a shutdown's close is in flight — a server edited in Settings during
    /// a folder switch — builds nothing until that close has returned: the server it would
    /// build is the one still closing. And a second shutdown meanwhile still awaits that close,
    /// although the reload is the one waiting for it now.
    ///
    /// RED until the fifth pass of group D's review (2026-09-24): a shutdown's closes were kept
    /// nowhere, so the reload built and dialled the server while its old session's close ran.
    func testAReloadAskedWhileAShutdownClosesBuildsNothingAndAQuitStillAwaitsTheClose() async throws {
        let (target, recorder, stored) = try await connectedWithClosesHeld()
        let url = stored.transport.http.urlString

        let first = Task { @MainActor in await target.shutdown(budget: 0) }
        await waitUntil { recorder.closesBegun(for: url) == 1 }
        XCTAssertEqual(recorder.closesBegun(for: url), 1, "premise: the shutdown's close began and is held")
        let reloading = Task { @MainActor in await target.reload() }
        // Main-actor turns for the reload to reach its decision were it not waiting.
        for _ in 0..<20 { await Task.yield() }
        let builtWhileClosing = recorder.transportsBuilt(for: url)
        let listedWhileClosing = target.connections.count
        let closes = await closesWhenAShutdownReturns(target, of: url, recorder: recorder)
        await first.value
        await reloading.value

        XCTAssertEqual(builtWhileClosing, 1, "the reload dialled the server while its old session's close ran")
        XCTAssertEqual(listedWhileClosing, 0, "the reload built a connection while the shutdown's close ran")
        XCTAssertEqual(closes.returned, closes.begun, "the quit returned while the shutdown's close was in flight")
        XCTAssertEqual(closes.begun, 1)
        XCTAssertTrue(target.connections.isEmpty, "the reload the quit overtook committed")
    }

    // MARK: - The editor's view of the Keychain

    /// What the editor reads to offer "leave blank to keep" — refreshed by every save, from
    /// the same reading as the rows.
    func testTheStoredSecretKeysFollowEachSave() async throws {
        let new = try config(headers: ["X-Api-Key"], authorization: .staticBearer)
        XCTAssertTrue(manager.storedSecretKeys(of: new.id).isEmpty)

        try await manager.save(new, secrets: MCPServerSecretEdit(
            bearer: "t.SECRET", headers: [.init(name: "X-Api-Key", value: "k.SECRET")]))

        XCTAssertEqual(manager.storedSecretKeys(of: new.id),
                       [new.bearerSecretKey, new.secretKey(forHeader: "X-Api-Key")])
    }
}

/// Spelling helpers for the edits these tests type.
private enum MCPServerEditSecret {
    static func bearer(_ token: String) -> MCPServerSecretEdit { MCPServerSecretEdit(bearer: token) }
}

// MARK: - Seeing what a request carries

/// Builds a transport per connection attempt that answers a modern handshake and records the
/// `Authorization` of every request it builds — its sends, the close (as a legacy server's
/// `DELETE` does), and a probe on demand — through the authorizer the connection handed it.
private nonisolated final class AuthorizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var built: [RecordingTransport] = []
    private var sent: [(url: String, authorization: String?)] = []
    private var probeCount = 0
    private var log: [String] = []
    private var closesHeld = false
    private var heldCloses: [(url: String, continuation: CheckedContinuation<Void, Never>)] = []
    private var begun: [String: Int] = [:]

    func transport(for url: String, authorizer: any MCPAuthorizer) -> RecordingTransport {
        let inner = ScriptedTransport()
        inner.script(MCPWire.discoverMethod, [.result(.object([
            "protocolVersion": .string(MCPConstants.modernProtocolVersion),
            "serverInfo": .object(["name": .string("scripted")]),
        ]))])
        inner.script(MCPWire.toolsListMethod, [.result(.object([
            "tools": .array([.object([
                "name": .string("get_price"),
                "description": .string("Does get_price."),
                "inputSchema": .object(["type": .string("object")]),
            ])]),
        ]))])
        let transport = RecordingTransport(url: url, inner: inner, authorizer: authorizer, recorder: self)
        lock.withLock { built.append(transport) }
        return transport
    }

    func record(url: String, authorization: String?) {
        lock.withLock { sent.append((url, authorization)) }
    }

    /// Every `Authorization` value a request to `url` carried, in order.
    func authorizations(sentTo url: String) -> [String?] {
        lock.withLock { sent.filter { $0.url == url }.map(\.authorization) }
    }

    var probes: Int { lock.withLock { probeCount } }

    /// Things that happened, in the order they did: `closed <url>` when a transport's close
    /// returns, and whatever a test notes itself (a Keychain write).
    func note(_ event: String) { lock.withLock { log.append(event) } }
    var events: [String] { lock.withLock { log } }

    /// How many transports were ever built for `url`, and how many closes of one began.
    func transportsBuilt(for url: String) -> Int { lock.withLock { built.filter { $0.url == url }.count } }
    func closesBegun(for url: String) -> Int { lock.withLock { begun[url] ?? 0 } }

    /// Every close from here on begins — builds its request, counts — and then waits until
    /// `releaseCloses()`: a legacy `DELETE` the server sits on, for a test that orders a reload
    /// against the moment it returns.
    func holdCloses() { lock.withLock { closesHeld = true } }

    func releaseCloses() {
        let held: [CheckedContinuation<Void, Never>] = lock.withLock {
            closesHeld = false
            defer { heldCloses = [] }
            return heldCloses.map(\.continuation)
        }
        for continuation in held { continuation.resume() }
    }

    /// Lets the closes of `url` held NOW return, and goes on holding every other close — and
    /// every close begun from here on.
    func releaseCloses(for url: String) {
        let held: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { heldCloses.removeAll { $0.url == url } }
            return heldCloses.filter { $0.url == url }.map(\.continuation)
        }
        for continuation in held { continuation.resume() }
    }

    func closeBegan(_ url: String) async {
        let mustWait: Bool = lock.withLock {
            begun[url, default: 0] += 1
            return closesHeld
        }
        guard mustWait else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let held: Bool = lock.withLock {
                guard closesHeld else { return false }
                heldCloses.append((url, continuation))
                return true
            }
            if !held { continuation.resume() }
        }
    }

    /// Every transport whose close has not returned builds one request NOW, and this returns
    /// once each has: a request any of them could send at this moment, since the credential is
    /// read per request. Blocks its caller — the Keychain write that triggers it — on purpose,
    /// so nothing moves in between; the requests are built off the main actor.
    func probeOpenTransports() {
        let open: [RecordingTransport] = lock.withLock {
            probeCount += 1
            return built.filter(\.isOpen)
        }
        guard !open.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for transport in open { await transport.buildRequest() }
            done.signal()
        }
        done.wait()
    }
}

private nonisolated final class RecordingTransport: MCPTransport, @unchecked Sendable {
    let url: String
    private let inner: ScriptedTransport
    private let authorizer: any MCPAuthorizer
    private let recorder: AuthorizationRecorder
    private let lock = NSLock()
    private var closeReturned = false

    init(url: String, inner: ScriptedTransport, authorizer: any MCPAuthorizer, recorder: AuthorizationRecorder) {
        self.url = url
        self.inner = inner
        self.authorizer = authorizer
        self.recorder = recorder
    }

    var isOpen: Bool { lock.withLock { !closeReturned } }

    /// One request, built the way the HTTP transport builds each: the credential read now.
    func buildRequest() async {
        guard let address = URL(string: url) else { return }
        let request = (try? await authorizer.authorized(URLRequest(url: address))) ?? URLRequest(url: address)
        recorder.record(url: url, authorization: request.value(forHTTPHeaderField: "Authorization"))
    }

    func connect() async throws { try await inner.connect() }

    func adopt(era: MCPProtocolEra, protocolVersion: String) async {
        await inner.adopt(era: era, protocolVersion: protocolVersion)
    }

    @discardableResult
    func send(_ frame: MCPOutgoingFrame, hints: MCPSendHints) async throws -> MCPSendOutcome {
        await buildRequest()
        return try await inner.send(frame, hints: hints)
    }

    func events() async -> AsyncStream<MCPIncomingEvent> { await inner.events() }

    func cancel(requestID: JSONRPCID) async { await inner.cancel(requestID: requestID) }

    func close(budget: TimeInterval) async {
        await buildRequest()
        await recorder.closeBegan(url)
        await inner.close(budget: budget)
        lock.withLock { closeReturned = true }
        recorder.note("closed \(url)")
    }
}

/// The in-memory Keychain, with a hook run right after each write lands — outside any lock,
/// so the hook may read the store.
private nonisolated final class ProbingTokenStorage: SecureTokenStorage, @unchecked Sendable {
    private let inner = InMemorySecureTokenStorage()
    private let lock = NSLock()
    private var hook: (@Sendable (_ key: String, _ token: String?) -> Void)?
    private var refusedListing: KeychainError?

    var afterWrite: (@Sendable (_ key: String, _ token: String?) -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    /// When set, `accountNames` throws it while every value is still read and written — a
    /// Keychain that refuses the LISTING only, which `readError` cannot say (it refuses both).
    var listingError: KeychainError? {
        get { lock.withLock { refusedListing } }
        set { lock.withLock { refusedListing = newValue } }
    }

    /// The in-memory store's own write hook, per key and per kind.
    var writeFailure: (@Sendable (_ key: String, _ token: String?) -> KeychainError?)? {
        get { inner.writeFailure }
        set { inner.writeFailure = newValue }
    }

    func setToken(_ token: String?, forKey key: String) throws {
        try inner.setToken(token, forKey: key)
        afterWrite?(key, token)
    }

    func loadToken(forKey key: String) throws -> String? { try inner.loadToken(forKey: key) }

    func accountNames(withPrefix prefix: String) throws -> [String] {
        if let refusal = listingError { throw refusal }
        return try inner.accountNames(withPrefix: prefix)
    }
}

/// The first value a Keychain hook saw, kept for the test to read after.
private nonisolated final class RunningCount: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Int?
    var isTaken: Bool { lock.withLock { seen != nil } }
    var value: Int? { lock.withLock { seen } }
    func take(_ count: Int) { lock.withLock { if seen == nil { seen = count } } }
}

/// Set once, read from a Keychain hook — which runs under the in-memory store's lock, so it
/// must not call back into the store.
private nonisolated final class LandedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var landed = false
    func set() { lock.withLock { landed = true } }
    var isSet: Bool { lock.withLock { landed } }
}
