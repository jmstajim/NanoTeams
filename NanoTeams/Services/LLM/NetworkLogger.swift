import Foundation

enum NetworkDirection: String, Codable {
    case request
    case response
}

struct NetworkLogRecord: Codable, Hashable {
    var id: UUID
    var createdAt: Date
    var direction: NetworkDirection
    var httpMethod: String
    var url: String
    var statusCode: Int?
    var body: String?
    var durationMs: Double?
    var errorMessage: String?
    var correlationID: UUID
    var stepID: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var roleName: String?
}

final class NetworkLogger {
    let logURL: URL
    let conversationLogURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.nanoteams.networklogger")

    init(logURL: URL, fileManager: FileManager = .default) {
        self.logURL = logURL
        self.conversationLogURL = logURL.deletingLastPathComponent()
            .appendingPathComponent("conversation_log.md", isDirectory: false)
        self.fileManager = fileManager

        self.encoder = JSONCoderFactory.makePersistenceEncoder()
        self.decoder = JSONCoderFactory.makeDateDecoder()
    }

    func append(_ record: NetworkLogRecord) {
        queue.sync {
            do {
                // Read existing records
                var records: [NetworkLogRecord] = []
                if fileManager.fileExists(atPath: logURL.path),
                   let data = fileManager.contents(atPath: logURL.path) {
                    records = (try? decoder.decode([NetworkLogRecord].self, from: data)) ?? []
                }

                // Append new record
                records.append(record)

                // Create parent directory if needed
                let parent = logURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true,
                                                     attributes: NTMSRepository.internalDirAttributes)
                }

                // Write back as JSON array
                let data = try encoder.encode(records)
                try data.write(to: logURL, options: .atomic)

                // Generate and write markdown conversation log
                let renderer = ConversationLogRenderer()
                let markdown = renderer.render(records: records)
                try markdown.write(to: conversationLogURL, atomically: true, encoding: .utf8)
            } catch {
                // Best-effort logging; never fail operations due to logging issues
                #if DEBUG
                print("[NetworkLogger] append failed: \(error)")
                #endif
            }
        }
    }

    /// Creates a request record and returns it for later response pairing
    static func createRequestRecord(
        url: URL,
        method: String,
        body: Data?,
        stepID: String?,
        roleName: String? = nil
    ) -> NetworkLogRecord {
        let bodyString: String?
        if let body = body {
            bodyString = String(data: body, encoding: .utf8)
        } else {
            bodyString = nil
        }

        return NetworkLogRecord(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            direction: .request,
            httpMethod: method,
            url: url.absoluteString,
            statusCode: nil,
            body: bodyString,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: stepID,
            roleName: roleName
        )
    }

    /// Creates a response record paired with a request via correlationID
    static func createResponseRecord(
        for request: NetworkLogRecord,
        statusCode: Int,
        durationMs: Double,
        body: String? = nil,
        error: Error?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) -> NetworkLogRecord {
        NetworkLogRecord(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            direction: .response,
            httpMethod: request.httpMethod,
            url: request.url,
            statusCode: statusCode,
            body: body,
            durationMs: durationMs,
            errorMessage: error?.localizedDescription,
            correlationID: request.correlationID,
            stepID: request.stepID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            roleName: request.roleName
        )
    }
    nonisolated deinit {}
}
