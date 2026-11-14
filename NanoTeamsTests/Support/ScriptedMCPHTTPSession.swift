import Foundation

@testable import NanoTeams

/// An `MCPHTTPSession` that answers from a script instead of from a socket.
///
/// `URLSession.AsyncBytes` has no public initializer, so a real byte stream is fabricated
/// through URLSession's built-in `data:` URL handler — the same trick the LM Studio streaming
/// tests use — and paired with a hand-built `HTTPURLResponse`. That is what lets the
/// transport's whole body run for real: the status ladder, the SSE parse loop, the byte
/// ceiling, the header writing.
final class ScriptedMCPHTTPSession: MCPHTTPSession, @unchecked Sendable {

    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = ""
        /// Thrown from `sessionBytes` instead of answering — a transport failure.
        var error: Error?
        /// Answer with a plain `URLResponse` so the "not an HTTP response" arm runs.
        var nonHTTPResponse = false

        static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status,
                  headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a },
                  body: body)
        }

        static func sse(_ body: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: 200,
                  headers: headers.merging(["Content-Type": "text/event-stream"]) { a, _ in a },
                  body: body)
        }

        static func status(_ status: Int, body: String = "", headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers, body: body)
        }

        static let accepted = Reply(status: 202, headers: [:], body: "")

        /// Answer with a plain `URLResponse`, so the "not an HTTP response" arm runs.
        static let nonHTTP = Reply(status: 200, headers: [:], body: "", nonHTTPResponse: true)
    }

    /// Consumed in order. The last one repeats, so a test that only cares about the first
    /// exchange does not have to script the rest.
    var replies: [Reply] = []
    /// When set, what every GET gets instead — consumed the same way. The legacy push channel
    /// opens on its own task, so sharing one queue with the POSTs makes which request gets
    /// which reply a race.
    var getReplies: [Reply] = []
    /// When set, a GET is answered only once a POST carrying this JSON-RPC method has gone out —
    /// what a real server does: it cannot reply on its push stream to a request it has not
    /// received. The push channel opens on its own task, so without this a scripted reply could
    /// land before the client sent the request it answers, and the client rightly drops a reply
    /// nobody waits for (2026-11-07: the parallel instrumented run timed out
    /// `testAReplySentOnTheLegacyPushChannelAnswersItsPendingRequest` that way). Bounded at ten
    /// seconds, like a hung DELETE, so a POST that never comes fails the test instead of hanging it.
    var getRepliesAwaitRPCMethod: String?
    /// When a POST carries a JSON-RPC method named here, what it gets instead — every time,
    /// not consumed. A connection that reconnects sends the same methods over and over, and a
    /// queue scripted for one pass would answer the second pass's `initialize` with the first
    /// pass's `tools/list`. `{{id}}` in the body is replaced by the request's own id, so the
    /// reply correlates whichever attempt asked.
    var repliesByRPCMethod: [String: Reply] = [:]
    var refusedRedirect: MCPRefusedRedirect?
    /// A 2026-07-28 request is first checked the way a conforming server checks it
    /// (`ConformingMCPServerCheck`): one missing a required `_meta` key is answered `400` +
    /// `-32602`, one whose headers disagree with its body `400` + `-32020` — before, and instead
    /// of, any scripted reply, which stays where it was in its queue. Off by default: a transport
    /// test sends hand-built frames the check would refuse. On for the modern end-to-end tests,
    /// so a malformed modern request can no longer pass a session that accepts any `_meta`.
    var conforming = false
    /// Declared `x-mcp-header` parameters by tool name, checked when `conforming` is `true`
    /// alongside any extracted from `repliesByRPCMethod[MCPWire.toolsListMethod]`.
    var toolHeaderParameters: [String: [ConformingMCPServerCheck.HeaderParameter]] = [:]
    /// When set, a `DELETE` is never answered: it waits until its task is cancelled — counted in
    /// `abandonedDeleteCount` — and throws, or gives up after ten seconds and throws. A legacy
    /// server sitting on the release of its session, for the close's budget to end.
    var hangsDeletes: Bool {
        get { lock.withLock { deletesHang } }
        set { lock.withLock { deletesHang = newValue } }
    }
    /// Hung `DELETE`s that ended because their task was cancelled.
    var abandonedDeleteCount: Int { lock.withLock { abandonedDeletes } }
    private var deletesHang = false
    private var abandonedDeletes = 0

    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private var replyIndex = 0
    private var getReplyIndex = 0
    private var invalidations = 0

    var requests: [URLRequest] { lock.withLock { sent } }
    var invalidateCount: Int { lock.withLock { invalidations } }

    /// Every request that went out, by HTTP method — the shape most assertions want.
    func requests(method: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method }
    }

    /// Every POST that carried the JSON-RPC `method`.
    func requests(rpcMethod: String) -> [URLRequest] {
        requests.filter { Self.rpcMethod(of: $0) == rpcMethod }
    }

    private static func rpcMethod(of request: URLRequest) -> String? {
        rpcObject(of: request)?["method"] as? String
    }

    private static func rpcObject(of request: URLRequest) -> [String: Any]? {
        guard let body = request.httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// The request's id as it would be written back — a number bare, a string quoted.
    private static func idLiteral(of request: URLRequest) -> String {
        switch rpcObject(of: request)?["id"] {
        case let number as Int: return String(number)
        case let text as String: return "\"\(text)\""
        default: return "null"
        }
    }

    func header(_ name: String, ofRequest index: Int = 0) -> String? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index].value(forHTTPHeaderField: name)
    }

    // MARK: - MCPHTTPSession

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let reply = record(request)
        if request.httpMethod == "DELETE", hangsDeletes {
            let deadline = Date().addingTimeInterval(10)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            if Task.isCancelled { lock.withLock { abandonedDeletes += 1 } }
            throw CancellationError()
        }
        if let error = reply.error { throw error }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let reply = record(request)
        if request.httpMethod == "GET", let awaited = getRepliesAwaitRPCMethod {
            let deadline = Date().addingTimeInterval(10)
            while requests(rpcMethod: awaited).isEmpty, !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        if let error = reply.error { throw error }
        let mime = reply.headers["Content-Type"] ?? "application/octet-stream"
        let dataURL = URL(string: "data:\(mime);base64," + Data(reply.body.utf8).base64EncodedString())!
        let (bytes, _) = try await URLSession.shared.bytes(from: dataURL)
        if reply.nonHTTPResponse {
            return (bytes, URLResponse(
                url: request.url!, mimeType: mime, expectedContentLength: -1, textEncodingName: nil))
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (bytes, http)
    }

    func invalidate() { lock.withLock { invalidations += 1 } }

    func takeRefusedRedirect() -> MCPRefusedRedirect? {
        lock.withLock {
            defer { refusedRedirect = nil }
            return refusedRedirect
        }
    }

    private func record(_ request: URLRequest) -> Reply {
        lock.withLock {
            sent.append(request)
            if conforming, request.httpMethod == "POST" {
                var declared = toolHeaderParameters
                if let listed = repliesByRPCMethod[MCPWire.toolsListMethod]?.body.data(using: .utf8) {
                    for (tool, params) in ConformingMCPServerCheck.headerParameters(inToolsListBody: listed)
                        where declared[tool] == nil {
                        declared[tool] = params
                    }
                }
                if let refusal = ConformingMCPServerCheck.refusal(
                    header: { request.value(forHTTPHeaderField: $0) },
                    body: request.httpBody,
                    toolHeaderParameters: declared) {
                    let id = request.httpBody
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["id"]
                    return Reply.json(refusal.body(answering: id), status: refusal.status)
                }
            }
            if request.httpMethod == "GET", !getReplies.isEmpty {
                let reply = getReplies[min(getReplyIndex, getReplies.count - 1)]
                getReplyIndex += 1
                return reply
            }
            if let method = Self.rpcMethod(of: request), var reply = repliesByRPCMethod[method] {
                reply.body = reply.body.replacingOccurrences(of: "{{id}}", with: Self.idLiteral(of: request))
                return reply
            }
            guard !replies.isEmpty else { return Reply.accepted }
            let reply = replies[min(replyIndex, replies.count - 1)]
            replyIndex += 1
            return reply
        }
    }
}

/// Collects the first `count` events off a transport with a wall-clock ceiling, so a test that
/// scripts a frame that never arrives fails as a timeout rather than hanging the suite.
func collectMCPEvents(
    _ stream: AsyncStream<MCPIncomingEvent>, count: Int, timeout: TimeInterval = 5
) async -> [MCPIncomingEvent] {
    await withTaskGroup(of: [MCPIncomingEvent]?.self) { group in
        group.addTask {
            var collected: [MCPIncomingEvent] = []
            for await event in stream {
                collected.append(event)
                if collected.count >= count { break }
            }
            return collected
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}
