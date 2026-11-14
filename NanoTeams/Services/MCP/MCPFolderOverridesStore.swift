import Foundation

/// Which of the configured servers this work folder may reach.
///
/// Separate file, separate lifetime, separate owner: the catalogue is machine-scoped and lives
/// in Application Support, while this one is a fact about one folder and lives inside it,
/// under `internal/` where the LLM's file tools cannot see it.
///
/// **Stored as a DISABLED list, never an enabled one.** With an enabled list, a server added
/// later would be silently absent from every folder that predates it — and "the tool is not
/// there" is the hardest failure in this design to diagnose, because nothing is wrong
/// anywhere. Per-folder sets are also the mitigation for cross-server shadowing: a folder that
/// needs a design server does not also carry a brokerage one.
nonisolated final class MCPFolderOverridesStore: @unchecked Sendable {

    private let fileURL: URL
    private let fileManager: FileManager
    private let store: AtomicJSONStore
    private let lock = NSLock()

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.store = AtomicJSONStore(fileManager: fileManager)
    }

    convenience init(paths: NTMSPaths, fileManager: FileManager = .default) {
        self.init(fileURL: paths.mcpFolderJSON, fileManager: fileManager)
    }

    /// A folder that has never disabled anything has no file, and that is the common case —
    /// so an absent file is an answer (`.empty`), not a failure.
    func load() -> MCPFolderOverrides {
        lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
            return (try? store.read(MCPFolderOverrides.self, from: fileURL)) ?? .empty
        }
    }

    func save(_ overrides: MCPFolderOverrides) throws {
        try lock.withLock {
            let directory = fileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: NTMSRepository.internalDirAttributes)
            }
            try store.write(overrides, to: fileURL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    func setServer(_ serverID: UUID, enabled: Bool) throws {
        var overrides = load()
        if enabled {
            overrides.disabledServerIDs.remove(serverID)
        } else {
            overrides.disabledServerIDs.insert(serverID)
        }
        try save(overrides)
    }

    func allows(_ serverID: UUID) -> Bool { load().allows(serverID) }
}
