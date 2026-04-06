import XCTest
@testable import NanoTeams

private extension NativeLMStudioClient.NativeChatInput {
    /// Extracts the text string for test assertions. Returns nil for multimodal input.
    var textValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

final class NativeLMStudioRequestBuilderTests: XCTestCase {

    // MARK: - buildRequest

    func testBuildRequest_stateless_includesSystemPrompt() {
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "test-model")
        let messages = [
            ChatMessage(role: .system, content: "You are a helpful assistant."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: [], session: nil
        )
        XCTAssertNotNil(request.systemPrompt)
        XCTAssertTrue(request.systemPrompt!.contains("helpful assistant"))
        XCTAssertNil(request.previousResponseID)
    }

    func testBuildRequest_stateful_omitsSystemPrompt() {
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "test-model")
        let messages = [
            ChatMessage(role: .system, content: "You are a helpful assistant."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let session = LLMSession(responseID: "resp-123")
        let request = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: [], session: session,
            omitSystemPromptOnContinuation: true
        )
        XCTAssertNil(request.systemPrompt)
        XCTAssertEqual(request.previousResponseID, "resp-123")
    }

    func testBuildRequest_stateful_keepSystemPromptWhenNotOmitting() {
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "test-model")
        let messages = [
            ChatMessage(role: .system, content: "System prompt."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let session = LLMSession(responseID: "resp-456")
        let request = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: [], session: session,
            omitSystemPromptOnContinuation: false
        )
        XCTAssertNotNil(request.systemPrompt)
        XCTAssertEqual(request.previousResponseID, "resp-456")
    }

    func testBuildRequest_withTools_appendsToolSchemaToSystemPrompt() {
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "test-model")
        let messages = [
            ChatMessage(role: .system, content: "Base prompt."),
            ChatMessage(role: .user, content: "Read file"),
        ]
        let tools = [
            ToolSchema(name: "read_file", description: "Read a file", parameters: .object(properties: [:])),
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: tools, session: nil
        )
        XCTAssertNotNil(request.systemPrompt)
        XCTAssertTrue(request.systemPrompt!.contains("Tool Calling"))
        XCTAssertTrue(request.systemPrompt!.contains("read_file"))
        XCTAssertTrue(request.systemPrompt!.contains("Read a file"))
    }

    func testBuildRequest_emptyTools_noToolSection() {
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "test-model")
        let messages = [
            ChatMessage(role: .system, content: "Base prompt."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: [], session: nil
        )
        XCTAssertNotNil(request.systemPrompt)
        XCTAssertFalse(request.systemPrompt!.contains("Tool Calling"))
    }

    func testBuildRequest_stateless_includesAssistantMessages() {
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "test-model")
        let messages = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .user, content: "Q1"),
            ChatMessage(role: .assistant, content: "A1"),
            ChatMessage(role: .user, content: "Q2"),
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: [], session: nil
        )
        XCTAssertTrue(request.input.textValue!.contains("Q1"))
        XCTAssertTrue(request.input.textValue!.contains("[Assistant]"))
        XCTAssertTrue(request.input.textValue!.contains("A1"))
        XCTAssertTrue(request.input.textValue!.contains("Q2"))
    }

    func testBuildRequest_stateful_excludesAssistantMessages() {
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "test-model")
        let messages = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .user, content: "New question"),
            ChatMessage(role: .assistant, content: "Old answer"),
        ]
        let session = LLMSession(responseID: "resp-789")
        let request = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: [], session: session
        )
        XCTAssertTrue(request.input.textValue!.contains("New question"))
        XCTAssertFalse(request.input.textValue!.contains("[Assistant]"))
        XCTAssertFalse(request.input.textValue!.contains("Old answer"))
    }

    func testBuildRequest_toolResults_formattedCorrectly() {
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "test-model")
        let messages = [
            ChatMessage(role: .system, content: "System."),
            ChatMessage(role: .tool, content: "{\"ok\": true}"),
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: [], session: nil
        )
        XCTAssertTrue(request.input.textValue!.contains("[Tool Result]"))
        XCTAssertTrue(request.input.textValue!.contains("{\"ok\": true}"))
    }

    func testBuildRequest_modelName_passedThrough() {
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "my-model-v2")
        let messages = [ChatMessage(role: .user, content: "Hi")]
        let request = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: [], session: nil
        )
        XCTAssertEqual(request.model, "my-model-v2")
        XCTAssertTrue(request.stream)
        XCTAssertTrue(request.store)
    }

    // MARK: - NativeChatRequest encoding

    func testNativeChatRequest_encodesSnakeCaseKeys() throws {
        let request = NativeLMStudioClient.NativeChatRequest(
            model: "test",
            systemPrompt: "prompt",
            input: .text("hello"),
            previousResponseID: "resp-1",
            store: true,
            stream: false,
            maxOutputTokens: 1000,
            temperature: 0.7
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["system_prompt"])
        XCTAssertNotNil(json["previous_response_id"])
        XCTAssertNotNil(json["max_output_tokens"])
        XCTAssertNil(json["systemPrompt"])
        XCTAssertNil(json["previousResponseID"])
        XCTAssertNil(json["maxOutputTokens"])
    }

    func testNativeChatRequest_omitsNilFields() throws {
        let request = NativeLMStudioClient.NativeChatRequest(
            model: "test",
            systemPrompt: nil,
            input: .text("hello"),
            previousResponseID: nil,
            store: true,
            stream: true,
            maxOutputTokens: nil,
            temperature: nil
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["system_prompt"])
        XCTAssertNil(json["previous_response_id"])
        XCTAssertNil(json["max_output_tokens"])
        XCTAssertNil(json["temperature"])
    }
}
