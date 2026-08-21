import XCTest

@testable import NanoTeams

/// `OllamaClient.buildRequest` — messages-array construction for `/api/chat`.
/// The unification contract with the LM Studio builder is pinned here: same
/// Harmony tool-schema SSOT, same `[Tool Result]` labelling, no sampling keys.
final class OllamaRequestBuilderTests: XCTestCase {

    private func makeConfig(temperature: Double? = nil) -> LLMConfig {
        LLMConfig(
            provider: .ollama,
            baseURLString: "http://127.0.0.1:11434",
            modelName: "gpt-oss:20b",
            temperature: temperature
        )
    }

    private var sampleTool: ToolSchema {
        ToolSchema(
            name: "read_file",
            description: "Read a file",
            parameters: JSONSchema(type: "object")
        )
    }

    // MARK: - System prompt + tool schema injection

    func testSystemMessagesMergeIntoOneSystemMessage() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .system, content: "A"),
                ChatMessage(role: .system, content: "B"),
                ChatMessage(role: .user, content: "hi"),
            ],
            tools: []
        )
        XCTAssertEqual(request.messages.first?.role, "system")
        XCTAssertEqual(request.messages.first?.content, "A\n\nB")
        XCTAssertEqual(request.messages.filter { $0.role == "system" }.count, 1)
    }

    func testToolSchemas_autoAppendHarmonyBlockToSystem() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .system, content: "You are an engineer."),
                ChatMessage(role: .user, content: "go"),
            ],
            tools: [sampleTool]
        )
        let system = request.messages.first { $0.role == "system" }
        XCTAssertNotNil(system)
        XCTAssertTrue(system!.content.contains(NativeLMStudioClient.harmonyBodyMarker),
                      "Ollama requests must carry the SAME Harmony tool block as LM Studio")
        XCTAssertTrue(system!.content.contains("read_file"))
    }

    func testToolSchemas_noDoubleInjectionWhenPromptAlreadyCarriesBlock() {
        // PromptBuilder places the block via {toolCalling} — the builder must
        // detect the body marker and not append a second copy.
        let prompt = "Role prompt.\n\n" + NativeLMStudioClient.buildToolSchemaSection(tools: [sampleTool])
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .system, content: prompt),
                ChatMessage(role: .user, content: "go"),
            ],
            tools: [sampleTool]
        )
        let system = request.messages.first { $0.role == "system" }!
        let occurrences = system.content.components(
            separatedBy: NativeLMStudioClient.harmonyBodyMarker).count - 1
        XCTAssertEqual(occurrences, 1, "Harmony block must appear exactly once")
    }

    func testNoTools_noHarmonyBlock() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .system, content: "S"),
                ChatMessage(role: .user, content: "hi"),
            ],
            tools: []
        )
        let system = request.messages.first { $0.role == "system" }!
        XCTAssertFalse(system.content.contains(NativeLMStudioClient.harmonyBodyMarker))
    }

    // MARK: - Conversation mapping

    func testToolResultsRideUserChannelWithLabel() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .user, content: "do it"),
                ChatMessage(role: .assistant, content: "<|call|>{\"name\":\"read_file\"}<|end|>"),
                ChatMessage(role: .tool, content: "{\"ok\":true}", toolCallID: "tc-1"),
            ],
            tools: []
        )
        XCTAssertEqual(request.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(request.messages.last?.content, "[Tool Result]\n{\"ok\":true}")
    }

    func testAssistantToolCalls_rematerializedAsHarmonyText() {
        // The streaming path truncates the Harmony envelope out of the
        // persisted assistant content — the stateless resend must rebuild it,
        // or every prior tool-call turn shows the model an empty assistant
        // message followed by an orphan [Tool Result].
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .user, content: "read A"),
                ChatMessage(
                    role: .assistant, content: nil,
                    toolCalls: [ChatToolCall(
                        id: "tc-1", name: "read_file",
                        argumentsJSON: #"{"path":"A.swift"}"#)]),
                ChatMessage(role: .tool, content: "{\"ok\":true}", toolCallID: "tc-1"),
            ],
            tools: []
        )
        let assistant = request.messages.first { $0.role == "assistant" }
        XCTAssertEqual(
            assistant?.content,
            #"<|call|>{"name":"read_file","arguments":{"path":"A.swift"}}<|end|>"#)
    }

    func testAssistantProsePlusToolCall_keepsBoth() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(
                    role: .assistant, content: "Let me check.",
                    toolCalls: [ChatToolCall(id: "a", name: "git_status", argumentsJSON: "{}")]),
            ],
            tools: []
        )
        XCTAssertEqual(
            request.messages.first?.content,
            "Let me check.\n<|call|>{\"name\":\"git_status\",\"arguments\":{}}<|end|>")
    }

    func testConsecutiveUserSideTurnsMergeIntoOneMessage() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .assistant, content: "calls"),
                ChatMessage(role: .tool, content: "r1", toolCallID: "a"),
                ChatMessage(role: .tool, content: "r2", toolCallID: "b"),
                ChatMessage(role: .user, content: "continue"),
            ],
            tools: []
        )
        XCTAssertEqual(request.messages.map(\.role), ["assistant", "user"])
        XCTAssertEqual(
            request.messages.last?.content,
            "[Tool Result]\nr1\n\n[Tool Result]\nr2\n\ncontinue")
    }

    func testAssistantTurnsBreakTheMerge() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .user, content: "u1"),
                ChatMessage(role: .assistant, content: "a1"),
                ChatMessage(role: .user, content: "u2"),
            ],
            tools: []
        )
        XCTAssertEqual(request.messages.map(\.role), ["user", "assistant", "user"])
    }

    // MARK: - Images

    func testImages_rawBase64OnMergedUserMessage() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(
                    role: .user, content: "what is this?",
                    imageContent: [ImageContent(base64Data: "QUJD", mimeType: "image/png")]),
            ],
            tools: []
        )
        // Ollama takes RAW base64 — no "data:mime;base64," prefix.
        XCTAssertEqual(request.messages.first?.images, ["QUJD"])
    }

    func testNoImages_imagesFieldNil() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: []
        )
        XCTAssertNil(request.messages.first?.images)
    }

    // MARK: - Sampling / wire hygiene

    func testDefaultConfig_carriesNoSamplingKeys() throws {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: []
        )
        XCTAssertNil(request.options)
        let json = String(
            data: try JSONCoderFactory.makeWireEncoder().encode(request), encoding: .utf8)!
        XCTAssertFalse(json.contains("temperature"))
        XCTAssertFalse(json.contains("keep_alive"),
                       "Unconfigured (nil) ⇒ omit the key and let the server decide — "
                           + "the same policy every other optional key follows")
        XCTAssertFalse(json.contains("num_ctx"),
                       "num_ctx stays server-side (OLLAMA_CONTEXT_LENGTH): sending it would "
                           + "have to stay CONSTANT across requests or the model reloads and "
                           + "the prefix cache dies")
    }

    /// The benchmark sets a ceiling and NOTHING else, so `options` has to be built from either
    /// knob rather than mapped over temperature alone.
    ///
    /// RED: keep `config.temperature.map { Options(temperature: $0) }` → a benchmark run ships no
    /// `options` at all, the cap silently never reaches Ollama, and the only visible symptom is
    /// that Ollama rows take as long as they always did.
    func testOutputCapAlone_stillShipsOptions() throws {
        var config = makeConfig()
        config.maxOutputTokens = 512
        let request = OllamaClient.buildRequest(
            config: config, messages: [ChatMessage(role: .user, content: "hi")], tools: [])

        XCTAssertEqual(request.options?.numPredict, 512)
        let json = String(
            data: try JSONCoderFactory.makeWireEncoder().encode(request), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""num_predict":512"#), json)
        XCTAssertFalse(json.contains("temperature"), "an unset knob still omits its key")
    }

    /// Both knobs together, because they are built by one expression and a fix for one can drop
    /// the other. RED: rebuild `options` from `maxOutputTokens` alone → the judge's temperature
    /// pin disappears and security verdicts regain sampling variance.
    func testTemperatureAndCap_bothRideOptions() throws {
        var config = makeConfig()
        config.temperature = 0
        config.maxOutputTokens = 128
        let request = OllamaClient.buildRequest(
            config: config, messages: [ChatMessage(role: .user, content: "hi")], tools: [])

        XCTAssertEqual(request.options?.temperature, 0)
        XCTAssertEqual(request.options?.numPredict, 128)
    }

    /// A configured keep-alive MUST reach the wire, on every request — Ollama restarts the
    /// idle timer per call. Without it the model (and its KV prefix cache) is evicted after
    /// Ollama's 5-minute default, which expires during a human's `ask_supervisor`
    /// round-trip: exactly when the replayed conversation needs the cache warm. Measured on
    /// this project's models: a miss costs ~7 s instead of ~80 ms at 13k tokens.
    func testConfiguredKeepAlive_ridesTheWireAsSeconds() throws {
        var config = makeConfig()
        config.keepAliveSeconds = 1800
        let request = OllamaClient.buildRequest(
            config: config,
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: []
        )
        XCTAssertEqual(request.keepAlive, 1800)
        let json = String(
            data: try JSONCoderFactory.makeWireEncoder().encode(request), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"keep_alive\":1800"),
                      "snake_case wire key, seconds as a number — got: \(json)")
    }

    /// `0` is Ollama's "unload immediately" and must survive as a real value rather than
    /// being swallowed by an `if non-zero` style guard.
    func testZeroKeepAlive_isSentNotDropped() throws {
        var config = makeConfig()
        config.keepAliveSeconds = 0
        let request = OllamaClient.buildRequest(
            config: config,
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: []
        )
        let json = String(
            data: try JSONCoderFactory.makeWireEncoder().encode(request), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"keep_alive\":0"), "got: \(json)")
    }

    func testJudgeVerdictPin_temperatureRidesOptions() throws {
        let request = OllamaClient.buildRequest(
            config: makeConfig(temperature: 0),
            messages: [ChatMessage(role: .user, content: "judge")],
            tools: []
        )
        XCTAssertEqual(request.options?.temperature, 0)
        let json = String(
            data: try JSONCoderFactory.makeWireEncoder().encode(request), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""options":{"temperature":0}"#))
    }

    // MARK: - Degenerate shapes

    func testEmptyMessages_producesEmptyMessagesArray() {
        let request = OllamaClient.buildRequest(config: makeConfig(), messages: [], tools: [])
        XCTAssertTrue(request.messages.isEmpty)
    }

    func testToolsWithoutAnySystemMessage_synthesizesSystemWithToolBlockOnly() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [ChatMessage(role: .user, content: "go")],
            tools: [sampleTool]
        )
        XCTAssertEqual(request.messages.first?.role, "system",
                       "direct-LLM-call services build no system message — the tool block must still ship")
        XCTAssertTrue(request.messages.first!.content.hasPrefix("## Tool Calling"))
    }

    func testAssistantNilContentEmptyToolCalls_emptyContent() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [ChatMessage(role: .assistant, content: nil, toolCalls: [])],
            tools: []
        )
        XCTAssertEqual(request.messages, [
            OllamaClient.ChatRequestMessage(role: "assistant", content: "", images: nil)
        ])
    }

    func testToolNilContent_labelOnly() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [ChatMessage(role: .tool, content: nil, toolCallID: "t")],
            tools: []
        )
        XCTAssertEqual(request.messages.first?.content, "[Tool Result]\n")
    }

    func testMultipleToolCallsOnOneAssistantTurn_allRematerializedInOrder() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .assistant, content: nil, toolCalls: [
                    ChatToolCall(id: "a", name: "read_file", argumentsJSON: #"{"path":"a"}"#),
                    ChatToolCall(id: "b", name: "git_status", argumentsJSON: "{}"),
                ]),
            ],
            tools: []
        )
        XCTAssertEqual(
            request.messages.first?.content,
            "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a\"}}<|end|>\n"
                + "<|call|>{\"name\":\"git_status\",\"arguments\":{}}<|end|>")
    }

    /// Structural pin for the shared renderer: the wire's assistant content IS
    /// `content + HarmonyToolCallEnvelope.appendedWireText(for:)`. Tautological while the
    /// builder delegates — which is the point. It fails the moment anyone re-inlines the loop
    /// and lets the wire drift from the two measurement surfaces that price the same bytes
    /// (`ContextBudgetPolicy.estimateTokens`, `PromptPrefixFingerprint.chain`).
    func testAssistantContent_isContentPlusTheSharedEnvelopeRender() {
        let fixtures: [ChatMessage] = [
            ChatMessage(role: .assistant, content: nil, toolCalls: [
                ChatToolCall(id: "a", name: "read_file", argumentsJSON: #"{"path":"a"}"#),
            ]),
            ChatMessage(role: .assistant, content: "prose", toolCalls: [
                ChatToolCall(id: "a", name: "git_status", argumentsJSON: "{}"),
                ChatToolCall(id: "b", name: "git_log", argumentsJSON: #"{"limit":5}"#),
            ]),
            ChatMessage(role: .assistant, content: "no calls at all"),
            ChatMessage(role: .assistant, content: "", toolCalls: []),
        ]
        for message in fixtures {
            let wire = OllamaClient.buildRequest(
                config: makeConfig(), messages: [message], tools: []
            ).messages.first { $0.role == "assistant" }?.content
            XCTAssertEqual(
                wire,
                (message.content ?? "") + HarmonyToolCallEnvelope.appendedWireText(for: message))
        }
    }

    func testImagesAcrossMergedUserAndToolTurns_accumulateOnOneMessage() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [
                ChatMessage(role: .tool, content: "shot taken", toolCallID: "t",
                            imageContent: [ImageContent(base64Data: "QQ==", mimeType: "image/png")]),
                ChatMessage(role: .user, content: "and this one",
                            imageContent: [ImageContent(base64Data: "Qg==", mimeType: "image/png")]),
            ],
            tools: []
        )
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages.first?.images, ["QQ==", "Qg=="])
    }

    func testUserNilContentWithImageOnly_stillProducesMessageWithImage() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [ChatMessage(
                role: .user, content: nil,
                imageContent: [ImageContent(base64Data: "QQ==", mimeType: "image/jpeg")])],
            tools: []
        )
        XCTAssertEqual(request.messages.first?.images, ["QQ=="])
        XCTAssertEqual(request.messages.first?.role, "user")
    }

    func testAssistantImages_documentedAsDropped() {
        // Pinned limitation: assistant turns never carry images in practice
        // (vision inputs arrive on user/tool turns) — the builder drops them
        // rather than inventing an unsupported wire shape.
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [ChatMessage(
                role: .assistant, content: "look",
                imageContent: [ImageContent(base64Data: "QQ==", mimeType: "image/png")])],
            tools: []
        )
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertNil(request.messages.first?.images)
    }

    func testNonZeroTemperature_ridesOptionsToo() throws {
        let request = OllamaClient.buildRequest(
            config: makeConfig(temperature: 0.7),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: []
        )
        XCTAssertEqual(request.options?.temperature, 0.7)
    }

    func testStreamTrueAndModelFromConfig() {
        let request = OllamaClient.buildRequest(
            config: makeConfig(),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: []
        )
        XCTAssertTrue(request.stream)
        XCTAssertEqual(request.model, "gpt-oss:20b")
    }
}
