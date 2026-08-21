import Foundation

/// Ollama native API client — STATELESS chat via `POST /api/chat`.
///
/// Unification contract with the LM Studio path:
/// - Tool calling is prompt-based on BOTH providers: the same Harmony
///   tool-schema block (`NativeLMStudioClient.buildToolSchemaSection` — the
///   app-wide SSOT) is injected into the system message, and tool calls come
///   back as `<|call|>{…}<|end|>` text parsed downstream by
///   `HarmonyToolCallParser`. Zero divergence in the tool pipeline.
/// - Statelessness is universal: every call on every provider carries the full
///   conversation and relies on the server's prompt-prefix cache. Server-side
///   response chains were removed app-wide.
/// - No explicit model lifecycle: Ollama loads models on first use and manages
///   residency itself (`keep_alive`), so `loadModel` / `unloadModel` /
///   `listLoadedInstances` intentionally keep the protocol defaults and the
///   `ChatModelEnsurer` census/ledger is never engaged for this provider
///   (`LLMProvider.managesModelResidency == false`).
///
/// Endpoints: `/api/chat` (NDJSON streaming), `/api/tags` (model list),
/// `/api/show` (capabilities / context length).
nonisolated struct OllamaClient: LLMClient {

    let session: any NetworkSession
    let tokenResolver: any LLMTokenResolver

    init(
        session: any NetworkSession = URLSession.shared,
        tokenResolver: any LLMTokenResolver = DefaultLLMTokenResolver()
    ) {
        self.session = session
        self.tokenResolver = tokenResolver
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
            // Detached for the same reason as NativeLMStudioClient: the caller
            // is `@MainActor`, and per-chunk UTF-8 decode + line splitting must
            // stay off the main thread.
            let streamTask = Task.detached {
                var requestRecord: NetworkLogRecord?
                var startTime = Date()
                do {
                    guard let baseURL = URL(string: config.baseURLString) else {
                        throw LLMClientError.invalidBaseURL(config.baseURLString)
                    }

                    var url = baseURL
                    url.append(path: "api")
                    url.append(path: "chat")

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // Ollama itself is unauthenticated, but reverse proxies in
                    // front of it commonly require a bearer — the mechanism is
                    // provider-neutral (keyed by base URL in the Keychain).
                    request.applyLMStudioBearer(baseURL: config.baseURLString, resolver: tokenResolver)
                    request.timeoutInterval = config.requestTimeoutSeconds > 0
                        ? TimeInterval(config.requestTimeoutSeconds)
                        : TimeInterval(Int32.max)

                    let payload = Self.buildRequest(config: config, messages: messages, tools: tools)
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

                    var accumulatedContent = ""
                    var accumulatedThinking = ""
                    var capturedUsage: TokenUsage?
                    var capturedPrefill: ServerPrefillReport?
                    var capturedGenerationNs: Double?
                    var capturedTotalNs: Double?
                    var capturedDoneReason: String?
                    var parser = OllamaChatStreamParser()

                    func handle(_ event: OllamaChatStreamParser.ParsedEvent) throws {
                        switch event {
                        case .contentDelta(let content):
                            accumulatedContent += content
                            continuation.yield(StreamEvent(contentDelta: content))
                        case .thinkingDelta(let thinking):
                            accumulatedThinking += thinking
                            continuation.yield(StreamEvent(thinkingDelta: thinking))
                        case .chatEnd(let report):
                            capturedUsage = report.usage
                            capturedPrefill = report.prefill
                            capturedGenerationNs = report.generationNs
                            capturedTotalNs = report.totalNs
                            capturedDoneReason = report.doneReason
                        case .error(let message):
                            throw LLMClientError.providerError(message)
                        }
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in parser.parse(line: line) {
                            try handle(event)
                        }
                    }
                    // Transport ended — drain any held-back partial-tag text.
                    for event in parser.finalize() {
                        try handle(event)
                    }

                    // Final event: usage plus the server's account of how it prefilled.
                    if capturedUsage != nil || capturedPrefill != nil
                        || capturedGenerationNs != nil || capturedTotalNs != nil
                        || capturedDoneReason != nil {
                        continuation.yield(StreamEvent(
                            tokenUsage: capturedUsage, serverPrefill: capturedPrefill,
                            serverGenerationNs: capturedGenerationNs,
                            serverTotalNs: capturedTotalNs,
                            serverDoneReason: capturedDoneReason))
                    }

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
                            outputTokens: capturedUsage?.outputTokens,
                            serverPrefill: capturedPrefill
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

    // MARK: - Request Building

    /// Builds the `/api/chat` payload. Static + pure for testability, mirroring
    /// `NativeLMStudioClient.buildRequest`.
    ///
    /// - System: all system messages merge into ONE system message, with the
    ///   shared Harmony tool-schema block auto-appended when the prompt doesn't
    ///   already carry it (same marker detection as the LM Studio builder —
    ///   `PromptBuilder` places the block itself via `{toolCalling}`).
    /// - Tool results ride the user channel labelled `[Tool Result]`
    ///   (prompt-based tool calling — models see the exact convention the LM
    ///   Studio flat rendering uses, so behavior is unified across providers).
    /// - Consecutive user-side turns merge into a single message: chat
    ///   templates behave best with alternating roles, and this mirrors the
    ///   LM Studio input-string join.
    static func buildRequest(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema]
    ) -> ChatRequest {
        let systemMessages = messages.filter { $0.role == .system }
        var systemPrompt = systemMessages.compactMap(\.content).joined(separator: "\n\n")
        if !tools.isEmpty && !systemPrompt.contains(NativeLMStudioClient.harmonyBodyMarker) {
            if !systemPrompt.isEmpty { systemPrompt += "\n\n" }
            systemPrompt += NativeLMStudioClient.buildToolSchemaSection(tools: tools)
        }

        var out: [ChatRequestMessage] = []
        if !systemPrompt.isEmpty {
            out.append(ChatRequestMessage(role: "system", content: systemPrompt))
        }

        var pendingUserParts: [String] = []
        var pendingImages: [String] = []
        func flushUser() {
            guard !pendingUserParts.isEmpty || !pendingImages.isEmpty else { return }
            out.append(ChatRequestMessage(
                role: "user",
                content: pendingUserParts.joined(separator: "\n\n"),
                images: pendingImages.isEmpty ? nil : pendingImages))
            pendingUserParts = []
            pendingImages = []
        }

        for msg in messages where msg.role != .system {
            let images = (msg.imageContent ?? []).map(\.base64Data)
            switch msg.role {
            case .user:
                pendingUserParts.append(msg.content ?? "")
                pendingImages.append(contentsOf: images)
            case .tool:
                pendingUserParts.append("[Tool Result]\n\(msg.content ?? "")")
                pendingImages.append(contentsOf: images)
            case .assistant:
                flushUser()
                // Re-materialize tool calls as the Harmony text the model
                // originally emitted. The streaming path truncates the
                // envelope out of the persisted assistant content, so a
                // stateless full-history resend without this would show the
                // model empty assistant turns followed by orphan
                // `[Tool Result]` blocks — degrading every multi-iteration
                // tool loop. `HarmonyToolCallEnvelope` owns those bytes: the
                // LM Studio builder and both measurement surfaces render the
                // same text from the same function.
                out.append(ChatRequestMessage(
                    role: "assistant",
                    content: (msg.content ?? "")
                        + HarmonyToolCallEnvelope.appendedWireText(for: msg)))
            case .system:
                break
            }
        }
        flushUser()

        return ChatRequest(
            model: config.modelName,
            messages: out,
            stream: true,
            // Built when EITHER knob is set, not just temperature: mapping over one of them
            // silently discarded the other, so a benchmark run (which sets only the cap) would
            // have shipped `options` absent entirely.
            options: (config.temperature == nil && config.maxOutputTokens == nil)
                ? nil
                : ChatRequest.Options(
                    temperature: config.temperature, numPredict: config.maxOutputTokens),
            keepAlive: config.keepAliveSeconds
        )
    }

    // MARK: - Model Listing

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] {
        // Format and quantization ride `/api/tags` itself — `details.format` /
        // `details.quantization_level`, present for every model in the one response that yields the
        // names. They cost nothing extra here; the `/api/show` fan-out below is the capability
        // probe, which is a separate and older question.
        let infos = try await fetchTagEntries(config: config).map {
            LLMModelInfo(
                name: $0.name,
                format: $0.details?.format,
                quantization: $0.details?.quantizationLevel)
        }
        // Probed with the TRIMMED names, which are the same keys the filters look up below — the
        // map and its readers cannot disagree about a name with stray whitespace.
        let capabilities = await probeCapabilities(infos.map(\.name), config: config)

        if visionOnly {
            // Tags carry no capability metadata — the vision filter needs the
            // per-model `/api/show` probe. Models whose probe fails are
            // excluded (conservative: never offer a model we can't confirm
            // sees images).
            return infos.filter { capabilities[$0.name]??.contains("vision") == true }
                .normalizedUnique(name: \.name)
        }

        // Chat picker: exclude embedding-ONLY models (the LM Studio analogue
        // filters `type == "llm"`). Fail-open per model — a failed probe or a
        // capability-less old server never hides a chat model.
        return infos.filter { info in
            guard let caps = capabilities[info.name] ?? nil else { return true }
            return !(caps.contains("embedding") && !caps.contains("completion"))
        }.normalizedUnique(name: \.name)
    }

    func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] {
        let names = try await fetchTagEntries(config: config).map(\.name)
        let capabilities = await probeCapabilities(names, config: config)
        // Degraded path for older Ollama builds without `capabilities` in
        // `/api/show`: when NO probe produced a capability list, return the
        // full list — the user can still pick a known embedding model manually
        // (same degradation as the LM Studio OpenAI-shape fallback).
        let probedAny = capabilities.values.contains { $0 != nil }
        if !probedAny { return names.normalizedUnique() }
        return names.filter { capabilities[$0]??.contains("embedding") == true }
            .normalizedUnique()
    }

    /// Models resident on this server right now, from `GET /api/ps`.
    ///
    /// The protocol default returns `[]` because the app does not MANAGE Ollama residency —
    /// `LLMProvider.managesModelResidency` is false and nothing here loads or pins a model. That
    /// is still true; this override exists for a different job: the benchmark has to be able to
    /// SEE what else is resident, because a co-resident model competes for memory and bandwidth
    /// and poisons every timing. Observing residency is not managing it.
    ///
    /// `instanceID` is the model name — Ollama has no per-instance identity, and eviction is
    /// addressed by name.
    func listLoadedInstances(
        provider _: LLMProvider, baseURLString: String
    ) async throws -> LoadedInstanceListing {
        guard let baseURL = URL(string: baseURLString) else {
            throw LLMClientError.invalidBaseURL(baseURLString)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/ps"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.applyLMStudioBearer(baseURL: baseURLString, resolver: tokenResolver)

        let (data, response) = try await session.sessionData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMClientError.missingResponse
        }
        let decoded = try JSONCoderFactory.makeWireDecoder().decode(PSResponse.self, from: data)
        // Always `.listed`: `/api/ps` has been in Ollama since 0.1.x, and this
        // client throws rather than synthesizing an answer on any non-2xx — so
        // an empty list here really is an empty server.
        return .listed(decoded.models.compactMap { entry in
            guard let name = entry.name ?? entry.model, !name.isEmpty else { return nil }
            return LoadedModelInstance(modelName: name, instanceID: name)
        })
    }

    /// Evicts a model by asking for it with `keep_alive: 0` — Ollama's documented unload, and the
    /// only one it offers (there is no unload endpoint).
    ///
    /// An empty `messages` array is deliberate: it makes the request a pure residency instruction
    /// with no generation to pay for. Idempotent by nature — evicting a model that is already
    /// gone is a no-op on the server, which matches the protocol's contract.
    func unloadModel(
        provider _: LLMProvider, instanceID: String, baseURLString: String
    ) async throws {
        guard let baseURL = URL(string: baseURLString) else {
            throw LLMClientError.invalidBaseURL(baseURLString)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.applyLMStudioBearer(baseURL: baseURLString, resolver: tokenResolver)
        request.httpBody = try JSONCoderFactory.makeWireEncoder().encode(
            ChatRequest(model: instanceID, messages: [], stream: false, options: nil, keepAlive: 0))

        let (_, response) = try await session.sessionData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMClientError.missingResponse
        }
    }

    /// `GET /api/tags`, whole entries.
    ///
    /// Entries rather than names because one response carries three facts per model — the name,
    /// `details.format` and `details.quantization_level` — and the two that are not the name were
    /// decoded and dropped on the floor here for as long as this returned `[String]`.
    private func fetchTagEntries(config: LLMConfig) async throws -> [TagsResponse.ModelEntry] {
        guard let baseURL = URL(string: config.baseURLString) else {
            throw LLMClientError.invalidBaseURL(config.baseURLString)
        }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.applyLMStudioBearer(baseURL: config.baseURLString, resolver: tokenResolver)

        let (data, response) = try await session.sessionData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.missingResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMClientError.badHTTPStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        let decoded = try JSONCoderFactory.makeWireDecoder().decode(TagsResponse.self, from: data)
        return decoded.models
    }

    /// Probes `/api/show` for every model concurrently. The map's value is
    /// `nil` when the probe failed or the server carries no `capabilities`
    /// field (old build) — callers decide fail-open vs fail-closed per filter.
    private func probeCapabilities(
        _ names: [String],
        config: LLMConfig
    ) async -> [String: [String]?] {
        await withTaskGroup(of: (String, [String]?).self) { group in
            for name in names {
                group.addTask {
                    (name, await self.showMetadata(model: name, config: config)?.capabilities)
                }
            }
            var map: [String: [String]?] = [:]
            for await (name, capabilities) in group {
                map[name] = capabilities
            }
            return map
        }
    }

    // MARK: - Model Metadata

    /// Whether `config.modelName` can see images, per `/api/show`
    /// `capabilities`. `nil` = undeterminable (probe failed / field absent) —
    /// callers fail toward the "cannot see images" vision-fallback path.
    func modelSupportsVision(config: LLMConfig) async -> Bool? {
        guard let meta = await showMetadata(model: config.modelName, config: config),
              let capabilities = meta.capabilities
        else { return nil }
        return capabilities.contains("vision")
    }

    /// EFFECTIVE context window, preferring the LOADED instance's own figure.
    ///
    /// 1. `/api/ps` `context_length` — the window the runner actually loaded with.
    ///    It already accounts for `OLLAMA_CONTEXT_LENGTH`, a per-request `num_ctx`
    ///    and the runner's clamping, which is exactly what the overflow check needs.
    ///    Before this existed the net was structurally unarmable on a stock
    ///    `ollama pull`: such a model has no modelfile `num_ctx`, so the probe was
    ///    always `nil` and the warning could never fire.
    /// 2. Modelfile `num_ctx` from `/api/show` — the declared window when the model
    ///    is cold (nothing is resident to ask).
    /// 3. `nil` = undeterminable.
    ///
    /// The architecture max (`<arch>.context_length`) is deliberately NOT a fallback:
    /// Ollama does not load at the architecture max, and it silently TRUNCATES an
    /// oversized prompt with HTTP 200 — so overstating the window (131072 for a stock
    /// llama3.1) would compose a prompt whose head is dropped server-side with no
    /// error to trigger the self-correction. A failed probe still yields `nil`, never
    /// a guess: `ContextBudgetPolicy` must not manufacture a warning.
    func modelContextLength(config: LLMConfig) async -> Int? {
        if let loaded = await fetchRunningModels(config: config)?
            .first(where: { entry in
                [entry.model, entry.name].contains { $0.map { Self.sameModel($0, config.modelName) } == true }
            })?.contextLength, loaded > 0 {
            return loaded
        }
        return await showMetadata(model: config.modelName, config: config)?.modelfileNumCtx
    }

    /// Ollama reports a model as `name:tag`, and callers routinely configure the bare
    /// name. Compare on the bare name so `qwen3:8b` matches a configured `qwen3`,
    /// while still preferring an exact hit.
    private static func sameModel(_ reported: String, _ configured: String) -> Bool {
        if reported == configured { return true }
        func bare(_ s: String) -> Substring { s.split(separator: ":").first ?? s[...] }
        return bare(reported) == bare(configured)
    }

    private func showMetadata(
        model: String,
        config: LLMConfig
    ) async -> ShowMetadata? {
        guard let data = await showData(model: model, config: config) else { return nil }
        return Self.parseShowResponse(data)
    }

    /// Raw `/api/show` body for `model`, `nil` on any failure. Shared by the
    /// capability/context probes and the Model Details card.
    private func showData(model: String, config: LLMConfig) async -> Data? {
        guard let baseURL = URL(string: config.baseURLString),
              let body = try? JSONCoderFactory.makeWireEncoder().encode(ShowRequest(model: model))
        else { return nil }
        let url = baseURL.appendingPathComponent("api/show")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.applyLMStudioBearer(baseURL: config.baseURLString, resolver: tokenResolver)
        request.httpBody = body

        guard let (data, response) = try? await session.sessionData(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    // MARK: - Model Load Details

    /// Model Details card source: static metadata from `/api/show` (modelfile
    /// parameters, quantization, family, capabilities, context length) plus
    /// runtime state from `/api/ps` (loaded / VRAM / keep-alive expiry).
    /// `nil` when `/api/show` fails entirely; a failed `/api/ps` probe just
    /// omits the runtime rows rather than claiming "Not loaded".
    func modelLoadDetails(config: LLMConfig) async -> ModelLoadDetails? {
        guard let data = await showData(model: config.modelName, config: config) else { return nil }
        var fields: [ModelLoadDetails.Field] = []

        if let running = await fetchRunningModels(config: config) {
            if let entry = running.first(where: {
                $0.name == config.modelName || $0.model == config.modelName
            }) {
                fields.append(.init(label: "State", value: "Loaded"))
                if let vram = entry.sizeVram {
                    fields.append(.init(label: "VRAM", value: Self.formatBytes(vram)))
                }
                if let until = entry.expiresAt, !until.isEmpty {
                    fields.append(.init(label: "Keep-alive until", value: until))
                }
            } else {
                fields.append(.init(label: "State", value: "Not loaded"))
            }
        }

        fields.append(contentsOf: Self.parseShowLoadFields(data))
        return fields.isEmpty ? nil : ModelLoadDetails(fields: fields)
    }

    /// `nil` = probe failed (unknown state); `[]` = server answered, nothing
    /// resident. The distinction keeps a transport blip from rendering a
    /// loaded model as "Not loaded".
    private func fetchRunningModels(config: LLMConfig) async -> [PSResponse.Entry]? {
        guard let baseURL = URL(string: config.baseURLString) else { return nil }
        let url = baseURL.appendingPathComponent("api/ps")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.applyLMStudioBearer(baseURL: config.baseURLString, resolver: tokenResolver)

        guard let (data, response) = try? await session.sessionData(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONCoderFactory.makeWireDecoder().decode(PSResponse.self, from: data)
        else { return nil }
        return decoded.models
    }

    /// Static-metadata rows from an `/api/show` body. Pure + static for
    /// testability. Order: effective context → identity metadata →
    /// capabilities → raw modelfile parameters.
    static func parseShowLoadFields(_ data: Data) -> [ModelLoadDetails.Field] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var fields: [ModelLoadDetails.Field] = []

        let parsed = parseShowResponse(data)
        if let numCtx = parsed.modelfileNumCtx {
            fields.append(.init(label: "Context length (num_ctx)", value: String(numCtx)))
        }
        if let archMax = parsed.architectureContextLength {
            fields.append(.init(label: "Max context length", value: String(archMax)))
        }

        let details = obj["details"] as? [String: Any]
        if let size = details?["parameter_size"] as? String, !size.isEmpty {
            fields.append(.init(label: "Parameters", value: size))
        }
        if let quant = details?["quantization_level"] as? String, !quant.isEmpty {
            fields.append(.init(label: ModelLoadDetails.quantizationLabel, value: quant))
        }
        if let family = details?["family"] as? String, !family.isEmpty {
            fields.append(.init(label: "Family", value: family))
        }
        if let format = details?["format"] as? String, !format.isEmpty {
            fields.append(.init(label: ModelLoadDetails.formatLabel, value: format))
        }
        // The minimum Ollama version this model needs. Paired with the server's own
        // `/api/version` it explains a failure that would otherwise read as a bad model.
        if let requires = obj["requires"] as? String, !requires.isEmpty {
            fields.append(.init(label: "Requires Ollama", value: requires))
        }
        if let capabilities = parsed.capabilities, !capabilities.isEmpty {
            fields.append(.init(label: "Capabilities", value: capabilities.joined(separator: ", ")))
        }
        if let params = obj["parameters"] as? String {
            let trimmed = params.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                fields.append(.init(label: ModelLoadDetails.modelfileParametersLabel, value: trimmed))
            }
        }
        return fields
    }

    static func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// Parsed `/api/show` metadata. `modelfileNumCtx` is the EFFECTIVE window
    /// (the modelfile `num_ctx` parameter); `architectureContextLength` is the
    /// architecture MAXIMUM — display-only, never a runtime-window claim.
    nonisolated struct ShowMetadata: Equatable {
        var capabilities: [String]?
        var modelfileNumCtx: Int?
        var architectureContextLength: Int?
    }

    /// Pure parse of an `/api/show` response body — static for testability.
    ///
    /// `model_info` is a flat map of mixed-type keys
    /// (`"llama.context_length": 131072`, tokenizer arrays, strings…), so it
    /// goes through `JSONSerialization` rather than a Codable struct.
    /// `capabilities` is `["completion","tools","vision",…]` on newer builds;
    /// `nil` when absent (undeterminable, never a guess).
    static func parseShowResponse(_ data: Data) -> ShowMetadata {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ShowMetadata()
        }
        var meta = ShowMetadata()
        meta.capabilities = obj["capabilities"] as? [String]

        if let info = obj["model_info"] as? [String: Any] {
            // Sorted keys: deterministic pick if several `*.context_length`
            // keys ever coexist (nondeterministic dictionary order is a known
            // trap — see the TemplateResolver грабли).
            for key in info.keys.sorted() where key.hasSuffix(".context_length") {
                if let n = info[key] as? Int { meta.architectureContextLength = n; break }
                if let d = info[key] as? Double { meta.architectureContextLength = Int(d); break }
            }
        }
        if let params = obj["parameters"] as? String {
            for line in params.components(separatedBy: "\n") {
                let parts = line.split(separator: " ")
                if parts.count >= 2, parts[0] == "num_ctx", let n = Int(parts[1]) {
                    meta.modelfileNumCtx = n
                }
            }
        }
        return meta
    }
}
