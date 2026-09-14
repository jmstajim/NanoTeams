import XCTest

@testable import NanoTeams

/// End-to-end `OpenAICompatLMStudioClient.streamChat` over REAL `URLSession.AsyncBytes` (the
/// data-URL replay `NativeClientStreamChatTests` uses): the request shape, the explicit
/// load through the HELD native client, the SSE loop's every arm — reasoning under both
/// names, tool-call pieces, `finish_reason`, `usage`, the error chunk's two readings — the
/// non-2xx, 429, non-HTTP and transport failures, and the network log it writes.
final class OpenAICompatStreamChatTests: XCTestCase {

    /// `path -> (status, body)` for every `sessionData` route (the lifecycle probes the native
    /// client issues); the SSE payload for `sessionBytes` (the chat itself).
    private final class RoutingSession: NetworkSession, @unchecked Sendable {
        var dataRoutes: [String: (status: Int, body: String)] = [:]
        var chatPayload: String = ""
        var chatStatus: Int = 200
        var chatHeaders: [String: String]?
        var chatReturnsNonHTTPResponse = false
        var chatTransportError: Error?
        /// Never answers: `sessionBytes` sleeps until the request task is cancelled, so the
        /// client's cancellation arm runs deterministically.
        var chatHangsUntilCancelled = false
        private(set) var dataPaths: [String] = []
        private(set) var chatRequests: [URLRequest] = []

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            let path = request.url?.path ?? ""
            dataPaths.append(path)
            let route = dataRoutes[path] ?? (status: 500, body: "{\"error\":\"unrouted\"}")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil)!
            return (Data(route.body.utf8), response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            chatRequests.append(request)
            if let chatTransportError { throw chatTransportError }
            if chatHangsUntilCancelled { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            let dataURL = URL(string: "data:text/event-stream;base64,"
                + Data(chatPayload.utf8).base64EncodedString())!
            let (bytes, _) = try await URLSession.shared.bytes(from: dataURL)
            if chatReturnsNonHTTPResponse {
                return (bytes, URLResponse(
                    url: request.url!, mimeType: "text/event-stream",
                    expectedContentLength: -1, textEncodingName: nil))
            }
            return (bytes, HTTPURLResponse(
                url: request.url!, statusCode: chatStatus, httpVersion: nil, headerFields: chatHeaders)!)
        }
    }

    private struct Collected {
        var content = ""
        var thinking = ""
        var calls: [StreamEvent.ToolCallDelta] = []
        var usage: TokenUsage?
        var reasoningTokens: Int?
        var doneReason: String?
        var residency: ClientResidencyFacts?
        var error: Error?
    }

    private let readFile = ToolSchema(
        name: ToolNames.readFile, description: "Read a file",
        parameters: .object(properties: ["path": JSONSchema.string("Path")], required: ["path"]))

    /// A FRESH ensurer per client (CLAUDE.md #49): the process-global one would leak its
    /// census across tests.
    private func makeClient(_ session: RoutingSession, tokens: [String: String] = [:]) -> OpenAICompatLMStudioClient {
        let native = NativeLMStudioClient(
            session: session, tokenResolver: StubLLMTokenResolver(tokens), modelEnsurer: ChatModelEnsurer())
        return OpenAICompatLMStudioClient(session: session, tokenResolver: StubLLMTokenResolver(tokens), native: native)
    }

    private func config(baseURL: String = "http://127.0.0.1:1234", timeout: Int? = nil) -> LLMConfig {
        LLMConfig(
            provider: .lmStudio, baseURLString: baseURL, modelName: "google/gemma-4-26b-a4b-qat",
            requestTimeoutSeconds: timeout, toolCallingMode: .native)
    }

