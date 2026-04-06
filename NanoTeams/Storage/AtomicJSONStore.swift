import Foundation

enum AtomicJSONStoreError: LocalizedError {
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

struct AtomicJSONStore {
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

        let tempURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp", isDirectory: false)
        try data.write(to: tempURL, options: [.atomic])

        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        } catch {
            // If target doesn't exist yet, move temp into place.
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                try fileManager.moveItem(at: tempURL, to: url)
            } catch {
                // Clean up temp file to avoid orphaned files on disk.
                try? fileManager.removeItem(at: tempURL)
                throw AtomicJSONStoreError.atomicReplaceFailed(url, underlying: error)
            }
        }
    }

    func writeIfMissing<T: Encodable>(_ value: T, to url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try write(value, to: url)
    }
}

