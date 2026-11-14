import Foundation

/// What a transport carries for `MCPClient`: frames out, frames in, and the two lifecycle
/// verbs.
///
/// The seam exists twice over. It is the DIP boundary a test substitutes (`ScriptedTransport`
/// answers frames from a list, with no HTTP at all), and it is where a second transport would
/// attach if one is ever added — stdio, which this wave deliberately does not ship, because a
/// local process is the "run an arbitrary command as the user" vector and an HTTP-only client
/// does not have it by construction.
///
/// **Every reply arrives through `events()`, including the reply to a request.** The
/// alternative — `send` returning the response — cannot express what Streamable HTTP
/// actually does: one POST can answer with an SSE stream carrying progress notifications
/// and then the result, and a legacy server can answer on a completely different connection
/// (the GET stream). One inbound channel, correlation by id in `MCPClient`, is the shape
/// that holds both.
nonisolated protocol MCPTransport: Sendable {

    /// Opens the transport. For HTTP this validates the endpoint and builds the session; no
    /// request is made, because which request comes first is the era probe's decision.
    func connect() async throws

    /// Tells the transport which revision the handshake settled on, and the exact version
    /// string to put in `MCP-Protocol-Version` from now on. Called once, after the probe:
    /// before it the transport writes the modern version, because the probe IS a modern
    /// request. For the legacy era this is also when the server's own push channel opens —
    /// before the handshake there is no session for it to belong to.
    func adopt(era: MCPProtocolEra, protocolVersion: String) async

    /// Writes one frame. `hints` carries what the 2026-07-28 headers need and the frame
    /// body does not repeat.
    @discardableResult
    func send(_ frame: MCPOutgoingFrame, hints: MCPSendHints) async throws -> MCPSendOutcome

    /// The inbound channel. Called once per connection; a second call returns a stream that
    /// yields nothing, because the frames have an owner already.
    func events() async -> AsyncStream<MCPIncomingEvent>

    /// Abandons one in-flight request by closing the stream its reply was coming back on. A
    /// POST still waiting for its FIRST byte is not a stream yet: it runs inside the task that
    /// called `send`, and cancelling that task is what closes it — `MCPClient` does both.
    /// The `notifications/cancelled` courtesy frame is the CLIENT's business, not the
    /// transport's — the transport does not know whether the server's era has one.
    func cancel(requestID: JSONRPCID) async

    /// Ends the transport, spending at most `budget` seconds on the graceful part (the
    /// legacy `DELETE` that releases the server's session).
    func close(budget: TimeInterval) async
}

// MARK: - Frames

nonisolated enum MCPOutgoingFrame: Sendable, Hashable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    /// The client's reply to a server-initiated request. Legacy era only — and only ever
    /// `ping`'s empty result or a `methodNotFound` refusal, because this client advertises
    /// no capabilities.
    case response(JSONRPCResponse)

    var method: String? {
        switch self {
        case .request(let request): return request.method
        case .notification(let notification): return notification.method
        case .response: return nil
        }
    }

    /// The id a reply to THIS frame would carry: a request's own. A notification awaits no
    /// answer, and neither does this client's reply to a server's request — whose id is the
    /// SERVER's, from a namespace that only shares its spelling with this client's own ids. The
    /// one id the transport keys what comes back on: the error answering a 4xx, the stream it
    /// reads, the reply that settles it (`StreamableHTTPTransport.send`). Until 2026-10-28 it
    /// was keyed on any frame's id (`requestID`, which this replaced), a reply's included, and a
    /// server refusing this client's reply to its request #7 with a body echoing `7` failed this
    /// client's own request #7 — its stream's end did too — the class
    /// `MCPClient.routeNotification` closes for a server's `notifications/cancelled`.
    var awaitedResponseID: JSONRPCID? {
        if case .request(let request) = self { return request.id }
        return nil
    }
}

/// What the modern era mirrors into headers beside the body.
///
/// The 2026-07-28 revision copies routing metadata out of the JSON into headers so an
/// intermediary can read it without parsing the body; the body keeps it, and stays
/// authoritative. The client passes what it knows; the transport decides which era's headers to
/// write, because only it knows which era the connection settled on.
nonisolated struct MCPSendHints: Sendable, Hashable {
    /// The tool or resource the call names — `Mcp-Name`.
    let name: String?
    /// `x-mcp-header` parameters a tool declared, mirrored from the body and already validated
    /// by the caller (`MCPArgumentCoercion`) — which hands none for a legacy-era session.
    let headerParameters: [String: String]
    /// Whether the caller expects a long-lived notification stream (`subscriptions/listen`)
    /// rather than a single request/response turn. `StreamableHTTPTransport` gives a POST with
    /// this hint `timeouts.requestAbsolute` instead of `timeouts.httpIdleTimeout` and treats a
    /// clean end of its SSE stream as normal completion rather than `.streamEnded`.
    let expectsLongLivedStream: Bool
    /// The `MCP-Protocol-Version` header value for THIS frame, or `nil` when the frame carries
    /// none (the legacy opening `initialize`) or relies on the transport's adopted version.
    let protocolVersion: String?

    static let none = MCPSendHints(
        name: nil, headerParameters: [:], expectsLongLivedStream: false, protocolVersion: nil)

    init(
        name: String? = nil,
        headerParameters: [String: String] = [:],
        expectsLongLivedStream: Bool = false,
        protocolVersion: String? = nil
    ) {
        self.name = name
        self.headerParameters = headerParameters
        self.expectsLongLivedStream = expectsLongLivedStream
        self.protocolVersion = protocolVersion
    }

    func withProtocolVersion(_ protocolVersion: String?) -> MCPSendHints {
        MCPSendHints(
            name: name, headerParameters: headerParameters,
            expectsLongLivedStream: expectsLongLivedStream, protocolVersion: protocolVersion)
    }
}

