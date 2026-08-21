import XCTest

@testable import NanoTeams

/// `OllamaClient` model listing (`/api/tags`) + metadata (`/api/show`) paths.
/// Wire-level via a canned `NetworkSession` double (house pattern — each test
/// file owns its private stub).
final class OllamaClientTests: XCTestCase {

    private func makeConfig(model: String = "gpt-oss:20b") -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: model)
    }

    private func makeClient(status: Int = 200, body: String) -> OllamaClient {
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:11434")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
        return OllamaClient(
            session: StubOllamaNetworkSession(response: response, data: Data(body.utf8)),
            tokenResolver: StubLLMTokenResolver()
        )
    }

    // MARK: - Residency (/api/ps, keep_alive: 0)

    /// The benchmark needs to SEE what else is resident — a co-resident model competes for memory
    /// and poisons every timing. Observing residency is not managing it.
    func testListLoadedInstances_decodesRunningModels() async throws {
        let client = makeClient(body: #"""
        {"models":[{"name":"qwen3.8:27b-mlx","size_vram":33785093136},{"name":"gpt-oss:20b"}]}
        """#)
        let instances = try await client.listLoadedInstances(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434").adoptable

        XCTAssertEqual(instances.map(\.modelName), ["qwen3.8:27b-mlx", "gpt-oss:20b"])
        // Ollama has no per-instance identity — eviction is addressed by name.
        XCTAssertEqual(instances.map(\.instanceID), ["qwen3.8:27b-mlx", "gpt-oss:20b"])
    }

    /// RED: emit an entry for a nameless row → the preparer would try to evict "" and record a
    /// failure for a model that does not exist.
    func testListLoadedInstances_skipsNamelessEntries() async throws {
        let client = makeClient(body: #"{"models":[{"size_vram":1},{"model":"only-model"}]}"#)
        let instances = try await client.listLoadedInstances(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434").adoptable
        XCTAssertEqual(instances.map(\.modelName), ["only-model"])
    }

    /// `.listed([])`, never `.unsupported`: `/api/ps` answered, and it said the machine is idle.
    /// Ollama has had that route since 0.1.x and this client throws on any non-2xx, so there is no
    /// state in which it should claim the question is unanswerable.
    ///
    /// RED: return `.unsupported` here → the benchmark stops preparing a genuinely clean Ollama
    /// box and every run on it reads "not verified".
    func testListLoadedInstances_nothingResident_isAnEmptyAnswerNotAnUnanswerableOne() async throws {
        let client = makeClient(body: #"{"models":[]}"#)
        let listing = try await client.listLoadedInstances(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434")
        XCTAssertEqual(listing, .listed([]))
    }

    /// `keep_alive: 0` is Ollama's documented unload and the only one it offers — there is no
    /// unload endpoint. RED: send any other keep-alive → the model stays resident and the next
    /// sample is measured beside it.
    func testUnloadModel_asksWithKeepAliveZeroAndNoMessages() async throws {
        let session = CapturingOllamaSession()
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        try await client.unloadModel(
            provider: .ollama, instanceID: "gpt-oss:20b", baseURLString: "http://127.0.0.1:11434")

        let body = try XCTUnwrap(session.lastBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-oss:20b")
        XCTAssertEqual(json["keep_alive"] as? Int, 0)
        XCTAssertEqual((json["messages"] as? [Any])?.count, 0,
                       "an empty turn makes this a pure residency instruction with no generation "
                           + "to pay for")
        XCTAssertEqual(session.lastPath, "/api/chat")
    }

    func testUnloadModel_nonSuccessStatus_throws() async {
        let client = makeClient(status: 500, body: "boom")
        do {
            try await client.unloadModel(provider: .ollama, instanceID: "m", baseURLString: "http://127.0.0.1:11434")
            XCTFail("expected a throw on a non-2xx unload")
        } catch {
            // expected
        }
    }

    /// RED: swallow the failure → the preparer reads "nothing else is resident" from a server it
    /// could not reach, and reports the machine as verified clean when it was never checked.
    func testListLoadedInstances_nonSuccessStatus_throws() async {
        let client = makeClient(status: 503, body: "busy")
        do {
            _ = try await client.listLoadedInstances(provider: .ollama, baseURLString: "http://127.0.0.1:11434")
            XCTFail("expected a throw so the caller can report that nothing was verified")
        } catch {
            // expected
        }
    }

    func testListLoadedInstances_invalidBaseURL_throws() async {
        let client = makeClient(body: #"{"models":[]}"#)
        do {
            _ = try await client.listLoadedInstances(provider: .ollama, baseURLString: "")
            XCTFail("expected a throw for an unusable endpoint")
        } catch {
            // expected
        }
    }

    func testUnloadModel_invalidBaseURL_throws() async {
        let client = makeClient(body: "{}")
        do {
            try await client.unloadModel(provider: .ollama, instanceID: "m", baseURLString: "")
            XCTFail("expected a throw for an unusable endpoint")
        } catch {
            // expected
        }
    }

    // MARK: - fetchModels (/api/tags)

    func testFetchModels_decodesTagsShape() async throws {
        let client = makeClient(body: #"{"models":[{"name":"llama3.1:8b"},{"name":"gpt-oss:20b"}]}"#)
        let models = try await client.fetchModels(config: makeConfig(), visionOnly: false).map(\.name)
        XCTAssertEqual(Set(models), ["llama3.1:8b", "gpt-oss:20b"])
    }

    /// `details.format` and `details.quantization_level` ride `/api/tags` — the very response that
    /// yields the names — and were decoded and thrown away for as long as this returned `[String]`.
    /// Measured against a live Ollama 0.32: `"format":"safetensors"`, `"quantization_level":"nvfp4"`.
    /// RED: stop reading `details` in `fetchModels` → every Ollama row loses its chips.
    func testFetchModels_carriesFormatAndQuantizationFromTagDetails() async throws {
        let client = makeClient(body: #"""
        {"models":[
          {"name":"qwen3.6:35b","details":{"format":"safetensors","quantization_level":"nvfp4"}},
          {"name":"llama3.1:8b","details":{"format":"gguf","quantization_level":"Q4_K_M"}}
        ]}
        """#)
        let models = try await client.fetchModels(config: makeConfig(), visionOnly: false)

        XCTAssertEqual(models.map(\.name), ["llama3.1:8b", "qwen3.6:35b"])
        XCTAssertEqual(models.map(\.format), ["gguf", "safetensors"])
        XCTAssertEqual(models.map(\.quantization), ["Q4_K_M", "nvfp4"])
    }

    /// An entry with no `details` is still a model. Fail-open, exactly as the capability probe is:
    /// a missing label must never hide a model from the picker.
    func testFetchModels_tagWithoutDetails_stillListedWithNoChips() async throws {
        let client = makeClient(body: #"{"models":[{"name":"bare:latest"}]}"#)
        let models = try await client.fetchModels(config: makeConfig(), visionOnly: false)

        XCTAssertEqual(models.map(\.name), ["bare:latest"])
        XCTAssertNil(models.first?.format)
        XCTAssertNil(models.first?.quantization)
    }

    func testFetchModels_emptyBaseURL_throwsInvalidBaseURL() async {
        let client = makeClient(body: "{}")
        do {
            _ = try await client.fetchModels(
                config: LLMConfig(provider: .ollama, baseURLString: "", modelName: "m"),
                visionOnly: false)
            XCTFail("Expected invalidBaseURL")
        } catch let error as LLMClientError {
            guard case .invalidBaseURL = error else {
                return XCTFail("Expected invalidBaseURL, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMClientError, got \(type(of: error))")
        }
    }

    func testFetchModels_non2xx_throwsBadHTTPStatus() async {
        let client = makeClient(status: 500, body: "boom")
        do {
            _ = try await client.fetchModels(config: makeConfig(), visionOnly: false)
            XCTFail("Expected badHTTPStatus")
        } catch let error as LLMClientError {
            guard case .badHTTPStatus(let code, _) = error else {
                return XCTFail("Expected badHTTPStatus, got \(error)")
            }
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Expected LLMClientError, got \(type(of: error))")
        }
    }

    func testFetchModels_chatList_excludesEmbeddingOnlyModels() async throws {
        // The LM Studio analogue filters `type == "llm"` — an Ollama user's
        // pulled nomic-embed-text must not be offered as a chat model.
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/tags": .fixed(#"{"models":[{"name":"nomic-embed-text"},{"name":"gpt-oss:20b"}]}"#),
            "/api/show": .byBody { requestBody in
                requestBody.contains("nomic")
                    ? #"{"capabilities":["embedding"]}"#
                    : #"{"capabilities":["completion","tools"]}"#
            },
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let models = try await client.fetchModels(config: makeConfig(), visionOnly: false).map(\.name)
        XCTAssertEqual(models, ["gpt-oss:20b"])
    }

    func testFetchModels_chatList_failOpenWhenProbeHasNoCapabilities() async throws {
        // Old servers without `capabilities` must never hide chat models.
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/tags": .fixed(#"{"models":[{"name":"a"},{"name":"b"}]}"#),
            "/api/show": .byBody { _ in #"{"modelfile":"FROM …"}"# },
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let models = try await client.fetchModels(config: makeConfig(), visionOnly: false).map(\.name)
        XCTAssertEqual(Set(models), ["a", "b"])
    }

    func testFetchModels_visionOnly_filtersViaShowCapabilities() async throws {
        // The stub routes by path: /api/tags lists two models, /api/show
        // reports vision only for llava.
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/tags": .fixed(#"{"models":[{"name":"llava:13b"},{"name":"gpt-oss:20b"}]}"#),
            "/api/show": .byBody { requestBody in
                requestBody.contains("llava")
                    ? #"{"capabilities":["completion","vision"]}"#
                    : #"{"capabilities":["completion","tools"]}"#
            },
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let models = try await client.fetchModels(config: makeConfig(), visionOnly: true).map(\.name)
        XCTAssertEqual(models, ["llava:13b"])
    }

    func testFetchEmbeddingModels_filtersByEmbeddingCapability() async throws {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/tags": .fixed(#"{"models":[{"name":"nomic-embed-text"},{"name":"gpt-oss:20b"}]}"#),
            "/api/show": .byBody { requestBody in
                requestBody.contains("nomic")
                    ? #"{"capabilities":["embedding"]}"#
                    : #"{"capabilities":["completion","tools"]}"#
            },
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let models = try await client.fetchEmbeddingModels(config: makeConfig())
        XCTAssertEqual(models, ["nomic-embed-text"])
    }

    func testFetchEmbeddingModels_noCapabilitiesAnywhere_returnsAll() async throws {
        // Older Ollama without `capabilities` in /api/show: degraded to the
        // full list (user picks manually) — same degradation as the LM Studio
        // OpenAI-shape fallback.
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/tags": .fixed(#"{"models":[{"name":"a"},{"name":"b"}]}"#),
            "/api/show": .byBody { _ in #"{"modelfile":"FROM …"}"# },
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let models = try await client.fetchEmbeddingModels(config: makeConfig())
        XCTAssertEqual(Set(models), ["a", "b"])
    }

    // MARK: - modelSupportsVision / modelContextLength

    func testModelSupportsVision_trueFromCapabilities() async {
        let client = makeClient(body: #"{"capabilities":["completion","vision"]}"#)
        let result = await client.modelSupportsVision(config: makeConfig(model: "llava:13b"))
        XCTAssertEqual(result, true)
    }

    func testModelSupportsVision_falseWhenListedWithoutVision() async {
        let client = makeClient(body: #"{"capabilities":["completion","tools"]}"#)
        let result = await client.modelSupportsVision(config: makeConfig())
        XCTAssertEqual(result, false)
    }

    func testModelSupportsVision_nilWhenCapabilitiesAbsent() async {
        let client = makeClient(body: #"{"modelfile":"FROM …"}"#)
        let result = await client.modelSupportsVision(config: makeConfig())
        XCTAssertNil(result)
    }

    func testModelSupportsVision_nilOnHTTPError() async {
        let client = makeClient(status: 404, body: #"{"error":"model not found"}"#)
        let result = await client.modelSupportsVision(config: makeConfig())
        XCTAssertNil(result)
    }

    func testModelContextLength_archMaxOnly_returnsNil() async {
        // The architecture max is NOT the runtime window — Ollama's default
        // window is OLLAMA_CONTEXT_LENGTH (~4096) and oversized prompts are
        // silently truncated with HTTP 200. nil → the planner's conservative
        // fallback, the correct answer for a stock install.
        let client = makeClient(
            body: #"{"model_info":{"general.architecture":"llama","llama.context_length":131072}}"#)
        let result = await client.modelContextLength(config: makeConfig())
        XCTAssertNil(result)
    }

    func testModelContextLength_numCtxPresent_returnsIt() async {
        let client = makeClient(
            body: #"{"parameters":"num_ctx 16384","model_info":{"llama.context_length":131072}}"#)
        let result = await client.modelContextLength(config: makeConfig())
        XCTAssertEqual(result, 16384)
    }

    /// `/api/ps` reports the window the runner ACTUALLY loaded with — it already folds
    /// in `OLLAMA_CONTEXT_LENGTH`, a per-request `num_ctx` and the runner's clamping, so
    /// it must win over the modelfile's declared value.
    func testModelContextLength_prefersLoadedInstanceFromPS_overModelfileNumCtx() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(#"{"parameters":"num_ctx 16384"}"#),
            "/api/ps": .fixed(#"{"models":[{"name":"gpt-oss:20b","model":"gpt-oss:20b","context_length":8192}]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let result = await client.modelContextLength(config: makeConfig())
        XCTAssertEqual(result, 8192, "the loaded window governs, not the declared one")
    }

    /// This is the case the whole change exists for: a stock `ollama pull` has no
    /// modelfile `num_ctx`, so before `/api/ps` the probe was always nil and the
    /// overflow warning could never fire.
    func testModelContextLength_stockPullWithNoNumCtx_stillLearnsWindowFromPS() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(#"{"model_info":{"llama.context_length":131072}}"#),
            "/api/ps": .fixed(#"{"models":[{"model":"gpt-oss:20b","context_length":4096}]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let result = await client.modelContextLength(config: makeConfig())
        XCTAssertEqual(result, 4096)
    }

    /// Older Ollama builds omit the field — fall through rather than assert a window.
    func testModelContextLength_psAbsentField_fallsBackToNumCtx() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(#"{"parameters":"num_ctx 16384"}"#),
            "/api/ps": .fixed(#"{"models":[{"name":"gpt-oss:20b","model":"gpt-oss:20b"}]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let result = await client.modelContextLength(config: makeConfig())
        XCTAssertEqual(result, 16384)
    }

    /// A DIFFERENT resident model's window must never be adopted.
    func testModelContextLength_psListsAnotherModel_fallsBackToNumCtx() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(#"{"parameters":"num_ctx 16384"}"#),
            "/api/ps": .fixed(#"{"models":[{"model":"llama3.1:8b","context_length":2048}]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let result = await client.modelContextLength(config: makeConfig())
        XCTAssertEqual(result, 16384)
    }

    /// Ollama reports `name:tag` while callers routinely configure the bare name.
    func testModelContextLength_bareConfiguredName_matchesTaggedInstance() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(#"{}"#),
            "/api/ps": .fixed(#"{"models":[{"model":"gpt-oss:20b","context_length":8192}]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let result = await client.modelContextLength(config: makeConfig(model: "gpt-oss"))
        XCTAssertEqual(result, 8192)
    }

    /// Cold model + no declared window → still nil. `ContextBudgetPolicy` must never
    /// warn on a guess, so an undeterminable window stays undeterminable.
    func testModelContextLength_notLoadedAndNoNumCtx_returnsNil() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(#"{"model_info":{"llama.context_length":131072}}"#),
            "/api/ps": .fixed(#"{"models":[]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let result = await client.modelContextLength(config: makeConfig())
        XCTAssertNil(result)
    }

    // MARK: - parseShowResponse (pure)

    func testParseShowResponse_separatesNumCtxFromArchitectureMax() {
        let body = #"{"parameters":"num_ctx 8192\nstop \"<|end|>\"","model_info":{"llama.context_length":131072}}"#
        let parsed = OllamaClient.parseShowResponse(Data(body.utf8))
        XCTAssertEqual(parsed.modelfileNumCtx, 8192)
        XCTAssertEqual(parsed.architectureContextLength, 131072)
    }

    func testParseShowResponse_capabilitiesAndContext() {
        let body = #"{"capabilities":["completion","thinking"],"model_info":{"qwen3.context_length":40960}}"#
        let parsed = OllamaClient.parseShowResponse(Data(body.utf8))
        XCTAssertEqual(parsed.capabilities, ["completion", "thinking"])
        XCTAssertEqual(parsed.architectureContextLength, 40960)
        XCTAssertNil(parsed.modelfileNumCtx)
    }

    func testParseShowResponse_malformedJSON_allNil() {
        let parsed = OllamaClient.parseShowResponse(Data("not json".utf8))
        XCTAssertNil(parsed.capabilities)
        XCTAssertNil(parsed.modelfileNumCtx)
        XCTAssertNil(parsed.architectureContextLength)
    }

    // MARK: - modelLoadDetails

    func testModelLoadDetails_loadedModel_mergesShowAndPS() async {
        let show = #"{"details":{"parameter_size":"20.9B","quantization_level":"MXFP4","family":"gptoss","format":"gguf"},"capabilities":["completion","tools","thinking"],"model_info":{"gptoss.context_length":131072},"parameters":"num_ctx 8192"}"#
        let ps = #"{"models":[{"name":"gpt-oss:20b","model":"gpt-oss:20b","size_vram":13600000000,"expires_at":"2026-07-23T21:00:00Z"}]}"#
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(show),
            "/api/ps": .fixed(ps),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())

        let details = await client.modelLoadDetails(config: makeConfig())

        let labels = details?.fields.map(\.label) ?? []
        XCTAssertEqual(labels.first, "State")
        XCTAssertEqual(details?.fields.first?.value, "Loaded")
        func value(_ label: String) -> String? {
            details?.fields.first { $0.label == label }?.value
        }
        XCTAssertEqual(value("VRAM"), "13.6 GB")
        XCTAssertEqual(value("Keep-alive until"), "2026-07-23T21:00:00Z")
        XCTAssertEqual(value("Context length (num_ctx)"), "8192")
        XCTAssertEqual(value("Max context length"), "131072")
        XCTAssertEqual(value("Parameters"), "20.9B")
        XCTAssertEqual(value("Quantization"), "MXFP4")
        XCTAssertEqual(value("Family"), "gptoss")
        XCTAssertEqual(value("Format"), "gguf")
        XCTAssertEqual(value("Capabilities"), "completion, tools, thinking")
        XCTAssertEqual(value("Modelfile parameters"), "num_ctx 8192")
    }

    /// `ModelLoadDetails.Field` is `Identifiable` off its LABEL, and the Model Details card
    /// renders the fields in a `ForEach` — so two fields sharing a label would be two rows
    /// with one id, which is SwiftUI's documented undefined-results case (CLAUDE.md #22:
    /// wrong removal animations, stale-index crashes).
    ///
    /// Asserted against the richest real payload rather than a hand-built pair, because the
    /// property that matters is "the provider path cannot emit a duplicate", not "String
    /// equality works".
    ///
    /// RED: change `id` to a constant, or merge two label cases in `modelLoadDetails` → the
    /// uniqueness assertion fails.
    func testModelLoadDetails_fieldIDsAreUniqueAndDerivedFromTheLabel() async {
        let show = #"{"details":{"parameter_size":"20.9B","quantization_level":"MXFP4","family":"gptoss","format":"gguf"},"capabilities":["completion","tools","thinking"],"model_info":{"gptoss.context_length":131072},"parameters":"num_ctx 8192"}"#
        let ps = #"{"models":[{"name":"gpt-oss:20b","model":"gpt-oss:20b","size_vram":13600000000,"expires_at":"2026-07-23T21:00:00Z"}]}"#
        let client = OllamaClient(
            session: RoutingOllamaNetworkSession(routes: [
                "/api/show": .fixed(show), "/api/ps": .fixed(ps),
            ]),
            tokenResolver: StubLLMTokenResolver())

        let fields = await client.modelLoadDetails(config: makeConfig())?.fields ?? []

        XCTAssertGreaterThan(fields.count, 5, "arrange: the rich payload must yield many rows")
        for field in fields {
            XCTAssertEqual(field.id, field.label, "the id IS the label")
        }
        XCTAssertEqual(
            Set(fields.map(\.id)).count, fields.count,
            "duplicate ids in a ForEach are undefined results: \(fields.map(\.id))")
    }

    func testModelLoadDetails_notResident_showsNotLoaded() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(#"{"capabilities":["completion"]}"#),
            "/api/ps": .fixed(#"{"models":[]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let details = await client.modelLoadDetails(config: makeConfig())
        XCTAssertEqual(details?.fields.first?.label, "State")
        XCTAssertEqual(details?.fields.first?.value, "Not loaded")
    }

    func testModelLoadDetails_psProbeFails_omitsStateRatherThanLying() async {
        // A transport blip on /api/ps must not render a loaded model as
        // "Not loaded" — the runtime rows are simply omitted.
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(#"{"capabilities":["completion"]}"#),
            "/api/ps": .fixed("not json"),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let details = await client.modelLoadDetails(config: makeConfig())
        XCTAssertFalse(details?.fields.contains { $0.label == "State" } ?? true)
        XCTAssertEqual(details?.fields.first?.label, "Capabilities")
    }

    func testModelLoadDetails_showFails_returnsNil() async {
        let client = makeClient(status: 404, body: #"{"error":"model not found"}"#)
        let details = await client.modelLoadDetails(config: makeConfig())
        XCTAssertNil(details)
    }

    func testParseShowResponse_doubleEncodedContextLength() {
        // JSONSerialization can surface large ints as Double depending on
        // payload shape — both must parse.
        let body = #"{"model_info":{"llama.context_length":4096.0}}"#
        let parsed = OllamaClient.parseShowResponse(Data(body.utf8))
        XCTAssertEqual(parsed.architectureContextLength, 4096)
    }

    // MARK: - Listing / parse corners

    func testFetchTags_emptyModelList_returnsEmpty() async throws {
        let client = makeClient(body: #"{"models":[]}"#)
        let models = try await client.fetchModels(config: makeConfig(), visionOnly: false).map(\.name)
        XCTAssertEqual(models, [])
    }

    func testFetchTags_duplicateAndWhitespaceNames_normalizedUnique() async throws {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/tags": .fixed(#"{"models":[{"name":"a:1b"},{"name":" a:1b "},{"name":"b"}]}"#),
            "/api/show": .byBody { _ in #"{"capabilities":["completion"]}"# },
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let models = try await client.fetchModels(config: makeConfig(), visionOnly: false).map(\.name)
        XCTAssertEqual(models, ["a:1b", "b"], "trim + dedupe + case-insensitive sort")
    }

    func testFetchModels_visionOnly_allProbesFail_returnsEmpty() async {
        // Conservative direction: never offer a model we can't CONFIRM sees
        // images (unlike the chat list, which fails open).
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/tags": .fixed(#"{"models":[{"name":"a"},{"name":"b"}]}"#),
            "/api/show": .byBody { _ in "not json" },
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let models = ((try? await client.fetchModels(config: makeConfig(), visionOnly: true)) ?? []).map(\.name)
        XCTAssertEqual(models, [])
    }

    func testParseShowResponse_multipleContextLengthKeys_sortedKeyWinsDeterministically() {
        // Nondeterministic dictionary order is a known trap (TemplateResolver
        // грабли) — sorted keys pin the pick.
        let body = #"{"model_info":{"zeta.context_length":9,"alpha.context_length":7}}"#
        let parsed = OllamaClient.parseShowResponse(Data(body.utf8))
        XCTAssertEqual(parsed.architectureContextLength, 7)
    }

    func testParseShowResponse_malformedNumCtx_ignored() {
        let body = #"{"parameters":"num_ctx abc\nnum_ctx","model_info":{"llama.context_length":8192}}"#
        let parsed = OllamaClient.parseShowResponse(Data(body.utf8))
        XCTAssertNil(parsed.modelfileNumCtx)
        XCTAssertEqual(parsed.architectureContextLength, 8192)
    }

    func testParseShowResponse_lastNumCtxLineWins() {
        let body = #"{"parameters":"num_ctx 2048\nnum_ctx 8192"}"#
        let parsed = OllamaClient.parseShowResponse(Data(body.utf8))
        XCTAssertEqual(parsed.modelfileNumCtx, 8192)
    }

    func testParseShowResponse_emptyCapabilitiesArray_isProbedNotNil() {
        let parsed = OllamaClient.parseShowResponse(Data(#"{"capabilities":[]}"#.utf8))
        XCTAssertNotNil(parsed.capabilities)
        XCTAssertEqual(parsed.capabilities, [])
    }

    func testParseShowResponse_rootIsArray_allNil() {
        let parsed = OllamaClient.parseShowResponse(Data("[1,2,3]".utf8))
        XCTAssertNil(parsed.capabilities)
        XCTAssertNil(parsed.modelfileNumCtx)
        XCTAssertNil(parsed.architectureContextLength)
    }

    func testModelSupportsVision_emptyCapabilities_definitiveFalse() async {
        let client = makeClient(body: #"{"capabilities":[]}"#)
        let result = await client.modelSupportsVision(config: makeConfig())
        XCTAssertEqual(result, false, "listed with an empty capability set is a definitive no, not undeterminable")
    }

    // MARK: - Model Load Details corners

    func testModelLoadDetails_emptyShowPlusEmptyPS_onlyStateRow() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed("{}"),
            "/api/ps": .fixed(#"{"models":[]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let details = await client.modelLoadDetails(config: makeConfig())
        XCTAssertEqual(details?.fields.map(\.label), ["State"])
        XCTAssertEqual(details?.fields.first?.value, "Not loaded")
    }

    func testModelLoadDetails_psMatchesByModelFieldWhenNameDiffers() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed(#"{"capabilities":["completion"]}"#),
            "/api/ps": .fixed(#"{"models":[{"name":"friendly-alias","model":"gpt-oss:20b","size_vram":1500000000}]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let details = await client.modelLoadDetails(config: makeConfig())
        XCTAssertEqual(details?.fields.first?.value, "Loaded")
        XCTAssertEqual(details?.fields.first { $0.label == "VRAM" }?.value, "1.5 GB")
    }

    func testModelLoadDetails_emptyExpiresAt_omitted() async {
        let session = RoutingOllamaNetworkSession(routes: [
            "/api/show": .fixed("{}"),
            "/api/ps": .fixed(#"{"models":[{"name":"gpt-oss:20b","expires_at":""}]}"#),
        ])
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let details = await client.modelLoadDetails(config: makeConfig())
        XCTAssertFalse(details?.fields.contains { $0.label == "Keep-alive until" } ?? true)
    }

    func testFormatBytes_corners() {
        XCTAssertEqual(OllamaClient.formatBytes(0), "0.0 GB")
        XCTAssertEqual(OllamaClient.formatBytes(1_500_000_000), "1.5 GB")
        XCTAssertEqual(OllamaClient.formatBytes(13_600_000_000), "13.6 GB")
        XCTAssertEqual(OllamaClient.formatBytes(999_000_000), "1.0 GB")
    }

    /// Measured on a live Ollama 0.32.14: `/api/show` reports the minimum server version a model
    /// needs. RED: drop the row → the one field that explains "this model will not run here",
    /// read beside `serverVersion`, is gone.
    func testParseShowLoadFields_carriesTheRequiredOllamaVersion() {
        let body = #"{"requires":"0.32.12","details":{"family":"qwen3_5"}}"#
        let fields = OllamaClient.parseShowLoadFields(Data(body.utf8))
        XCTAssertEqual(fields.first { $0.label == "Requires Ollama" }?.value, "0.32.12")
    }

    /// A server that does not report it must not render an empty row.
    func testParseShowLoadFields_absentRequires_rendersNoRow() {
        let body = #"{"details":{"family":"qwen3_5"}}"#
        let fields = OllamaClient.parseShowLoadFields(Data(body.utf8))
        XCTAssertNil(fields.first { $0.label == "Requires Ollama" })
    }

    func testParseShowLoadFields_orderingPin() {
        let body = #"""
        {"capabilities":["completion","tools"],
         "details":{"parameter_size":"20.9B","quantization_level":"MXFP4","family":"gptoss","format":"gguf"},
         "model_info":{"gptoss.context_length":131072},
         "parameters":"num_ctx 8192"}
        """#
        let fields = OllamaClient.parseShowLoadFields(Data(body.utf8))
        XCTAssertEqual(fields.map(\.label), [
            "Context length (num_ctx)", "Max context length", "Parameters",
            "Quantization", "Family", "Format", "Capabilities", "Modelfile parameters",
        ])
    }
}

// MARK: - Network doubles

/// Replays one canned `(Data, URLResponse)` for any request.
private final class StubOllamaNetworkSession: NetworkSession, @unchecked Sendable {
    let response: URLResponse
    let data: Data

    init(response: URLResponse, data: Data) {
        self.response = response
        self.data = data
    }

    func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) {
        (data, response)
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("StubOllamaNetworkSession.sessionBytes not supported")
    }
}

/// Records the last request so a test can assert what was actually sent.
private final class CapturingOllamaSession: NetworkSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastBody: Data?
    private var _lastPath: String?

    var lastBody: Data? { lock.withLock { _lastBody } }
    var lastPath: String? { lock.withLock { _lastPath } }

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            _lastBody = request.httpBody
            _lastPath = request.url?.path
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{}".utf8), response)
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("CapturingOllamaSession.sessionBytes not supported")
    }
}

/// Routes by URL path; `/api/show` responses can vary by request body (to
/// return different capabilities per model).
private final class RoutingOllamaNetworkSession: NetworkSession, @unchecked Sendable {
    enum Route {
        case fixed(String)
        case byBody((String) -> String)
    }

    private let routes: [String: Route]

    init(routes: [String: Route]) {
        self.routes = routes
    }

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        guard let route = routes[path] else {
            fatalError("No route for \(path)")
        }
        let body: String
        switch route {
        case .fixed(let s):
            body = s
        case .byBody(let f):
            body = f(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("RoutingOllamaNetworkSession.sessionBytes not supported")
    }
}