    private func drain(
        _ client: OpenAICompatLMStudioClient, config: LLMConfig,
        messages: [ChatMessage] = [ChatMessage(role: .user, content: "Read App.swift")],
        tools: [ToolSchema]? = nil, logger: NetworkLogger? = nil
    ) async -> Collected {
        let stream = client.streamChat(
            config: config, messages: messages, tools: tools ?? [readFile],
            logger: logger, stepID: "engineer", roleName: "Software Engineer")
        var out = Collected()
        do {
            for try await event in stream {
                out.content += event.contentDelta
                out.thinking += event.thinkingDelta
                out.calls += event.toolCallDeltas
                if let u = event.tokenUsage { out.usage = u }
                if let r = event.serverReasoningOutputTokens { out.reasoningTokens = r }
                if let d = event.serverDoneReason { out.doneReason = d }
                if let f = event.clientResidency { out.residency = f }
            }
        } catch {
            out.error = error
        }
        return out
    }

    /// Recorded 2026-09-13 on LM Studio (`gemma-4-26b-a4b-qat`, probe L1), trimmed.
    private static let toolCallStream = """
    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"I should read the file."},"finish_reason":null}]}
    
    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"268992578","type":"function","function":{"name":"read_file","arguments":""}}]},"finish_reason":null}]}
    
    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":"}}]},"finish_reason":null}]}
    
    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"App.swift\\"}"}}]},"finish_reason":null}]}
    
    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
    
    data: {"id":"c1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":2552,"completion_tokens":31,"total_tokens":2583,"completion_tokens_details":{"reasoning_tokens":9}}}
    
    data: [DONE]
    """

    // MARK: - The request