nonisolated enum MCPSendOutcome: Sendable, Hashable {
    /// The server took the frame and said nothing more (HTTP 202). A reply, if the frame
    /// deserves one, arrives on another connection.
    case accepted
    /// The server answered on this connection; the frames are already on `events()`.
    case answered
}

nonisolated enum MCPIncomingEvent: Sendable, Hashable {
    case frame(JSONRPCIncoming)
    /// The CONNECTION is gone — said by a transport that is one connection, where that fact
    /// is true of every request at once. The client fails them all rather than letting them
    /// time out one by one: a role waiting 120 s for a server that is already gone is a stall
    /// the user cannot explain.
    case failed(MCPTransportError)
    /// The stream carrying ONE request's reply broke, or ended before the reply came. Only
    /// that request fails. Over HTTP every request is its own exchange, and until 2026-09-23
    /// one broken stream was reported as `.failed` — one slow tool failed every call in
    /// flight beside it.
    case requestFailed(JSONRPCID, MCPTransportError)
    /// A stream no request is waiting on — the legacy push channel — broke, or the server
    /// refused it. Nothing fails; the transport reopens it when asking again can help, and the
    /// client only records it.
    case streamLost(MCPTransportError)
    /// The server forgot the session (legacy 404). Whoever owns the connection starts a new
    /// one: re-initialize, re-list, re-pin.
    case sessionLost
    case closed
}

// MARK: - Failures

/// Why a transport could not carry a frame.
///
/// Every case is reader-facing text: it reaches the server row in Settings and, folded into
/// `MCP_SERVER_UNAVAILABLE`, the model. None of them quotes a header, and `network` is built
/// from a classified `URLError` code rather than from the system's own message — a
/// localized network string in a tool result is the failure this app already fixed once.
nonisolated enum MCPTransportError: Error, Hashable, LocalizedError {
    case endpointRefused(String)
    case notConnected
    case httpStatus(code: Int, body: String)
    case unauthorized(status: Int, challenge: String?)
    /// The server forgot the session (404 on a request that carried `Mcp-Session-Id`). The
    /// client re-initializes and re-lists rather than reporting a failure.
    case sessionLost
    case frameTooLarge(bytes: Int, limit: Int)
    case malformedFrame(String)
    case redirectRefused(from: String, to: String)
    case network(String)
    case timedOut
    /// A request's stream ended without its reply, and either carried no `id:` to resume from
    /// or exhausted `MCPConstants.maxStreamResumptionAttempts` `Last-Event-ID` resumptions.
    case streamEnded
    case closed

    var errorDescription: String? { message }

    /// Non-optional, and that is the point: `LocalizedError` types it `String?`, so every
    /// caller wrote `errorDescription ?? "something went wrong"` — a fallback no arm of this
    /// switch can reach. Saying it once here deletes the fallback everywhere.
    var message: String {
        switch self {
        case .endpointRefused(let reason):
            return reason
        case .notConnected:
            return "The server is not connected. Enable it in Settings → MCP Servers, then try again."
        case .httpStatus(let code, let body):
            let detail = body.isEmpty ? "" : " — \(body)"
            return "The server answered HTTP \(code)\(detail). Check the URL and that the server is running."
        case .unauthorized(let status, let challenge):
            let detail = challenge.map { " (\($0))" } ?? ""
            return "The server refused the credentials with HTTP \(status)\(detail). Update the token in Settings → MCP Servers."
        case .sessionLost:
            return "The server dropped the session. A new one is being started — try the call again."
        case .frameTooLarge(let bytes, let limit):
            return "The server sent a \(bytes)-byte frame, past the \(limit)-byte ceiling. Ask the server to paginate its answer."
        case .malformedFrame(let detail):
            return "The server sent a frame this client cannot read: \(detail)"
        case .redirectRefused(let from, let to):
            return "The server redirected from \(from) to a different origin (\(to)). Point the URL at the final host instead."
        case .network(let reason):
            return "Could not reach the server: \(reason)"
        case .timedOut:
            return "The server did not answer in time. Check that it is running, then reconnect."
        case .streamEnded:
            return "The server closed the stream before it answered. Try the call again."
        case .closed:
            return "The connection was closed. Reconnect to continue."
        }
    }

    /// Whether reconnecting could plausibly help. A refused endpoint or a refused redirect
    /// is a configuration fact and will refuse identically forever; a dropped connection is
    /// not.
    var isRetryable: Bool {
        switch self {
        case .endpointRefused, .redirectRefused, .unauthorized, .frameTooLarge:
            return false
        case .notConnected, .httpStatus, .sessionLost, .malformedFrame, .network, .timedOut, .streamEnded,
             .closed:
            return true
        }
    }
}
