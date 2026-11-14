import Foundation
import Network
import XCTest

@testable import NanoTeams

final class HostedMCPListenerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostedMCPListenerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        MCPEndpointPolicy.setConfiguredHostedServerPort(HostedMCPConstants.defaultPort)
        try super.tearDownWithError()
    }

    // MARK: - 1. Dual-Stack Bind (127.0.0.1 & [::1]) on Ephemeral Port 0 (§7.1)

    func testDualStackLoopbackBindOnEphemeralPortAndBothIPv4AndIPv6ReachIdentifyAndMCP() async throws {
        let secretStorage = InMemorySecureTokenStorage()
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage,
            appVersion: "2.5.0",
            processIdentifier: 1234
        )
        let issued = try agentStore.createAgent(label: "DualStack Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(
                    toolName: name,
                    argumentsJSON: "{}",
                    outputJSON: #"{"status":"ready"}"#,
                    isError: false
                )
            },
            agentTextVersion: "test-agent-text-version"
        )
        let frameLog = HostedMCPFrameLog()
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: dispatcher,
            frameLog: frameLog
        )
        defer {
            Task { await listener.stop() }
        }

        let port = try await listener.start(port: 0)
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(listener.boundPort, port)
        XCTAssertEqual(listener.state, HostedMCPListenerState.listening(port: port))

        // 1. GET /identify over IPv4 (127.0.0.1)
        let nonce = "0123456789abcdef0123456789abcdef"
        let v4IdentifyURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/identify?agent=\(issued.record.shortID)&nonce=\(nonce)")
        )
        let (v4Data, v4Resp) = try await URLSession.shared.data(from: v4IdentifyURL)
        let v4HTTP = try XCTUnwrap(v4Resp as? HTTPURLResponse)
        XCTAssertEqual(v4HTTP.statusCode, 200)
        let v4Payload = try JSONDecoder().decode(HostedMCPIdentifyPayload.self, from: v4Data)
        XCTAssertEqual(v4Payload.app, "NanoTeams")
        XCTAssertEqual(v4Payload.version, "2.5.0")
        XCTAssertEqual(v4Payload.pid, 1234)
        XCTAssertEqual(v4Payload.proof.count, 64)

        // 2. POST /mcp (ping) over IPv6 ([::1])
        let v6MCPURL = try XCTUnwrap(URL(string: "http://[::1]:\(port)/mcp"))
        var v6Req = URLRequest(url: v6MCPURL)
        v6Req.httpMethod = "POST"
        v6Req.setValue("Bearer \(issued.token)", forHTTPHeaderField: "Authorization")
        v6Req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        v6Req.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        v6Req.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

        let (v6Data, v6Resp) = try await URLSession.shared.data(for: v6Req)
        let v6HTTP = try XCTUnwrap(v6Resp as? HTTPURLResponse)
        XCTAssertEqual(v6HTTP.statusCode, 200)
        let v6Text = String(decoding: v6Data, as: UTF8.self)
        XCTAssertTrue(v6Text.contains(#""result":{}"#))

        XCTAssertGreaterThanOrEqual(frameLog.entries().count, 2)
        await listener.stop()
        XCTAssertEqual(listener.state, HostedMCPListenerState.stopped)
        XCTAssertNil(listener.boundPort)
    }

    // MARK: - 2. "Both or Neither" Startup When One Loopback Address Is Busy (§7.1)

    func testPortInUseWhenEitherIPv4OrIPv6IsOccupiedClosesBothAndSurfacesPortInUseError() async throws {
        // Bind a raw IPv6 loopback socket on [::1] with an ephemeral port so [::1]:P is busy while 127.0.0.1:P is free!
        let v6Socket = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(v6Socket, 0)
        defer {
            if v6Socket >= 0 { close(v6Socket) }
        }

        var v6Only: Int32 = 1
        _ = setsockopt(v6Socket, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))

        var addr6 = sockaddr_in6()
        addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = 0
        addr6.sin6_addr = in6addr_loopback

        let bindResult = withUnsafePointer(to: &addr6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(v6Socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(Darwin.listen(v6Socket, 4), 0)

        var boundAddr = sockaddr_in6()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(v6Socket, $0, &addrLen)
            }
        }
        XCTAssertEqual(nameResult, 0)
        let occupiedPort = UInt16(bigEndian: boundAddr.sin6_port)
        XCTAssertGreaterThan(occupiedPort, 0)

        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "test-agent-text-version"
        )
        let listener = HostedMCPListener(agentStore: agentStore, dispatcher: dispatcher)
        defer {
            Task { await listener.stop() }
        }

        do {
            _ = try await listener.start(port: occupiedPort)
            XCTFail("Expected start(port:) to fail with .portInUse when [::1]:\(occupiedPort) is occupied")
        } catch let error as HostedMCPListenerError {
            XCTAssertEqual(error, .portInUse(occupiedPort))
            XCTAssertEqual(error.message, "Port in use")
        }

        XCTAssertEqual(listener.state, HostedMCPListenerState.failed(.portInUse(occupiedPort)))
        XCTAssertNil(listener.boundPort)

        // Verify 127.0.0.1:occupiedPort was closed by listener cleanup and is still bindable!
        let v4Socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(v4Socket, 0)
        defer {
            if v4Socket >= 0 { close(v4Socket) }
        }
        var addr4 = sockaddr_in()
        addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr4.sin_family = sa_family_t(AF_INET)
        addr4.sin_port = occupiedPort.bigEndian
        addr4.sin_addr.s_addr = inet_addr("127.0.0.1")
        let v4BindResult = withUnsafePointer(to: &addr4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(v4Socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(v4BindResult, 0, "127.0.0.1:\(occupiedPort) must be closed when [::1]:\(occupiedPort) fails to bind")
    }

    // MARK: - 3. End-to-End MCPClient over StreamableHTTPTransport & Self-Connection Guard (§7.1, §10.2)

    @MainActor
    func testEndToEndMCPClientOverStreamableHTTPAgainstHostedMCPListener() async throws {
        let secretStorage = InMemorySecureTokenStorage()
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage
        )
        let frameLog = HostedMCPFrameLog(
            directoryURL: tempDir,
            refusalCoalesceWindowSeconds: 0
        )
        let orchestrator = TestOrchestrator.make(
            hostedMCPAgentStore: agentStore,
            hostedMCPFrameLog: frameLog
        )
        let folderURL = tempDir.appendingPathComponent("e2e-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        await orchestrator.openWorkFolder(folderURL)
        if let nonChat = orchestrator.snapshot?.workFolder.teams.first(where: { !$0.isChatMode && !$0.isHiddenFromPickers }) {
            await orchestrator.mutateWorkFolder { $0.setActiveTeam(nonChat.id) }
        }
        await orchestrator.setAutovisorDriver(.externalAgent)
        await orchestrator.setAutovisorEnabled(true)

        let issued = try agentStore.createAgent(label: "E2E MCPClient")
        let tokenSecretPart = String(issued.token.split(separator: "_", maxSplits: 2)[2])
        let port = try await orchestrator.startHostedMCPServer(port: 0)
        defer {
            Task { @MainActor in await orchestrator.stopHostedMCPServer() }
        }

        // Configure MCPEndpointPolicy's blocked self-port to default 47321 so our ephemeral test port can be dialled by StreamableHTTPTransport in this E2E test.
        MCPEndpointPolicy.setConfiguredHostedServerPort(HostedMCPConstants.defaultPort)

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        let timeouts = MCPTimeouts(connect: 5, requestInactivity: 5, requestAbsolute: 10)

        func extractToolText(_ result: MCPCallToolResult) -> String {
            result.contentBlocks.first?.objectValue?["text"]?.stringValue ?? ""
        }

        for cachedEra in [nil, MCPProtocolEra.legacy] {
            let session = MCPURLSession(timeouts: timeouts)
            let authorizer = StaticBearerAuthorizer(
                bearerKey: "k",
                storage: InMemorySecureTokenStorage(initial: ["k": issued.token])
            )
            let transport = StreamableHTTPTransport(
                config: MCPHTTPConfig(urlString: url.absoluteString),
                authorizer: authorizer,
                session: session,
                timeouts: timeouts
            )
            let client = MCPClient(transport: transport, log: nil, timeouts: timeouts, clientVersion: "1.0")
            let connection = try await client.connect(cachedEra: cachedEra)
            XCTAssertEqual(connection.era, cachedEra ?? .modern)

            let tools = try await client.listAllTools()
            let toolNames = tools.compactMap { $0.objectValue?["name"]?.stringValue }
            XCTAssertEqual(toolNames, ExternalAutovisorToolNames.all)
            XCTAssertTrue(toolNames.contains(ExternalAutovisorToolNames.folderStatus))

            // 1. folder_status
            let statusCall = try await client.callTool(
                originalName: ExternalAutovisorToolNames.folderStatus,
                arguments: .object([:])
            )
            let statusText = extractToolText(statusCall)
            XCTAssertFalse(statusCall.isError, statusText)
            let statusJSON = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(statusText.utf8)) as? [String: Any]
            )
            let statusData = try XCTUnwrap(statusJSON["data"] as? [String: Any])
            let folderID = try XCTUnwrap(statusData["folder_id"] as? String)
            let initialCursor = try XCTUnwrap(statusData["event_cursor"] as? String)

            // 2. create_managed_task, then drive question -> answer -> result -> close
            let createCall = try await client.callTool(
                originalName: ExternalAutovisorToolNames.createManagedTask,
                arguments: .object([
                    "folder_id": .string(folderID),
                    "title": .string("E2E Task (\(connection.era))"),
                    // The agent's own token, pasted into an argument: the full call kept for the
                    // pane must not carry it (asserted at the end, over `external_calls/`).
                    "brief": .string("Verify full external autovisor lifecycle — token \(issued.token)"),
                ])
            )
            let createText = extractToolText(createCall)
            XCTAssertFalse(createCall.isError, createText)
            let createJSON = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(createText.utf8)) as? [String: Any]
            )
            let createData = try XCTUnwrap(createJSON["data"] as? [String: Any])
            let taskID = try XCTUnwrap(createData["task_id"] as? Int)

            // 3. Stop the auto-started engine so we can deterministically stage a role question and verify wait_for_events delivers it
            orchestrator.stopEngine(for: taskID)
            let askNow = Date()
            _ = await orchestrator.mutateTask(taskID: taskID) { task in
                let step = StepExecution(
                    id: "architect",
                    role: .techLead,
                    title: "Architect",
                    status: .needsSupervisorInput,
                    updatedAt: askNow,
                    toolCalls: [
                        StepToolCall(
                            id: UUID(),
                            createdAt: askNow,
                            name: ToolNames.askSupervisor,
                            argumentsJSON: #"{"question":"Use SQLite or CoreData?"}"#,
                            resultJSON: #"{"ok":true}"#
                        )
                    ],
                    needsSupervisorInput: true,
                    supervisorQuestion: "Use SQLite or CoreData?"
                )
                task.runs = [Run(id: 0, steps: [step], roleStatuses: ["architect": .working])]
            }

            let waitCall = try await client.callTool(
                originalName: ExternalAutovisorToolNames.waitForEvents,
                arguments: .object([
                    "after": .string(initialCursor),
                    "timeout_seconds": .int(5),
                ])
            )
            let waitText = extractToolText(waitCall)
            XCTAssertFalse(waitCall.isError, waitText)
            XCTAssertTrue(waitText.contains("Use SQLite or CoreData?"), waitText)

            // 4. answer_task_question
            let answerCall = try await client.callTool(
                originalName: ExternalAutovisorToolNames.answerTaskQuestion,
                arguments: .object([
                    "folder_id": .string(folderID),
                    "task_id": .int(taskID),
                    "role_id": .string("architect"),
                    "answer": .string("Use SQLite."),
                ])
            )
            let answerText = extractToolText(answerCall)
            XCTAssertFalse(answerCall.isError, answerText)

            // 5. Stop the resumed engine, complete the step, and call task_result
            orchestrator.stopEngine(for: taskID)
            _ = await orchestrator.mutateTask(taskID: taskID) { task in
                var step = task.runs[0].steps[0]
                step.status = .done
                step.needsSupervisorInput = false
                step.messages.append(
                    StepMessage(role: .techLead, content: "Implemented SQLite persistence layer.")
                )
                task.runs = [Run(id: 0, steps: [step], roleStatuses: ["architect": .done])]
            }

            let resultCall = try await client.callTool(
                originalName: ExternalAutovisorToolNames.taskResult,
                arguments: .object([
                    "folder_id": .string(folderID),
                    "task_id": .int(taskID),
                ])
            )
            let resultText = extractToolText(resultCall)
            XCTAssertFalse(resultCall.isError, resultText)
            XCTAssertTrue(resultText.contains("Implemented SQLite persistence layer."), resultText)

            // 6. control_task (close)
            let closeCall = try await client.callTool(
                originalName: ExternalAutovisorToolNames.controlTask,
                arguments: .object([
                    "folder_id": .string(folderID),
                    "task_id": .int(taskID),
                    "action": .string("close"),
                ])
            )
            let closeText = extractToolText(closeCall)
            XCTAssertFalse(closeCall.isError, closeText)

            await client.close()
        }

        // Verify 401 on wrong token over HTTP
        var badAuthReq = URLRequest(url: url)
        badAuthReq.httpMethod = "POST"
        badAuthReq.setValue("Bearer ntm_\(issued.record.shortID)_" + String(repeating: "Z", count: 43), forHTTPHeaderField: "Authorization")
        badAuthReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        badAuthReq.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let (_, badAuthResp) = try await URLSession.shared.data(for: badAuthReq)
        XCTAssertEqual((badAuthResp as? HTTPURLResponse)?.statusCode, 401)

        // Verify 503 (never 401) when Keychain read fails over HTTP
        secretStorage.readError = KeychainError.unhandled(-25308)
        var kcReq = URLRequest(url: url)
        kcReq.httpMethod = "POST"
        kcReq.setValue("Bearer \(issued.token)", forHTTPHeaderField: "Authorization")
        kcReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        kcReq.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let (_, kcResp) = try await URLSession.shared.data(for: kcReq)
        XCTAssertEqual((kcResp as? HTTPURLResponse)?.statusCode, 503)
        secretStorage.readError = nil

        // Verify neither the frame log file nor the external activity log file contains the token or its secret
        let frameLogFile = tempDir.appendingPathComponent(HostedMCPConstants.frameLogFileName)
        let frameLogContents = (try? String(contentsOf: frameLogFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(frameLogContents.isEmpty)
        XCTAssertFalse(frameLogContents.contains(issued.token))
        XCTAssertFalse(frameLogContents.contains(tokenSecretPart))

        orchestrator.externalActivityLog.flush()
        let activityLogFile = NTMSPaths(workFolderRoot: folderURL).externalActivityLogJSONL
        let activityLogContents = (try? String(contentsOf: activityLogFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(activityLogContents.isEmpty)
        XCTAssertFalse(activityLogContents.contains(issued.token))
        XCTAssertFalse(activityLogContents.contains(tokenSecretPart))

        // The full calls beside the log hold whole bodies — the brief above included — and the
        // token is still not among them.
        let callsDir = ExternalAutovisorActivityLog.callsDirectoryURL(for: activityLogFile)
        let callFiles = (try? FileManager.default.contentsOfDirectory(at: callsDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertFalse(callFiles.isEmpty, "the calls of this session are kept in full")
        var sawBrief = false
        for file in callFiles {
            let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            XCTAssertFalse(contents.contains(issued.token), file.lastPathComponent)
            XCTAssertFalse(contents.contains(tokenSecretPart), file.lastPathComponent)
            sawBrief = sawBrief || contents.contains("Verify full external autovisor lifecycle")
        }
        XCTAssertTrue(sawBrief, "the brief's call is among them, scrubbed rather than dropped")
    }

    // MARK: - 4. Connection Cap, Header-Phase Eviction & Reserved Non-Wait Slots (§7.1)

    func testConnectionCapEvictsOldestHeaderPhaseConnectionAndReservesNonWaitSlots() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let issued = try agentStore.createAgent(label: "Slot Test Agent")

        final class ReleaseFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isReleased: Bool {
                lock.lock(); defer { lock.unlock() }; return value
            }
            func release() {
                lock.lock(); value = true; lock.unlock()
            }
        }
        let waitGate = ReleaseFlag()
        let waitEntered = expectation(description: "2 wait_for_events calls entered")
        waitEntered.expectedFulfillmentCount = 2

        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, isCancelled in
                if name == ExternalAutovisorToolNames.waitForEvents {
                    waitEntered.fulfill()
                    while !isCancelled() && !waitGate.isReleased {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
                return ToolExecutionResult(
                    toolName: name,
                    argumentsJSON: "{}",
                    outputJSON: #"{"ok":true,"data":{}}"#,
                    isError: false
                )
            },
            agentTextVersion: "test-agent-text-version"
        )

        // Configure maxOpenConnections = 4, reservedNonWaitConnections = 2 -> max 2 concurrent wait_for_events
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: dispatcher,
            configuration: .init(
                maxOpenConnections: 4,
                reservedNonWaitConnections: 2,
                headDeadline: .seconds(5),
                bodyDeadline: .seconds(5)
            )
        )
        defer {
            waitGate.release()
            Task { await listener.stop() }
        }

        let port = try await listener.start(port: 0)
        let mcpURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))

        func makeWaitRequest(id: Int) -> URLRequest {
            var req = URLRequest(url: mcpURL)
            req.httpMethod = "POST"
            req.setValue("Bearer \(issued.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
            req.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
            req.setValue("wait_for_events", forHTTPHeaderField: "Mcp-Name")
            req.httpBody = Data("""
            {"jsonrpc":"2.0","id":\(id),"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":5},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
            """.utf8)
            return req
        }

        // Launch 2 concurrent wait_for_events requests (consuming all 4 - 2 = 2 wait slots)
        let wait1 = Task { try await URLSession.shared.data(for: makeWaitRequest(id: 1)) }
        let wait2 = Task { try await URLSession.shared.data(for: makeWaitRequest(id: 2)) }
        await fulfillment(of: [waitEntered], timeout: 3.0)

        // A 3rd wait_for_events request must receive 503 Service Unavailable with Retry-After: 2
        let (_, wait3Resp) = try await URLSession.shared.data(for: makeWaitRequest(id: 3))
        let wait3HTTP = try XCTUnwrap(wait3Resp as? HTTPURLResponse)
        XCTAssertEqual(wait3HTTP.statusCode, 503)
        XCTAssertEqual(wait3HTTP.value(forHTTPHeaderField: "Retry-After"), "2")

        // Meanwhile, a non-wait request (ping) succeeds using the reserved non-wait slots!
        var pingReq = URLRequest(url: mcpURL)
        pingReq.httpMethod = "POST"
        pingReq.setValue("Bearer \(issued.token)", forHTTPHeaderField: "Authorization")
        pingReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pingReq.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        pingReq.httpBody = Data(#"{"jsonrpc":"2.0","id":99,"method":"ping"}"#.utf8)
        let (_, pingResp) = try await URLSession.shared.data(for: pingReq)
        let pingHTTP = try XCTUnwrap(pingResp as? HTTPURLResponse)
        XCTAssertEqual(pingHTTP.statusCode, 200)

        // Open 2 slow connections that stay in header-reading phase (filling the remaining 2 of 4 open connections)
        func openSlowHeaderSocket() throws -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            XCTAssertEqual(rc, 0)
            let partial = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n".utf8)
            _ = partial.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, partial.count) }
            return fd
        }

        let slowFD1 = try openSlowHeaderSocket()
        let slowFD2 = try openSlowHeaderSocket()
        defer {
            close(slowFD1)
            close(slowFD2)
        }
        try? await Task.sleep(for: .milliseconds(50))

        // Now all 4 connections are open (2 active waits + 2 slow header readers).
        // Sending another ping must evict the oldest header-reading connection (slowFD1) and succeed with 200!
        let (_, pingAfterEvictResp) = try await URLSession.shared.data(for: pingReq)
        let pingAfterEvictHTTP = try XCTUnwrap(pingAfterEvictResp as? HTTPURLResponse)
        XCTAssertEqual(pingAfterEvictHTTP.statusCode, 200)

        waitGate.release()
        _ = try? await wait1.value
        _ = try? await wait2.value
    }

    // MARK: - 5. Folder Transition Gate Returns 503 Retry-After: 1 (§7.1)

    @MainActor
    func testFolderTransitionGateReturns503RetryAfter1WhileSwitchingFromPreviousGeneration() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let issued = try agentStore.createAgent(label: "Transition Agent")
        let gate = HostedMCPTransitionGate()
        gate.setActive(true)

        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "test-agent-text-version"
        )
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: dispatcher,
            isFolderTransitionGateActive: { gate.isActive }
        )
        defer {
            Task { await listener.stop() }
        }

        let port = try await listener.start(port: 0)
        let mcpURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        var req = URLRequest(url: mcpURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(issued.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

        let (data503, resp503) = try await URLSession.shared.data(for: req)
        let http503 = try XCTUnwrap(resp503 as? HTTPURLResponse)
        XCTAssertEqual(http503.statusCode, 503)
        XCTAssertEqual(http503.value(forHTTPHeaderField: "Retry-After"), "1")
        let body503 = String(decoding: data503, as: UTF8.self)
        XCTAssertTrue(body503.contains("-32018"), body503)
        XCTAssertTrue(body503.contains("folder_transition_in_progress"), body503)

        // Once folder transition completes, requests succeed again
        gate.setActive(false)
        let (_, resp200) = try await URLSession.shared.data(for: req)
        let http200 = try XCTUnwrap(resp200 as? HTTPURLResponse)
        XCTAssertEqual(http200.statusCode, 200)

        // Also verify orchestrator.resetWorkFolderSettings() clears hostedMCPTransitionGate and re-activates autovisorEventFeed
        let orchestrator = TestOrchestrator.make(hostedMCPAgentStore: agentStore)
        let resetFolderURL = tempDir.appendingPathComponent("reset-project", isDirectory: true)
        try FileManager.default.createDirectory(at: resetFolderURL, withIntermediateDirectories: true)
        await orchestrator.openWorkFolder(resetFolderURL)
        XCTAssertFalse(orchestrator.hostedMCPTransitionGate.isActive)
        await orchestrator.resetWorkFolderSettings()
        XCTAssertFalse(orchestrator.hostedMCPTransitionGate.isActive)
        XCTAssertNotNil(orchestrator.autovisorEventFeed.currentCursor)
    }

    // MARK: - 6. Orchestrator Lifecycle & shutdownForTermination (§7.1)

    @MainActor
    func testOrchestratorLifecycleAndShutdownForTerminationWakesWaitsWithShuttingDownWithinBudget() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let orchestrator = TestOrchestrator.make(hostedMCPAgentStore: agentStore)
        let folderURL = tempDir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        await orchestrator.openWorkFolder(folderURL)
        await orchestrator.setAutovisorDriver(.externalAgent)
        await orchestrator.setAutovisorEnabled(true)

        let issued = try agentStore.createAgent(label: "Shutdown Agent")
        let port = try await orchestrator.startHostedMCPServer(port: 0)
        XCTAssertEqual(orchestrator.hostedMCPListenerState, .listening(port: port))
        XCTAssertEqual(orchestrator.activeHostedMCPServerPort, port)

        let initialCursor = try XCTUnwrap(orchestrator.autovisorEventFeed.currentCursor)
        let mcpURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        var waitReq = URLRequest(url: mcpURL)
        waitReq.httpMethod = "POST"
        waitReq.setValue("Bearer \(issued.token)", forHTTPHeaderField: "Authorization")
        waitReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        waitReq.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
        waitReq.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
        waitReq.setValue("wait_for_events", forHTTPHeaderField: "Mcp-Name")
        waitReq.httpBody = Data("""
        {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"wait_for_events","arguments":{"after":"\(initialCursor)","timeout_seconds":25},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """.utf8)

        let waitResponseTask = Task { () -> (Data, URLResponse) in
            try await URLSession.shared.data(for: waitReq)
        }

        // Wait until the waiter registers on autovisorEventFeed
        for _ in 0..<50 {
            if orchestrator.autovisorEventFeed.waiterCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(orchestrator.autovisorEventFeed.waiterCount, 1)

        // The woken wait records its row while shutdown is suspended in its teardown; hold the
        // log's queue from that moment, so the row's line is still pending unless shutdown
        // drains the queue AFTER the teardown (a flush before it has nothing to drain yet).
        let release = DispatchSemaphore(value: 0)
        let log = orchestrator.externalActivityLog
        log.onRecordAppended = { record in
            if record.tool == ExternalAutovisorToolNames.waitForEvents {
                log._testHoldIOQueue(atMost: 0.5, until: release)
            }
        }
        defer { release.signal() }

        let shutdownStart = Date()
        await orchestrator.shutdownForTermination()
        let shutdownElapsed = Date().timeIntervalSince(shutdownStart)
        XCTAssertLessThan(shutdownElapsed, 1.5)
        XCTAssertEqual(orchestrator.hostedMCPListenerState, .stopped)
        let logURL = NTMSPaths(workFolderRoot: folderURL).externalActivityLogJSONL
        let lines = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(lines.contains(#""tool":"wait_for_events""#),
                      "the row the shutdown itself produced reached the disk before shutdown returned")

        let (data, response) = try await waitResponseTask.value
        let httpResp = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResp.statusCode, 200)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("shutting_down"), "Expected shutting_down in response: \(text)")
    }

    // MARK: - 7. App Nap Assertion Follows In-Flight Requests (§13.2 п.6)

    /// The `.userInitiatedAllowingIdleSystemSleep` activity is held while at least one
    /// dispatched `POST /mcp` request is in flight — a long `wait_for_events` SSE stream
    /// included — and released when the count returns to zero. An idle listener holds none:
    /// External Agents left on with no agent connected used to keep a permanent assertion.
    func testAppNapActivityIsHeldOnlyWhileADispatchedMCPRequestIsInFlight() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "App Nap Agent")
        let waitGate = ToolGate()
        let listGate = ToolGate()
        let calls = ToolCallLog()
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(
                gates: [ExternalAutovisorToolNames.waitForEvents: waitGate, ExternalAutovisorToolNames.listTasks: listGate],
                calls: calls
            ))
        )
        let session = Self.makeSession()
        defer {
            waitGate.open()
            listGate.open()
            session.invalidateAndCancel()
        }

        let port = try await listener.start(port: 0)
        XCTAssertFalse(listener.hasActiveAppNapActivity, "listening with nothing in flight must not hold an App Nap assertion")

        let identifyURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/identify?agent=\(issued.record.shortID)&nonce=0123456789abcdef"))
        let (_, identifyResponse) = try await session.data(from: identifyURL)
        XCTAssertEqual(Self.statusCode(identifyResponse), 200)
        let (_, unauthorizedResponse) = try await session.data(for: Self.mcpRequest(
            port: port, token: "ntm_00000000_bogus", id: 1, tool: ExternalAutovisorToolNames.folderStatus
        ))
        XCTAssertEqual(Self.statusCode(unauthorizedResponse), 401)
        XCTAssertFalse(listener.hasActiveAppNapActivity, "requests answered without a dispatch never take the assertion")

        let waitTask = Task {
            try await session.data(for: Self.mcpRequest(
                port: port, token: issued.token, id: 2,
                tool: ExternalAutovisorToolNames.waitForEvents, arguments: #"{"timeout_seconds":600}"#
            ))
        }
        await waitUntil("wait_for_events entered its tool") { calls.enteredCount(ExternalAutovisorToolNames.waitForEvents) == 1 }
        XCTAssertTrue(listener.hasActiveAppNapActivity, "a dispatched wait_for_events SSE stream holds the assertion")

        let listTask = Task {
            try await session.data(for: Self.mcpRequest(
                port: port, token: issued.token, id: 3, tool: ExternalAutovisorToolNames.listTasks
            ))
        }
        await waitUntil("list_tasks entered its tool") { calls.enteredCount(ExternalAutovisorToolNames.listTasks) == 1 }

        listGate.open()
        let (_, listResponse) = try await listTask.value
        XCTAssertEqual(Self.statusCode(listResponse), 200)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(listener.hasActiveAppNapActivity, "the wait is still in flight: the assertion follows a count, not the last request")

        waitGate.open()
        let (waitData, waitResponse) = try await waitTask.value
        XCTAssertEqual(Self.statusCode(waitResponse), 200)
        XCTAssertTrue(String(decoding: waitData, as: UTF8.self).contains(": connected"), "anti-vacuum: the wait was an SSE stream")
        await waitUntil("the last completion released the assertion") { !listener.hasActiveAppNapActivity }

        await listener.stop()
        XCTAssertFalse(listener.hasActiveAppNapActivity)
    }

    func testStopWhileARequestIsInFlightReleasesTheAppNapActivityAndALateCompletionCannotRetakeIt() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Stop In Flight Agent")
        let waitGate = ToolGate()
        let listGate = ToolGate()
        let calls = ToolCallLog()
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(
                gates: [ExternalAutovisorToolNames.waitForEvents: waitGate, ExternalAutovisorToolNames.listTasks: listGate],
                calls: calls
            ))
        )
        let session = Self.makeSession()
        defer {
            waitGate.open()
            listGate.open()
            session.invalidateAndCancel()
        }

        let port = try await listener.start(port: 0)
        let waitTask = Task {
            try? await session.data(for: Self.mcpRequest(
                port: port, token: issued.token, id: 1,
                tool: ExternalAutovisorToolNames.waitForEvents, arguments: #"{"timeout_seconds":600}"#
            ))
        }
        await waitUntil("wait_for_events entered its tool") { calls.enteredCount(ExternalAutovisorToolNames.waitForEvents) == 1 }
        XCTAssertTrue(listener.hasActiveAppNapActivity)

        await listener.stop()
        XCTAssertFalse(listener.hasActiveAppNapActivity, "stop() ends the assertion with the request still in flight")
        XCTAssertEqual(listener.state, .stopped)
        await waitUntil("the stopped request saw its cancellation") { calls.cancelledCount(ExternalAutovisorToolNames.waitForEvents) == 1 }
        _ = await waitTask.value
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(listener.hasActiveAppNapActivity, "the stopped request finishing late must not take it again")

        let restartedPort = try await listener.start(port: 0)
        XCTAssertFalse(listener.hasActiveAppNapActivity, "a restart starts from an empty count")
        let listTask = Task {
            try await session.data(for: Self.mcpRequest(
                port: restartedPort, token: issued.token, id: 2, tool: ExternalAutovisorToolNames.listTasks
            ))
        }
        await waitUntil("list_tasks entered its tool") { calls.enteredCount(ExternalAutovisorToolNames.listTasks) == 1 }
        XCTAssertTrue(listener.hasActiveAppNapActivity)
        listGate.open()
        let (_, listResponse) = try await listTask.value
        XCTAssertEqual(Self.statusCode(listResponse), 200)
        await waitUntil("the completion released the assertion") { !listener.hasActiveAppNapActivity }

        // A restart is a stop first: it ends the assertion of a request still in flight.
        let secondWait = Task {
            try? await session.data(for: Self.mcpRequest(
                port: restartedPort, token: issued.token, id: 3,
                tool: ExternalAutovisorToolNames.waitForEvents, arguments: #"{"timeout_seconds":600}"#
            ))
        }
        await waitUntil("the second wait entered its tool") { calls.enteredCount(ExternalAutovisorToolNames.waitForEvents) == 2 }
        XCTAssertTrue(listener.hasActiveAppNapActivity)
        _ = try await listener.start(port: 0)
        XCTAssertFalse(listener.hasActiveAppNapActivity, "start() on a busy listener stops it first")
        await waitUntil("the restart cancelled the second wait") { calls.cancelledCount(ExternalAutovisorToolNames.waitForEvents) == 2 }
        _ = await secondWait.value
        XCTAssertFalse(listener.hasActiveAppNapActivity)
        await listener.stop()
    }

    // MARK: - 8. Loopback-Only Bind, Port-In-Use Failure And TIME_WAIT Re-bind (§7.1, §13.2 п.1)

    func testLoopbackOnlyBindAndAPortInUseStartFailureHoldNoAppNapActivity() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let dispatcher = Self.makeDispatcher(Self.gatedExecutor(gates: [:], calls: ToolCallLog()))
        let listener = HostedMCPListener(agentStore: agentStore, dispatcher: dispatcher)
        let rivalListener = HostedMCPListener(agentStore: agentStore, dispatcher: dispatcher)

        XCTAssertFalse(listener.hasActiveAppNapActivity)
        let port = try await listener.start(port: 0)
        XCTAssertGreaterThan(port, 0)
        XCTAssertFalse(listener.hasActiveAppNapActivity)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"))
        let lsofResult = try ProcessRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
            currentDirectory: nil,
            timeout: 10
        )
        XCTAssertEqual(lsofResult.exitCode, 0, "lsof stderr=\(lsofResult.stderr)")
        XCTAssertTrue(lsofResult.stdout.contains("127.0.0.1:\(port) (LISTEN)"), lsofResult.stdout)
        XCTAssertTrue(lsofResult.stdout.contains("[::1]:\(port) (LISTEN)"), lsofResult.stdout)
        XCTAssertFalse(lsofResult.stdout.contains("*:\(port)"), "must never bind the wildcard:\n\(lsofResult.stdout)")

        do {
            _ = try await rivalListener.start(port: port)
            XCTFail("a second listener on a listening port must fail with .portInUse")
        } catch let error as HostedMCPListenerError {
            XCTAssertEqual(error, .portInUse(port))
        }
        XCTAssertEqual(rivalListener.state, .failed(.portInUse(port)))
        XCTAssertNil(rivalListener.boundPort)
        XCTAssertFalse(rivalListener.hasActiveAppNapActivity)
        XCTAssertEqual(listener.state, .listening(port: port), "the rival's failure leaves the first listener alone")

        await listener.stop(gracePeriod: .zero)
        XCTAssertFalse(listener.hasActiveAppNapActivity)
    }

    /// A connection the server closes first leaves the server's end in TIME_WAIT for 2×MSL
    /// (30 s on macOS), and re-binding the same port right after `stop()` must still work.
    ///
    /// Neither `lsof` nor `netstat` can show that state from here: `lsof` lists open files and a
    /// TIME_WAIT socket has no owning descriptor, and `netstat` spawned by the test host prints
    /// no sockets at all (measured 2026-11-07: 0 bytes, exit 0, while `net.inet.tcp.pcbcount`
    /// read 76). So the state is proved by its signature instead: with no listener left, a plain
    /// `bind` of the address is refused with `EADDRINUSE` while an `SO_REUSEADDR` bind is allowed
    /// — the address is held by a closed connection, which a listening socket would not let pass.
    func testImmediateRebindAfterStopSucceedsWhileServedConnectionsAreInTimeWait() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "TIME_WAIT Agent")
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(gates: [:], calls: ToolCallLog()))
        )
        let port = try await listener.start(port: 0)

        func identifyOverRawSocket(family: Int32, hostHeader: String) async throws -> String {
            let socket = try XCTUnwrap(RawLoopbackSocket(family: family, port: port))
            defer { socket.close() }
            socket.send(
                "GET /identify?agent=\(issued.record.shortID)&nonce=0123456789abcdef HTTP/1.1\r\n" +
                    "Host: \(hostHeader):\(port)\r\n\r\n"
            )
            return await socket.readToEOF()
        }

        for (family, hostHeader) in [(AF_INET, "127.0.0.1"), (AF_INET6, "[::1]")] {
            let reply = try await identifyOverRawSocket(family: family, hostHeader: hostHeader)
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK\r\n"), reply)
        }
        await listener.stop(gracePeriod: .zero)

        for family in [AF_INET, AF_INET6] {
            XCTAssertEqual(
                Self.bindErrno(family: family, port: port, reuseAddress: false), EADDRINUSE,
                "family \(family): the served connection's server end must still hold the address"
            )
            XCTAssertEqual(
                Self.bindErrno(family: family, port: port, reuseAddress: true), 0,
                "family \(family): what holds the address must be a closed connection, not a listener"
            )
        }

        let rebound = try await listener.start(port: port)
        XCTAssertEqual(rebound, port)
        XCTAssertEqual(listener.state, .listening(port: port))
        let replyAfterRebind = try await identifyOverRawSocket(family: AF_INET, hostHeader: "127.0.0.1")
        XCTAssertTrue(replyAfterRebind.hasPrefix("HTTP/1.1 200 OK\r\n"), replyAfterRebind)
        await listener.stop(gracePeriod: .zero)
    }

    // MARK: - 9. Error Replies, Connection Removal, Cancellation And Drain (§7.1, §7.2, §6)

    func testIdentifyErrorsAndAParseErrorAreAnsweredAndLogged() async throws {
        XCTAssertEqual(HostedMCPListenerError.bindFailed("bad").message, "Could not start the server: bad")

        let secretStorage = InMemorySecureTokenStorage()
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let issued = try agentStore.createAgent(label: "Identify Error Agent")
        let frameLog = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 0)
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(gates: [:], calls: ToolCallLog())),
            frameLog: frameLog
        )
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let port = try await listener.start(port: 0)
        let nonce = "0123456789abcdef0123456789abcdef"

        let unknownURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/identify?agent=deadbeef&nonce=\(nonce)"))
        let (_, notFound) = try await session.data(from: unknownURL)
        XCTAssertEqual(Self.statusCode(notFound), 404)

        secretStorage.readError = KeychainError.unhandled(-25308)
        let knownURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/identify?agent=\(issued.record.shortID)&nonce=\(nonce)"))
        let (_, unavailable) = try await session.data(from: knownURL)
        secretStorage.readError = nil
        XCTAssertEqual(Self.statusCode(unavailable), 503)
        XCTAssertEqual((unavailable as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), "\(HostedMCPConstants.busyRetryAfterSeconds)")

        let badSocket = try XCTUnwrap(RawLoopbackSocket(port: port))
        badSocket.send("BAD_REQUEST_LINE\r\n\r\n")
        let badReply = await badSocket.readToEOF()
        badSocket.close()
        XCTAssertTrue(badReply.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), badReply)
        XCTAssertTrue(badReply.contains("Connection: close\r\n"), badReply)

        let entries = frameLog.entries()
        XCTAssertTrue(entries.contains { $0.method == "GET /identify" && $0.statusCode == 404 && $0.refusalReason == "agent_not_found" }, "\(entries)")
        XCTAssertTrue(entries.contains { $0.method == "GET /identify" && $0.statusCode == 503 && $0.refusalReason == "keychain_unavailable:keychain_unavailable" }, "\(entries)")
        XCTAssertTrue(entries.contains { $0.method == "HTTP" && $0.statusCode == 400 && $0.refusalReason == "parse_error" }, "\(entries)")
        await listener.stop()
    }

    func testAConnectionThatEndsMidHeadIsRemovedWithoutAReply() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(gates: [:], calls: ToolCallLog()))
        )
        let port = try await listener.start(port: 0)
        let initialCount = await listener._testOpenConnectionCount()
        XCTAssertEqual(initialCount, 0)

        let socket = try XCTUnwrap(RawLoopbackSocket(port: port))
        defer { socket.close() }
        socket.send("GET /identify ")
        await waitUntil("the half-sent head is an open connection") { await listener._testOpenConnectionCount() == 1 }
        socket.shutdownWrite()
        await waitUntil("EOF mid-head removes the connection") { await listener._testOpenConnectionCount() == 0 }
        let reply = await socket.readToEOF()
        XCTAssertEqual(reply, "", "a connection that ends mid-head gets no reply")
        await listener.stop()
    }

    func testANonJSONBodyIsAnswered400ParseErrorWithoutAnID() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Bad Body Agent")
        let frameLog = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 0)
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(gates: [:], calls: ToolCallLog())),
            frameLog: frameLog
        )
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let port = try await listener.start(port: 0)

        var request = Self.mcpRequest(port: port, token: issued.token, id: 1, tool: ExternalAutovisorToolNames.folderStatus)
        request.httpBody = Data("not-json".utf8)
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual(Self.statusCode(response), 400)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
        XCTAssertNil(json["id"], "a parse error carries no id (§7.2)")
        XCTAssertTrue(
            frameLog.entries().contains { $0.method == "POST /mcp" && $0.statusCode == 400 && $0.refusalReason == "http_400" },
            "\(frameLog.entries())"
        )
        await listener.stop()
    }

    /// Rotating or revoking a token cancels that agent's in-flight requests and closes their
    /// connections — and nobody else's. A revoke whose Keychain delete fails still commits, so
    /// it cancels too (§6).
    func testRotatingOrRevokingATokenCancelsOnlyThatAgentsInFlightRequests() async throws {
        let secretStorage = InMemorySecureTokenStorage()
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: secretStorage)
        let rotating = try agentStore.createAgent(label: "Rotating")
        let revoked = try agentStore.createAgent(label: "Revoked")
        let rotatingGate = ToolGate()
        let revokedGate = ToolGate()
        let calls = ToolCallLog()
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(
                gates: ["Rotating": rotatingGate, "Revoked": revokedGate],
                calls: calls,
                key: { _, agent in agent.label }
            ))
        )
        let session = Self.makeSession()
        defer {
            rotatingGate.open()
            revokedGate.open()
            session.invalidateAndCancel()
        }
        let port = try await listener.start(port: 0)

        let rotatingTask = Task {
            try? await session.data(for: Self.mcpRequest(port: port, token: rotating.token, id: 1, tool: ExternalAutovisorToolNames.listTasks))
        }
        let revokedTask = Task {
            try? await session.data(for: Self.mcpRequest(port: port, token: revoked.token, id: 2, tool: ExternalAutovisorToolNames.listTasks))
        }
        await waitUntil("both requests are in flight") { calls.enteredCount("Rotating") == 1 && calls.enteredCount("Revoked") == 1 }

        let rotated = try agentStore.rotateToken(agentID: rotating.record.id)
        await waitUntil("rotation cancelled the rotating agent's request") { calls.cancelledCount("Rotating") == 1 }
        _ = await rotatingTask.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.cancelledCount("Revoked"), 0, "another agent's request is untouched")

        rotatingGate.open()
        let (_, oldTokenResponse) = try await session.data(for: Self.mcpRequest(port: port, token: rotating.token, id: 3, tool: ExternalAutovisorToolNames.folderStatus))
        XCTAssertEqual(Self.statusCode(oldTokenResponse), 401)
        let (_, newTokenResponse) = try await session.data(for: Self.mcpRequest(port: port, token: rotated.token, id: 4, tool: ExternalAutovisorToolNames.folderStatus))
        XCTAssertEqual(Self.statusCode(newTokenResponse), 200)

        let revokedKey = revoked.record.id.uuidString
        secretStorage.writeFailure = { key, token in key == revokedKey && token == nil ? .unhandled(-25308) : nil }
        let outcome = try agentStore.revokeAgent(agentID: revoked.record.id)
        secretStorage.writeFailure = nil
        XCTAssertEqual(outcome, .revokedLeavingVerifier)
        await waitUntil("a revoke that kept its verifier still cancelled the request") { calls.cancelledCount("Revoked") == 1 }
        _ = await revokedTask.value
        let (_, revokedTokenResponse) = try await session.data(for: Self.mcpRequest(port: port, token: revoked.token, id: 5, tool: ExternalAutovisorToolNames.folderStatus))
        XCTAssertEqual(Self.statusCode(revokedTokenResponse), 401)
        await waitUntil("no connection is left open") { await listener._testOpenConnectionCount() == 0 }
        await listener.stop()
    }

    func testBusyRejectionAndCancelConnectionsForAgent() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Busy Agent")
        let waitGate = ToolGate()
        let listGate = ToolGate()
        let calls = ToolCallLog()
        let frameLog = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 0)
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(
                gates: [ExternalAutovisorToolNames.waitForEvents: waitGate, ExternalAutovisorToolNames.listTasks: listGate],
                calls: calls
            )),
            frameLog: frameLog,
            configuration: .init(maxOpenConnections: 2, reservedNonWaitConnections: 1, headDeadline: .seconds(5), bodyDeadline: .seconds(5))
        )
        let session = Self.makeSession()
        defer {
            waitGate.open()
            listGate.open()
            session.invalidateAndCancel()
        }
        let port = try await listener.start(port: 0)

        let waitTask = Task {
            try? await session.data(for: Self.mcpRequest(port: port, token: issued.token, id: 1, tool: ExternalAutovisorToolNames.waitForEvents))
        }
        let listTask = Task {
            try? await session.data(for: Self.mcpRequest(port: port, token: issued.token, id: 2, tool: ExternalAutovisorToolNames.listTasks))
        }
        await waitUntil("both requests are in flight") {
            calls.enteredCount(ExternalAutovisorToolNames.waitForEvents) == 1 && calls.enteredCount(ExternalAutovisorToolNames.listTasks) == 1
        }

        let busySocket = try XCTUnwrap(RawLoopbackSocket(port: port))
        let busyReply = await busySocket.readToEOF()
        busySocket.close()
        XCTAssertTrue(busyReply.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"), busyReply)
        XCTAssertTrue(busyReply.contains("Retry-After: \(HostedMCPConstants.busyRetryAfterSeconds)\r\n"), busyReply)
        XCTAssertTrue(busyReply.contains("server_busy"), busyReply)
        XCTAssertTrue(frameLog.entries().contains { $0.method == "CONNECT" && $0.statusCode == 503 && $0.refusalReason == "connection_cap_exceeded" })

        listener.cancelConnections(forAgent: issued.record.id)
        await waitUntil("both in-flight requests were cancelled") {
            calls.cancelledCount(ExternalAutovisorToolNames.waitForEvents) == 1 && calls.cancelledCount(ExternalAutovisorToolNames.listTasks) == 1
        }
        await waitUntil("their connections are closed") { await listener._testOpenConnectionCount() == 0 }
        _ = await waitTask.value
        _ = await listTask.value
        await listener.stop()
    }

    func testStopDrainsThenForceClosesAnInFlightRequestWithinItsGracePeriod() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Drain Agent")
        let gate = ToolGate()
        let calls = ToolCallLog()
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(gates: [ExternalAutovisorToolNames.folderStatus: gate], calls: calls))
        )
        let session = Self.makeSession()
        defer {
            gate.open()
            session.invalidateAndCancel()
        }
        let port = try await listener.start(port: 0)
        let statusTask = Task {
            try? await session.data(for: Self.mcpRequest(port: port, token: issued.token, id: 1, tool: ExternalAutovisorToolNames.folderStatus))
        }
        await waitUntil("folder_status is in flight") { calls.enteredCount(ExternalAutovisorToolNames.folderStatus) == 1 }

        let clock = ContinuousClock()
        let stopStart = clock.now
        await listener.stop(gracePeriod: .milliseconds(20))
        let stopElapsed = clock.now - stopStart
        XCTAssertLessThan(stopElapsed, .seconds(2), "stop() waits out its grace period, then force-closes")
        XCTAssertEqual(listener.state, .stopped)
        XCTAssertNil(listener.boundPort)
        let openAfterStop = await listener._testOpenConnectionCount()
        XCTAssertEqual(openAfterStop, 0)
        await waitUntil("the in-flight request saw its cancellation") { calls.cancelledCount(ExternalAutovisorToolNames.folderStatus) == 1 }
        _ = await statusTask.value
    }

    func testAListenerReleasedWithoutStopDeallocatesAndFreesItsPort() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let dispatcher = Self.makeDispatcher(Self.gatedExecutor(gates: [:], calls: ToolCallLog()))
        var listener: HostedMCPListener? = HostedMCPListener(agentStore: agentStore, dispatcher: dispatcher)
        weak let released = listener
        let port = try await XCTUnwrap(listener).start(port: 0)
        XCTAssertEqual(listener?.hasActiveAppNapActivity, false)

        listener = nil
        await waitUntil("nothing retains a listener nobody stopped") { released == nil }

        let successor = HostedMCPListener(agentStore: agentStore, dispatcher: dispatcher)
        var reboundPort: UInt16?
        await waitUntil("deinit cancelled both loopback listeners, freeing the port") {
            reboundPort = try? await successor.start(port: port)
            return reboundPort != nil
        }
        XCTAssertEqual(reboundPort, port)
        await successor.stop(gracePeriod: .zero)
    }

    // MARK: - 10. One Request Per Connection, Redaction Set, Refusal Coalescing (§7.2, §10.2)

    /// Bytes that arrive on a connection after its request completed — a trailing CRLF, a
    /// pipelined copy — must never dispatch that request again: each re-dispatch ran the tool
    /// once more and orphaned the earlier dispatch task from eviction.
    func testBytesArrivingAfterACompleteRequestNeverDispatchItAgain() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Pipelining Agent")
        let gate = ToolGate()
        let calls = ToolCallLog()
        let frameLog = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 0)
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(gates: [ExternalAutovisorToolNames.folderStatus: gate], calls: calls)),
            frameLog: frameLog
        )
        defer { gate.open() }
        let port = try await listener.start(port: 0)

        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"folder_status","arguments":{}}}"#
        let request =
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(issued.token)\r\n" +
            "Content-Type: application/json\r\nMCP-Protocol-Version: 2025-11-25\r\n" +
            "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let socket = try XCTUnwrap(RawLoopbackSocket(port: port))
        defer { socket.close() }
        socket.send(request)
        await waitUntil("folder_status is in flight") { calls.enteredCount(ExternalAutovisorToolNames.folderStatus) == 1 }

        socket.send("\r\n")
        try await Task.sleep(for: .milliseconds(100))
        socket.send(request)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.enteredCount(ExternalAutovisorToolNames.folderStatus), 1, "later bytes must not dispatch the request again")

        gate.open()
        let reply = await socket.readToEOF()
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK\r\n"), reply)
        XCTAssertEqual(reply.components(separatedBy: "HTTP/1.1 ").count - 1, 1, "exactly one response on the connection")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.enteredCount(ExternalAutovisorToolNames.folderStatus), 1)
        XCTAssertEqual(frameLog.entries().filter { $0.tool == ExternalAutovisorToolNames.folderStatus }.count, 1)
        await listener.stop()
    }

    /// Only a token that authenticates joins the frame log's redaction set: registering every
    /// presented bearer let an unauthenticated client grow the set — and the cost of every later
    /// log write — without bound.
    func testOnlyTokensThatAuthenticateJoinTheFrameLogRedactionSet() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Redaction Agent")
        let frameLog = HostedMCPFrameLog()
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(gates: [:], calls: ToolCallLog())),
            frameLog: frameLog
        )
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let port = try await listener.start(port: 0)

        for index in 0..<20 {
            let bogus = "ntm_\(String(format: "%08x", index))_" + String(repeating: "Q", count: 43)
            let (_, response) = try await session.data(for: Self.mcpRequest(port: port, token: bogus, id: index, tool: ExternalAutovisorToolNames.folderStatus))
            XCTAssertEqual(Self.statusCode(response), 401)
        }
        XCTAssertEqual(frameLog._testSensitiveValueCount, 0, "a token that did not authenticate is not registered")

        for id in 100..<103 {
            let (_, response) = try await session.data(for: Self.mcpRequest(port: port, token: issued.token, id: id, tool: ExternalAutovisorToolNames.folderStatus))
            XCTAssertEqual(Self.statusCode(response), 200)
        }
        XCTAssertEqual(frameLog._testSensitiveValueCount, 2, "the authenticated token and its secret part, once")
        await listener.stop()
    }

    /// Distinct forbidden `Origin`s coalesce into one logged refusal per window, and that one
    /// keeps its `Origin` verbatim (E9).
    func testForbiddenOriginsFromDistinctClientsCoalesceIntoOneLoggedRefusal() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let frameLog = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 60)
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(Self.gatedExecutor(gates: [:], calls: ToolCallLog())),
            frameLog: frameLog
        )
        let port = try await listener.start(port: 0)

        for index in 0..<30 {
            let socket = try XCTUnwrap(RawLoopbackSocket(port: port))
            socket.send(
                "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: https://evil-\(index).example\r\n" +
                    "Content-Length: 0\r\n\r\n"
            )
            let reply = await socket.readToEOF()
            socket.close()
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403 Forbidden\r\n"), reply)
        }
        let refusals = frameLog.entries().filter { $0.statusCode == 403 }
        XCTAssertEqual(refusals.map(\.refusalReason), ["forbidden_origin:https://evil-0.example"])
        XCTAssertEqual(frameLog._testTrackedRefusalKeyCount, 1)
        await listener.stop()
    }

    // MARK: - Helpers

    /// Polls `condition` every 10 ms until it holds or `timeout` passes, failing the test on a
    /// timeout. Returns whether it held.
    @discardableResult
    // MARK: - Review of 2026-11-07: the wildcard squatter and the abandoned wait slot

    /// A process of the same user listening on the WILDCARD address (`nc -l 47321` binds
    /// `0.0.0.0`) or dual-stack `[::]` does not fail the loopback probe once the probe sets
    /// `SO_REUSEADDR` (c458dc15): binding `127.0.0.1:P` next to a wildcard listener succeeds. The
    /// squatter must still read as "port in use" (D11), which today the `NWListener`'s own bind
    /// provides — pinned here so a change to that bind cannot let a squatter's port go unreported.
    func testAWildcardSquatterOnThePortStillSurfacesPortInUse() async throws {
        for (family, label) in [(AF_INET, "0.0.0.0"), (AF_INET6, "[::] dual-stack")] {
            let squatter = try Self.listenOnWildcard(family: family)
            defer { close(squatter.fd) }
            let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
            let listener = HostedMCPListener(
                agentStore: agentStore,
                dispatcher: Self.makeDispatcher(Self.gatedExecutor(gates: [:], calls: ToolCallLog()))
            )

            do {
                _ = try await listener.start(port: squatter.port)
                XCTFail("start(port:) must refuse \(squatter.port) while a \(label) listener holds it")
            } catch let error as HostedMCPListenerError {
                XCTAssertEqual(error, .portInUse(squatter.port), label)
            }
            XCTAssertEqual(listener.state, HostedMCPListenerState.failed(.portInUse(squatter.port)), label)
            await listener.stop()
        }
    }

    /// `stop()` abandons the requests in flight, and a request it abandoned may still finish
    /// after the restart — its tool call ignored the cancellation. Its slot was given back when
    /// it was abandoned, so its late end must not give back a slot a request of the restarted
    /// listener now holds: the pre-fix decrement (`activeWaitCount = max(0, activeWaitCount - 1)`)
    /// did, and every abandoned wait then admitted one extra wait into the slots reserved for
    /// everything else. Pinned 2026-11-07 after the review found no test failing on that decrement.
    func testALateEndOfAWaitAbandonedByStopFreesNoSlotOfTheRestartedListener() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Slot Accounting Agent")
        let abandonedGate = ToolGate()
        let heldGate = ToolGate()
        let calls = ToolCallLog()
        // The abandoned call (timeout 7) ignores cancellation and ends only when its gate opens;
        // the restarted listener's wait (timeout 8) blocks on its gate or until it is cancelled;
        // any other call returns at once, so a wait admitted by mistake answers 200, not a hang.
        let executor = ClosureHostedMCPToolExecutor { name, arguments, _, _, isCancelled in
            let key = "\(name)#\(arguments["timeout_seconds"]?.intValue ?? -1)"
            calls.noteEntered(key)
            if key == "\(ExternalAutovisorToolNames.waitForEvents)#7" {
                while !abandonedGate.isOpen { try? await Task.sleep(for: .milliseconds(10)) }
            } else if key == "\(ExternalAutovisorToolNames.waitForEvents)#8" {
                while !heldGate.isOpen && !isCancelled() { try? await Task.sleep(for: .milliseconds(10)) }
            }
            return ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true,"data":{}}"#, isError: false)
        }
        let frameLog = HostedMCPFrameLog()
        // Two open connections, one reserved for non-waits: exactly one wait slot.
        let listener = HostedMCPListener(
            agentStore: agentStore,
            dispatcher: Self.makeDispatcher(executor),
            frameLog: frameLog,
            configuration: .init(maxOpenConnections: 2, reservedNonWaitConnections: 1, headDeadline: .seconds(5), bodyDeadline: .seconds(5))
        )
        let session = Self.makeSession()
        defer {
            abandonedGate.open()
            heldGate.open()
            Task { await listener.stop() }
        }
        func wait(port: UInt16, id: Int, timeout: Int) -> URLRequest {
            Self.mcpRequest(port: port, token: issued.token, id: id, tool: ExternalAutovisorToolNames.waitForEvents,
                            arguments: #"{"timeout_seconds":\#(timeout)}"#)
        }
        let waitKey = { (timeout: Int) in "\(ExternalAutovisorToolNames.waitForEvents)#\(timeout)" }

        let firstPort = try await listener.start(port: 0)
        let abandoned = Task { try? await session.data(for: wait(port: firstPort, id: 1, timeout: 7)) }
        _ = await waitUntil("the first wait entered its tool call") { calls.enteredCount(waitKey(7)) == 1 }
        await listener.stop()
        _ = await abandoned.value

        let secondPort = try await listener.start(port: 0)
        let held = Task { try? await session.data(for: wait(port: secondPort, id: 2, timeout: 8)) }
        _ = await waitUntil("the restarted listener's wait holds the only slot") { calls.enteredCount(waitKey(8)) == 1 }

        let waitsLoggedBefore = frameLog.entries().filter { $0.tool == ExternalAutovisorToolNames.waitForEvents }.count
        abandonedGate.open()
        _ = await waitUntil("the abandoned wait ended and was logged") {
            frameLog.entries().filter { $0.tool == ExternalAutovisorToolNames.waitForEvents }.count > waitsLoggedBefore
        }
        // Its end is queued on the listener's queue right after that log line; one hop through
        // the queue later, it has run.
        try? await Task.sleep(for: .milliseconds(50))
        _ = await listener._testOpenConnectionCount()

        let (_, refused) = try await session.data(for: wait(port: secondPort, id: 3, timeout: 9))
        XCTAssertEqual(Self.statusCode(refused), 503, "the only wait slot is still held by the restarted listener's wait")
        XCTAssertEqual(calls.enteredCount(waitKey(9)), 0)

        heldGate.open()
        _ = await held.value
    }

    /// A socket listening on the wildcard address of `family` (dual-stack for IPv6) on an
    /// ephemeral port.
    private static func listenOnWildcard(family: Int32) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw XCTSkip("socket(\(family)) failed: errno \(errno)") }
        var port: UInt16 = 0
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = in_addr_t(0)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            XCTAssertEqual(bound, 0)
            var name = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &name) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            port = UInt16(bigEndian: name.sin_port)
        } else {
            var v6Only: Int32 = 0
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = 0
            addr.sin6_addr = in6addr_any
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            XCTAssertEqual(bound, 0)
            var name = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &name) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            port = UInt16(bigEndian: name.sin6_port)
        }
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        XCTAssertGreaterThan(port, 0)
        return (fd, port)
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if await condition() { return true }
        XCTFail("timed out waiting until: \(description)", file: file, line: line)
        return false
    }

    private static func makeDispatcher(_ executor: ClosureHostedMCPToolExecutor) -> HostedMCPDispatcher {
        HostedMCPDispatcher(toolExecutor: executor, agentTextVersion: "test-agent-text-version")
    }

    /// A tool executor whose calls block on the gate their key names (the tool name unless
    /// `key` says otherwise) until it opens or the call is cancelled.
    private static func gatedExecutor(
        gates: [String: ToolGate],
        calls: ToolCallLog,
        key: @escaping @Sendable (String, AgentIdentity) -> String = { name, _ in name }
    ) -> ClosureHostedMCPToolExecutor {
        ClosureHostedMCPToolExecutor { name, _, agent, _, isCancelled in
            let callKey = key(name, agent)
            calls.noteEntered(callKey)
            if let gate = gates[callKey] {
                while !gate.isOpen && !isCancelled() {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if isCancelled() { calls.noteCancelled(callKey) }
            }
            return ToolExecutionResult(
                toolName: name,
                argumentsJSON: "{}",
                outputJSON: #"{"ok":true,"data":{}}"#,
                isError: false
            )
        }
    }

    /// A modern-era (`2026-07-28`) `tools/call` request.
    private static func mcpRequest(
        port: UInt16,
        token: String,
        id: Int,
        tool: String,
        arguments: String = "{}"
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
        request.setValue(tool, forHTTPHeaderField: "Mcp-Name")
        request.httpBody = Data("""
        {"jsonrpc":"2.0","id":\(id),"method":"tools/call","params":{"name":"\(tool)","arguments":\(arguments),"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """.utf8)
        return request
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }

    private static func statusCode(_ response: URLResponse) -> Int? {
        (response as? HTTPURLResponse)?.statusCode
    }

    /// Binds (and closes) a throwaway loopback socket on `port`; `0` on success, else `errno`.
    private static func bindErrno(family: Int32, port: UInt16, reuseAddress: Bool) -> Int32 {
        let fd = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return errno }
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        if reuseAddress {
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let result: Int32
        if family == AF_INET6 {
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result == 0 ? 0 : errno
    }
}

// MARK: - Test Support

/// A latch gated tools wait on; once open, every current and later waiter passes.
private final class ToolGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }
}

/// Counts, per key, the tool calls that started and the ones that ended on cancellation.
private final class ToolCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: [String: Int] = [:]
    private var cancelled: [String: Int] = [:]

    func noteEntered(_ key: String) {
        lock.lock()
        entered[key, default: 0] += 1
        lock.unlock()
    }

    func noteCancelled(_ key: String) {
        lock.lock()
        cancelled[key, default: 0] += 1
        lock.unlock()
    }

    func enteredCount(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entered[key] ?? 0
    }

    func cancelledCount(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelled[key] ?? 0
    }
}

/// A blocking loopback client socket for byte-level control over one connection.
private final class RawLoopbackSocket: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    init?(family: Int32 = AF_INET, port: UInt16) {
        let fd = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        close()
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// Reads until the peer closes (or the 5 s receive timeout passes), off the cooperative pool.
    func readToEOF() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var received = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(self.fd, &buffer, buffer.count)
                    guard count > 0 else { break }
                    received.append(contentsOf: buffer[0..<count])
                }
                continuation.resume(returning: String(decoding: received, as: UTF8.self))
            }
        }
    }

    func shutdownWrite() {
        _ = Darwin.shutdown(fd, SHUT_WR)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}
