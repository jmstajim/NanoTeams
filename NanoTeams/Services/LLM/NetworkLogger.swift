import Foundation

enum NetworkDirection: String, Codable {
    case request
    case response
    /// A tool call — NOT wire traffic. A discrete audit record for every tool
    /// call the run made: executed (success + handler error), and the
    /// pre-runtime non-dispatched cases (malformed / missing-name / unauthorized
    /// / duplicate-write) that never become an HTTP request. `.request`/`.response`
    /// consumers (e.g. `FirstPromptFromLogsExtractor`) skip these by direction.
    case toolCall
}

nonisolated struct NetworkLogRecord: Codable, Hashable {
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

nonisolated final class NetworkLogger: @unchecked Sendable {
    let logURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.nanoteams.networklogger")

    init(logURL: URL, fileManager: FileManager = .default) {
        self.logURL = logURL
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

                // Write back as JSON array. The human-readable `conversation_log.md`
                // is NO LONGER produced here — it now renders what the user actually
                // SEES (the activity feed), owned by `NTMSOrchestrator+ConversationLog`,
                // so it can be diffed against this wire log.
                let data = try encoder.encode(records)
                try data.write(to: logURL, options: .atomic)
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

    /// Creates a `.toolCall` audit record for a single tool call. Used for both
    /// executed calls (from `ToolRuntime`) and pre-runtime non-dispatched ones
    /// (unauthorized / duplicate-write / malformed / missing-name). Not HTTP
    /// traffic: `httpMethod`/`url` are empty and `correlationID` is fresh
    /// (unpaired). `errorMessage` is nil for a clean success. `arguments` and
    /// `result` are embedded as escaped JSON *string* values so a malformed
    /// payload can't corrupt the surrounding `[NetworkLogRecord]` array, and
    /// `body` itself stays valid JSON for downstream parsing.
    static func createToolCallRecord(
        toolName: String,
        argumentsJSON: String,
        resultJSON: String?,
        errorMessage: String?,
        stepID: String?,
        roleName: String? = nil
    ) -> NetworkLogRecord {
        let body = JSONUtilities.jsonStringForToolArgs([
            "event": "tool_call",
            "tool": toolName,
            "arguments": argumentsJSON,
            "result": resultJSON ?? "",
        ])
        return NetworkLogRecord(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            direction: .toolCall,
            httpMethod: "",
            url: "",
            statusCode: nil,
            body: body,
            durationMs: nil,
            errorMessage: errorMessage,
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
