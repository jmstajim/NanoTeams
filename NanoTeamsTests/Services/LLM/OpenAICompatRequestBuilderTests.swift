import XCTest

@testable import NanoTeams

/// `OpenAICompatLMStudioClient.buildRequest` — the `/v1/chat/completions` shape a `.native`
/// request on LM Studio carries. Golden bytes where the shape is the contract.
final class OpenAICompatRequestBuilderTests: XCTestCase {

    private var config: LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "gemma", toolCallingMode: .native)
    }

    private var readFile: ToolSchema {
        ToolSchema(name: "read_file", description: "Read a file.",
                   parameters: JSONSchema(type: "object", properties: ["path": JSONSchema.string("Path")], required: ["path"]))
    }

    private func encoded(_ request: OpenAICompatLMStudioClient.ChatCompletionRequest) throws -> String {
        String(decoding: try JSONCoderFactory.makeWireEncoder().encode(request), as: UTF8.self)
    }

    func testRequest_carriesToolsStreamAndUsageOption() throws {
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config, messages: [ChatMessage(role: .user, content: "go")], tools: [readFile])
        XCTAssertTrue(request.stream)
        XCTAssertEqual(request.streamOptions, .init(includeUsage: true))
        XCTAssertEqual(request.tools?.map(\.function.name), ["read_file"])
        XCTAssertNil(request.maxTokens, "no output ceiling for a role step")
        XCTAssertNil(request.temperature)
        let json = try encoded(request)
        XCTAssertTrue(json.contains(#""stream_options":{"include_usage":true}"#), json)
        XCTAssertFalse(json.contains("max_tokens"))
        XCTAssertFalse(json.contains("temperature"))
    }

    func testSystemPrompt_isTheFirstMessage_withTheNativeBlockAppended() throws {
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config,
            messages: [ChatMessage(role: .system, content: "A"), ChatMessage(role: .system, content: "B"),
                       ChatMessage(role: .user, content: "go")],
            tools: [readFile])
        XCTAssertEqual(request.messages.first?.role, "system")
        let system = try XCTUnwrap(request.messages.first?.content.text)
        XCTAssertTrue(system.hasPrefix("A\n\nB"))
        XCTAssertTrue(system.contains(NativeLMStudioClient.toolBlockMarker))
        XCTAssertFalse(system.contains(NativeLMStudioClient.harmonyBodyMarker))
        XCTAssertFalse(system.contains("**read_file**"))
    }

    func testAssistantCalls_areOpenAIObjects_withStringArguments() throws {
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config,
            messages: [
                ChatMessage(role: .assistant, content: nil,
                            toolCalls: [ChatToolCall(id: "268992578", name: "read_file", argumentsJSON: #"{"path":"App.swift"}"#)]),
                ChatMessage(role: .tool, content: #"{"ok":true}"#, toolCallID: "268992578"),
            ],
            tools: [readFile])
        let json = try encoded(request)
        XCTAssertTrue(json.contains(#"{"content":"","role":"assistant","tool_calls":[{"function":{"arguments":"{\"path\":\"App.swift\"}","name":"read_file"},"id":"268992578","type":"function"}]}"#), json)
        XCTAssertTrue(json.contains(#"{"content":"{\"ok\":true}","role":"tool","tool_call_id":"268992578"}"#), json)
        XCTAssertFalse(json.contains("<|call|>"))
    }

    func testToolResultWithoutID_pairsPositionally() throws {
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config,
            messages: [
                ChatMessage(role: .assistant, content: nil, toolCalls: [ChatToolCall(id: "ask-9", name: "ask_supervisor", argumentsJSON: "{}")]),
                ChatMessage(role: .tool, content: "answer"),
            ],
            tools: [readFile])
        XCTAssertEqual(request.messages.last?.toolCallID, "ask-9")
    }

    func testEmptyArguments_becomeAnEmptyObjectString() throws {
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config,
            messages: [ChatMessage(role: .assistant, content: nil, toolCalls: [ChatToolCall(id: "c", name: "git_status", argumentsJSON: "  ")])],
            tools: [readFile])
        let assistant = request.messages.first { $0.role == "assistant" }
        XCTAssertEqual(assistant?.toolCalls?.first?.function.arguments, "{}")
    }

    func testUserImages_becomeParts_andToolImagesFollowAsAUserTurn() throws {
        let image = ImageContent(base64Data: "QQ==", mimeType: "image/png")
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config,
            messages: [
                ChatMessage(role: .user, content: "look", imageContent: [image]),
                ChatMessage(role: .assistant, content: nil, toolCalls: [ChatToolCall(id: "c", name: "screen_capture", argumentsJSON: "{}")]),
                ChatMessage(role: .tool, content: "shot", toolCallID: "c", imageContent: [image]),
            ],
            tools: [readFile])
        let turns = request.messages.filter { $0.role != "system" }
        XCTAssertEqual(turns.map(\.role), ["user", "assistant", "tool", "user"])
        let json = try encoded(request)
        XCTAssertTrue(json.contains(#"[{"text":"look","type":"text"},{"image_url":{"url":"data:image/png;base64,QQ=="},"type":"image_url"}]"#), json)
        XCTAssertEqual(turns[2].content, .text("shot"), "the tool role takes a string")
        XCTAssertEqual(turns[3].content, .parts([.imageURL("data:image/png;base64,QQ==")]))
    }

    func testBenchmarkKnobs_rideTheirOpenAINames() throws {
        var c = config
        c.temperature = 0
        c.maxOutputTokens = 512
        let json = try encoded(OpenAICompatLMStudioClient.buildRequest(
            config: c, messages: [ChatMessage(role: .user, content: "hi")], tools: []))
        XCTAssertTrue(json.contains(#""max_tokens":512"#), json)
        XCTAssertTrue(json.contains(#""temperature":0"#), json)
        XCTAssertFalse(json.contains("\"tools\""), "a tool-less call declares none")
    }


    // MARK: - Reasoning replay

    /// An assistant turn that carries the model's reasoning replays it in the field the OpenAI
    /// shape reserves for it, `reasoning_content`, beside the calls — the template's own gate
    /// decides what to do with it. Measured 2026-09-14 on `qwythos-9b` (Qwen3.5, LM Studio MLX,
    /// 19.9k tokens): the tool-loop continuation prefilled in 0.39 s with the field and 13.28 s
    /// without it, because a hybrid cache can only be REUSED on a byte-identical continuation
    /// and the continuation is byte-identical only when the turn is re-rendered as generated.
    func testAssistantReasoning_ridesReasoningContent_besideTheCalls() throws {
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config,
            messages: [
                ChatMessage(role: .assistant, content: nil,
                            toolCalls: [ChatToolCall(id: "7", name: "list_files", argumentsJSON: #"{"path":"App"}"#)],
                            reasoning: "I need to call list_files first.\n"),
                ChatMessage(role: .tool, content: #"{"ok":true}"#, toolCallID: "7"),
            ],
            tools: [readFile])
        let assistant = try XCTUnwrap(request.messages.first { $0.role == "assistant" })
        XCTAssertEqual(assistant.reasoningContent, "I need to call list_files first.\n", "verbatim — the template trims")
        let json = try encoded(request)
        XCTAssertTrue(json.contains(#""reasoning_content":"I need to call list_files first.\n""#), json)
        XCTAssertTrue(json.contains(#""tool_calls":[{"function":{"arguments":"{\"path\":\"App\"}","name":"list_files"},"id":"7","type":"function"}]"#), json)
    }

    /// A turn without reasoning carries no key at all — not `null`, not `""`: a template that
    /// reads `message.reasoning_content is string` would render an empty think block for `""`.
    func testAssistantWithoutReasoning_carriesNoReasoningContentKey() throws {
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config,
            messages: [ChatMessage(role: .assistant, content: "plain prose")],
            tools: [readFile])
        XCTAssertNil(request.messages.first { $0.role == "assistant" }?.reasoningContent)
        XCTAssertFalse(try encoded(request).contains("reasoning_content"))
    }

    /// Reasoning is an ASSISTANT fact. A user or tool turn never carries the key even when the
    /// `ChatMessage` does — nothing sets it there, and the wire must not invent a channel.
    func testReasoning_onANonAssistantTurn_isNotRendered() throws {
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config,
            messages: [
                ChatMessage(role: .user, content: "go", reasoning: "stray"),
                ChatMessage(role: .tool, content: "r", toolCallID: "1", reasoning: "stray"),
            ],
            tools: [readFile])
        XCTAssertTrue(request.messages.allSatisfy { $0.reasoningContent == nil })
        XCTAssertFalse(try encoded(request).contains("stray"))
    }

    /// `Content.text` is the one reading the log and the tests share: a string as-is, a parts
    /// array as its text parts joined, images dropped.
    func testContentText_readsBothShapes() {
        XCTAssertEqual(OpenAICompatLMStudioClient.ChatCompletionRequest.Content.text("plain").text, "plain")
        let parts = OpenAICompatLMStudioClient.ChatCompletionRequest.Content.parts([
            .text("look"), .imageURL("data:image/png;base64,QQ=="), .text("closer"),
        ])
        XCTAssertEqual(parts.text, "look\n\ncloser")
        XCTAssertEqual(OpenAICompatLMStudioClient.ChatCompletionRequest.Content.parts([]).text, "")
    }

    /// A system message anywhere in the array is merged into the first message and skipped in
    /// the turn run — never rendered twice, never as a `system` turn mid-conversation.
    func testSystemMessages_areMergedOnce_andSkippedInTheTurnRun() throws {
        let request = OpenAICompatLMStudioClient.buildRequest(
            config: config,
            messages: [
                ChatMessage(role: .system, content: "A"),
                ChatMessage(role: .user, content: "go"),
                ChatMessage(role: .system, content: "B"),
            ],
            tools: [readFile])
        XCTAssertEqual(request.messages.map(\.role), ["system", "user"])
        XCTAssertTrue(request.messages.first?.content.text.hasPrefix("A\n\nB") == true)
    }
}
