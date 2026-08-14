import XCTest

@testable import NanoTeams

// MARK: - Shared doubles

/// Routes `sessionData` by URL path (so the `ChatModelEnsurer` probe/load round trip
/// and the chat POST can be scripted independently) and replays canned SSE bytes for
/// `sessionBytes`.
///
/// `URLSession.AsyncBytes` has no public initializer, so the chat half fabricates a real
/// byte stream through URLSession's built-in `data:` URL handler — the same trick
/// `OllamaStreamChatTests.NDJSONBytesSession` uses — and pairs it with a hand-built
/// `HTTPURLResponse`. That is what lets the whole `streamChat` body (SSE parse loop,
/// non-2xx arms, logging, terminal diagnostics) run for real instead of being mocked out.
private final class LMStudioRoutingSession: NetworkSession, @unchecked Sendable {

    /// `path -> (status, body)` for every `sessionData` route. An unrouted path answers
    /// HTTP 500, which makes `listLoadedInstances` throw and the ensure fail OPEN
    /// (`EnsureOutcome.skipped`) — the quiet default for tests that only care about chat.
    var dataRoutes: [String: (status: Int, body: String)] = [:]

    /// Raw payload replayed by `sessionBytes`. SSE frames on the happy path; plain text
    /// when the test drives a non-2xx error body.
    var chatPayload: String = ""
    var chatStatus: Int = 200
    var chatHeaders: [String: String]?
    /// Return a plain (non-HTTP) `URLResponse` so the client's `missingResponse` arm runs.
    var chatReturnsNonHTTPResponse = false
    /// Thrown from `sessionBytes` instead of returning — transport failure.
    var chatTransportError: Error?

    private(set) var dataPaths: [String] = []
    private(set) var chatRequests: [URLRequest] = []

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        dataPaths.append(path)
        let route = dataRoutes[path] ?? (status: 500, body: "{\"error\":\"unrouted\"}")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: route.status,
            httpVersion: nil, headerFields: nil)!
        return (Data(route.body.utf8), response)
    }

    func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        chatRequests.append(request)
        if let chatTransportError { throw chatTransportError }
        let dataURL = URL(string: "data:text/event-stream;base64,"
            + Data(chatPayload.utf8).base64EncodedString())!
        let (bytes, _) = try await URLSession.shared.bytes(from: dataURL)
        if chatReturnsNonHTTPResponse {
            let plain = URLResponse(
                url: request.url!, mimeType: "text/event-stream",
                expectedContentLength: -1, textEncodingName: nil)
            return (bytes, plain)
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: chatStatus,
            httpVersion: nil, headerFields: chatHeaders)!
        return (bytes, http)
    }
}

/// Replays a fixed `[StreamEvent]` list — the service-side harness, mirroring
/// `PerformStreamingCallLoopBreakTests.ScriptedClient`.
private final class ScriptedStreamClient: LLMClient, @unchecked Sendable {
    var events: [StreamEvent] = []
    /// Finish the stream by throwing `CancellationError` after every event, driving
    /// `performStreamingCall`'s `catch is CancellationError` partial-commit arm.
    var finishCancelled = false
    private(set) var streamChatCallCount = 0

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        streamChatCallCount += 1
        let scripted = events
        let cancel = finishCancelled
        return AsyncThrowingStream { continuation in
            for event in scripted { continuation.yield(event) }
            if cancel {
                continuation.finish(throwing: CancellationError())
            } else {
                continuation.finish()
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

// MARK: - NativeLMStudioClient.streamChat, end to end

/// The `streamChat` body was the one part of `NativeLMStudioClient` no test ever RAN:
/// the auth pin throws out of `sessionBytes` before a single byte is parsed, and the
/// remaining suites all target `buildRequest` or the `sessionData` endpoints. These
/// drive the real SSE loop, its error arms, the ensure-before-request ordering, the
/// terminal diagnostics, and the network log it writes.
final class NativeClientStreamChatTests: XCTestCase {

    private let baseURL = "http://127.0.0.1:1234"
    private let model = "test-model"

    private func makeConfig(
        baseURLString: String? = nil,
        requestTimeoutSeconds: Int? = nil
    ) -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: baseURLString ?? baseURL,
            modelName: model,
            requestTimeoutSeconds: requestTimeoutSeconds)
    }

    /// A FRESH ensurer every time. `NativeLMStudioClient`'s own default is the
    /// process-global `ChatModelEnsurer.shared`, whose ledger and request census would
    /// leak across tests — the outward-resolving seam CLAUDE.md #49 forbids. The
    /// parameter defaults to `nil` rather than to a constructing expression, because a
    /// default argument is evaluated at the CALL SITE.
    private func makeClient(
        _ session: LMStudioRoutingSession,
        ensurer: ChatModelEnsurer? = nil,
        tokens: [String: String] = [:]
    ) -> NativeLMStudioClient {
        NativeLMStudioClient(
            session: session,
            tokenResolver: StubLLMTokenResolver(tokens),
            modelEnsurer: ensurer ?? ChatModelEnsurer())
    }

    private struct Collected {
        var content = ""
        var thinking = ""
        var progress: [Double] = []
        var usage: TokenUsage?
        var prefill: ServerPrefillReport?
        var residency: ClientResidencyFacts?
        var error: Error?
    }

    private func drain(
        _ client: NativeLMStudioClient,
        config: LLMConfig,
        messages: [ChatMessage] = [ChatMessage(role: .user, content: "hi")],
        tools: [ToolSchema] = [],
        logger: NetworkLogger? = nil
    ) async -> Collected {
        let stream = client.streamChat(
            config: config, messages: messages, tools: tools,
            logger: logger, stepID: "engineer", roleName: "Software Engineer")
        var out = Collected()
        do {
            for try await event in stream {
                out.content += event.contentDelta
                out.thinking += event.thinkingDelta
                if let p = event.processingProgress { out.progress.append(p) }
                if let u = event.tokenUsage { out.usage = u }
                if let s = event.serverPrefill { out.prefill = s }
                if let r = event.clientResidency { out.residency = r }
            }
        } catch {
            out.error = error
        }
        return out
    }

    // MARK: - SSE happy path

    func testStream_contentThinkingProgressUsageAndPrefill() async {
        let session = LMStudioRoutingSession()
        session.chatPayload = """
        event: prompt_processing.start
        data: {}

        event: prompt_processing.progress
        data: {"progress":0.5}

        event: reasoning.delta
        data: {"content":"weighing options"}

        event: message.delta
        data: {"content":"Hello"}

        event: message.delta
        data: {"content":" world"}

        event: chat.end
        data: {"stats":{"input_tokens":120,"total_output_tokens":8,"model_load_time_seconds":0}}
        """

        let out = await drain(makeClient(session), config: makeConfig())

        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "Hello world")
        XCTAssertEqual(out.thinking, "weighing options")
        XCTAssertEqual(out.progress, [0.0, 0.5],
                       "prompt_processing.start maps to 0.0 and progress frames pass through")
        XCTAssertEqual(out.usage, TokenUsage(inputTokens: 120, outputTokens: 8))
        XCTAssertEqual(out.prefill?.modelLoadMs, 0,
                       "LM Studio reports exactly 0 when warm — recorded VERBATIM, never thresholded here")
        XCTAssertEqual(out.prefill?.promptTokens, 120)
    }

