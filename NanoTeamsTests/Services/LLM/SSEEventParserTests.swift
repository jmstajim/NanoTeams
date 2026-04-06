import XCTest
@testable import NanoTeams

final class SSEEventParserTests: XCTestCase {

    private var parser: SSEEventParser!

    override func setUp() {
        super.setUp()
        parser = SSEEventParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Content Delta

    func testContentDelta_returnsContent() {
        _ = parser.parse(line: "event: message.delta")
        let result = parser.parse(line: "data: {\"content\": \"Hello\"}")
        if case .contentDelta(let text) = result {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected contentDelta, got \(String(describing: result))")
        }
    }

    // MARK: - Thinking Delta

    func testThinkingDelta_returnsThinking() {
        _ = parser.parse(line: "event: reasoning.delta")
        let result = parser.parse(line: "data: {\"content\": \"Let me think...\"}")
        if case .thinkingDelta(let text) = result {
            XCTAssertEqual(text, "Let me think...")
        } else {
            XCTFail("Expected thinkingDelta, got \(String(describing: result))")
        }
    }

    // MARK: - Chat End

    func testChatEnd_returnsResponseIDAndUsage() {
        _ = parser.parse(line: "event: chat.end")
        let json = "{\"response_id\": \"resp-123\", \"stats\": {\"input_tokens\": 100, \"total_output_tokens\": 50}}"
        let result = parser.parse(line: "data: \(json)")
        if case .chatEnd(let responseID, let usage) = result {
            XCTAssertEqual(responseID, "resp-123")
            XCTAssertEqual(usage?.inputTokens, 100)
            XCTAssertEqual(usage?.outputTokens, 50)
        } else {
            XCTFail("Expected chatEnd, got \(String(describing: result))")
        }
    }

    // MARK: - Error

    func testError_returnsMessage() {
        _ = parser.parse(line: "event: error")
        let result = parser.parse(line: "data: {\"message\": \"Model not loaded\"}")
        if case .error(let msg) = result {
            XCTAssertEqual(msg, "Model not loaded")
        } else {
            XCTFail("Expected error, got \(String(describing: result))")
        }
    }

    func testError_noMessage_defaultsToStreamError() {
        _ = parser.parse(line: "event: error")
        let result = parser.parse(line: "data: {}")
        if case .error(let msg) = result {
            XCTAssertEqual(msg, "Stream error")
        } else {
            XCTFail("Expected error, got \(String(describing: result))")
        }
    }

    // MARK: - Processing Progress

    func testProcessingStart_returnsZero() {
        _ = parser.parse(line: "event: prompt_processing.start")
        let result = parser.parse(line: "data: {}")
        if case .processingProgress(let p) = result {
            XCTAssertEqual(p, 0.0, accuracy: 0.001)
        } else {
            XCTFail("Expected processingProgress(0.0), got \(String(describing: result))")
        }
    }

    func testProcessingProgress_returnsProgress() {
        _ = parser.parse(line: "event: prompt_processing.progress")
        let result = parser.parse(line: "data: {\"progress\": 0.5}")
        if case .processingProgress(let p) = result {
            XCTAssertEqual(p, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Expected processingProgress(0.5), got \(String(describing: result))")
        }
    }

    func testProcessingEnd_returnsOne() {
        _ = parser.parse(line: "event: prompt_processing.end")
        let result = parser.parse(line: "data: {}")
        if case .processingProgress(let p) = result {
            XCTAssertEqual(p, 1.0, accuracy: 0.001)
        } else {
            XCTFail("Expected processingProgress(1.0), got \(String(describing: result))")
        }
    }

    // MARK: - Unknown event type

    func testUnknownEventType_returnsIgnored() {
        _ = parser.parse(line: "event: chat.start")
        let result = parser.parse(line: "data: {}")
        if case .ignored = result {
            // OK
        } else {
            XCTFail("Expected ignored, got \(String(describing: result))")
        }
    }

    // MARK: - Non-data/event lines

    func testNonDataLine_returnsNil() {
        XCTAssertNil(parser.parse(line: "some random text"))
    }

    func testEmptyLine_returnsNil() {
        XCTAssertNil(parser.parse(line: ""))
    }

    func testEventLine_returnsNil() {
        // event: lines don't produce results, only set state
        XCTAssertNil(parser.parse(line: "event: message.delta"))
    }

    func testEmptyData_returnsNil() {
        _ = parser.parse(line: "event: message.delta")
        XCTAssertNil(parser.parse(line: "data: "))
    }

    // MARK: - Stateful event type tracking

    func testEventType_persistsBetweenCalls() {
        // Set event type once
        _ = parser.parse(line: "event: message.delta")

        // First data with this type
        let r1 = parser.parse(line: "data: {\"content\": \"A\"}")
        if case .contentDelta(let t) = r1 { XCTAssertEqual(t, "A") }
        else { XCTFail("Expected contentDelta") }

        // Second data without new event: line — uses same type
        let r2 = parser.parse(line: "data: {\"content\": \"B\"}")
        if case .contentDelta(let t) = r2 { XCTAssertEqual(t, "B") }
        else { XCTFail("Expected contentDelta") }
    }

    func testEventType_changesOnNewEventLine() {
        _ = parser.parse(line: "event: message.delta")
        let r1 = parser.parse(line: "data: {\"content\": \"Hello\"}")
        if case .contentDelta = r1 { /* OK */ }
        else { XCTFail("Expected contentDelta") }

        // Switch to reasoning
        _ = parser.parse(line: "event: reasoning.delta")
        let r2 = parser.parse(line: "data: {\"content\": \"Thinking\"}")
        if case .thinkingDelta(let t) = r2 { XCTAssertEqual(t, "Thinking") }
        else { XCTFail("Expected thinkingDelta") }
    }

    // MARK: - Empty content

    func testContentDelta_emptyContent_returnsIgnored() {
        _ = parser.parse(line: "event: message.delta")
        let result = parser.parse(line: "data: {\"content\": \"\"}")
        if case .ignored = result { /* OK */ }
        else { XCTFail("Expected ignored for empty content, got \(String(describing: result))") }
    }

    func testContentDelta_nilContent_returnsIgnored() {
        _ = parser.parse(line: "event: message.delta")
        let result = parser.parse(line: "data: {}")
        if case .ignored = result { /* OK */ }
        else { XCTFail("Expected ignored for nil content, got \(String(describing: result))") }
    }
}
