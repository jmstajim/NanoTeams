import Foundation

nonisolated enum AtomicJSONStoreError: LocalizedError {
    case unableToCreateDirectory(URL)
    case atomicReplaceFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unableToCreateDirectory(let url):
            "Unable to create directory: \(url.path)"
        case .atomicReplaceFailed(let url, let underlying):
            "Atomic write failed for \(url.lastPathComponent): \(underlying.localizedDescription)"
        }
    }
}

nonisolated struct AtomicJSONStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        encoder: JSONEncoder = JSONCoderFactory.makePersistenceEncoder(),
        decoder: JSONDecoder = JSONCoderFactory.makeDateDecoder()
    ) {
        self.fileManager = fileManager
        self.encoder = encoder
        self.decoder = decoder
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw AtomicJSONStoreError.unableToCreateDirectory(dir)
            }
        }

        let data = try encoder.encode(value)

        // Unique-per-call temp filename. A shared name (`.task.json.tmp`) raced
        // under concurrent writes to the same target: writer A would create
        // `.task.json.tmp`, writer B would overwrite it via `Data.write(.atomic)`,
        // writer A's `replaceItemAt` would then move B's bytes into target
        // (silently dropping A's write), and B's `replaceItemAt` would fail
        // with `atomicReplaceFailed` because the temp had already been
        // consumed. Net effect: dropped writes plus surfaced errors. Per-call
        // UUID temp names eliminate the contention.
        let tempURL = dir.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try data.write(to: tempURL, options: [.atomic])

        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        } catch {
            // Fall back to remove-then-move.
            //
            // NOT "the target doesn't exist yet", which is what this comment used to claim:
            // measured on APFS/macOS 26, `replaceItemAt` succeeds against a MISSING target, and
            // even against a target that is a non-empty directory. What it actually refuses is a
            // target it cannot write — a read-only file, a read-only parent directory, or a
            // dangling symlink (all NSCocoaErrorDomain 513 / 4). Of those, only the read-only
            // FILE is rescuable here: the directory is still writable, so the old file can be
            // removed and the temp moved into its place. The other two fail again below and
            // surface as `atomicReplaceFailed`, which is correct — the volume really is refusing.
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                try fileManager.moveItem(at: tempURL, to: url)
            } catch {
                // Both atomic-replace AND fallback move failed — surface the
                // primary error to the caller and log any cleanup failure
                // separately so we don't lose the diagnostic. (Bootstrap-time
                // sweep in `NTMSRepository+Bootstrap.swift` reaps any orphan
                // that the cleanup couldn't remove on the next app launch.)
                do {
                    try fileManager.removeItem(at: tempURL)
                } catch {
                    print("[AtomicJSONStore] WARNING: could not clean orphan temp "
                        + "\(tempURL.lastPathComponent): \(error)")
                }
                throw AtomicJSONStoreError.atomicReplaceFailed(url, underlying: error)
            }
        }
    }

    func writeIfMissing<T: Encodable>(_ value: T, to url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try write(value, to: url)
    }
}

