import Foundation

/// What kind of thing happened on a server's connection.
nonisolated enum MCPRPCEventKind: String, Codable, Hashable, CaseIterable {
    case connect
    /// Which revision the probe settled on, and how.
    case era
    case request
    case response
    case notification
    /// A server → client request. Legacy era only, and this client answers exactly two ways.
    case serverRequest
    /// A catalogue refresh: how many tools, from how many pages.
    case list
    /// A pin decision: approved, new, changed, removed.
    case pin
    case failure
    case close
}

/// One line of a server's frame log.
///
/// **What is deliberately absent: headers.** The audit question this log answers is "what was
/// asked and what came back", and no header carries any of that — while `Authorization` and
/// `Mcp-Session-Id` carry exactly the two things that must never be written down. Leaving the
/// field out entirely is stronger than redacting it, because there is then nothing for a
/// future change to forget to redact (`MCPRPCLogHasNoHeadersTests`).
nonisolated struct MCPRPCLogRecord: Codable, Hashable {
    var id: UUID
    var createdAt: Date
    var kind: MCPRPCEventKind
    /// `"out"` or `"in"`, absent for events that are neither.
    var direction: String?
    var method: String?
    /// The request id as text, so a number and a string id read the same in `jq`.
    var requestID: String?
    var durationMs: Double?
    var errorCode: Int?
    var errorMessage: String?
    /// A redacted, size-capped excerpt of the frame's payload. `nil` when the frame carried
    /// none.
    var body: String?
    /// The payload's TRUE size, so a capped excerpt still says how much was dropped.
    var bodyBytes: Int?
    /// Free-text note for the events that are not frames — the era the probe chose, the tool
    /// count a refresh found, which pin moved.
    var detail: String?

    init(
        kind: MCPRPCEventKind,
        direction: String? = nil,
        method: String? = nil,
        requestID: JSONRPCID? = nil,
        durationMs: Double? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil,
        body: String? = nil,
        bodyBytes: Int? = nil,
        detail: String? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.direction = direction
        self.method = method
        self.requestID = requestID?.description
        self.durationMs = durationMs
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.body = body
        self.bodyBytes = bodyBytes
        self.detail = detail
    }
}

