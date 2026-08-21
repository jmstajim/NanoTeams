import Foundation

/// LM Studio's undocumented WebSocket RPC dialect — and nothing about what the answers mean.
///
/// Reverse-engineered from `lmstudio-js` and then MEASURED against LM Studio 0.4.21 on
/// 2026-08-19. Three of its rules are load-bearing and none of them is guessable:
///
/// 1. The authentication frame is REQUIRED, and its absence is answered with silence rather than
///    a refusal — a client that skips it waits forever for a reply that is never coming.
/// 2. Its three keys must all be present, but their VALUES are not checked: empty strings
///    authenticate. So they are constants here, never anything user-derived, and the identifier
///    exists to name this app in the server's logs.
/// 3. The `parameter` key must be ABSENT from an `rpcCall` whose endpoint takes no argument.
///    Both `{}` and `null` are rejected with "Expected void" — which is why `RPCCallFrame` has no
///    such field at all rather than an optional one, and why a test asserts on the encoded bytes.
///
/// The whole exchange measured at a 1.4 ms median across seven runs (connect, upgrade,
/// authenticate and call), which is what makes a one-second deadline three orders of magnitude of
/// headroom rather than a compromise.
nonisolated struct LMStudioWebSocketRPC: Sendable {

    let connector: any WebSocketConnecting
    let tokenResolver: any LLMTokenResolver
    /// Budget for the WHOLE exchange, not per operation. Per-operation timeouts add up: three
    /// slow steps under a 1 s limit each can spend 3 s between them, and a socket that connects
    /// and then goes quiet would sit there for the sum. One deadline cannot be outlasted that way.
    let timeout: Duration

    init(
        connector: any WebSocketConnecting = URLSessionWebSocketConnector(),
        tokenResolver: any LLMTokenResolver = DefaultLLMTokenResolver(),
        timeout: Duration = .seconds(1)
    ) {
        self.connector = connector
        self.tokenResolver = tokenResolver
        self.timeout = timeout
    }

    /// Opens `ws(s)://host/<namespace>`, authenticates, issues ONE `rpcCall`, decodes its `result`.
    ///
    /// Returns nil on ANY failure — bad URL, refused upgrade, refused auth, a warning naming our
    /// endpoint, an undecodable payload, or the deadline. A probe that cannot answer says nothing;
    /// it must never throw into a measurement, and it must never delay one.
    func call<Result: Decodable & Sendable>(
        namespace: String,
        endpoint: String,
        baseURLString: String,
        as _: Result.Type
    ) async -> Result? {
        guard let url = Self.webSocketURL(baseURLString: baseURLString, namespace: namespace)
        else { return nil }
        var upgrade = URLRequest(url: url)
        upgrade.applyLMStudioBearer(baseURL: baseURLString, resolver: tokenResolver)

        // Captured as immutable locals so the child task closes over Sendable VALUES only —
        // never over `self`, and never over a `var` the enclosing task could still write to. A
        // task-group closure is `sending`, and a captured mutable binding is exactly what that
        // rules out.
        let request = upgrade
        let connector = self.connector
        let deadline = timeout

        return await withTaskGroup(of: Result?.self) { group in
            group.addTask {
                await Self.exchange(
                    request, endpoint: endpoint, connector: connector, as: Result.self)
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// One connection, closed on every path out — including cancellation, which is why `close()`
    /// is synchronous.
    private static func exchange<Result: Decodable & Sendable>(
        _ request: URLRequest,
        endpoint: String,
        connector: any WebSocketConnecting,
        as _: Result.Type
    ) async -> Result? {
        guard let channel = try? await connector.connect(request) else { return nil }
        defer { channel.close() }

        guard await authenticate(on: channel) else { return nil }

        let callID = 1
        guard let frame = try? JSONCoderFactory.makeWireEncoder().encode(
            RPCCallFrame(endpoint: endpoint, callId: callID)),
            let text = String(data: frame, encoding: .utf8),
            (try? await channel.send(.text(text))) != nil
        else { return nil }

        return await awaitResult(on: channel, callID: callID, endpoint: endpoint, as: Result.self)
    }

    private static func authenticate(on channel: any WebSocketChannel) async -> Bool {
        guard let frame = try? JSONCoderFactory.makeWireEncoder().encode(AuthFrame()),
              let text = String(data: frame, encoding: .utf8),
              (try? await channel.send(.text(text))) != nil,
              case .text(let reply)? = try? await channel.receive(),
              let decoded = try? JSONCoderFactory.makeWireDecoder()
              .decode(AuthReply.self, from: Data(reply.utf8))
        else { return false }
        return decoded.success == true
    }

    /// Reads until the answer to OUR call arrives.
    ///
    /// Frames for another `callId` are skipped rather than accepted: a shared socket answering an
    /// unrelated question is not our result. Binary and non-JSON frames are skipped for the same
    /// reason. A `communicationWarning` naming our endpoint ends the wait immediately — the server
    /// has said it will not answer, and waiting out the deadline would only make a knowable
    /// failure slower.
    private static func awaitResult<Result: Decodable & Sendable>(
        on channel: any WebSocketChannel,
        callID: Int,
        endpoint: String,
        as _: Result.Type
    ) async -> Result? {
        let decoder = JSONCoderFactory.makeWireDecoder()
        while true {
            // The cancellation exit is written where it happens rather than as a condition on the
            // loop: a `while !Task.isCancelled` needs a trailing `return nil` that no execution can
            // ever reach, and an unreachable line is a line nothing can pin.
            if Task.isCancelled { return nil }
            // A transport failure ends the wait; a frame we cannot read does NOT. Collapsing the
            // two would let one stray binary frame look like the peer hanging up.
            guard let frame = try? await channel.receive() else { return nil }
            guard case .text(let reply) = frame else { continue }
            let data = Data(reply.utf8)
            if let warning = try? decoder.decode(RPCWarning.self, from: data),
               warning.type == "communicationWarning",
               warning.warning?.contains(endpoint) == true {
                return nil
            }
            guard let envelope = try? decoder.decode(RPCEnvelope<Result>.self, from: data),
                  envelope.callId == callID, let result = envelope.result
            else { continue }
            return result
        }
    }

    /// `http` → `ws`, `https` → `wss`, on the same host, port and path the REST API uses. Any
    /// other scheme yields nil rather than a guess: this app talks to servers a user typed in.
    static func webSocketURL(baseURLString: String, namespace: String) -> URL? {
        guard var components = URLComponents(string: baseURLString.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(),
              components.host?.isEmpty == false
        else { return nil }
        switch scheme {
        case "http", "ws": components.scheme = "ws"
        case "https", "wss": components.scheme = "wss"
        default: return nil
        }
        let base = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = base + "/" + namespace
        return components.url
    }

    // MARK: - Wire frames

    /// All three keys are required and none of the values is checked — see the type's note.
    private struct AuthFrame: Encodable {
        let authVersion = 1
        let clientIdentifier = "nanoteams"
        let clientPasskey = "nanoteams"
    }

    /// No `parameter` field EXISTS on this type. An optional one would encode as `null` or be
    /// omitted depending on encoder details a future refactor will change, and the server rejects
    /// `null` exactly as it rejects `{}`.
    private struct RPCCallFrame: Encodable {
        let type: String
        let endpoint: String
        let callId: Int

        init(endpoint: String, callId: Int) {
            self.type = "rpcCall"
            self.endpoint = endpoint
            self.callId = callId
        }
    }

    private struct AuthReply: Decodable {
        var success: Bool?
    }

    private struct RPCEnvelope<Payload: Decodable>: Decodable {
        var type: String?
        var callId: Int?
        var result: Payload?
    }

    private struct RPCWarning: Decodable {
        var type: String?
        var warning: String?
        var kind: String?
    }
}
