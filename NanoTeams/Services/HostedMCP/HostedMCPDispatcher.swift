import Foundation

/// Per-agent token bucket configuration for Hosted MCP rate limiting (§7.2).
nonisolated struct HostedMCPRateLimitConfiguration: Sendable, Equatable {
    var capacity: Int
    var refillPerSecond: Double

    init(
        capacity: Int = HostedMCPConstants.rateLimitBucketCapacity,
        refillPerSecond: Double = HostedMCPConstants.rateLimitRefillPerSecond
    ) {
        self.capacity = max(1, capacity)
        self.refillPerSecond = max(0.001, refillPerSecond)
    }
}

/// Result of dispatching an authenticated POST `/mcp` request (§7.3).
nonisolated enum HostedMCPDispatchOutcome: Sendable {
    case httpResponse(HostedMCPHTTPResponse)
    case sse(headBytes: Data)
}

/// Dual-era MCP JSON-RPC dispatcher (`2026-07-28` modern stateless era and
/// `2025-11-25` / `2025-06-18` legacy session era, §7.2–§7.3).
nonisolated final class HostedMCPDispatcher: @unchecked Sendable {

    private let toolExecutor: any HostedMCPToolExecuting
    private let serverVersion: String
    let agentTextVersion: String
    private let rateLimitConfig: HostedMCPRateLimitConfiguration
    private let keepAliveInterval: TimeInterval
    private let ssePromotionWaitThresholdSeconds: Int
    private let now: @Sendable () -> Date

    private let stateLock = NSLock()
    private var bucketsByAgent: [UUID: AgentTokenBucket] = [:]
    private var legacySessions: [SessionKey: String] = [:]
    private var inFlightLegacyRequests: [UUID: InFlightEntry] = [:]
    private var inFlightModernRequests: [UUID: InFlightEntry] = [:]

    private struct SessionKey: Hashable, Sendable {
        let agentID: UUID
        let sessionID: String
    }

    private struct AgentTokenBucket: Sendable {
        var tokens: Double
        var lastRefill: Date
    }

    private struct InFlightEntry: Sendable {
        let entryID: UUID
        let agentID: UUID
        let sessionID: String?
        let requestID: JSONRPCID
        let token: HostedMCPCancellationToken
    }

    init(
        toolExecutor: any HostedMCPToolExecuting,
        serverVersion: String = HostedMCPConstants.defaultServerVersion,
        agentTextVersion: String,
        rateLimitConfig: HostedMCPRateLimitConfiguration = HostedMCPRateLimitConfiguration(),
        keepAliveInterval: TimeInterval = HostedMCPConstants.sseKeepAliveIntervalSeconds,
        ssePromotionWaitThresholdSeconds: Int = HostedMCPConstants.ssePromotionWaitThresholdSeconds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.toolExecutor = toolExecutor
        self.serverVersion = serverVersion
        self.agentTextVersion = agentTextVersion
        self.rateLimitConfig = rateLimitConfig
        self.keepAliveInterval = max(0.05, keepAliveInterval)
        self.ssePromotionWaitThresholdSeconds = ssePromotionWaitThresholdSeconds
        self.now = now
    }

    /// Cancels all in-flight requests (both eras) and invalidates legacy sessions belonging to `agentID`
    /// when the agent's token is rotated or revoked (§6).
    func cancelAllRequests(forAgent agentID: UUID) {
        let tokens: [HostedMCPCancellationToken]
        stateLock.lock()
        let allEntries = Array(inFlightLegacyRequests.values) + Array(inFlightModernRequests.values)
        tokens = allEntries.filter { $0.agentID == agentID }.map(\.token)
        legacySessions = legacySessions.filter { $0.key.agentID != agentID }
        bucketsByAgent.removeValue(forKey: agentID)
        stateLock.unlock()
        for token in tokens {
            token.cancel()
        }
    }

    /// Cancels all in-flight requests across all agents when the server stops or shuts down (§7.1).
    func cancelAllRequests() {
        let tokens: [HostedMCPCancellationToken]
        stateLock.lock()
        let allEntries = Array(inFlightLegacyRequests.values) + Array(inFlightModernRequests.values)
        tokens = allEntries.map(\.token)
        inFlightLegacyRequests.removeAll()
        inFlightModernRequests.removeAll()
        legacySessions.removeAll()
        stateLock.unlock()
        for token in tokens {
            token.cancel()
        }
    }

    /// Convenience entry point returning a single `HostedMCPHTTPResponse` (used when SSE streaming
    /// is not requested).
    func handlePOST(
        request: HostedMCPHTTPRequest,
        agent: AgentIdentity
    ) async -> HostedMCPHTTPResponse {
        let outcome = await dispatch(request: request, agent: agent, onSSEChunk: nil)
        switch outcome {
        case .httpResponse(let response):
            return response
        case .sse(let headBytes):
            return HostedMCPHTTPResponse(statusCode: 200, body: headBytes)
        }
    }

    /// Full entry point supporting SSE promotion (`text/event-stream`) when `onSSEChunk` is provided.
    func dispatch(
        request: HostedMCPHTTPRequest,
        agent: AgentIdentity,
        onSSEHead: (@Sendable (Data) async -> Void)? = nil,
        onSSEChunk: (@Sendable (Data) async -> Void)?
    ) async -> HostedMCPDispatchOutcome {
        let incoming: JSONRPCIncoming
        do {
            incoming = try JSONRPCCodec.decode(request.body)
        } catch let codecError {
            let body = JSONRPCCodec.encodeError(
                JSONRPCError(code: codecError.rpcErrorCode, message: codecError.message),
                id: nil
            )
            return .httpResponse(.json(statusCode: 400, body: body))
        }

        switch incoming {
        case .response:
            let body = JSONRPCCodec.encodeError(
                JSONRPCError(
                    code: MCPErrorCode.invalidRequest,
                    message: "Invalid Request: client responses are not accepted by this server"
                ),
                id: nil
            )
            return .httpResponse(.json(statusCode: 400, body: body))

        case .notification(let notification):
            let response = handleNotification(notification, request: request, agent: agent)
            return .httpResponse(response)

        case .request(let rpcRequest):
            return await handleRequest(
                rpcRequest,
                httpRequest: request,
                agent: agent,
                onSSEHead: onSSEHead,
                onSSEChunk: onSSEChunk
            )
        }
    }

    // MARK: - Notifications (§7.3)

    private func handleNotification(
        _ notification: JSONRPCNotification,
        request: HostedMCPHTTPRequest,
        agent: AgentIdentity
    ) -> HostedMCPHTTPResponse {
        let metaObj = notification.params?.objectValue?["_meta"]?.objectValue
        let isModernNotification = metaObj?[MCPWire.protocolVersionMetaKey] != nil
            || request.head.header(MCPConstants.protocolVersionHeader) == MCPConstants.modernProtocolVersion

        if isModernNotification {
            let headerVer = request.head.header(MCPConstants.protocolVersionHeader)?
                .trimmingCharacters(in: .whitespaces)
            if let metaVer = metaObj?[MCPWire.protocolVersionMetaKey]?.stringValue {
                if headerVer != metaVer {
                    return rpcErrorResponse(
                        statusCode: 400,
                        id: nil,
                        code: MCPErrorCode.headerMismatch,
                        message: "Header mismatch: MCP-Protocol-Version must match params._meta"
                    )
                }
                if metaVer != MCPConstants.modernProtocolVersion {
                    return unsupportedVersionResponse(id: nil)
                }
            }
            // Modern notifications do not require `Mcp-Method` and return 202 empty body (§7.3).
            return .empty(statusCode: 202)
        }

        // Legacy notification
        if let headerVer = request.head.header(MCPConstants.protocolVersionHeader)?
            .trimmingCharacters(in: .whitespaces),
           !headerVer.isEmpty,
           !HostedMCPConstants.supportedLegacyProtocolVersions.contains(headerVer)
        {
            return unsupportedVersionResponse(id: nil)
        }

        if notification.method == MCPWire.cancelledNotification {
            if let rawReqID = notification.params?.objectValue?["requestId"],
               let targetID = Self.parseJSONRPCID(from: rawReqID)
            {
                let sessionID = Self.normalizedHeader(request.head.header("Mcp-Session-Id"))
                cancelLegacyInFlight(agentID: agent.id, sessionID: sessionID, requestID: targetID)
            }
        }

        return .empty(statusCode: 202)
    }

    // MARK: - Requests (§7.3)

    private func handleRequest(
        _ rpcRequest: JSONRPCRequest,
        httpRequest: HostedMCPHTTPRequest,
        agent: AgentIdentity,
        onSSEHead: (@Sendable (Data) async -> Void)?,
        onSSEChunk: (@Sendable (Data) async -> Void)?
    ) async -> HostedMCPDispatchOutcome {
        // Rule: `initialize` is ALWAYS routed to legacy, regardless of `_meta` (§7.3).
        if rpcRequest.method == MCPWire.initializeMethod {
            if let retryAfterMs = checkRateLimit(for: agent.id) {
                return .httpResponse(rateLimitHTTP429Response(id: rpcRequest.id, retryAfterMs: retryAfterMs))
            }
            return .httpResponse(handleLegacyInitialize(rpcRequest, agent: agent))
        }

        let paramsObj = rpcRequest.params?.objectValue
        let metaObj = paramsObj?["_meta"]?.objectValue
        let hasModernMetaKey = metaObj?[MCPWire.protocolVersionMetaKey] != nil
        let headerVersion = Self.normalizedHeader(
            httpRequest.head.header(MCPConstants.protocolVersionHeader)
        )

        if hasModernMetaKey || headerVersion == MCPConstants.modernProtocolVersion {
            return await handleModernRequest(
                rpcRequest,
                httpRequest: httpRequest,
                headerVersion: headerVersion,
                paramsObj: paramsObj,
                metaObj: metaObj,
                agent: agent,
                onSSEHead: onSSEHead,
                onSSEChunk: onSSEChunk
            )
        } else {
            return await handleLegacyRequest(
                rpcRequest,
                httpRequest: httpRequest,
                headerVersion: headerVersion,
                paramsObj: paramsObj,
                metaObj: metaObj,
                agent: agent,
                onSSEHead: onSSEHead,
                onSSEChunk: onSSEChunk
            )
        }
    }

    // MARK: - Modern Era (2026-07-28, Stateless, §7.3)

    private func handleModernRequest(
        _ rpcRequest: JSONRPCRequest,
        httpRequest: HostedMCPHTTPRequest,
        headerVersion: String?,
        paramsObj: [String: JSONValue]?,
        metaObj: [String: JSONValue]?,
        agent: AgentIdentity,
        onSSEHead: (@Sendable (Data) async -> Void)?,
        onSSEChunk: (@Sendable (Data) async -> Void)?
    ) async -> HostedMCPDispatchOutcome {
        // 1. If `MCP-Protocol-Version: 2026-07-28` is sent without `_meta[protocolVersion]` -> 400 -32602
        guard let metaVersion = metaObj?[MCPWire.protocolVersionMetaKey]?.stringValue else {
            return .httpResponse(rpcErrorResponse(
                statusCode: 400,
                id: rpcRequest.id,
                code: MCPErrorCode.invalidParams,
                message: "Invalid params: params._meta.io.modelcontextprotocol/protocolVersion is required"
            ))
        }

        // 2. `MCP-Protocol-Version` header is required and must match `_meta` -> else 400 -32020
        guard let headerVersion, headerVersion == metaVersion else {
            return .httpResponse(rpcErrorResponse(
                statusCode: 400,
                id: rpcRequest.id,
                code: MCPErrorCode.headerMismatch,
                message: "Header mismatch: MCP-Protocol-Version must match params._meta.io.modelcontextprotocol/protocolVersion"
            ))
        }

        // 3. Supported modern version check -> else 400 -32022 with `data.supported`
        guard metaVersion == MCPConstants.modernProtocolVersion else {
            return .httpResponse(unsupportedVersionResponse(id: rpcRequest.id))
        }

        // 4. Required `_meta[clientCapabilities]` key -> else 400 -32602
        guard metaObj?[MCPWire.clientCapabilitiesMetaKey]?.objectValue != nil else {
            return .httpResponse(rpcErrorResponse(
                statusCode: 400,
                id: rpcRequest.id,
                code: MCPErrorCode.invalidParams,
                message: "Invalid params: params._meta.io.modelcontextprotocol/clientCapabilities is required"
            ))
        }

        // 5. `Mcp-Method` header must equal `method` -> else 400 -32020
        let mcpMethodHeader = Self.normalizedHeader(httpRequest.head.header("Mcp-Method"))
        guard mcpMethodHeader == rpcRequest.method else {
            return .httpResponse(rpcErrorResponse(
                statusCode: 400,
                id: rpcRequest.id,
                code: MCPErrorCode.headerMismatch,
                message: "Header mismatch: Mcp-Method must equal the request body method"
            ))
        }

        // 6. For `tools/call`, `Mcp-Name` (after `=?base64?…?=` decoding) must equal `params.name` -> else 400 -32020
        if rpcRequest.method == MCPWire.toolsCallMethod {
            let bodyToolName = paramsObj?["name"]?.stringValue
            let rawNameHeader = httpRequest.head.header("Mcp-Name")
            let decodedHeaderName = rawNameHeader.flatMap(Self.decodeSentinelHeaderValue)
            guard let bodyToolName, !bodyToolName.isEmpty, decodedHeaderName == bodyToolName else {
                return .httpResponse(rpcErrorResponse(
                    statusCode: 400,
                    id: rpcRequest.id,
                    code: MCPErrorCode.headerMismatch,
                    message: "Header mismatch: Mcp-Name must match params.name"
                ))
            }
        }

        // 7. Method dispatch in Modern Era: only `server/discover`, `tools/list`, `tools/call` exist.
        // Any other method (including `ping` and `subscriptions/listen`) -> 404 -32601 (§7.3).
        switch rpcRequest.method {
        case MCPWire.discoverMethod, MCPWire.toolsListMethod:
            if let retryAfterMs = checkRateLimit(for: agent.id) {
                return .httpResponse(rateLimitHTTP429Response(id: rpcRequest.id, retryAfterMs: retryAfterMs))
            }
            let result = rpcRequest.method == MCPWire.discoverMethod
                ? buildModernDiscoverResult()
                : buildModernToolsListResult()
            let body = JSONRPCCodec.encode(JSONRPCResponse(id: rpcRequest.id, outcome: .result(result)))
            return .httpResponse(.json(statusCode: 200, body: body))

        case MCPWire.toolsCallMethod:
            return await executeToolsCall(
                rpcRequest: rpcRequest,
                paramsObj: paramsObj,
                metaObj: metaObj,
                agent: agent,
                sessionID: nil,
                modern: true,
                onSSEHead: onSSEHead,
                onSSEChunk: onSSEChunk
            )

        default:
            return .httpResponse(rpcErrorResponse(
                statusCode: 404,
                id: rpcRequest.id,
                code: MCPErrorCode.methodNotFound,
                message: "Method not found: \(rpcRequest.method)"
            ))
        }
    }

    // MARK: - Legacy Era (2025-11-25 / 2025-06-18, Session-Based, §7.3)

    private func handleLegacyInitialize(
        _ rpcRequest: JSONRPCRequest,
        agent: AgentIdentity
    ) -> HostedMCPHTTPResponse {
        let paramsObj = rpcRequest.params?.objectValue
        guard let requestedVersion = paramsObj?["protocolVersion"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedVersion.isEmpty
        else {
            return rpcErrorResponse(
                statusCode: 400,
                id: rpcRequest.id,
                code: MCPErrorCode.invalidParams,
                message: "Invalid params: protocolVersion is required on initialize"
            )
        }

        // Echo supported legacy version {2025-11-25, 2025-06-18}, otherwise fall back to 2025-11-25.
        let negotiatedVersion: String = HostedMCPConstants.supportedLegacyProtocolVersions.contains(requestedVersion)
            ? requestedVersion
            : MCPConstants.legacyProtocolVersion

        let sessionID = UUID().uuidString.lowercased()
        rememberLegacySession(agentID: agent.id, sessionID: sessionID, version: negotiatedVersion)

        let result: JSONValue = .object([
            "protocolVersion": .string(negotiatedVersion),
            "capabilities": capabilitiesJSON,
            "serverInfo": serverInfoJSON,
            "instructions": .string(HostedMCPInstructions.text),
            "_meta": .object([
                HostedMCPConstants.agentTextVersionMetaKey: .string(agentTextVersion),
            ]),
        ])
        let body = JSONRPCCodec.encode(JSONRPCResponse(id: rpcRequest.id, outcome: .result(result)))
        return .json(
            statusCode: 200,
            headers: [("Mcp-Session-Id", sessionID)],
            body: body
        )
    }

    private func handleLegacyRequest(
        _ rpcRequest: JSONRPCRequest,
        httpRequest: HostedMCPHTTPRequest,
        headerVersion: String?,
        paramsObj: [String: JSONValue]?,
        metaObj: [String: JSONValue]?,
        agent: AgentIdentity,
        onSSEHead: (@Sendable (Data) async -> Void)?,
        onSSEChunk: (@Sendable (Data) async -> Void)?
    ) async -> HostedMCPDispatchOutcome {
        let sessionID = Self.normalizedHeader(httpRequest.head.header("Mcp-Session-Id"))

        // Validate version header or session version (§7.3, E4):
        // - Header present but unsupported -> 400 -32022
        // - Header absent -> use session's remembered version
        // - Neither header nor remembered session version -> 400 -32022 with supported versions
        if let headerVersion {
            guard HostedMCPConstants.supportedLegacyProtocolVersions.contains(headerVersion) else {
                return .httpResponse(unsupportedVersionResponse(id: rpcRequest.id))
            }
            if let sessionID {
                // Unknown session ID with valid version header is accepted as a new session namespace (D7, E5).
                rememberLegacySessionIfAbsent(agentID: agent.id, sessionID: sessionID, version: headerVersion)
            }
        } else {
            guard let sessionID,
                  lookupLegacySessionVersion(agentID: agent.id, sessionID: sessionID) != nil
            else {
                return .httpResponse(unsupportedVersionResponse(id: rpcRequest.id))
            }
        }

        switch rpcRequest.method {
        case MCPWire.pingMethod, MCPWire.toolsListMethod:
            if let retryAfterMs = checkRateLimit(for: agent.id) {
                return .httpResponse(rateLimitHTTP429Response(id: rpcRequest.id, retryAfterMs: retryAfterMs))
            }
            let result: JSONValue = rpcRequest.method == MCPWire.pingMethod
                ? .object([:])
                : .object([
                    "tools": .array(HostedMCPCatalog.allToolsWireJSON),
                    "_meta": .object([
                        HostedMCPConstants.agentTextVersionMetaKey: .string(agentTextVersion),
                    ]),
                ])
            let body = JSONRPCCodec.encode(JSONRPCResponse(id: rpcRequest.id, outcome: .result(result)))
            return .httpResponse(.json(statusCode: 200, body: body))

        case MCPWire.toolsCallMethod:
            return await executeToolsCall(
                rpcRequest: rpcRequest,
                paramsObj: paramsObj,
                metaObj: metaObj,
                agent: agent,
                sessionID: sessionID,
                modern: false,
                onSSEHead: onSSEHead,
                onSSEChunk: onSSEChunk
            )

        default:
            return .httpResponse(rpcErrorResponse(
                statusCode: 400,
                id: rpcRequest.id,
                code: MCPErrorCode.methodNotFound,
                message: "Method not found: \(rpcRequest.method)"
            ))
        }
    }

    // MARK: - Tool Execution & SSE Promotion (§7.3)

    private func executeToolsCall(
        rpcRequest: JSONRPCRequest,
        paramsObj: [String: JSONValue]?,
        metaObj: [String: JSONValue]?,
        agent: AgentIdentity,
        sessionID: String?,
        modern: Bool,
        onSSEHead: (@Sendable (Data) async -> Void)?,
        onSSEChunk: (@Sendable (Data) async -> Void)?
    ) async -> HostedMCPDispatchOutcome {
        if let retryAfterMs = checkRateLimit(for: agent.id) {
            let result = buildRateLimitedToolCallResult(
                toolName: paramsObj?["name"]?.stringValue ?? "tools/call",
                arguments: paramsObj?["arguments"]?.objectValue ?? [:],
                retryAfterMs: retryAfterMs,
                modern: modern
            )
            let body = JSONRPCCodec.encode(JSONRPCResponse(id: rpcRequest.id, outcome: .result(result)))
            return .httpResponse(.json(statusCode: 200, body: body))
        }

        guard let toolName = paramsObj?["name"]?.stringValue, !toolName.isEmpty else {
            return .httpResponse(rpcErrorResponse(
                statusCode: 400,
                id: rpcRequest.id,
                code: MCPErrorCode.invalidParams,
                message: "Invalid params: tools/call requires a non-empty string 'name'"
            ))
        }

        let arguments: [String: JSONValue]
        if let rawArgs = paramsObj?["arguments"], rawArgs != .null {
            guard let obj = rawArgs.objectValue else {
                return .httpResponse(rpcErrorResponse(
                    statusCode: 400,
                    id: rpcRequest.id,
                    code: MCPErrorCode.invalidParams,
                    message: "Invalid params: tools/call 'arguments' must be a JSON object"
                ))
            }
            arguments = obj
        } else {
            arguments = [:]
        }

        let progressToken = Self.extractProgressToken(from: metaObj)
        let shouldPromoteSSE: Bool = {
            guard onSSEChunk != nil else { return false }
            if progressToken != nil { return true }
            guard toolName == ExternalAutovisorToolNames.waitForEvents else { return false }
            let waitSeconds = arguments["timeout_seconds"].flatMap(\.intValue) ?? HostedMCPConstants.defaultWaitSeconds
            return waitSeconds > ssePromotionWaitThresholdSeconds
        }()

        let cancelToken = HostedMCPCancellationToken()
        let entryID = registerInFlight(
            agentID: agent.id,
            sessionID: sessionID,
            requestID: rpcRequest.id,
            token: cancelToken,
            modern: modern
        )
        defer {
            unregisterInFlight(entryID: entryID, modern: modern)
        }

        let executor = self.toolExecutor
        let executeClosure: @Sendable () async -> ToolExecutionResult = {
            if modern {
                return await withTaskCancellationHandler {
                    await executor.executeTool(
                        name: toolName,
                        arguments: arguments,
                        agent: agent,
                        sessionID: sessionID,
                        isCancelled: { cancelToken.isCancelled || Task.isCancelled }
                    )
                } onCancel: {
                    cancelToken.cancel()
                }
            } else {
                // In legacy era, client connection disconnect is NOT treated as cancellation (§7.3).
                // Only `notifications/cancelled` or agent token rotation/revocation triggers `cancelToken`.
                let detachedLegacyCall = Task {
                    await executor.executeTool(
                        name: toolName,
                        arguments: arguments,
                        agent: agent,
                        sessionID: sessionID,
                        isCancelled: { cancelToken.isCancelled }
                    )
                }
                cancelToken.onCancel {
                    if HostedMCPCatalog.isReadOnlyTool(toolName) {
                        detachedLegacyCall.cancel()
                    }
                }
                return await detachedLegacyCall.value
            }
        }

        if shouldPromoteSSE, let onSSEChunk {
            let headBytes = HostedMCPSSEWriter.responseHeaderData()
            await onSSEHead?(headBytes)
            await onSSEChunk(HostedMCPSSEWriter.primingCommentData())

            let gate = SSEProgressGate()
            let interval = self.keepAliveInterval
            let tickerTask = Task {
                var step = 0
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(interval))
                    } catch {
                        break
                    }
                    if Task.isCancelled { break }
                    guard let tickData = gate.nextTickData(step: &step, progressToken: progressToken) else {
                        break
                    }
                    await onSSEChunk(tickData)
                }
            }

            let execResult = await executeClosure()
            gate.markFinished()
            tickerTask.cancel()
            _ = await tickerTask.value

            let rpcResult = buildToolCallResultJSON(from: execResult, modern: modern)
            let finalResponse = JSONRPCResponse(id: rpcRequest.id, outcome: .result(rpcResult))
            let finalFrame = HostedMCPSSEWriter.messageFrameData(JSONRPCCodec.encode(finalResponse))
            await onSSEChunk(finalFrame)
            return .sse(headBytes: headBytes)
        } else {
            let execResult = await executeClosure()
            let rpcResult = buildToolCallResultJSON(from: execResult, modern: modern)
            let body = JSONRPCCodec.encode(JSONRPCResponse(id: rpcRequest.id, outcome: .result(rpcResult)))
            return .httpResponse(.json(statusCode: 200, body: body))
        }
    }

    // MARK: - Result & Error Builders

    private var serverInfoJSON: JSONValue {
        .object([
            "name": .string(HostedMCPConstants.serverName),
            "title": .string(HostedMCPConstants.serverTitle),
            "version": .string(serverVersion),
        ])
    }

    private var capabilitiesJSON: JSONValue {
        .object([
            "tools": .object([
                "listChanged": .bool(false),
            ]),
        ])
    }

    private var modernMetaJSON: [String: JSONValue] {
        [
            MCPWire.serverInfoMetaKey: serverInfoJSON,
            HostedMCPConstants.agentTextVersionMetaKey: .string(agentTextVersion),
        ]
    }

    private func buildModernDiscoverResult() -> JSONValue {
        var meta = modernMetaJSON
        meta["ttlMs"] = .int(HostedMCPConstants.discoveryCacheTTLMs)
        meta["cacheScope"] = .string(HostedMCPConstants.catalogueCacheScope)
        return .object([
            "resultType": .string("complete"),
            "protocolVersion": .string(MCPConstants.modernProtocolVersion),
            "supportedVersions": .array(HostedMCPConstants.allSupportedProtocolVersions.map(JSONValue.string)),
            "capabilities": capabilitiesJSON,
            "serverInfo": serverInfoJSON,
            "instructions": .string(HostedMCPInstructions.text),
            "tools": .array(HostedMCPCatalog.allToolsWireJSON),
            "ttlMs": .int(HostedMCPConstants.discoveryCacheTTLMs),
            "cacheScope": .string(HostedMCPConstants.catalogueCacheScope),
            "_meta": .object(meta),
        ])
    }

    private func buildModernToolsListResult() -> JSONValue {
        var meta = modernMetaJSON
        meta["ttlMs"] = .int(HostedMCPConstants.discoveryCacheTTLMs)
        meta["cacheScope"] = .string(HostedMCPConstants.catalogueCacheScope)
        return .object([
            "resultType": .string("complete"),
            "tools": .array(HostedMCPCatalog.allToolsWireJSON),
            "ttlMs": .int(HostedMCPConstants.discoveryCacheTTLMs),
            "cacheScope": .string(HostedMCPConstants.catalogueCacheScope),
            "_meta": .object(meta),
        ])
    }

    private func buildToolCallResultJSON(
        from execution: ToolExecutionResult,
        modern: Bool
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(execution.outputJSON),
                ]),
            ]),
            "isError": .bool(execution.isError),
        ]
        if modern {
            object["resultType"] = .string("complete")
            object["_meta"] = .object(modernMetaJSON)
        } else {
            object["_meta"] = .object([
                HostedMCPConstants.agentTextVersionMetaKey: .string(agentTextVersion),
            ])
        }
        return .object(object)
    }

    private func buildRateLimitedToolCallResult(
        toolName: String,
        arguments: [String: JSONValue],
        retryAfterMs: Int,
        modern: Bool
    ) -> JSONValue {
        // The envelope every other refusal on this surface uses, so an agent reads one shape:
        // until 2026-11-09 this one alone spelled its code in lowercase and put the wait in three
        // places, none of them `details`.
        // Nothing judged the call, so its next is the call: what it sent of the arguments that say
        // where it reads, its folder included, typed as the hosted schema types them (E1 review
        // R8 — until 2026-11-12 the hint named the tool alone). It never reaches the exit seam of
        // `executeExternalAutovisorTool`, so the completion runs here, with no folder proved.
        var execResult = makeErrorResult(
            toolName: toolName,
            args: [:],
            code: .rateLimited,
            message: "Rate limit exceeded for this agent. Retry after \(retryAfterMs) ms.",
            details: ["retry_after_ms": "\(retryAfterMs)"],
            next: ExternalNextCall.afterRateLimit.hint(
                after: toolName, call: arguments.mapValues { $0.toFoundation() })
        )
        execResult.outputJSON = HostedMCPNextHintCompletion.completing(execResult.outputJSON, provenFolderID: nil)
        return buildToolCallResultJSON(from: execResult, modern: modern)
    }

    private func rateLimitHTTP429Response(
        id: JSONRPCID,
        retryAfterMs: Int
    ) -> HostedMCPHTTPResponse {
        let retrySeconds = max(1, Int(ceil(Double(retryAfterMs) / 1_000.0)))
        let err = JSONRPCError(
            code: MCPErrorCode.invalidRequest,
            message: "Too Many Requests: retry after \(retryAfterMs) ms",
            data: .object(["retry_after_ms": .int(retryAfterMs)])
        )
        let body = JSONRPCCodec.encode(JSONRPCResponse(id: id, outcome: .failure(err)))
        return .json(
            statusCode: 429,
            headers: [("Retry-After", "\(retrySeconds)")],
            body: body
        )
    }

    private func unsupportedVersionResponse(id: JSONRPCID?) -> HostedMCPHTTPResponse {
        let data: JSONValue = .object([
            "supported": .array(HostedMCPConstants.allSupportedProtocolVersions.map(JSONValue.string)),
        ])
        let err = JSONRPCError(
            code: MCPErrorCode.unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            data: data
        )
        let body = JSONRPCCodec.encodeError(err, id: id)
        return .json(statusCode: 400, body: body)
    }

    private func rpcErrorResponse(
        statusCode: Int,
        id: JSONRPCID?,
        code: Int,
        message: String,
        data: JSONValue? = nil
    ) -> HostedMCPHTTPResponse {
        let err = JSONRPCError(code: code, message: message, data: data)
        let body = JSONRPCCodec.encodeError(err, id: id)
        return .json(statusCode: statusCode, body: body)
    }

    // MARK: - State Helpers (Rate Limit, Legacy Sessions, In-Flight Tracking)

    private func checkRateLimit(for agentID: UUID) -> Int? {
        let currentNow = now()
        stateLock.lock()
        defer { stateLock.unlock() }

        let capacity = Double(rateLimitConfig.capacity)
        let rate = rateLimitConfig.refillPerSecond
        var bucket = bucketsByAgent[agentID] ?? AgentTokenBucket(tokens: capacity, lastRefill: currentNow)
        let elapsed = max(0, currentNow.timeIntervalSince(bucket.lastRefill))
        if elapsed > 0 {
            bucket.tokens = min(capacity, bucket.tokens + elapsed * rate)
            bucket.lastRefill = currentNow
        }
        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0
            bucketsByAgent[agentID] = bucket
            return nil
        } else {
            bucketsByAgent[agentID] = bucket
            let needed = max(0.001, 1.0 - bucket.tokens)
            let waitSeconds = needed / rate
            return max(1, Int(ceil(waitSeconds * 1_000.0)))
        }
    }

    private func rememberLegacySession(agentID: UUID, sessionID: String, version: String) {
        stateLock.lock()
        legacySessions[SessionKey(agentID: agentID, sessionID: sessionID)] = version
        stateLock.unlock()
    }

    private func rememberLegacySessionIfAbsent(agentID: UUID, sessionID: String, version: String) {
        let key = SessionKey(agentID: agentID, sessionID: sessionID)
        stateLock.lock()
        if legacySessions[key] == nil {
            legacySessions[key] = version
        }
        stateLock.unlock()
    }

    private func lookupLegacySessionVersion(agentID: UUID, sessionID: String) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return legacySessions[SessionKey(agentID: agentID, sessionID: sessionID)]
    }

    private func registerInFlight(
        agentID: UUID,
        sessionID: String?,
        requestID: JSONRPCID,
        token: HostedMCPCancellationToken,
        modern: Bool
    ) -> UUID {
        let entryID = UUID()
        let entry = InFlightEntry(
            entryID: entryID,
            agentID: agentID,
            sessionID: sessionID,
            requestID: requestID,
            token: token
        )
        stateLock.lock()
        if modern {
            inFlightModernRequests[entryID] = entry
        } else {
            inFlightLegacyRequests[entryID] = entry
        }
        stateLock.unlock()
        return entryID
    }

    private func unregisterInFlight(entryID: UUID, modern: Bool) {
        stateLock.lock()
        if modern {
            inFlightModernRequests.removeValue(forKey: entryID)
        } else {
            inFlightLegacyRequests.removeValue(forKey: entryID)
        }
        stateLock.unlock()
    }

    private func cancelLegacyInFlight(
        agentID: UUID,
        sessionID: String?,
        requestID: JSONRPCID
    ) {
        let tokensToCancel: [HostedMCPCancellationToken]
        stateLock.lock()
        let matchingAgentAndID = inFlightLegacyRequests.values.filter {
            $0.agentID == agentID && $0.requestID == requestID
        }
        if let sessionID {
            tokensToCancel = matchingAgentAndID.filter { $0.sessionID == sessionID }.map(\.token)
        } else {
            // Ambiguous cancellation without session is ignored when >1 request matches (§7.3).
            if matchingAgentAndID.count == 1, let single = matchingAgentAndID.first {
                tokensToCancel = [single.token]
            } else {
                tokensToCancel = []
            }
        }
        stateLock.unlock()
        for token in tokensToCancel {
            token.cancel()
        }
    }

    // MARK: - Header & Token Parsing Helpers

    private static func normalizedHeader(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Decodes the 2026-07-28 `=?base64?…?=` header sentinel before comparing with the body field.
    static func decodeSentinelHeaderValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("=?base64?"), trimmed.hasSuffix("?=") {
            guard trimmed.count >= 11 else { return nil }
            let base64Slice = String(trimmed.dropFirst(9).dropLast(2))
            guard let data = Data(base64Encoded: base64Slice),
                  let decoded = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return decoded
        }
        return trimmed
    }

    private static func extractProgressToken(from metaObj: [String: JSONValue]?) -> JSONValue? {
        guard let raw = metaObj?["progressToken"] else { return nil }
        switch raw {
        case .string(let s) where !s.isEmpty:
            return .string(s)
        case .int(let i):
            return .int(i)
        default:
            return nil
        }
    }

    private static func parseJSONRPCID(from value: JSONValue) -> JSONRPCID? {
        switch value {
        case .string(let s):
            return .string(s)
        case .int(let i):
            return .number(i)
        default:
            return nil
        }
    }
}

private nonisolated final class SSEProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func nextTickData(step: inout Int, progressToken: JSONValue?) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        step += 1
        var payload = HostedMCPSSEWriter.keepAliveCommentData()
        if let progressToken {
            let notification = JSONRPCNotification(
                method: MCPWire.progressNotification,
                params: .object([
                    "progressToken": progressToken,
                    "progress": .int(step),
                ])
            )
            payload.append(HostedMCPSSEWriter.messageFrameData(JSONRPCCodec.encode(notification)))
        }
        return payload
    }
}
