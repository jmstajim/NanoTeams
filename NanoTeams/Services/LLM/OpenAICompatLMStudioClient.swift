import Foundation

/// LM Studio's OpenAI-compatible endpoint — `POST /v1/chat/completions` — the client a
/// `.native` request on that provider goes through.
///
/// It exists because the app's own LM Studio endpoint cannot carry the native protocol:
/// `/api/v1/chat` has no `tools` field (15 fields; tools reach it only through server-side
/// `integrations`), so a model the server reports as tool-trained can only be handed its
/// schemas here. `LLMClientRouter` sends exactly the requests that need it — an LM Studio
/// config in `.native` mode whose call declares tools or whose wire already carries native
/// `tool_calls` — and everything else (vision, judges, the auto-answer, consultations, the
/// benchmark) stays on `NativeLMStudioClient`, whose `prompt_processing.*` progress and
/// `stats` this route does not report (`stats: {}`; DEBTS names `/api/v0/chat/completions` as
/// the alternative that does).
///
/// Everything about the SERVER is delegated to the native client it holds: the explicit
/// load before each request (`ChatModelEnsurer.ensureLoaded`, which measured 2026-09-13
/// serves `/v1` with the same instance), the request census, the model list and every
/// capability probe. This type owns the wire and nothing else.
nonisolated struct OpenAICompatLMStudioClient: LLMClient {

    let session: any NetworkSession
    let tokenResolver: any LLMTokenResolver
    /// The lifecycle owner. One instance per router, shared with the `.lmStudio` slot, so the
    /// two clients agree on which model is loaded and how many requests are open on it.
    let native: NativeLMStudioClient

    init(
        session: any NetworkSession = URLSession.shared,
        tokenResolver: any LLMTokenResolver = DefaultLLMTokenResolver(),
        native: NativeLMStudioClient? = nil
    ) {
        self.session = session
        self.tokenResolver = tokenResolver
        self.native = native ?? NativeLMStudioClient(session: session, tokenResolver: tokenResolver)
    }

    // MARK: - Chat

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger? = nil,
        stepID: String? = nil,
        roleName: String? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            // Detached for the reason the two sibling clients are: the caller is main-actor
            // code, and per-chunk decode belongs off it.
            let streamTask = Task.detached {
                var requestRecord: NetworkLogRecord?
                var startTime = Date()
                var capturedResidency: ClientResidencyFacts?
                // Declared outside the `do` so the interrupted record can carry them.
                var accumulatedContent = ""
                var accumulatedThinking = ""
                var accumulatedToolCalls: [StreamEvent.ToolCallDelta] = []
                let ensurer = self.native.modelEnsurer
                await ensurer.beginRequest(
                    modelName: config.modelName, baseURLString: config.baseURLString)
                defer {
                    let model = config.modelName
                    let base = config.baseURLString
                    Task { await ensurer.endRequest(modelName: model, baseURLString: base) }
                }
                do {
                    guard let baseURL = URL(string: config.baseURLString) else {
                        throw LLMClientError.invalidBaseURL(config.baseURLString)
                    }

                    // Explicit adopt-or-load through the NATIVE client — the instance it loads
                    // is the one this route is served by, and JIT-loading here would let LM
                    // Studio auto-evict it (`NativeLMStudioClient.streamChat` says why).
                    let ensureStart = Date()
                    let ensureOutcome = try await ensurer.ensureLoaded(
                        modelName: config.modelName,
                        baseURLString: config.baseURLString,
                        client: self.native
                    )
                    if case .loaded = ensureOutcome {
                        capturedResidency = ClientResidencyFacts(
                            appLoadedModelForThisRequest: true,
                            appModelLoadMs: Date().timeIntervalSince(ensureStart) * 1000)
                        continuation.yield(StreamEvent(clientResidency: capturedResidency))
                    }

                    var url = baseURL
                    url.append(path: "v1")
                    url.append(path: "chat")
                    url.append(path: "completions")

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.applyLMStudioBearer(baseURL: config.baseURLString, resolver: tokenResolver)
                    request.timeoutInterval = config.requestTimeoutSeconds > 0
                        ? TimeInterval(config.requestTimeoutSeconds)
                        : TimeInterval(Int32.max)

                    let payload = Self.buildRequest(config: config, messages: messages, tools: tools)
                    let bodyData = try JSONCoderFactory.makeWireEncoder().encode(payload)
                    request.httpBody = bodyData

                    if let logger {
                        logger.noteProvenanceIfNeeded(config: config, stepID: stepID, roleName: roleName)
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
                            if errorBody.utf8.count > 500 { break }
                        }
                        let body = errorBody.isEmpty
                            ? nil
                            : errorBody.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw LLMClientError.badHTTPStatus(http.statusCode, body)
                    }

                    var capturedUsage: TokenUsage?
                    var capturedReasoningTokens: Int?
                    var capturedFinishReason: String?
                    var parser = OpenAIChatChunkParser()

                    func handle(_ event: OpenAIChatChunkParser.ParsedEvent) throws {
                        switch event {
                        case .contentDelta(let content):
                            accumulatedContent += content
                            continuation.yield(StreamEvent(contentDelta: content))
                        case .thinkingDelta(let thinking):
                            accumulatedThinking += thinking
                            continuation.yield(StreamEvent(thinkingDelta: thinking))
                        case .toolCallDeltas(let calls):
                            accumulatedToolCalls += calls
                            continuation.yield(StreamEvent(toolCallDeltas: calls))
                        case .finish(let reason):
                            capturedFinishReason = reason
                        case .usage(let usage, let reasoningTokens):
                            capturedUsage = usage
                            capturedReasoningTokens = reasoningTokens
                        case .error(let message):
                            // Same rule as the Ollama client: a rejection of the model's own
                            // call is the model's turn, not the server's health.
                            let sawGeneration = !accumulatedContent.isEmpty
                                || !accumulatedThinking.isEmpty || !accumulatedToolCalls.isEmpty
                            if NativeToolCallRejectionClassifier.isRejection(
                                message: message, sawGeneration: sawGeneration,
                                toolsDeclared: !tools.isEmpty)
                            {
                                throw LLMClientError.nativeToolCallRejected(message)
                            }
                            throw LLMClientError.providerError(message)
                        case .done:
                            break
                        }
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in parser.parse(line: line) {
                            try handle(event)
                        }
                    }
                    for event in parser.finalize() {
                        try handle(event)
                    }

                    // Terminal event: usage, how the server stopped, and what it attributed to
                    // reasoning. No `serverPrefill`: this route reports no model-load time and
                    // no prefill window (`stats` is empty here) — `tokenUsage.inputTokens`
                    // carries the prompt count the truncation detector reads.
                    if capturedUsage != nil || capturedFinishReason != nil
                        || capturedReasoningTokens != nil {
                        continuation.yield(StreamEvent(
                            tokenUsage: capturedUsage,
                            serverReasoningOutputTokens: capturedReasoningTokens,
                            serverDoneReason: capturedFinishReason))
                    }

                    if let logger, let reqRecord = requestRecord {
                        let durationMs = Date().timeIntervalSince(startTime) * 1000
                        let responseRecord = NetworkLogger.createResponseRecord(
                            for: reqRecord,
                            statusCode: http.statusCode,
                            durationMs: durationMs,
                            body: NetworkLogger.streamedBodyText(
                                thinking: accumulatedThinking, content: accumulatedContent,
                                toolCalls: Self.coalesce(accumulatedToolCalls)),
                            error: nil,
                            inputTokens: capturedUsage?.inputTokens,
                            outputTokens: capturedUsage?.outputTokens,
                            serverPrefill: nil,
                            clientResidency: capturedResidency,
                            doneReason: capturedFinishReason
                        )
                        logger.append(responseRecord)
                    }

                    continuation.finish()
                } catch {
                    // One arm for a transport failure, a provider error chunk and a
                    // cancellation alike: the record carries what had streamed by then.
                    // Until 2026-09-13 a Swift cancellation logged nothing and a URL-layer
                    // one logged `cancelled` with no body, so a request cut off at the
                    // run's timeout after minutes of reasoning left the log blank.
                    if let logger, let reqRecord = requestRecord {
                        let durationMs = Date().timeIntervalSince(startTime) * 1000
                        let errorRecord = NetworkLogger.createResponseRecord(
                            for: reqRecord,
                            statusCode: 0,
                            durationMs: durationMs,
                            body: NetworkLogger.streamedBodyText(
                                thinking: accumulatedThinking, content: accumulatedContent,
                                toolCalls: Self.coalesce(accumulatedToolCalls)),
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

    /// The streamed pieces folded into whole calls, for the log line only — the same fold
    /// `ToolCallAccumulator` performs for the caller.
    static func coalesce(_ deltas: [StreamEvent.ToolCallDelta]) -> [StreamEvent.ToolCallDelta] {
        var accumulator = ToolCallAccumulator()
        accumulator.absorb(deltas)
        return accumulator.finalize().enumerated().map { offset, call in
            StreamEvent.ToolCallDelta(
                index: offset, id: call.providerID, name: call.name, argumentsDelta: call.argumentsJSON)
        }
    }

    // MARK: - Everything else is the native client's

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] {
        try await native.fetchModels(config: config, visionOnly: visionOnly)
    }

    func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] {
        try await native.fetchEmbeddingModels(config: config)
    }

    func loadModel(
        provider: LLMProvider, modelName: String, baseURLString: String
    ) async throws -> String {
        try await native.loadModel(provider: provider, modelName: modelName, baseURLString: baseURLString)
    }

    func unloadModel(
        provider: LLMProvider, instanceID: String, baseURLString: String
    ) async throws {
        try await native.unloadModel(provider: provider, instanceID: instanceID, baseURLString: baseURLString)
    }

    func listLoadedInstances(
        provider: LLMProvider, baseURLString: String
    ) async throws -> LoadedInstanceListing {
        try await native.listLoadedInstances(provider: provider, baseURLString: baseURLString)
    }

    func modelSupportsVision(config: LLMConfig) async -> Bool? {
        await native.modelSupportsVision(config: config)
    }

    func modelContextLength(config: LLMConfig) async -> Int? {
        await native.modelContextLength(config: config)
    }

    func modelLoadDetails(config: LLMConfig) async -> ModelLoadDetails? {
        await native.modelLoadDetails(config: config)
    }

    func toolCallingSupport(config: LLMConfig) async -> Bool? {
        await native.toolCallingSupport(config: config)
    }
}
