import XCTest

@testable import NanoTeams

/// Client-layer surfaces that the existing per-file suites leave uncovered:
/// the `LLMClient` protocol's DEFAULT implementations, the `URLSession`
/// conformance bridge, the error `errorDescription` arms nobody drives,
/// `EmbeddingConfig`'s per-model prompt table + validating/Codable inits, the
/// `LMStudioEmbeddingClient` static classifiers and its logger plumbing,
/// `LLMConnectionChecker`'s non-URLError / non-HTTP transport arms,
/// `SSEEventParser`'s undecodable-payload arms, and `OllamaClient`'s
/// transport-failure + `NetworkLogger` paths.
///
/// Everything is driven through the REAL production entry points via the
/// `NetworkSession` seam. `URLSession.AsyncBytes` has no public initializer, so
/// byte streams are fabricated from a `data:` URL (house pattern — see
/// `OllamaStreamChatTests.NDJSONBytesSession`). No network, no LM Studio.
final class LLMClientSurfacesTests: XCTestCase {

    // MARK: - Fixtures

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LLMClientSurfacesTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    private func ollamaConfig(
        baseURL: String = "http://127.0.0.1:11434",
        model: String = "gpt-oss:20b"
    ) -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: baseURL, modelName: model)
    }

    private func embeddingConfig(
        model: String = "text-embedding-nomic-embed-text-v1.5"
    ) -> EmbeddingConfig {
        EmbeddingConfig(
            baseURLString: "http://127.0.0.1:1234",
            modelName: model,
            batchSize: 8,
            requestTimeout: 5)
    }

    private func readNetworkRecords(at url: URL) throws -> [NetworkLogRecord] {
        let data = try Data(contentsOf: url)
        return try JSONCoderFactory.makeDateDecoder()
            .decode([NetworkLogRecord].self, from: data)
    }

    // MARK: - LLMClient protocol defaults
    //
    // A client that implements ONLY the two members without defaults inherits
    // the whole `nonisolated extension LLMClient` block. These defaults are the
    // contract every test double in the module relies on, and nothing drove
    // them directly.

    func testDefaultFetchEmbeddingModels_returnsEmpty() async throws {
        let client = MinimalLLMClient()
        let models = try await client.fetchEmbeddingModels(config: ollamaConfig())
        XCTAssertEqual(models, [], "no embedding listing surface by default")
    }

    func testDefaultLoadModel_throwsProviderError() async {
        let client = MinimalLLMClient()
        do {
            _ = try await client.loadModel(modelName: "m", baseURLString: "http://x")
            XCTFail("Expected providerError — the default must be loud, not a silent success")
        } catch let error as LLMClientError {
            guard case .providerError(let message) = error else {
                return XCTFail("Expected providerError, got \(error)")
            }
            XCTAssertTrue(message.contains("model lifecycle"), message)
        } catch {
            XCTFail("Expected LLMClientError, got \(type(of: error))")
        }
    }

    func testDefaultUnloadModel_throwsProviderError() async {
        let client = MinimalLLMClient()
        do {
            try await client.unloadModel(instanceID: "i", baseURLString: "http://x")
            XCTFail("Expected providerError")
        } catch let error as LLMClientError {
            guard case .providerError = error else {
                return XCTFail("Expected providerError, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMClientError, got \(type(of: error))")
        }
    }

    /// Deliberately asymmetric with `loadModel`/`unloadModel`: returning `[]`
    /// lets the caller fall through to `loadModel`, which is where a genuinely
    /// unsupported provider surfaces its error.
    func testDefaultListLoadedInstances_returnsEmptyRatherThanThrowing() async throws {
        let client = MinimalLLMClient()
        let instances = try await client.listLoadedInstances(baseURLString: "http://x")
        XCTAssertEqual(instances, [])
    }

    func testDefaultMetadataProbes_areUndeterminable() async {
        let client = MinimalLLMClient()
        let config = ollamaConfig()
        let vision = await client.modelSupportsVision(config: config)
        let context = await client.modelContextLength(config: config)
        let details = await client.modelLoadDetails(config: config)
        XCTAssertNil(vision, "callers must fall toward the no-vision path, never assume vision")
        XCTAssertNil(context, "an undeterminable window must stay undeterminable")
        XCTAssertNil(details)
    }

    func testStreamChatConvenienceOverload_forwardsNilRoleName() async throws {
        let client = MinimalLLMClient()
        // 5-arg call → the extension's convenience overload → 6-arg requirement.
        let stream = client.streamChat(
            config: ollamaConfig(), messages: [], tools: [], logger: nil, stepID: "step-1")
        for try await _ in stream {}
        XCTAssertEqual(client.streamCallCount, 1)
        XCTAssertEqual(client.lastStepID, "step-1")
        XCTAssertNil(client.lastRoleName, "the convenience overload passes roleName: nil")
    }

    func testLoadedModelInstance_equatable() {
        let a = LoadedModelInstance(modelName: "nomic", instanceID: "nomic")
        let b = LoadedModelInstance(modelName: "nomic", instanceID: "nomic")
        let c = LoadedModelInstance(modelName: "nomic", instanceID: "nomic:2")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "the dedup suffix is what distinguishes duplicate loads")
    }

    // MARK: - URLSession → NetworkSession bridge
    //
    // The protocol methods exist only because Swift won't match a requirement
    // against a method with an extra defaulted parameter. A `data:` URL keeps
    // this fully offline.

    func testURLSessionBridge_sessionData_deliversBody() async throws {
        let payload = #"{"ok":true}"#
        let url = URL(string: "data:application/json;base64,"
            + Data(payload.utf8).base64EncodedString())!
        let session: any NetworkSession = URLSession.shared

        let (data, _) = try await session.sessionData(for: URLRequest(url: url))

        XCTAssertEqual(String(data: data, encoding: .utf8), payload)
    }

    func testURLSessionBridge_sessionBytes_deliversLines() async throws {
        let payload = "one\ntwo\n"
        let url = URL(string: "data:text/plain;base64,"
            + Data(payload.utf8).base64EncodedString())!
        let session: any NetworkSession = URLSession.shared

        let (bytes, _) = try await session.sessionBytes(for: URLRequest(url: url))
        var lines: [String] = []
        for try await line in bytes.lines { lines.append(line) }

        XCTAssertEqual(lines, ["one", "two"])
    }

    // MARK: - LLMClientError.errorDescription — uncovered arms

    /// An unconfigured server reads as "not configured yet", not "you typed
    /// something invalid" — onAppear preflights would otherwise render a
    /// useless `Invalid LLM base URL:` row with nothing after the colon.
    func testInvalidBaseURL_emptyString_saysAddressIsEmpty() {
        let message = LLMClientError.invalidBaseURL("").errorDescription ?? ""
        XCTAssertTrue(message.contains("Server address is empty"), message)
        XCTAssertFalse(message.contains("Invalid LLM base URL"), message)
    }

    func testInvalidBaseURL_whitespaceOnly_saysAddressIsEmpty() {
        let message = LLMClientError.invalidBaseURL("   \n\t ").errorDescription ?? ""
        XCTAssertTrue(message.contains("Server address is empty"), message)
    }

    /// The out-of-memory envelope must be replaced by something actionable AND
    /// must name the model — the raw envelope buries it mid-sentence.
    func testBadHTTPStatus_modelLoadFailure_namesTheQuotedModel() {
        let body = #"""
        {"error":{"type":"model_load_failed","message":"Failed to load LLM 'google/gemma-4-26b-a4b': Error: Model loading was stopped due to insufficient system resources."}}
        """#
        let message = LLMClientError.badHTTPStatus(500, body).errorDescription ?? ""
        XCTAssertTrue(message.contains("Couldn't load 'google/gemma-4-26b-a4b'"), message)
        XCTAssertTrue(message.contains("free memory"), message)
        XCTAssertFalse(message.contains("HTTP 500"),
                       "the raw envelope wrapper must be replaced, not appended: \(message)")
    }

    func testBadHTTPStatus_modelLoadFailure_withoutQuotedName_stillActionable() {
        // No apostrophe anywhere → `quotedModelName` returns nil → generic arm.
        let body = #"{"error":{"type":"model_load_failed","message":"insufficient system resources"}}"#
        let message = LLMClientError.badHTTPStatus(500, body).errorDescription ?? ""
        XCTAssertTrue(message.contains("Couldn't load the model"), message)
        XCTAssertTrue(message.contains("free memory"), message)
    }

    /// Ordering pin: the auth branch is tested BEFORE the model-load branch, so
    /// a 401 whose body happens to mention a load failure still tells the user
    /// about their token.
    func testBadHTTPStatus_401_beatsTheModelLoadClassifier() {
        let body = #"{"error":{"type":"model_load_failed","message":"Failed to load LLM 'x'"}}"#
        let message = LLMClientError.badHTTPStatus(401, body).errorDescription ?? ""
        XCTAssertTrue(message.contains("Authentication required"), message)
        XCTAssertFalse(message.contains("Couldn't load"), message)
    }

    /// A body merely mentioning "load" without a qualifier is NOT resource
    /// exhaustion — it must fall through to the verbatim HTTP arm.
    func testBadHTTPStatus_unrelatedLoadWording_isNotMisclassified() {
        let message = LLMClientError
            .badHTTPStatus(500, "failed to load file from disk")
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("HTTP 500"), message)
        XCTAssertTrue(message.contains("failed to load file from disk"), message)
        XCTAssertFalse(message.contains("free memory"), message)
    }

    // MARK: - EmbeddingConfig: per-model prompt table
    //
    // Mismatched prefixes silently degrade recall (the model lands in a
    // different region of the embedding space), so the whole table is pinned.

    func testPrefixes_nomicFamily() {
        let config = embeddingConfig(model: "text-embedding-nomic-embed-text-v1.5")
        XCTAssertEqual(config.documentPrefix, "search_document: ")
        XCTAssertEqual(config.queryPrefix, "search_query: ")
    }

    func testPrefixes_nomicHuggingFaceSpelling_resolvesBySubstring() {
        let config = embeddingConfig(model: "nomic-ai/nomic-embed-text-v1.5")
        XCTAssertEqual(config.documentPrefix, "search_document: ")
        XCTAssertEqual(config.queryPrefix, "search_query: ")
    }

    func testPrefixes_mxbai_isQueryOnly() {
        let config = embeddingConfig(model: "mixedbread-ai/mxbai-embed-large-v1")
        XCTAssertEqual(config.documentPrefix, "")
        XCTAssertEqual(
            config.queryPrefix,
            "Represent this sentence for searching relevant passages: ")
    }

    func testPrefixes_multilingualE5_isSymmetricPassageQuery() {
        let config = embeddingConfig(model: "intfloat/multilingual-e5-large")
        XCTAssertEqual(config.documentPrefix, "passage: ")
        XCTAssertEqual(config.queryPrefix, "query: ")
    }

    func testPrefixes_bareE5Prefix_matchesViaHasPrefix() {
        let config = embeddingConfig(model: "e5-base-v2")
        XCTAssertEqual(config.documentPrefix, "passage: ")
        XCTAssertEqual(config.queryPrefix, "query: ")
    }

    func testPrefixes_namespacedE5_matchesViaSlashForm() {
        let config = embeddingConfig(model: "intfloat/e5-large-v2")
        XCTAssertEqual(config.documentPrefix, "passage: ")
        XCTAssertEqual(config.queryPrefix, "query: ")
    }

    func testPrefixes_bgeFamily_hasNoPrefixes() {
        for name in ["BAAI/bge-m3", "bge-large-en-v1.5", "bge-base-en"] {
            let config = embeddingConfig(model: name)
            XCTAssertEqual(config.documentPrefix, "", name)
            XCTAssertEqual(config.queryPrefix, "", name)
        }
    }

    func testPrefixes_graniteFamily_hasNoPrefixes() {
        let config = embeddingConfig(model: "ibm-granite/granite-embedding-278m-multilingual")
        XCTAssertEqual(config.documentPrefix, "")
        XCTAssertEqual(config.queryPrefix, "")
    }

    /// Unknown models assume nomic-style — LM Studio's most common preset.
    func testPrefixes_unknownModel_fallsBackToNomicStyle() {
        let config = embeddingConfig(model: "some-vendor/mystery-embed-v9")
        XCTAssertEqual(config.documentPrefix, "search_document: ")
        XCTAssertEqual(config.queryPrefix, "search_query: ")
    }

    func testPrefixes_matchIsCaseInsensitive() {
        let config = embeddingConfig(model: "MixedBread-AI/MXBAI-Embed-Large-V1")
        XCTAssertEqual(config.documentPrefix, "")
        XCTAssertTrue(config.queryPrefix.hasPrefix("Represent this sentence"))
    }

    // MARK: - EmbeddingConfig: validating + Codable inits

    func testValidatingInit_acceptsWellFormedInput() {
        let config = EmbeddingConfig(
            validating: "http://127.0.0.1:1234", modelName: "m", batchSize: 4, requestTimeout: 2)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.batchSize, 4)
        XCTAssertEqual(config?.requestTimeout, 2)
    }

    func testValidatingInit_rejectsEmptyModelName() {
        XCTAssertNil(EmbeddingConfig(validating: "http://127.0.0.1:1234", modelName: ""))
    }

    func testValidatingInit_rejectsNonPositiveBatchSize() {
        XCTAssertNil(EmbeddingConfig(
            validating: "http://127.0.0.1:1234", modelName: "m", batchSize: 0))
        XCTAssertNil(EmbeddingConfig(
            validating: "http://127.0.0.1:1234", modelName: "m", batchSize: -1))
    }

    func testValidatingInit_rejectsNonPositiveTimeout() {
        XCTAssertNil(EmbeddingConfig(
            validating: "http://127.0.0.1:1234", modelName: "m", requestTimeout: 0))
        XCTAssertNil(EmbeddingConfig(
            validating: "http://127.0.0.1:1234", modelName: "m", requestTimeout: -5))
    }

    func testCodable_roundTripsThroughValidation() throws {
        let original = embeddingConfig(model: "bge-m3")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EmbeddingConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// A corrupted persisted config must surface as a decode failure so
    /// `StoreConfiguration` falls back to the default rather than shipping an
    /// invariant-violating config into the builder.
    func testCodable_corruptedBatchSize_throwsDecodingError() {
        let json = #"""
        {"baseURLString":"http://127.0.0.1:1234","modelName":"m","batchSize":0,"requestTimeout":60}
        """#
        XCTAssertThrowsError(
            try JSONDecoder().decode(EmbeddingConfig.self, from: Data(json.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError, "got \(type(of: error))")
        }
    }

    func testCodable_corruptedEmptyModelName_throwsDecodingError() {
        let json = #"""
        {"baseURLString":"http://127.0.0.1:1234","modelName":"","batchSize":8,"requestTimeout":60}
        """#
        XCTAssertThrowsError(
            try JSONDecoder().decode(EmbeddingConfig.self, from: Data(json.utf8)))
    }

    func testDefaultNomicLMStudio_isCoherent() {
        let config = EmbeddingConfig.defaultNomicLMStudio
        XCTAssertEqual(config.baseURLString, "http://127.0.0.1:1234")
        XCTAssertEqual(config.documentPrefix, "search_document: ")
        XCTAssertGreaterThan(config.batchSize, 0)
        XCTAssertGreaterThan(config.requestTimeout, 0)
    }

    // MARK: - EmbeddingClientError.errorDescription — non-auth arms

    func testEmbeddingErrorDescriptions_carryTheirDistinguishingDetail() {
        XCTAssertTrue(
            (EmbeddingClientError.invalidResponse("garbled").errorDescription ?? "")
                .contains("garbled"))
        XCTAssertTrue(
            (EmbeddingClientError.requestEncodingFailed("bad encode").errorDescription ?? "")
                .contains("bad encode"))
        let dim = EmbeddingClientError.dimensionMismatch(expected: 768, got: 384)
            .errorDescription ?? ""
        XCTAssertTrue(dim.contains("768") && dim.contains("384"), dim)
        XCTAssertTrue(
            (EmbeddingClientError.modelNotLoaded("nomic").errorDescription ?? "")
                .contains("nomic"))
        XCTAssertTrue(
            (EmbeddingClientError.timeout.errorDescription ?? "").lowercased()
                .contains("timed out"))
        XCTAssertTrue(
            (EmbeddingClientError.transportError("connection reset").errorDescription ?? "")
                .contains("connection reset"))
        XCTAssertTrue(
            (EmbeddingClientError.serverUnreachable("refused").errorDescription ?? "")
                .contains("refused"))
    }

    func testEmbeddingHTTPError_emptyMessage_omitsTheColonFragment() {
        let withEmpty = EmbeddingClientError.httpError(status: 503, message: "")
            .errorDescription ?? ""
        let withNil = EmbeddingClientError.httpError(status: 503, message: nil)
            .errorDescription ?? ""
        XCTAssertEqual(withEmpty, "Embedding HTTP 503.")
        XCTAssertEqual(withNil, "Embedding HTTP 503.")
    }

    /// The detail is capped at 160 chars so a giant HTML error page can't take
    /// over the banner.
    func testEmbeddingErrorDescription_truncatesLongDetail() {
        let long = String(repeating: "x", count: 400)
        let description = EmbeddingClientError.invalidResponse(long).errorDescription ?? ""
        XCTAssertLessThan(description.count, 220, String(description.prefix(80)))
        XCTAssertFalse(description.contains(long))
    }

    func testEmbeddingServerUnreachable_isTerminal() {
        // Complements the existing isTerminal pin, which omitted this case.
        XCTAssertTrue(EmbeddingClientError.serverUnreachable("x").isTerminal)
    }

    // MARK: - LMStudioEmbeddingClient: static classifiers

    func testClassifyTransportError_cancelled_staysTypedForStaticCallers() {
        // The instance path intercepts URLError.cancelled and throws
        // CancellationError; the STATIC helper classifies conservatively so
        // callers still see a typed EmbeddingClientError.
        let classified = LMStudioEmbeddingClient
            .classifyTransportError(URLError(.cancelled))
        guard case .transportError(let detail) = classified else {
            return XCTFail("Expected transportError, got \(classified)")
        }
        XCTAssertEqual(detail, "cancelled")
    }

    func testClassifyTransportError_dnsFamily_isTerminalServerUnreachable() {
        for code in [URLError.Code.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                     .notConnectedToInternet] {
            let classified = LMStudioEmbeddingClient
                .classifyTransportError(URLError(code))
            guard case .serverUnreachable = classified else {
                return XCTFail("Expected serverUnreachable for \(code), got \(classified)")
            }
            XCTAssertTrue(classified.isTerminal,
                          "an unreachable server must short-circuit the retry loop")
        }
    }

    func testClassifyTransportError_nonURLError_fallsBackToTransportError() {
        let classified = LMStudioEmbeddingClient
            .classifyTransportError(PrivateProbeError.boom)
        guard case .transportError = classified else {
            return XCTFail("Expected transportError, got \(classified)")
        }
    }

    func testClassifyHTTPError_unparseableBody_usesRawStringAsMessage() {
        let classified = LMStudioEmbeddingClient.classifyHTTPError(
            status: 502, data: Data("<html>bad gateway</html>".utf8), modelName: "m")
        guard case .httpError(let status, let message) = classified else {
            return XCTFail("Expected httpError, got \(classified)")
        }
        XCTAssertEqual(status, 502)
        XCTAssertEqual(message, "<html>bad gateway</html>")
    }

    /// The heuristic is `model` OR `not found` — a 404 saying only "not found"
    /// still means the named model isn't loaded.
    func testClassifyHTTPError_404NotFoundWithoutTheWordModel_isModelNotLoaded() {
        let classified = LMStudioEmbeddingClient.classifyHTTPError(
            status: 404, data: Data(#"{"error":{"message":"Not Found"}}"#.utf8),
            modelName: "nomic")
        guard case .modelNotLoaded(let name) = classified else {
            return XCTFail("Expected modelNotLoaded, got \(classified)")
        }
        XCTAssertEqual(name, "nomic")
    }

    func testClassifyHTTPError_404EmptyBody_fallsThroughToHTTPError() {
        let classified = LMStudioEmbeddingClient.classifyHTTPError(
            status: 404, data: Data(), modelName: "nomic")
        guard case .httpError(let status, _) = classified else {
            return XCTFail("Expected httpError for an empty 404 body, got \(classified)")
        }
        XCTAssertEqual(status, 404)
    }

    func testDecode_zeroExpectedWithEmptyData_reportsEmptyResponse() {
        // Reachable only through the static API — `embed` short-circuits on an
        // empty input array before the network call.
        XCTAssertThrowsError(
            try LMStudioEmbeddingClient.decode(
                data: Data(#"{"data":[]}"#.utf8), expectedCount: 0)
        ) { error in
            guard let typed = error as? EmbeddingClientError else {
                return XCTFail("Expected EmbeddingClientError, got \(error)")
            }
            guard case .invalidResponse(let detail) = typed else {
                return XCTFail("Expected invalidResponse, got \(typed)")
            }
            XCTAssertTrue(detail.contains("Empty response data"), detail)
        }
    }

    func testDecode_singleItem_returnsIt() throws {
        let vectors = try LMStudioEmbeddingClient.decode(
            data: Data(#"{"data":[{"embedding":[0.25,0.5],"index":0}]}"#.utf8),
            expectedCount: 1)
        XCTAssertEqual(vectors, [[0.25, 0.5]])
    }

    // MARK: - LMStudioEmbeddingClient: transport + logging paths

    func testEmbed_nonHTTPResponse_throwsInvalidResponse() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .plainResponse(Data(#"{"data":[]}"#.utf8))
        let client = LMStudioEmbeddingClient(
            session: session, tokenResolver: StubLLMTokenResolver())
        do {
            _ = try await client.embed(texts: ["a"], config: embeddingConfig())
            XCTFail("Expected invalidResponse")
        } catch let error as EmbeddingClientError {
            guard case .invalidResponse(let detail) = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("Non-HTTP"), detail)
        } catch {
            XCTFail("Expected EmbeddingClientError, got \(type(of: error))")
        }
    }

    func testEmbed_withLogger_recordsRequestAndResponse() async throws {
        let logURL = tempDir.appendingPathComponent("embed_ok.json")
        let logger = NetworkLogger(logURL: logURL)
        let session = ScriptedNetworkSession()
        session.dataResult = .http(200, Data(#"{"data":[{"embedding":[1.0],"index":0}]}"#.utf8))
        let client = LMStudioEmbeddingClient(
            session: session, tokenResolver: StubLLMTokenResolver())

        _ = try await client.embed(
            texts: ["a"], config: embeddingConfig(), logger: logger, stepID: "step-7")

        let records = try readNetworkRecords(at: logURL)
        XCTAssertEqual(records.count, 2, "one request + one response record per call")
        XCTAssertEqual(records.first?.direction, .request)
        XCTAssertEqual(records.first?.stepID, "step-7")
        XCTAssertEqual(records.last?.direction, .response)
        XCTAssertEqual(records.last?.statusCode, 200)
        XCTAssertNil(records.last?.errorMessage)
    }

    func testEmbed_withLogger_transportFailure_recordsErrorRecord() async {
        let logURL = tempDir.appendingPathComponent("embed_timeout.json")
        let logger = NetworkLogger(logURL: logURL)
        let session = ScriptedNetworkSession()
        session.dataResult = .failure(URLError(.timedOut))
        let client = LMStudioEmbeddingClient(
            session: session, tokenResolver: StubLLMTokenResolver())

        do {
            _ = try await client.embed(
                texts: ["a"], config: embeddingConfig(), logger: logger, stepID: nil)
            XCTFail("Expected timeout")
        } catch let error as EmbeddingClientError {
            guard case .timeout = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        } catch {
            XCTFail("Expected EmbeddingClientError, got \(type(of: error))")
        }

        let records = (try? readNetworkRecords(at: logURL)) ?? []
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.last?.statusCode, 0, "no HTTP status on a transport failure")
        XCTAssertNotNil(records.last?.errorMessage)
    }

    func testEmbed_withLogger_cancellation_logsCancellationAndRethrowsIt() async {
        let logURL = tempDir.appendingPathComponent("embed_cancel.json")
        let logger = NetworkLogger(logURL: logURL)
        let session = ScriptedNetworkSession()
        session.dataResult = .failure(URLError(.cancelled))
        let client = LMStudioEmbeddingClient(
            session: session, tokenResolver: StubLLMTokenResolver())

        do {
            _ = try await client.embed(
                texts: ["a"], config: embeddingConfig(), logger: logger, stepID: nil)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Correct — the cooperative-cancellation tree must unwind, not retry.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let records = (try? readNetworkRecords(at: logURL)) ?? []
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.last?.statusCode, 0)
    }

    func testEmbed_withLogger_httpErrorStillRecordsTheBody() async {
        let logURL = tempDir.appendingPathComponent("embed_500.json")
        let logger = NetworkLogger(logURL: logURL)
        let session = ScriptedNetworkSession()
        session.dataResult = .http(500, Data(#"{"error":{"message":"OOM"}}"#.utf8))
        let client = LMStudioEmbeddingClient(
            session: session, tokenResolver: StubLLMTokenResolver())

        _ = try? await client.embed(
            texts: ["a"], config: embeddingConfig(), logger: logger, stepID: nil)

        let records = (try? readNetworkRecords(at: logURL)) ?? []
        XCTAssertEqual(records.last?.statusCode, 500)
        XCTAssertTrue(records.last?.body?.contains("OOM") == true,
                      "the response body is logged before classification throws")
    }

    // MARK: - LLMConnectionChecker: uncovered transport arms

    func testProbeOutcome_nonHTTPResponse_isOtherTransport() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .plainResponse(Data())
        let outcome = await LLMConnectionChecker.probeOutcome(
            baseURL: "http://localhost:1234",
            session: session,
            resolver: StubLLMTokenResolver([:]))
        guard case .otherTransport(let detail) = outcome else {
            return XCTFail("Expected otherTransport, got \(outcome)")
        }
        XCTAssertEqual(detail, "non-HTTP response")
    }

    func testCheckWithMessage_nonHTTPResponse_namesTheProviderAndURL() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .plainResponse(Data())
        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: "http://localhost:1234",
            session: session,
            resolver: StubLLMTokenResolver([:]))
        XCTAssertFalse(result.isReachable)
        XCTAssertNil(result.statusCode)
        XCTAssertTrue(result.message.contains("LM Studio"), result.message)
        XCTAssertTrue(result.message.contains("http://localhost:1234"), result.message)
    }

    /// A non-`URLError` (e.g. a proxy shim throwing its own type) must not fall
    /// off the classifier — it lands in `.otherTransport` with its description.
    func testProbeOutcome_nonURLError_isOtherTransport() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .failure(PrivateProbeError.boom)
        let outcome = await LLMConnectionChecker.probeOutcome(
            baseURL: "http://localhost:1234",
            session: session,
            resolver: StubLLMTokenResolver([:]))
        guard case .otherTransport = outcome else {
            return XCTFail("Expected otherTransport, got \(outcome)")
        }
    }

    func testProbeOutcome_connectionRefusedAndTimeout_haveTypedCases() async {
        let refused = ScriptedNetworkSession()
        refused.dataResult = .failure(URLError(.cannotConnectToHost))
        let refusedOutcome = await LLMConnectionChecker.probeOutcome(
            baseURL: "http://localhost:1234", session: refused,
            resolver: StubLLMTokenResolver([:]))
        guard case .connectionRefused = refusedOutcome else {
            return XCTFail("Expected connectionRefused, got \(refusedOutcome)")
        }

        let slow = ScriptedNetworkSession()
        slow.dataResult = .failure(URLError(.timedOut))
        let slowOutcome = await LLMConnectionChecker.probeOutcome(
            baseURL: "http://localhost:1234", session: slow,
            resolver: StubLLMTokenResolver([:]))
        guard case .timedOut = slowOutcome else {
            return XCTFail("Expected timedOut, got \(slowOutcome)")
        }

        let offline = ScriptedNetworkSession()
        offline.dataResult = .failure(URLError(.notConnectedToInternet))
        let offlineOutcome = await LLMConnectionChecker.probeOutcome(
            baseURL: "http://localhost:1234", session: offline,
            resolver: StubLLMTokenResolver([:]))
        guard case .offline = offlineOutcome else {
            return XCTFail("Expected offline, got \(offlineOutcome)")
        }
    }

    /// `statusCode` is what the settings UI branches on to show "Authentication
    /// required" — every connection-level outcome must report `nil`, never a
    /// synthesized code.
    func testProbeOutcome_statusCode_isNilForEveryNonHTTPCase() {
        let nonHTTP: [LLMProbeOutcome] = [
            .dnsLookupFailed, .connectionRefused, .timedOut, .offline,
            .otherTransport("x"), .invalidURL,
        ]
        for outcome in nonHTTP {
            XCTAssertNil(outcome.statusCode, "\(outcome) must not report a status")
        }
        XCTAssertEqual(LLMProbeOutcome.http(401).statusCode, 401)
    }

    func testProbe_backCompatWrapper_returnsNilOnTransportFailure() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .failure(URLError(.cannotFindHost))
        let status = await LLMConnectionChecker.probe(
            baseURL: "http://localhost:1234", session: session,
            resolver: StubLLMTokenResolver([:]))
        XCTAssertNil(status)
    }

    func testCheck_returnsFalseWhenTransportFails() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .failure(URLError(.cannotConnectToHost))
        let reachable = await LLMConnectionChecker.check(
            baseURL: "http://localhost:1234", session: session,
            resolver: StubLLMTokenResolver([:]))
        XCTAssertFalse(reachable)
    }

    func testCheck_ollamaProvider_204_isStillReachable() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .http(204, Data())
        let reachable = await LLMConnectionChecker.check(
            baseURL: "http://localhost:11434", provider: .ollama, session: session,
            resolver: StubLLMTokenResolver([:]))
        XCTAssertTrue(reachable, "any 2xx counts, not just 200")
    }

    /// `URL(string:)` rejecting the empty string is platform-dependent, so pin
    /// the OBSERVABLE contract (unreachable, no status, a message the user can
    /// read) rather than which branch produced it.
    func testCheckWithMessage_emptyBaseURL_isUnreachableWithNoStatus() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .http(200, Data())
        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: "", session: session, resolver: StubLLMTokenResolver([:]))
        XCTAssertFalse(result.isReachable)
        XCTAssertNil(result.statusCode)
        XCTAssertFalse(result.message.isEmpty)
    }

    // MARK: - SSEEventParser: undecodable-payload arms

    /// LM Studio's `Stats.inputTokens` is non-optional, so a stats object
    /// missing it fails to decode — the frame must degrade to `.ignored`, never
    /// crash or fabricate a usage figure.
    /// An EMPTY stats object is not undecodable — every field is optional, so it
    /// decodes to all-defaults and the stream really did end. Reporting the
    /// terminal event is right; the zeros are what "the server sent no counts"
    /// looks like, and `TokenUsage` has no other way to say it.
    func testSSE_chatEndWithEmptyStats_stillReportsTheTerminalEvent() {
        var parser = SSEEventParser()
        _ = parser.parse(line: "event: chat.end")

        guard case .chatEnd(let usage, let prefill)? = parser.parse(line: #"data: {"stats": {}}"#)
        else { return XCTFail("an empty stats object is still a chat.end") }

        XCTAssertEqual(usage, TokenUsage(inputTokens: 0, outputTokens: 0))
        XCTAssertNil(prefill, "no prefill figures were sent")
    }

    /// Genuinely unparseable bytes, by contrast, are dropped — a half-written
    /// frame must not be mistaken for a completed stream.
    func testSSE_chatEndWithMalformedPayload_isIgnored() {
        for payload in [#"data: {"stats": "#, "data: not-json", "data: [1,2,3]"] {
            var parser = SSEEventParser()
            _ = parser.parse(line: "event: chat.end")
            let result = parser.parse(line: payload)
            guard case .ignored? = result else {
                return XCTFail("Expected ignored for \(payload), got \(String(describing: result))")
            }
        }
    }

    func testSSE_chatEndNestedResultShape_isDecoded() {
        var parser = SSEEventParser()
        _ = parser.parse(line: "event: chat.end")
        let json = #"{"type":"chat.end","result":{"stats":{"input_tokens":11,"total_output_tokens":3}}}"#
        guard case .chatEnd(let usage, _)? = parser.parse(line: "data: \(json)") else {
            return XCTFail("Expected chatEnd for the nested result shape")
        }
        XCTAssertEqual(usage, TokenUsage(inputTokens: 11, outputTokens: 3))
    }

    func testSSE_messageDeltaWithNonObjectPayload_isIgnored() {
        var parser = SSEEventParser()
        _ = parser.parse(line: "event: message.delta")
        guard case .ignored? = parser.parse(line: "data: [1,2,3]") else {
            return XCTFail("Expected ignored for a non-object payload")
        }
    }

    func testSSE_reasoningDeltaWithNonObjectPayload_isIgnored() {
        var parser = SSEEventParser()
        _ = parser.parse(line: "event: reasoning.delta")
        guard case .ignored? = parser.parse(line: "data: \"just a string\"") else {
            return XCTFail("Expected ignored for a non-object payload")
        }
    }

    /// The error frame is the one event type that must never silently vanish —
    /// an undecodable body still surfaces a generic error.
    func testSSE_errorFrameWithUndecodableBody_stillSurfacesAnError() {
        var parser = SSEEventParser()
        _ = parser.parse(line: "event: error")
        guard case .error(let message)? = parser.parse(line: "data: [\"oops\"]") else {
            return XCTFail("Expected error for an undecodable error frame")
        }
        XCTAssertEqual(message, "Stream error")
    }

    func testSSE_progressFrameMissingProgressField_isIgnored() {
        var parser = SSEEventParser()
        _ = parser.parse(line: "event: prompt_processing.progress")
        guard case .ignored? = parser.parse(line: "data: {}") else {
            return XCTFail("Expected ignored when `progress` is absent")
        }
    }

    /// A `data:` frame arriving before any `event:` header falls to the default
    /// arm (`currentEventType ?? ""`).
    func testSSE_dataBeforeAnyEventHeader_isIgnored() {
        var parser = SSEEventParser()
        guard case .ignored? = parser.parse(line: #"data: {"content":"orphan"}"#) else {
            return XCTFail("Expected ignored with no event type in scope")
        }
    }

    func testSSE_eventAndDataLinesTolerateSurroundingWhitespace() {
        var parser = SSEEventParser()
        XCTAssertNil(parser.parse(line: "   event:   message.delta   "))
        guard case .contentDelta(let text)? =
                parser.parse(line: "   data:   {\"content\":\"padded\"}   ") else {
            return XCTFail("Expected contentDelta despite padding")
        }
        XCTAssertEqual(text, "padded")
    }

    func testSSE_dataWithOnlyWhitespacePayload_returnsNil() {
        var parser = SSEEventParser()
        _ = parser.parse(line: "event: message.delta")
        XCTAssertNil(parser.parse(line: "data:      "))
    }

    // MARK: - OllamaClient: transport-failure arms

    func testOllamaStream_invalidBaseURL_throwsBeforeAnyRequest() async {
        let session = ScriptedNetworkSession()
        session.bytesResult = .failure(PrivateProbeError.boom)
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let outcome = await drainOllamaStream(
            client: client, config: ollamaConfig(baseURL: ""))
        guard let error = outcome.error as? LLMClientError else {
            return XCTFail("Expected LLMClientError, got \(String(describing: outcome.error))")
        }
        guard case .invalidBaseURL = error else {
            return XCTFail("Expected invalidBaseURL, got \(error)")
        }
        XCTAssertFalse(session.sawBytesRequest, "the guard must fire before the request")
    }

    func testOllamaStream_nonHTTPResponse_throwsMissingResponse() async {
        let session = ScriptedNetworkSession()
        session.bytesResult = .plainResponse("")
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let outcome = await drainOllamaStream(client: client, config: ollamaConfig())
        guard let error = outcome.error as? LLMClientError else {
            return XCTFail("Expected LLMClientError, got \(String(describing: outcome.error))")
        }
        guard case .missingResponse = error else {
            return XCTFail("Expected missingResponse, got \(error)")
        }
    }

    func testOllamaStream_transportThrow_propagatesVerbatim() async {
        let session = ScriptedNetworkSession()
        session.bytesResult = .failure(URLError(.networkConnectionLost))
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let outcome = await drainOllamaStream(client: client, config: ollamaConfig())
        XCTAssertEqual((outcome.error as? URLError)?.code, URLError.Code.networkConnectionLost)
    }

    func testOllamaStream_errorStatusWithEmptyBody_reportsNilBody() async {
        let session = ScriptedNetworkSession()
        session.bytesResult = .http(500, "")
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let outcome = await drainOllamaStream(client: client, config: ollamaConfig())
        guard let error = outcome.error as? LLMClientError else {
            return XCTFail("Expected LLMClientError, got \(String(describing: outcome.error))")
        }
        guard case .badHTTPStatus(let code, let body) = error else {
            return XCTFail("Expected badHTTPStatus, got \(error)")
        }
        XCTAssertEqual(code, 500)
        XCTAssertNil(body, "an empty error body must be nil, not an empty string")
    }

    /// The error-body reader stops once it has enough to be actionable — a
    /// multi-megabyte HTML error page must not be buffered whole.
    func testOllamaStream_hugeErrorBody_isCappedNotBufferedWhole() async {
        let line = String(repeating: "E", count: 900)
        let session = ScriptedNetworkSession()
        session.bytesResult = .http(503, "\(line)\n\(line)\n\(line)")
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let outcome = await drainOllamaStream(client: client, config: ollamaConfig())
        guard let error = outcome.error as? LLMClientError else {
            return XCTFail("Expected LLMClientError, got \(String(describing: outcome.error))")
        }
        guard case .badHTTPStatus(let code, let body) = error else {
            return XCTFail("Expected badHTTPStatus, got \(error)")
        }
        XCTAssertEqual(code, 503)
        XCTAssertNotNil(body)
        XCTAssertLessThan(body?.count ?? .max, line.count * 3,
                          "the reader must break out before draining every line")
    }

    func testOllamaFetchModels_nonHTTPResponse_throwsMissingResponse() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .plainResponse(Data(#"{"models":[]}"#.utf8))
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        do {
            _ = try await client.fetchModels(config: ollamaConfig(), visionOnly: false)
            XCTFail("Expected missingResponse")
        } catch let error as LLMClientError {
            guard case .missingResponse = error else {
                return XCTFail("Expected missingResponse, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMClientError, got \(type(of: error))")
        }
    }

    func testOllamaFetchEmbeddingModels_invalidBaseURL_throws() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .http(200, Data(#"{"models":[]}"#.utf8))
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        do {
            _ = try await client.fetchEmbeddingModels(config: ollamaConfig(baseURL: ""))
            XCTFail("Expected invalidBaseURL")
        } catch let error as LLMClientError {
            guard case .invalidBaseURL = error else {
                return XCTFail("Expected invalidBaseURL, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMClientError, got \(type(of: error))")
        }
    }

    /// Every metadata probe swallows transport failures and reports
    /// "undeterminable" — `ContextBudgetPolicy` must never warn on a guess, and
    /// the vision fallback must never assume vision.
    func testOllamaMetadataProbes_transportFailure_areAllUndeterminable() async {
        let session = ScriptedNetworkSession()
        session.dataResult = .failure(URLError(.cannotConnectToHost))
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let config = ollamaConfig()

        let vision = await client.modelSupportsVision(config: config)
        let context = await client.modelContextLength(config: config)
        let details = await client.modelLoadDetails(config: config)

        XCTAssertNil(vision)
        XCTAssertNil(context)
        XCTAssertNil(details)
    }

    /// `/api/ps` reporting a zero window is not a window — it must fall through
    /// to the declared `num_ctx` rather than pinning the budget at 0.
    func testOllamaModelContextLength_zeroLoadedWindow_fallsBackToNumCtx() async {
        let session = PathRoutedNetworkSession(bodies: [
            "/api/show": #"{"parameters":"num_ctx 16384"}"#,
            "/api/ps": #"{"models":[{"model":"gpt-oss:20b","context_length":0}]}"#,
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let result = await client.modelContextLength(config: ollamaConfig())
        XCTAssertEqual(result, 16384)
    }

    func testOllamaModelContextLength_psProbeFails_stillReadsNumCtx() async {
        let session = PathRoutedNetworkSession(
            bodies: ["/api/show": #"{"parameters":"num_ctx 2048"}"#],
            failingPaths: ["/api/ps"])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let result = await client.modelContextLength(config: ollamaConfig())
        XCTAssertEqual(result, 2048)
    }

    // MARK: - OllamaClient: NetworkLogger plumbing

    func testOllamaStream_withLogger_writesRequestAndResponseRecords() async throws {
        let logURL = tempDir.appendingPathComponent("ollama_ok.json")
        let logger = NetworkLogger(logURL: logURL)
        let ndjson = """
        {"message":{"thinking":"weighing options"},"done":false}
        {"message":{"content":"final answer"},"done":false}
        {"done":true,"prompt_eval_count":21,"eval_count":5}
        """
        let session = ScriptedNetworkSession()
        session.bytesResult = .http(200, ndjson)
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())

        let outcome = await drainOllamaStream(
            client: client, config: ollamaConfig(), logger: logger,
            stepID: "step-9", roleName: "Software Engineer")

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.content, "final answer")

        let records = try readNetworkRecords(at: logURL)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.direction, .request)
        XCTAssertEqual(records.first?.httpMethod, "POST")
        XCTAssertEqual(records.first?.stepID, "step-9")
        XCTAssertEqual(records.first?.roleName, "Software Engineer")

        let response = try XCTUnwrap(records.last)
        XCTAssertEqual(response.direction, .response)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.inputTokens, 21)
        XCTAssertEqual(response.outputTokens, 5)
        XCTAssertEqual(response.correlationID, records.first?.correlationID,
                       "request and response must share a correlation id")
        let body = try XCTUnwrap(response.body)
        XCTAssertTrue(body.contains("[reasoning]"), body)
        XCTAssertTrue(body.contains("weighing options"), body)
        XCTAssertTrue(body.contains("final answer"), body)
    }

    func testOllamaStream_withLogger_contentOnly_omitsTheReasoningBlock() async throws {
        let logURL = tempDir.appendingPathComponent("ollama_content_only.json")
        let logger = NetworkLogger(logURL: logURL)
        let session = ScriptedNetworkSession()
        session.bytesResult = .http(200, """
        {"message":{"content":"plain"},"done":false}
        {"done":true}
        """)
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())

        _ = await drainOllamaStream(client: client, config: ollamaConfig(), logger: logger)

        let records = try readNetworkRecords(at: logURL)
        let body = try XCTUnwrap(records.last?.body)
        XCTAssertEqual(body, "plain")
        XCTAssertFalse(body.contains("[reasoning]"))
    }

    func testOllamaStream_withLogger_emptyStream_recordsNilBody() async throws {
        let logURL = tempDir.appendingPathComponent("ollama_empty.json")
        let logger = NetworkLogger(logURL: logURL)
        let session = ScriptedNetworkSession()
        session.bytesResult = .http(200, "")
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())

        _ = await drainOllamaStream(client: client, config: ollamaConfig(), logger: logger)

        let records = try readNetworkRecords(at: logURL)
        XCTAssertEqual(records.count, 2)
        XCTAssertNil(records.last?.body, "nothing streamed → no body, not an empty string")
    }

    func testOllamaStream_withLogger_httpError_recordsZeroStatusErrorRecord() async throws {
        let logURL = tempDir.appendingPathComponent("ollama_500.json")
        let logger = NetworkLogger(logURL: logURL)
        let session = ScriptedNetworkSession()
        session.bytesResult = .http(500, #"{"error":"internal"}"#)
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())

        let outcome = await drainOllamaStream(
            client: client, config: ollamaConfig(), logger: logger)
        XCTAssertNotNil(outcome.error)

        let records = try readNetworkRecords(at: logURL)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.last?.statusCode, 0,
                       "the catch arm records a synthetic 0 — the HTTP code is inside the error")
        XCTAssertNotNil(records.last?.errorMessage)
    }

    func testOllamaStream_invalidBaseURL_withLogger_writesNothing() async {
        let logURL = tempDir.appendingPathComponent("ollama_no_request.json")
        let logger = NetworkLogger(logURL: logURL)
        let session = ScriptedNetworkSession()
        session.bytesResult = .http(200, "")
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())

        let outcome = await drainOllamaStream(
            client: client, config: ollamaConfig(baseURL: ""), logger: logger)

        XCTAssertNotNil(outcome.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path),
                       "a request that never left must not produce a log record")
    }

    // MARK: - OllamaClient: pure parse corners

    func testParseShowLoadFields_malformedJSON_returnsEmpty() {
        XCTAssertTrue(OllamaClient.parseShowLoadFields(Data("not json".utf8)).isEmpty)
    }

    func testParseShowLoadFields_emptyStringDetails_areSkipped() {
        let body = #"""
        {"details":{"parameter_size":"","quantization_level":"","family":"","format":""},
         "capabilities":[],"parameters":"   \n  "}
        """#
        XCTAssertTrue(
            OllamaClient.parseShowLoadFields(Data(body.utf8)).isEmpty,
            "blank vendor strings must not render as empty rows")
    }

    func testParseShowLoadFields_partialDetails_onlyRendersWhatIsPresent() {
        let body = #"{"details":{"family":"llama"},"parameters":"num_ctx 4096"}"#
        let fields = OllamaClient.parseShowLoadFields(Data(body.utf8))
        XCTAssertEqual(fields.map(\.label),
                       ["Context length (num_ctx)", "Family", "Modelfile parameters"])
    }

    func testParseShowResponse_parametersNotAString_ignoresNumCtx() {
        let parsed = OllamaClient.parseShowResponse(Data(#"{"parameters":4096}"#.utf8))
        XCTAssertNil(parsed.modelfileNumCtx)
    }

    func testParseShowResponse_modelInfoNotAnObject_ignoresArchitectureMax() {
        let parsed = OllamaClient.parseShowResponse(Data(#"{"model_info":"nope"}"#.utf8))
        XCTAssertNil(parsed.architectureContextLength)
    }

    func testParseShowResponse_nonIntegerContextLength_isIgnored() {
        let parsed = OllamaClient.parseShowResponse(
            Data(#"{"model_info":{"llama.context_length":"many"}}"#.utf8))
        XCTAssertNil(parsed.architectureContextLength)
    }

    func testFormatBytes_negativeAndSubGigabyteValues() {
        XCTAssertEqual(OllamaClient.formatBytes(-1_500_000_000), "-1.5 GB")
        XCTAssertEqual(OllamaClient.formatBytes(120_000_000), "0.1 GB")
    }

    // MARK: - Ollama stream drain helper

    private struct OllamaStreamOutcome {
        var content = ""
        var thinking = ""
        var usage: TokenUsage?
        var error: Error?
    }

    private func drainOllamaStream(
        client: OllamaClient,
        config: LLMConfig,
        logger: NetworkLogger? = nil,
        stepID: String? = nil,
        roleName: String? = nil
    ) async -> OllamaStreamOutcome {
        let stream = client.streamChat(
            config: config,
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: [],
            logger: logger,
            stepID: stepID,
            roleName: roleName)
        var outcome = OllamaStreamOutcome()
        do {
            for try await event in stream {
                outcome.content += event.contentDelta
                outcome.thinking += event.thinkingDelta
                if let usage = event.tokenUsage { outcome.usage = usage }
            }
        } catch {
            outcome.error = error
        }
        return outcome
    }
}

// MARK: - Private doubles

/// Error type with no `URLError` relationship — drives the "not a URLError"
/// fall-through arms of the transport classifiers.
private enum PrivateProbeError: Error {
    case boom
}

/// One scripted outcome for `sessionData` and one for `sessionBytes`. Byte
/// streams are fabricated from a `data:` URL because `URLSession.AsyncBytes`
/// has no public initializer (house pattern).
private final class ScriptedNetworkSession: NetworkSession, @unchecked Sendable {

    enum DataResult {
        /// HTTP status + body.
        case http(Int, Data)
        /// A plain (non-HTTP) `URLResponse` — drives the `missingResponse` /
        /// `invalidResponse("Non-HTTP response")` arms.
        case plainResponse(Data)
        case failure(Error)
    }

    enum BytesResult {
        case http(Int, String)
        case plainResponse(String)
        case failure(Error)
    }

    var dataResult: DataResult = .http(200, Data())
    var bytesResult: BytesResult = .http(200, "")
    /// Read by the invalid-base-URL test to prove the guard fires BEFORE the
    /// request is ever issued.
    var sawBytesRequest = false

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "http://127.0.0.1")!
        switch dataResult {
        case .failure(let error):
            throw error
        case .http(let status, let body):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        case .plainResponse(let body):
            let response = URLResponse(
                url: url, mimeType: "application/json",
                expectedContentLength: body.count, textEncodingName: "utf-8")
            return (body, response)
        }
    }

    func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        sawBytesRequest = true
        let url = request.url ?? URL(string: "http://127.0.0.1")!
        switch bytesResult {
        case .failure(let error):
            throw error
        case .http(let status, let payload):
            let bytes = try await Self.makeBytes(payload)
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (bytes, response)
        case .plainResponse(let payload):
            let bytes = try await Self.makeBytes(payload)
            let response = URLResponse(
                url: url, mimeType: "application/x-ndjson",
                expectedContentLength: payload.count, textEncodingName: "utf-8")
            return (bytes, response)
        }
    }

    private static func makeBytes(_ payload: String) async throws -> URLSession.AsyncBytes {
        let dataURL = URL(string: "data:application/x-ndjson;base64,"
            + Data(payload.utf8).base64EncodedString())!
        let (bytes, _) = try await URLSession.shared.bytes(from: dataURL)
        return bytes
    }
}

/// Serves a canned body per URL path; unlisted paths (or any path in
/// `failingPaths`) throw, which is how the "probe failed" arms are driven.
private final class PathRoutedNetworkSession: NetworkSession, @unchecked Sendable {
    private let bodies: [String: String]
    private let failingPaths: Set<String>

    init(bodies: [String: String], failingPaths: Set<String> = []) {
        self.bodies = bodies
        self.failingPaths = failingPaths
    }

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        if failingPaths.contains(path) { throw URLError(.cannotConnectToHost) }
        guard let body = bodies[path] else { throw URLError(.unsupportedURL) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw URLError(.unsupportedURL)
    }
}

/// Implements ONLY the two `LLMClient` members that have no default, so every
/// assertion against it exercises the protocol extension.
private final class MinimalLLMClient: LLMClient, @unchecked Sendable {
    var streamCallCount = 0
    var lastStepID: String?
    var lastRoleName: String?

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        streamCallCount += 1
        lastStepID = stepID
        lastRoleName = roleName
        return AsyncThrowingStream<StreamEvent, Error> { continuation in
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] {
        []
    }
}
