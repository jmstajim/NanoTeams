import XCTest

@testable import NanoTeams

final class LMStudioClientTests: XCTestCase {

    // MARK: - Configuration Tests

    func testConfigurationCustomValues() {
        let config = LLMConfig(
            baseURLString: "http://127.0.0.1:1234",
            modelName: "custom-model"
        )
        XCTAssertEqual(config.baseURLString, "http://127.0.0.1:1234")
        XCTAssertEqual(config.modelName, "custom-model")
    }

    func testConfigurationDefaultValues() {
        let config = LLMConfig()
        XCTAssertEqual(config.baseURLString, "http://localhost:1234")
        XCTAssertEqual(config.modelName, "openai/gpt-oss-20b")
    }

    func testConfigurationHashable() {
        let config1 = LLMConfig(baseURLString: "http://a", modelName: "m1")
        let config2 = LLMConfig(baseURLString: "http://a", modelName: "m1")
        let config3 = LLMConfig(baseURLString: "http://b", modelName: "m1")

        XCTAssertEqual(config1, config2)
        XCTAssertNotEqual(config1, config3)

        var set = Set<LLMConfig>()
        set.insert(config1)
        XCTAssertTrue(set.contains(config2))
        XCTAssertFalse(set.contains(config3))
    }

    // MARK: - ClientError Tests

    func testClientErrorInvalidBaseURL() {
        let error = LLMClientError.invalidBaseURL("not-a-url")
        XCTAssertEqual(error.errorDescription, "Invalid LLM base URL: not-a-url")
    }

    func testClientErrorBadHTTPStatus() {
        let error = LLMClientError.badHTTPStatus(500, nil)
        XCTAssertEqual(error.errorDescription, "LLM request failed with HTTP status 500")
    }

    func testClientErrorBadHTTPStatusWithBody() {
        let error = LLMClientError.badHTTPStatus(400, "Invalid type for 'input'.")
        XCTAssertEqual(error.errorDescription, "LLM request failed with HTTP 400: Invalid type for 'input'.")
    }

    func testClientErrorMissingResponse() {
        let error = LLMClientError.missingResponse
        XCTAssertEqual(error.errorDescription, "Missing HTTP response from LLM server")
    }

    func testClientErrorEquatable() {
        XCTAssertEqual(
            LLMClientError.invalidBaseURL("a"),
            LLMClientError.invalidBaseURL("a")
        )
        XCTAssertNotEqual(
            LLMClientError.invalidBaseURL("a"),
            LLMClientError.invalidBaseURL("b")
        )
        XCTAssertEqual(
            LLMClientError.badHTTPStatus(404, nil),
            LLMClientError.badHTTPStatus(404, nil)
        )
        XCTAssertNotEqual(
            LLMClientError.badHTTPStatus(404, nil),
            LLMClientError.badHTTPStatus(500, nil)
        )
        XCTAssertEqual(
            LLMClientError.missingResponse,
            LLMClientError.missingResponse
        )
    }

    // MARK: - ChatMessage Tests

