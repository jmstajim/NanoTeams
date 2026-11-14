import Foundation
import Network

@testable import NanoTeams

/// A real MCP server, in-process, on an ephemeral loopback port.
///
/// The scripted transport and the scripted session each cut the stack at a seam, which is
/// what makes them precise — and is also what they cannot test: that the whole path from
/// `MCPClient.call` through `URLSession`, a socket, an HTTP response and back actually fits
/// together. Everything between those seams is where a real client breaks: a header the
/// server rejects, a chunked SSE body, a connection closed mid-stream, a 202 with no body.
///
/// Binds port 0 and reports what the OS assigned, so parallel test hosts cannot collide.
final class FakeMCPHTTPServer: @unchecked Sendable {

    /// What kind of server this is pretending to be.
    ///
    /// Every mode but `.legacy` is a CONFORMING modern server as well: a request carrying the
    /// 2026-07-28 version header is checked the way such a server checks it
    /// (`ConformingMCPServerCheck`) — a missing required `_meta` key is answered `400` + `-32602`,
    /// a header that disagrees with its body `400` + `-32020` — before it is answered. A legacy
    /// request (`initialize` and what follows it) is not: these modes answer it as a dual-era
    /// server does.
    enum Mode: Sendable {
        /// 2026-07-28: answers `server/discover` with the spec's `DiscoverResult` — its identity
        /// under `_meta`, where the revision puts it — and keeps no sessions.
        case modern
        /// 2026-07-28 with push notifications: `server/discover` advertises `subscriptions` and
        /// `tools.listChanged: true`, and `POST subscriptions/listen` opens a long-lived SSE
        /// stream that `pushListChanged()` writes to.
        case modernPush
        /// 2025-11-25: refuses `server/discover`, answers `initialize`, hands out a session id.
        case legacy
        /// 2025-11-25 with strict `MCP-Protocol-Version` header validation on every POST,
        /// matching `modelcontextprotocol/go-sdk` v1.0.0 (`StreamableHTTPHandler.ServeHTTP`):
        /// before `initialize`, any present `MCP-Protocol-Version` outside the accepted legacy
        /// revisions is refused with HTTP `400` text (including `server/discover` carrying
        /// `2026-07-28`); after `initialize`, every POST must carry the negotiated revision.
        case legacyStrict
        /// Answers 200 with something that is not JSON at all.
        case garbage
        /// Accepts the request and never answers.
        case hang
        /// 401 with a challenge.
        case unauthorized
        /// Answers `tools/call` with an SSE stream: progress notifications, then the result.
        case streamingTool
        /// Answers `tools/call` with an SSE stream that sends an event carrying `id: call-evt-1`
        /// and then closes cleanly before the result; delivers the result on a follow-up `GET`
        /// carrying `Last-Event-ID: call-evt-1`.
        case resumableStreamTool
        /// Legacy (2025-11-25) counterpart of `.resumableStreamTool`: requires both
        /// `Last-Event-ID: call-evt-1` and `Mcp-Session-Id` on the resumption `GET`.
        case legacyResumableStreamTool
        /// Answers `tools/call` after `callDuration` over an SSE stream, reporting progress every
        /// `progressInterval` — but ONLY when the request supplied `_meta.progressToken`, and
        /// only under that token. What a spec-conforming server does: the Python and TS SDKs
        /// make `report_progress` a no-op for a request that named no token.
        case progressReportingTool
        /// Answers `tools/call` with an SSE stream that breaks off mid-body — one progress event,
        /// then the connection drops short of the declared length: what a crashing server or a
        /// proxy cutting the stream looks like on the wire.
        case brokenStreamTool
        /// The same for a single JSON reply: `tools/call` answered with part of the body its
        /// `Content-Length` promised, then the connection dropped.
        case brokenJSONTool
    }

    /// One request as the server saw it — the assertion surface for headers, which is where
    /// authorization and the session id actually live.
    struct Received: Sendable {
        let httpMethod: String
        let headers: [String: String]
        let body: String

