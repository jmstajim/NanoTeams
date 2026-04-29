import XCTest

@testable import NanoTeams

/// User scenario: the embedding pipeline returns 401/403 because the user
/// enabled "Require Authentication" on LM Studio but didn't add a token (or
/// added the wrong one). The error message surfaced in the search index pane
/// must point the user at the fix — Settings → LLM — instead of dumping the
/// raw LM Studio JSON envelope.
///
/// Regression test for the gap caught in code review: `EmbeddingClientError.httpError`
/// previously rendered as `"Embedding HTTP 401: <body>"` with no actionable
/// hint. The fix routes 401/403 through `LLMAuthErrorClassifier` in the
/// `errorDescription` getter, mirroring `LLMClientError.badHTTPStatus`.
final class EmbeddingAuthErrorMessageTests: XCTestCase {

    // MARK: - 401 — user must see "add your API token"

    func testHTTPError_401_routesThroughAuthClassifier() {
        let err = EmbeddingClientError.httpError(status: 401, message: "Unauthorized")
        let desc = err.errorDescription ?? ""

        XCTAssertTrue(
            desc.contains("Authentication required"),
            "401 must surface the actionable auth-required message; got: \(desc)"
        )
        XCTAssertTrue(
            desc.contains("Settings → LLM"),
            "Message must point the user at where to fix it; got: \(desc)"
        )
        XCTAssertFalse(
            desc.contains("Embedding HTTP"),
            "401 must NOT show the generic 'Embedding HTTP' wrapper; got: \(desc)"
        )
    }

    func testHTTPError_401_routesEvenWithEmptyBody() {
        let err = EmbeddingClientError.httpError(status: 401, message: nil)
        let desc = err.errorDescription ?? ""

        XCTAssertTrue(desc.contains("Authentication required"), desc)
        XCTAssertTrue(desc.contains("(HTTP 401)"), desc)
    }

    // MARK: - 403 — same path; user with valid token but wrong permissions

    func testHTTPError_403_routesThroughAuthClassifier() {
        let err = EmbeddingClientError.httpError(status: 403, message: "Forbidden")
        let desc = err.errorDescription ?? ""

        XCTAssertTrue(desc.contains("Authentication required"), desc)
        XCTAssertTrue(desc.contains("(HTTP 403)"), desc)
    }

    // MARK: - Non-auth statuses must NOT be misclassified as auth

    /// Critical: a 500 is a server bug, not an auth failure. Telling the user
    /// to "add an API token" for a 500 would send them on a wild goose chase.
    func testHTTPError_500_doesNotMentionAuthentication() {
        let err = EmbeddingClientError.httpError(status: 500, message: "internal server error")
        let desc = err.errorDescription ?? ""

        XCTAssertFalse(
            desc.contains("Authentication required"),
            "500 must not be classified as auth; got: \(desc)"
        )
        XCTAssertTrue(
            desc.contains("500"),
            "Generic HTTP error must still surface the status code; got: \(desc)"
        )
    }

    func testHTTPError_404_doesNotMentionAuthentication() {
        let err = EmbeddingClientError.httpError(status: 404, message: "not found")
        let desc = err.errorDescription ?? ""

        XCTAssertFalse(desc.contains("Authentication required"), desc)
    }

    // MARK: - End-to-end: classifyHTTPError → errorDescription path

    /// Pin the full chain: real HTTP body from LM Studio → classifyHTTPError
    /// produces `.httpError` → user sees the auth-required message.
    func testClassifyHTTPError_401_endToEndProducesActionableMessage() {
        let body = Data(#"{"error":{"message":"Unauthorized","type":"auth_error"}}"#.utf8)
        let err = LMStudioEmbeddingClient.classifyHTTPError(
            status: 401, data: body, modelName: "any-model"
        )
        // Pin the case shape so a future refactor that introduces an `.authRequired`
        // case still routes through this same description path.
        guard case .httpError(let status, _) = err else {
            XCTFail("Expected .httpError, got \(err)"); return
        }
        XCTAssertEqual(status, 401)
        XCTAssertTrue(err.errorDescription?.contains("Authentication required") == true)
    }

    /// 403 end-to-end — same chain as 401, separate test because the classifier
    /// branches on status code and a future refactor that adds 403-specific
    /// handling could regress one without the other.
    func testClassifyHTTPError_403_endToEndProducesActionableMessage() {
        let body = Data(#"{"error":{"message":"Forbidden","type":"auth_error"}}"#.utf8)
        let err = LMStudioEmbeddingClient.classifyHTTPError(
            status: 403, data: body, modelName: "any-model"
        )
        guard case .httpError(let status, _) = err else {
            XCTFail("Expected .httpError, got \(err)"); return
        }
        XCTAssertEqual(status, 403)
        XCTAssertTrue(
            err.errorDescription?.contains("Authentication required") == true,
            "403 must surface the actionable auth message: \(err.errorDescription ?? "nil")"
        )
    }

    // MARK: - Non-JSON bodies (regression for I4 review finding)

    /// LM Studio behind an nginx reverse proxy returns a raw HTML 401 page.
    /// The classifier must still route through the auth message regardless
    /// of the body shape — a strict JSON parse would silently fall back to
    /// the generic "Embedding HTTP 401: <body>" message and lose the fix
    /// hint.
    func testClassifyHTTPError_401_withHTMLBody_stillProducesActionableMessage() {
        let body = Data("<html><body><h1>401 Authorization Required</h1></body></html>".utf8)
        let err = LMStudioEmbeddingClient.classifyHTTPError(
            status: 401, data: body, modelName: "any-model"
        )
        XCTAssertTrue(
            err.errorDescription?.contains("Authentication required") == true,
            "Auth path must not depend on JSON body shape: \(err.errorDescription ?? "nil")"
        )
    }

    func testClassifyHTTPError_401_withEmptyBody_stillProducesActionableMessage() {
        let err = LMStudioEmbeddingClient.classifyHTTPError(
            status: 401, data: Data(), modelName: "any-model"
        )
        XCTAssertTrue(
            err.errorDescription?.contains("Authentication required") == true,
            "Empty body must still route to the auth message: \(err.errorDescription ?? "nil")"
        )
    }

    func testClassifyHTTPError_401_withPlaintextBody_stillProducesActionableMessage() {
        let body = Data("nginx: 401 Unauthorized\nrequest_id=abc123".utf8)
        let err = LMStudioEmbeddingClient.classifyHTTPError(
            status: 401, data: body, modelName: "any-model"
        )
        XCTAssertTrue(
            err.errorDescription?.contains("Authentication required") == true,
            "Plaintext body must still route to the auth message: \(err.errorDescription ?? "nil")"
        )
    }
}
