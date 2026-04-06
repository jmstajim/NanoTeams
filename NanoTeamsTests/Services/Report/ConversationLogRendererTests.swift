import XCTest
@testable import NanoTeams

final class ConversationLogRendererTests: XCTestCase {

    var renderer: ConversationLogRenderer!

    override func setUp() {
        super.setUp()
        renderer = ConversationLogRenderer()
    }

    override func tearDown() {
        renderer = nil
        super.tearDown()
    }

    // MARK: - Empty Records Tests

    func testRender_EmptyRecords() {
        let result = renderer.render(records: [])

        XCTAssertTrue(result.contains("# Conversation Log"))
        XCTAssertTrue(result.contains("Generated:"))
        XCTAssertTrue(result.contains("_No network activity recorded._"))
    }

    // MARK: - Request Record Tests

    func testRender_SingleRequest() {
        let correlationID = UUID()
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: nil,
            durationMs: nil,
            errorMessage: nil,
            correlationID: correlationID,
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("# Conversation Log"))
        XCTAssertTrue(result.contains("→ Request"))
        XCTAssertTrue(result.contains("Method: POST"))
        XCTAssertTrue(result.contains("Correlation:"))
        XCTAssertTrue(result.contains("<details>"))
        XCTAssertTrue(result.contains("</details>"))
    }

    func testRender_RequestWithStepID() {
        let stepID = "test_step"
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: nil,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: stepID
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("Step:"))
        XCTAssertTrue(result.contains(stepID.prefix(8)))
    }

    // MARK: - Response Record Tests

    func testRender_SingleResponse() {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 200,
            body: "Response body",
            durationMs: 150.5,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("← Response"))
        XCTAssertTrue(result.contains("Status: 200"))
        XCTAssertTrue(result.contains("Duration: 150.5ms"))
    }

    func testRender_ResponseWithError() {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 500,
            body: nil,
            durationMs: 50.0,
            errorMessage: "Internal Server Error",
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("Error: Internal Server Error"))
    }

    // MARK: - Request/Response Pair Tests

    func testRender_RequestResponsePair() {
        let correlationID = UUID()
        let request = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: nil,
            durationMs: nil,
            errorMessage: nil,
            correlationID: correlationID,
            stepID: nil
        )
        let response = NetworkLogRecord(
            id: UUID(),
            createdAt: Date().addingTimeInterval(1),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 200,
            body: "OK",
            durationMs: 1000.0,
            errorMessage: nil,
            correlationID: correlationID,
            stepID: nil
        )

        let result = renderer.render(records: [request, response])

        XCTAssertTrue(result.contains("1. → Request"))
        XCTAssertTrue(result.contains("2. ← Response"))
    }

    // MARK: - Body Rendering Tests

    func testRender_PlainTextBody() {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 200,
            body: "Simple plain text response",
            durationMs: 100.0,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("Simple plain text response"))
        XCTAssertTrue(result.contains("```"))
    }

    func testRender_JSONBody_WithMessages() {
        let jsonBody = """
        {
            "messages": [
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": "Hello!"}
            ]
        }
        """
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: jsonBody,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("[SYSTEM]"))
        XCTAssertTrue(result.contains("[USER]"))
        XCTAssertTrue(result.contains("You are a helpful assistant."))
        XCTAssertTrue(result.contains("Hello!"))
    }

    func testRender_JSONBody_WithTools() {
        let jsonBody = """
        {
            "messages": [],
            "tools": [
                {"function": {"name": "read_file", "description": "Read a file from disk"}},
                {"function": {"name": "write_file", "description": "Write content to a file"}}
            ]
        }
        """
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: jsonBody,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("[TOOLS]"))
        XCTAssertTrue(result.contains("2 available"))
        XCTAssertTrue(result.contains("`read_file`"))
        XCTAssertTrue(result.contains("`write_file`"))
    }

    func testRender_JSONBody_LongToolDescription() {
        let longDescription = String(repeating: "a", count: 100)
        let jsonBody = """
        {
            "tools": [
                {"function": {"name": "tool", "description": "\(longDescription)"}}
            ]
        }
        """
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: jsonBody,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        // Long description should be truncated with "..."
        XCTAssertTrue(result.contains("..."))
    }

    // MARK: - Structured Response Tests

    func testRender_StructuredResponse_WithReasoning() {
        let body = """
        [reasoning]
        I need to think about this carefully.
        This is my reasoning process.
        [/reasoning]
        Here is the actual response.
        """
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 200,
            body: body,
            durationMs: 100.0,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("**Thinking:**"))
        XCTAssertTrue(result.contains("> I need to think about this carefully."))
        XCTAssertTrue(result.contains("Here is the actual response."))
    }

    func testRender_StructuredResponse_WithToolCalls() {
        let body = """
        Let me read that file.
        [tool_calls]
        [{"name": "read_file", "arguments": {"path": "/test.txt"}}]
        [/tool_calls]
        """
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 200,
            body: body,
            durationMs: 100.0,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("**Tool Calls:**"))
        XCTAssertTrue(result.contains("```json"))
        XCTAssertTrue(result.contains("read_file"))
    }

    func testRender_StructuredResponse_FullFormat() {
        let body = """
        [reasoning]
        Analyzing the request...
        [/reasoning]
        I'll help you with that.
        [tool_calls]
        [{"name": "search", "arguments": {"query": "test"}}]
        [/tool_calls]
        """
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 200,
            body: body,
            durationMs: 100.0,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("**Thinking:**"))
        XCTAssertTrue(result.contains("I'll help you with that."))
        XCTAssertTrue(result.contains("**Tool Calls:**"))
    }

    // MARK: - Multiple Records Tests

    func testRender_MultipleRecords_InOrder() {
        var records: [NetworkLogRecord] = []
        let correlationID = UUID()

        for i in 0..<5 {
            records.append(NetworkLogRecord(
                id: UUID(),
                createdAt: Date().addingTimeInterval(Double(i)),
                direction: i % 2 == 0 ? .request : .response,
                httpMethod: "POST",
                url: "https://api.example.com/chat",
                statusCode: i % 2 == 0 ? nil : 200,
                body: nil,
                durationMs: i % 2 == 0 ? nil : 100.0,
                errorMessage: nil,
                correlationID: correlationID,
                stepID: nil
            ))
        }

        let result = renderer.render(records: records)

        XCTAssertTrue(result.contains("1. → Request"))
        XCTAssertTrue(result.contains("2. ← Response"))
        XCTAssertTrue(result.contains("3. → Request"))
        XCTAssertTrue(result.contains("4. ← Response"))
        XCTAssertTrue(result.contains("5. → Request"))
    }

    // MARK: - Code Fence Tests

    func testRender_CodeFenceEscaping() {
        // Body contains backticks that need escaping
        let body = "Here is some code:\n```swift\nlet x = 1\n```"
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 200,
            body: body,
            durationMs: 100.0,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        // Should use more backticks to escape the inner fence
        XCTAssertTrue(result.contains("````"))
    }

    func testRender_CodeFence_NoBackticks() {
        let body = "Simple text without backticks"
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 200,
            body: body,
            durationMs: 100.0,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        // Should use standard triple backticks
        XCTAssertTrue(result.contains("```"))
        XCTAssertFalse(result.contains("````"))
    }

    // MARK: - Message Content Length Tests

    func testRender_ShortMessageContent_Inline() {
        let jsonBody = """
        {"messages": [{"role": "user", "content": "Hi"}]}
        """
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: jsonBody,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        // Short content should be inline (not in code fence)
        XCTAssertTrue(result.contains("[USER]"))
        XCTAssertTrue(result.contains("Hi"))
    }

    func testRender_LongMessageContent_InCodeFence() {
        let longContent = String(repeating: "a", count: 200)
        let jsonBody = """
        {"messages": [{"role": "user", "content": "\(longContent)"}]}
        """
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: jsonBody,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        // Long content should be in code fence
        XCTAssertTrue(result.contains("```"))
        XCTAssertTrue(result.contains(longContent))
    }

    func testRender_MultilineMessageContent_InCodeFence() {
        let jsonBody = """
        {"messages": [{"role": "user", "content": "Line 1\\nLine 2"}]}
        """
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: jsonBody,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        // Multiline content should be in code fence
        XCTAssertTrue(result.contains("```"))
    }

    // MARK: - Edge Cases

    func testRender_InvalidJSON() {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: "{invalid json",
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        // Should still render the body (as raw text in fence)
        XCTAssertTrue(result.contains("{invalid json"))
    }

    func testRender_EmptyBody() {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: 200,
            body: nil,
            durationMs: 100.0,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        // Should render without body section
        XCTAssertTrue(result.contains("← Response"))
        XCTAssertTrue(result.contains("Status: 200"))
    }

    func testRender_ZeroStatusCode() {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "https://api.example.com/chat",
            statusCode: nil,
            body: nil,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        let result = renderer.render(records: [record])

        XCTAssertTrue(result.contains("Status: 0"))
    }

    // MARK: - Formatting Tests

    func testRender_ContainsHeader() {
        let result = renderer.render(records: [])

        XCTAssertTrue(result.hasPrefix("# Conversation Log"))
    }

    func testRender_ContainsSeparator() {
        let result = renderer.render(records: [])

        XCTAssertTrue(result.contains("---"))
    }

    func testRender_ContainsGeneratedDate() {
        let result = renderer.render(records: [])

        XCTAssertTrue(result.contains("Generated:"))
        // ISO8601 format includes T separator
        XCTAssertTrue(result.contains("T"))
    }
}
