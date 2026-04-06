import XCTest

@testable import NanoTeams

/// Integration tests for SSE event parsing: malformed data recovery, event type coverage.
/// Validates SSEEventParser handles all event types and malformed input gracefully.
@MainActor
final class EndToEndNetworkErrorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: SSE malformed JSON recovers gracefully

    func testSSE_malformedJSON_recoversGracefully() {
        var parser = SSEEventParser()

        // Valid event
        _ = parser.parse(line: "event: message.delta")
        let valid = parser.parse(line: #"data: {"content": "Hello"}"#)
        if case .contentDelta(let text) = valid {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Should parse valid content delta")
        }

        // Malformed JSON — should not crash
        _ = parser.parse(line: "event: message.delta")
        let malformed = parser.parse(line: "data: {invalid json")
        // Should return .ignored for malformed data (not crash)
        XCTAssertNotNil(malformed, "Should return something for malformed data")
        if case .contentDelta = malformed {
            XCTFail("Malformed JSON should not produce contentDelta")
        }
    }

    // MARK: - Test 2: SSE mixed valid and invalid preserves valid content

    func testSSE_mixedValidAndInvalid_preservesValidContent() {
        var parser = SSEEventParser()
        var collectedContent = ""

        let lines = [
            "event: message.delta",
            #"data: {"content": "First "}"#,
            "event: message.delta",
            "data: {broken",
            "event: message.delta",
            #"data: {"content": "Second"}"#,
            "event: chat.end",
            #"data: {"responseID": "resp-1"}"#,
        ]

        var gotChatEnd = false

        for line in lines {
            if let event = parser.parse(line: line) {
                switch event {
                case .contentDelta(let text):
                    collectedContent += text
                case .chatEnd:
                    gotChatEnd = true
                default:
                    break
                }
            }
        }

        XCTAssertTrue(collectedContent.contains("First"), "Should collect valid first delta")
        XCTAssertTrue(collectedContent.contains("Second"), "Should collect valid second delta")
        XCTAssertTrue(gotChatEnd, "Should reach chat.end despite malformed intermediate data")
    }

    // MARK: - Test 3: SSE processing progress events

    func testSSE_processingProgress_parsesCorrectly() {
        var parser = SSEEventParser()

        _ = parser.parse(line: "event: prompt_processing.start")
        let start = parser.parse(line: "data: {}")
        if case .processingProgress(let progress) = start {
            XCTAssertEqual(progress, 0.0, "Start should be 0%")
        } else {
            XCTFail("Should parse processing start")
        }

        _ = parser.parse(line: "event: prompt_processing.end")
        let end = parser.parse(line: "data: {}")
        if case .processingProgress(let progress) = end {
            XCTAssertEqual(progress, 1.0, "End should be 100%")
        } else {
            XCTFail("Should parse processing end")
        }
    }

    // MARK: - Test 4: SSE thinking delta parsed

    func testSSE_thinkingDelta_parsedCorrectly() {
        var parser = SSEEventParser()

        _ = parser.parse(line: "event: reasoning.delta")
        let event = parser.parse(line: #"data: {"content": "Let me think..."}"#)

        if case .thinkingDelta(let text) = event {
            XCTAssertEqual(text, "Let me think...")
        } else {
            XCTFail("Should parse thinking/reasoning delta")
        }
    }

    // MARK: - Test 5: SSE error event parsed

    func testSSE_errorEvent_parsed() {
        var parser = SSEEventParser()

        _ = parser.parse(line: "event: error")
        let event = parser.parse(line: #"data: {"message": "Model overloaded"}"#)

        if case .error(let msg) = event {
            XCTAssertEqual(msg, "Model overloaded")
        } else {
            XCTFail("Should parse error event")
        }
    }

    // MARK: - Test 6: SSE non-data lines return nil

    func testSSE_nonDataLines_returnNil() {
        var parser = SSEEventParser()

        // Comment line
        let comment = parser.parse(line: ": keepalive")
        XCTAssertNil(comment, "Comment lines should return nil")

        // Empty line
        let empty = parser.parse(line: "")
        XCTAssertNil(empty, "Empty lines should return nil")

        // Random text
        let random = parser.parse(line: "some random text")
        XCTAssertNil(random, "Non-SSE lines should return nil")
    }

    // MARK: - Test 7: SSE chat.end with token usage

    func testSSE_chatEnd_withTokenUsage() {
        var parser = SSEEventParser()

        _ = parser.parse(line: "event: chat.end")
        let event = parser.parse(line: #"data: {"response_id": "resp-123", "stats": {"input_tokens": 500, "total_output_tokens": 200}}"#)

        if case .chatEnd(let responseID, let usage) = event {
            XCTAssertEqual(responseID, "resp-123")
            XCTAssertEqual(usage?.inputTokens, 500)
            XCTAssertEqual(usage?.outputTokens, 200)
        } else {
            XCTFail("Should parse chat.end with usage stats")
        }
    }
}