    /// `prompt_processing.end` maps to 1.0 — the terminal frame of the progress phase.
    func testStream_promptProcessingEnd_reportsFullProgress() async {
        let session = LMStudioRoutingSession()
        session.chatPayload = """
        event: prompt_processing.end
        data: {}

        event: message.delta
        data: {"content":"go"}
        """
        let out = await drain(makeClient(session), config: makeConfig())
        XCTAssertEqual(out.progress, [1.0])
        XCTAssertEqual(out.content, "go")
    }

    /// An SSE stream with no `chat.end` frame emits NO terminal diagnostics event — the
    /// client must not fabricate a zeroed `TokenUsage` for a truncated stream.
    func testStream_withoutChatEnd_emitsNoTerminalDiagnostics() async {
        let session = LMStudioRoutingSession()
        session.chatPayload = """
        event: message.delta
        data: {"content":"partial"}
        """
        let out = await drain(makeClient(session), config: makeConfig())
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "partial")
        XCTAssertNil(out.usage)
        XCTAssertNil(out.prefill)
    }

    func testStream_emptyBody200_finishesCleanWithNoEvents() async {
        let session = LMStudioRoutingSession()
        session.chatPayload = ""
        let out = await drain(makeClient(session), config: makeConfig())
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "")
        XCTAssertEqual(out.thinking, "")
        XCTAssertNil(out.usage)
    }

    /// Unhandled `event:` types and bare comment/blank lines must be skipped without
    /// disturbing the surrounding deltas.
    func testStream_unknownEventTypesAndBlankLines_ignored() async {
        let session = LMStudioRoutingSession()
        session.chatPayload = """
        event: chat.start
        data: {"id":"resp_1"}

        event: message.start
        data: {}

        event: message.delta
        data: {"content":"a"}

        : this is an SSE comment

        event: tool_call.start
        data: {"name":"mcp_thing"}

        event: message.delta
        data: {"content":"b"}
        """
        let out = await drain(makeClient(session), config: makeConfig())
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "ab")
    }

    // MARK: - Stream error arms

    func testStream_midStreamErrorEvent_throwsProviderError_afterEarlierContent() async {
        let session = LMStudioRoutingSession()
        session.chatPayload = """
        event: message.delta
        data: {"content":"partial"}

        event: error
        data: {"message":"model crashed"}
        """
        let out = await drain(makeClient(session), config: makeConfig())

        XCTAssertEqual(out.content, "partial", "content before the error still streams")
        guard case .providerError(let message)? = out.error as? LLMClientError else {
            return XCTFail("Expected providerError, got \(String(describing: out.error))")
        }
        XCTAssertEqual(message, "model crashed")
    }

    /// An `error` frame whose payload doesn't decode still terminates the stream — the
    /// parser's `.error("Stream error")` fallback must not degrade into `.ignored`.
    func testStream_undecodableErrorEvent_stillThrows() async {
        let session = LMStudioRoutingSession()
        session.chatPayload = """
        event: error
        data: not-json
        """
        let out = await drain(makeClient(session), config: makeConfig())
        guard case .providerError(let message)? = out.error as? LLMClientError else {
            return XCTFail("Expected providerError, got \(String(describing: out.error))")
        }
        XCTAssertFalse(message.isEmpty, "the fallback must still name the failure to the user")
    }

    func testStream_http429WithRetryAfter_throwsRateLimited_withoutReadingBody() async {
        let session = LMStudioRoutingSession()
        session.chatStatus = 429
        session.chatHeaders = ["Retry-After": "30"]
        session.chatPayload = "{\"error\":\"slow down\"}"

        let out = await drain(makeClient(session), config: makeConfig())
        guard case .rateLimited(let retryAfter)? = out.error as? LLMClientError else {
            return XCTFail("Expected rateLimited, got \(String(describing: out.error))")
        }
        XCTAssertEqual(retryAfter, 30)
    }

    func testStream_http429WithoutRetryAfter_hasNilHint() async {
        let session = LMStudioRoutingSession()
        session.chatStatus = 429
        let out = await drain(makeClient(session), config: makeConfig())
        guard case .rateLimited(let retryAfter)? = out.error as? LLMClientError else {
            return XCTFail("Expected rateLimited, got \(String(describing: out.error))")
        }
        XCTAssertNil(retryAfter)
    }

    func testStream_http500_throwsBadHTTPStatus_carryingTheServerBody() async {
        let session = LMStudioRoutingSession()
        session.chatStatus = 500
        session.chatPayload = "{\"error\":\"no model loaded\"}"

        let out = await drain(makeClient(session), config: makeConfig())
        guard case .badHTTPStatus(let code, let body)? = out.error as? LLMClientError else {
            return XCTFail("Expected badHTTPStatus, got \(String(describing: out.error))")
        }
        XCTAssertEqual(code, 500)
        XCTAssertEqual(body, "{\"error\":\"no model loaded\"}",
                       "the actionable server body must survive into the error")
    }

    /// The error-body reader stops once it has ~500 characters. A server that dumps a
    /// multi-megabyte stack trace must not be accumulated whole into an error string
    /// that then rides `lastErrorMessage`.
    func testStream_hugeErrorBody_isCappedNotAccumulatedWhole() async {
        let sentinel = "TAIL-SENTINEL-MUST-NOT-APPEAR"
        let padded = (0..<40).map { "error line \($0) padding padding padding" }
        let session = LMStudioRoutingSession()
        session.chatStatus = 500
        session.chatPayload = (padded + [sentinel]).joined(separator: "\n")

        let out = await drain(makeClient(session), config: makeConfig())
        guard case .badHTTPStatus(_, let rawBody)? = out.error as? LLMClientError,
              let body = rawBody else {
            return XCTFail("Expected badHTTPStatus with a body, got \(String(describing: out.error))")
        }
        XCTAssertGreaterThan(body.count, 500, "the cap is a stop condition, not a hard truncation")
        XCTAssertLessThan(body.count, 900, "…but the whole payload must NOT be accumulated")
        XCTAssertFalse(body.contains(sentinel), "reading stopped well before the end of the body")
    }

    /// Empty error body → `nil`, not `""`. `LLMClientError.badHTTPStatus`'s description
    /// branches on that optional, and an empty string would print a dangling colon.
    func testStream_nonHTTPErrorWithEmptyBody_reportsNilBody() async {
        let session = LMStudioRoutingSession()
        session.chatStatus = 503
        session.chatPayload = ""
        let out = await drain(makeClient(session), config: makeConfig())
        guard case .badHTTPStatus(let code, let body)? = out.error as? LLMClientError else {
            return XCTFail("Expected badHTTPStatus, got \(String(describing: out.error))")
        }
        XCTAssertEqual(code, 503)
        XCTAssertNil(body)
    }

    func testStream_nonHTTPResponse_throwsMissingResponse() async {
        let session = LMStudioRoutingSession()
        session.chatReturnsNonHTTPResponse = true
        let out = await drain(makeClient(session), config: makeConfig())
        XCTAssertEqual(out.error as? LLMClientError, .missingResponse)
    }

    func testStream_transportFailure_propagatesTheUnderlyingError() async {
        let session = LMStudioRoutingSession()
        session.chatTransportError = URLError(.cannotConnectToHost)
        let out = await drain(makeClient(session), config: makeConfig())
        XCTAssertEqual((out.error as? URLError)?.code, URLError.Code.cannotConnectToHost)
    }

    /// An unusable base URL fails BEFORE anything touches the network — no model probe,
    /// no load, no chat request. Pins that the guard sits ahead of the ensure.
    func testStream_invalidBaseURL_throws_andIssuesNoNetworkCallAtAll() async {
        let session = LMStudioRoutingSession()
        let out = await drain(
            makeClient(session), config: makeConfig(baseURLString: "not a valid url ://bad"))

        guard case .invalidBaseURL(let raw)? = out.error as? LLMClientError else {
            return XCTFail("Expected invalidBaseURL, got \(String(describing: out.error))")
        }
        XCTAssertEqual(raw, "not a valid url ://bad")
        XCTAssertTrue(session.dataPaths.isEmpty, "the ensure probe must not run")
        XCTAssertTrue(session.chatRequests.isEmpty, "no chat request may be built")
    }

    // MARK: - Model ensure ordering and residency facts

    /// `EnsureOutcome.loaded` is the ONLY reload evidence available on LM Studio (the
    /// server reports 0 ms when warm), so the client must publish it as a
    /// `ClientResidencyFacts` event before any network work for the chat itself.
    func testStream_appLoadedTheModel_emitsClientResidencyFacts() async {
        let session = LMStudioRoutingSession()
        session.dataRoutes["/api/v0/models"] = (200, "{\"data\":[]}")
        session.dataRoutes["/api/v1/models/load"] = (200, "{\"instance_id\":\"inst-1\"}")
        session.chatPayload = """
        event: message.delta
        data: {"content":"ok"}
        """

        let out = await drain(makeClient(session), config: makeConfig())

        XCTAssertNil(out.error)
        XCTAssertEqual(out.residency?.appLoadedModelForThisRequest, true)
        XCTAssertNotNil(out.residency?.appModelLoadMs,
                        "the app-measured load duration rides the same facts")
        XCTAssertTrue(session.dataPaths.contains("/api/v1/models/load"))
    }

    /// An already-resident instance is `.adopted` — the cache came with it, so nothing
    /// is reported and no redundant load is issued.
    func testStream_adoptedResidentInstance_reportsNoResidencyAndNeverLoads() async {
        let session = LMStudioRoutingSession()
        session.dataRoutes["/api/v0/models"] =
            (200, "{\"data\":[{\"id\":\"test-model\",\"state\":\"loaded\"}]}")
        session.chatPayload = """
        event: message.delta
        data: {"content":"ok"}
        """

        let out = await drain(makeClient(session), config: makeConfig())

        XCTAssertNil(out.error)
        XCTAssertNil(out.residency, "absence is never evidence — adoption says nothing about the cache")
        XCTAssertFalse(session.dataPaths.contains("/api/v1/models/load"),
                       "a redundant load would create a duplicate `name:2` instance")
    }

    /// Listing failure is fail-open: the ensure skips and the chat request still goes out,
    /// so the canonical connection error comes from the chat call itself.
    func testStream_instanceListingFails_ensureSkips_butTheChatStillRuns() async {
        let session = LMStudioRoutingSession()  // unrouted /api/v0/models → HTTP 500
        session.chatPayload = """
        event: message.delta
        data: {"content":"still answered"}
        """

        let out = await drain(makeClient(session), config: makeConfig())

        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "still answered")
        XCTAssertNil(out.residency)
        XCTAssertEqual(session.chatRequests.count, 1)
    }

    /// The explicit load is a PRECONDITION of the request: when it fails, the stream fails
    /// and no chat request is issued. Otherwise LM Studio would JIT-load the model, and a
    /// JIT instance is Auto-Evicted by the next one.
    func testStream_modelLoadFails_streamThrows_andNoChatRequestIsIssued() async {
        let session = LMStudioRoutingSession()
        session.dataRoutes["/api/v0/models"] = (200, "{\"data\":[]}")
        session.dataRoutes["/api/v1/models/load"] = (500, "{\"error\":\"model_load_failed\"}")

        let out = await drain(makeClient(session), config: makeConfig())

        guard case .badHTTPStatus(let code, _)? = out.error as? LLMClientError else {
            return XCTFail("Expected badHTTPStatus from the load, got \(String(describing: out.error))")
        }
        XCTAssertEqual(code, 500)
        XCTAssertTrue(session.chatRequests.isEmpty,
                      "the request must not be issued against a model that failed to load")
    }

    /// The request census guards residency reconciliation against unloading a model that
    /// is mid-stream. `endRequest` lands from an unstructured Task in a `defer`, so the
    /// post-condition is polled rather than read once.
    func testStream_requestCensus_isBalancedAfterTheStreamCompletes() async {
        let session = LMStudioRoutingSession()
        session.chatPayload = """
        event: message.delta
        data: {"content":"ok"}
        """
        let ensurer = ChatModelEnsurer()
        let out = await drain(makeClient(session, ensurer: ensurer), config: makeConfig())
        XCTAssertNil(out.error)

        var stillOpen = true
        for _ in 0..<200 {
            stillOpen = await ensurer.hasOpenRequest(modelName: model, baseURLString: baseURL)
            if !stillOpen { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(stillOpen,
                       "an unbalanced census would pin the model resident forever")
    }

    /// …and it is balanced on the FAILURE path too — the `defer` runs from the catch arm.
    func testStream_requestCensus_isBalancedAfterAFailedStream() async {
        let session = LMStudioRoutingSession()
        session.chatStatus = 500
        let ensurer = ChatModelEnsurer()
        _ = await drain(makeClient(session, ensurer: ensurer), config: makeConfig())

        var stillOpen = true
        for _ in 0..<200 {
            stillOpen = await ensurer.hasOpenRequest(modelName: model, baseURLString: baseURL)
            if !stillOpen { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(stillOpen)
    }

    // MARK: - Outgoing wire invariants (measured on the real request, not buildRequest)

    /// `buildRequest` is pinned elsewhere; this pins what actually reaches `URLRequest`:
    /// `system_prompt` on every call, `store:false`, no `developer` role, no sampling keys,
    /// and the assistant turn's Harmony envelope re-materialised (the history-loss bug).
    func testStream_outgoingBody_carriesTheStatelessWireInvariants() async throws {
        let session = LMStudioRoutingSession()
        session.chatPayload = ""
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are an engineer."),
            ChatMessage(role: .user, content: "read A"),
            ChatMessage(
                role: .assistant, content: nil,
                toolCalls: [ChatToolCall(
                    id: "tc-1", name: "read_file", argumentsJSON: "{\"path\":\"A.swift\"}")]),
            ChatMessage(role: .tool, content: "{\"ok\":true}", toolCallID: "tc-1"),
        ]

        _ = await drain(makeClient(session), config: makeConfig(), messages: messages)

        let request = try XCTUnwrap(session.chatRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/chat")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(String(data: bodyData, encoding: .utf8))
        XCTAssertTrue(body.contains("\"system_prompt\""),
                      "nothing holds the system prompt server-side — it ships every call")
        XCTAssertTrue(body.contains("You are an engineer."))
        XCTAssertTrue(body.contains("\"store\":false"),
                      "no chain ever resumes a stored response")
        XCTAssertTrue(body.contains("\"stream\":true"))
        XCTAssertFalse(body.contains("developer"),
                       "LM Studio treats the `developer` role specially — it must never appear")
        XCTAssertFalse(body.contains("previous_response_id"))
        XCTAssertTrue(
            body.contains("read_file"),
            "the assistant turn's tool call must be re-materialised onto the wire; without it "
                + "the model sees a bare [Assistant] ahead of a tool result it never asked for")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        for key in ["temperature", "max_output_tokens", "top_k", "top_p", "min_p",
                    "repeat_penalty", "seed"] {
            XCTAssertNil(json[key], "a default-config request must carry no sampling key '\(key)'")
        }
    }

    /// `requestTimeoutSeconds == 0` means "wait indefinitely" — reasoning models can spend
    /// minutes before the first token, and URLRequest's 60 s default would kill them.
    func testStream_zeroTimeoutConfig_disablesTheRequestTimeout() async throws {
        let session = LMStudioRoutingSession()
        _ = await drain(makeClient(session), config: makeConfig(requestTimeoutSeconds: 0))
        let request = try XCTUnwrap(session.chatRequests.first)
        XCTAssertEqual(request.timeoutInterval, TimeInterval(Int32.max), accuracy: 1)
    }

    func testStream_positiveTimeoutConfig_isPassedThrough() async throws {
        let session = LMStudioRoutingSession()
        _ = await drain(makeClient(session), config: makeConfig(requestTimeoutSeconds: 42))
        let request = try XCTUnwrap(session.chatRequests.first)
        XCTAssertEqual(request.timeoutInterval, 42, accuracy: 0.001)
    }

    func testStream_bearerToken_ridesTheChatRequest() async throws {
        let session = LMStudioRoutingSession()
        _ = await drain(
            makeClient(session, tokens: [baseURL: "chat-secret"]), config: makeConfig())
        let request = try XCTUnwrap(session.chatRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer chat-secret")
    }

    // MARK: - Network logging

    private func readLog(_ url: URL) throws -> [NetworkLogRecord] {
        let data = try Data(contentsOf: url)
        return try JSONCoderFactory.makeDateDecoder().decode([NetworkLogRecord].self, from: data)
    }

    func testStream_networkLogger_writesPairedRequestAndResponseRecords() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.json")

        let session = LMStudioRoutingSession()
        session.dataRoutes["/api/v0/models"] = (200, "{\"data\":[]}")
        session.dataRoutes["/api/v1/models/load"] = (200, "{\"instance_id\":\"inst-1\"}")
        session.chatPayload = """
        event: reasoning.delta
        data: {"content":"deliberating"}

        event: message.delta
        data: {"content":"final answer"}

        event: chat.end
        data: {"stats":{"input_tokens":11,"total_output_tokens":4,"model_load_time_seconds":0}}
        """

        let out = await drain(
            makeClient(session), config: makeConfig(), logger: NetworkLogger(logURL: logURL))
        XCTAssertNil(out.error)

        let records = try readLog(logURL)
        XCTAssertEqual(records.count, 2, "one request record, one response record")

        let request = try XCTUnwrap(records.first { $0.direction == .request })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url.hasSuffix("/api/v1/chat"))
        XCTAssertEqual(request.stepID, "engineer")
        XCTAssertEqual(request.roleName, "Software Engineer")

        let response = try XCTUnwrap(records.first { $0.direction == .response })
        XCTAssertEqual(response.correlationID, request.correlationID,
                       "the pair is correlated so the log can be replayed as turns")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.inputTokens, 11)
        XCTAssertEqual(response.outputTokens, 4)
        XCTAssertEqual(response.modelLoadMs, 0,
                       "the SERVER figure is recorded verbatim — it is the calibration source")
        XCTAssertNotNil(response.appModelLoadMs,
                        "…and the APP-measured load stays in its own field so the two provenances "
                            + "remain distinguishable in a real log")
        let body = try XCTUnwrap(response.body)
        XCTAssertTrue(body.contains("[reasoning]\ndeliberating\n[/reasoning]"))
        XCTAssertTrue(body.hasSuffix("final answer"))
    }

    /// Content-only turn: no `[reasoning]` wrapper is fabricated.
    func testStream_networkLogger_contentOnlyResponse_hasNoReasoningWrapper() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.json")

        let session = LMStudioRoutingSession()
        session.chatPayload = """
        event: message.delta
        data: {"content":"just prose"}
        """
        _ = await drain(
            makeClient(session), config: makeConfig(), logger: NetworkLogger(logURL: logURL))

        let records = try readLog(logURL)
        let response = try XCTUnwrap(records.first { $0.direction == .response })
        XCTAssertEqual(response.body, "just prose")
        XCTAssertNil(response.inputTokens, "no chat.end frame ⇒ no fabricated token counts")
    }

    /// The failure arm logs a record with `statusCode: 0` and the error text, so a run that
    /// died on the wire is still reconstructible from `network_log.json`.
    func testStream_networkLogger_failedRequest_recordsStatusZeroAndTheError() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.json")

        let session = LMStudioRoutingSession()
        session.chatStatus = 500
        session.chatPayload = "{\"error\":\"boom\"}"
        _ = await drain(
            makeClient(session), config: makeConfig(), logger: NetworkLogger(logURL: logURL))

        let records = try readLog(logURL)
        XCTAssertEqual(records.count, 2)
        let response = try XCTUnwrap(records.first { $0.direction == .response })
        XCTAssertEqual(response.statusCode, 0, "0 marks a record that never got an HTTP answer")
        XCTAssertNotNil(response.errorMessage)
        XCTAssertNil(response.body)
    }

    /// Nothing is logged when the base URL never resolves — there is no request to pair.
    func testStream_networkLogger_invalidBaseURL_writesNothing() async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.json")

        let session = LMStudioRoutingSession()
        _ = await drain(
            makeClient(session), config: makeConfig(baseURLString: "not a valid url ://bad"),
            logger: NetworkLogger(logURL: logURL))

        XCTAssertFalse(fm.fileExists(atPath: logURL.path))
    }
}

