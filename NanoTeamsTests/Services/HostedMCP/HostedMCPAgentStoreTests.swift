import CryptoKit
import Foundation
import XCTest

@testable import NanoTeams

final class HostedMCPAgentStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostedMCPAgentStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        MCPEndpointPolicy.setConfiguredHostedServerPort(HostedMCPConstants.defaultPort)
        try super.tearDownWithError()
    }

    // MARK: - 0. A record keeps no client (2026-11-09)

    /// Until 2026-11-09 the record kept the client the agent was added for (`client_kind`), so a
    /// reissue knew how to hand the token over. Every agent gets the same token file and the
    /// same connection facts now, so the field went: a record an earlier build wrote with it
    /// still loads, and the key is not written again.
    func testARecordWithAClientKindFromAnEarlierBuild_loads_andTheKeyIsNotWrittenAgain() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(HostedMCPAgentRecord.self, from: Data("""
        {"id":"A4C36525-0000-4000-8000-000000000001","short_id":"a4c36525","label":"x",
         "created_at":"2026-11-08T00:00:00Z","client_kind":"claude_code"}
        """.utf8))
        XCTAssertEqual(record.label, "x")

        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        _ = try store.createAgent(label: "Claude Code")
        let onDisk = try String(contentsOf: tempDir.appendingPathComponent("agents.json"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("client_kind"), onDisk)
    }

    // MARK: - 1. Agent CRUD, File Permissions & Token Format (§6)

    func testCreateListRotateRevokeDirectoryMode0700FileMode0600AndNoCleartextTokensOnDisk() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let fixedNow = Date(timeIntervalSince1970: 1_759_971_200)
        let store = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage,
            appVersion: "2.5.0",
            processIdentifier: 4242,
            now: { fixedNow }
        )

        XCTAssertThrowsError(try store.createAgent(label: "   ")) { error in
            guard let storeError = error as? HostedMCPAgentStoreError else {
                return XCTFail("Expected HostedMCPAgentStoreError, got \(error)")
            }
            XCTAssertEqual(storeError, .emptyLabel)
            XCTAssertFalse(storeError.message.isEmpty)
        }

        let issued = try store.createAgent(label: "Claude Code", clientHint: "claude")
        XCTAssertEqual(issued.record.label, "Claude Code")
        XCTAssertEqual(issued.record.clientHint, "claude")
        XCTAssertEqual(issued.record.createdAt, fixedNow)
        XCTAssertNil(issued.record.rotatedAt)
        XCTAssertNil(issued.record.lastSeenAt)
        XCTAssertEqual(issued.record.shortID.count, HostedMCPConstants.shortIDCharacterCount)
        XCTAssertEqual(issued.record.identity, AgentIdentity(id: issued.record.id, label: "Claude Code"))

        // Token format: ntm_<8 hex>_<43 char base64url of 32 random bytes>
        let tokenParts = issued.token.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        XCTAssertEqual(tokenParts.count, 3)
        XCTAssertEqual(String(tokenParts[0]) + "_", HostedMCPConstants.tokenPrefix)
        XCTAssertEqual(String(tokenParts[1]), issued.record.shortID)
        let secretPart = String(tokenParts[2])
        XCTAssertEqual(secretPart.count, 43)

        // Directory mode 0o700 and file mode 0o600
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        let dirPosix = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(dirPosix & 0o777, 0o700)

        let fileAttrs = try FileManager.default.attributesOfItem(atPath: store.agentsFileURL.path)
        let filePosix = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(filePosix & 0o777, 0o600)

        // agents.json must not contain the token or secret
        let rawJSON = try String(contentsOf: store.agentsFileURL, encoding: .utf8)
        XCTAssertFalse(rawJSON.contains(issued.token))
        XCTAssertFalse(rawJSON.contains(secretPart))

        // SecureTokenStorage holds the SHA-256 hex verifier, not the cleartext secret
        let storedVerifier = try XCTUnwrap( try secretStorage.loadToken(forKey: issued.record.id.uuidString) )
        XCTAssertNotEqual(storedVerifier, issued.token)
        XCTAssertNotEqual(storedVerifier, secretPart)
        let expectedDigest = HostedMCPAgentStore.sha256Digest(of: secretPart)
        XCTAssertEqual(expectedDigest.count, 32)
        let expectedHex = expectedDigest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(storedVerifier, expectedHex)

        // Reload from disk in a second store instance
        let reloadedStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage,
            now: { fixedNow }
        )
        XCTAssertEqual(reloadedStore.listAgents(), [issued.record])
        XCTAssertEqual(reloadedStore.agent(id: issued.record.id), issued.record)
        XCTAssertEqual(reloadedStore.agent(shortID: issued.record.shortID), issued.record)
    }

    // MARK: - 2. Constant-Time Verification, Rotation, Revocation & Keychain 503 (§6)

    func testConstantTimeVerificationValidInvalidRotatedRevokedAndKeychain503Failure() throws {
        let a = Data([0x01, 0x02, 0x03, 0x04])
        let b = Data([0x01, 0x02, 0x03, 0x04])
        let c = Data([0x01, 0x02, 0x03, 0x05])
        let d = Data([0x01, 0x02, 0x03])
        XCTAssertTrue(HostedMCPAgentStore.constantTimeEquals(a, b))
        XCTAssertFalse(HostedMCPAgentStore.constantTimeEquals(a, c))
        XCTAssertFalse(HostedMCPAgentStore.constantTimeEquals(a, d))

        let secretStorage = InMemorySecureTokenStorage()
        let fixedNow = Date(timeIntervalSince1970: 1_759_971_200)
        let store = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage,
            now: { fixedNow }
        )
        let issued = try store.createAgent(label: "Cursor Agent")

        // Valid token authenticates
        XCTAssertEqual(
            store.verifyBearerToken(issued.token),
            .authenticated(issued.record.identity)
        )

        // Wrong secret fails with .invalidToken
        let wrongToken = "ntm_\(issued.record.shortID)_" + String(repeating: "A", count: 43)
        XCTAssertEqual(store.verifyBearerToken(wrongToken), .invalidToken)
        XCTAssertEqual(store.verifyBearerToken("invalid_format"), .invalidToken)

        // Keychain failure returns .storageFailure (503, never 401)
        secretStorage.readError = KeychainError.unhandled(-25308)
        let keychainDecision = store.verifyBearerToken(issued.token)
        if case .storageFailure = keychainDecision {
            // Expected
        } else {
            XCTFail("Expected .storageFailure when Keychain fails, got \(keychainDecision)")
        }
        secretStorage.readError = nil

        // Rotate token: old token immediately rejected, new token accepted, rotatedAt persisted
        final class LockedArray<Element>: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [Element] = []
            func append(_ item: Element) {
                lock.lock(); items.append(item); lock.unlock()
            }
            var snapshot: [Element] {
                lock.lock(); defer { lock.unlock() }; return items
            }
        }
        let invalidatedAgents = LockedArray<UUID>()
        store.addInvalidationHandler { agentID in
            invalidatedAgents.append(agentID)
        }
        let rotated = try store.rotateToken(agentID: issued.record.id)
        XCTAssertNotEqual(rotated.token, issued.token)
        XCTAssertNotNil(rotated.record.rotatedAt)
        let reloadedAfterRotate = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        XCTAssertEqual(reloadedAfterRotate.agent(id: issued.record.id)?.rotatedAt, rotated.record.rotatedAt)
        XCTAssertEqual(invalidatedAgents.snapshot, [issued.record.id])
        XCTAssertEqual(store.verifyBearerToken(issued.token), .invalidToken)
        XCTAssertEqual(
            store.verifyBearerToken(rotated.token),
            .authenticated(issued.record.identity)
        )

        // Revoke agent: removed from store and Keychain, token rejected
        try store.revokeAgent(agentID: issued.record.id)
        XCTAssertEqual(invalidatedAgents.snapshot, [issued.record.id, issued.record.id])
        XCTAssertTrue(store.listAgents().isEmpty)
        XCTAssertNil(try secretStorage.loadToken(forKey: issued.record.id.uuidString))
        XCTAssertEqual(store.verifyBearerToken(rotated.token), .invalidToken)
    }

    // MARK: - 3. Lazy lastSeenAt Persistence (<= 1 write per 60 s, §6) & Presence Window (120 s)

    func testLazyLastSeenAtUpdatesInMemoryImmediatelyAndPersistsAtMostOncePer60Seconds() throws {
        let secretStorage = InMemorySecureTokenStorage()
        final class ClockBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Date
            init(_ initial: Date) { self.value = initial }
            var now: Date {
                get { lock.lock(); defer { lock.unlock() }; return value }
                set { lock.lock(); value = newValue; lock.unlock() }
            }
        }
        let clock = ClockBox(Date(timeIntervalSince1970: 1_759_971_200))
        let store = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage,
            lastSeenPersistenceInterval: 60,
            now: { clock.now }
        )

        let issued = try store.createAgent(label: "Codex CLI")
        XCTAssertNil(store.agent(id: issued.record.id)?.lastSeenAt)
        XCTAssertFalse(store.isAgentPresent(agentID: issued.record.id))
        XCTAssertTrue(store.isAgentPresent(agentID: issued.record.id, hasActiveWait: true))

        // 1st verification at t = +10s: updates memory AND writes to disk (since previous persisted was nil)
        let firstTime = Date(timeIntervalSince1970: 1_759_971_210)
        clock.now = firstTime
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity))
        XCTAssertEqual(store.agent(id: issued.record.id)?.lastSeenAt, firstTime)
        XCTAssertTrue(store.isAgentPresent(agentID: issued.record.id))

        let diskStoreAfterFirst = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        XCTAssertEqual(diskStoreAfterFirst.agent(id: issued.record.id)?.lastSeenAt, firstTime)

        // 2nd verification at t = +30s (only 20s later < 60s): updates memory, skips disk write
        let secondTime = Date(timeIntervalSince1970: 1_759_971_230)
        clock.now = secondTime
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity))
        XCTAssertEqual(store.agent(id: issued.record.id)?.lastSeenAt, secondTime)

        let diskStoreBefore60s = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        XCTAssertEqual(
            diskStoreBefore60s.agent(id: issued.record.id)?.lastSeenAt,
            Date(timeIntervalSince1970: 1_759_971_210),
            "Disk must not be rewritten within 60s window"
        )

        // 3rd verification at t = +75s (65s after first disk write >= 60s): persists to disk
        let thirdTime = Date(timeIntervalSince1970: 1_759_971_275)
        clock.now = thirdTime
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity))
        let diskStoreAfter60s = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        XCTAssertEqual(diskStoreAfter60s.agent(id: issued.record.id)?.lastSeenAt, thirdTime)

        // 4th verification at t = +90s, then explicit flushPendingLastSeenWrites() on shutdown
        let fourthTime = Date(timeIntervalSince1970: 1_759_971_290)
        clock.now = fourthTime
        _ = store.verifyBearerToken(issued.token)
        try store.flushPendingLastSeenWrites()
        let diskStoreAfterFlush = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        XCTAssertEqual(diskStoreAfterFlush.agent(id: issued.record.id)?.lastSeenAt, fourthTime)

        // Presence expires after 120s unless hasActiveWait is true
        clock.now = fourthTime.addingTimeInterval(121)
        XCTAssertFalse(store.isAgentPresent(agentID: issued.record.id))
        XCTAssertTrue(store.isAgentPresent(agentID: issued.record.id, hasActiveWait: true))
    }

    // MARK: - 4. GET /identify HMAC-SHA256 Proof (§6, §7.2)

    func testIdentifyEndpointHMACProofMatchesReferenceVectorAndRejectsInvalidNonceOrUnknownAgent() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage,
            appVersion: "2.9.1",
            processIdentifier: 9876
        )
        let issued = try store.createAgent(label: "Stdio Bridge")
        let tokenParts = issued.token.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        let secret = String(tokenParts[2])
        let verifierDigest = Data(SHA256.hash(data: Data(secret.utf8)))

        let nonceHex = "0123456789abcdef0123456789abcdef"
        let messageData = Data(("nanoteams-identify-v1:" + nonceHex).utf8)
        let expectedMAC = HMAC<SHA256>.authenticationCode(
            for: messageData,
            using: SymmetricKey(data: verifierDigest)
        )
        let expectedProof = expectedMAC.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            HostedMCPAgentStore.computeIdentifyProof(verifierDigest: verifierDigest, nonceHex: nonceHex),
            expectedProof
        )

        let result = store.identify(shortID: issued.record.shortID, nonceHex: nonceHex)
        guard case .success(let payload) = result else {
            return XCTFail("Expected .success from identify, got \(result)")
        }
        XCTAssertEqual(payload, HostedMCPIdentifyPayload(
            app: "NanoTeams",
            version: "2.9.1",
            pid: 9876,
            proof: expectedProof
        ))

        // Unknown shortID -> .agentNotFound
        XCTAssertEqual(store.identify(shortID: "deadbeef", nonceHex: nonceHex), .agentNotFound)

        // Nonce too short (<16) or too long (>64) or non-hex -> .invalidNonce
        XCTAssertEqual(store.identify(shortID: issued.record.shortID, nonceHex: "0123456789abcd"), .invalidNonce)
        let nonce66 = String(repeating: "a", count: 66)
        XCTAssertEqual(store.identify(shortID: issued.record.shortID, nonceHex: nonce66), .invalidNonce)
        XCTAssertEqual(store.identify(shortID: issued.record.shortID, nonceHex: "0123456789abcdeg"), .invalidNonce)
    }

    // MARK: - 5. Rotation/Revocation Cancels Active Waits & In-Flight Requests (§6)

    @MainActor
    func testRotationAndRevocationImmediatelyCancelActiveWaitsAndInFlightRequests() async throws {
        let secretStorage = InMemorySecureTokenStorage()
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let orchestrator = TestOrchestrator.make(hostedMCPAgentStore: agentStore)

        let folderURL = tempDir.appendingPathComponent("workfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        await orchestrator.openWorkFolder(folderURL)
        await orchestrator.setAutovisorDriver(.externalAgent)
        await orchestrator.setAutovisorEnabled(true)

        let issued = try agentStore.createAgent(label: "Active Wait Agent")
        let initialCursor = try XCTUnwrap(orchestrator.autovisorEventFeed.currentCursor)

        let waitStarted = expectation(description: "waitForEvents entered")
        let waitFinished = expectation(description: "waitForEvents cancelled on token rotation")

        let waitTask = Task { @MainActor () -> AutovisorWaitResult in
            waitStarted.fulfill()
            let res = await orchestrator.autovisorEventFeed.waitForEvents(
                agentID: issued.record.id,
                after: initialCursor,
                timeoutSeconds: 30
            )
            waitFinished.fulfill()
            return res
        }

        await fulfillment(of: [waitStarted], timeout: 2.0)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(orchestrator.autovisorEventFeed.waiterCount, 1)

        // Rotate token -> must immediately wake and cancel the wait!
        _ = try agentStore.rotateToken(agentID: issued.record.id)
        await fulfillment(of: [waitFinished], timeout: 2.0)
        let waitResult = await waitTask.value
        XCTAssertFalse(waitResult.timedOut)
        XCTAssertEqual(orchestrator.autovisorEventFeed.waiterCount, 0)

        // Verify resetWorkFolderSettings() clears hostedMCPTransitionGate and re-activates autovisorEventFeed
        XCTAssertFalse(orchestrator.hostedMCPTransitionGate.isActive)
        await orchestrator.resetWorkFolderSettings()
        XCTAssertFalse(orchestrator.hostedMCPTransitionGate.isActive)
        let cursorAfterReset = try XCTUnwrap(orchestrator.autovisorEventFeed.currentCursor)

        // Verify shutdownForTermination() wakes active waitForEvents with .shuttingDown
        let shutdownWaitStarted = expectation(description: "shutdown waitForEvents entered")
        let shutdownWaitTask = Task { @MainActor () -> AutovisorWaitResult in
            shutdownWaitStarted.fulfill()
            return await orchestrator.autovisorEventFeed.waitForEvents(
                agentID: issued.record.id,
                after: cursorAfterReset,
                timeoutSeconds: 30
            )
        }
        await fulfillment(of: [shutdownWaitStarted], timeout: 2.0)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(orchestrator.autovisorEventFeed.waiterCount, 1)

        await orchestrator.shutdownForTermination()
        let shutdownResult = await shutdownWaitTask.value
        XCTAssertEqual(shutdownResult.stopReason, .shuttingDown)
        XCTAssertEqual(orchestrator.autovisorEventFeed.waiterCount, 0)
    }

    // MARK: - 6. Frame Log Ring Buffer (200), Token Scrubbing & File Rotation (§7.1)

    func testFrameLogRingBuffer200EntriesLiteralTokenScrubbingZeroHeadersAndFileRotation() throws {
        let logDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        let frameLog = HostedMCPFrameLog(
            capacity: HostedMCPConstants.frameLogRingCapacity,
            directoryURL: logDir,
            maxFileBytes: 4096,
            refusalCoalesceWindowSeconds: 0
        )

        let sensitiveToken = "ntm_1234abcd_SecretTokenValueForRedactionTest1234567890abc"
        frameLog.registerSensitiveToken(sensitiveToken)
        let agent = AgentIdentity(id: UUID(), label: "Claude Code")

        for idx in 0..<250 {
            frameLog.record(
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_759_971_200 + idx)),
                agent: agent,
                method: "tools/call",
                tool: "folder_status",
                statusCode: 200,
                durationMs: idx,
                refusalReason: idx == 249 ? "leaked \(sensitiveToken) and Bearer \(sensitiveToken)" : nil,
                agentTextVersion: "test-agent-text-version"
            )
        }

        let entries = frameLog.entries()
        XCTAssertEqual(entries.count, 200)
        XCTAssertEqual(entries.first?.durationMs, 50)
        XCTAssertEqual(entries.last?.durationMs, 249)

        let lastReason = try XCTUnwrap(entries.last?.refusalReason)
        XCTAssertFalse(lastReason.contains(sensitiveToken))
        XCTAssertFalse(lastReason.contains("SecretTokenValueForRedactionTest1234567890abc"))
        XCTAssertTrue(lastReason.contains("[REDACTED]"))

        let currentLogURL = logDir.appendingPathComponent(HostedMCPConstants.frameLogFileName)
        let rotatedLogURL = logDir.appendingPathComponent(HostedMCPConstants.frameLogRotatedFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentLogURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedLogURL.path))

        let currentLogText = try String(contentsOf: currentLogURL, encoding: .utf8)
        XCTAssertFalse(currentLogText.contains(sensitiveToken))

        frameLog.clear()
        XCTAssertTrue(frameLog.entries().isEmpty)
    }

    // MARK: - 7. Environment Scrubbing, Port Resolution & Self-Connection Policy (§10.2)

    func testEnvironmentScrubbingPortResolutionAndSelfConnectionPolicy() throws {
        let rawEnv: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/test",
            "NANOTEAMS_MCP_PORT": "48888",
            "NANOTEAMS_MCP_TOKEN": "ntm_12345678_secret",
            "nanoteams_mcp_custom": "value",
            "NANOTEAMS_TOKEN": "ntm_12345678_secret",
        ]
        let scrubbed = HostedMCPEnvironment.scrubbingHostedMCPVariables(from: rawEnv)
        XCTAssertEqual(scrubbed["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(scrubbed["HOME"], "/Users/test")
        XCTAssertNil(scrubbed["NANOTEAMS_MCP_PORT"])
        XCTAssertNil(scrubbed["NANOTEAMS_MCP_TOKEN"])
        XCTAssertNil(scrubbed["nanoteams_mcp_custom"])
        XCTAssertNil(scrubbed["NANOTEAMS_TOKEN"])

        // Port resolution from NANOTEAMS_MCP_PORT
        XCTAssertEqual(
            HostedMCPEnvironment.resolveServerPort(environment: ["NANOTEAMS_MCP_PORT": "49123"], configuredPort: 47321),
            49123
        )
        XCTAssertEqual(
            HostedMCPEnvironment.resolveServerPort(environment: ["NANOTEAMS_MCP_PORT": "80"], configuredPort: 48000),
            48000
        )
        XCTAssertEqual(
            HostedMCPEnvironment.resolveServerPort(environment: [:], configuredPort: 47321),
            47321
        )

        // Self-connection refusal in MCPEndpointPolicy
        MCPEndpointPolicy.setConfiguredHostedServerPort(47321)
        for selfURL in [
            "http://127.0.0.1:47321/mcp",
            "http://localhost:47321/mcp",
            "http://[::1]:47321/mcp",
            "https://[::ffff:127.0.0.1]:47321/mcp",
        ] {
            XCTAssertThrowsError(try MCPEndpointPolicy.validate(selfURL)) { error in
                XCTAssertEqual(
                    error as? MCPEndpointPolicy.Failure,
                    .hostedSelfConnection(port: 47321),
                    "Expected .hostedSelfConnection for \(selfURL), got \(error)"
                )
            }
            XCTAssertFalse(MCPEndpointPolicy.allows(selfURL))
        }

        // Other loopback ports remain allowed
        XCTAssertNoThrow(try MCPEndpointPolicy.validate("http://127.0.0.1:47322/mcp"))
        XCTAssertTrue(MCPEndpointPolicy.allows("http://127.0.0.1:47322/mcp"))
    }

    // MARK: - 8. ASCII-Only Hex In Tokens And /identify Nonces (§6, §7.2)

    /// `Character.isHexDigit` also accepts the fullwidth digits and letters, so a fullwidth
    /// nonce reached `computeIdentifyProof` and the unauthenticated route answered it.
    func testIdentifyAndTokenParsingAcceptOnlyASCIIHex() throws {
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try store.createAgent(label: "Hex Agent")
        let shortID = issued.record.shortID

        for nonce in [
            String(repeating: "\u{FF10}\u{FF41}", count: 8),
            String(repeating: "\u{FF21}\u{FF19}", count: 16),
            "0123456789abcde\u{FF46}",
            "0123456789abcdef0",
        ] {
            XCTAssertEqual(store.identify(shortID: shortID, nonceHex: nonce), .invalidNonce, nonce.debugDescription)
        }
        for nonce in ["0123456789ABCDEF", String(repeating: "0a", count: 32)] {
            guard case .success = store.identify(shortID: shortID, nonceHex: nonce) else {
                XCTFail("ASCII hex nonce \(nonce) must be answered")
                continue
            }
        }

        let secret = String(issued.token.split(separator: "_", maxSplits: 2)[2])
        let fullwidthShortID = String(String.UnicodeScalarView(shortID.unicodeScalars.map { scalar in
            Unicode.Scalar(scalar.value + 0xFEE0) ?? scalar
        }))
        XCTAssertEqual(fullwidthShortID.count, shortID.count)
        XCTAssertNotEqual(fullwidthShortID, shortID)
        XCTAssertEqual(store.verifyBearerToken("ntm_\(fullwidthShortID)_\(secret)"), .invalidToken)
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity))
    }

    // MARK: - 9. Revocation Commits On Persist, Even When The Keychain Delete Fails (§6)

    /// The persisted removal is the commit point: once `agents.json` no longer names the agent,
    /// its token cannot authenticate, so its in-flight work must be cancelled and the list
    /// refreshed even when the Keychain then refuses to delete the verifier. Before, that refusal
    /// threw after the removal had committed — no invalidation, no change notification, the
    /// caller told revoke failed, and a retry answering `agentNotFound`.
    func testRevokeCommitsCancelsAndNotifiesWhenOnlyTheKeychainDeleteFails() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let doomed = try store.createAgent(label: "Doomed")
        let bystander = try store.createAgent(label: "Bystander")
        let invalidated = StoreHandlerLog<UUID>()
        let changes = StoreHandlerLog<Int>()
        store.addInvalidationHandler { invalidated.append($0) }
        store.addChangeHandler { changes.append(1) }
        let doomedKey = doomed.record.id.uuidString
        secretStorage.writeFailure = { key, token in
            key == doomedKey && token == nil ? .unhandled(-25308) : nil
        }

        let outcome = try store.revokeAgent(agentID: doomed.record.id)

        XCTAssertEqual(outcome, .revokedLeavingVerifier)
        XCTAssertEqual(outcome.warning, "Agent revoked, but its token verifier could not be removed from the macOS Keychain.")
        XCTAssertEqual(invalidated.snapshot, [doomed.record.id], "its in-flight requests and waits are cancelled")
        XCTAssertEqual(changes.snapshot.count, 1, "the agent list refreshes")
        XCTAssertEqual(store.listAgents().map(\.id), [bystander.record.id])
        XCTAssertEqual(
            HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage).listAgents().map(\.id),
            [bystander.record.id],
            "agents.json no longer names the agent"
        )
        XCTAssertEqual(store.verifyBearerToken(doomed.token), .invalidToken)
        XCTAssertEqual(store.identify(shortID: doomed.record.shortID, nonceHex: "0123456789abcdef"), .agentNotFound)
        XCTAssertNotNil(try secretStorage.loadToken(forKey: doomedKey), "the verifier the Keychain kept is reported, not hidden")
        XCTAssertThrowsError(try store.revokeAgent(agentID: doomed.record.id)) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .agentNotFound(doomed.record.id))
        }
        XCTAssertEqual(store.verifyBearerToken(bystander.token), .authenticated(bystander.record.identity))

        secretStorage.writeFailure = nil
        let changesBeforeCleanRevoke = changes.snapshot.count
        let cleanOutcome = try store.revokeAgent(agentID: bystander.record.id)
        XCTAssertEqual(cleanOutcome, .revoked)
        XCTAssertNil(cleanOutcome.warning)
        XCTAssertNil(try secretStorage.loadToken(forKey: bystander.record.id.uuidString))
        XCTAssertEqual(invalidated.snapshot, [doomed.record.id, bystander.record.id])
        XCTAssertEqual(changes.snapshot.count, changesBeforeCleanRevoke + 1)
        XCTAssertTrue(store.listAgents().isEmpty)
    }

    // MARK: - 10. A Failed Write Leaves Records, Verifiers And lastSeenAt State As They Were (§6)

    func testKeychainWriteFailuresAndUnknownAgentsLeaveTheStoreUnchanged() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let changes = StoreHandlerLog<Int>()
        store.addChangeHandler { changes.append(1) }

        XCTAssertThrowsError(try store.rotateToken(agentID: UUID())) { error in
            guard case .agentNotFound = error as? HostedMCPAgentStoreError else {
                return XCTFail("expected agentNotFound, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.revokeAgent(agentID: UUID())) { error in
            guard case .agentNotFound = error as? HostedMCPAgentStoreError else {
                return XCTFail("expected agentNotFound, got \(error)")
            }
        }

        secretStorage.writeFailure = { _, token in token == nil ? nil : .unhandled(-25308) }
        XCTAssertThrowsError(try store.createAgent(label: "Never Stored")) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .keychainFailure("keychain_write_failed"))
        }
        XCTAssertTrue(store.listAgents().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.agentsFileURL.path))
        XCTAssertEqual(try secretStorage.accountNames(withPrefix: ""), [])
        secretStorage.writeFailure = nil

        let issued = try store.createAgent(label: "Keychain Agent")
        let key = issued.record.id.uuidString
        let verifierBefore = try XCTUnwrap(try secretStorage.loadToken(forKey: key))
        secretStorage.writeFailure = { _, token in token == nil ? nil : .unhandled(-25308) }
        XCTAssertThrowsError(try store.rotateToken(agentID: issued.record.id)) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .keychainFailure("keychain_write_failed"))
        }
        secretStorage.writeFailure = nil
        XCTAssertEqual(changes.snapshot.count, 1, "only the one create that committed notified")
        XCTAssertNil(store.agent(id: issued.record.id)?.rotatedAt)
        XCTAssertEqual(try secretStorage.loadToken(forKey: key), verifierBefore)
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity))

        let blockerFile = tempDir.appendingPathComponent("blocker-file")
        try Data("x".utf8).write(to: blockerFile)
        let blockedSecrets = InMemorySecureTokenStorage()
        let blockedStore = HostedMCPAgentStore(
            directoryURL: blockerFile.appendingPathComponent("nested", isDirectory: true),
            secretStorage: blockedSecrets
        )
        XCTAssertThrowsError(try blockedStore.createAgent(label: "Blocked")) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .storageWriteFailed("directory_create_failed"))
        }
        XCTAssertTrue(blockedStore.listAgents().isEmpty)
        XCTAssertEqual(try blockedSecrets.accountNames(withPrefix: ""), [], "the verifier written before the failed save is rolled back")
    }

    /// Every persist failure is rolled back whole: the record, the verifier, and the `lastSeenAt`
    /// bookkeeping. A revoke that could not save used to re-insert the record but drop its
    /// "dirty lastSeenAt" mark, so the shutdown flush silently skipped it.
    func testFailedPersistLeavesRecordsVerifiersAndLastSeenStateAsTheyWere() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let clock = StoreTestClock(Date(timeIntervalSince1970: 1_759_971_200))
        let store = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage,
            lastSeenPersistenceInterval: 3600,
            now: { clock.now }
        )
        let issued = try store.createAgent(label: "Persist Agent")
        let key = issued.record.id.uuidString
        let verifierBefore = try XCTUnwrap(try secretStorage.loadToken(forKey: key))
        let changes = StoreHandlerLog<Int>()
        let invalidated = StoreHandlerLog<UUID>()
        store.addChangeHandler { changes.append(1) }
        store.addInvalidationHandler { invalidated.append($0) }

        clock.now = Date(timeIntervalSince1970: 1_759_971_210)
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity))

        // Block agents.json: a non-empty directory where the file goes.
        let fm = FileManager.default
        try fm.removeItem(at: store.agentsFileURL)
        try fm.createDirectory(at: store.agentsFileURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.agentsFileURL.appendingPathComponent("keep"))

        XCTAssertThrowsError(try store.createAgent(label: "Never Stored")) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .storageWriteFailed("file_write_failed"))
        }
        XCTAssertEqual(store.listAgents().map(\.id), [issued.record.id])
        XCTAssertEqual(try secretStorage.accountNames(withPrefix: ""), [key], "the new agent's verifier is rolled back")

        XCTAssertThrowsError(try store.rotateToken(agentID: issued.record.id)) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .storageWriteFailed("file_write_failed"))
        }
        XCTAssertNil(store.agent(id: issued.record.id)?.rotatedAt, "the record is restored")
        XCTAssertEqual(try secretStorage.loadToken(forKey: key), verifierBefore, "the previous verifier is restored")
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity), "the old token still verifies")

        // A verification inside the hour only marks lastSeenAt dirty; the failed revoke must keep that mark.
        let lastVerification = Date(timeIntervalSince1970: 1_759_971_230)
        clock.now = lastVerification
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity))

        XCTAssertThrowsError(try store.revokeAgent(agentID: issued.record.id)) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .storageWriteFailed("file_write_failed"))
        }
        XCTAssertEqual(store.listAgents().map(\.id), [issued.record.id], "the agent is still listed")
        XCTAssertEqual(try secretStorage.loadToken(forKey: key), verifierBefore)
        XCTAssertTrue(invalidated.snapshot.isEmpty, "nothing committed, so nothing is cancelled")

        try fm.removeItem(at: store.agentsFileURL)
        try store.flushPendingLastSeenWrites()
        let reloaded = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        XCTAssertEqual(reloaded.agent(id: issued.record.id)?.lastSeenAt, lastVerification)
        XCTAssertNil(reloaded.agent(id: issued.record.id)?.rotatedAt)
        XCTAssertEqual(changes.snapshot.count, 3, "the three verifications notified; no failed create, rotate or revoke did")
    }

    /// Rotation writes the new verifier first and, when `agents.json` then cannot be saved, puts
    /// back the verifier it read. When the Keychain does not answer the read, the verifier there
    /// may be a good one it could not put back, so the rotation does not start. RED before
    /// 2026-11-07: `try?` read that as "none", the failed save's rollback DELETED the working
    /// verifier, and the rotation threw — the agent's token answered 401 and no new token was
    /// shown (review records-c6). A CORRUPT entry still rotates: that is how the person repairs
    /// one (`testMalformedVerifierOfARegisteredAgentFailsClosedInVerifyAndIdentify`).
    func testRotationRefusesWhenTheKeychainDoesNotAnswerTheRead_andTheOldTokenStillWorks() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let issued = try store.createAgent(label: "Locked Keychain Agent")
        let key = issued.record.id.uuidString
        let verifierBefore = try XCTUnwrap(try secretStorage.loadToken(forKey: key))

        // Block agents.json — a non-empty directory where the file goes — so the save fails
        // after the rotation's Keychain write.
        let fm = FileManager.default
        try fm.removeItem(at: store.agentsFileURL)
        try fm.createDirectory(at: store.agentsFileURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.agentsFileURL.appendingPathComponent("keep"))
        secretStorage.readError = .unhandled(-25308) // errSecInteractionNotAllowed: a locked Keychain

        XCTAssertThrowsError(try store.rotateToken(agentID: issued.record.id)) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .keychainFailure("keychain_unavailable"))
        }

        secretStorage.readError = nil
        XCTAssertEqual(try secretStorage.loadToken(forKey: key), verifierBefore, "the working verifier is left as it was")
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity), "the agent's token still works")
        XCTAssertNil(store.agent(id: issued.record.id)?.rotatedAt)
    }

    /// An agent with no verifier at all rotates normally: there is nothing to put back, so a
    /// failed save removes the verifier the rotation wrote.
    func testRotationOfAnAgentWithNoVerifier_rollsBackToNoVerifier() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let issued = try store.createAgent(label: "Verifier-less Agent")
        let key = issued.record.id.uuidString
        try secretStorage.setToken(nil, forKey: key)
        let fm = FileManager.default
        try fm.removeItem(at: store.agentsFileURL)
        try fm.createDirectory(at: store.agentsFileURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.agentsFileURL.appendingPathComponent("keep"))

        XCTAssertThrowsError(try store.rotateToken(agentID: issued.record.id)) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .storageWriteFailed("file_write_failed"))
        }
        XCTAssertEqual(try secretStorage.accountNames(withPrefix: ""), [], "the rotation's own verifier is rolled back")
    }

    /// A `lastSeenAt` write that fails never fails the verification: the agent is authenticated,
    /// the stamp stays dirty in memory, and the shutdown flush persists it once the disk is back.
    func testAVerificationWhoseLastSeenWriteFailsStillAuthenticatesAndIsFlushedLater() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let clock = StoreTestClock(Date(timeIntervalSince1970: 1_759_971_200))
        let store = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage,
            lastSeenPersistenceInterval: 0,
            now: { clock.now }
        )
        let issued = try store.createAgent(label: "Unwritable Agent")
        let fm = FileManager.default
        try fm.removeItem(at: store.agentsFileURL)
        try fm.createDirectory(at: store.agentsFileURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.agentsFileURL.appendingPathComponent("keep"))

        let seenAt = Date(timeIntervalSince1970: 1_759_971_250)
        clock.now = seenAt
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity))
        XCTAssertEqual(store.agent(id: issued.record.id)?.lastSeenAt, seenAt)
        XCTAssertThrowsError(try store.flushPendingLastSeenWrites(), "the disk is still refusing the write")

        try fm.removeItem(at: store.agentsFileURL)
        try store.flushPendingLastSeenWrites()
        XCTAssertEqual(HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage).agent(id: issued.record.id)?.lastSeenAt, seenAt)
        XCTAssertNoThrow(try store.flushPendingLastSeenWrites(), "nothing is pending once flushed")
    }

    // MARK: - 11. A Malformed Stored Verifier Of A Registered Agent Authenticates Nothing (§6)

    // MARK: - The two environment presets

    /// `.inert`, what every test orchestrator gets, touches nothing real: a temporary directory,
    /// an in-memory secret store in a DEBUG build, no process environment, no auto-start. Until
    /// 2026-11-07 the presets' closures ran only inside a test that opened the real default
    /// storage; that test was fixed (it now points the last opened folder at a temporary one),
    /// and nothing evaluated them any more.
    func testTheInertPresetTouchesNothingReal() {
        let inert = HostedMCPEnvironment.inert
        XCTAssertTrue(inert.directoryURL().path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(inert.secretStorage() is InMemorySecureTokenStorage)
        XCTAssertEqual(inert.processEnvironment(), [:])
        XCTAssertFalse(inert.allowAutoStart)
        XCTAssertLessThan(abs(inert.now().timeIntervalSinceNow), 60)
        // Token files go under a temporary folder in every test: a test writing into the real
        // `~/.claude` would hand its token to the developer's Claude Code (#375).
        XCTAssertTrue(inert.clientHomeDirectory().path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertNotEqual(inert.clientHomeDirectory().standardizedFileURL.path, NSHomeDirectory())
    }

    /// The tab was renamed Agent Access → External Agents on 2026-11-08; what it had already
    /// stored keeps the old spelling. A new one would read as nothing stored: the switch off,
    /// the port back at its default, no agent's verifier found — every issued token refused —
    /// and the beta gate back up in front of a person who had accepted it.
    func testStoredNames_keepTheTabsFormerName() {
        XCTAssertEqual(UserDefaultsKeys.externalAgentsEnabled, "NanoTeams.agentAccess.enabled.v1")
        XCTAssertEqual(UserDefaultsKeys.externalAgentsPort, "NanoTeams.agentAccess.port.v1")
        XCTAssertEqual(HostedMCPConstants.keychainService, "com.nanoteams.agentaccess.v1")
        XCTAssertEqual(HostedMCPConstants.externalAgentsSubdirectory, "agent-access")
        XCTAssertEqual(BetaFeature.externalAgents.rawValue, "agentAccess")
    }

    /// `.live` keeps the agents in the app's own Application Support folder and their verifiers
    /// under the hosted server's own Keychain service — never the MCP client's, whose sweep deletes
    /// the accounts it does not know — and it never starts the server itself inside a test process.
    /// Constructing a `KeychainSecureTokenStorage` only records its service; no item is read.
    func testTheLivePresetUsesTheAppsOwnStores_andDoesNotAutoStartUnderXCTest() throws {
        let live = HostedMCPEnvironment.live
        let directory = live.directoryURL()
        XCTAssertEqual(directory.lastPathComponent, HostedMCPConstants.externalAgentsSubdirectory)
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "NanoTeams")
        let storage = try XCTUnwrap(live.secretStorage() as? KeychainSecureTokenStorage)
        XCTAssertEqual(storage.service, HostedMCPConstants.keychainService)
        XCTAssertNotEqual(storage.service, KeychainSecureTokenStorage.defaultService)
        XCTAssertEqual(live.processEnvironment()["HOME"], ProcessInfo.processInfo.environment["HOME"])
        XCTAssertFalse(live.allowAutoStart, "XCTest is loaded, so the live server must not start itself here")
        XCTAssertLessThan(abs(live.now().timeIntervalSinceNow), 60)
        // In the app the token files go into the person's own client folders — where the clients
        // read them, and where the sandbox denies every role (#375).
        XCTAssertEqual(live.clientHomeDirectory().path, NSHomeDirectory())
    }

    func testMalformedVerifierOfARegisteredAgentFailsClosedInVerifyAndIdentify() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let issued = try store.createAgent(label: "Corrupt Verifier Agent")
        let key = issued.record.id.uuidString
        let nonce = "0123456789abcdef0123456789abcdef"

        for corrupt in [
            "deadbeef",
            String(repeating: "z", count: 64),
            String(repeating: "a", count: 63),
            String(repeating: "ab", count: 33),
        ] {
            try secretStorage.setToken(corrupt, forKey: key)
            XCTAssertEqual(
                store.listAgents().map(\.id), [issued.record.id],
                "anti-vacuum: the agent is still registered, so its record guard cannot be what answers"
            )
            XCTAssertEqual(store.verifyBearerToken(issued.token), .invalidToken, corrupt)
            XCTAssertEqual(store.identify(shortID: issued.record.shortID, nonceHex: nonce), .agentNotFound, corrupt)
        }

        try secretStorage.setToken(nil, forKey: key)
        XCTAssertEqual(store.verifyBearerToken(issued.token), .invalidToken)
        XCTAssertEqual(store.identify(shortID: issued.record.shortID, nonceHex: nonce), .agentNotFound)

        secretStorage.storeCorruptEntry(forKey: key)
        XCTAssertEqual(store.verifyBearerToken(issued.token), .storageFailure("keychain_unavailable"))
        XCTAssertEqual(store.identify(shortID: issued.record.shortID, nonceHex: nonce), .storageFailure("keychain_unavailable"))

        let repaired = try store.rotateToken(agentID: issued.record.id)
        XCTAssertEqual(store.verifyBearerToken(repaired.token), .authenticated(issued.record.identity))

        for malformed in [
            "ntm_zzzzzzzz_secret",
            "ntm_\(issued.record.shortID)_",
            "ntm_\(issued.record.shortID)",
            "ntm_\(issued.record.shortID.dropLast())_secret",
            "xyz_\(issued.record.shortID)_secret",
        ] {
            XCTAssertEqual(store.verifyBearerToken(malformed), .invalidToken, malformed)
        }
    }

    // MARK: - 12. The Work Folder Context Permission (decision A3 revised, 2026-11-13)

    /// The person's switch for `set_work_folder_context` is part of the record: off for a new
    /// agent, written to `agents.json` when flipped, read back by the next launch.
    func testContextPermission_isOffForANewAgent_andSurvivesAReload() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let issued = try store.createAgent(label: "Claude Code")
        XCTAssertFalse(issued.record.mayReplaceWorkFolderContext, "a new agent may not replace the context")
        XCTAssertEqual(try storedPermissions(), [issued.record.id.uuidString: false], "the key is written from the start")

        try store.setMayReplaceWorkFolderContext(true, agentID: issued.record.id)
        XCTAssertEqual(store.agent(id: issued.record.id)?.mayReplaceWorkFolderContext, true)
        XCTAssertEqual(try storedPermissions(), [issued.record.id.uuidString: true])
        XCTAssertEqual(
            HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
                .agent(id: issued.record.id)?.mayReplaceWorkFolderContext,
            true, "the next launch reads the switch as the person left it")

        try store.setMayReplaceWorkFolderContext(false, agentID: issued.record.id)
        XCTAssertEqual(
            HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
                .agent(id: issued.record.id)?.mayReplaceWorkFolderContext,
            false, "turning it off is written too")
    }

    /// `loadRecordsFromDisk` reads `agents.json` as ONE array, so a record that fails to decode
    /// empties the list. A file from before 2026-11-13 has no `may_replace_work_folder_context`;
    /// every agent in it must load, with the switch off. RED with a synthesized decoder: the
    /// missing key failed the array and every registered agent disappeared.
    func testAnAgentsFileFromBeforeThePermission_loadsEveryAgent_withTheSwitchOff() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("""
        [
          {"id":"A4C36525-0000-4000-8000-000000000001","short_id":"a4c36525","label":"Claude Code",
           "created_at":"2026-11-08T00:00:00Z","last_seen_at":"2026-11-12T00:00:00Z"},
          {"id":"B7D10F33-0000-4000-8000-000000000002","short_id":"b7d10f33","label":"Codex",
           "created_at":"2026-11-09T00:00:00Z","rotated_at":"2026-11-10T00:00:00Z","client_kind":"codex"}
        ]
        """.utf8).write(to: tempDir.appendingPathComponent(HostedMCPConstants.agentsFileName))

        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let agents = store.listAgents()
        XCTAssertEqual(agents.map(\.label), ["Claude Code", "Codex"], "no agent is lost to the new key")
        XCTAssertEqual(agents.map(\.mayReplaceWorkFolderContext), [false, false])
        XCTAssertEqual(agents.last?.rotatedAt, ISO8601DateFormatter().date(from: "2026-11-10T00:00:00Z"),
                       "the keys beside it still decode")
    }

    /// A value of the wrong type is not an absent key: the record is undecodable, as any other
    /// mistyped key makes it — the switch is never read as on from something that is not `true`.
    func testAPermissionThatIsNotABool_failsTheRecord_ratherThanReadingAsOn() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(HostedMCPAgentRecord.self, from: Data("""
        {"id":"A4C36525-0000-4000-8000-000000000001","short_id":"a4c36525","label":"x",
         "created_at":"2026-11-08T00:00:00Z","may_replace_work_folder_context":"yes"}
        """.utf8)))
    }

    /// The switch governs what the agent may do, not who it is: a reissued token keeps it, and
    /// flipping it cancels nothing — no call in flight, no wait.
    func testRotationKeepsThePermission_andFlippingItInvalidatesNothing() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let issued = try store.createAgent(label: "Cursor")
        let invalidated = StoreHandlerLog<UUID>()
        store.addInvalidationHandler { invalidated.append($0) }

        try store.setMayReplaceWorkFolderContext(true, agentID: issued.record.id)
        XCTAssertTrue(invalidated.snapshot.isEmpty, "the switch cancels no call of the agent's")
        XCTAssertEqual(store.verifyBearerToken(issued.token), .authenticated(issued.record.identity),
                       "the token still authenticates")

        let rotated = try store.rotateToken(agentID: issued.record.id)
        XCTAssertTrue(rotated.record.mayReplaceWorkFolderContext, "a reissued token keeps the switch")
        XCTAssertEqual(
            HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
                .agent(id: issued.record.id)?.mayReplaceWorkFolderContext,
            true)
    }

    /// A change notifies the page once; setting the value the record already holds writes
    /// nothing and notifies no one.
    func testSettingThePermission_notifiesOncePerChange_andTheSameValueIsANoOp() throws {
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try store.createAgent(label: "Gemini CLI")
        let changes = StoreHandlerLog<Int>()
        store.addChangeHandler { changes.append(1) }
        let written = try modificationDate(of: store.agentsFileURL)

        try store.setMayReplaceWorkFolderContext(false, agentID: issued.record.id)
        XCTAssertTrue(changes.snapshot.isEmpty, "the switch was already off")
        XCTAssertEqual(try modificationDate(of: store.agentsFileURL), written, "nothing is written")

        try store.setMayReplaceWorkFolderContext(true, agentID: issued.record.id)
        try store.setMayReplaceWorkFolderContext(true, agentID: issued.record.id)
        XCTAssertEqual(changes.snapshot.count, 1, "one change, one notification")
    }

    /// An agent that is not registered — revoked between the page drawing its row and the click —
    /// is refused by name, and no other agent's record moves.
    func testSettingThePermissionOfAnUnknownAgent_throwsAgentNotFound_andChangesNoOtherAgent() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let kept = try store.createAgent(label: "Kept")
        let revoked = try store.createAgent(label: "Revoked")
        try store.revokeAgent(agentID: revoked.record.id)
        let changes = StoreHandlerLog<Int>()
        store.addChangeHandler { changes.append(1) }

        for agentID in [revoked.record.id, UUID()] {
            XCTAssertThrowsError(try store.setMayReplaceWorkFolderContext(true, agentID: agentID)) { error in
                XCTAssertEqual(error as? HostedMCPAgentStoreError, .agentNotFound(agentID))
            }
        }
        XCTAssertEqual(store.listAgents().map(\.id), [kept.record.id])
        XCTAssertEqual(store.agent(id: kept.record.id)?.mayReplaceWorkFolderContext, false)
        XCTAssertTrue(changes.snapshot.isEmpty)
    }

    /// Writing `agents.json` is the commit point: when it fails, the switch shows what is stored.
    func testAFailedWrite_leavesThePermissionAsItWas_andNotifiesNoOne() throws {
        let secretStorage = InMemorySecureTokenStorage()
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let issued = try store.createAgent(label: "Blocked")
        let changes = StoreHandlerLog<Int>()
        store.addChangeHandler { changes.append(1) }

        // Block agents.json: a non-empty directory where the file goes.
        let fm = FileManager.default
        try fm.removeItem(at: store.agentsFileURL)
        try fm.createDirectory(at: store.agentsFileURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.agentsFileURL.appendingPathComponent("keep"))

        XCTAssertThrowsError(try store.setMayReplaceWorkFolderContext(true, agentID: issued.record.id)) { error in
            XCTAssertEqual(error as? HostedMCPAgentStoreError, .storageWriteFailed("file_write_failed"))
        }
        XCTAssertEqual(store.agent(id: issued.record.id)?.mayReplaceWorkFolderContext, false)
        XCTAssertTrue(changes.snapshot.isEmpty, "nothing committed, so nothing is announced")
    }

    /// `may_replace_work_folder_context` of every record in `agents.json`, keyed by agent id.
    private func storedPermissions() throws -> [String: Bool] {
        let data = try Data(contentsOf: tempDir.appendingPathComponent(HostedMCPConstants.agentsFileName))
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var permissions: [String: Bool] = [:]
        for row in rows {
            let id = try XCTUnwrap(row["id"] as? String)
            permissions[id] = row["may_replace_work_folder_context"] as? Bool
        }
        return permissions
    }

    private func modificationDate(of url: URL) throws -> Date {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }
}

/// Collects what store handlers saw; handlers may run on any thread.
private final class StoreHandlerLog<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var snapshot: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private final class StoreTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ initial: Date) {
        value = initial
    }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
