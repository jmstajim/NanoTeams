import XCTest

@testable import NanoTeams

/// Pins the retryable/non-retryable classification used by the step-execution
/// retry loop. Permanent errors (wrong model / 404, auth, bad URL) must NOT be
/// retried — they fail the step immediately so an error bubble is produced.
final class LLMRetryPolicyTests: XCTestCase {

    // MARK: - Non-retryable (permanent → fail the step now)

    func testBadHTTPStatus404_modelNotFound_isNotRetryable() {
        // The reported bug: an invalid model identifier looped 26+ times.
        XCTAssertFalse(LLMRetryPolicy.isRetryable(
            LLMClientError.badHTTPStatus(404, "{\"error\":{\"code\":\"model_not_found\"}}")))
    }

    func testBadHTTPStatus404_noBody_isNotRetryable() {
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(404, nil)))
    }

    func testBadHTTPStatus401_auth_isNotRetryable() {
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(401, nil)))
    }

    func testBadHTTPStatus403_forbidden_isNotRetryable() {
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(403, nil)))
    }

    func testBadHTTPStatus405_isNotRetryable() {
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(405, nil)))
    }

    func testBadHTTPStatus409_isNotRetryable() {
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(409, nil)))
    }

    func testBadHTTPStatus422_isNotRetryable() {
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(422, nil)))
    }

    func testInvalidBaseURL_isNotRetryable() {
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.invalidBaseURL("htp://typo")))
    }

    // MARK: - Retryable (transient / recoverable)

    func testBadHTTPStatus400_poisonedChain_isRetryable() {
        // 400 keeps retrying: the loop clears the session and rebuilds the
        // conversation statelessly, which can recover a poisoned chain.
        XCTAssertTrue(LLMRetryPolicy.isRetryable(
            LLMClientError.badHTTPStatus(400, "previous_response_not_found")))
    }

    func testBadHTTPStatus408_requestTimeout_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(408, nil)))
    }

    func testBadHTTPStatus429_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(429, nil)))
    }

    func testBadHTTPStatus500_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(500, nil)))
    }

    func testBadHTTPStatus503_withBody_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(503, "model loading")))
    }

    func testRateLimited_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.rateLimited(retryAfter: 30)))
    }

    func testMissingResponse_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.missingResponse))
    }

    func testProviderError_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.providerError("context length exceeded")))
    }

    func testURLError_networkTransport_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(URLError(.timedOut)))
        XCTAssertTrue(LLMRetryPolicy.isRetryable(URLError(.notConnectedToInternet)))
        XCTAssertTrue(LLMRetryPolicy.isRetryable(URLError(.networkConnectionLost)))
    }

    func testGenericNSError_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(NSError(domain: "x", code: 1)))
    }

    func testCancellationError_isRetryable_butHandledUpstream() {
        // CancellationError is caught separately in the lifecycle loop and never
        // reaches the generic catch where isRetryable is consulted. Defaulting it
        // to retryable is harmless and documents the non-LLMClientError fall-through.
        XCTAssertTrue(LLMRetryPolicy.isRetryable(CancellationError()))
    }

    // MARK: - Boundaries

    func test499_isNotRetryable_but500_isRetryable() {
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(499, nil)))
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(500, nil)))
    }

    func test400_isRetryable_but401_isNotRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(400, nil)))
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(401, nil)))
    }

    func testBelow400_fallsThroughToRetryable() {
        // Only 4xx are treated as permanent; anything below 400 (a 3xx surfaced as
        // badHTTPStatus, or a defensive 200) falls through to retryable. Pinned so
        // the `(400..<500)` lower bound is a deliberate choice, not an accident.
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(302, nil)))
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(200, nil)))
    }

    // MARK: - Status-code boundary corners

    func testTeapot418_arbitrary4xx_isNotRetryable() {
        // Any 4xx outside the {400,408,429} recoverable set is permanent.
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(418, nil)))
        XCTAssertFalse(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(451, nil)))
    }

    func test599_topOf5xx_isRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(599, nil)))
    }

    func test600_above5xx_isRetryable() {
        // Above the 5xx band still falls through `(400..<500)` to retryable.
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(600, nil)))
    }

    func testZeroAndNegativeStatus_areRetryable() {
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(0, nil)))
        XCTAssertTrue(LLMRetryPolicy.isRetryable(LLMClientError.badHTTPStatus(-1, nil)))
    }
}
