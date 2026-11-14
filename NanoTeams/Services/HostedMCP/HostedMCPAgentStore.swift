import CryptoKit
import Foundation
import Security

/// Persisted metadata for an external agent registered in `agents.json` (§6).
///
/// The token secret is never stored here: only its `SHA-256` hex verifier is stored in
/// `SecureTokenStorage` (`KeychainSecureTokenStorage(service: "com.nanoteams.agentaccess.v1")`
/// in production, `InMemorySecureTokenStorage` in tests).
nonisolated struct HostedMCPAgentRecord: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var shortID: String
    var label: String
    var createdAt: Date
    var rotatedAt: Date? = nil
    var lastSeenAt: Date?
    /// A free line about the client, shown on the agent's row when there is one. Nothing in
    /// the app writes it today: the client an agent was added for stopped being recorded on
    /// 2026-11-09, when every agent began to get the same token file and the same connection
    /// facts (a `client_kind` key an earlier build wrote is ignored on load).
    var clientHint: String?
    /// Whether the person lets this agent replace the Work Folder Context
    /// (`set_work_folder_context`) of a folder it is the Autovisor of. Off until they turn it on,
    /// on the agent's row: the context rides the system prompt of every role on a team whose
    /// prompt carries it, the person's own tasks included, so it is the one write that reaches
    /// past the agent's tasks DIRECTLY (decision A3, revised 2026-11-13). Its tasks can still edit
    /// an instruction file the context injects, as any task can — hosted-mcp.md, threat boundary.
    var mayReplaceWorkFolderContext: Bool = false

    var identity: AgentIdentity {
        AgentIdentity(id: id, label: label)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case shortID = "short_id"
        case label
        case createdAt = "created_at"
        case rotatedAt = "rotated_at"
        case lastSeenAt = "last_seen_at"
        case clientHint = "client_hint"
        case mayReplaceWorkFolderContext = "may_replace_work_folder_context"
    }
}

extension HostedMCPAgentRecord {
    /// Written by hand for one reason: every key added after the first release must read as
    /// absent, not as a fault. `loadRecordsFromDisk` reads the file as one array and an
    /// undecodable record empties it — a synthesized decoder would have required
    /// `may_replace_work_folder_context` and dropped every agent registered before 2026-11-13.
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        shortID = try c.decode(String.self, forKey: .shortID)
        label = try c.decode(String.self, forKey: .label)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        rotatedAt = try c.decodeIfPresent(Date.self, forKey: .rotatedAt)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        clientHint = try c.decodeIfPresent(String.self, forKey: .clientHint)
        mayReplaceWorkFolderContext =
            try c.decodeIfPresent(Bool.self, forKey: .mayReplaceWorkFolderContext) ?? false
    }
}

/// Result of creating or rotating an agent token. The cleartext `token` is returned once
/// to the caller and never persisted to disk (§6).
nonisolated struct HostedMCPIssuedAgent: Sendable, Equatable {
    var record: HostedMCPAgentRecord
    var token: String
}

/// Errors thrown by `HostedMCPAgentStore` management operations.
nonisolated enum HostedMCPAgentStoreError: Error, LocalizedError, Sendable, Equatable {
    case emptyLabel
    case agentNotFound(UUID)
    case randomGenerationFailed
    case keychainFailure(String)
    case storageWriteFailed(String)

    var message: String {
        switch self {
        case .emptyLabel:
            return "Enter a label for the agent."
        case .agentNotFound:
            return "Agent not found."
        case .randomGenerationFailed:
            return "Could not generate a secure token."
        case .keychainFailure(let detail):
            return "macOS Keychain error: \(detail)"
        case .storageWriteFailed(let detail):
            return "Could not save the agent list: \(detail)"
        }
    }

    var errorDescription: String? { message }
}

/// Outcome of a `revokeAgent(agentID:)` that committed: the record is gone from `agents.json`,
/// its token no longer authenticates, and its in-flight requests were cancelled (§6).
nonisolated enum HostedMCPAgentRevocation: Sendable, Equatable {
    /// The agent's `SHA-256` verifier was deleted from `SecureTokenStorage` as well.
    case revoked
    /// The Keychain refused to delete the verifier. It is not a secret and nothing reads it
    /// again — the record that gated it is gone — but it stays in the Keychain until removed.
    case revokedLeavingVerifier

    /// Text for the person who revoked the agent, or `nil` when there is nothing to report.
    var warning: String? {
        switch self {
        case .revoked:
            return nil
        case .revokedLeavingVerifier:
            return "Agent revoked, but its token verifier could not be removed from the macOS Keychain."
        }
    }
}

