import XCTest

@testable import NanoTeams

/// The transport seam's value types. Two properties matter beyond the shapes: every
/// failure says what to DO about it (a model reads these folded into
/// `MCP_SERVER_UNAVAILABLE`), and `isRetryable` separates a configuration fact from a
/// dropped connection — a reconnect loop against a refused endpoint is a busy loop.
final class MCPTransportContractTests: XCTestCase {

    // MARK: - Failure text

    func testEveryFailureNamesARepair() {
        let failures: [MCPTransportError] = [
            .endpointRefused("Use https, or http on 127.0.0.1."),
            .notConnected,
            .httpStatus(code: 500, body: "boom"),
            .unauthorized(status: 401, challenge: "Bearer"),
            .sessionLost,
            .frameTooLarge(bytes: 100, limit: 64),
            .malformedFrame("not valid JSON"),
            .redirectRefused(from: "https://a", to: "https://b"),
            .network("the host could not be found"),
            .timedOut,
            .streamEnded,
            .closed,
        ]
        for failure in failures {
            XCTAssertFalse(failure.localizedDescription.isEmpty, "\(failure)")
            XCTAssertEqual(failure.errorDescription, failure.localizedDescription, "\(failure)")
        }
    }

    func testStatusFailureCarriesTheServersOwnWordsWhenItHasThem() {
        XCTAssertTrue(MCPTransportError.httpStatus(code: 503, body: "maintenance")
            .localizedDescription.contains("maintenance"))
        XCTAssertFalse(MCPTransportError.httpStatus(code: 503, body: "")
            .localizedDescription.contains("—"))
    }

    func testUnauthorizedPointsAtTheTokenField() {
        XCTAssertTrue(MCPTransportError.unauthorized(status: 403, challenge: nil)
            .localizedDescription.contains("Settings → MCP Servers"))
    }

    // MARK: - Retry classification

    func testConfigurationFactsAreNotRetried() {
        // Each of these refuses identically forever; retrying is a busy loop.
        XCTAssertFalse(MCPTransportError.endpointRefused("x").isRetryable)
        XCTAssertFalse(MCPTransportError.redirectRefused(from: "a", to: "b").isRetryable)
        XCTAssertFalse(MCPTransportError.unauthorized(status: 401, challenge: nil).isRetryable)
        XCTAssertFalse(MCPTransportError.frameTooLarge(bytes: 1, limit: 0).isRetryable)
    }

    func testTransientFailuresAreRetried() {
        for failure: MCPTransportError in [.notConnected, .httpStatus(code: 500, body: ""),
                                           .sessionLost, .malformedFrame("x"), .network("x"),
                                           .timedOut, .streamEnded, .closed] {
            XCTAssertTrue(failure.isRetryable, "\(failure)")
        }
    }

    // MARK: - Frames and hints

    func testOutgoingFrameExposesItsMethod() {
        let request = MCPOutgoingFrame.request(JSONRPCRequest(id: .number(1), method: "tools/list"))
        XCTAssertEqual(request.method, "tools/list")

        let notification = MCPOutgoingFrame.notification(JSONRPCNotification(method: "notifications/initialized"))
        XCTAssertEqual(notification.method, "notifications/initialized")

        let response = MCPOutgoingFrame.response(
            JSONRPCResponse(id: .string("a"), outcome: .result(.object([:]))))
        XCTAssertNil(response.method, "a reply names no method")
    }

    /// Only a request awaits an answer. A reply carries an id — the SERVER's, echoed — and
    /// awaits nothing; keyed on it, a refusal of the reply settled this client's own request of
    /// the same number (`StreamableHTTPTransportTests`, the 4xx table and the stray replies).
    func testOnlyARequestAwaitsAnAnswer() {
        XCTAssertEqual(MCPOutgoingFrame.request(JSONRPCRequest(id: .number(7), method: "tools/call")).awaitedResponseID,
                       .number(7))
        XCTAssertEqual(MCPOutgoingFrame.request(JSONRPCRequest(id: .string("p"), method: "ping")).awaitedResponseID,
                       .string("p"))
        XCTAssertNil(MCPOutgoingFrame.notification(JSONRPCNotification(method: "notifications/cancelled")).awaitedResponseID)
        XCTAssertNil(MCPOutgoingFrame.response(
            JSONRPCResponse(id: .number(7), outcome: .result(.object([:])))).awaitedResponseID)
        XCTAssertNil(MCPOutgoingFrame.response(JSONRPCResponse(
            id: .number(7), outcome: .failure(JSONRPCError(code: -32601, message: "no")))).awaitedResponseID)
    }

    func testDefaultHintsCarryNothing() {
        XCTAssertNil(MCPSendHints.none.name)
        XCTAssertTrue(MCPSendHints.none.headerParameters.isEmpty)
        XCTAssertFalse(MCPSendHints.none.expectsLongLivedStream)
        XCTAssertEqual(MCPSendHints(), MCPSendHints.none)
    }

    func testHintsCarryTheModernHeaderFacts() {
        let hints = MCPSendHints(name: "get_screenshot", headerParameters: ["X": "1"],
                                 expectsLongLivedStream: true)
        XCTAssertEqual(hints.name, "get_screenshot")
        XCTAssertEqual(hints.headerParameters, ["X": "1"])
        XCTAssertTrue(hints.expectsLongLivedStream)
    }

    func testIncomingEventHoldsEitherAFrameOrAFailure() {
        let frame = MCPIncomingEvent.frame(.notification(JSONRPCNotification(method: "x")))
        XCTAssertNotEqual(frame, .closed)
        XCTAssertEqual(MCPIncomingEvent.failed(.timedOut), .failed(.timedOut))
    }
}
