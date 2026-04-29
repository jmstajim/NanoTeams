import XCTest

@testable import NanoTeams

/// Pins the routing of auth failures (401/403) through the auth classifier
/// across every UI/runtime surface — `LLMClientError`, `checkWithMessage`,
/// preflight, etc. The test value: a regression that breaks any one of
/// these wires (e.g. a refactor that drops the `LLMAuthErrorClassifier`
/// dispatch) immediately surfaces here instead of as a confused user
/// staring at raw JSON server bodies.
final class LLMAuthFailureRoutingTests: XCTestCase {

    // MARK: - AuthFailureKind discrimination

    func testAuthFailureKind_401_isMissingOrInvalid() {
        XCTAssertEqual(LLMAuthErrorClassifier.authFailureKind(status: 401), .missingOrInvalid)
    }

    func testAuthFailureKind_403_isForbidden() {
        XCTAssertEqual(LLMAuthErrorClassifier.authFailureKind(status: 403), .forbidden)
    }

    func testAuthFailureKind_400_isNil() {
        XCTAssertNil(LLMAuthErrorClassifier.authFailureKind(status: 400))
    }

    func testAuthFailureKind_500_isNil() {
        XCTAssertNil(LLMAuthErrorClassifier.authFailureKind(status: 500))
    }

    // MARK: - LLMClientError 401/403 errorDescription routes through the classifier

    func testLLMClientError_401_errorDescription_routesThroughAuthClassifier() {
        let err: LLMClientError = .badHTTPStatus(401, "{\"error\":\"...\"}")
        let message = err.errorDescription ?? ""
        XCTAssertTrue(
            message.contains("Authentication required"),
            "401 must produce the auth-required message, got: \(message)"
        )
        XCTAssertFalse(
            message.contains("\"error\""),
            "401 must NOT dump the raw JSON body — that's what the classifier is for. Got: \(message)"
        )
    }

    func testLLMClientError_403_errorDescription_routesThroughAuthClassifier() {
        let err: LLMClientError = .badHTTPStatus(403, nil)
        XCTAssertTrue(
            err.errorDescription?.contains("Authentication required") == true
        )
    }

    func testLLMClientError_500_errorDescription_includesBodyAndStatus() {
        let err: LLMClientError = .badHTTPStatus(500, "boom")
        let message = err.errorDescription ?? ""
        XCTAssertTrue(message.contains("500"))
        XCTAssertTrue(message.contains("boom"))
        XCTAssertFalse(
            message.contains("Authentication required"),
            "Non-auth statuses MUST NOT carry the auth-required message — that would mislabel a real server error as a token problem."
        )
    }

    func testLLMClientError_emptyURL_invalidBaseURL_isHelpful() {
        let err: LLMClientError = .invalidBaseURL("")
        let message = err.errorDescription ?? ""
        XCTAssertTrue(
            message.contains("empty"),
            "Empty URL should produce a helpful 'enter the URL' hint, not the literal `Invalid LLM base URL: ` with nothing after the colon. Got: \(message)"
        )
    }

    // MARK: - checkWithMessage 500 path

    private final class CapturingNetworkSession: NetworkSession, @unchecked Sendable {
        var capturedRequest: URLRequest?
        var statusCode: Int = 200

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequest = request
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: statusCode,
                httpVersion: nil, headerFields: nil)!)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    func testCheckWithMessage_500_doesNotMentionAuthentication() async {
        let session = CapturingNetworkSession()
        session.statusCode = 500

        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: "http://localhost:1234",
            session: session,
            resolver: StubLLMTokenResolver([:])
        )

        XCTAssertFalse(result.isReachable)
        XCTAssertEqual(result.statusCode, 500)
        XCTAssertFalse(
            result.message.contains("Authentication required"),
            "500 must not be classified as auth failure. A regression in `isAuthFailure` (e.g. expanding to >= 401) would silently mislabel every server error as a token problem."
        )
        XCTAssertTrue(result.message.contains("500"))
    }

    func testCheckWithMessage_401_explicitlyMentionsToken() async {
        let session = CapturingNetworkSession()
        session.statusCode = 401

        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: "http://localhost:1234",
            session: session,
            resolver: StubLLMTokenResolver([:])
        )
        XCTAssertTrue(result.message.contains("token"),
                      "401 message should hint to add a token; got: \(result.message)")
    }
}