        var rpcMethod: String? {
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["method"] as? String
        }

        var rpcID: Any? {
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["id"]
        }

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    let mode: Mode
    /// Set to answer the next request with 404 — the legacy "I forgot your session" path.
    var forgetsSession = false
    /// Tools the catalogue reports.
    var toolNames: [String] = ["get_metadata"]
    /// Optional per-tool description overrides (`name -> description`); defaults to `"Does <name>."`.
    var toolDescriptions: [String: String] {
        get { lock.withLock { descriptions } }
        set { lock.withLock { descriptions = newValue } }
    }
    /// Optional per-tool raw JSON annotations object (`name -> "{\"readOnlyHint\":true}"`).
    var toolAnnotations: [String: String] {
        get { lock.withLock { annotationsByTool } }
        set { lock.withLock { annotationsByTool = newValue } }
    }
    /// Static resources returned by `resources/list` and served by `resources/read`.
    var resources: [(uri: String, name: String, description: String, mimeType: String?, text: String)] {
        get { lock.withLock { resourceEntries } }
        set { lock.withLock { resourceEntries = newValue } }
    }
    /// URI templates returned by `resources/templates/list`.
    var resourceTemplates: [(uriTemplate: String, name: String, description: String, mimeType: String?)] {
        get { lock.withLock { resourceTemplateEntries } }
        set { lock.withLock { resourceTemplateEntries = newValue } }
    }
    /// Handler answering `resources/read` for template-expanded URIs.
    var resourceTemplateHandler: (@Sendable (String) -> (mimeType: String?, text: String)?)? {
        get { lock.withLock { templateReadHandler } }
        set { lock.withLock { templateReadHandler = newValue } }
    }
    /// Prompts returned by `prompts/list` and served by `prompts/get`.
    var prompts: [(
        name: String,
        description: String,
        arguments: [(name: String, description: String, required: Bool)],
        messages: [(role: String, text: String)]
    )] {
        get { lock.withLock { promptEntries } }
        set { lock.withLock { promptEntries = newValue } }
    }
    /// Number of open `subscriptions/listen` push streams.
    var pushSubscriberCount: Int { lock.withLock { pushStreams.count } }
    /// The `x-mcp-header` parameter each tool of this server declares on `id` (`Mcp-Param-Id`).
    static let defaultToolHeaderParameters: [ConformingMCPServerCheck.HeaderParameter] = [
        .init("id", header: "Mcp-Param-Id")
    ]
    /// Seconds before a plain `tools/call` is answered; `.infinity` never answers it.
    var toolCallDelay: TimeInterval {
        get { lock.withLock { callDelay } }
        set { lock.withLock { callDelay = newValue } }
    }
    /// `.streamingTool` only: seconds of silence between the progress notification and the
    /// result — a call that is working, not a server that is gone.
    var streamPause: TimeInterval {
        get { lock.withLock { pause } }
        set { lock.withLock { pause = newValue } }
    }
    /// Requests the CLIENT hung up on before they were answered — what a cancelled call looks
    /// like from the server's side.
    var abandonedRequests: Int { lock.withLock { abandoned } }
    /// `.progressReportingTool` only: how long a call works before it answers.
    var callDuration: TimeInterval {
        get { lock.withLock { duration } }
        set { lock.withLock { duration = newValue } }
    }
    /// `.progressReportingTool` only: seconds between two progress reports.
    var progressInterval: TimeInterval {
        get { lock.withLock { interval } }
        set { lock.withLock { interval = newValue } }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-mcp-http-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var seen: [Received] = []
    private var descriptions: [String: String] = [:]
    private var annotationsByTool: [String: String] = [:]
    private var resourceEntries: [(uri: String, name: String, description: String, mimeType: String?, text: String)] = []
    private var resourceTemplateEntries: [(uriTemplate: String, name: String, description: String, mimeType: String?)] = []
    private var templateReadHandler: (@Sendable (String) -> (mimeType: String?, text: String)?)?
    private var promptEntries: [(
        name: String,
        description: String,
        arguments: [(name: String, description: String, required: Bool)],
        messages: [(role: String, text: String)]
    )] = []
    private var pushStreams: [NWConnection] = []
    private var pendingResumableCallID: Any?
    private let sessionID = "sess-\(UUID().uuidString.prefix(8))"
    private var legacyInitialized = false
    private var callDelay: TimeInterval = 0
    private var pause: TimeInterval = 0
    private var abandoned = 0
    private var duration: TimeInterval = 7
    private var interval: TimeInterval = 1

    var requests: [Received] { lock.withLock { seen } }
    var issuedSessionID: String { sessionID }

    init(mode: Mode) throws {
        self.mode = mode
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = FakeServerOneShot()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port?.rawValue else { return }
                    resumed.fire { continuation.resume(returning: port) }
                case .failed(let error):
                    resumed.fire { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            connections.forEach { $0.cancel() }
            connections = []
            pushStreams.removeAll()
        }
    }

    /// Emits `notifications/tools_list_changed` on every open `subscriptions/listen` stream.
    func pushListChanged(method: String = "notifications/tools_list_changed") {
        let payload = Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"\(method)\"}\n\n".utf8)
        let subscribers = lock.withLock { pushStreams }
        for subscriber in subscribers {
            send(payload, on: subscriber, thenClose: false)
        }
    }

