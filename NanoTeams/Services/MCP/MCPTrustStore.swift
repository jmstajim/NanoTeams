import Foundation

/// What the user has approved, across launches.
///
/// **The pins are the whole point.** A tool reaches a prompt only while its live hash equals
/// the one a person read and said yes to; a changed hash makes it unreviewed again and drops
/// the `alwaysAllow` grant with it (`reconcile`). Everything in this file exists to make that
/// true even across a server restart, a rename, or a build that adds a field.
///
/// **Read once, then held.** The decoded file stays in memory after the first read and is
/// replaced by every successful write. It is asked on the main actor by every snapshot rebuild,
/// every Settings row and every approval card, and until 2026-09-23 each of those asks was a
/// full read and decode of the file — once per TOOL per rebuild. Holding it is sound because
/// this store is the file's only writer: the manager owns the one instance for the process, and
/// a second instance over the same directory sees the first one's writes only at its own first
/// read.
nonisolated final class MCPTrustStore: @unchecked Sendable {

    let directory: URL
    private let fileManager: FileManager
    private let store: AtomicJSONStore
    private let lock = NSLock()
    /// What the file holds, once read. Guarded by `lock`; replaced only after a write lands,
    /// so a failed write leaves it equal to the disk.
    private var held: MCPTrustFile?

    var fileURL: URL { directory.appendingPathComponent("trust.json", isDirectory: false) }

    init(directory: URL = MCPServerCatalogueStore.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.store = AtomicJSONStore(fileManager: fileManager)
    }

    // MARK: - Reading

    func load() -> MCPTrustFile {
        lock.withLock { loadLocked() }
    }

    func record(for serverID: UUID) -> MCPServerTrustRecord {
        load().records[serverID.uuidString] ?? .empty
    }

    func pin(serverID: UUID, tool: String) -> MCPToolPin? {
        record(for: serverID).toolPins[tool]
    }

    /// Where each live tool stands against what was approved.
    func pinDiff(serverID: UUID, liveHashes: [String: String]) -> MCPPinDiff {
        MCPPinDiff.between(liveHashes: liveHashes, pins: record(for: serverID).toolPins)
    }

    /// The held file, or the disk's on the first ask. Caller holds `lock`.
    private func loadLocked() -> MCPTrustFile {
        if let held { return held }
        let file = readFromDisk()
        held = file
        return file
    }

    /// An unreadable trust file is moved aside, not repaired. The consequence is deliberate
    /// and is the safe direction: every tool becomes unreviewed and the user is asked again.
    private func readFromDisk() -> MCPTrustFile {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            return try store.read(MCPTrustFile.self, from: fileURL)
        } catch {
            let backup = fileURL.appendingPathExtension("bak")
            try? fileManager.removeItem(at: backup)
            try? fileManager.moveItem(at: fileURL, to: backup)
            return .empty
        }
    }

    // MARK: - Writing

    /// Caller holds `lock`. Memory moves only once the disk has.
    private func saveLocked(_ file: MCPTrustFile) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: NTMSRepository.internalDirAttributes)
        }
        try store.write(file, to: fileURL)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        held = file
    }

    /// Read, change and write under ONE hold of the lock, so two writers cannot each read the
    /// same file and drop the other's change. A change that leaves the record as it was writes
    /// nothing — reconciling runs on every catalogue listing.
    private func mutate<Value>(
        serverID: UUID, _ body: (inout MCPServerTrustRecord) throws -> Value
    ) throws -> Value {
        try lock.withLock {
            var file = loadLocked()
            let before = file.records[serverID.uuidString] ?? .empty
            var record = before
            let result = try body(&record)
            guard record != before else { return result }
            file.records[serverID.uuidString] = record
            try saveLocked(file)
            return result
        }
    }

    /// Records a person's approval of one tool: the text they read, and the hash of exactly
    /// that text. The hash is DERIVED here rather than passed in, so a pin can never carry a
    /// text that is not the one its hash covers.
    ///
    /// `alwaysAllow` starts FALSE on every approval, including a re-approval after a change.
    /// A grant given for one text is not a grant for another, and carrying it across a change
    /// is exactly the rug pull the pin exists to catch.
    func approve(serverID: UUID, tool: String, canonicalForm: String, now: Date = Date()) throws {
        try approveAll(serverID: serverID, canonicalFormsByTool: [tool: canonicalForm], now: now)
    }

    func approveAll(serverID: UUID, canonicalFormsByTool: [String: String], now: Date = Date()) throws {
        try mutate(serverID: serverID) { record in
            record.approvedAt = record.approvedAt ?? now
            for (tool, form) in canonicalFormsByTool {
                record.setPin(MCPToolPin(
                    toolName: tool,
                    hash: MCPPinHasher.hash(canonicalForm: form),
                    approvedAt: now,
                    approvedCanonicalJSON: form))
            }
        }
    }

    /// Deletes the approval the person was looking at. `false` — and nothing deleted — when
    /// the pin now holds another text than `expectedHash`: that approval was given elsewhere,
    /// after the screen was drawn. No pin at all is `true`: nothing is left to revoke.
    @discardableResult
    func revoke(serverID: UUID, tool: String, expectedHash: String) throws -> Bool {
        try mutate(serverID: serverID) { record in
            guard let pin = record.toolPins[tool] else { return true }
            guard pin.hash == expectedHash else { return false }
            record.toolPins[tool] = nil
            return true
        }
    }

    /// Records that the person refused the text at `hash`. A rejected rewrite keeps the old
    /// approval exactly as it was — its hash and its recorded text, so the tool still reads
    /// as changed against what was read — and loses its standing grant. `false`, and nothing
    /// written, when `hash` IS the approved text (`MCPServerTrustRecord.reject`).
    @discardableResult
    func reject(serverID: UUID, tool: String, hash: String) throws -> Bool {
        try mutate(serverID: serverID) { record in
            guard record.reject(tool: tool, hash: hash) else { return false }
            if var pin = record.toolPins[tool], pin.alwaysAllow {
                pin.alwaysAllow = false
                record.toolPins[tool] = pin
            }
            return true
        }
    }

    /// Grants or withdraws "run this without asking".
    ///
    /// A GRANT is bound to `expectedHash` — the text on the screen that granted it — and is
    /// refused unless the pin still holds that text: a tool that moved between the screen
    /// being drawn and the tap landing gets no grant at all. A WITHDRAWAL is never refused:
    /// it fails closed, and a stale switch that could not turn a grant off would be the unsafe
    /// direction. `true` when the pin now reads as asked.
    @discardableResult
    func setAlwaysAllow(serverID: UUID, tool: String, expectedHash: String, allowed: Bool) throws -> Bool {
        try mutate(serverID: serverID) { record in
            guard var pin = record.toolPins[tool] else { return false }
            if allowed, pin.hash != expectedHash { return false }
            pin.alwaysAllow = allowed
            record.toolPins[tool] = pin
            return true
        }
    }

    // MARK: - Catalogue drift

    /// Reconciles the pins against what the server publishes now, tool name → live hash.
    ///
    /// A tool that vanished is MARKED, not dropped: a restarting server shows an empty
    /// catalogue for a moment, and pruning on sight would send the user back through the
    /// review sheet after every server relaunch. One that comes back has its mark cleared.
    ///
    /// A tool published at another hash than its pin loses its standing grant, on disk, here —
    /// so a server that restores the approved text later does not get the grant back with it.
    func reconcile(serverID: UUID, liveHashes: [String: String], now: Date = Date()) throws {
        try mutate(serverID: serverID) { record in
            for (tool, var pin) in record.toolPins {
                let liveHash = liveHashes[tool]
                let before = pin
                if liveHash != nil, pin.removedAt != nil {
                    pin.removedAt = nil
                } else if liveHash == nil, pin.removedAt == nil {
                    pin.removedAt = now
                }
                if let liveHash, liveHash != pin.hash {
                    pin.alwaysAllow = false
                }
                if pin != before { record.toolPins[tool] = pin }
            }
        }
    }

    /// Drops pins whose tool has been gone longer than the retention window, across every
    /// server. Returns how many went, so the caller can log a sweep that did something.
    @discardableResult
    func pruneRemoved(now: Date = Date(), retention: TimeInterval = MCPConstants.removedPinRetention) throws -> Int {
        try lock.withLock {
            var file = loadLocked()
            var pruned = 0
            for (serverKey, var record) in file.records {
                for (tool, pin) in record.toolPins where pin.isPrunable(now: now, retention: retention) {
                    record.toolPins[tool] = nil
                    pruned += 1
                }
                file.records[serverKey] = record
            }
            guard pruned > 0 else { return 0 }
            try saveLocked(file)
            return pruned
        }
    }

    // MARK: - Era cache

    /// Remembers which revision the probe settled on, so the next connect can skip it. A
    /// cache, never a belief — the client re-probes once when the cached era fails.
    func cacheEra(serverID: UUID, era: MCPProtocolEra) throws {
        try mutate(serverID: serverID) { $0.cachedEra = era }
    }

    func cachedEra(serverID: UUID) -> MCPProtocolEra? { record(for: serverID).cachedEra }

    // MARK: - Forgetting

    /// Deleting a server takes its approvals with it — a later server reusing the id would
    /// otherwise inherit a stranger's pins — and so does pointing it at another host
    /// (`MCPServerManager.save`): the approvals were given to the old address.
    func forget(serverID: UUID) throws {
        try lock.withLock {
            var file = loadLocked()
            guard file.records[serverID.uuidString] != nil else { return }
            file.records[serverID.uuidString] = nil
            try saveLocked(file)
        }
    }
}
