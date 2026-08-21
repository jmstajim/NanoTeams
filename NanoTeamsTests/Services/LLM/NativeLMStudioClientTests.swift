import XCTest

@testable import NanoTeams

private extension NativeLMStudioClient.NativeChatInput {
    var textValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    func contains(_ substring: String) -> Bool {
        textValue?.contains(substring) ?? false
    }
}

final class NativeLMStudioClientTests: XCTestCase {

    // MARK: - Properties

    var sut: NativeLMStudioClient!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        sut = NativeLMStudioClient()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeConfig(
        baseURLString: String = "http://localhost:1234",
        modelName: String = "openai/gpt-oss-20b",
        temperature: Double? = nil
    ) -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: baseURLString,
            modelName: modelName,
            temperature: temperature
        )
    }

    private func makeToolSchema(
        name: String = "read_file",
        description: String = "Read a file from disk",
        parameters: JSONSchema = JSONSchema.object(
            properties: ["path": JSONSchema.string("File path")],
            required: ["path"]
        )
    ) -> ToolSchema {
        ToolSchema(name: name, description: description, parameters: parameters)
    }

    private func encodeToDict(
        _ request: NativeLMStudioClient.NativeChatRequest
    ) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        return obj as! [String: Any]
    }

    private func collectStreamError(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async -> Error? {
        do {
            for try await _ in stream {}
            return nil
        } catch {
            return error
        }
    }

    // MARK: - System Prompt

    func testSystemMessageExtractedToSystemPrompt() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are a helpful assistant."),
            ChatMessage(role: .user, content: "Hello"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(request.systemPrompt, "You are a helpful assistant.")
    }

    func testMultipleSystemMessagesConcatenated() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "Be concise."),
            ChatMessage(role: .system, content: "You are an engineer."),
            ChatMessage(role: .user, content: "Hello"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(request.systemPrompt, "Be concise.\n\nYou are an engineer.")
    }

    func testNoSystemMessageProducesNilSystemPrompt() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Hello"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertNil(request.systemPrompt)
    }

    func testSystemMessageNotInInput() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System instructions."),
            ChatMessage(role: .user, content: "Hello"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        // System message goes to systemPrompt, not input
        XCTAssertFalse(request.input.contains("System instructions."))
        XCTAssertEqual(request.input.textValue,"Hello")
    }

    // MARK: - Input Rendering

    func testStatelessUserMessageInInput() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .user, content: "What is 2+2?"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(request.input.textValue,"What is 2+2?")
    }

    func testStatelessAssistantMessageInInput() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there!"),
            ChatMessage(role: .user, content: "How are you?"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        // Parts joined with "\n\n"
        XCTAssertTrue(request.input.contains("Hello"))
        XCTAssertTrue(request.input.contains("[Assistant]\nHi there!"))
        XCTAssertTrue(request.input.contains("How are you?"))
        XCTAssertEqual(request.input.textValue,"Hello\n\n[Assistant]\nHi there!\n\nHow are you?")
    }

    func testStatelessToolResultFormattedAsText() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Read a file"),
            ChatMessage(role: .tool, content: "file contents here", toolCallID: "call_abc"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertTrue(request.input.contains("[Tool Result]\nfile contents here"))
        XCTAssertEqual(request.input.textValue,"Read a file\n\n[Tool Result]\nfile contents here")
    }

    func testStatelessAllPartsJoinedWithDoubleNewline() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi"),
            ChatMessage(role: .tool, content: "result", toolCallID: "c1"),
            ChatMessage(role: .user, content: "Thanks"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        let expected = "Hello\n\n[Assistant]\nHi\n\n[Tool Result]\nresult\n\nThanks"
        XCTAssertEqual(request.input.textValue,expected)
    }

    // MARK: - System / user / tool routing

    func testSystemGoesToSystemPromptNotInput() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .user, content: "New user question"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(request.input.textValue,"New user question")
    }

    func testToolResultInInput() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .tool, content: "read output", toolCallID: "call_x"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(request.input.textValue,"[Tool Result]\nread output")
    }

    /// Assistant turns are rendered into `input`. Nothing is held server-side, so
    /// skipping them (the old stateful behavior) would show the model tool results
    /// for calls it has no record of making.
    func testAssistantMessagesAreRendered() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .assistant, content: "Previous assistant response"),
            ChatMessage(role: .tool, content: "tool output", toolCallID: "c1"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(
            request.input.textValue,
            "[Assistant]\nPrevious assistant response\n\n[Tool Result]\ntool output")
    }

    func testMultipleToolResults() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .tool, content: "result 1", toolCallID: "c1"),
            ChatMessage(role: .tool, content: "result 2", toolCallID: "c2"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertTrue(request.input.contains("[Tool Result]\nresult 1"))
        XCTAssertTrue(request.input.contains("[Tool Result]\nresult 2"))
        XCTAssertEqual(request.input.textValue,"[Tool Result]\nresult 1\n\n[Tool Result]\nresult 2")
    }

    // MARK: - Request Config Fields

    func testModelNameMapped() throws {
        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(modelName: "ibm/granite-4-micro"),
            messages: [ChatMessage(role: .user, content: "Hi")],
            tools: []
        )

        XCTAssertEqual(request.model, "ibm/granite-4-micro")
    }

    func testTemperatureMapped() throws {
        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(temperature: 0.3),
            messages: [ChatMessage(role: .user, content: "Hi")],
            tools: []
        )

        XCTAssertEqual(request.temperature, 0.3)
    }

    /// `stream` is always on; `store` is always OFF. Nothing resumes a stored
    /// response now that chains are gone, so storing one only accumulates orphan
    /// server-side state.
    func testStreamAlwaysTrue_storeAlwaysFalse() throws {
        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: [ChatMessage(role: .user, content: "Hi")],
            tools: []
        )

        XCTAssertFalse(request.store)
        XCTAssertTrue(request.stream)
    }

    // MARK: - Encoding (CodingKeys)

    func testRequestEncodesWithSnakeCaseKeys() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .user, content: "Hello"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        let dict = try encodeToDict(request)

        XCTAssertNotNil(dict["system_prompt"])
        XCTAssertNil(dict["systemPrompt"])
        XCTAssertNil(dict["previous_response_id"],
                     "Response chains were removed — the key must never reach the wire")
    }

    func testInputEncodedAsString() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Hello world"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        let dict = try encodeToDict(request)
        // input must encode as a plain String, not an array
        XCTAssertEqual(dict["input"] as? String, "Hello world")
        XCTAssertNil(dict["input"] as? [[String: Any]])
    }

    // MARK: - Tool Schema Injection

    func testEmptyToolsNoToolSectionInSystemPrompt() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are an assistant."),
            ChatMessage(role: .user, content: "Hello"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(request.systemPrompt, "You are an assistant.")
        XCTAssertFalse(request.systemPrompt?.contains("Tool Calling") ?? false)
    }

    func testToolSchemaAppendedToSystemPrompt() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are an engineer."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let tools = [makeToolSchema(name: "read_file", description: "Read a file")]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: tools
        )

        let prompt = request.systemPrompt ?? ""
        XCTAssertTrue(prompt.hasPrefix("You are an engineer."))
        XCTAssertTrue(prompt.contains("Tool Calling"))
        XCTAssertTrue(prompt.contains("read_file"))
        XCTAssertTrue(prompt.contains("<|call|>"))
    }

    func testToolSchemaIncludesDescription() throws {
        let messages: [ChatMessage] = [ChatMessage(role: .user, content: "Hi")]
        let tools = [makeToolSchema(name: "git_status", description: "Show git status")]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: tools
        )

        let prompt = request.systemPrompt ?? ""
        XCTAssertTrue(prompt.contains("git_status"))
        XCTAssertTrue(prompt.contains("Show git status"))
    }

    func testToolSchemaIncludesParameters() throws {
        let messages: [ChatMessage] = [ChatMessage(role: .user, content: "Hi")]
        let schema = JSONSchema.object(
            properties: ["path": JSONSchema.string("File path"), "mode": JSONSchema.string("Mode")],
            required: ["path"]
        )
        let tools = [makeToolSchema(name: "write_file", parameters: schema)]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: tools
        )

        let prompt = request.systemPrompt ?? ""
        XCTAssertTrue(prompt.contains("path"))
        XCTAssertTrue(prompt.contains("mode"))
    }

    func testMultipleToolsAllInjected() throws {
        let messages: [ChatMessage] = [ChatMessage(role: .user, content: "Hi")]
        let tools = [
            makeToolSchema(name: "read_file", description: "Read"),
            makeToolSchema(name: "write_file", description: "Write"),
            makeToolSchema(name: "git_status", description: "Git status"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: tools
        )

        let prompt = request.systemPrompt ?? ""
        XCTAssertTrue(prompt.contains("read_file"))
        XCTAssertTrue(prompt.contains("write_file"))
        XCTAssertTrue(prompt.contains("git_status"))
    }

    func testToolSchemaWithNoSystemMessageCreatesSystemPrompt() throws {
        // No system message, but tools present → systemPrompt should still be non-nil
        let messages: [ChatMessage] = [ChatMessage(role: .user, content: "Hi")]
        let tools = [makeToolSchema()]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: tools
        )

        XCTAssertNotNil(request.systemPrompt)
        XCTAssertTrue(request.systemPrompt?.contains("Tool Calling") ?? false)
    }

    // MARK: - Wire invariants

    func testInvariant_SystemPromptAlwaysSent() throws {
        // Nothing persists it server-side, so every request must carry it — and it
        // anchors the byte-identical prefix the KV cache keys on.
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "Be concise."),
            ChatMessage(role: .user, content: "Question"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(request.systemPrompt, "Be concise.")
    }

    func testInvariant_SystemNeverDuplicatedIntoInput() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .tool, content: "tool output", toolCallID: "c1"),
            ChatMessage(role: .user, content: "Continue"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertTrue(request.input.contains("[Tool Result]\ntool output"))
        XCTAssertTrue(request.input.contains("Continue"))
        // System rides `system_prompt`, never `input`
        XCTAssertFalse(request.input.contains("System."))
    }

    // MARK: - URL Construction

    func testInvalidBaseURLThrows() async {
        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "not a valid url ://bad",
            modelName: "model",
            temperature: 0.7
        )

        let stream = sut.streamChat(
            config: config,
            messages: [ChatMessage(role: .user, content: "Hi")],
            tools: [],
            logger: nil,
            stepID: nil
        )

        let error = await collectStreamError(stream)
        XCTAssertNotNil(error)

        guard let llmError = error as? LLMClientError,
              case .invalidBaseURL(let urlString) = llmError
        else {
            XCTFail("Expected invalidBaseURL error, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(urlString, "not a valid url ://bad")
    }

    func testFetchModelsUsesNativeEndpoint() async {
        // Verify fetchModels constructs the correct /api/v1/models URL by observing
        // that a connection to a non-existent local server fails (not a URL-build error)
        let config = makeConfig(baseURLString: "http://127.0.0.1:19999")

        do {
            _ = try await sut.fetchModels(config: config, visionOnly: false)
            XCTFail("Expected network error for non-existent server")
        } catch {
            // Connection refused / timeout = URL was constructed, just no server
            // The error should NOT be LLMClientError.invalidBaseURL
            if let llmError = error as? LLMClientError, case .invalidBaseURL = llmError {
                XCTFail("Should not be invalidBaseURL — URL construction should have succeeded")
            }
            // Any other error (connection refused) = pass
        }
    }

    // MARK: - fetchEmbeddingModels filter

    /// `fetchEmbeddingModels` must return only entries whose LM Studio native
    /// `type` is `"embeddings"` (plural, what current LM Studio emits) or
    /// `"embedding"` (older builds). Everything else — `llm`, `vlm`, or
    /// unspecified — must be excluded so the Semantic-Expansion dropdown
    /// doesn't show chat models.
    func testFetchEmbeddingModels_filtersToEmbeddingTypeOnly() async throws {
        let body = #"""
        {
          "models": [
            { "key": "openai/gpt-oss-20b",                "type": "llm" },
            { "key": "text-embedding-nomic-embed-text-v1.5", "type": "embeddings" },
            { "key": "qwen/qwen3-vl-8b",                  "type": "vlm", "capabilities": { "vision": true } },
            { "key": "legacy-embed",                       "type": "embedding" },
            { "key": "unlabeled-thing" }
          ]
        }
        """#
        let stubSession = StubNetworkSession(
            response: HTTPURLResponse(
                url: URL(string: "http://localhost:1234/api/v1/models")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!,
            data: Data(body.utf8)
        )
        let client = NativeLMStudioClient(session: stubSession)
        let config = makeConfig()

        let embeddings = try await client.fetchEmbeddingModels(config: config)

        XCTAssertEqual(
            embeddings.sorted(),
            ["legacy-embed", "text-embedding-nomic-embed-text-v1.5"],
            "Only `embedding`/`embeddings` types must land in the picker."
        )
    }

    /// Wire-format defensive pin: LM Studio can list the same model twice
    /// (same `key`, surfaced from multiple storage paths or slots). The picker
    /// uses `ForEach(id: \.self)`, so duplicates trigger SwiftUI's
    /// "ID occurs multiple times" warning and a nondeterministic checkmark
    /// position. The client must collapse them before they reach the UI.
    func testFetchEmbeddingModels_dedupesDuplicateKeys() async throws {
        let body = #"""
        {
          "models": [
            { "key": "text-embedding-nomic-embed-text-v1.5",               "type": "embeddings" },
            { "key": "text-embedding-granite-embedding-278m-multilingual", "type": "embeddings" },
            { "key": "text-embedding-nomic-embed-text-v1.5",               "type": "embeddings" }
          ]
        }
        """#
        let stubSession = StubNetworkSession(
            response: HTTPURLResponse(
                url: URL(string: "http://localhost:1234/api/v1/models")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!,
            data: Data(body.utf8)
        )
        let client = NativeLMStudioClient(session: stubSession)
        let config = makeConfig()

        let result = try await client.fetchEmbeddingModels(config: config)

        XCTAssertEqual(
            result.count, 2,
            "Duplicate `key` entries must be collapsed before reaching the picker."
        )
        XCTAssertEqual(
            Set(result),
            [
                "text-embedding-nomic-embed-text-v1.5",
                "text-embedding-granite-embedding-278m-multilingual",
            ]
        )
    }

    // MARK: - Format / quantization on the model list

    private func modelListClient(_ body: String) -> NativeLMStudioClient {
        NativeLMStudioClient(
            session: StubNetworkSession(
                response: HTTPURLResponse(
                    url: URL(string: "http://localhost:1234/api/v1/models")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: Data(body.utf8)))
    }

    /// The shape a live LM Studio 0.4.x actually sends (measured): `format` at the top level,
    /// `quantization` as an OBJECT. Both ride the list call every picker already makes, and until
    /// `LLMModelInfo` existed both were decoded and dropped — which is why the benchmark's model
    /// list could only label a model AFTER measuring it.
    /// RED: drop `format` from `NativeModelInfo` → the chips vanish from every unmeasured row.
    func testFetchModels_carriesFormatAndObjectQuantization() async throws {
        let body = #"""
        {
          "models": [
            { "key": "qwen3.8-4b", "type": "llm", "format": "gguf",
              "quantization": { "name": "Q4_K_M", "bits_per_weight": 4 } },
            { "key": "google/gemma-4-e2b", "type": "llm", "format": "mlx",
              "quantization": { "name": "4bit", "bits_per_weight": 4 } }
          ]
        }
        """#
        let models = try await modelListClient(body)
            .fetchModels(config: makeConfig(), visionOnly: false)

        XCTAssertEqual(models.map(\.name), ["google/gemma-4-e2b", "qwen3.8-4b"])
        XCTAssertEqual(models.map(\.format), ["mlx", "gguf"])
        XCTAssertEqual(models.map(\.quantization), ["4bit", "Q4_K_M"])
    }

    /// The same field as a BARE STRING, which is how the sibling `/api/v0/models` route spells it.
    ///
    /// The pin is not really about the string: `decodeIfPresent` THROWS on a type mismatch rather
    /// than returning nil (CLAUDE.md #83), and one throw fails the whole `NativeModelListResponse`
    /// and drops the client onto the OpenAI-compatible branch — which carries no `type`, so an
    /// unexpected quantization shape on ONE model would stop every picker in the app from filtering
    /// embedders out. Hence the assertion on `type` filtering, not just on the value.
    /// RED: delete `Quantization.init(from:)`'s `singleValueContainer` branch → the embedder comes
    /// back and the quantization is nil.
    func testFetchModels_bareStringQuantization_decodesWithoutFallingBackToOpenAIShape() async throws {
        let body = #"""
        {
          "models": [
            { "key": "legacy-model", "type": "llm", "format": "gguf", "quantization": "Q8_0" },
            { "key": "text-embedding-nomic-embed-text-v1.5", "type": "embeddings" }
          ]
        }
        """#
        let models = try await modelListClient(body)
            .fetchModels(config: makeConfig(), visionOnly: false)

        XCTAssertEqual(models.map(\.name), ["legacy-model"], "the native branch must still be the one that answered")
        XCTAssertEqual(models.first?.quantization, "Q8_0")
        XCTAssertEqual(models.first?.format, "gguf")
    }

    /// A quantization of an unexpected TYPE is decoration failing, not a list failing. Same
    /// reasoning as above, one step further: the field is read with `try?` so the model survives
    /// without its chip rather than taking the whole response down with it.
    /// RED: decode `quantization` with a plain `decodeIfPresent` → the embedder reappears.
    func testFetchModels_unexpectedQuantizationType_dropsTheChipNotTheList() async throws {
        let body = #"""
        {
          "models": [
            { "key": "odd-model", "type": "llm", "format": "mlx", "quantization": 4 },
            { "key": "text-embedding-nomic-embed-text-v1.5", "type": "embeddings" }
          ]
        }
        """#
        let models = try await modelListClient(body)
            .fetchModels(config: makeConfig(), visionOnly: false)

        XCTAssertEqual(models.map(\.name), ["odd-model"])
        XCTAssertNil(models.first?.quantization, "an unreadable value is not a value")
        XCTAssertEqual(models.first?.format, "mlx", "the readable half still reports")
    }

    /// A server that reports neither leaves both nil — never inferred from the other, and never an
    /// empty string, which would render as a blank capsule.
    func testFetchModels_serverReportsNeither_bothNilAndModelStillListed() async throws {
        let body = #"""
        { "models": [ { "key": "plain", "type": "llm", "format": "", "quantization": { } } ] }
        """#
        let models = try await modelListClient(body)
            .fetchModels(config: makeConfig(), visionOnly: false)

        XCTAssertEqual(models.map(\.name), ["plain"])
        XCTAssertNil(models.first?.format)
        XCTAssertNil(models.first?.quantization)
    }

    /// The OpenAI-compatible fallback carries no metadata at all, so it reports none — the same
    /// no-guessing rule `modelSupportsVision` follows on that branch.
    func testFetchModels_openAIFallback_reportsNoFormatRatherThanGuessing() async throws {
        let body = #"{"object":"list","data":[{"id":"some-model"}]}"#
        let models = try await modelListClient(body)
            .fetchModels(config: makeConfig(), visionOnly: false)

        XCTAssertEqual(models.map(\.name), ["some-model"])
        XCTAssertNil(models.first?.format)
        XCTAssertNil(models.first?.quantization)
    }

    /// Symmetric pin: `fetchModels(visionOnly: false)` must NOT return
    /// embedding models — chat-model pickers shouldn't show them.
    func testFetchModels_excludesEmbeddingModels() async throws {
        let body = #"""
        {
          "models": [
            { "key": "openai/gpt-oss-20b",                "type": "llm" },
            { "key": "text-embedding-nomic-embed-text-v1.5", "type": "embeddings" }
          ]
        }
        """#
        let stubSession = StubNetworkSession(
            response: HTTPURLResponse(
                url: URL(string: "http://localhost:1234/api/v1/models")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!,
            data: Data(body.utf8)
        )
        let client = NativeLMStudioClient(session: stubSession)
        let config = makeConfig()

        let llms = try await client.fetchModels(config: config, visionOnly: false).map(\.name)
        XCTAssertEqual(llms, ["openai/gpt-oss-20b"])
    }

    /// Dedup must apply on the OpenAI-compatible fallback path too. The native
    /// decoder rejects `{"object":"list","data":[...]}` (no `models` key),
    /// so this exercises the second branch of `fetchModelsMatching`. Without
    /// dedup, an upstream proxy that reports the same model under several
    /// IDs surfaces all of them in the picker.
    func testFetchEmbeddingModels_openAIFallback_dedupesDuplicateIDs() async throws {
        let body = #"""
        {
          "object": "list",
          "data": [
            { "id": "text-embedding-3-small", "object": "model" },
            { "id": "text-embedding-3-large", "object": "model" },
            { "id": "text-embedding-3-small", "object": "model" }
          ]
        }
        """#
        let stubSession = StubNetworkSession(
            response: HTTPURLResponse(
                url: URL(string: "http://localhost:1234/api/v1/models")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!,
            data: Data(body.utf8)
        )
        let client = NativeLMStudioClient(session: stubSession)
        let config = makeConfig()

        let result = try await client.fetchEmbeddingModels(config: config)

        XCTAssertEqual(result.count, 2,
                       "OpenAI-format duplicates must be collapsed before reaching the picker.")
        XCTAssertEqual(
            Set(result),
            ["text-embedding-3-small", "text-embedding-3-large"]
        )
    }

    /// Symmetric to `testFetchEmbeddingModels_dedupesDuplicateKeys`: the chat
    /// picker shares the same `fetchModelsMatching` helper, so duplicates from
    /// the LM Studio response must collapse there too. Pinned separately
    /// because it's a different public surface (`fetchModels(visionOnly:)`)
    /// — a future refactor that splits the helper would catch this fast.
    func testFetchModels_dedupesDuplicateKeys() async throws {
        let body = #"""
        {
          "models": [
            { "key": "openai/gpt-oss-20b",       "type": "llm" },
            { "key": "ibm/granite-4-micro",      "type": "llm" },
            { "key": "openai/gpt-oss-20b",       "type": "llm" }
          ]
        }
        """#
        let stubSession = StubNetworkSession(
            response: HTTPURLResponse(
                url: URL(string: "http://localhost:1234/api/v1/models")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!,
            data: Data(body.utf8)
        )
        let client = NativeLMStudioClient(session: stubSession)
        let config = makeConfig()

        let result = try await client.fetchModels(config: config, visionOnly: false).map(\.name)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(
            Set(result),
            ["openai/gpt-oss-20b", "ibm/granite-4-micro"]
        )
    }

    // MARK: - LM Studio Requires No Credentials

    func testLMStudioConnectsWithoutCredentials() async {
        // LM Studio requires no API key — streaming should attempt a real connection
        // (not fail before even trying due to missing credentials).
        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://127.0.0.1:19999",
            modelName: "model",
            temperature: 0.7
        )

        let stream = sut.streamChat(
            config: config,
            messages: [ChatMessage(role: .user, content: "Hi")],
            tools: [],
            logger: nil,
            stepID: nil
        )

        let error = await collectStreamError(stream)

        // Should fail with a network error (connection refused), NOT an invalidBaseURL error
        // which would indicate URL construction failed before even attempting the connection.
        if let llmError = error as? LLMClientError,
           case .invalidBaseURL = llmError
        {
            XCTFail("LM Studio should attempt a network connection, not fail on URL construction")
        }
        // Any network error (connection refused, timeout) = pass
    }

    // MARK: - Nil Content Handling

    func testNilContentUserMessageBecomesEmptyString() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: nil),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(request.input.textValue,"")
    }

    func testNilContentToolResultBecomesEmptyToolResult() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .tool, content: nil, toolCallID: "c1"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: []
        )

        XCTAssertEqual(request.input.textValue,"[Tool Result]\n")
    }

    // MARK: - System prompt is never omitted

    func testSystemPromptAndToolSchemas_alwaysSent() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are an engineer."),
            ChatMessage(role: .user, content: "Continue"),
        ]
        let tools = [
            makeToolSchema(name: "read_file", description: "Read"),
            makeToolSchema(name: "write_file", description: "Write"),
        ]

        let request = NativeLMStudioClient.buildRequest(
            config: makeConfig(),
            messages: messages,
            tools: tools
        )

        let prompt = try XCTUnwrap(request.systemPrompt)
        XCTAssertTrue(prompt.contains("You are an engineer."))
        XCTAssertTrue(prompt.contains("read_file"), "Tool schemas ride system_prompt")
        XCTAssertTrue(prompt.contains("write_file"))
        XCTAssertEqual(request.input.textValue, "Continue")
    }

}

// MARK: - StubNetworkSession

/// Minimal `NetworkSession` double that replays a canned `(Data, URLResponse)`
/// for any request. Used for deterministic fetchModels filter tests.
private final class StubNetworkSession: NetworkSession, @unchecked Sendable {
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
        // Not exercised by the embedding-filter tests — trap on unexpected use.
        fatalError("StubNetworkSession.sessionBytes not supported")
    }
}
