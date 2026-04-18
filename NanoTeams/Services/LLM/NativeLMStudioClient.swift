import Foundation

/// LM Studio native API client — stateful via `previous_response_id`.
/// Endpoint: `POST /api/v1/chat`
///
/// Notes:
/// - System prompt uses `system_prompt` field and persists in the response chain
/// - `input` is a plain string (single user message or joined tool results + user text)
/// - No `tools` parameter — tool schemas are injected into `system_prompt` as a Harmony-format
///   description block; models generate `<|call|>` tool calls parsed by HarmonyToolCallParser
/// - SSE uses named `event:` lines (18 event types) instead of JSON `type` field
/// - Token stats come from `stats.tokens_in/tokens_out`
/// - Models endpoint is `/api/v1/models`
struct NativeLMStudioClient: LLMClient {

    let session: any NetworkSession

    init(session: any NetworkSession = URLSession.shared) {
        self.session = session
    }

    // MARK: - Public API

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        session: LLMSession?,
        logger: NetworkLogger? = nil,
        stepID: String? = nil,
        roleName: String? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = Task {
                var requestRecord: NetworkLogRecord?
                var startTime = Date()
                do {
                    guard let baseURL = URL(string: config.baseURLString) else {
                        throw LLMClientError.invalidBaseURL(config.baseURLString)
                    }

                    var url = baseURL
                    url.append(path: "api")
                    url.append(path: "v1")
                    url.append(path: "chat")

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let payload = Self.buildRequest(
                        config: config,
                        messages: messages,
                        tools: tools,
                        session: session
                    )

                    let bodyData = try JSONCoderFactory.makeWireEncoder().encode(payload)
                    request.httpBody = bodyData

                    if let logger {
                        requestRecord = NetworkLogger.createRequestRecord(
                            url: url, method: "POST", body: bodyData,
                            stepID: stepID, roleName: roleName)
                        logger.append(requestRecord!)
                    }

                    try Task.checkCancellation()

                    startTime = Date()
                    let (bytes, response) = try await self.session.sessionBytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMClientError.missingResponse
                    }

                    if !(200..<300).contains(http.statusCode) {
                        if http.statusCode == 429 {
                            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                                .flatMap(Double.init)
                            throw LLMClientError.rateLimited(retryAfter: retryAfter)
                        }
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line + "\n"
                            if errorBody.count > 500 { break }
                        }
                        let body = errorBody.isEmpty
                            ? nil
                            : errorBody.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw LLMClientError.badHTTPStatus(http.statusCode, body)
                    }

                    // Accumulators for network logging
                    var accumulatedContent = ""
                    var accumulatedThinking = ""
                    var capturedResponseID: String?
                    var capturedUsage: TokenUsage?

                    var sseParser = SSEEventParser()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard let event = sseParser.parse(line: line) else { continue }
                        switch event {
                        case .contentDelta(let content):
                            accumulatedContent += content
                            continuation.yield(StreamEvent(contentDelta: content))
                        case .thinkingDelta(let content):
                            accumulatedThinking += content
                            continuation.yield(StreamEvent(thinkingDelta: content))
                        case .chatEnd(let responseID, let usage):
                            capturedResponseID = responseID
                            capturedUsage = usage
                        case .error(let message):
                            throw LLMClientError.providerError(message)
                        case .processingProgress(let progress):
                            continuation.yield(StreamEvent(processingProgress: progress))
                        case .ignored:
                            break
                        }
                    }

                    // Emit final event with session + usage
                    let finalSession = capturedResponseID.map { LLMSession(responseID: $0) }
                    if capturedUsage != nil || finalSession != nil {
                        continuation.yield(StreamEvent(
                            tokenUsage: capturedUsage,
                            session: finalSession
                        ))
                    }

                    // Log response
                    if let logger, let reqRecord = requestRecord {
                        let durationMs = Date().timeIntervalSince(startTime) * 1000
                        var responseBody = ""
                        if !accumulatedThinking.isEmpty {
                            responseBody += "[reasoning]\n\(accumulatedThinking)\n[/reasoning]\n\n"
                        }
                        if !accumulatedContent.isEmpty {
                            responseBody += accumulatedContent
                        }
                        let responseRecord = NetworkLogger.createResponseRecord(
                            for: reqRecord,
                            statusCode: http.statusCode,
                            durationMs: durationMs,
                            body: responseBody.isEmpty ? nil : responseBody,
                            error: nil,
                            inputTokens: capturedUsage?.inputTokens,
                            outputTokens: capturedUsage?.outputTokens
                        )
                        logger.append(responseRecord)
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if let logger, let reqRecord = requestRecord {
                        let durationMs = Date().timeIntervalSince(startTime) * 1000
                        let errorRecord = NetworkLogger.createResponseRecord(
                            for: reqRecord,
                            statusCode: 0,
                            durationMs: durationMs,
                            error: error
                        )
                        logger.append(errorRecord)
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] {
        guard let baseURL = URL(string: config.baseURLString) else {
            throw LLMClientError.invalidBaseURL(config.baseURLString)
        }

        let url = baseURL.appendingPathComponent("api/v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let (data, response) = try await self.session.sessionData(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.missingResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw LLMClientError.badHTTPStatus(http.statusCode, body)
        }

        let decoder = JSONCoderFactory.makeWireDecoder()

        // Try LM Studio native format first: { "models": [{ "key": "...", "type": "llm" }] }
        if let native = try? decoder.decode(NativeModelListResponse.self, from: data) {
            return native.models
                .filter { $0.type == nil || $0.type == "llm" }
                .filter { !visionOnly || $0.capabilities?.vision == true }
                .map(\.key)
                .sorted()
        }

        // Fallback: OpenAI-compatible format — no capability metadata, return all
        let openAI = try decoder.decode(OpenAIModelListResponse.self, from: data)
        return openAI.data.map(\.id).sorted()
    }

}