/// The per-server audit trail, one JSON object per line under
/// `.nanoteams/internal/mcp/<slug>/rpc_log.jsonl`.
///
/// Third of three logs, and the only one that sees the protocol. `tool_calls.jsonl` records
/// that a role called a tool and what came back; `network_log.jsonl` records the LLM wire;
/// this one records the conversation with the server — the frames, the era the probe chose,
/// the catalogue refreshes and every pin that moved. Without it, "the server changed a tool
/// three days ago" is unanswerable.
nonisolated final class MCPRPCLog: @unchecked Sendable {

    /// Ceiling on the payload excerpt. A cap on a LOG line, not on a tool result — a tool
    /// result is never truncated, and that rule is elsewhere and stays. A `get_screenshot`
    /// reply is a megabyte of base64 and writing it here would cost more than the audit is
    /// worth; `bodyBytes` keeps the true size.
    static let maxBodyCharacters = 4096

    let logURL: URL
    private let encoder: JSONEncoder
    private let fileManager: FileManager
    /// What THIS server is sent — its secret header names and secret values — read when a
    /// line is written, never held (`MCPRedaction.Credentials.sent(to:storage:)`), so a token
    /// rotated in Settings is scrubbed from the next line on. Until 2026-09-23 the log was
    /// given the header names and never read them, and knew no value at all.
    ///
    /// The price is one Keychain read per secret per line, and nothing for a server sent none
    /// (`StaticBearerAuthorizer.make` hands it `NoAuthorizer`, which never reads). Measured
    /// 2026-09-23 on an M5 Pro: 75–84 µs per `SecItemCopyMatching` round trip (2 000 lookups of
    /// an absent item, so the IPC without the decrypt), the same order as the line's own
    /// append. Paid rather than caching a secret in this object, which would put the token in a
    /// heap dump for the life of the connection.
    private let credentials: @Sendable () -> MCPRedaction.Credentials

    init(
        logURL: URL,
        credentials: @escaping @Sendable () -> MCPRedaction.Credentials = { .none },
        fileManager: FileManager = .default
    ) {
        self.logURL = logURL
        self.credentials = credentials
        self.fileManager = fileManager
        self.encoder = JSONCoderFactory.makeJSONLEncoder()
    }

    func append(_ record: MCPRPCLogRecord) {
        JSONLFileLog.append(
            record, to: logURL, encoder: encoder, fileManager: fileManager,
            directoryAttributes: NTMSRepository.internalDirAttributes)
    }

    // MARK: - Frames

    func noteOutgoing(_ frame: MCPOutgoingFrame) {
        let credentials = credentials()
        switch frame {
        case .request(let request):
            append(MCPRPCLogRecord(
                kind: .request, direction: "out", method: request.method, requestID: request.id,
                body: excerpt(request.params, credentials), bodyBytes: size(request.params)))
        case .notification(let notification):
            append(MCPRPCLogRecord(
                kind: .notification, direction: "out", method: notification.method,
                body: excerpt(notification.params, credentials), bodyBytes: size(notification.params)))
        case .response(let response):
            append(MCPRPCLogRecord(
                kind: .response, direction: "out", requestID: response.id,
                errorCode: response.error?.code,
                errorMessage: response.error.map { credentials.excerpt($0.message, limit: 200) },
                body: excerpt(response.result, credentials), bodyBytes: size(response.result)))
        }
    }

    func noteIncoming(_ frame: JSONRPCIncoming, durationMs: Double? = nil) {
        let credentials = credentials()
        switch frame {
        case .response(let response):
            append(MCPRPCLogRecord(
                kind: .response, direction: "in", requestID: response.id, durationMs: durationMs,
                errorCode: response.error?.code,
                errorMessage: response.error.map { credentials.excerpt($0.message, limit: 200) },
                body: excerpt(response.result, credentials), bodyBytes: size(response.result)))
        case .notification(let notification):
            append(MCPRPCLogRecord(
                kind: .notification, direction: "in", method: notification.method,
                body: excerpt(notification.params, credentials), bodyBytes: size(notification.params)))
        case .request(let request):
            append(MCPRPCLogRecord(
                kind: .serverRequest, direction: "in", method: request.method, requestID: request.id,
                body: excerpt(request.params, credentials), bodyBytes: size(request.params)))
        }
    }

    // MARK: - Lifecycle events

    func noteConnect(url: URL) {
        append(MCPRPCLogRecord(kind: .connect, detail: MCPRedaction.url(url)))
    }

    func noteEra(_ era: MCPProtocolEra, protocolVersion: String, how: String) {
        append(MCPRPCLogRecord(
            kind: .era, detail: "\(era.rawValue) (\(protocolVersion)) — \(how)"))
    }

    func noteList(toolCount: Int, pages: Int) {
        append(MCPRPCLogRecord(kind: .list, detail: "\(toolCount) tools over \(pages) page(s)"))
    }

    func notePin(tool: String, state: String) {
        append(MCPRPCLogRecord(kind: .pin, detail: "\(tool): \(state)"))
    }

    func noteFailure(_ error: any Error, method: String? = nil, requestID: JSONRPCID? = nil) {
        append(MCPRPCLogRecord(
            kind: .failure, method: method, requestID: requestID,
            errorMessage: credentials().excerpt(Self.reason(for: error), limit: 400)))
    }

    func noteClose(reason: String) {
        append(MCPRPCLogRecord(kind: .close, detail: MCPRedaction.excerpt(reason, limit: 200)))
    }

    /// App-authored text only. A foreign error's own string never reaches this file — it is
    /// the same defect as letting one reach a tool result, one file over.
    private static func reason(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? "the operation failed"
    }

    // MARK: - Payloads

    private func excerpt(_ value: JSONValue?, _ credentials: MCPRedaction.Credentials) -> String? {
        guard let value else { return nil }
        let canonical = credentials.text(value.canonicalJSONString())
        guard canonical.count > Self.maxBodyCharacters else { return canonical }
        return String(canonical.prefix(Self.maxBodyCharacters)) + "…"
    }

    private func size(_ value: JSONValue?) -> Int? {
        value.map { $0.canonicalJSONString().utf8.count }
    }
}
