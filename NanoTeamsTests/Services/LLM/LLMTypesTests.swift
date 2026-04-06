//
//  LLMTypesTests.swift
//  NanoTeamsTests
//
//  Tests for LLMTypes value types: LLMProvider, LLMConfig, StreamEvent,
//  TokenUsage, LLMSession, ChatMessage, ChatToolCall, LLMClientError.
//

import XCTest
@testable import NanoTeams

final class LLMTypesTests: XCTestCase {

    // MARK: - LLMProvider: Cases & Identifiable

    func testLLMProviderAllCasesExist() {
        let cases = LLMProvider.allCases
        XCTAssertEqual(cases.count, 1)
        XCTAssertTrue(cases.contains(.lmStudio))
    }

    func testLLMProviderIDMatchesRawValue() {
        for provider in LLMProvider.allCases {
            XCTAssertEqual(provider.id, provider.rawValue)
        }
    }

    // MARK: - LLMProvider: displayName

    func testLLMProviderDisplayNameLMStudio() {
        XCTAssertEqual(LLMProvider.lmStudio.displayName, "LM Studio")
    }

    // MARK: - LLMProvider: defaultBaseURL

    func testLLMProviderDefaultBaseURL() {
        XCTAssertEqual(LLMProvider.lmStudio.defaultBaseURL, "http://localhost:1234")
    }

    // MARK: - LLMProvider: defaultModel

    func testLLMProviderDefaultModel() {
        XCTAssertEqual(LLMProvider.lmStudio.defaultModel, "openai/gpt-oss-20b")
    }

    // MARK: - LLMProvider: supportsModelFetching

    func testLLMProviderSupportsModelFetchingTrue() {
        XCTAssertTrue(LLMProvider.lmStudio.supportsModelFetching)
    }

    // MARK: - LLMProvider: supportsStatefulSessions

    func testLLMProviderSupportsStatefulSessionsTrue() {
        XCTAssertTrue(LLMProvider.lmStudio.supportsStatefulSessions)
    }

    // MARK: - LLMProvider: defaultMaxTokens

    func testLLMProviderDefaultMaxTokensLMStudio() {
        XCTAssertEqual(LLMProvider.lmStudio.defaultMaxTokens, 0)
    }

    // MARK: - LLMProvider: Codable Round-Trip

    func testLLMProviderCodableRoundTrip() throws {
        for provider in LLMProvider.allCases {
            let encoder = JSONEncoder()
            let data = try encoder.encode(provider)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(LLMProvider.self, from: data)
            XCTAssertEqual(decoded, provider)
        }
    }

    func testLLMProviderRawValueEncoding() throws {
        let data = try JSONEncoder().encode(LLMProvider.lmStudio)
        let jsonString = String(data: data, encoding: .utf8)
        XCTAssertEqual(jsonString, "\"lmStudio\"")
    }

    // MARK: - LLMConfig: Default Init

    func testLLMConfigDefaultInit() {
        let config = LLMConfig()
        XCTAssertEqual(config.provider, .lmStudio)
        XCTAssertEqual(config.baseURLString, LLMProvider.lmStudio.defaultBaseURL)
        XCTAssertEqual(config.modelName, LLMProvider.lmStudio.defaultModel)
        XCTAssertEqual(config.maxTokens, LLMProvider.lmStudio.defaultMaxTokens)
        XCTAssertNil(config.temperature)
    }

    // MARK: - LLMConfig: Init with All Explicit Values

