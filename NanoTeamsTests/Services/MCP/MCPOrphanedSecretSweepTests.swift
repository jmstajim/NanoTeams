import XCTest

@testable import NanoTeams

/// The once-per-launch sweep of MCP secrets no configured server reads: what a refused Add left
/// under an id no server has, what a removal whose Keychain clear was refused left behind, and
/// every account spelled before an account named its origin.
///
/// It deletes, so everything here is about when it must NOT: a manager nobody opted in, a server
/// list that is missing, moved aside (in this launch or kept from an earlier one), unreadable or
/// written by a newer version, a Keychain that will not list, a server the open folder blocks —
/// and an Add that lands while it runs.
@MainActor
final class MCPOrphanedSecretSweepTests: XCTestCase {

    private var root: URL!
    private var catalogueDirectory: URL!
    private var catalogue: MCPServerCatalogueStore!
    private var storage: SweepProbeStorage!
    private var manager: MCPServerManager!
    private var frozen: URL?

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-sweep-\(UUID().uuidString)", isDirectory: true)
        catalogueDirectory = root.appendingPathComponent("catalogue", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogueDirectory, withIntermediateDirectories: true)
        catalogue = MCPServerCatalogueStore(directory: catalogueDirectory)
        storage = SweepProbeStorage()
        manager = makeManager(sweeps: true)
    }

    override func tearDown() async throws {
        storage?.onListing = nil
        await manager?.shutdown(budget: 0)
        if let frozen { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: frozen.path) }
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        catalogueDirectory = nil
        catalogue = nil
        storage = nil
        manager = nil
        frozen = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A manager over the test's catalogue and Keychain double, whose connections never reach a
    /// socket. `sweeps` is the opt-in the app's `.live` environment carries and nothing else.
    private func makeManager(sweeps: Bool) -> MCPServerManager {
        var environment = MCPEnvironment(
            makeTransport: { _, _, _ in NeverConnectingTransport() },
            secretStorage: storage,
            trustDirectory: root.appendingPathComponent("trust", isDirectory: true),
            writesRPCLog: false)
        environment.sweepsOrphanedSecrets = sweeps
        return MCPServerManager(catalogueStore: catalogue, environment: environment)
    }

    private func server(
        _ slug: String, url: String = "https://a.test/mcp", headers: [String] = [],
        authorization: MCPAuthorizationMode = .staticBearer, enabled: Bool = true
    ) throws -> MCPServerConfig {
        MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug(slug)), displayName: slug,
            transport: .http(MCPHTTPConfig(urlString: url, secretHeaderNames: headers, authorization: authorization)),
            isEnabled: enabled)
    }

    private func seed(_ accounts: [String]) throws {
        for account in accounts { try storage.setToken("v", forKey: account) }
    }

    /// Every account the Keychain double holds — read past its counter and its refusal.
    private var held: [String] { storage.everyAccount }

    /// A configured server and an account left under an id no server has.
    private func aServerAndAnOrphan() throws -> (server: MCPServerConfig, orphan: String) {
        let configured = try server("folio")
        try catalogue.upsert(configured)
        let orphan = try server("gone").bearerSecretKey
        try seed([configured.bearerSecretKey, orphan])
        return (configured, orphan)
    }

    // MARK: - What it deletes

    /// Every account spelled under a server id that no configured server reads — switched on or
    /// off — goes; each server's own accounts stay; nothing not spelled under a server id is
    /// touched. Once per manager: later folder opens and reloads list nothing again.
    func testAnOptedInManagerSweepsWhatNoServerReadsOnceAfterItsFirstFolderOpen() async throws {
        let enabled = try server("folio", headers: ["X-Api-Key"])
        let disabled = try server("ledger", url: "https://b.test/mcp", headers: ["X-Tenant"], authorization: .none, enabled: false)
        try catalogue.upsert(enabled)
        try catalogue.upsert(disabled)
        let gone = try server("gone", headers: ["X-Api-Key"])
        var elsewhere = enabled
        elsewhere.transport = .http(MCPHTTPConfig(urlString: "https://old.test/mcp", authorization: .staticBearer))
        let kept = [
            enabled.bearerSecretKey, enabled.secretKey(forHeader: "X-Api-Key"), disabled.secretKey(forHeader: "X-Tenant"),
            "http://localhost:1234", "\(enabled.id.uuidString.lowercased())/bearer", "not-a-server/bearer",
        ]
        let orphans = [
            gone.bearerSecretKey, gone.secretKey(forHeader: "X-Api-Key"),
            enabled.secretAccountPrefix + "bearer", elsewhere.bearerSecretKey, disabled.bearerSecretKey,
        ]
        try seed(kept + orphans)

        await manager.setWorkFolder(paths: nil)

        XCTAssertEqual(held, kept.sorted())
        XCTAssertEqual(storage.listings, 1)
        XCTAssertNil(manager.lastError)

        try seed([gone.bearerSecretKey])
        await manager.setWorkFolder(paths: nil)
        await manager.reload()
        XCTAssertEqual(storage.listings, 1, "once per manager")
        XCTAssertTrue(held.contains(gone.bearerSecretKey))
    }

    /// A server the OPEN folder blocks is still configured: its secrets stay — whether it is
    /// switched on app-wide or off as well. A folder's rule is about that folder, and the
    /// secrets are app-wide: the server runs in every other folder on exactly these accounts.
    /// What goes is what no configured server reads at all.
    ///
    /// The first sweep test opens no folder, so every server is allowed there; until the fourth
    /// pass of group D's review (2026-09-24) a sweep fed the FOLDER's list — mutant V14b, which
    /// survived every class — deleted a blocked server's token at launch, and it read "Needs a
    /// token" everywhere else.
    func testAServerBlockedInTheOpenFolderKeepsItsSecrets() async throws {
        let blocked = try server("folio", headers: ["X-Api-Key"])
        let blockedAndOff = try server("ledger", url: "https://b.test/mcp", headers: ["X-Tenant"], enabled: false)
        let allowed = try server("atlas", url: "https://c.test/mcp")
        for config in [blocked, blockedAndOff, allowed] { try catalogue.upsert(config) }
        let paths = NTMSPaths(workFolderRoot: root.appendingPathComponent("folder", isDirectory: true))
        let folderRules = MCPFolderOverridesStore(paths: paths)
        try folderRules.setServer(blocked.id, enabled: false)
        try folderRules.setServer(blockedAndOff.id, enabled: false)
        let kept = blocked.allSecretKeys + blockedAndOff.allSecretKeys + allowed.allSecretKeys
        XCTAssertEqual(kept.count, 5, "premise: every account each server reads")
        let orphan = try server("gone").bearerSecretKey
        try seed(kept + [orphan])

        await manager.setWorkFolder(paths: paths)

        XCTAssertFalse(folderRules.allows(blocked.id), "premise: the open folder blocks it")
        XCTAssertEqual(manager.serverRows.map(\.isAllowedInThisFolder), [false, false, true],
                       "premise: the manager read the folder's rules before the sweep")
        XCTAssertEqual(storage.listings, 1)
        XCTAssertEqual(held, kept.sorted(), "a server the folder blocks lost a secret, or the orphan stayed")
    }

    // MARK: - When it must not

    /// A manager nobody opted in — every test, preview and headless run — never lists, so never
    /// deletes: above all, never from the real Keychain.
    func testAManagerNotOptedInListsNothing() async throws {
        let (configured, orphan) = try aServerAndAnOrphan()
        await manager.shutdown(budget: 0)
        manager = makeManager(sweeps: false)

        await manager.setWorkFolder(paths: nil)

        XCTAssertEqual(storage.listings, 0)
        XCTAssertEqual(held, [configured.bearerSecretKey, orphan].sorted())
    }

    /// No server list on disk means "do not know", never "no servers".
    func testWithNoServerListOnDiskNothingIsSwept() async throws {
        let orphan = try server("gone").bearerSecretKey
        try seed([orphan])
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogue.fileURL.path), "premise")

        await manager.setWorkFolder(paths: nil)

        XCTAssertEqual(held, [orphan])
    }

    /// A server list the first reload had to move aside names servers nobody can read any more —
    /// not no servers.
    func testAServerListMovedAsideSweepsNothing() async throws {
        let (configured, orphan) = try aServerAndAnOrphan()
        try Data("{ not json".utf8).write(to: catalogue.fileURL)

        await manager.setWorkFolder(paths: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogue.fileURL.appendingPathExtension("bak").path),
                      "premise: the reload moved the file aside")
        XCTAssertEqual(held, [configured.bearerSecretKey, orphan].sorted())
    }

    /// A list moved aside at an EARLIER launch is still kept beside one saved since, and the
    /// servers it named are still unknown: the new list reads cleanly and names one server, and
    /// the sweep still deletes nothing — not the orphan, which may be the moved list's.
    ///
    /// RED until the fourth pass of group D's review (2026-09-24): "moved aside" was a flag of
    /// the store that moved it, so a fresh launch read the new list as the whole truth and
    /// deleted the secrets of every server only the backup still named.
    func testAListMovedAsideAtAnEarlierLaunchSweepsNothing() async throws {
        let (configured, orphan) = try aServerAndAnOrphan()
        try Data("{ not json".utf8).write(to: catalogue.fileURL.appendingPathExtension("bak"))
        XCTAssertEqual(catalogue.load().servers.map(\.id), [configured.id],
                       "premise: the list beside the backup reads cleanly")

        await manager.setWorkFolder(paths: nil)

        XCTAssertEqual(manager.serverRows.map(\.config.id), [configured.id], "premise: the list ran")
        XCTAssertEqual(held, [configured.bearerSecretKey, orphan].sorted())
    }

    /// One that cannot be read and cannot be moved aside either.
    func testAServerListThatCannotBeReadSweepsNothing() async throws {
        let (configured, orphan) = try aServerAndAnOrphan()
        try Data("{ not json".utf8).write(to: catalogue.fileURL)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: catalogueDirectory.path)
        frozen = catalogueDirectory

        await manager.setWorkFolder(paths: nil)

        XCTAssertEqual(catalogue.reading(), .unreadable, "premise: the file is still there, and unreadable")
        XCTAssertEqual(held, [configured.bearerSecretKey, orphan].sorted())
    }

    /// A list a newer version wrote may keep its servers where this one does not look — and this
    /// one's tolerant decoding would read that as no servers.
    func testAServerListANewerVersionWroteSweepsNothing() async throws {
        let (configured, orphan) = try aServerAndAnOrphan()
        try catalogue.save(MCPServerCatalogueFile(
            schemaVersion: MCPServerCatalogueFile.currentSchemaVersion + 1, servers: [configured]))

        await manager.setWorkFolder(paths: nil)

        XCTAssertEqual(held, [configured.bearerSecretKey, orphan].sorted())
    }

    /// A Keychain that refuses the listing skips the sweep quietly: the folder opens, no error
    /// reaches the list pane, and nothing is deleted. It is not tried again in this run.
    func testARefusedListingSkipsQuietly() async throws {
        let (configured, orphan) = try aServerAndAnOrphan()
        storage.listingError = .unhandled(-25308)

        await manager.setWorkFolder(paths: nil)
        await manager.setWorkFolder(paths: nil)

        XCTAssertEqual(storage.listings, 1)
        XCTAssertNil(manager.lastError)
        storage.listingError = nil
        XCTAssertEqual(held, [configured.bearerSecretKey, orphan].sorted())
        XCTAssertEqual(manager.serverRows.map(\.config.id), [configured.id])
    }

    // MARK: - A skipped sweep says why (fifth pass of group D's review, 2026-09-24)
    //
    // The sweep logs through `print`, as every console line of the app does — there is no log
    // seam to capture. What it reads the list as, and the ONE line it logs when it will not
    // run, is `MCPServerManager.orphanedSecretSweepReading(of:)`; the sweep prints that line
    // and nothing else, so these tests pin the line there, from the list's real states on disk.

    /// The line, when the reading is a skip that logs one.
    private func skipLine() -> String? {
        guard case .skipped(let line) = MCPServerManager.orphanedSecretSweepReading(of: catalogue) else { return nil }
        return line
    }

    /// A list moved aside is kept: the sweep says where it is and that removing it lets the
    /// sweep run — the only way anyone learns there is a `.bak` to deal with.
    ///
    /// RED until the fifth pass of group D's review (2026-09-24): every launch skipped in
    /// silence for as long as the backup was kept.
    func testAListMovedAsideSkipsTheSweepWithALineNamingTheBackup() throws {
        try catalogue.upsert(try server("folio"))
        try Data("{ not json".utf8).write(to: catalogue.backupURL)
        XCTAssertEqual(catalogue.reading(), .quarantined, "premise")

        let line = try XCTUnwrap(skipLine(), "a skip over a list moved aside logged nothing")

        XCTAssertTrue(line.hasPrefix("[MCPServerManager] WARNING: orphaned-secret sweep skipped"), line)
        XCTAssertTrue(line.contains(catalogue.backupURL.path), line)
        XCTAssertTrue(line.contains("removed"), line)
    }

    /// A list that cannot be read: the line names the file.
    ///
    /// RED until the fifth pass of group D's review (2026-09-24), as the backup above.
    func testAnUnreadableListSkipsTheSweepWithALineNamingTheFile() throws {
        try Data("{ not json".utf8).write(to: catalogue.fileURL)
        XCTAssertEqual(catalogue.reading(), .unreadable, "premise")

        let line = try XCTUnwrap(skipLine(), "a skip over an unreadable list logged nothing")

        XCTAssertTrue(line.hasPrefix("[MCPServerManager] WARNING: orphaned-secret sweep skipped"), line)
        XCTAssertTrue(line.contains(catalogue.fileURL.path), line)
        XCTAssertTrue(line.contains("cannot be read"), line)
    }

    /// A list a newer version wrote: the line names the file and both schemas.
    ///
    /// RED until the fifth pass of group D's review (2026-09-24), as the backup above.
    func testAListANewerVersionWroteSkipsTheSweepWithALineNamingTheVersions() throws {
        let newer = MCPServerCatalogueFile.currentSchemaVersion + 1
        try catalogue.save(MCPServerCatalogueFile(schemaVersion: newer, servers: [try server("folio")]))

        let line = try XCTUnwrap(skipLine(), "a skip over a newer list logged nothing")

        XCTAssertTrue(line.hasPrefix("[MCPServerManager] WARNING: orphaned-secret sweep skipped"), line)
        XCTAssertTrue(line.contains(catalogue.fileURL.path), line)
        XCTAssertTrue(line.contains("newer version"), line)
        XCTAssertTrue(line.contains("schema \(newer)"), line)
        XCTAssertTrue(line.contains("reads \(MCPServerCatalogueFile.currentSchemaVersion)"), line)
    }

    /// No list was ever saved — a fresh install: the sweep skips, and says nothing, because
    /// nothing is wrong.
    func testAListNeverSavedSkipsTheSweepInSilence() {
        XCTAssertEqual(catalogue.reading(), .missing, "premise")

        XCTAssertEqual(MCPServerManager.orphanedSecretSweepReading(of: catalogue), .skipped(logLine: nil))
    }

    /// A list read cleanly is swept, and nothing is logged about it: the reading is every
    /// configured server.
    func testAListReadCleanlyIsSweptWithNoLine() throws {
        let folio = try server("folio")
        let ledger = try server("ledger", url: "https://b.test/mcp", enabled: false)
        try catalogue.upsert(folio)
        try catalogue.upsert(ledger)

        XCTAssertEqual(MCPServerManager.orphanedSecretSweepReading(of: catalogue), .servers([folio, ledger]))
    }

    // MARK: - An Add while it runs

    /// An Add asked while the sweep is listing — here, for the very id a refused earlier attempt
    /// left a token under — lands after the sweep, and keeps what it wrote. The sweep decides
    /// and deletes in ONE main-actor turn, and a save writes its Keychain and its list in one
    /// too, so neither can start inside the other: the leftover is swept, the Add's own token
    /// is not.
    func testAnAddAskedWhileTheSweepListsKeepsWhatItWrote() async throws {
        let (configured, orphan) = try aServerAndAnOrphan()
        let added = try server("added", url: "https://x.test/mcp")
        try storage.setToken("first attempt", forKey: added.bearerSecretKey)
        let adding = AddBox()
        storage.onListing = { [manager] in
            adding.task = Task { @MainActor in
                try await manager?.save(added, secrets: MCPServerSecretEdit(bearer: "second attempt"))
            }
        }

        await manager.setWorkFolder(paths: nil)
        storage.onListing = nil
        try await XCTUnwrap(adding.task, "premise: the Add was asked while the sweep listed").value

        XCTAssertEqual(try storage.loadToken(forKey: added.bearerSecretKey), "second attempt")
        XCTAssertNil(try storage.loadToken(forKey: orphan))
        XCTAssertEqual(try storage.loadToken(forKey: configured.bearerSecretKey), "v")
        XCTAssertEqual(catalogue.servers.map(\.id), [configured.id, added.id])
    }
}

