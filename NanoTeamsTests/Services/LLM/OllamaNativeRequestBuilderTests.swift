import XCTest

@testable import NanoTeams

/// `OllamaClient.buildRequest` under `.native`: the catalog on `tools`, assistant calls as
/// `tool_calls` objects, every result its own `role: tool` message — and the prompt-taught
/// bytes untouched, which `OllamaRequestBuilderTests` pins separately.
final class OllamaNativeRequestBuilderTests: XCTestCase {

    private func config(_ mode: ToolCallingMode) -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "ornith",
                  toolCallingMode: mode)
    }

    private var readFile: ToolSchema {
        ToolSchema(name: "read_file", description: "Read a file.",
                   parameters: JSONSchema(type: "object", properties: ["path": JSONSchema.string("Path")], required: ["path"]))
    }

    private func encoded(_ request: OllamaClient.ChatRequest) throws -> String {
        String(decoding: try JSONCoderFactory.makeWireEncoder().encode(request), as: UTF8.self)
    }

    /// The turns after the system message the builder always writes when `tools` is non-empty
    /// (the chip is appended to an absent prompt too) — the shape under test is the turn run.
    private func nonSystem(_ request: OllamaClient.ChatRequest) -> [OllamaClient.ChatRequestMessage] {
        request.messages.filter { $0.role != "system" }
    }

    // MARK: - Catalog

    func testNative_sendsTheCatalogOnTools_andNoHarmonyLesson() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [ChatMessage(role: .system, content: "S"), ChatMessage(role: .user, content: "go")],
            tools: [readFile])
        XCTAssertEqual(request.tools?.map(\.function.name), ["read_file"])
        let system = try XCTUnwrap(request.messages.first { $0.role == "system" }?.content)
        XCTAssertFalse(system.contains(NativeLMStudioClient.harmonyBodyMarker), "no format lesson under native")
        XCTAssertFalse(system.contains("**read_file**"), "no prose catalog — it rides `tools`")
        XCTAssertTrue(system.contains(NativeLMStudioClient.oneToolPerResponseRule))
        XCTAssertTrue(system.contains(NativeLMStudioClient.toolBlockMarker), "the injection boundary still ships")
        let json = try encoded(request)
        XCTAssertTrue(json.contains(#""tools":[{"function":{"description":"Read a file.","name":"read_file""#), json)
    }

    func testPromptTaught_sendsNoToolsField() throws {
        let request = OllamaClient.buildRequest(
            config: config(.promptTaught),
            messages: [ChatMessage(role: .user, content: "go")], tools: [readFile])
        XCTAssertNil(request.tools)
        XCTAssertFalse(try encoded(request).contains("\"tools\""))
    }

    /// A native config with NO tools is a tool-less call (a judge, a consultation): nothing
    /// native about the wire, and no empty `tools` array either — some templates read `[]`
    /// as "tools were declared".
    func testNative_withoutTools_isTheOrdinaryWire() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [ChatMessage(role: .assistant, content: "hi"), ChatMessage(role: .tool, content: "r", toolCallID: "t")],
            tools: [])
        XCTAssertNil(request.tools)
        XCTAssertEqual(request.messages.map(\.role), ["assistant", "user"], "the tool result merges into the user channel as before")
    }

    // MARK: - Replay

    func testNative_assistantCalls_areObjectsNotHarmonyText() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [
                ChatMessage(role: .assistant, content: "Let me look.",
                            toolCalls: [ChatToolCall(id: "c1", name: "read_file", argumentsJSON: #"{"path":"a.swift","depth":1}"#)]),
                ChatMessage(role: .tool, content: #"{"ok":true}"#, toolCallID: "c1"),
            ],
            tools: [readFile])
        let assistant = try XCTUnwrap(request.messages.first { $0.role == "assistant" })
        XCTAssertEqual(assistant.content, "Let me look.", "no envelope appended")
        XCTAssertEqual(assistant.toolCalls?.count, 1)
        XCTAssertEqual(assistant.toolCalls?.first?.function.name, "read_file")
        XCTAssertEqual(assistant.toolCalls?.first?.function.index, 0)
        let json = try encoded(request)
        XCTAssertTrue(json.contains(#""tool_calls":[{"function":{"arguments":{"depth":1,"path":"a.swift"},"index":0,"name":"read_file"}}]"#), json)
        XCTAssertFalse(json.contains("<|call|>"))
    }

    func testNative_toolResults_areTheirOwnRole_namedByTheCallTheyAnswer() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [
                ChatMessage(role: .assistant, content: nil,
                            toolCalls: [ChatToolCall(id: "c1", name: "read_file", argumentsJSON: "{}"),
                                        ChatToolCall(id: "c2", name: "git_status", argumentsJSON: "{}")]),
                ChatMessage(role: .tool, content: "r1", toolCallID: "c1"),
                ChatMessage(role: .tool, content: "r2", toolCallID: "c2"),
                ChatMessage(role: .user, content: "continue"),
            ],
            tools: [readFile])
        let turns = nonSystem(request)
        XCTAssertEqual(turns.map(\.role), ["assistant", "tool", "tool", "user"])
        XCTAssertEqual(turns[1].content, "r1", "no `[Tool Result]` label")
        XCTAssertEqual(turns[1].toolName, "read_file")
        XCTAssertEqual(turns[2].toolName, "git_status")
        XCTAssertEqual(turns[0].content, "", "a call-only turn carries an empty string, not nil")
        let json = try encoded(request)
        XCTAssertTrue(json.contains(#"{"content":"r1","role":"tool","tool_name":"read_file"}"#), json)
    }

    /// The Supervisor's answer on re-entry carries no id (`+StepLifecycle`): it answers the
    /// preceding turn's ask positionally.
    func testNative_toolResultWithoutID_pairsPositionally() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [
                ChatMessage(role: .assistant, content: nil,
                            toolCalls: [ChatToolCall(id: "ask-1", name: "ask_supervisor", argumentsJSON: #"{"question":"?"}"#)]),
                ChatMessage(role: .tool, content: #"{"ok":true,"response":"yes"}"#),
            ],
            tools: [readFile])
        XCTAssertEqual(request.messages.last?.role, "tool")
        XCTAssertEqual(request.messages.last?.toolName, "ask_supervisor")
    }

    /// Unparseable arguments become `{}`, never a refused request.
    func testNative_unparseableArguments_becomeAnEmptyObject() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [ChatMessage(role: .assistant, content: nil,
                                   toolCalls: [ChatToolCall(id: "c", name: "read_file", argumentsJSON: "{not json")])],
            tools: [readFile])
        let assistant = request.messages.first { $0.role == "assistant" }
        XCTAssertEqual(assistant?.toolCalls?.first?.function.arguments, .object([:]))
    }

    func testNative_consecutiveUserTurnsStillMerge_butAToolTurnClosesTheRun() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [
                ChatMessage(role: .user, content: "a"),
                ChatMessage(role: .user, content: "b"),
                ChatMessage(role: .assistant, content: nil, toolCalls: [ChatToolCall(id: "c", name: "read_file", argumentsJSON: "{}")]),
                ChatMessage(role: .tool, content: "r", toolCallID: "c"),
                ChatMessage(role: .user, content: "c"),
            ],
            tools: [readFile])
        let turns = nonSystem(request)
        XCTAssertEqual(turns.map(\.role), ["user", "assistant", "tool", "user"])
        XCTAssertEqual(turns[0].content, "a\n\nb")
    }

    func testNative_imagesOnAToolTurn_rideTheToolMessage() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [
                ChatMessage(role: .assistant, content: nil, toolCalls: [ChatToolCall(id: "c", name: "screen_capture", argumentsJSON: "{}")]),
                ChatMessage(role: .tool, content: "shot", toolCallID: "c",
                            imageContent: [ImageContent(base64Data: "QQ==", mimeType: "image/png")]),
            ],
            tools: [readFile])
        XCTAssertEqual(request.messages.last?.images, ["QQ=="])
    }

    // MARK: - The chip and the auto-append agree in both modes

    func testNative_promptAlreadyCarryingTheBlock_isNotDoubled() throws {
        let chip = PromptBuilder.formatToolCallingBlock(tools: [readFile], mode: .native)
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [ChatMessage(role: .system, content: "Role.\n\n## Tool Calling\n\n" + chip),
                       ChatMessage(role: .user, content: "go")],
            tools: [readFile])
        let system = try XCTUnwrap(request.messages.first?.content)
        XCTAssertEqual(system.components(separatedBy: NativeLMStudioClient.toolBlockMarker).count - 1, 1)
    }


    /// A system message mid-array is merged into the one system turn and never becomes a turn.
    func testNative_systemMessagesMidArray_mergeIntoTheOneSystemTurn() {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [
                ChatMessage(role: .system, content: "A"),
                ChatMessage(role: .user, content: "go"),
                ChatMessage(role: .system, content: "B"),
            ],
            tools: [readFile])
        XCTAssertEqual(request.messages.map(\.role), ["system", "user"])
        XCTAssertTrue(request.messages[0].content.hasPrefix("A\n\nB"))
    }

    // MARK: - Reasoning replay

    /// Under `.native` an assistant turn's reasoning rides Ollama's own `thinking` field — the
    /// message field its API documents for thinking models — verbatim, beside the calls. The
    /// renderer's gate decides whether the model sees it again; the client's job is to hand the
    /// turn back as it was generated, so the server's cache can continue rather than restart.
    func testNative_assistantReasoning_ridesThinking_besideTheCalls() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [
                ChatMessage(role: .assistant, content: nil,
                            toolCalls: [ChatToolCall(id: "c", name: "read_file", argumentsJSON: #"{"path":"A.swift"}"#)],
                            reasoning: "Read the file first.\n"),
                ChatMessage(role: .tool, content: "text", toolCallID: "c"),
            ],
            tools: [readFile])
        let assistant = try XCTUnwrap(nonSystem(request).first { $0.role == "assistant" })
        XCTAssertEqual(assistant.thinking, "Read the file first.\n")
        XCTAssertEqual(assistant.toolCalls?.map(\.function.name), ["read_file"])
        let json = try encoded(request)
        XCTAssertTrue(json.contains(#""thinking":"Read the file first.\n""#), json)
    }

    /// No reasoning → no key. `""` is not the same statement as absence to a renderer.
    func testNative_assistantWithoutReasoning_carriesNoThinkingKey() throws {
        let request = OllamaClient.buildRequest(
            config: config(.native),
            messages: [ChatMessage(role: .assistant, content: "prose")],
            tools: [readFile])
        XCTAssertNil(nonSystem(request).first?.thinking)
        XCTAssertFalse(try encoded(request).contains("\"thinking\""))
    }

    /// Under `.promptTaught` the assistant turn is Harmony TEXT and the reasoning has no slot:
    /// neither the field nor the words reach the wire (playbook A6.16 — reasoning is never
    /// content-channel text).
    func testPromptTaught_neverCarriesReasoning_asFieldOrText() throws {
        let request = OllamaClient.buildRequest(
            config: config(.promptTaught),
            messages: [
                ChatMessage(role: .assistant, content: "prose",
                            toolCalls: [ChatToolCall(id: "c", name: "read_file", argumentsJSON: "{}")],
                            reasoning: "SECRET-REASONING"),
            ],
            tools: [readFile])
        let json = try encoded(request)
        XCTAssertFalse(json.contains("\"thinking\""), json)
        XCTAssertFalse(json.contains("SECRET-REASONING"), json)
    }
}