    func testRequest_goesToChatCompletions_withToolsStreamUsageAndTheNativeChip() async throws {
        let session = RoutingSession()
        session.chatPayload = Self.toolCallStream
        _ = await drain(makeClient(session), config: config())

        let request = try XCTUnwrap(session.chatRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#""tools":[{"function":{"description":"Read a file""#), body)
        XCTAssertTrue(body.contains(#""stream":true"#))
        XCTAssertTrue(body.contains(#""stream_options":{"include_usage":true}"#))
        XCTAssertTrue(body.contains(NativeLMStudioClient.oneToolPerResponseRule))
        XCTAssertFalse(body.contains("Call tools using this Harmony format"), "no lesson on the native wire")
        XCTAssertEqual(session.dataPaths.first, "/api/v0/models",
                       "the explicit adopt-or-load (the native client's census probe) runs first")
    }

    func testRequest_carriesTheBearerToken_whenOneIsStored() async throws {
        let session = RoutingSession()
        session.chatPayload = "data: [DONE]\n"
        _ = await drain(makeClient(session, tokens: ["http://127.0.0.1:1234": "secret"]), config: config())
        XCTAssertEqual(session.chatRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testRequest_timeout_isTheConfigsOrEffectivelyUnbounded() async throws {
        let bounded = RoutingSession(); bounded.chatPayload = "data: [DONE]\n"
        _ = await drain(makeClient(bounded), config: config(timeout: 90))
        XCTAssertEqual(bounded.chatRequests.first?.timeoutInterval, 90)
        let unbounded = RoutingSession(); unbounded.chatPayload = "data: [DONE]\n"
        _ = await drain(makeClient(unbounded), config: config(timeout: 0))
        XCTAssertEqual(unbounded.chatRequests.first?.timeoutInterval, TimeInterval(Int32.max))
    }

    func testInvalidBaseURL_throws_beforeAnyNetworkCall() async {
        let session = RoutingSession()
        let out = await drain(makeClient(session), config: config(baseURL: "not a url ://bad"))
        guard case .invalidBaseURL? = out.error as? LLMClientError else {
            return XCTFail("\(String(describing: out.error))")
        }
        XCTAssertTrue(session.chatRequests.isEmpty)
    }

    // MARK: - The SSE loop

    func testStream_reasoningToolCallPiecesFinishAndUsage_arriveInOrder() async {
        let session = RoutingSession()
        session.chatPayload = Self.toolCallStream
        let out = await drain(makeClient(session), config: config())

        XCTAssertNil(out.error)
        XCTAssertEqual(out.thinking, "I should read the file.")
        XCTAssertEqual(out.content, "")
        XCTAssertEqual(out.calls.count, 3, "three pieces, folded by the caller's accumulator")
        XCTAssertEqual(out.calls.first?.id, "268992578")
        XCTAssertEqual(out.calls.first?.name, ToolNames.readFile)
        XCTAssertEqual(out.calls.map { $0.argumentsDelta ?? "" }.joined(), #"{"path":"App.swift"}"#)
        XCTAssertEqual(out.usage, TokenUsage(inputTokens: 2552, outputTokens: 31))
        XCTAssertEqual(out.reasoningTokens, 9)
        XCTAssertEqual(out.doneReason, "tool_calls")
    }

    func testStream_reasoningUnderTheOtherName_andContent_andLength() async {
        let session = RoutingSession()
        session.chatPayload = """
        data: {"choices":[{"index":0,"delta":{"reasoning":"gpt-oss style"}}]}
        
        data: {"choices":[{"index":0,"delta":{"content":"Hel"}}]}
        
        data: {"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":"length"}]}
        
        data: [DONE]
        """
        let out = await drain(makeClient(session), config: config())
        XCTAssertNil(out.error)
        XCTAssertEqual(out.thinking, "gpt-oss style")
        XCTAssertEqual(out.content, "Hello")
        XCTAssertEqual(out.doneReason, "length", "the `length`-with-no-call branch reads this")
        XCTAssertNil(out.usage, "no usage frame ⇒ none fabricated")
    }

    func testStream_inlineThinkTags_areReroutedToThinking() async {
        let session = RoutingSession()
        session.chatPayload = """
        data: {"choices":[{"index":0,"delta":{"content":"<think>plan</think>answer"}}]}
        
        data: [DONE]
        """
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual(out.thinking, "plan")
        XCTAssertEqual(out.content, "answer")
    }

    func testStream_withoutDone_orAnyTerminalFrame_finishesCleanWithNoDiagnostics() async {
        let session = RoutingSession()
        session.chatPayload = """
        data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}
        """
        let out = await drain(makeClient(session), config: config())
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "partial")
        XCTAssertNil(out.usage)
        XCTAssertNil(out.doneReason)
    }

    func testStream_emptyBody_finishesCleanWithNoEvents() async {
        let session = RoutingSession()
        session.chatPayload = ""
        let out = await drain(makeClient(session), config: config())
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "")
        XCTAssertTrue(out.calls.isEmpty)
    }

    // MARK: - The error chunk

    func testStream_errorAfterGeneratedTokens_isANativeCallRejection() async {
        let session = RoutingSession()
        session.chatPayload = """
        data: {"choices":[{"index":0,"delta":{"reasoning_content":"calling"}}]}
        
        data: {"error":{"message":"Unexpected token in tool call","type":"invalid_request_error"}}
        """
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual(out.thinking, "calling")
        XCTAssertEqual(out.error as? LLMClientError, .nativeToolCallRejected("Unexpected token in tool call"))
    }

    func testStream_errorBeforeAnyToken_withoutTheWording_isAProviderError() async {
        let session = RoutingSession()
        session.chatPayload = """
        data: {"error":{"message":"Model unloaded"}}
        """
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual(out.error as? LLMClientError, .providerError("Model unloaded"))
    }

    func testStream_errorBeforeAnyToken_withTheDocumentedWording_isARejection() async {
        let session = RoutingSession()
        session.chatPayload = """
        data: {"error":{"message":"Failed to parse tool call: missing name"}}
        """
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual(out.error as? LLMClientError, .nativeToolCallRejected("Failed to parse tool call: missing name"))
    }

    // MARK: - HTTP and transport failures

    func testHTTP500_throwsBadHTTPStatusWithTheBody() async {
        let session = RoutingSession()
        session.chatStatus = 500
        session.chatPayload = "{\"error\":\"boom\"}"
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual(out.error as? LLMClientError, .badHTTPStatus(500, "{\"error\":\"boom\"}"))
    }

    func testHTTP500_withAnEmptyBody_carriesNil() async {
        let session = RoutingSession()
        session.chatStatus = 503
        session.chatPayload = ""
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual(out.error as? LLMClientError, .badHTTPStatus(503, nil))
    }

    func testHTTP500_bodyIsCappedNearFiveHundredBytes() async {
        let session = RoutingSession()
        session.chatStatus = 500
        session.chatPayload = (0..<200).map { _ in "0123456789" }.joined(separator: "\n")
        let out = await drain(makeClient(session), config: config())
        guard case .badHTTPStatus(500, let body?)? = out.error as? LLMClientError else {
            return XCTFail("\(String(describing: out.error))")
        }
        XCTAssertLessThan(body.utf8.count, 600, "the cap stops the read, it does not swallow the whole body")
    }

    func testHTTP429_withRetryAfter_throwsRateLimited() async {
        let session = RoutingSession()
        session.chatStatus = 429
        session.chatHeaders = ["Retry-After": "7"]
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual(out.error as? LLMClientError, .rateLimited(retryAfter: 7))
    }

    func testNonHTTPResponse_throwsMissingResponse() async {
        let session = RoutingSession()
        session.chatReturnsNonHTTPResponse = true
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual(out.error as? LLMClientError, .missingResponse)
    }

    func testTransportError_propagatesAsIs() async {
        let session = RoutingSession()
        session.chatTransportError = URLError(.notConnectedToInternet)
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual((out.error as? URLError)?.code, .notConnectedToInternet)
    }

    // MARK: - Residency through the held native client

    func testExplicitLoad_throughTheNativeClient_emitsResidencyFacts() async {
        let session = RoutingSession()
        session.dataRoutes["/api/v0/models"] = (200, "{\"data\":[]}")
        session.dataRoutes["/api/v1/models/load"] = (200, "{\"instance_id\":\"inst-1\"}")
        session.chatPayload = "data: [DONE]\n"
        let out = await drain(makeClient(session), config: config())
        XCTAssertNil(out.error)
        XCTAssertEqual(out.residency?.appLoadedModelForThisRequest, true)
        XCTAssertTrue(session.dataPaths.contains("/api/v1/models/load"))
        XCTAssertEqual(session.chatRequests.count, 1, "the chat waited for the load")
    }

    // MARK: - The network log

    func testNetworkLog_writesProvenanceRequestAndResponse_withTheCallsFolded() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.jsonl")
        NetworkLogger._testResetProvenanceRegistry()

        let session = RoutingSession()
        session.chatPayload = Self.toolCallStream
        let out = await drain(makeClient(session), config: config(), logger: NetworkLogger(logURL: logURL))
        XCTAssertNil(out.error)

        let records = try NetworkLogTestReading.strictRecords(at: logURL)
        XCTAssertEqual(records.map(\.direction), [.provenance, .request, .response])
        let request = try XCTUnwrap(records.first { $0.direction == .request })
        XCTAssertTrue(request.url.hasSuffix("/v1/chat/completions"))
        XCTAssertEqual(request.stepID, "engineer")
        let response = try XCTUnwrap(records.first { $0.direction == .response })
        XCTAssertEqual(response.correlationID, request.correlationID)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.inputTokens, 2552)
        XCTAssertEqual(response.outputTokens, 31)
        XCTAssertEqual(response.doneReason, "tool_calls", "`finish_reason` verbatim, so a `length` stop is auditable from the log")
        let body = try XCTUnwrap(response.body)
        XCTAssertTrue(body.hasPrefix("[reasoning]\nI should read the file.\n[/reasoning]"))
        XCTAssertTrue(body.contains("[tool_call] read_file {\"path\":\"App.swift\"}"),
                      "the pieces are folded into one call for the log: \(body)")
        XCTAssertTrue(records.first?.body?.contains("\"toolCalling\":\"native\"") == true,
                      "the provenance names the mode")
    }

    func testNetworkLog_onAFailure_writesAnErrorRecord() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.jsonl")
        NetworkLogger._testResetProvenanceRegistry()

        let session = RoutingSession()
        session.chatStatus = 500
        session.chatPayload = "nope"
        let out = await drain(makeClient(session), config: config(), logger: NetworkLogger(logURL: logURL))
        XCTAssertNotNil(out.error)

        let records = try NetworkLogTestReading.strictRecords(at: logURL)
        let errorRecord = try XCTUnwrap(records.last)
        XCTAssertEqual(errorRecord.direction, .response)
        XCTAssertEqual(errorRecord.statusCode, 0)
        XCTAssertNotNil(errorRecord.errorMessage)
    }

    /// The record of an interrupted request carries what had streamed by then: on 2026-09-13
    /// a Change Planner request ran 662 s to the run's timeout and its record said `cancelled`
    /// and nothing else, so whether the model was looping in its reasoning or the server had
    /// stalled could not be read from the log.
    func testNetworkLog_onAnErrorAfterTokens_theRecordCarriesWhatStreamed() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.jsonl")
        NetworkLogger._testResetProvenanceRegistry()

        let session = RoutingSession()
        session.chatPayload = """
        data: {"choices":[{"index":0,"delta":{"reasoning_content":"weighing"}}]}
        
        data: {"choices":[{"index":0,"delta":{"content":"partial prose"}}]}
        
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"read_file","arguments":"{\\"path\\":\\"A\\"}"}}]}}]}
        
        data: {"error":{"message":"Model unloaded"}}
        """
        let out = await drain(makeClient(session), config: config(), logger: NetworkLogger(logURL: logURL))
        XCTAssertNotNil(out.error)

        let records = try NetworkLogTestReading.strictRecords(at: logURL)
        let errorRecord = try XCTUnwrap(records.last)
        XCTAssertEqual(errorRecord.direction, .response)
        XCTAssertEqual(errorRecord.statusCode, 0)
        XCTAssertNotNil(errorRecord.errorMessage)
        let body = try XCTUnwrap(errorRecord.body, "what streamed before the error is in the record")
        XCTAssertTrue(body.hasPrefix("[reasoning]\nweighing\n[/reasoning]\n\n"), body)
        XCTAssertTrue(body.contains("partial prose"), body)
        XCTAssertTrue(body.contains("[tool_call] read_file {\"path\":\"A\"}"), body)
    }

    /// A consumer cancelled mid-request leaves a record too — `cancelled`, body nil when
    /// nothing had streamed — where until 2026-09-13 the cancellation arm logged nothing.
    func testCancellation_leavesAResponseRecordNamedCancelled() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.jsonl")
        NetworkLogger._testResetProvenanceRegistry()

        let session = RoutingSession()
        session.chatHangsUntilCancelled = true
        let client = makeClient(session)
        let config = config()
        let tools = [readFile]   // hoisted: the task must not capture the test case
        let logger = NetworkLogger(logURL: logURL)
        let consumer = Task { () -> Bool in
            let stream = client.streamChat(
                config: config, messages: [ChatMessage(role: .user, content: "hi")], tools: tools,
                logger: logger, stepID: "engineer", roleName: "Software Engineer")
            do {
                for try await _ in stream {}
                return false
            } catch {
                return error is CancellationError
            }
        }
        while session.chatRequests.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        consumer.cancel()
        _ = await consumer.value

        // The consumer returns before the producer's catch arm has appended the record.
        let deadline = Date().addingTimeInterval(5)
        var records: [NetworkLogRecord] = []
        while Date() < deadline {
            records = (try? NetworkLogTestReading.strictRecords(at: logURL)) ?? []
            if records.contains(where: { $0.direction == .response }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let request = try XCTUnwrap(records.first { $0.direction == .request })
        let response = try XCTUnwrap(records.first { $0.direction == .response }, "the interrupted request left a record")
        XCTAssertEqual(response.statusCode, 0)
        XCTAssertEqual(response.errorMessage, "cancelled")
        XCTAssertNil(response.body, "nothing had streamed")
        XCTAssertEqual(response.correlationID, request.correlationID)
    }

    // MARK: - coalesce

    func testCoalesce_foldsPiecesIntoWholeCalls_inOrder() {
        let folded = OpenAICompatLMStudioClient.coalesce([
            StreamEvent.ToolCallDelta(index: 0, id: "a", name: "read_file", argumentsDelta: "{\"pa"),
            StreamEvent.ToolCallDelta(index: 1, id: "b", name: "git_status", argumentsDelta: "{}"),
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "th\":\"x\"}"),
        ])
        XCTAssertEqual(folded.map(\.name), ["read_file", "git_status"])
        XCTAssertEqual(folded.map(\.argumentsDelta), ["{\"path\":\"x\"}", "{}"])
        XCTAssertEqual(folded.map(\.id), ["a", "b"])
        XCTAssertEqual(folded.map(\.index), [0, 1])
        XCTAssertTrue(OpenAICompatLMStudioClient.coalesce([]).isEmpty)
    }

    // MARK: - Delegation

    func testLifecycleAndListing_delegateToTheNativeClient() async throws {
        let session = RoutingSession()
        session.dataRoutes["/api/v1/models"] = (200, #"{"models":[{"key":"m","type":"llm","capabilities":{"trained_for_tool_use":true}}]}"#)
        session.dataRoutes["/api/v0/models"] = (200, #"{"data":[{"id":"m","type":"llm","state":"loaded","max_context_length":8192}]}"#)
        let client = makeClient(session)
        let support = await client.toolCallingSupport(
            config: LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m"))
        XCTAssertEqual(support, true)
        let listing = try await client.listLoadedInstances(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234")
        if case .listed = listing {} else { XCTFail("\(listing)") }
        XCTAssertTrue(session.dataPaths.contains("/api/v1/models"))
        XCTAssertTrue(session.chatRequests.isEmpty, "no chat was issued by a probe")
    }


    // MARK: - The parser's held-back tail, a content-only log, cancellation

    /// A stream that ends on a partial `<think` prefix: the splitter held it back, and the
    /// client's `finalize()` pass releases it as content so no byte is lost.
    func testStream_heldBackTagPrefix_isReleasedAtTransportEnd() async {
        let session = RoutingSession()
        session.chatPayload = """
        data: {"choices":[{"index":0,"delta":{"content":"answer <thi"}}]}
        """
        let out = await drain(makeClient(session), config: config())
        XCTAssertNil(out.error)
        XCTAssertEqual(out.content, "answer <thi")
    }

    func testNetworkLog_contentOnlyResponse_hasNoReasoningWrapper() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.jsonl")
        NetworkLogger._testResetProvenanceRegistry()

        let session = RoutingSession()
        session.chatPayload = """
        data: {"choices":[{"index":0,"delta":{"content":"just prose"},"finish_reason":"stop"}]}
        
        data: [DONE]
        """
        let out = await drain(makeClient(session), config: config(), logger: NetworkLogger(logURL: logURL))
        XCTAssertNil(out.error)
        let response = try XCTUnwrap(try NetworkLogTestReading.strictRecords(at: logURL).first { $0.direction == .response })
        XCTAssertEqual(response.body, "just prose")
    }

    /// Cancelling the consumer cancels the request task; the client ends the stream with
    /// `CancellationError` rather than a transport error, so the step's cancellation arm — not
    /// its retry arm — sees it.
    func testCancellation_endsTheStream_withoutATransportError() async throws {
        let session = RoutingSession()
        session.chatHangsUntilCancelled = true
        let client = makeClient(session)
        let config = config()
        let tools = [readFile]   // hoisted: the task must not capture the test case
        let consumer = Task { () -> String in
            let stream = client.streamChat(
                config: config, messages: [ChatMessage(role: .user, content: "hi")], tools: tools,
                logger: nil, stepID: nil, roleName: nil)
            do {
                for try await _ in stream {}
                return "ended"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "error: \(error)"
            }
        }
        // Give the request task time to reach the hanging `sessionBytes`, then pull the plug.
        while session.chatRequests.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        consumer.cancel()
        let outcome = await consumer.value
        XCTAssertTrue(outcome == "ended" || outcome == "cancelled", outcome)
    }

    // MARK: - Every other surface is the native client's

    func testEveryProbeAndLifecycleCall_reachesTheNativeClientsEndpoints() async {
        let session = RoutingSession()   // every route unrouted ⇒ 500 ⇒ throws / nil, but the CALL is the native client's
        let client = makeClient(session)
        let config = self.config()
        do { _ = try await client.fetchModels(config: config, visionOnly: false); XCTFail("500 must throw") } catch {}
        do { _ = try await client.fetchEmbeddingModels(config: config); XCTFail("500 must throw") } catch {}
        do { _ = try await client.loadModel(provider: .lmStudio, modelName: "m", baseURLString: config.baseURLString); XCTFail("500 must throw") } catch {}
        do { try await client.unloadModel(provider: .lmStudio, instanceID: "i", baseURLString: config.baseURLString); XCTFail("500 must throw") } catch {}
        let vision = await client.modelSupportsVision(config: config)
        let context = await client.modelContextLength(config: config)
        let details = await client.modelLoadDetails(config: config)
        XCTAssertNil(vision); XCTAssertNil(context); XCTAssertNil(details)
        XCTAssertTrue(session.dataPaths.contains("/api/v1/models"))
        XCTAssertTrue(session.dataPaths.contains("/api/v0/models"))
        XCTAssertTrue(session.dataPaths.contains("/api/v1/models/load"))
        XCTAssertTrue(session.dataPaths.contains("/api/v1/models/unload"))
        XCTAssertTrue(session.chatRequests.isEmpty)
    }


    /// The same four calls when the server answers: the native client's decoded answers come
    /// back through the wrappers unchanged.
    func testLifecycleCalls_thatSucceed_returnTheNativeClientsAnswers() async throws {
        let session = RoutingSession()
        session.dataRoutes["/api/v1/models"] = (200, #"{"models":[{"key":"gemma","type":"llm"},{"key":"nomic","type":"embeddings"}]}"#)
        session.dataRoutes["/api/v1/models/load"] = (200, #"{"instance_id":"inst-1"}"#)
        session.dataRoutes["/api/v1/models/unload"] = (200, "{}")
        let client = makeClient(session)
        let config = self.config()
        let models = try await client.fetchModels(config: config, visionOnly: false)
        XCTAssertEqual(models.map(\.name), ["gemma"], "the embedding model is not a chat model")
        let embeddings = try await client.fetchEmbeddingModels(config: config)
        XCTAssertEqual(embeddings, ["nomic"])
        let instance = try await client.loadModel(provider: .lmStudio, modelName: "gemma", baseURLString: config.baseURLString)
        XCTAssertEqual(instance, "inst-1")
        try await client.unloadModel(provider: .lmStudio, instanceID: instance, baseURLString: config.baseURLString)
        XCTAssertEqual(session.dataPaths.filter { $0 == "/api/v1/models/unload" }.count, 1)
        XCTAssertTrue(session.chatRequests.isEmpty)
    }


    // MARK: - What a mid-stream error after tokens is NOT

    func testStream_unloadAfterTokens_staysAProviderError() async {
        let session = RoutingSession()
        session.chatPayload = """
        data: {"choices":[{"index":0,"delta":{"reasoning_content":"calling"}}]}
        
        data: {"error":{"message":"Model unloaded"}}
        """
        let out = await drain(makeClient(session), config: config())
        XCTAssertEqual(out.error as? LLMClientError, .providerError("Model unloaded"))
    }

    func testStream_toolLessRequest_errorAfterTokens_staysAProviderError() async {
        let session = RoutingSession()
        session.chatPayload = """
        data: {"choices":[{"index":0,"delta":{"content":"hello"}}]}
        
        data: {"error":{"message":"Unexpected token"}}
        """
        let out = await drain(makeClient(session), config: config(), tools: [])
        XCTAssertEqual(out.error as? LLMClientError, .providerError("Unexpected token"))
    }
}