    func testChatMessageEncoding() throws {
        let message = ChatMessage(role: .user, content: "Hello, AI!")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(message)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"role\":\"user\""))
        XCTAssertTrue(jsonString.contains("\"content\":\"Hello, AI!\""))
    }

    func testChatMessageHashable() {
        let msg1 = ChatMessage(role: .user, content: "hi")
        let msg2 = ChatMessage(role: .user, content: "hi")
        let msg3 = ChatMessage(role: .assistant, content: "hi")

        XCTAssertEqual(msg1, msg2)
        XCTAssertNotEqual(msg1, msg3)
    }

    // MARK: - JSONSchemaLeaf Tests

    func testJSONSchemaLeafString() throws {
        let leaf = JSONSchemaLeaf.string("A description")
        XCTAssertEqual(leaf.type, "string")
        XCTAssertEqual(leaf.description, "A description")
        XCTAssertNil(leaf.enumValues)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(leaf)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"type\":\"string\""))
    }

    func testJSONSchemaLeafStringWithEnum() throws {
        let leaf = JSONSchemaLeaf.string("Sort order", enumValues: ["asc", "desc"])
        XCTAssertEqual(leaf.type, "string")
        XCTAssertEqual(leaf.enumValues, ["asc", "desc"])

        let encoder = JSONEncoder()
        let data = try encoder.encode(leaf)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"enum\""))
    }

    func testJSONSchemaLeafInteger() {
        let leaf = JSONSchemaLeaf.integer("Count")
        XCTAssertEqual(leaf.type, "integer")
        XCTAssertEqual(leaf.description, "Count")
        XCTAssertNil(leaf.enumValues)
    }

    func testJSONSchemaLeafBoolean() {
        let leaf = JSONSchemaLeaf.boolean("Enabled flag")
        XCTAssertEqual(leaf.type, "boolean")
        XCTAssertEqual(leaf.description, "Enabled flag")
    }

    // MARK: - JSONSchema Tests

    func testJSONSchemaObjectConstruction() throws {
        let schema = JSONSchema.object(
            properties: [
                "path": JSONSchema.string("File path"),
                "count": JSONSchema.integer("Number of items"),
            ],
            required: ["path"]
        )

        XCTAssertEqual(schema.type, "object")
        XCTAssertEqual(schema.required, ["path"])
        XCTAssertNotNil(schema.properties)
        XCTAssertEqual(schema.properties?.count, 2)
    }

    func testJSONSchemaArrayConstruction() {
        let arrayProp = JSONSchema.array(
            items: JSONSchema.string("path"),
            description: "List of paths"
        )

        XCTAssertEqual(arrayProp.type, "array")
        XCTAssertEqual(arrayProp.description, "List of paths")
        XCTAssertNotNil(arrayProp.items)
    }

    // MARK: - ToolSchema Tests

    func testToolSchemaConstruction() {
        let tool = ToolSchema(
            name: "git_status",
            description: "Get git repository status",
            parameters: JSONSchema.object(properties: [:])
        )

        XCTAssertEqual(tool.name, "git_status")
        XCTAssertEqual(tool.description, "Get git repository status")
        XCTAssertEqual(tool.parameters.type, "object")
    }

    func testDefaultToolsNotEmpty() {
        let tools = ToolHandlerRegistry.allSchemas
        XCTAssertFalse(tools.isEmpty)

        // Check expected tools exist
        let toolNames = Set(tools.map { $0.name })
        XCTAssertTrue(toolNames.contains("read_file"))
        XCTAssertTrue(toolNames.contains("write_file"))
        XCTAssertTrue(toolNames.contains("git_status"))
        XCTAssertTrue(toolNames.contains("git_commit"))
        XCTAssertTrue(toolNames.contains("run_xcodebuild"))
        XCTAssertTrue(toolNames.contains("ask_supervisor"))
    }

    // MARK: - StreamEvent Tests

    func testStreamEventEmpty() {
        let event = StreamEvent()
        XCTAssertTrue(event.isEmpty)
        XCTAssertEqual(event.contentDelta, "")
        XCTAssertTrue(event.toolCallDeltas.isEmpty)
    }

    func testStreamEventWithContent() {
        let event = StreamEvent(contentDelta: "Hello")
        XCTAssertFalse(event.isEmpty)
        XCTAssertEqual(event.contentDelta, "Hello")
    }

    func testStreamEventWithToolCalls() {
        let toolDelta = StreamEvent.ToolCallDelta(
            index: 0,
            id: "call_1",
            name: "read_file",
            argumentsDelta: "{}"
        )
        let event = StreamEvent(contentDelta: "", toolCallDeltas: [toolDelta])
        XCTAssertFalse(event.isEmpty)
    }

    func testStreamEventHashable() {
        let event1 = StreamEvent(contentDelta: "a")
        let event2 = StreamEvent(contentDelta: "a")
        let event3 = StreamEvent(contentDelta: "b")

        XCTAssertEqual(event1, event2)
        XCTAssertNotEqual(event1, event3)
    }

    func testStreamEventWithReasoningContent() {
        let event = StreamEvent(thinkingDelta: "thinking")
        XCTAssertFalse(event.isEmpty)
        XCTAssertEqual(event.thinkingDelta, "thinking")
        XCTAssertEqual(event.contentDelta, "")
    }

    func testStreamEventEmptyReasoningContent() {
        let event = StreamEvent()
        XCTAssertEqual(event.thinkingDelta, "")
    }

    // MARK: - JSON Schema Codability Round-trip Tests

    func testJSONSchemaCodableRoundTrip() throws {
        let schema = JSONSchema.object(
            properties: [
                "name": JSONSchema.string("Name"),
                "age": JSONSchema.integer("Age"),
                "active": JSONSchema.boolean("Is active"),
            ],
            required: ["name"],
            description: "A person"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(schema)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(JSONSchema.self, from: data)

        XCTAssertEqual(schema.type, decoded.type)
        XCTAssertEqual(schema.description, decoded.description)
        XCTAssertEqual(schema.required, decoded.required)
        XCTAssertEqual(schema.properties?.count, decoded.properties?.count)
    }
}
