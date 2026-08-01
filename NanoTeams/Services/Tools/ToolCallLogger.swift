import Foundation

nonisolated struct ToolCallLogRecord: Codable, Hashable {
    var createdAt: Date
    var taskID: Int
    var runID: Int
    var roleID: String
    var toolName: String
    var argumentsJSON: String
    var resultJSON: String?
    var errorMessage: String?
    /// Wall-clock duration of the handler body, in milliseconds.
    ///
    /// `createdAt` is stamped BEFORE the handler runs and `withResult` carries it over verbatim,
    /// so duration is not derivable from a single record — hence this field. It is measured with
    /// `ContinuousClock`, never from two `MonotonicClock.now()` reads: that clock returns
    /// `max(Date(), last + 1ms)` under a process-wide lock, which makes it a source of ORDER, not
    /// of elapsed time (neighbouring tool calls push each other's floor forward, so a delta
    /// between two reads can be fabricated entirely by unrelated concurrent work).
    ///
    /// Declared LAST with a default so the synthesized memberwise init keeps every existing
    /// construction site compiling, and `decodeIfPresent` reads old JSONL lines back as `nil`.
    ///
    /// Populated only where a handler actually executed, which gives the invariant
    /// **`durationMS != nil` ⟺ a handler ran** — `tool_not_found` and non-executed calls stay nil.
    ///
    /// Deliberately NOT surfaced in `ToolResultMeta`: that rides every tool result into the
    /// replayed conversation, and a value that changes between runs would poison the stable
    /// prompt prefix the KV cache depends on.
    var durationMS: Double?
}

nonisolated final class ToolCallLogger: @unchecked Sendable {
    let logURL: URL
    private let encoder: JSONEncoder
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.nanoteams.toolcalllogger")

    init(logURL: URL, fileManager: FileManager = .default) {
        self.logURL = logURL
        self.fileManager = fileManager

        self.encoder = JSONCoderFactory.makeJSONLEncoder()
    }

    func append(_ record: ToolCallLogRecord) {
        queue.sync {
            do {
                let data = try encoder.encode(record)
                var line = data
                line.append(0x0A)

                let parent = logURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true,
                                                     attributes: NTMSRepository.internalDirAttributes)
                }

                if !fileManager.fileExists(atPath: logURL.path) {
                    fileManager.createFile(atPath: logURL.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }

                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // Best-effort logging; never fail tool execution due to logging issues.
                #if DEBUG
                print("[ToolCallLogger] append failed: \(error)")
                #endif
            }
        }
    }
    nonisolated deinit {}
}
