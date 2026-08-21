import Foundation

/// Append-only JSONL file primitive — one line per record, `seekToEnd` + one
/// `write` per append, O(1) in the file's size.
///
/// Three loggers grew private copies of this body (`ToolCallLogger`,
/// `BenchmarkHistoryStore` — whose doc comment admits copying it — and, worst,
/// `NetworkLogger`, which instead decoded the whole array, appended, pretty-print
/// re-encoded and atomically rewrote the file on EVERY record: measured on a real
/// 33-record run log, 5.77 MB written and parsed to produce a 327 KB file, n/2
/// amplification with no ceiling because nothing caps a run's record count).
///
/// **Serialization is per FILE, not per logger instance.** The registry hands out
/// one serial queue per canonical path, because instances do not map 1:1 onto
/// files: `LLMExecutionService` builds a `NetworkLogger` per step, team
/// generation builds its own for the same run file, and parallel roles of one run
/// (CLAUDE.md #45) write concurrently — with per-instance queues the whole-file
/// read-modify-write interleaved and LOST records; with line appends the damage
/// would shrink to a torn line, and with the per-file queue it is gone. The file
/// is the resource, so the lock lives on the file (precedent for the process-wide
/// registry: `MonotonicClock.shared`).
///
/// Failure trade, inherited from `BenchmarkHistoryStore`'s doc: one corrupt line
/// costs one row (`decodeLines` skips it), where the array shape silently
/// truncated the ENTIRE file to `[]` on one bad byte.
nonisolated enum JSONLFileLog {

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var queues: [String: DispatchQueue] = [:]
    /// Paths whose torn tail (if any) has been repaired this process — the
    /// repair runs once, on the first append that touches the file.
    nonisolated(unsafe) private static var repairedPaths: Set<String> = []

    /// The serial queue that owns `url`'s file. Callers that need a multi-step
    /// critical section (read + filter + rewrite) run it via `rewrite`.
    private static func queue(for url: URL) -> DispatchQueue {
        let key = url.standardizedFileURL.path
        return registryLock.withLock {
            if let existing = queues[key] { return existing }
            let fresh = DispatchQueue(label: "com.nanoteams.jsonlfilelog")
            queues[key] = fresh
            return fresh
        }
    }

    /// True exactly once per path per process — the caller then owns the repair.
    private static func claimTailRepair(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        return registryLock.withLock { repairedPaths.insert(key).inserted }
    }

    /// Byte length of the intact prefix: everything up to and including the last
    /// newline. A crash mid-append leaves a partial line with NO trailing
    /// newline; `decodeLines` already skips it (loss = one record), but the NEXT
    /// append would otherwise concatenate onto it and destroy TWO records — the
    /// partial one and its own. Backward chunked scan from the end, so the cost
    /// is O(torn line), not O(file).
    private static func intactPrefixLength(_ handle: FileHandle) throws -> UInt64 {
        let end = try handle.seekToEnd()
        guard end > 0 else { return 0 }
        let chunkSize: UInt64 = 64 * 1024
        var searchEnd = end
        while searchEnd > 0 {
            let start = searchEnd > chunkSize ? searchEnd - chunkSize : 0
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(searchEnd - start)) ?? Data()
            if let idx = data.lastIndex(of: 0x0A) {
                return start + UInt64(idx) + 1
            }
            searchEnd = start
        }
        return 0
    }

    /// Appends one record as one line. Best-effort: logging must never fail the
    /// operation being logged (the contract all three call sites already had).
    static func append<T: Encodable>(
        _ record: T,
        to url: URL,
        encoder: JSONEncoder,
        fileManager: FileManager = .default,
        directoryAttributes: [FileAttributeKey: Any]? = nil
    ) {
        queue(for: url).sync {
            do {
                var line = try encoder.encode(record)
                line.append(0x0A)

                let parent = url.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(
                        at: parent, withIntermediateDirectories: true,
                        attributes: directoryAttributes)
                }
                if !fileManager.fileExists(atPath: url.path) {
                    fileManager.createFile(atPath: url.path, contents: nil)
                }
                // forUpdating, not forWritingTo: the one-shot torn-tail repair
                // below READS the tail to find the last newline.
                let handle = try FileHandle(forUpdating: url)
                defer { try? handle.close() }
                if claimTailRepair(url) {
                    let intact = try intactPrefixLength(handle)
                    let end = try handle.seekToEnd()
                    if intact < end { try handle.truncate(atOffset: intact) }
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                #if DEBUG
                print("[JSONLFileLog] append to \(url.lastPathComponent) failed: \(error)")
                #endif
            }
        }
    }

    /// Atomically replaces the file's whole content — the multi-step critical
    /// section (read + transform + rewrite) the per-file queue exists for:
    /// compaction, cold-state rebuilds, and any "filter then persist" pass.
    /// Best-effort like `append`; returns false when the write failed. The
    /// fresh content is intact by construction, so the path's torn-tail repair
    /// is marked done.
    @discardableResult
    static func rewrite(
        _ url: URL,
        with data: Data,
        fileManager: FileManager = .default,
        directoryAttributes: [FileAttributeKey: Any]? = nil
    ) -> Bool {
        queue(for: url).sync {
            do {
                let parent = url.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(
                        at: parent, withIntermediateDirectories: true,
                        attributes: directoryAttributes)
                }
                let tmp = parent.appendingPathComponent(
                    ".\(url.lastPathComponent).rewrite-\(UUID().uuidString)")
                try data.write(to: tmp, options: .atomic)
                if fileManager.fileExists(atPath: url.path) {
                    _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
                } else {
                    try fileManager.moveItem(at: tmp, to: url)
                }
                _ = claimTailRepair(url)
                return true
            } catch {
                #if DEBUG
                print("[JSONLFileLog] rewrite of \(url.lastPathComponent) failed: \(error)")
                #endif
                return false
            }
        }
    }

    /// All decodable lines; a bad line costs one row, never the file.
    static func decodeLines<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        decoder: JSONDecoder,
        fileManager: FileManager = .default
    ) -> [T] {
        queue(for: url).sync {
            guard let data = fileManager.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }
            return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
                try? decoder.decode(T.self, from: Data($0.utf8))
            }
        }
    }

}
