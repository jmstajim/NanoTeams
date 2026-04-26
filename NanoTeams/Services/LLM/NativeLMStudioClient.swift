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
                    // Reasoning/MoE models can spend minutes producing the first token on
                    // large prompts. URLRequest's 60s default would otherwise cause the
                    // request to time out before any content arrives. 0 = wait indefinitely.
                    request.timeoutInterval = config.requestTimeoutSeconds > 0
                        ? TimeInterval(config.requestTimeoutSeconds)
                        : TimeInterval(Int32.max)

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
        try await fetchModelsMatching(
            config: config,
            nativeFilter: { info in
                let isLLM = info.type == nil || info.type == "llm"
                let visionOK = !visionOnly || info.capabilities?.vision == true
                return isLLM && visionOK
            }
        )
    }

    func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] {
        // LM Studio reports embedding models with `type == "embeddings"`
        // (with the trailing `s`). Older builds emit `"embedding"` (singular)
        // so match both. OpenAI-compatible fallback has no type metadata and
        // returns the full list — acceptable degraded behavior there because
        // the user can still type a known embedding model name manually.
        try await fetchModelsMatching(
            config: config,
            nativeFilter: { info in info.type == "embeddings" || info.type == "embedding" }
        )
    }

    /// Shared GET `/api/v1/models` + decode. `nativeFilter` runs against the
    /// native response; the OpenAI fallback returns everything (no type info).
    private func fetchModelsMatching(
        config: LLMConfig,
        nativeFilter: (NativeModelListResponse.NativeModelInfo) -> Bool
    ) async throws -> [String] {
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
        // `normalizedUnique` collapses duplicate `key`s (LM Studio surfaces the
        // same model from multiple storage paths/slots), trims whitespace, and
        // sorts case-insensitively — matches what the picker expects.
        do {
            let native = try decoder.decode(NativeModelListResponse.self, from: data)
            return native.models
                .filter(nativeFilter)
                .map(\.key)
                .normalizedUnique()
        } catch {
            // Native decode failed — likely an LM Studio version mismatch or a
            // genuine OpenAI-compatible endpoint. Log so future API regressions
            // are debuggable, then fall through to the OpenAI shape.
            #if DEBUG
            print("NativeLMStudioClient: native model-list decode failed (\(error.localizedDescription)) — falling back to OpenAI shape")
            #endif
        }

        // Fallback: OpenAI-compatible format — no capability metadata, return all
        let openAI = try decoder.decode(OpenAIModelListResponse.self, from: data)
        return openAI.data.map(\.id).normalizedUnique()
    }

    // MARK: - Model Lifecycle (load / unload)

    /// `POST {base}/api/v1/models/load`. Returns `instance_id` on success.
    ///
    /// Idempotency: if the model is already loaded, the duplicate-instance
    /// problem is now prevented upstream by `EmbeddingModelLifecycleService`'s
    /// adoption path (`listLoadedInstances` runs before `loadModel`). The
    /// "non-2xx body decoded as LoadModelResponse" defense-in-depth path
    /// remains because some LM Studio builds historically returned 4xx with
    /// the existing instance_id embedded; if that fires we adopt it. The
    /// previous "fall back to modelName" guess has been removed — fabricating
    /// an id for an unload we can't actually target produced silent leaks.
    ///
    /// Timeout: 600s — first-time loads can include a model download for
    /// users who picked something they don't have on disk yet.
    func loadModel(modelName: String, baseURLString: String) async throws -> String {
        guard let baseURL = URL(string: baseURLString) else {
            throw LLMClientError.invalidBaseURL(baseURLString)
        }
        let url = baseURL.appendingPathComponent("api/v1/models/load")

        let encoder = JSONCoderFactory.makeWireEncoder()
        let body = try encoder.encode(LoadModelRequest(model: modelName, echo_load_config: true))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = body

        let (data, response) = try await self.session.sessionData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.missingResponse
        }

        let decoder = JSONCoderFactory.makeWireDecoder()
        if (200..<300).contains(http.statusCode) {
            let decoded = try decoder.decode(LoadModelResponse.self, from: data)
            return decoded.instance_id
        }

        // Non-2xx defense-in-depth: some LM Studio builds historically replied
        // 4xx with a parseable LoadModelResponse — adopt that id. If the body
        // decodes but `instance_id` is empty, we have no real id to return —
        // fall through to the structured-error path below.
        if let decoded = try? decoder.decode(LoadModelResponse.self, from: data),
           !decoded.instance_id.isEmpty {
            return decoded.instance_id
        }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        throw LLMClientError.badHTTPStatus(http.statusCode, bodyText)
    }

    /// `POST {base}/api/v1/models/unload`.
    ///
    /// Idempotency: HTTP 404 is treated as success (instance already gone,
    /// e.g. LM Studio was restarted between our load and unload). For
    /// non-404 4xx responses we decode the structured `LMStudioErrorEnvelope`
    /// and only honor the "already unloaded" semantics if the matching
    /// substrings appear in `error.message` — NOT in the raw body. Real
    /// error strings (e.g. LoRA's "the requested adapter is not loaded into
    /// the base model") would otherwise collide with our success substrings.
    func unloadModel(instanceID: String, baseURLString: String) async throws {
        guard let baseURL = URL(string: baseURLString) else {
            throw LLMClientError.invalidBaseURL(baseURLString)
        }
        let url = baseURL.appendingPathComponent("api/v1/models/unload")

        let encoder = JSONCoderFactory.makeWireEncoder()
        let body = try encoder.encode(UnloadModelRequest(instance_id: instanceID))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = body

        let (data, response) = try await self.session.sessionData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.missingResponse
        }

        if (200..<300).contains(http.statusCode) { return }

        if http.statusCode == 404 { return }

        let bodyText = String(data: data, encoding: .utf8) ?? ""
        if Self.errorMessageIndicatesAlreadyUnloaded(in: data) {
            return
        }
        throw LLMClientError.badHTTPStatus(http.statusCode, bodyText)
    }

    /// Returns `true` only when the LM Studio error envelope decodes AND the
    /// `error.message` field contains one of the documented "already unloaded"
    /// sentinel substrings. Substring scoped to `error.message` so unrelated
    /// errors (e.g. LoRA "not loaded into base model") can't collide with our
    /// success path.
    private static func errorMessageIndicatesAlreadyUnloaded(in data: Data) -> Bool {
        guard let envelope = try? JSONCoderFactory.makeWireDecoder().decode(LMStudioErrorEnvelope.self, from: data),
              let message = envelope.error?.message?.lowercased()
        else { return false }
        return message.contains("instance not found")
            || message.contains("no such instance")
            || (message.contains("not loaded") && !message.contains("base model"))
    }

    // MARK: - Loaded-Instance Listing (`/api/v0/models`)

    /// `GET {base}/api/v0/models` — LM Studio's per-instance model listing
    /// with a `state: "loaded" | "not-loaded"` field. The OpenAI-shaped
    /// `/api/v1/models` endpoint does NOT carry per-instance state, so this
    /// uses the `v0` route exclusively and degrades to `[]` on any failure
    /// (the caller will then fall through to `loadModel`).
    ///
    /// Returns one entry per loaded instance. `LoadedModelInstance.modelName`
    /// is the canonical name (LM Studio's `:N` dedup suffix stripped) for
    /// matching against `EmbeddingConfig.modelName`. `instanceID` is the raw
    /// `id` to pass to `unloadModel`.
    func listLoadedInstances(baseURLString: String) async throws -> [LoadedModelInstance] {
        guard let baseURL = URL(string: baseURLString) else {
            throw LLMClientError.invalidBaseURL(baseURLString)
        }
        let url = baseURL.appendingPathComponent("api/v0/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let (data, response) = try await self.session.sessionData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.missingResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // 404 here means LM Studio doesn't have v0 (older build). Treat
            // as "no info" so caller falls through to `loadModel` rather than
            // crashing the lifecycle.
            if http.statusCode == 404 { return [] }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.badHTTPStatus(http.statusCode, bodyText)
        }

        let decoded = try JSONCoderFactory.makeWireDecoder().decode(V0ModelListResponse.self, from: data)
        return decoded.data
            .filter { $0.state == "loaded" }
            .map { entry in
                LoadedModelInstance(
                    modelName: Self.canonicalModelName(entry.id),
                    instanceID: entry.id
                )
            }
    }

    /// LM Studio appends `:N` (N >= 2) to disambiguate duplicate-load
    /// instances. The first instance has no suffix. Strip a trailing
    /// `:\d+` to recover the canonical model name used to match against
    /// `EmbeddingConfig.modelName`.
    static func canonicalModelName(_ id: String) -> String {
        guard let colonIdx = id.lastIndex(of: ":") else { return id }
        let suffix = id[id.index(after: colonIdx)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber) else {
            return id
        }
        return String(id[..<colonIdx])
    }

}
