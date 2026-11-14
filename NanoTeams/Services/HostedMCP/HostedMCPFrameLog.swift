import Foundation

/// Single entry in `HostedMCPFrameLog` (§7.1).
///
/// Contains zero HTTP header fields and zero raw request/response bodies so Bearer tokens
/// can never leak into the diagnostic ring buffer or optional JSONL file.
nonisolated struct HostedMCPFrameLogEntry: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var timestamp: Date
    var agentID: UUID?
    var agentLabel: String?
    var method: String
    var tool: String?
    var statusCode: Int
    var durationMs: Int
    var refusalReason: String?
    var agentTextVersion: String

    init(
        id: UUID = UUID(),
        timestamp: Date,
        agentID: UUID?,
        agentLabel: String?,
        method: String,
        tool: String? = nil,
        statusCode: Int,
        durationMs: Int,
        refusalReason: String? = nil,
        agentTextVersion: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.agentID = agentID
        self.agentLabel = agentLabel
        self.method = method
        self.tool = tool
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.refusalReason = refusalReason
        self.agentTextVersion = agentTextVersion
    }
}

/// Bounded in-memory ring buffer (`200` entries) and optional size-rotated JSONL file
/// for Hosted MCP diagnostic frame logging (§7.1).
///
/// Refusals (`statusCode >= 400` with a reason) are rate-limited (§10.2 п.6): within
/// `refusalCoalesceWindowSeconds` of a logged refusal, later ones with the same agent, status
/// and reason CLASS are dropped. A reason is spelled `class` or `class:detail`, and the detail
/// is often request-supplied — a forbidden `Origin` verbatim (E9), a method token — so it rides
/// in the logged entry but never in the key: keyed on the whole reason, every distinct detail
/// bypassed the window and left a key behind for good. At most `maxTrackedRefusalKeys` keys
/// are kept — expired ones go first, then the least recently logged.
nonisolated final class HostedMCPFrameLog: @unchecked Sendable {

    static let maxTrackedRefusalKeys = 256

    private let capacity: Int
    private let directoryURL: URL?
    private let maxFileBytes: Int
    private let refusalCoalesceWindowSeconds: TimeInterval

    private let lock = NSLock()
    private var ring: [HostedMCPFrameLogEntry] = []
    private var sensitiveValues: Set<String> = []
    private var lastRefusalByKey: [RefusalKey: RefusalStamp] = [:]
    private var refusalSequence: UInt64 = 0

    private struct RefusalKey: Hashable, Sendable {
        let agentID: UUID?
        let statusCode: Int
        let reasonClass: String
    }

    private struct RefusalStamp: Sendable {
        let loggedAt: Date
        let sequence: UInt64
    }

    /// The issuer's one spelling of a token in text (`HostedMCPConstants.agentTokenPattern`).
    /// This log carried its own, different one until 2026-11-08.
    private static let ntmTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: HostedMCPConstants.agentTokenPattern,
        options: []
    )

    init(
        capacity: Int = HostedMCPConstants.frameLogRingCapacity,
        directoryURL: URL? = nil,
        maxFileBytes: Int = HostedMCPConstants.frameLogMaxFileBytes,
        refusalCoalesceWindowSeconds: TimeInterval = 1.0
    ) {
        self.capacity = max(1, capacity)
        self.directoryURL = directoryURL
        self.maxFileBytes = max(512, maxFileBytes)
        self.refusalCoalesceWindowSeconds = max(0, refusalCoalesceWindowSeconds)
    }

    /// Adds a token — and its secret part — to the literals every later entry is scrubbed of.
    /// Register only tokens that AUTHENTICATED: the set is rebuilt into the scrubber on every
    /// write, so registering whatever a request presents lets an unauthenticated client grow it
    /// and the cost of each write without bound.
    func registerSensitiveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        sensitiveValues.insert(trimmed)
        let parts = trimmed.split(separator: "_", omittingEmptySubsequences: false)
        if parts.count >= 3 {
            let secretPart = parts.dropFirst(2).joined(separator: "_")
            if secretPart.count >= MCPRedaction.Credentials.minimumLiteralBytes {
                sensitiveValues.insert(secretPart)
            }
        }
        lock.unlock()
    }

    func record(
        timestamp: Date = Date(),
        agent: AgentIdentity?,
        method: String,
        tool: String? = nil,
        statusCode: Int,
        durationMs: Int,
        refusalReason: String? = nil,
        agentTextVersion: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        let credentials = MCPRedaction.Credentials(values: Array(sensitiveValues))
        let scrubbedMethod = scrubString(method, credentials: credentials)
        let scrubbedTool = tool.map { scrubString($0, credentials: credentials) }
        let scrubbedReason = refusalReason.map { scrubString($0, credentials: credentials) }

        if statusCode >= 400,
           let scrubbedReason,
           refusalCoalesceWindowSeconds > 0 {
            let key = RefusalKey(
                agentID: agent?.id,
                statusCode: statusCode,
                reasonClass: Self.reasonClass(of: scrubbedReason)
            )
            if let stamp = lastRefusalByKey[key],
               timestamp.timeIntervalSince(stamp.loggedAt) < refusalCoalesceWindowSeconds {
                return
            }
            trackLoggedRefusal(key, at: timestamp)
        }

        let entry = HostedMCPFrameLogEntry(
            timestamp: timestamp,
            agentID: agent?.id,
            agentLabel: agent?.label,
            method: scrubbedMethod,
            tool: scrubbedTool,
            statusCode: statusCode,
            durationMs: max(0, durationMs),
            refusalReason: scrubbedReason,
            agentTextVersion: agentTextVersion
        )

        ring.append(entry)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }

        if let directoryURL {
            appendToDiskFile(entry: entry, directoryURL: directoryURL)
        }
    }

    func entries() -> [HostedMCPFrameLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return ring
    }

    func clear() {
        lock.lock()
        ring.removeAll()
        lastRefusalByKey.removeAll()
        lock.unlock()
    }

    #if DEBUG
    var _testTrackedRefusalKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lastRefusalByKey.count
    }

    var _testSensitiveValueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sensitiveValues.count
    }
    #endif

    // MARK: - Private

    /// The `class` of a `class` or `class:detail` refusal reason.
    private static func reasonClass(of reason: String) -> String {
        reason.firstIndex(of: ":").map { String(reason[..<$0]) } ?? reason
    }

    /// Notes that `key` was logged at `timestamp`. Called under `lock`.
    private func trackLoggedRefusal(_ key: RefusalKey, at timestamp: Date) {
        if lastRefusalByKey[key] == nil, lastRefusalByKey.count >= Self.maxTrackedRefusalKeys {
            lastRefusalByKey = lastRefusalByKey.filter {
                timestamp.timeIntervalSince($0.value.loggedAt) < refusalCoalesceWindowSeconds
            }
            if lastRefusalByKey.count >= Self.maxTrackedRefusalKeys,
               let leastRecent = lastRefusalByKey.min(by: {
                   ($0.value.loggedAt, $0.value.sequence) < ($1.value.loggedAt, $1.value.sequence)
               })?.key {
                lastRefusalByKey.removeValue(forKey: leastRecent)
            }
        }
        refusalSequence &+= 1
        lastRefusalByKey[key] = RefusalStamp(loggedAt: timestamp, sequence: refusalSequence)
    }

    private func scrubString(_ raw: String, credentials: MCPRedaction.Credentials) -> String {
        var scrubbed = credentials.text(raw)
        if let regex = Self.ntmTokenRegex {
            scrubbed = regex.stringByReplacingMatches(
                in: scrubbed,
                range: NSRange(scrubbed.startIndex..., in: scrubbed),
                withTemplate: "[REDACTED]"
            )
        }
        if scrubbed.contains(MCPRedaction.placeholder) {
            scrubbed = scrubbed.replacingOccurrences(of: MCPRedaction.placeholder, with: "[REDACTED]")
        }
        return scrubbed
    }

    private func appendToDiskFile(entry: HostedMCPFrameLogEntry, directoryURL: URL) {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: directoryURL.path) {
                try fm.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let currentURL = directoryURL.appendingPathComponent(HostedMCPConstants.frameLogFileName)
            let rotatedURL = directoryURL.appendingPathComponent(HostedMCPConstants.frameLogRotatedFileName)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard var lineData = try? encoder.encode(entry) else { return }
            lineData.append(0x0A)

            if fm.fileExists(atPath: currentURL.path) {
                let attrs = try? fm.attributesOfItem(atPath: currentURL.path)
                let currentSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                if currentSize + lineData.count > maxFileBytes {
                    if fm.fileExists(atPath: rotatedURL.path) {
                        try? fm.removeItem(at: rotatedURL)
                    }
                    try? fm.moveItem(at: currentURL, to: rotatedURL)
                }
            }

            if !fm.fileExists(atPath: currentURL.path) {
                fm.createFile(
                    atPath: currentURL.path,
                    contents: lineData,
                    attributes: [.posixPermissions: 0o600]
                )
            } else if let handle = try? FileHandle(forWritingTo: currentURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: lineData)
            }
        } catch {
            // Frame log disk writes are best-effort diagnostic persistence.
        }
    }
}