/// Response body returned by `GET /identify?agent=<short id>&nonce=<hex>` (§6, §7.2).
nonisolated struct HostedMCPIdentifyPayload: Codable, Sendable, Equatable {
    var app: String
    var version: String
    var pid: Int32
    var proof: String
}

/// Outcome of evaluating `GET /identify` against `HostedMCPAgentStore` (§6).
nonisolated enum HostedMCPIdentifyResult: Sendable, Equatable {
    case success(HostedMCPIdentifyPayload)
    case invalidNonce
    case agentNotFound
    case storageFailure(String)
}

/// Manages external agent records (`agents.json` with directory `0o700` and file `0o600`),
/// token issuance/rotation/revocation (`ntm_<short id>_<32 random bytes base64url>`),
/// `SHA-256(secret)` verifiers in `SecureTokenStorage`, constant-time comparison,
/// lazy `lastSeenAt` persistence (at most once per 60 s), and `GET /identify` HMAC-SHA256 proof (§6).
nonisolated final class HostedMCPAgentStore: @unchecked Sendable {

    let directoryURL: URL
    private let secretStorage: any SecureTokenStorage
    private let lastSeenPersistenceInterval: TimeInterval
    private let appVersion: String
    private let processIdentifier: Int32
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var records: [HostedMCPAgentRecord] = []
    private var lastPersistedAtByAgent: [UUID: Date] = [:]
    private var dirtyLastSeenAgents: Set<UUID> = []
    private var invalidationHandlers: [@Sendable (UUID) -> Void] = []
    private var changeHandlers: [@Sendable () -> Void] = []

    var agentsFileURL: URL {
        directoryURL.appendingPathComponent(HostedMCPConstants.agentsFileName)
    }

    init(
        directoryURL: URL,
        secretStorage: any SecureTokenStorage,
        lastSeenPersistenceInterval: TimeInterval = HostedMCPConstants.lastSeenPersistenceIntervalSeconds,
        appVersion: String = HostedMCPConstants.defaultServerVersion,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directoryURL = directoryURL
        self.secretStorage = secretStorage
        self.lastSeenPersistenceInterval = max(0, lastSeenPersistenceInterval)
        self.appVersion = appVersion
        self.processIdentifier = processIdentifier
        self.now = now
        self.records = Self.loadRecordsFromDisk(fileURL: directoryURL.appendingPathComponent(HostedMCPConstants.agentsFileName))
        for record in self.records {
            if let seen = record.lastSeenAt {
                self.lastPersistedAtByAgent[record.id] = seen
            }
        }
    }

    /// Registers a callback invoked synchronously whenever an agent's token is rotated or
    /// the agent is revoked so active `wait_for_events` calls and streams are cancelled immediately (§6).
    func addInvalidationHandler(_ handler: @escaping @Sendable (UUID) -> Void) {
        lock.lock()
        invalidationHandlers.append(handler)
        lock.unlock()
    }

    /// Registers a callback invoked whenever the agent registry or `lastSeenAt` changes so
    /// SwiftUI views observing `NTMSOrchestrator` refresh immediately.
    func addChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        changeHandlers.append(handler)
        lock.unlock()
    }

    func listAgents() -> [HostedMCPAgentRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    var agents: [HostedMCPAgentRecord] {
        listAgents()
    }

    func agent(id: UUID) -> HostedMCPAgentRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.id == id }
    }

    func agent(shortID: String) -> HostedMCPAgentRecord? {
        let normalized = shortID.lowercased()
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.shortID.lowercased() == normalized }
    }

    /// Returns `true` when the agent has an active `wait_for_events` call or its `lastSeenAt`
    /// is within `windowSeconds` (`120 s` by default) of `now()` (§6).
    func isAgentPresent(
        agentID: UUID,
        hasActiveWait: Bool = false,
        windowSeconds: TimeInterval = HostedMCPConstants.presenceConnectedWindowSeconds
    ) -> Bool {
        if hasActiveWait { return true }
        lock.lock()
        let seen = records.first(where: { $0.id == agentID })?.lastSeenAt
        lock.unlock()
        guard let seen else { return false }
        return now().timeIntervalSince(seen) <= max(0, windowSeconds)
    }

    func createAgent(label: String, clientHint: String? = nil) throws -> HostedMCPIssuedAgent {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            throw HostedMCPAgentStoreError.emptyLabel
        }
        let trimmedHint = clientHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHint = (trimmedHint?.isEmpty == false) ? trimmedHint : nil

        let secretPart = try Self.generateRandomBase64URLSecret()
        let verifierDigest = Self.sha256Digest(of: secretPart)
        let verifierHex = Self.hexString(from: verifierDigest)

        let onChange: [@Sendable () -> Void]
        lock.lock()
        let existingShortIDs = Set(records.map { $0.shortID.lowercased() })
        var id = UUID()
        var shortID = Self.deriveShortID(from: id)
        while existingShortIDs.contains(shortID) { id = UUID(); shortID = Self.deriveShortID(from: id) }

        let record = HostedMCPAgentRecord(
            id: id,
            shortID: shortID,
            label: trimmedLabel,
            createdAt: now(),
            rotatedAt: nil,
            lastSeenAt: nil,
            clientHint: effectiveHint
        )

        do {
            try secretStorage.setToken(verifierHex, forKey: id.uuidString)
        } catch {
            lock.unlock()
            throw HostedMCPAgentStoreError.keychainFailure("keychain_write_failed")
        }

        do {
            try persistLocked(records + [record])
        } catch {
            try? secretStorage.setToken(nil, forKey: id.uuidString)
            lock.unlock()
            throw error
        }
        records.append(record)
        onChange = changeHandlers
        lock.unlock()

        for handler in onChange {
            handler()
        }

        let token = "\(HostedMCPConstants.tokenPrefix)\(shortID)_\(secretPart)"
        return HostedMCPIssuedAgent(record: record, token: token)
    }

    func rotateToken(agentID: UUID) throws -> HostedMCPIssuedAgent {
        let secretPart = try Self.generateRandomBase64URLSecret()
        let verifierDigest = Self.sha256Digest(of: secretPart)
        let verifierHex = Self.hexString(from: verifierDigest)

        let record: HostedMCPAgentRecord
        let handlers: [@Sendable (UUID) -> Void]
        let onChange: [@Sendable () -> Void]

        lock.lock()
        guard let index = records.firstIndex(where: { $0.id == agentID }) else {
            lock.unlock()
            throw HostedMCPAgentStoreError.agentNotFound(agentID)
        }
        // The verifier a failed save below puts back.
        let previousVerifierHex: String?
        do {
            previousVerifierHex = try secretStorage.loadToken(forKey: agentID.uuidString)
        } catch KeychainError.invalidUTF8 {
            // The entry holds bytes that are no verifier: the state "Reissue token" exists to
            // repair, so the rotation goes ahead. A failed save then removes the entry, which
            // authenticated nothing either way.
            previousVerifierHex = nil
        } catch {
            // The Keychain did not answer (locked, interaction not allowed). The verifier there
            // may be a good one, and a failed save could not put it back: `try?` read this as
            // "none", and that rollback deleted a working verifier — the agent's token answered 401
            // while the rotation threw and showed no new one. Nothing is changed.
            lock.unlock()
            throw HostedMCPAgentStoreError.keychainFailure("keychain_unavailable")
        }
        do {
            try secretStorage.setToken(verifierHex, forKey: agentID.uuidString)
        } catch {
            lock.unlock()
            throw HostedMCPAgentStoreError.keychainFailure("keychain_write_failed")
        }
        var rotatedRecords = records
        rotatedRecords[index].rotatedAt = now()
        do {
            try persistLocked(rotatedRecords)
        } catch {
            try? secretStorage.setToken(previousVerifierHex, forKey: agentID.uuidString)
            lock.unlock()
            throw error
        }
        records = rotatedRecords
        record = records[index]
        handlers = invalidationHandlers
        onChange = changeHandlers
        lock.unlock()

        for handler in handlers {
            handler(agentID)
        }
        for handler in onChange {
            handler()
        }

        let token = "\(HostedMCPConstants.tokenPrefix)\(record.shortID)_\(secretPart)"
        return HostedMCPIssuedAgent(record: record, token: token)
    }

    /// Lets `agentID` replace the open folder's Work Folder Context, or takes that back
    /// (`HostedMCPAgentRecord.mayReplaceWorkFolderContext`). Writing `agents.json` is the commit
    /// point: a failed write throws and changes nothing. The token is untouched — the switch
    /// governs what the agent may do, not who it is — so no call in flight is cancelled; the
    /// next `set_work_folder_context` reads the new value.
    func setMayReplaceWorkFolderContext(_ allowed: Bool, agentID: UUID) throws {
        let onChange: [@Sendable () -> Void]
        lock.lock()
        guard let index = records.firstIndex(where: { $0.id == agentID }) else {
            lock.unlock()
            throw HostedMCPAgentStoreError.agentNotFound(agentID)
        }
        guard records[index].mayReplaceWorkFolderContext != allowed else {
            lock.unlock()
            return
        }
        var updated = records
        updated[index].mayReplaceWorkFolderContext = allowed
        do {
            try persistLocked(updated)
        } catch {
            lock.unlock()
            throw error
        }
        records = updated
        onChange = changeHandlers
        lock.unlock()
        for handler in onChange {
            handler()
        }
    }

    /// Revokes `agentID` (§6). Writing `agents.json` without the record is the commit point: a
    /// failed write throws and changes nothing, while once it succeeds the token can no longer
    /// authenticate, so the agent's in-flight requests and waits are cancelled and the list is
    /// refreshed whatever the Keychain then does with the verifier — a refused delete is
    /// reported in the outcome, never thrown.
    @discardableResult
    func revokeAgent(agentID: UUID) throws -> HostedMCPAgentRevocation {
        let handlers: [@Sendable (UUID) -> Void]
        let onChange: [@Sendable () -> Void]
        let outcome: HostedMCPAgentRevocation

        lock.lock()
        guard let index = records.firstIndex(where: { $0.id == agentID }) else {
            lock.unlock()
            throw HostedMCPAgentStoreError.agentNotFound(agentID)
        }
        var remainingRecords = records
        remainingRecords.remove(at: index)
        do {
            try persistLocked(remainingRecords)
        } catch {
            lock.unlock()
            throw error
        }
        records = remainingRecords
        lastPersistedAtByAgent.removeValue(forKey: agentID)
        dirtyLastSeenAgents.remove(agentID)

        do {
            try secretStorage.setToken(nil, forKey: agentID.uuidString)
            outcome = .revoked
        } catch {
            outcome = .revokedLeavingVerifier
        }

        handlers = invalidationHandlers
        onChange = changeHandlers
        lock.unlock()

        for handler in handlers {
            handler(agentID)
        }
        for handler in onChange {
            handler()
        }
        return outcome
    }

    /// Verifies a raw `ntm_<short id>_<secret>` bearer token in constant time (§6).
    ///
    /// - If Keychain access throws an error, returns `.storageFailure` (`503`, never `401`).
    /// - On success, updates `lastSeenAt` in memory immediately and writes `agents.json`
    ///   at most once every `lastSeenPersistenceInterval` seconds (`60 s` by default).
    func verifyBearerToken(_ rawToken: String) -> HostedMCPTokenVerificationResult {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Self.parseToken(trimmed) else {
            return .invalidToken
        }

        let candidateDigest = Self.sha256Digest(of: parsed.secret)

        lock.lock()
        guard let index = records.firstIndex(where: { $0.shortID.caseInsensitiveCompare(parsed.shortID) == .orderedSame }) else {
            lock.unlock()
            let dummy = Data(repeating: 0, count: 32)
            _ = Self.constantTimeEquals(candidateDigest, dummy)
            return .invalidToken
        }

        let record = records[index]
        let storedHex: String?
        do {
            storedHex = try secretStorage.loadToken(forKey: record.id.uuidString)
        } catch {
            lock.unlock()
            return .storageFailure("keychain_unavailable")
        }

        guard let storedHex,
              let storedDigest = Self.dataFromHex(storedHex),
              storedDigest.count == 32
        else {
            lock.unlock()
            let dummy = Data(repeating: 0, count: 32)
            _ = Self.constantTimeEquals(candidateDigest, dummy)
            return .invalidToken
        }

        guard Self.constantTimeEquals(candidateDigest, storedDigest) else {
            lock.unlock()
            return .invalidToken
        }

        let currentNow = now()
        records[index].lastSeenAt = currentNow
        let lastPersisted = lastPersistedAtByAgent[record.id]
        if lastPersisted == nil || currentNow.timeIntervalSince(lastPersisted!) >= lastSeenPersistenceInterval {
            if (try? persistLocked(records)) != nil {
                lastPersistedAtByAgent[record.id] = currentNow
                dirtyLastSeenAgents.remove(record.id)
            } else {
                dirtyLastSeenAgents.insert(record.id)
            }
        } else {
            dirtyLastSeenAgents.insert(record.id)
        }
        let identity = records[index].identity
        let onChange = changeHandlers
        lock.unlock()

        for handler in onChange {
            handler()
        }

        return .authenticated(identity)
    }

    /// Flushes any pending in-memory `lastSeenAt` updates to `agents.json` on shutdown.
    func flushPendingLastSeenWrites() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !dirtyLastSeenAgents.isEmpty else { return }
        try persistLocked(records)
        let currentNow = now()
        for record in records where dirtyLastSeenAgents.contains(record.id) {
            lastPersistedAtByAgent[record.id] = record.lastSeenAt ?? currentNow
        }
        dirtyLastSeenAgents.removeAll()
    }

    /// Evaluates `GET /identify?agent=<short id>&nonce=<hex>` without requiring a Bearer token
    /// (§6, §7.2); the nonce follows `HostedMCPHex.isIdentifyNonce`, the guard's own rule.
    func identify(shortID: String, nonceHex: String) -> HostedMCPIdentifyResult {
        guard HostedMCPHex.isIdentifyNonce(nonceHex) else {
            return .invalidNonce
        }

        lock.lock()
        let matched = records.first { $0.shortID.caseInsensitiveCompare(shortID) == .orderedSame }
        let storedHexResult: Result<String?, Error>? = matched.map { record in
            Result { try secretStorage.loadToken(forKey: record.id.uuidString) }
        }
        lock.unlock()

        guard let record = matched, let storedHexResult else {
            return .agentNotFound
        }

        let storedHex: String?
        switch storedHexResult {
        case .success(let value):
            storedHex = value
        case .failure:
            return .storageFailure("keychain_unavailable")
        }

        guard let storedHex,
              let verifierDigest = Self.dataFromHex(storedHex),
              verifierDigest.count == 32,
              record.shortID.count == HostedMCPConstants.shortIDCharacterCount
        else {
            return .agentNotFound
        }

        let proof = Self.computeIdentifyProof(verifierDigest: verifierDigest, nonceHex: nonceHex)
        return .success(
            HostedMCPIdentifyPayload(
                app: "NanoTeams",
                version: appVersion,
                pid: processIdentifier,
                proof: proof
            )
        )
    }

    /// Constant-time comparison of two byte buffers (`SHA-256` digests) (§6).
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        let lhsBytes = [UInt8](lhs)
        let rhsBytes = [UInt8](rhs)
        guard lhsBytes.count == rhsBytes.count else {
            var accumulator: UInt8 = 1
            for byte in lhsBytes {
                accumulator |= byte ^ byte
            }
            return accumulator == 0
        }
        var diff: UInt8 = 0
        for idx in 0..<lhsBytes.count {
            diff |= lhsBytes[idx] ^ rhsBytes[idx]
        }
        return diff == 0
    }

    /// Computes `SHA-256(secret)` as 32 raw bytes.
    static func sha256Digest(of secret: String) -> Data {
        Data(SHA256.hash(data: Data(secret.utf8)))
    }

    /// Computes `HMAC-SHA256(key: verifierDigest, data: "nanoteams-identify-v1:" + nonceHex)` as lowercase hex (§6).
    static func computeIdentifyProof(verifierDigest: Data, nonceHex: String) -> String {
        let key = SymmetricKey(data: verifierDigest)
        let message = Data((HostedMCPConstants.identifyDomainSeparator + nonceHex).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private Helpers

    private static func deriveShortID(from uuid: UUID) -> String {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(HostedMCPConstants.shortIDCharacterCount))
    }

    private static func generateRandomBase64URLSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: HostedMCPConstants.tokenSecretRandomByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw HostedMCPAgentStoreError.randomGenerationFailed
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func parseToken(_ rawToken: String) -> (shortID: String, secret: String)? {
        guard rawToken.hasPrefix(HostedMCPConstants.tokenPrefix) else { return nil }
        let remainder = rawToken.dropFirst(HostedMCPConstants.tokenPrefix.count)
        guard let underscoreIndex = remainder.firstIndex(of: "_") else { return nil }
        let shortID = String(remainder[..<underscoreIndex])
        let secret = String(remainder[remainder.index(after: underscoreIndex)...])
        guard shortID.utf8.count == HostedMCPConstants.shortIDCharacterCount,
              HostedMCPHex.isDigits(shortID),
              !secret.isEmpty
        else {
            return nil
        }
        return (shortID, secret)
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return Data(bytes)
    }

    private static func loadRecordsFromDisk(fileURL: URL) -> [HostedMCPAgentRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HostedMCPAgentRecord].self, from: data)) ?? []
    }

    /// Writes `snapshot` as `agents.json`. Callers pass the records they INTEND to hold and
    /// adopt them only after this returns, so a failed write leaves every in-memory record and
    /// its `lastSeenAt` bookkeeping exactly as it was — nothing to roll back.
    private func persistLocked(_ snapshot: [HostedMCPAgentRecord]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            do {
                try fm.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw HostedMCPAgentStoreError.storageWriteFailed("directory_create_failed")
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw HostedMCPAgentStoreError.storageWriteFailed("json_encode_failed")
        }

        let targetURL = agentsFileURL
        do {
            try data.write(to: targetURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
        } catch {
            throw HostedMCPAgentStoreError.storageWriteFailed("file_write_failed")
        }
    }
}
