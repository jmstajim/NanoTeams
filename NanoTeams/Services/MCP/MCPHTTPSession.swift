import Foundation

/// A redirect the delegate refused, kept so the transport can report WHERE the server tried
/// to send it rather than just that something went wrong.
nonisolated struct MCPRefusedRedirect: Hashable, Sendable {
    let from: String
    let to: String
}

/// The URL-loading seam the MCP transport owns.
///
/// It refines `NetworkSession` — the app's existing stub point — with the two things a
/// dedicated session needs and a shared one cannot offer: it can be torn down (a `URLSession`
/// holding a delegate leaks until it is invalidated), and it can report a refused redirect,
/// which happens inside the delegate where the transport cannot see it.
nonisolated protocol MCPHTTPSession: NetworkSession {
    func invalidate()
    /// The most recent redirect this session refused, or `nil`. Read after a request comes
    /// back with a 3xx that was not followed.
    func takeRefusedRedirect() -> MCPRefusedRedirect?
}

/// Refuses any redirect that leaves the origin.
///
/// `URLSession` follows redirects by default AND re-attaches the request's headers on a
/// same-host hop, so without an explicit delegate a server could answer `302` with a
/// `Location` pointing anywhere and receive the `Authorization` header meant for it. Returning
/// `nil` stops the chain and hands the 3xx response back to the caller, which turns it into a
/// named failure.
nonisolated final class MCPRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var refused: MCPRefusedRedirect?

    /// The completion-handler form, not the `async` one, and not by preference: on Swift 6.4
    /// the `async` spelling of this delegate method crashes SILGen while emitting the
    /// native-to-foreign thunk for its `URLRequest?` return (`emitNativeToForeignThunk`, no
    /// diagnostic, just a stack dump). The completion-handler overload compiles and does the
    /// same job.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(decide(task: task, response: response, newRequest: request))
    }

    /// The decision itself, off the delegate signature so it can be exercised without a
    /// URLSession. The hop is judged from the URL that ISSUED the 3xx, not from the original
    /// request: on a chain, an allowed first hop must not vouch for a second one.
    func decide(task: URLSessionTask, response: HTTPURLResponse, newRequest request: URLRequest) -> URLRequest? {
        decide(
            source: response.url ?? task.currentRequest?.url ?? task.originalRequest?.url,
            newRequest: request)
    }

    func decide(source: URL?, newRequest request: URLRequest) -> URLRequest? {
        guard let source, let destination = request.url,
              MCPRedirectPolicy.allows(from: source, to: destination) else {
            record(MCPRefusedRedirect(
                from: source.map(MCPRedaction.url) ?? "the server",
                to: request.url.map(MCPRedaction.url) ?? "another address"))
            return nil
        }
        return request
    }

    private func record(_ redirect: MCPRefusedRedirect) {
        lock.lock(); defer { lock.unlock() }
        refused = redirect
    }

    /// Reads and clears. Clearing matters: a refusal left behind would be reported against the
    /// next unrelated failure on the same session.
    func takeRefusedRedirect() -> MCPRefusedRedirect? {
        lock.lock(); defer { lock.unlock() }
        defer { refused = nil }
        return refused
    }
}

/// The production `MCPHTTPSession`: one ephemeral `URLSession` per server connection.
///
/// Ephemeral, cookie-less and cache-less by construction. None of the three is theoretical:
/// a shared session would let one server's `Set-Cookie` ride another's requests, and a cached
/// `tools/list` would hide a rug pull behind a 304.
nonisolated final class MCPURLSession: MCPHTTPSession, @unchecked Sendable {

    private let session: URLSession
    private let delegate: MCPRedirectRefusingDelegate

    init(timeouts: MCPTimeouts = .standard) {
        let delegate = MCPRedirectRefusingDelegate()
        self.delegate = delegate
        self.session = MCPURLSessionFactory.make(delegate: delegate, timeouts: timeouts)
    }

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }

    /// `invalidateAndCancel` rather than `finishTasksAndInvalidate`: the caller is closing the
    /// connection, and a long-lived SSE stream would never "finish" on its own.
    func invalidate() { session.invalidateAndCancel() }

    func takeRefusedRedirect() -> MCPRefusedRedirect? { delegate.takeRefusedRedirect() }
}

/// Builds the configuration. Separate from `MCPURLSession` so the settings can be asserted
/// without opening a socket — every one of them is a security decision, and a silently
/// changed default is exactly the kind of thing that is never noticed.
nonisolated enum MCPURLSessionFactory {

    static func make(delegate: MCPRedirectRefusingDelegate, timeouts: MCPTimeouts) -> URLSession {
        URLSession(configuration: configuration(timeouts: timeouts),
                   delegate: delegate, delegateQueue: nil)
    }

    /// Both ceilings are the SERVER's own. `timeoutIntervalForRequest` is the HTTP layer's
    /// wait for the next byte, so it follows the inactivity budget; `timeoutIntervalForResource`
    /// caps a task's whole life, so it follows the absolute one — each a margin above it
    /// (`MCPTimeouts.httpIdleTimeout`). Each request still sets its own idle value — this is
    /// the fallback for one that does not. Until 2026-09-23 the resource ceiling was the
    /// constant 600 s, so a server given a longer absolute budget was cut at 600 s anyway.
    static func configuration(timeouts: MCPTimeouts) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = [:]
        configuration.timeoutIntervalForRequest = timeouts.httpIdleTimeout
        configuration.timeoutIntervalForResource = timeouts.httpResourceTimeout
        // A request queued until the network comes back is a request the user cannot see; a
        // server that is simply off should fail now and let the backoff decide when to retry.
        configuration.waitsForConnectivity = false
        return configuration
    }
}

/// The HTTP layer's own ceilings, each strictly ABOVE the budget `MCPClient`'s watchdog
/// enforces, so the watchdog is the one owner of both and the HTTP layer only ends what nobody
/// watches.
///
/// Equal, as they were until 2026-09-23, the two raced: URLSession resets its idle clock when a
/// progress report's BYTES arrive, the client only after it has decoded and routed them, so
/// after a report the HTTP layer could fire first by milliseconds — and the call failed as
/// "server unavailable, reconnect" instead of "timed out", and a legacy server got no
/// `notifications/cancelled` (F12).
nonisolated extension MCPTimeouts {
    /// `URLRequest.timeoutInterval` of a POST, and the session's fallback for a request that
    /// sets none.
    var httpIdleTimeout: TimeInterval { requestInactivity + MCPConstants.httpTimeoutMargin }
    /// `timeoutIntervalForResource`.
    var httpResourceTimeout: TimeInterval { requestAbsolute + MCPConstants.httpTimeoutMargin }
}