// MARK: - LLMExecutionService+Streaming: post-stream arms

/// The service half of the pair. `performStreamingCall`'s in-loop branches (the Harmony
/// rewind, the envelope-as-thinking pipe, both duplicate-tool-call breaks) and
/// `processStreamingResult` — the function that decides what the NEXT request will carry.
@MainActor
final class StreamingPostStreamArmsTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var client: ScriptedStreamClient!
    private let stepID = "engineer"
    private let taskID = 7

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        client = ScriptedStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    override func tearDown() {
        service = nil
        delegate = nil
        client = nil
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    private func run(
        _ events: [StreamEvent],
        tools: [ToolSchema] = []
    ) async throws -> LLMExecutionService.StreamingResult {
        client.events = events
        return try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: client, config: LLMConfig(),
            tools: tools, conversationMessages: [], networkLogger: nil)
    }

    private func envelope(_ name: String, _ args: String) -> String {
        "<|call|>{\"name\":\"\(name)\",\"arguments\":\(args)}<|end|>"
    }

    /// A task with one running step, so `appendToolCalls` has somewhere to land.
    private func installTask() {
        let step = StepExecution(
            id: stepID, role: .softwareEngineer, title: "Step", status: .running)
        delegate.taskToMutate = NTMSTask(
            id: taskID, title: "T", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
    }

    // MARK: - Degenerate entry

    /// No delegate ⇒ nothing to stream into. The early return must not touch the client.
    func testNoDelegate_returnsEmptyResult_andNeverStreams() async throws {
        let orphan = LLMExecutionService(repository: NTMSRepository())
        client.events = [StreamEvent(contentDelta: "should never be requested")]

        let result = try await orphan.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: client, config: LLMConfig(),
            tools: [], conversationMessages: [], networkLogger: nil)

        XCTAssertEqual(result.assistantContent, "")
        XCTAssertEqual(result.thinkingContent, "")
        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
        XCTAssertFalse(result.sawHarmonyMarker)
        XCTAssertNil(result.thinkingLoopSignal)
        XCTAssertEqual(client.streamChatCallCount, 0,
                       "with nowhere to stream into, the request must not be issued at all")
    }

    /// An entirely empty stream still commits (an empty turn is a turn) and resolves nothing.
    func testEmptyStream_commitsEmptyTurn_withNilThinking() async throws {
        let result = try await run([])
        XCTAssertEqual(delegate.commitStreamingCalls.count, 1)
        XCTAssertEqual(delegate.commitStreamingCalls[0].2, "")
        XCTAssertNil(delegate.commitStreamingCalls[0].3)
        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
    }

    /// Reasoning that is only whitespace must not persist a thinking disclosure that
    /// expands to nothing.
    func testWhitespaceOnlyThinking_isCommittedAsNil() async throws {
        _ = try await run([StreamEvent(thinkingDelta: "\n\n   \n")])
        XCTAssertEqual(delegate.commitStreamingCalls.count, 1)
        XCTAssertNil(delegate.commitStreamingCalls[0].3,
                     "an empty [reasoning] block must not become an expandable-but-blank section")
    }

    // MARK: - Harmony marker rewind

    /// The marker arrives split across three deltas — `uiBuffer` is the complete record of
    /// all deltas precisely so a marker straddling a flush boundary is still found, and the
    /// preview rewinds to the prose that preceded it.
    func testHarmonyMarkerSplitAcrossDeltas_rewindsPreviewToPreMarkerProse() async throws {
        let result = try await run([
            StreamEvent(contentDelta: "Reading now "),
            StreamEvent(contentDelta: "<|"),
            StreamEvent(contentDelta: "call|>{\"name\":\"git_status\",\"arguments\":{}}<|end|>"),
        ])

        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertEqual(result.assistantContent, "Reading now ")
        XCTAssertEqual(result.resolvedToolCalls.map(\.name), [ToolNames.gitStatus])

        XCTAssertEqual(delegate.replaceStreamingPreviewCalls.count, 1)
        XCTAssertEqual(delegate.replaceStreamingPreviewCalls[0].3, "Reading now ")
        XCTAssertEqual(delegate.markStreamingToolCallCalls, [stepID],
                       "the stream committed to an envelope — the Thinking loader takes over")

        let thinking = delegate.appendStreamingThinkingCalls.map(\.1).joined()
        XCTAssertTrue(
            thinking.contains("<|call|>"),
            "the slice the rewind removed from the content preview must re-surface as thinking, "
                + "so no streamed text ever just vanishes from screen")
        XCTAssertTrue(result.thinkingContent.isEmpty,
                      "the envelope pipe is preview-only — it must never enter thinkingCollected")
    }

    /// Truncation happens at the EARLIEST of the three markers, not the first one matched.
    func testHarmonyRewind_truncatesAtTheEarliestMarker() async throws {
        let result = try await run([
            StreamEvent(contentDelta: "A<|channel|>commentary<|call|>{\"name\":\"git_status\",\"arguments\":{}}<|end|>")
        ])
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertEqual(result.assistantContent, "A",
                       "`<|channel|>` precedes `<|call|>` here — the cut is at the earlier one")
        XCTAssertEqual(delegate.replaceStreamingPreviewCalls[0].3, "A")
    }

    /// Marker at position 0: no prose at all, and the preview rewinds to empty rather than
    /// leaving a partial `<` / `<|` on screen.
    func testHarmonyRewind_markerAtStart_leavesNoAssistantContent() async throws {
        let result = try await run([
            StreamEvent(contentDelta: envelope("read_file", "{\"path\":\"a.txt\"}"))
        ])
        XCTAssertEqual(result.assistantContent, "")
        XCTAssertEqual(delegate.replaceStreamingPreviewCalls[0].3, "")
        XCTAssertEqual(result.resolvedToolCalls.map(\.name), [ToolNames.readFile])
        XCTAssertEqual(result.harmonyBuffer, envelope("read_file", "{\"path\":\"a.txt\"}"))
    }

    /// Once the marker is seen, later content deltas go to `harmonyBuffer` and surface as
    /// live THINKING — never into the visible content preview.
    func testPostMarkerDeltas_streamAsThinking_notAsContentPreview() async throws {
        let previewCallsBefore = delegate.appendStreamingPreviewCalls.count
        let result = try await run([
            StreamEvent(contentDelta: "<|call|>{\"name\":\"git_status\","),
            StreamEvent(contentDelta: "\"arguments\":{}}"),
            StreamEvent(contentDelta: "<|end|>"),
        ])

        XCTAssertEqual(result.assistantContent, "")
        XCTAssertEqual(
            delegate.appendStreamingPreviewCalls.count, previewCallsBefore,
            "visible prose freezes at the marker — nothing after it may reach the content preview")
        let thinking = delegate.appendStreamingThinkingCalls.map(\.1).joined()
        XCTAssertTrue(thinking.contains("\"arguments\":{}}"))
        XCTAssertEqual(result.resolvedToolCalls.map(\.name), [ToolNames.gitStatus])
    }

    // MARK: - Duplicate-tool-call break (Harmony channel)

    /// Byte-identical envelopes: the close-marker count reaches 2, the re-parse finds
    /// duplicates, the stream breaks, and only the FIRST instance survives dedup.
    func testDuplicateHarmonyEnvelopes_breakTheStream_andCollapseToOneCall() async throws {
        let dup = envelope("read_file", "{\"path\":\"a.txt\"}")
        let result = try await run([
            StreamEvent(contentDelta: dup),   // detection — seeds the count at 1
            StreamEvent(contentDelta: dup),   // count 2 → re-parse → duplicate → break
            StreamEvent(contentDelta: dup),
            StreamEvent(contentDelta: "MUST-NOT-BE-CONSUMED"),
        ])

        XCTAssertEqual(result.resolvedToolCalls.count, 1,
                       "later occurrences of a duplicated signature are dropped")
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.readFile)
        XCTAssertFalse(result.harmonyBuffer.contains("MUST-NOT-BE-CONSUMED"),
                       "the break must stop the loop before the next event is processed")
        XCTAssertEqual(delegate.commitStreamingCalls.count, 1,
                       "a duplicate break still commits what streamed — only a THINKING-loop discards")
        XCTAssertTrue(delegate.discardStreamingCalls.isEmpty)
    }

    /// Regression: the SAME two envelopes, framed as two deltas.
    ///
    /// The count used to be incremented only inside the `sawHarmonyMarker` branch, so the
    /// delta that first carried a marker never counted its own — with two envelopes
    /// buffered the counter read 1, the `>= 2` gate never fired, and because the post-loop
    /// dedup is gated on `loopDetected`, BOTH identical calls were dispatched. Which
    /// framing a provider chooses is not something this app controls.
    func testTwoDuplicateEnvelopes_asTwoDeltas_stillBreakAndCollapse() async throws {
        let dup = envelope("read_file", "{\"path\":\"a.txt\"}")
        let result = try await run([
            StreamEvent(contentDelta: dup),
            StreamEvent(contentDelta: dup),
            StreamEvent(contentDelta: "MUST-NOT-BE-CONSUMED"),
        ])

        XCTAssertEqual(result.resolvedToolCalls.count, 1,
                       "two identical calls must collapse to one: \(result.resolvedToolCalls.map(\.name))")
        XCTAssertFalse(result.harmonyBuffer.contains("MUST-NOT-BE-CONSUMED"),
                       "the break must stop the loop")
    }

    /// The other framing of the same two envelopes: ONE coalesced delta. This never
    /// reached the check at all — the duplicate test lived in the branch the detection
    /// delta does not take.
    func testTwoDuplicateEnvelopes_inOneCoalescedDelta_stillBreakAndCollapse() async throws {
        let dup = envelope("read_file", "{\"path\":\"a.txt\"}")
        let result = try await run([
            StreamEvent(contentDelta: dup + dup),
            StreamEvent(contentDelta: "MUST-NOT-BE-CONSUMED"),
        ])

        XCTAssertEqual(result.resolvedToolCalls.count, 1,
                       "two identical calls in one chunk must collapse: \(result.resolvedToolCalls.map(\.name))")
        XCTAssertFalse(result.harmonyBuffer.contains("MUST-NOT-BE-CONSUMED"),
                       "the break must stop the loop")
    }

    /// A SINGLE envelope carrying both terminators must not be counted twice — otherwise
    /// every ordinary tool call pays a re-parse it cannot possibly need.
    func testCloseMarkerCount_singleEnvelopeWithBothTerminators_countsOnce() {
        let one = envelope("read_file", "{\"path\":\"a.txt\"}")
        XCTAssertEqual(LLMExecutionService.closeMarkerCount(in: one), 1,
                       "one envelope is one call, however many terminators it spells")
        XCTAssertEqual(LLMExecutionService.closeMarkerCount(in: one + one), 2)
        XCTAssertEqual(LLMExecutionService.closeMarkerCount(in: "no markers here"), 0)
    }

    /// The control case that makes the previous tests meaningful: three DISTINCT calls also
    /// trip the counter and the re-parse, but must not be broken or deduplicated.
    func testDistinctHarmonyEnvelopes_areAllDispatched() async throws {
        let result = try await run([
            StreamEvent(contentDelta: envelope("read_file", "{\"path\":\"a.txt\"}")),
            StreamEvent(contentDelta: envelope("read_file", "{\"path\":\"b.txt\"}")),
            StreamEvent(contentDelta: envelope("git_status", "{}")),
        ])

        XCTAssertEqual(result.resolvedToolCalls.count, 3,
                       "a batch of different calls is legitimate work, not a loop")
        XCTAssertEqual(
            result.resolvedToolCalls.map(\.name),
            [ToolNames.readFile, ToolNames.readFile, ToolNames.gitStatus])
    }

    // MARK: - Duplicate-tool-call break (provider-native deltas)

    func testDuplicateProviderToolCallDeltas_breakTheStream_andCollapseToOneCall() async throws {
        let result = try await run([
            StreamEvent(toolCallDeltas: [
                StreamEvent.ToolCallDelta(
                    index: 0, id: "c0", name: ToolNames.gitStatus, argumentsDelta: "{}"),
                StreamEvent.ToolCallDelta(
                    index: 1, id: "c1", name: ToolNames.gitStatus, argumentsDelta: "{}"),
            ]),
            StreamEvent(contentDelta: "MUST-NOT-BE-CONSUMED"),
        ])

        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.gitStatus)
        XCTAssertFalse(result.assistantContent.contains("MUST-NOT-BE-CONSUMED"),
                       "the break must stop the loop before the next event is processed")
    }

    /// Key order and whitespace differences are the same call — the canonical signature is
    /// what the break keys on, not the raw bytes.
    func testProviderToolCallDeltas_duplicateOnlyAfterCanonicalisation_stillBreaks() async throws {
        let result = try await run([
            StreamEvent(toolCallDeltas: [
                StreamEvent.ToolCallDelta(
                    index: 0, id: "c0", name: ToolNames.writeFile,
                    argumentsDelta: "{\"path\":\"a\",\"content\":\"x\"}"),
                StreamEvent.ToolCallDelta(
                    index: 1, id: "c1", name: ToolNames.writeFile,
                    argumentsDelta: "{\"content\":\"x\", \"path\":\"a\"}"),
            ])
        ])
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
    }

    /// Provider-native deltas never materialise in the content preview, so the fragments are
    /// surfaced as thinking and the tool-call flag is raised — otherwise the bubble freezes.
    func testProviderToolCallDeltas_surfaceAsThinking_andFlagToolCallStreaming() async throws {
        let result = try await run([
            StreamEvent(toolCallDeltas: [
                StreamEvent.ToolCallDelta(
                    index: 0, id: "c0", name: ToolNames.readFile,
                    argumentsDelta: "{\"path\":\"a.txt\"}")
            ])
        ])

        XCTAssertEqual(result.resolvedToolCalls.map(\.name), [ToolNames.readFile])
        XCTAssertEqual(result.resolvedToolCalls.first?.providerID, "c0",
                       "the provider id must survive so the tool message can name its call")
        XCTAssertEqual(delegate.markStreamingToolCallCalls, [stepID])
        XCTAssertEqual(delegate.markStreamActivityCalls, [stepID])
        XCTAssertTrue(delegate.clearProcessingProgressCalls.contains(stepID))
        let thinking = delegate.appendStreamingThinkingCalls.map(\.1).joined()
        XCTAssertEqual(thinking, ToolNames.readFile + "{\"path\":\"a.txt\"}")
    }

    /// A delta carrying neither a name nor arguments contributes no thinking fragment —
    /// and `finalize()` drops the nameless partial rather than dispatching an empty call.
    func testProviderToolCallDelta_withNoNameOrArguments_resolvesNothing() async throws {
        let result = try await run([
            StreamEvent(toolCallDeltas: [
                StreamEvent.ToolCallDelta(index: 0, id: "c0", name: nil, argumentsDelta: nil)
            ])
        ])
        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
        XCTAssertTrue(delegate.appendStreamingThinkingCalls.isEmpty,
                      "an empty fragment must not push a blank thinking append")
        XCTAssertEqual(delegate.markStreamingToolCallCalls, [stepID],
                       "the turn still committed to a tool call — the loader must animate")
    }

    // MARK: - Terminal diagnostics

    func testTerminalDiagnostics_areCarriedOntoTheResult() async throws {
        let result = try await run([
            StreamEvent(contentDelta: "hi"),
            StreamEvent(
                tokenUsage: TokenUsage(inputTokens: 7, outputTokens: 3),
                serverPrefill: ServerPrefillReport(modelLoadMs: 12, promptTokens: 7),
                clientResidency: ClientResidencyFacts(
                    appLoadedModelForThisRequest: true, appModelLoadMs: 4300)),
        ])

        XCTAssertEqual(result.tokenUsage, TokenUsage(inputTokens: 7, outputTokens: 3))
        XCTAssertEqual(result.serverPrefill?.modelLoadMs, 12)
        XCTAssertEqual(result.clientResidency?.appLoadedModelForThisRequest, true)
        XCTAssertEqual(result.clientResidency?.appModelLoadMs, 4300)
    }

    /// Two diagnostics frames in one stream: the LAST wins, so a provider that emits an
    /// interim report can't pin a stale figure.
    func testTerminalDiagnostics_lastFrameWins() async throws {
        let result = try await run([
            StreamEvent(tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            StreamEvent(tokenUsage: TokenUsage(inputTokens: 99, outputTokens: 42)),
        ])
        XCTAssertEqual(result.tokenUsage, TokenUsage(inputTokens: 99, outputTokens: 42))
    }

    /// Cancellation still commits the partial turn — and does NOT resolve tool calls, since
    /// the cancellation arm throws before route 1..4 ever run.
    func testCancellation_commitsPartialContent_andResolvesNoToolCalls() async {
        client.events = [StreamEvent(contentDelta: "half a th")]
        client.finishCancelled = true

        do {
            _ = try await service.performStreamingCall(
                stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
                client: client, config: LLMConfig(),
                tools: [], conversationMessages: [], networkLogger: nil)
            XCTFail("Expected CancellationError to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(delegate.commitStreamingCalls.count, 1)
        XCTAssertEqual(delegate.commitStreamingCalls[0].2, "half a th")
        XCTAssertTrue(delegate.clearProcessingProgressCalls.contains(stepID))
    }

    // MARK: - processStreamingResult

    private func makeResult(
        content: String = "",
        toolCalls: [StepToolCall] = []
    ) -> LLMExecutionService.StreamingResult {
        LLMExecutionService.StreamingResult(
            assistantContent: content, thinkingContent: "",
            resolvedToolCalls: toolCalls, sawHarmonyMarker: false, harmonyBuffer: "")
    }

    func testProcessStreamingResult_contentOnly_appendsOneAssistantTurn() async {
        var messages: [ChatMessage] = [ChatMessage(role: .user, content: "q")]
        await service.processStreamingResult(
            makeResult(content: "  an answer  "),
            stepID: stepID, taskID: taskID, conversationMessages: &messages)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.content, "an answer",
                       "the appended turn carries the CLEANED content, matching what was committed")
        XCTAssertTrue(messages.last?.toolCalls?.isEmpty ?? true)
    }

    /// The empty anchor. A turn that resolved to nothing still happened, so the wire must
    /// grow — otherwise a malformed iteration leaves the array byte-identical to the
    /// previous one and the retry nudge replies to nothing.
    func testProcessStreamingResult_emptyTurn_appendsNilContentAnchor() async {
        var messages: [ChatMessage] = [ChatMessage(role: .user, content: "q")]
        _ = await service.processStreamingResult(
            makeResult(), stepID: stepID, taskID: taskID, conversationMessages: &messages)

        XCTAssertEqual(messages.count, 2, "the conversation must keep growing")
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertNil(messages.last?.content)
        XCTAssertNil(messages.last?.toolCalls)
    }

    /// Whitespace-only content is "nothing" for this purpose — it takes the anchor branch.
    func testProcessStreamingResult_whitespaceOnlyContent_takesTheAnchorBranch() async {
        var messages: [ChatMessage] = []
        _ = await service.processStreamingResult(
            makeResult(content: "   \n\t "),
            stepID: stepID, taskID: taskID, conversationMessages: &messages)

        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(messages.last?.content)
    }

    func testProcessStreamingResult_toolCalls_appendThemOntoTheAssistantTurn() async {
        installTask()
        var messages: [ChatMessage] = []
        let calls = [
            StepToolCall(providerID: "prov-1", name: ToolNames.readFile,
                         argumentsJSON: "{\"path\":\"a.txt\"}"),
            StepToolCall(providerID: nil, name: ToolNames.gitStatus, argumentsJSON: "{}"),
        ]

        await service.processStreamingResult(
            makeResult(content: "Let me check.", toolCalls: calls),
            stepID: stepID, taskID: taskID, conversationMessages: &messages)

        XCTAssertEqual(messages.count, 1)
        let turn = messages[0]
        XCTAssertEqual(turn.role, .assistant)
        XCTAssertEqual(turn.content, "Let me check.")
        XCTAssertEqual(turn.toolCalls?.map(\.name), [ToolNames.readFile, ToolNames.gitStatus])
        XCTAssertEqual(turn.toolCalls?.first?.id, "prov-1",
                       "a provider id must ride through so the tool result can name its call")
        let synthesized = turn.toolCalls?.last?.id ?? ""
        XCTAssertFalse(synthesized.isEmpty,
                       "a call without a provider id gets a freshly minted one, never an empty string")
        XCTAssertNotEqual(synthesized, "prov-1")
    }

    /// Tool calls are re-stamped so they sort AFTER the assistant message in the timeline,
    /// and they land on the step through the delegate's atomic mutation.
    func testProcessStreamingResult_toolCalls_arePersistedRestampedOntoTheStep() async {
        installTask()
        let stamped = MonotonicClock.shared.now()
        let call = StepToolCall(
            createdAt: stamped, providerID: nil, name: ToolNames.gitStatus, argumentsJSON: "{}")

        var messages: [ChatMessage] = []
        _ = await service.processStreamingResult(
            makeResult(toolCalls: [call]),
            stepID: stepID, taskID: taskID, conversationMessages: &messages)

        let persisted = delegate.taskToMutate?.runs.last?.steps.first?.toolCalls ?? []
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.name, ToolNames.gitStatus)
        XCTAssertGreaterThan(
            persisted.first?.createdAt ?? .distantPast, stamped,
            "the re-stamp is what keeps the call card below the assistant bubble it belongs to")
    }

    /// A tool-call turn with no prose: the assistant turn still exists (it carries the
    /// calls), and its content is nil rather than an empty string.
    func testProcessStreamingResult_toolCallsWithoutContent_appendNilContentTurn() async {
        installTask()
        var messages: [ChatMessage] = []
        _ = await service.processStreamingResult(
            makeResult(toolCalls: [
                StepToolCall(name: ToolNames.gitStatus, argumentsJSON: "{}")
            ]),
            stepID: stepID, taskID: taskID, conversationMessages: &messages)

        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(messages[0].content)
        XCTAssertEqual(messages[0].toolCalls?.count, 1)
    }

    /// Nothing is persisted when the step is no longer live — the post-teardown write
    /// barrier must drop an orphaned turn instead of landing it on whatever now answers
    /// to this taskID.
    func testProcessStreamingResult_afterTeardown_doesNotPersistToolCalls() async {
        installTask()
        service.clearRunningTask(stepID: stepID, taskID: taskID)

        var messages: [ChatMessage] = []
        _ = await service.processStreamingResult(
            makeResult(toolCalls: [
                StepToolCall(name: ToolNames.gitStatus, argumentsJSON: "{}")
            ]),
            stepID: stepID, taskID: taskID, conversationMessages: &messages)

        XCTAssertTrue(
            (delegate.taskToMutate?.runs.last?.steps.first?.toolCalls ?? []).isEmpty,
            "an orphan's late write must be dropped by the isExecutionLive barrier")
        XCTAssertEqual(messages.count, 1,
                       "the in-memory wire array is still updated — it is not persisted state")
    }
}
