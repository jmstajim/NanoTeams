import XCTest

@testable import NanoTeams

/// `NetworkLogger.streamedBodyText` — the one rendering of what a streaming response carried,
/// shared by the completed record and the interrupted one — and the record's word for a
/// cancelled request (2026-09-13: a 662 s request cut off at the run's timeout had left a
/// record saying `cancelled` and nothing else).
final class NetworkLogStreamedBodyTests: XCTestCase {

    private func call(_ name: String, _ args: String) -> StreamEvent.ToolCallDelta {
        StreamEvent.ToolCallDelta(index: 0, id: nil, name: name, argumentsDelta: args)
    }

    func testNothingStreamed_isNil() {
        XCTAssertNil(NetworkLogger.streamedBodyText(thinking: "", content: "", toolCalls: []))
    }

    func testReasoningOnly_isWrapped() {
        XCTAssertEqual(
            NetworkLogger.streamedBodyText(thinking: "why", content: "", toolCalls: []),
            "[reasoning]\nwhy\n[/reasoning]\n\n")
    }

    func testContentOnly_hasNoWrapper() {
        XCTAssertEqual(NetworkLogger.streamedBodyText(thinking: "", content: "prose", toolCalls: []), "prose")
    }

    func testCallsOnly_renderAsTheLogsCallLines() {
        XCTAssertEqual(
            NetworkLogger.streamedBodyText(thinking: "", content: "", toolCalls: [call("read_file", "{}")]),
            "\n[tool_call] read_file {}")
    }

    func testOrder_isReasoningThenContentThenCalls() {
        let body = NetworkLogger.streamedBodyText(
            thinking: "why", content: "prose", toolCalls: [call("read_file", "{}"), call("git_status", "{}")])
        XCTAssertEqual(body, "[reasoning]\nwhy\n[/reasoning]\n\nprose\n[tool_call] read_file {}\n[tool_call] git_status {}")
    }

    // MARK: - The word for a cancelled request

    func testErrorMessage_forEitherCancellation_isOneWord() {
        XCTAssertEqual(NetworkLogger.errorMessage(for: CancellationError()), "cancelled",
                       "Swift's own description is \"The operation couldn't be completed\"")
        XCTAssertEqual(NetworkLogger.errorMessage(for: URLError(.cancelled)), "cancelled",
                       "the URL layer's word is localized; the log's is not")
    }

    func testErrorMessage_forAnyOtherError_isItsOwnDescription() {
        let error = LLMClientError.providerError("boom")
        XCTAssertEqual(NetworkLogger.errorMessage(for: error), error.localizedDescription)
        XCTAssertEqual(NetworkLogger.errorMessage(for: URLError(.timedOut)), URLError(.timedOut).localizedDescription)
    }

    func testResponseRecord_forACancelledRequest_saysCancelled_andKeepsTheBody() {
        let request = NetworkLogger.createRequestRecord(
            url: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!, method: "POST",
            body: Data(), stepID: "planner", roleName: "Change Planner")
        let record = NetworkLogger.createResponseRecord(
            for: request, statusCode: 0, durationMs: 662_253,
            body: "[reasoning]\nlooping\n[/reasoning]\n\n", error: CancellationError())
        XCTAssertEqual(record.errorMessage, "cancelled")
        XCTAssertEqual(record.body, "[reasoning]\nlooping\n[/reasoning]\n\n")
        XCTAssertEqual(record.statusCode, 0)
        XCTAssertEqual(record.correlationID, request.correlationID)
        XCTAssertNil(record.doneReason, "the server never said how it stopped")
    }
}