    func testLLMConfigInitWithAllExplicitValues() {
        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://custom.local:8888",
            modelName: "custom-model-v1",
            maxTokens: 4096,
            temperature: 0.3
        )
        XCTAssertEqual(config.provider, .lmStudio)
        XCTAssertEqual(config.baseURLString, "http://custom.local:8888")
        XCTAssertEqual(config.modelName, "custom-model-v1")
        XCTAssertEqual(config.maxTokens, 4096)
        XCTAssertEqual(config.temperature, 0.3)
    }

    func testLLMConfigHashableIncludesBaseURL() {
        let config1 = LLMConfig(provider: .lmStudio, baseURLString: "http://a.local:1234")
        let config2 = LLMConfig(provider: .lmStudio, baseURLString: "http://b.local:5678")
        XCTAssertNotEqual(config1, config2)
    }

    func testLLMConfigHashableIncludesModelName() {
        let config1 = LLMConfig(provider: .lmStudio, modelName: "model-a")
        let config2 = LLMConfig(provider: .lmStudio, modelName: "model-b")
        XCTAssertNotEqual(config1, config2)
    }

    func testLLMConfigHashableIncludesMaxTokens() {
        let config1 = LLMConfig(provider: .lmStudio, maxTokens: 100)
        let config2 = LLMConfig(provider: .lmStudio, maxTokens: 200)
        XCTAssertNotEqual(config1, config2)
    }

    func testLLMConfigHashableIncludesTemperature() {
        let config1 = LLMConfig(provider: .lmStudio, temperature: 0.5)
        let config2 = LLMConfig(provider: .lmStudio, temperature: 0.9)
        XCTAssertNotEqual(config1, config2)
    }

    // MARK: - StreamEvent: Empty Event

    func testStreamEventDefaultIsEmpty() {
        let event = StreamEvent()
        XCTAssertTrue(event.isEmpty)
        XCTAssertEqual(event.contentDelta, "")
        XCTAssertEqual(event.thinkingDelta, "")
        XCTAssertTrue(event.toolCallDeltas.isEmpty)
        XCTAssertNil(event.tokenUsage)
        XCTAssertNil(event.session)
    }

    func testStreamEventWithContentIsNotEmpty() {
        let event = StreamEvent(contentDelta: "Hello")
        XCTAssertFalse(event.isEmpty)
    }

    func testStreamEventWithThinkingIsNotEmpty() {
        let event = StreamEvent(thinkingDelta: "Thinking...")
        XCTAssertFalse(event.isEmpty)
    }

    func testStreamEventWithToolCallDeltasIsNotEmpty() {
        let delta = StreamEvent.ToolCallDelta(index: 0, id: "tc-1", name: "read_file", argumentsDelta: "{}")
        let event = StreamEvent(toolCallDeltas: [delta])
        XCTAssertFalse(event.isEmpty)
    }

    func testStreamEventWithTokenUsageIsNotEmpty() {
        let event = StreamEvent(tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 5))
        XCTAssertFalse(event.isEmpty)
    }

    func testStreamEventWithSessionIsNotEmpty() {
        let event = StreamEvent(session: LLMSession(responseID: "resp-1"))
        XCTAssertFalse(event.isEmpty)
    }

    func testStreamEventWithProcessingProgressIsNotEmpty() {
        let event = StreamEvent(processingProgress: 0.45)
        XCTAssertFalse(event.isEmpty)
    }

    func testStreamEventWithProcessingProgressZeroIsNotEmpty() {
        let event = StreamEvent(processingProgress: 0.0)
        XCTAssertFalse(event.isEmpty)
    }

    func testStreamEventProcessingProgressNilIsEmpty() {
        let event = StreamEvent(processingProgress: nil)
        XCTAssertTrue(event.isEmpty)
    }

    func testStreamEventProcessingProgressStoresValue() {
        let event = StreamEvent(processingProgress: 0.75)
        XCTAssertEqual(event.processingProgress, 0.75)
    }

    func testStreamEventDefaultHasNilProcessingProgress() {
        let event = StreamEvent()
        XCTAssertNil(event.processingProgress)
    }

    // MARK: - StreamEvent: ToolCallDelta

    func testToolCallDeltaStoresAllProperties() {
        let delta = StreamEvent.ToolCallDelta(
            index: 2,
            id: "call-abc",
            name: "git_status",
            argumentsDelta: "{\"path\": \"/tmp\"}"
        )
        XCTAssertEqual(delta.index, 2)
        XCTAssertEqual(delta.id, "call-abc")
        XCTAssertEqual(delta.name, "git_status")
        XCTAssertEqual(delta.argumentsDelta, "{\"path\": \"/tmp\"}")
    }

    func testToolCallDeltaAllNilOptionals() {
        let delta = StreamEvent.ToolCallDelta()
        XCTAssertNil(delta.index)
        XCTAssertNil(delta.id)
        XCTAssertNil(delta.name)
        XCTAssertNil(delta.argumentsDelta)
    }

    // MARK: - StreamEvent: Hashable

    func testStreamEventHashableEquality() {
        let event1 = StreamEvent(contentDelta: "x", thinkingDelta: "y")
        let event2 = StreamEvent(contentDelta: "x", thinkingDelta: "y")
        XCTAssertEqual(event1, event2)
    }

    func testStreamEventHashableInequality() {
        let event1 = StreamEvent(contentDelta: "a")
        let event2 = StreamEvent(contentDelta: "b")
        XCTAssertNotEqual(event1, event2)
    }

    // MARK: - TokenUsage: Default Init

    func testTokenUsageDefaultInit() {
        let usage = TokenUsage()
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
    }

    func testTokenUsageCustomInit() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
    }

    // MARK: - TokenUsage: Codable Round-Trip

    func testTokenUsageCodableRoundTrip() throws {
        let original = TokenUsage(inputTokens: 1500, outputTokens: 750)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        XCTAssertEqual(decoded.inputTokens, 1500)
        XCTAssertEqual(decoded.outputTokens, 750)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - TokenUsage: Accumulate

    func testTokenUsageAccumulate() {
        var usage = TokenUsage(inputTokens: 100, outputTokens: 50)
        let other = TokenUsage(inputTokens: 200, outputTokens: 80)
        usage.accumulate(other)
        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.outputTokens, 130)
    }

    func testTokenUsageAccumulateFromZero() {
        var usage = TokenUsage()
        usage.accumulate(TokenUsage(inputTokens: 42, outputTokens: 17))
        XCTAssertEqual(usage.inputTokens, 42)
        XCTAssertEqual(usage.outputTokens, 17)
    }

    func testTokenUsageAccumulateMultipleTimes() {
        var usage = TokenUsage(inputTokens: 10, outputTokens: 5)
        usage.accumulate(TokenUsage(inputTokens: 20, outputTokens: 10))
        usage.accumulate(TokenUsage(inputTokens: 30, outputTokens: 15))
        XCTAssertEqual(usage.inputTokens, 60)
        XCTAssertEqual(usage.outputTokens, 30)
    }

    // MARK: - LLMSession: Init and Hashable

    func testLLMSessionInit() {
        let session = LLMSession(responseID: "resp-abc-123")
        XCTAssertEqual(session.responseID, "resp-abc-123")
    }

    func testLLMSessionHashableEquality() {
        let session1 = LLMSession(responseID: "resp-1")
        let session2 = LLMSession(responseID: "resp-1")
        XCTAssertEqual(session1, session2)
    }

    func testLLMSessionHashableInequality() {
        let session1 = LLMSession(responseID: "resp-1")
        let session2 = LLMSession(responseID: "resp-2")
        XCTAssertNotEqual(session1, session2)
    }

    func testLLMSessionSetDeduplication() {
        let session1 = LLMSession(responseID: "resp-1")
        let session2 = LLMSession(responseID: "resp-1")
        let set: Set<LLMSession> = [session1, session2]
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - MessageRole: Cases

    func testMessageRoleCases() {
        XCTAssertEqual(MessageRole.system.rawValue, "system")
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.assistant.rawValue, "assistant")
        XCTAssertEqual(MessageRole.tool.rawValue, "tool")
    }

    // MARK: - ChatMessage: Basic Creation

    func testChatMessageSystemRole() {
        let msg = ChatMessage(role: .system, content: "You are a helpful assistant.")
        XCTAssertEqual(msg.role, .system)
        XCTAssertEqual(msg.content, "You are a helpful assistant.")
        XCTAssertNil(msg.toolCallID)
        XCTAssertNil(msg.toolCalls)
        XCTAssertNil(msg.isToolError)
    }

    func testChatMessageUserRole() {
        let msg = ChatMessage(role: .user, content: "Hello!")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.content, "Hello!")
    }

    func testChatMessageAssistantWithToolCalls() {
        let toolCall = ChatToolCall(id: "tc-1", name: "read_file", argumentsJSON: "{\"path\": \"/tmp/a.txt\"}")
        let msg = ChatMessage(role: .assistant, content: nil, toolCalls: [toolCall])
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertNil(msg.content)
        XCTAssertEqual(msg.toolCalls?.count, 1)
        XCTAssertEqual(msg.toolCalls?.first?.name, "read_file")
    }

    func testChatMessageToolRole() {
        let msg = ChatMessage(role: .tool, content: "file contents here", toolCallID: "tc-1")
        XCTAssertEqual(msg.role, .tool)
        XCTAssertEqual(msg.content, "file contents here")
        XCTAssertEqual(msg.toolCallID, "tc-1")
    }

    func testChatMessageToolRoleWithError() {
        let msg = ChatMessage(role: .tool, content: "Error: file not found", toolCallID: "tc-2", isToolError: true)
        XCTAssertEqual(msg.isToolError, true)
    }

    // MARK: - ChatMessage: Codable Round-Trip

    func testChatMessageCodableRoundTripSimple() throws {
        let original = ChatMessage(role: .user, content: "Test message")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.content, "Test message")
        XCTAssertNil(decoded.toolCallID)
        XCTAssertNil(decoded.toolCalls)
        XCTAssertNil(decoded.isToolError)
    }

    func testChatMessageCodableRoundTripWithToolCalls() throws {
        let toolCall = ChatToolCall(id: "tc-42", name: "git_status", argumentsJSON: "{}")
        let original = ChatMessage(role: .assistant, content: "Let me check.", toolCalls: [toolCall])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, .assistant)
        XCTAssertEqual(decoded.content, "Let me check.")
        XCTAssertEqual(decoded.toolCalls?.count, 1)
        XCTAssertEqual(decoded.toolCalls?.first?.id, "tc-42")
        XCTAssertEqual(decoded.toolCalls?.first?.name, "git_status")
        XCTAssertEqual(decoded.toolCalls?.first?.argumentsJSON, "{}")
    }

    func testChatMessageCodableRoundTripToolResponse() throws {
        let original = ChatMessage(role: .tool, content: "result", toolCallID: "tc-99", isToolError: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, .tool)
        XCTAssertEqual(decoded.toolCallID, "tc-99")
        XCTAssertEqual(decoded.isToolError, false)
    }

    func testChatMessageCodingKeysUseSnakeCase() throws {
        let toolCall = ChatToolCall(id: "tc-1", name: "read_file", argumentsJSON: "{}")
        let msg = ChatMessage(role: .tool, content: "ok", toolCallID: "tc-1", toolCalls: [toolCall], isToolError: true)
        let data = try JSONEncoder().encode(msg)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"tool_call_id\""), "Should use snake_case key tool_call_id")
        XCTAssertTrue(jsonString.contains("\"tool_calls\""), "Should use snake_case key tool_calls")
        XCTAssertTrue(jsonString.contains("\"is_tool_error\""), "Should use snake_case key is_tool_error")
    }

    // MARK: - ChatMessage: Hashable

    func testChatMessageHashableEquality() {
        let msg1 = ChatMessage(role: .user, content: "hello")
        let msg2 = ChatMessage(role: .user, content: "hello")
        XCTAssertEqual(msg1, msg2)
    }

    func testChatMessageHashableInequality() {
        let msg1 = ChatMessage(role: .user, content: "hello")
        let msg2 = ChatMessage(role: .assistant, content: "hello")
        XCTAssertNotEqual(msg1, msg2)
    }

    // MARK: - ChatToolCall: Init and Properties

    func testChatToolCallInit() {
        let tc = ChatToolCall(id: "call-123", name: "write_file", argumentsJSON: "{\"path\":\"/a.txt\",\"content\":\"hi\"}")
        XCTAssertEqual(tc.id, "call-123")
        XCTAssertEqual(tc.name, "write_file")
        XCTAssertEqual(tc.argumentsJSON, "{\"path\":\"/a.txt\",\"content\":\"hi\"}")
    }

    // MARK: - ChatToolCall: Codable Round-Trip

    func testChatToolCallCodableRoundTrip() throws {
        let original = ChatToolCall(id: "tc-abc", name: "search", argumentsJSON: "{\"query\":\"TODO\"}")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatToolCall.self, from: data)
        XCTAssertEqual(decoded.id, "tc-abc")
        XCTAssertEqual(decoded.name, "search")
        XCTAssertEqual(decoded.argumentsJSON, "{\"query\":\"TODO\"}")
    }

    func testChatToolCallCodingKeysUseSnakeCase() throws {
        let tc = ChatToolCall(id: "tc-1", name: "test", argumentsJSON: "{}")
        let data = try JSONEncoder().encode(tc)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"arguments_json\""), "Should use snake_case key arguments_json")
    }

    // MARK: - ChatToolCall: Hashable

    func testChatToolCallHashableEquality() {
        let tc1 = ChatToolCall(id: "tc-1", name: "git_log", argumentsJSON: "{}")
        let tc2 = ChatToolCall(id: "tc-1", name: "git_log", argumentsJSON: "{}")
        XCTAssertEqual(tc1, tc2)
    }

    func testChatToolCallHashableInequality() {
        let tc1 = ChatToolCall(id: "tc-1", name: "git_log", argumentsJSON: "{}")
        let tc2 = ChatToolCall(id: "tc-2", name: "git_log", argumentsJSON: "{}")
        XCTAssertNotEqual(tc1, tc2)
    }

    // MARK: - LLMClientError: Case Creation

    func testLLMClientErrorInvalidBaseURL() {
        let error = LLMClientError.invalidBaseURL("not-a-url")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("not-a-url"))
    }

    func testLLMClientErrorBadHTTPStatus() {
        let error = LLMClientError.badHTTPStatus(500, nil)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("500"))
    }

    func testLLMClientErrorBadHTTPStatusWithBody() {
        let error = LLMClientError.badHTTPStatus(400, "previous_response_not_found")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("400"))
        XCTAssertTrue(error.errorDescription!.contains("previous_response_not_found"))
    }

    func testLLMClientErrorMissingResponse() {
        let error = LLMClientError.missingResponse
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Missing"))
    }

    func testLLMClientErrorRateLimitedWithRetryAfter() {
        let error = LLMClientError.rateLimited(retryAfter: 30.0)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("30"))
    }

    func testLLMClientErrorRateLimitedWithoutRetryAfter() {
        let error = LLMClientError.rateLimited(retryAfter: nil)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("retry later"))
    }

    func testLLMClientErrorProviderError() {
        let error = LLMClientError.providerError("context length exceeded")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("context length exceeded"))
    }

    // MARK: - LLMClientError: Equatable

    func testLLMClientErrorEquatableSameCase() {
        XCTAssertEqual(
            LLMClientError.badHTTPStatus(404, nil),
            LLMClientError.badHTTPStatus(404, nil)
        )
    }

    func testLLMClientErrorEquatableDifferentValues() {
        XCTAssertNotEqual(
            LLMClientError.badHTTPStatus(404, nil),
            LLMClientError.badHTTPStatus(500, nil)
        )
    }

    func testLLMClientErrorEquatableDifferentCases() {
        XCTAssertNotEqual(
            LLMClientError.missingResponse,
            LLMClientError.badHTTPStatus(200, nil)
        )
    }

    func testLLMClientErrorEquatableRateLimited() {
        XCTAssertEqual(
            LLMClientError.rateLimited(retryAfter: 5.0),
            LLMClientError.rateLimited(retryAfter: 5.0)
        )
        XCTAssertNotEqual(
            LLMClientError.rateLimited(retryAfter: 5.0),
            LLMClientError.rateLimited(retryAfter: nil)
        )
    }

}