    deinit { listener.cancel() }

    func url(port: UInt16) -> String { "http://127.0.0.1:\(port)/mcp" }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    /// Reads until the headers and the declared body have both arrived. A single `receive`
    /// is not enough: URLSession is free to split a POST across segments, and a server that
    /// answered the first fragment would answer a truncated request.
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let request = Self.parse(buffer) else {
                if isComplete { return }
                self.read(connection, buffer: buffer)
                return
            }
            self.lock.withLock { self.seen.append(request) }
            self.respond(to: request, on: connection)
        }
    }

    private static func parse(_ buffer: Data) -> Received? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let declared = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[separator.upperBound...]
        guard body.count >= declared else { return nil }
        return Received(
            httpMethod: requestLine.components(separatedBy: " ").first ?? "",
            headers: headers,
            body: String(decoding: body.prefix(declared), as: UTF8.self))
    }

    // MARK: - Answers

    private func respond(to request: Received, on connection: NWConnection) {
        if case .hang = mode { return }
        if case .unauthorized = mode {
            return write(status: 401,
                         headers: ["WWW-Authenticate": "Bearer realm=\"mcp\"", "Content-Type": "text/plain"],
                         body: "unauthorized", on: connection)
        }
        if lock.withLock({ forgetsSession }), request.header("mcp-session-id") != nil {
            return write(status: 404, headers: ["Content-Type": "text/plain"], body: "no session", on: connection)
        }
        if case .garbage = mode {
            return write(status: 200, headers: ["Content-Type": "application/json"],
                         body: "this is not JSON", on: connection)
        }
        if request.httpMethod == "GET",
           mode == .resumableStreamTool || mode == .legacyResumableStreamTool,
           request.header(MCPConstants.lastEventIDHeader) == "call-evt-1" {
            if mode == .legacyResumableStreamTool,
               request.header("mcp-session-id") != sessionID {
                return write(status: 400, headers: ["Content-Type": "text/plain"],
                             body: "missing or mismatched Mcp-Session-Id", on: connection)
            }
            let id = lock.withLock { pendingResumableCallID }
            let body = "data: {\"jsonrpc\":\"2.0\",\"id\":\(Self.idLiteral(id)),"
                + "\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"resumed\"}]}}\n\n"
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
            return send(Data((head + body).utf8), on: connection, thenClose: true)
        }
        guard request.httpMethod == "POST" else {
            // The legacy GET push channel: this server offers none, and 405 is how a real one
            // says so.
            return write(status: 405, headers: [:], body: "", on: connection)
        }
        if mode == .legacyStrict {
            let initialized = lock.withLock { legacyInitialized }
            if !initialized {
                if let version = request.header(MCPConstants.protocolVersionHeader),
                   !MCPConstants.acceptedLegacyProtocolVersions.contains(version) {
                    return write(status: 400, headers: ["Content-Type": "text/plain"],
                                 body: "invalid protocol version: \(version)", on: connection)
                }
                if request.header("Mcp-Method") != nil {
                    return write(status: 400, headers: ["Content-Type": "text/plain"],
                                 body: "unexpected Mcp-Method header on legacy server", on: connection)
                }
            } else if request.header(MCPConstants.protocolVersionHeader) != MCPConstants.legacyProtocolVersion {
                return write(status: 400, headers: ["Content-Type": "text/plain"],
                             body: "missing or invalid protocol version", on: connection)
            }
        }
        let isLegacyMode = mode == .legacy || mode == .legacyStrict || mode == .legacyResumableStreamTool
        if !isLegacyMode,
           let refusal = ConformingMCPServerCheck.refusal(
               header: request.header,
               body: Data(request.body.utf8),
               toolHeaderParameters: lock.withLock {
                   Dictionary(uniqueKeysWithValues: toolNames.map { ($0, Self.defaultToolHeaderParameters) })
               }) {
            return write(status: refusal.status, headers: ["Content-Type": "application/json"],
                         body: refusal.body(answering: request.rpcID), on: connection)
        }
        guard let method = request.rpcMethod else {
            return write(status: 202, headers: [:], body: "", on: connection)
        }
        answer(method: method, request: request, on: connection)
    }

    private func answer(method: String, request: Received, on connection: NWConnection) {
        let id = request.rpcID
        let isLegacyMode = mode == .legacy || mode == .legacyStrict || mode == .legacyResumableStreamTool
        switch method {
        case MCPWire.discoverMethod where isLegacyMode:
            write(jsonrpcError: id, code: MCPErrorCode.methodNotFound, message: "unknown method", on: connection)
        case MCPWire.discoverMethod where mode == .modernPush:
            let extraCaps = extraCapabilitiesJSON()
            write(jsonrpcResult: id, result: """
            {"resultType":"complete","supportedVersions":["2026-07-28"],\
            "capabilities":{"tools":{"listChanged":true},"subscriptions":{}\(extraCaps)},\
            "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"fake","version":"1.0"}}}
            """, on: connection)
        case MCPWire.discoverMethod:
            // The 2026-07-28 `DiscoverResult`, spelled as server/discover spells it.
            let extraCaps = extraCapabilitiesJSON()
            write(jsonrpcResult: id, result: """
            {"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}\(extraCaps)},\
            "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"fake","version":"1.0"}}}
            """, on: connection)
        case MCPWire.subscriptionsListenMethod where mode == .modernPush:
            guard let notifications = Self.requestParamObject("notifications", in: request),
                  notifications["toolsListChanged"] as? Bool == true else {
                write(status: 400, headers: ["Content-Type": "application/json"],
                      body: """
                      {"jsonrpc":"2.0","id":\(Self.idLiteral(id)),"error":{"code":-32602,"message":"Invalid request parameters"}}
                      """,
                      on: connection)
                return
            }
            lock.withLock { pushStreams.append(connection) }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n: subscribed\n\n"
            send(Data(head.utf8), on: connection, thenClose: false)
        case MCPWire.initializeMethod:
            lock.withLock { legacyInitialized = true }
            let extraCaps = extraCapabilitiesJSON(leadingComma: false)
            write(jsonrpcResult: id, result: """
            {"protocolVersion":"\(MCPConstants.legacyProtocolVersion)","capabilities":{\(extraCaps)},\
            "serverInfo":{"name":"fake-legacy","version":"1.0"}}
            """, headers: ["Mcp-Session-Id": sessionID], on: connection)
        case MCPWire.resourcesListMethod:
            let items = lock.withLock { resourceEntries }.map { entry -> String in
                let mimeClause = entry.mimeType.map { ",\"mimeType\":\(Self.jsonString($0))" } ?? ""
                return """
                {"uri":\(Self.jsonString(entry.uri)),"name":\(Self.jsonString(entry.name)),\
                "description":\(Self.jsonString(entry.description))\(mimeClause)}
                """
            }.joined(separator: ",")
            write(jsonrpcResult: id, result: "{\"resources\":[\(items)]}", on: connection)
        case MCPWire.resourceTemplatesListMethod:
            let items = lock.withLock { resourceTemplateEntries }.map { entry -> String in
                let mimeClause = entry.mimeType.map { ",\"mimeType\":\(Self.jsonString($0))" } ?? ""
                return """
                {"uriTemplate":\(Self.jsonString(entry.uriTemplate)),"name":\(Self.jsonString(entry.name)),\
                "description":\(Self.jsonString(entry.description))\(mimeClause)}
                """
            }.joined(separator: ",")
            write(jsonrpcResult: id, result: "{\"resourceTemplates\":[\(items)]}", on: connection)
        case MCPWire.resourcesReadMethod:
            let uri = Self.requestParamString("uri", in: request) ?? ""
            let (staticEntries, handler) = lock.withLock {
                (resourceEntries, templateReadHandler)
            }
            if let found = staticEntries.first(where: { $0.uri == uri }) {
                let mimeClause = found.mimeType.map { ",\"mimeType\":\(Self.jsonString($0))" } ?? ""
                let result = """
                {"contents":[{"uri":\(Self.jsonString(found.uri))\(mimeClause),"text":\(Self.jsonString(found.text))}]}
                """
                write(jsonrpcResult: id, result: result, on: connection)
            } else if let resolved = handler?(uri) {
                let mimeClause = resolved.mimeType.map { ",\"mimeType\":\(Self.jsonString($0))" } ?? ""
                let result = """
                {"contents":[{"uri":\(Self.jsonString(uri))\(mimeClause),"text":\(Self.jsonString(resolved.text))}]}
                """
                write(jsonrpcResult: id, result: result, on: connection)
            } else {
                write(jsonrpcError: id, code: MCPErrorCode.invalidParams, message: "Resource not found: \(uri)", on: connection)
            }
        case MCPWire.promptsListMethod:
            let items = lock.withLock { promptEntries }.map { entry -> String in
                let args = entry.arguments.map { arg in
                    """
                    {"name":\(Self.jsonString(arg.name)),"description":\(Self.jsonString(arg.description)),\
                    "required":\(arg.required ? "true" : "false")}
                    """
                }.joined(separator: ",")
                return """
                {"name":\(Self.jsonString(entry.name)),"description":\(Self.jsonString(entry.description)),\
                "arguments":[\(args)]}
                """
            }.joined(separator: ",")
            write(jsonrpcResult: id, result: "{\"prompts\":[\(items)]}", on: connection)
        case MCPWire.promptsGetMethod:
            let name = Self.requestParamString("name", in: request) ?? ""
            let entries = lock.withLock { promptEntries }
            guard let found = entries.first(where: { $0.name == name }) else {
                write(jsonrpcError: id, code: MCPErrorCode.invalidParams, message: "Prompt not found: \(name)", on: connection)
                return
            }
            let msgs = found.messages.map { msg in
                """
                {"role":\(Self.jsonString(msg.role)),"content":{"type":"text","text":\(Self.jsonString(msg.text))}}
                """
            }.joined(separator: ",")
            let result = """
            {"description":\(Self.jsonString(found.description)),"messages":[\(msgs)]}
            """
            write(jsonrpcResult: id, result: result, on: connection)
        case MCPWire.toolsListMethod:
            let (names, customDescriptions, customAnnotations) = lock.withLock {
                (toolNames, descriptions, annotationsByTool)
            }
            let tools = names.map { name in
                let desc = customDescriptions[name] ?? "Does \(name)."
                let annClause = customAnnotations[name].map { ",\"annotations\":\($0)" } ?? ""
                return """
                {"name":"\(name)","description":"\(desc)",\
                "inputSchema":{"type":"object","properties":{"id":{"type":"string","x-mcp-header":"Id"}}}\(annClause)}
                """
            }.joined(separator: ",")
            write(jsonrpcResult: id, result: "{\"tools\":[\(tools)]}", on: connection)
        case MCPWire.toolsCallMethod where mode == .streamingTool:
            writeStreamingCall(id: id, on: connection)
        case MCPWire.toolsCallMethod where mode == .resumableStreamTool || mode == .legacyResumableStreamTool:
            lock.withLock { pendingResumableCallID = id }
            let idText = Self.idLiteral(id)
            let progress = """
            id: call-evt-1
            event: message
            data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":\(idText),"progress":0.5}}
            
            
            """
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
            send(Data((head + progress).utf8), on: connection, thenClose: true)
        case MCPWire.toolsCallMethod where mode == .brokenStreamTool:
            writeBrokenCall(id: id, on: connection)
        case MCPWire.toolsCallMethod where mode == .brokenJSONTool:
            let body = "{\"jsonrpc\":\"2.0\",\"id\":\(Self.idLiteral(id)),\"result\":{\"content\":["
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count + 4096)\r\n\r\n"
            send(Data((head + body).utf8), on: connection, thenClose: false)
            queue.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
        case MCPWire.toolsCallMethod where mode == .progressReportingTool:
            writeReportingCall(id: id, progressToken: Self.progressToken(in: request), on: connection)
        case MCPWire.toolsCallMethod:
            let answer = { [weak self] in
                self?.write(jsonrpcResult: id, result: """
                {"content":[{"type":"text","text":"called"}]}
                """, on: connection)
            }
            let delay = toolCallDelay
            if delay == 0 {
                answer()
            } else if delay.isInfinite {
                watchForHangUp(connection)
            } else {
                queue.asyncAfter(deadline: .now() + delay) { answer() }
            }
        default:
            // A notification carries no id; a real server answers 202 and says nothing.
            if id == nil {
                write(status: 202, headers: [:], body: "", on: connection)
            } else {
                write(jsonrpcError: id, code: MCPErrorCode.methodNotFound, message: "unknown method",
                      on: connection)
            }
        }
    }

    /// Waits for the client to close a request this server is never going to answer.
    private func watchForHangUp(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.lock.withLock { self.abandoned += 1 }
            } else {
                self.watchForHangUp(connection)
            }
        }
    }

    /// Progress notifications, then the result — the shape a POST answers with when the call
    /// takes a while, and the one a single JSON reply cannot express.
    private func writeStreamingCall(id: Any?, on connection: NWConnection) {
        let idText = Self.idLiteral(id)
        let progress = """
        event: message
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":\(idText),"progress":0.5}}
        
        
        """
        let result = """
        data: {"jsonrpc":"2.0","id":\(idText),"result":{"content":[{"type":"text","text":"streamed"}]}}
        
        
        """
        // No Content-Length: the body ends when the connection does, which is what a real SSE
        // response looks like to URLSession.
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        let pause = streamPause
        guard pause > 0 else {
            return send(Data((head + progress + result).utf8), on: connection, thenClose: true)
        }
        send(Data((head + progress).utf8), on: connection, thenClose: false)
        queue.asyncAfter(deadline: .now() + pause) { [weak self] in
            self?.send(Data(result.utf8), on: connection, thenClose: true)
        }
    }

    /// A long call over SSE: a progress report every `progressInterval` under the request's own
    /// token — none at all without one — and the result after `callDuration`.
    private func writeReportingCall(id: Any?, progressToken: Any?, on connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        send(Data(head.utf8), on: connection, thenClose: false)
        let duration = callDuration
        let interval = progressInterval
        if let progressToken, interval > 0 {
            let token = Self.idLiteral(progressToken)
            var at = interval
            while at < duration {
                let report = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\","
                    + "\"params\":{\"progressToken\":\(token),\"progress\":\(at)}}\n\n"
                queue.asyncAfter(deadline: .now() + at) { [weak self] in
                    self?.send(Data(report.utf8), on: connection, thenClose: false)
                }
                at += interval
            }
        }
        let result = "data: {\"jsonrpc\":\"2.0\",\"id\":\(Self.idLiteral(id)),"
            + "\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"reported\"}]}}\n\n"
        queue.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.send(Data(result.utf8), on: connection, thenClose: true)
        }
    }

    /// An SSE body cut off short of the length its header declared: the HTTP layer reports the
    /// body as broken rather than finished.
    private func writeBrokenCall(id: Any?, on connection: NWConnection) {
        let event = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\","
            + "\"params\":{\"progressToken\":\(Self.idLiteral(id)),\"progress\":0.1}}\n\n"
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
            + "Content-Length: \(event.utf8.count + 4096)\r\n\r\n"
        send(Data((head + event).utf8), on: connection, thenClose: false)
        queue.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
    }

    /// `params._meta.progressToken`, as the request spelled it.
    private static func progressToken(in request: Received) -> Any? {
        guard let data = request.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? [String: Any],
              let meta = params["_meta"] as? [String: Any] else { return nil }
        return meta["progressToken"]
    }

    private static func requestParamString(_ key: String, in request: Received) -> String? {
        guard let data = request.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? [String: Any] else { return nil }
        return params[key] as? String
    }

    private static func requestParamObject(_ key: String, in request: Received) -> [String: Any]? {
        guard let data = request.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? [String: Any] else { return nil }
        return params[key] as? [String: Any]
    }

    private func extraCapabilitiesJSON(leadingComma: Bool = true) -> String {
        let (hasResources, hasPrompts) = lock.withLock {
            (!resourceEntries.isEmpty || !resourceTemplateEntries.isEmpty, !promptEntries.isEmpty)
        }
        var clauses: [String] = []
        if hasResources { clauses.append("\"resources\":{\"listChanged\":true}") }
        if hasPrompts { clauses.append("\"prompts\":{\"listChanged\":true}") }
        guard !clauses.isEmpty else { return "" }
        return (leadingComma ? "," : "") + clauses.joined(separator: ",")
    }

    private static func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private func write(jsonrpcResult id: Any?, result: String, headers: [String: String] = [:],
                       on connection: NWConnection) {
        write(status: 200, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a },
              body: "{\"jsonrpc\":\"2.0\",\"id\":\(Self.idLiteral(id)),\"result\":\(result)}",
              on: connection)
    }

    private func write(jsonrpcError id: Any?, code: Int, message: String, on connection: NWConnection) {
        write(status: 200, headers: ["Content-Type": "application/json"],
              body: """
              {"jsonrpc":"2.0","id":\(Self.idLiteral(id)),"error":{"code":\(code),"message":"\(message)"}}
              """,
              on: connection)
    }

    private static func idLiteral(_ id: Any?) -> String {
        switch id {
        case let number as Int: return String(number)
        case let text as String: return "\"\(text)\""
        default: return "null"
        }
    }

    private func write(status: Int, headers: [String: String], body: String, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        send(Data((head + body).utf8), on: connection, thenClose: true)
    }

    private func send(_ data: Data, on connection: NWConnection, thenClose: Bool) {
        connection.send(content: data, completion: .contentProcessed { _ in
            if thenClose { connection.cancel() }
        })
    }
}

/// A continuation may be resumed exactly once, and `stateUpdateHandler` fires repeatedly.
private final class FakeServerOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire(_ body: () -> Void) {
        let alreadyFired = lock.withLock {
            let was = fired
            fired = true
            return was
        }
        guard !alreadyFired else { return }
        body()
    }
}