// MARK: - Doubles

/// The in-memory Keychain, counting its listings, with a hook run right after one — outside any
/// lock — and a refusal of the listing alone.
private nonisolated final class SweepProbeStorage: SecureTokenStorage, @unchecked Sendable {
    private let inner = InMemorySecureTokenStorage()
    private let lock = NSLock()
    private var count = 0
    private var hook: (@Sendable () -> Void)?
    private var refusal: KeychainError?

    var listings: Int { lock.withLock { count } }

    /// What the store holds, for an assertion: not a listing the code under test made.
    var everyAccount: [String] { (try? inner.accountNames(withPrefix: "")) ?? [] }

    var onListing: (@Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    var listingError: KeychainError? {
        get { lock.withLock { refusal } }
        set { lock.withLock { refusal = newValue } }
    }

    func setToken(_ token: String?, forKey key: String) throws { try inner.setToken(token, forKey: key) }

    func loadToken(forKey key: String) throws -> String? { try inner.loadToken(forKey: key) }

    func accountNames(withPrefix prefix: String) throws -> [String] {
        let (hook, refusal): ((@Sendable () -> Void)?, KeychainError?) = lock.withLock {
            count += 1
            return (self.hook, self.refusal)
        }
        if let refusal { throw refusal }
        let names = try inner.accountNames(withPrefix: prefix)
        hook?()
        return names
    }
}

/// Where the listing hook leaves the Add it started, for the test to await.
private nonisolated final class AddBox: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Task<Void, any Error>?
    var task: Task<Void, any Error>? {
        get { lock.withLock { started } }
        set { lock.withLock { started = newValue } }
    }
}
