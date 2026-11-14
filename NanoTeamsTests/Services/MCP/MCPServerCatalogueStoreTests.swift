import XCTest

@testable import NanoTeams

/// The configured-servers file: where it lives, who may read it, and what it does when it
/// cannot be read.
final class MCPServerCatalogueStoreTests: XCTestCase {

    private var directory: URL!
    private var store: MCPServerCatalogueStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-catalogue-\(UUID().uuidString)", isDirectory: true)
        store = MCPServerCatalogueStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        store = nil
        super.tearDown()
    }

    /// Writes raw bytes over the store's file, creating the directory first — the store
    /// itself only makes it on a save.
    private func writeRaw(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.fileURL)
    }

    private func config(slug: String = "folio", id: UUID = UUID()) throws -> MCPServerConfig {
        MCPServerConfig(
            id: id, slug: try XCTUnwrap(MCPServerSlug(slug)), displayName: slug,
            transport: .http(MCPHTTPConfig(urlString: "http://127.0.0.1:3845/mcp")))
    }

    // MARK: - Round trip

    func testAFolderThatWasNeverWrittenReadsAsEmpty() {
        XCTAssertTrue(store.load().servers.isEmpty)
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertNil(store.server(id: UUID()))
    }

    func testUpsertAddsThenReplacesInPlace() throws {
        let id = UUID()
        try store.upsert(try config(slug: "folio", id: id))
        try store.upsert(try config(slug: "other"))
        XCTAssertEqual(store.servers.map { $0.slug.rawValue }, ["folio", "other"])

        var edited = try XCTUnwrap(store.server(id: id))
        edited.isEnabled = true
        try store.upsert(edited)
        XCTAssertEqual(store.servers.map { $0.slug.rawValue }, ["folio", "other"],
                       "an edited server stays where it was")
        XCTAssertEqual(store.server(id: id)?.isEnabled, true)
    }

    func testRemoveDropsOnlyTheNamedServer() throws {
        let id = UUID()
        try store.upsert(try config(slug: "folio", id: id))
        try store.upsert(try config(slug: "other"))
        try store.remove(id: id)
        XCTAssertEqual(store.servers.map { $0.slug.rawValue }, ["other"])
        try store.remove(id: UUID())
        XCTAssertEqual(store.servers.count, 1, "removing a server that is not there is a no-op")
    }

    // MARK: - Permissions

    /// The file holds URLs and header NAMES; even so, it is owner-only, because the next
    /// field somebody adds will not be.
    func testTheDirectoryAndFileAreOwnerOnly() throws {
        try store.upsert(try config())
        let directoryMode = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default
            .attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    /// An install that predates the permission, or a directory the user made by hand, is
    /// hardened on the next save rather than never.
    func testAnExistingLooseDirectoryIsHardenedOnSave() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try store.upsert(try config())
        let mode = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    // MARK: - Corruption

    /// Deleting would silently drop every server the user configured; repairing would mean
    /// guessing which half of a hand-edited file was meant. The `.bak` keeps the evidence.
    func testAnUnreadableFileIsMovedAsideRatherThanDeleted() throws {
        try store.upsert(try config())
        try Data("{ not json".utf8).write(to: store.fileURL)

        XCTAssertTrue(store.load().servers.isEmpty)
        let backup = store.fileURL.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not json")
    }

    /// The read the role sandbox makes on every `bash` batch moves nothing — a person hand-editing
    /// the file mid-task must not lose it to `.bak` because a role ran a command — and still counts
    /// a list kept aside that decodes now, so an unreadable main file does not shrink what is
    /// reserved (review 2026-11-08).
    func testTheReadForPortReservationMovesNothingAndCountsTheListKeptAside() throws {
        try store.upsert(try config(slug: "main"))
        XCTAssertEqual(store.serversForPortReservation().map(\.slug.rawValue), ["main"])

        try writeRaw("{ half-edited")
        XCTAssertEqual(store.serversForPortReservation(), [], "nothing readable in the main file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path), "and it was not moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))

        // A list kept aside that decodes — written by the store's own encoder, then moved aside.
        try store.save(MCPServerCatalogueFile(servers: [try config(slug: "kept")]))
        try FileManager.default.moveItem(at: store.fileURL, to: store.backupURL)
        try writeRaw("{ half-edited")
        XCTAssertEqual(store.serversForPortReservation().map(\.slug.rawValue), ["kept"])
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "{ half-edited")
    }

    /// Keeping a chain of backups would hoard whatever was in the bad file forever.
    func testASecondCorruptionReplacesTheBackupRatherThanStacking() throws {
        try writeRaw("first")
        _ = store.load()
        try writeRaw("second")
        _ = store.load()
        XCTAssertEqual(
            try String(contentsOf: store.fileURL.appendingPathExtension("bak"), encoding: .utf8), "second")
    }

    /// A row whose slug cannot be used takes the whole file with it rather than being healed:
    /// healing would re-namespace tools the user already approved, and the pins are keyed by
    /// the old name.
    func testAFileWithAnUnusableSlugIsQuarantined() throws {
        try writeRaw(
            #"{"schemaVersion":1,"servers":[{"id":"7F1B9C1E-0000-0000-0000-000000000001","slug":"../evil","transport":{"kind":"http","http":{"urlString":"https://x/mcp"}}}]}"#)
        XCTAssertTrue(store.load().servers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("bak").path))
    }

    /// An unknown `approvalMode` (e.g. a future `"futureMode"` value after a downgrade) falls back to
    /// `.manual` — the strictest mode — rather than failing decoding and quarantining the whole
    /// `servers.json`.
    func testAnUnknownApprovalModeReadsAsManualInsteadOfQuarantiningTheCatalogue() throws {
        try writeRaw("""
        {"schemaVersion":1,"servers":[
          {"id":"7F1B9C1E-0000-0000-0000-000000000001","slug":"future_srv","displayName":"Future","transport":{"kind":"http","http":{"urlString":"https://x/mcp"}},"approvalMode":"futureMode"},
          {"id":"7F1B9C1E-0000-0000-0000-000000000002","slug":"semi_srv","displayName":"Semi","transport":{"kind":"http","http":{"urlString":"https://y/mcp"}},"approvalMode":"semiAutomatic"}
        ]}
        """)
        let loaded = store.load()
        XCTAssertEqual(loaded.servers.count, 2)
        XCTAssertEqual(loaded.servers.first?.approvalMode, .manual)
        XCTAssertEqual(loaded.servers.last?.approvalMode, .semiAutomatic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("bak").path))
        XCTAssertEqual(store.reading(), .read(loaded))
    }

    /// An unknown `authorization` mode (e.g. a future `"oauth"` value after a downgrade) falls
    /// back to `.none`, and an unknown transport `kind` (e.g. a future `"stdio"` row) is preserved
    /// in place without quarantining the whole `servers.json`.
    func testAnUnknownAuthorizationModeAndAnUnknownTransportDoNotQuarantineTheCatalogue() throws {
        try writeRaw("""
        {"schemaVersion":1,"servers":[
          {"id":"7F1B9C1E-0000-0000-0000-000000000001","slug":"oauth_srv","displayName":"OAuth","transport":{"kind":"http","http":{"urlString":"https://x/mcp","authorization":"oauth"}}},
          {"id":"7F1B9C1E-0000-0000-0000-000000000002","slug":"stdio_srv","displayName":"Stdio","transport":{"kind":"stdio","command":"npx"}},
          {"id":"7F1B9C1E-0000-0000-0000-000000000003","slug":"bearer_srv","displayName":"Bearer","transport":{"kind":"http","http":{"urlString":"https://y/mcp","authorization":"staticBearer"}}}
        ]}
        """)
        let loaded = store.load()
        XCTAssertEqual(loaded.servers.map(\.slug.rawValue), ["oauth_srv", "stdio_srv", "bearer_srv"])
        XCTAssertEqual(loaded.servers.first?.transport.http.authorization, MCPAuthorizationMode.none)
        XCTAssertEqual(loaded.servers.last?.transport.http.authorization, MCPAuthorizationMode.staticBearer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("bak").path))
        XCTAssertEqual(store.reading(), .read(loaded))
    }

    // MARK: - A reading that does not guess (third pass of group D's review, 2026-09-24)

    /// What the orphaned-secret sweep reads: the file's servers, or why there are none to read —
    /// no file, or one that will not decode — never an empty list standing in for "do not know".
    /// It moves nothing aside: that is `load()`'s.
    func testAReadingTellsAFileFromNoFileAndFromOneItCannotRead() throws {
        XCTAssertEqual(store.reading(), .missing)
        let config = try config()
        try store.upsert(config)
        XCTAssertEqual(store.reading(), .read(MCPServerCatalogueFile(servers: [config])))

        try writeRaw("{ not json")
        XCTAssertEqual(store.reading(), .unreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path), "a reading moves nothing aside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("bak").path))
    }

    /// While a list moved aside is kept, the servers it named are unknown — in this run and in
    /// every later one, whatever `servers.json` holds since: a new file names only what was saved
    /// after the move. The disk says so, not the store that moved it: a fresh store reads the
    /// same. Once the backup is removed — whatever it held recovered, or given up — the list
    /// reads as it is.
    ///
    /// RED until the fourth pass of group D's review (2026-09-24): "moved aside" was a flag of
    /// the store that moved the file, so the next launch read the new list as the whole truth.
    func testAListMovedAsideReadsQuarantinedUntilItsBackupIsRemoved() throws {
        try writeRaw("{ not json")
        XCTAssertTrue(store.load().servers.isEmpty, "premise: the file is moved aside")
        XCTAssertEqual(store.reading(), .quarantined)
        XCTAssertEqual(MCPServerCatalogueStore(directory: directory).reading(), .quarantined,
                       "no list at all beside the backup is not no servers")

        let config = try config()
        try store.upsert(config)
        XCTAssertEqual(store.reading(), .quarantined)
        XCTAssertEqual(MCPServerCatalogueStore(directory: directory).reading(), .quarantined,
                       "a later launch still does not know what the moved list named")
        try writeRaw("{ not json either")
        XCTAssertEqual(MCPServerCatalogueStore(directory: directory).reading(), .quarantined)

        try store.upsert(config)
        try FileManager.default.removeItem(at: store.fileURL.appendingPathExtension("bak"))
        XCTAssertEqual(store.reading(), .read(MCPServerCatalogueFile(servers: [config])))
        XCTAssertEqual(MCPServerCatalogueStore(directory: directory).reading(),
                       .read(MCPServerCatalogueFile(servers: [config])))
    }

    func testTheDefaultDirectorySitsBesideTheWorkFolderTreeNotInsideIt() {
        let path = MCPServerCatalogueStore.defaultDirectory.path
        XCTAssertTrue(path.hasSuffix("/NanoTeams/mcp"), path)
        XCTAssertFalse(path.contains(".nanoteams"), path)
    }
}
