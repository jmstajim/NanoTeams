import Foundation

/// The list of servers the user configured, on disk.
///
/// **Application Support, not the work folder.** A server is a thing the user connected to,
/// not a property of a folder: re-adding the same server per project — and re-reviewing every tool
/// each time — would train the user to click through the review sheet, which is the one
/// control this whole design rests on. Which of these servers a given folder may reach is a
/// separate, per-folder file (`MCPFolderOverridesStore`).
///
/// **Owner-only, and the file holds no secret.** The directory is 0700 and the file 0600, and
/// `MCPHTTPConfig` names secret headers rather than carrying their values — so even a copied
/// file hands over nothing but URLs.
nonisolated final class MCPServerCatalogueStore: @unchecked Sendable {

    /// `~/Library/Application Support/NanoTeams/mcp/`.
    ///
    /// Beside `.nanoteams/`, not inside it, for the same reason `BenchmarkHistoryStore` is:
    /// that tree belongs to a WORK FOLDER, and this is machine-scoped state that must survive
    /// switching folders.
    static var defaultDirectory: URL { NTMSPaths.machineStorageURL(.mcp) }

    let directory: URL
    private let fileManager: FileManager
    private let store: AtomicJSONStore
    private let lock = NSLock()

    var fileURL: URL { directory.appendingPathComponent("servers.json", isDirectory: false) }
    /// Where `load()` moves a file it cannot read (`quarantine()`), and what `reading()` reads
    /// as "the servers it named are unknown" for as long as it is kept.
    var backupURL: URL { fileURL.appendingPathExtension("bak") }

    init(directory: URL = MCPServerCatalogueStore.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.store = AtomicJSONStore(fileManager: fileManager)
    }

    // MARK: - Reading

    /// The stored catalogue, or an empty one.
    ///
    /// A file that will not decode is MOVED ASIDE rather than deleted or repaired. Deleting
    /// would silently drop every server the user configured; repairing would mean guessing at
    /// which half of a hand-edited file was meant. The `.bak` keeps the evidence and the next
    /// save starts clean — and while it is kept, `reading()` says the list is not known, so the
    /// launch sweep deletes no secret a server only the `.bak` names may read.
    func load() -> MCPServerCatalogueFile {
        lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
            do {
                return try store.read(MCPServerCatalogueFile.self, from: fileURL)
            } catch {
                quarantine()
                return .empty
            }
        }
    }

    /// How the file reads, for a caller that must tell "no servers" from "do not know".
    enum Reading: Equatable, Sendable {
        /// The file exists and decoded, and no list moved aside is kept beside it.
        case read(MCPServerCatalogueFile)
        /// No file and no list moved aside: nothing was ever saved.
        case missing
        /// A file exists and could not be read or decoded, and was not moved aside.
        case unreadable
        /// A list moved aside (`servers.json.bak`) is still kept — by this launch's `load()` or
        /// an earlier one's — so the servers it named are unknown, whatever `servers.json` holds
        /// now: a file saved since names only what was saved since. Until someone removes the
        /// backup, once whatever it held is recovered or given up.
        case quarantined
    }

    /// The file as it reads now — for the orphaned-secret sweep (`MCPServerManager`), which
    /// deletes what no configured server reads and so must never take a list it could not read
    /// for an empty one. Side-effect free: an unreadable file is reported, not moved aside —
    /// that is `load()`'s, whose `.empty` means "nothing usable", which is right for running
    /// servers and wrong for deleting their secrets.
    ///
    /// Read off the disk, not remembered: the backup is what says a list was moved aside, in
    /// this process or any later one. Until the fourth pass of group D's review (2026-09-24) it
    /// was a flag of the store that moved the file, so the next launch read a list saved since
    /// the move as the whole truth and swept the secrets of every server only the backup named.
    func reading() -> Reading {
        lock.withLock {
            guard !fileManager.fileExists(atPath: backupURL.path) else { return .quarantined }
            guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
            do {
                return .read(try store.read(MCPServerCatalogueFile.self, from: fileURL))
            } catch {
                return .unreadable
            }
        }
    }

    var servers: [MCPServerConfig] { load().servers }

    /// Every server the catalogue names — the file as it reads now AND the list `load()` moved
    /// aside, while it is kept — moving nothing: what the role sandbox reserves the local ports of
    /// on every tool batch (`NTMSOrchestrator.seatbeltMCPServerPorts`). `load()` would quarantine a
    /// file that does not decode, so a person hand-editing it mid-task would lose it to `.bak` the
    /// next time a role ran a command; and an unreadable list must not shrink what is reserved.
    func serversForPortReservation() -> [MCPServerConfig] {
        lock.withLock {
            [fileURL, backupURL].flatMap { url in
                (try? store.read(MCPServerCatalogueFile.self, from: url))?.servers ?? []
            }
        }
    }

    func server(id: UUID) -> MCPServerConfig? { load().servers.first { $0.id == id } }

    // MARK: - Writing

    func save(_ file: MCPServerCatalogueFile) throws {
        try lock.withLock {
            try ensureDirectory()
            try store.write(file, to: fileURL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    /// Adds a server, or replaces the one with the same id. Order is the user's — a new server
    /// goes last, an edited one stays where it was.
    func upsert(_ config: MCPServerConfig) throws {
        var file = load()
        if let index = file.servers.firstIndex(where: { $0.id == config.id }) {
            file.servers[index] = config
        } else {
            file.servers.append(config)
        }
        try save(file)
    }

    func remove(id: UUID) throws {
        var file = load()
        file.servers.removeAll { $0.id == id }
        try save(file)
    }

    // MARK: - Internals

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path) else {
            // Idempotent hardening: an install that predates the permission, or a directory
            // the user created by hand, is fixed on the next save rather than never.
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return
        }
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: NTMSRepository.internalDirAttributes)
    }

    /// Moves an unreadable file to `servers.json.bak`, replacing any previous one — keeping a
    /// chain of them would hoard whatever was in the bad file forever. A move that fails leaves
    /// the file where it was, which `reading()` reports as `.unreadable`.
    private func quarantine() {
        try? fileManager.removeItem(at: backupURL)
        try? fileManager.moveItem(at: fileURL, to: backupURL)
    }
}
