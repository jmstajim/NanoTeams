import XCTest

@testable import NanoTeams

/// The session's configuration and the delegate's one decision. Every setting here is a
/// security choice, and a silently changed default is exactly the kind of thing nobody
/// notices — so they are asserted rather than trusted.
final class MCPHTTPSessionTests: XCTestCase {

    // MARK: - Configuration

    /// A shared session would let one server's `Set-Cookie` ride another's requests, and a
    /// cached `tools/list` would hide a rug pull behind a 304.
    func testTheSessionCarriesNoCookiesAndNoCache() {
        let configuration = MCPURLSessionFactory.configuration(timeouts: .standard)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertTrue(configuration.httpAdditionalHeaders?.isEmpty ?? true)
    }

    /// A request queued until the network comes back is a request the user cannot see; a
    /// server that is simply off should fail now and let the backoff decide when to retry.
    ///
    /// Both ceilings are the SERVER's own: until 2026-09-23 the resource ceiling was the
    /// constant 600 s, so a server given a longer absolute budget was still cut at 600 s, and
    /// the idle ceiling was the connect budget (see `StreamableHTTPTransportTests`).
    ///
    /// Each strictly ABOVE the client's own budget, never equal to it: the client's watchdog
    /// owns both, and an HTTP layer that fired first reported a timed-out call as a server that
    /// is unavailable, and sent a legacy server no cancellation. RED until 2026-09-23 (F12).
    func testTheSessionDoesNotWaitForConnectivityAndCarriesTheServersOwnCeilings() {
        let timeouts = MCPTimeouts(connect: 5, requestInactivity: 300, requestAbsolute: 3600)
        let configuration = MCPURLSessionFactory.configuration(timeouts: timeouts)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertGreaterThan(configuration.timeoutIntervalForRequest, 300)
        XCTAssertLessThan(configuration.timeoutIntervalForRequest, 3600)
        XCTAssertGreaterThan(configuration.timeoutIntervalForResource, 3600)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, timeouts.httpIdleTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, timeouts.httpResourceTimeout)
    }

    // MARK: - Redirects

    private func request(_ urlString: String) throws -> URLRequest {
        URLRequest(url: try XCTUnwrap(URL(string: urlString)))
    }

    func testTheDelegateFollowsASameOriginHop() throws {
        let delegate = MCPRedirectRefusingDelegate()
        let followed = delegate.decide(
            source: try XCTUnwrap(URL(string: "https://example.com/mcp")),
            newRequest: try request("https://example.com/v2/mcp"))
        XCTAssertEqual(followed?.url?.absoluteString, "https://example.com/v2/mcp")
        XCTAssertNil(delegate.takeRefusedRedirect())
    }

    /// The hop that matters: a permitted host handing the connection — and the `Authorization`
    /// header — to one that was never allowed.
    func testTheDelegateRefusesACrossOriginHopAndRecordsWhereItPointed() throws {
        let delegate = MCPRedirectRefusingDelegate()
        XCTAssertNil(delegate.decide(
            source: try XCTUnwrap(URL(string: "https://example.com/mcp")),
            newRequest: try request("https://evil.test/mcp")))
        let refused = delegate.takeRefusedRedirect()
        XCTAssertEqual(refused?.from, "https://example.com/mcp")
        XCTAssertEqual(refused?.to, "https://evil.test/mcp")
    }

    /// Reading clears: a refusal left behind would be reported against the next unrelated
    /// failure on the same session.
    func testReadingARefusalClearsIt() throws {
        let delegate = MCPRedirectRefusingDelegate()
        _ = delegate.decide(source: try XCTUnwrap(URL(string: "https://a.test/mcp")),
                            newRequest: try request("https://b.test/mcp"))
        XCTAssertNotNil(delegate.takeRefusedRedirect())
        XCTAssertNil(delegate.takeRefusedRedirect())
    }

    /// A redirect the transport cannot attribute is still refused — the safe direction when
    /// the source URL is missing is "do not follow".
    func testAHopWithNoKnownSourceIsRefused() throws {
        let delegate = MCPRedirectRefusingDelegate()
        XCTAssertNil(delegate.decide(source: nil, newRequest: try request("https://example.com/mcp")))
        XCTAssertEqual(delegate.takeRefusedRedirect()?.from, "the server")
    }

    /// The credential in a recorded URL is removed before it is written anywhere.
    func testARecordedRedirectIsRedacted() throws {
        let delegate = MCPRedirectRefusingDelegate()
        _ = delegate.decide(source: try XCTUnwrap(URL(string: "https://u:p@a.test/mcp?token=SECRET-1234")),
                            newRequest: try request("https://b.test/mcp?token=SECRET-1234"))
        let refused = try XCTUnwrap(delegate.takeRefusedRedirect())
        XCTAssertFalse(refused.from.contains("SECRET-1234"), refused.from)
        XCTAssertFalse(refused.from.contains("u:p"), refused.from)
        XCTAssertFalse(refused.to.contains("SECRET-1234"), refused.to)
    }

    /// The completion-handler entry point itself, not just the decision behind it. It exists
    /// in that form because the `async` spelling crashes SILGen on Swift 6.4, so the wrapper
    /// is the part a compiler upgrade would silently change.
    func testTheDelegateEntryPointAnswersThroughItsCompletionHandler() throws {
        let delegate = MCPRedirectRefusingDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://example.com/mcp")))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://example.com/mcp")),
            statusCode: 302, httpVersion: nil, headerFields: nil))

        // The handler is `@Sendable`, so the answer lands in a box rather than in a local.
        let answers = RedirectAnswers()
        delegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: try request("https://example.com/v2/mcp"),
            completionHandler: { answers.record($0) })
        XCTAssertEqual(answers.last??.url?.absoluteString, "https://example.com/v2/mcp")

        delegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: try request("https://evil.test/mcp"),
            completionHandler: { answers.record($0) })
        XCTAssertEqual(answers.last, .some(nil), "a cross-origin hop is answered with nil")
        XCTAssertNotNil(delegate.takeRefusedRedirect())
    }

    /// The `task.currentRequest` fallback: a 3xx whose response carries no URL still has to be
    /// judged from somewhere, and the original request is the last thing left.
    func testAResponseWithoutAURLFallsBackToTheTasksOwnRequest() throws {
        let delegate = MCPRedirectRefusingDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://example.com/mcp")))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://example.com/mcp")),
            statusCode: 302, httpVersion: nil, headerFields: nil))
        XCTAssertNotNil(delegate.decide(
            task: task, response: response, newRequest: try request("https://example.com/again")))
    }

    // MARK: - The production session

    /// The wrapper forwards both halves of `NetworkSession` and can be torn down — a
    /// `URLSession` holding a delegate leaks until it is invalidated.
    func testTheProductionSessionForwardsAndCanBeInvalidated() async throws {
        let session = MCPURLSession(timeouts: MCPTimeouts(connect: 2, requestInactivity: 5, requestAbsolute: 5))
        XCTAssertNil(session.takeRefusedRedirect())

        // A `data:` URL exercises both entry points without a socket.
        let dataURL = try XCTUnwrap(URL(string: "data:application/json;base64,"
            + Data("{}".utf8).base64EncodedString()))
        let (data, _) = try await session.sessionData(for: URLRequest(url: dataURL))
        XCTAssertEqual(String(data: data, encoding: .utf8), "{}")
        let (bytes, _) = try await session.sessionBytes(for: URLRequest(url: dataURL))
        var count = 0
        for try await _ in bytes { count += 1 }
        XCTAssertEqual(count, 2)

        session.invalidate()
    }

    /// The delegate answers on whatever queue `URLSession` calls it from, so the test's own
    /// capture needs a lock rather than a `var`.
    private final class RedirectAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest?] = []
        func record(_ request: URLRequest?) { lock.withLock { recorded.append(request) } }
        var last: URLRequest?? { lock.withLock { recorded.last } }
    }
}
