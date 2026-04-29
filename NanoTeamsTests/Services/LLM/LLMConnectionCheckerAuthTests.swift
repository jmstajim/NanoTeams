import XCTest

@testable import NanoTeams

final class LLMConnectionCheckerAuthTests: XCTestCase {

    private final class CapturingNetworkSession: NetworkSession, @unchecked Sendable {
        var capturedRequest: URLRequest?
        var statusCode: Int = 200

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    private let baseURL = "http://localhost:1234"

    // MARK: - bearerToken parameter wins over Keychain

    func testCheck_explicitBearerToken_winsOverResolver() async {
        let session = CapturingNetworkSession()
        session.statusCode = 200
        // Resolver has a different token; the explicit one must win.
        let resolver = StubLLMTokenResolver([baseURL: "from-keychain"])

        _ = await LLMConnectionChecker.check(
            baseURL: baseURL,
            bearerToken: "from-securefield",
            session: session,
            resolver: resolver
        )

        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer from-securefield"
        )
    }

    func testCheck_nilBearerToken_fallsBackToResolver() async {
        let session = CapturingNetworkSession()
        session.statusCode = 200
        let resolver = StubLLMTokenResolver([baseURL: "from-keychain"])

        _ = await LLMConnectionChecker.check(
            baseURL: baseURL,
            bearerToken: nil,
            session: session,
            resolver: resolver
        )

        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer from-keychain"
        )
    }

    func testCheck_emptyBearerToken_andEmptyResolver_omitsHeader() async {
        let session = CapturingNetworkSession()
        session.statusCode = 200

        _ = await LLMConnectionChecker.check(
            baseURL: baseURL,
            bearerToken: "",
            session: session,
            resolver: StubLLMTokenResolver([:])
        )

        XCTAssertNil(session.capturedRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - 401 → actionable message

    func testCheckWithMessage_401_surfacesAuthRequiredMessage() async {
        let session = CapturingNetworkSession()
        session.statusCode = 401

        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: baseURL,
            bearerToken: "wrong-token",
            session: session,
            resolver: StubLLMTokenResolver([:])
        )

        XCTAssertFalse(result.isReachable)
        XCTAssertEqual(result.statusCode, 401)
        XCTAssertTrue(
            result.message.contains("Authentication required"),
            "Expected auth-required message; got: \(result.message)"
        )
    }

    func testCheckWithMessage_403_surfacesAuthRequiredMessage() async {
        let session = CapturingNetworkSession()
        session.statusCode = 403

        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: baseURL,
            session: session,
            resolver: StubLLMTokenResolver([:])
        )

        XCTAssertFalse(result.isReachable)
        XCTAssertTrue(result.message.contains("Authentication required"))
    }

    func testCheckWithMessage_200_returnsSuccessMessage() async {
        let session = CapturingNetworkSession()
        session.statusCode = 200

        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: baseURL,
            session: session,
            resolver: StubLLMTokenResolver([:])
        )

        XCTAssertTrue(result.isReachable)
        XCTAssertEqual(result.statusCode, 200)
    }

    // MARK: - Transport classifier (SF5) — distinguish DNS / refused / timeout

    private final class ThrowingNetworkSession: NetworkSession, @unchecked Sendable {
        let error: Error
        init(error: Error) { self.error = error }
        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            throw error
        }
        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    func testCheckWithMessage_dnsLookupFailed_distinguishedFromRefused() async {
        let session = ThrowingNetworkSession(error: URLError(.cannotFindHost))
        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: baseURL, session: session, resolver: StubLLMTokenResolver([:])
        )
        XCTAssertFalse(result.isReachable)
        XCTAssertNil(result.statusCode)
        XCTAssertTrue(
            result.message.lowercased().contains("hostname"),
            "DNS failure must say 'hostname' so user knows it's not a port issue. Got: \(result.message)"
        )
    }

    func testCheckWithMessage_connectionRefused_distinguishedFromDNS() async {
        let session = ThrowingNetworkSession(error: URLError(.cannotConnectToHost))
        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: baseURL, session: session, resolver: StubLLMTokenResolver([:])
        )
        XCTAssertTrue(
            result.message.lowercased().contains("refused"),
            "Connection-refused message should mention 'refused'. Got: \(result.message)"
        )
    }

    func testCheckWithMessage_timeout_mentionsTimeout() async {
        let session = ThrowingNetworkSession(error: URLError(.timedOut))
        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: baseURL, session: session, resolver: StubLLMTokenResolver([:])
        )
        XCTAssertTrue(
            result.message.lowercased().contains("did not respond")
                || result.message.lowercased().contains("timeout")
                || result.message.lowercased().contains("timed out"),
            "Timeout message should mention timing. Got: \(result.message)"
        )
    }

    func testCheckWithMessage_offline_mentionsOffline() async {
        let session = ThrowingNetworkSession(error: URLError(.notConnectedToInternet))
        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: baseURL, session: session, resolver: StubLLMTokenResolver([:])
        )
        XCTAssertTrue(
            result.message.lowercased().contains("offline"),
            "Offline message should mention offline status. Got: \(result.message)"
        )
    }

    // MARK: - probeOutcome typed return — direct tests

    func testProbeOutcome_dnsLookupFailed_returnsDNSCase() async {
        let session = ThrowingNetworkSession(error: URLError(.dnsLookupFailed))
        let outcome = await LLMConnectionChecker.probeOutcome(
            baseURL: baseURL, session: session, resolver: StubLLMTokenResolver([:])
        )
        if case .dnsLookupFailed = outcome { /* OK */ }
        else { XCTFail("Expected .dnsLookupFailed, got \(outcome)") }
    }

    func testProbeOutcome_200_returnsHttpCase() async {
        let session = CapturingNetworkSession()
        session.statusCode = 200
        let outcome = await LLMConnectionChecker.probeOutcome(
            baseURL: baseURL, session: session, resolver: StubLLMTokenResolver([:])
        )
        if case .http(let status) = outcome { XCTAssertEqual(status, 200) }
        else { XCTFail("Expected .http(200), got \(outcome)") }
    }

    func testProbeOutcome_invalidURL_returnsInvalidURL() async {
        let outcome = await LLMConnectionChecker.probeOutcome(
            baseURL: "" /* empty → URL(string:) returns nil after appendingPathComponent */,
            session: CapturingNetworkSession(),
            resolver: StubLLMTokenResolver([:])
        )
        // URL(string: "")?.appendingPathComponent("api/v1/models") may either
        // produce a relative-only URL or nil depending on platform; accept
        // either invalidURL or otherTransport — the point is "doesn't crash".
        switch outcome {
        case .invalidURL, .otherTransport:
            break
        default:
            XCTFail("Expected .invalidURL or .otherTransport for empty URL, got \(outcome)")
        }
    }
}
