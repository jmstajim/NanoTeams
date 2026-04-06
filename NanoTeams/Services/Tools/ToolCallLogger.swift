import Foundation

struct ToolCallLogRecord: Codable, Hashable {
    var createdAt: Date
    var taskID: Int
    var runID: Int
    var roleID: String
    var toolName: String
    var argumentsJSON: String
    var resultJSON: String?
    var errorMessage: String?
}

final class ToolCallLogger {
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
}
