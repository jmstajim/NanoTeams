import AppKit
import Darwin
import Foundation
import XCTest

@testable import NanoTeams

final class HostedMCPStdioRelayTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostedMCPStdioRelayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Test Doubles

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrText = ""

        func appendStdout(_ data: Data) {
            lock.lock()
            stdoutData.append(data)
            lock.unlock()
        }

        func appendStderr(_ text: String) {
            lock.lock()
            stderrText.append(text)
            lock.unlock()
        }

        func stdoutLines() -> [String] {
            lock.lock()
            let text = String(decoding: stdoutData, as: UTF8.self)
            lock.unlock()
            return text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }

        func stderrContents() -> String {
            lock.lock()
            defer { lock.unlock() }
            return stderrText
        }
    }

    private final class SpyAppOpener: HostedMCPAppOpening, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var openCallCount = 0
        private(set) var recordedActivatesFlags: [Bool] = []
        private let onOpen: (@Sendable () async throws -> Void)?

        init(onOpen: (@Sendable () async throws -> Void)? = nil) {
            self.onOpen = onOpen
        }

        func openApplication(activates: Bool) async throws {
            lock.withLock {
                openCallCount += 1
                recordedActivatesFlags.append(activates)
            }
            try await onOpen?()
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false

        var value: Bool { lock.withLock { isSet } }

        func set() { lock.withLock { isSet = true } }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    private final class LockedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        var all: [String] { lock.withLock { entries } }

        func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    }

    /// How the `/identify` poll after an auto-open ends, in the tests that pin it stops early.
    private enum IdentifyPoll: CaseIterable, Sendable {
        case agentNotRegistered
        case cancelled
        case keychainUnavailableThenSleepCancelled
    }

    /// In-process HTTP client that routes `/identify` and `POST /mcp` directly through
    /// `HostedMCPAgentStore` and `HostedMCPDispatcher`, recording every request header and
    /// supporting simulated connection-refused states, custom `/identify` overrides, and
    /// modern stream-close cancellation.
    private final class InProcessStdioHTTPClient: HostedMCPStdioHTTPClient, @unchecked Sendable {
        struct RecordedPost: Sendable {
            let port: UInt16
            let headers: [String: String]
            let body: Data
        }

        private let lock = NSLock()
        private let agentStore: HostedMCPAgentStore
        private let dispatcher: HostedMCPDispatcher
        var isServerReachable: Bool
        var identifyOverride: (@Sendable (UInt16, String, String) throws -> (Int, Data))?
        var postOverride: (@Sendable (UInt16, [(String, String)], Data, @escaping @Sendable (Data) async -> Void) async throws -> HostedMCPStdioHTTPResponse)?
        private(set) var identifyCallCount = 0
        private(set) var recordedPosts: [RecordedPost] = []
        private(set) var cancelledStreamPostCount = 0

        init(
            agentStore: HostedMCPAgentStore,
            dispatcher: HostedMCPDispatcher,
            isServerReachable: Bool = true
        ) {
            self.agentStore = agentStore
            self.dispatcher = dispatcher
            self.isServerReachable = isServerReachable
        }

        func getIdentify(
            port: UInt16,
            shortID: String,
            nonceHex: String
        ) async throws -> (statusCode: Int, body: Data) {
            let (reachable, override) = lock.withLock {
                identifyCallCount += 1
                return (isServerReachable, identifyOverride)
            }

            guard reachable else {
                throw HostedMCPStdioHTTPError.connectionRefused
            }
            if let override {
                return try override(port, shortID, nonceHex)
            }
            switch agentStore.identify(shortID: shortID, nonceHex: nonceHex) {
            case .success(let payload):
                let body = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
                return (200, body)
            case .invalidNonce:
                return (400, Data())
            case .agentNotFound:
                return (404, Data())
            case .storageFailure:
                return (503, Data())
            }
        }

        func postMCP(
            port: UInt16,
            headers: [(String, String)],
            body: Data,
            onSSEFrame: @escaping @Sendable (Data) async -> Void
        ) async throws -> HostedMCPStdioHTTPResponse {
            var headerMap: [String: String] = ["host": "127.0.0.1:\(port)", "content-type": "application/json"]
            for (k, v) in headers {
                headerMap[k.lowercased()] = v
            }

            let (reachable, customPostOverride) = lock.withLock {
                if isServerReachable {
                    recordedPosts.append(RecordedPost(port: port, headers: headerMap, body: body))
                }
                return (isServerReachable, postOverride)
            }

            guard reachable else {
                throw HostedMCPStdioHTTPError.connectionRefused
            }
            if let customPostOverride {
                return try await customPostOverride(port, headers, body, onSSEFrame)
            }

            guard let auth = headerMap["authorization"],
                  auth.lowercased().hasPrefix("bearer ")
            else {
                return HostedMCPStdioHTTPResponse(statusCode: 401, headers: [:], body: Data(), wasStreamedSSE: false)
            }
            let rawToken = String(auth.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
            let agent: AgentIdentity
            switch agentStore.verifyBearerToken(rawToken) {
            case .authenticated(let verified):
                agent = verified
            case .invalidToken:
                return HostedMCPStdioHTTPResponse(statusCode: 401, headers: [:], body: Data(), wasStreamedSSE: false)
            case .storageFailure:
                return HostedMCPStdioHTTPResponse(statusCode: 503, headers: [:], body: Data(), wasStreamedSSE: false)
            }

            let httpReq = HostedMCPHTTPRequest(
                head: HostedMCPHTTPRequestHead(
                    method: "POST",
                    rawTarget: "/mcp",
                    version: "HTTP/1.1",
                    headers: headerMap
                ),
                body: body
            )

            let sseParserBox = LockedSSEParser()
            let outcome = await withTaskCancellationHandler {
                await dispatcher.dispatch(
                    request: httpReq,
                    agent: agent,
                    onSSEHead: { _ in },
                    onSSEChunk: { chunk in
                        let frames = sseParserBox.feed(chunk)
                        for frame in frames {
                            await onSSEFrame(frame)
                        }
                    }
                )
            } onCancel: {
                self.lock.withLock {
                    self.cancelledStreamPostCount += 1
                }
            }

            if Task.isCancelled {
                throw HostedMCPStdioHTTPError.cancelled
            }

            switch outcome {
            case .httpResponse(let resp):
                var respHeaders: [String: String] = [:]
                for (k, v) in resp.headers {
                    respHeaders[k.lowercased()] = v
                }
                return HostedMCPStdioHTTPResponse(
                    statusCode: resp.statusCode,
                    headers: respHeaders,
                    body: resp.body,
                    wasStreamedSSE: false
                )
            case .sse:
                for frame in sseParserBox.finish() {
                    await onSSEFrame(frame)
                }
                return HostedMCPStdioHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "text/event-stream"],
                    body: Data(),
                    wasStreamedSSE: true
                )
            }
        }
    }

    private final class LockedSSEParser: @unchecked Sendable {
        private let lock = NSLock()
        private var parser = SSEFrameParser()
        private var pendingBytes = Data()

        func feed(_ data: Data) -> [Data] {
            lock.withLock {
                pendingBytes.append(data)
                var results: [Data] = []
                while let nlIndex = pendingBytes.firstIndex(of: 0x0A) {
                    let lineData = pendingBytes[pendingBytes.startIndex..<nlIndex]
                    pendingBytes.removeSubrange(pendingBytes.startIndex...nlIndex)
                    let line = String(data: lineData, encoding: .utf8) ?? ""
                    if let event = try? parser.consume(line: line) {
                        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            results.append(Data(trimmed.utf8))
                        }
                    }
                }
                return results
            }
        }

        func finish() -> [Data] {
            lock.withLock {
                var results: [Data] = []
                if !pendingBytes.isEmpty {
                    let line = String(data: pendingBytes, encoding: .utf8) ?? ""
                    pendingBytes.removeAll()
                    if let event = try? parser.consume(line: line) {
                        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            results.append(Data(trimmed.utf8))
                        }
                    }
                }
                if let event = parser.finish() {
                    let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        results.append(Data(trimmed.utf8))
                    }
                }
                return results
            }
        }
    }

    // MARK: - Helpers

    private static let missingTokenMessage = HostedMCPStdioRelay.missingTokenMessage

    private struct ErrorLine: Equatable {
        let id: JSONRPCID?
        let code: Int
        let message: String
    }

    /// A stdout line read as a JSON-RPC error reply, or `nil` when it is anything else.
    private func errorLine(_ line: String) -> ErrorLine? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["jsonrpc"] as? String == "2.0",
              let error = object["error"] as? [String: Any],
              let code = error["code"] as? Int,
              let message = error["message"] as? String
        else {
            return nil
        }
        let id: JSONRPCID? = switch object["id"] {
        case let number as Int: .number(number)
        case let string as String: .string(string)
        default: nil
        }
        return ErrorLine(id: id, code: code, message: message)
    }

    private func stdinStream(_ lines: [String], trailingNewline: Bool = true) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        continuation.yield(Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8))
        continuation.finish()
        return stream
    }

    private func makeAgentStore(label: String) throws -> (store: HostedMCPAgentStore, token: String, shortID: String) {
        let store = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try store.createAgent(label: label)
        let shortID = try XCTUnwrap(HostedMCPStdioRelay.parseBearerToken(issued.token)?.shortID)
        return (store, issued.token, shortID)
    }

    private func makeEchoDispatcher() -> HostedMCPDispatcher {
        HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )
    }

    /// Serves `URLSessionHostedMCPStdioHTTPClient` from a script instead of a socket: the client's
    /// own `URLSession` path runs — status, content type, the byte loop, error mapping — and no
    /// connection is ever opened, so nothing here can reach a server that happens to be
    /// listening. Scripts are keyed by the request's port, so each test names its own.
    ///
    /// There is no failing ending on purpose: `URLSession` drops the body bytes it has not yet
    /// handed to the iterator when the failure arrives in the same turn (measured 2026-11-07: 0 of
    /// 58 bytes), which a real connection that fails after sending its bytes does not do. A body
    /// that fails after its bytes is `ScriptedEventStreamClient`'s job.
    private final class ScriptedLoopbackProtocol: URLProtocol, @unchecked Sendable {

        enum Ending: Sendable {
            case finish
            /// Leaves the body open until the client cancels the task.
            case hold
        }

        struct Reply: Sendable {
            var statusCode = 200
            var contentType = "text/event-stream"
            var chunks: [String] = []
            var ending: Ending = .finish
        }

        typealias Route = @Sendable (URLRequest) -> Reply

        private final class Registry: @unchecked Sendable {
            private let lock = NSLock()
            private var routes: [Int: Route] = [:]
            private var served: [Int: [URLRequest]] = [:]

            func install(_ route: @escaping Route, port: Int) {
                lock.withLock {
                    routes[port] = route
                    served[port] = []
                }
            }

            func uninstall(port: Int) {
                lock.withLock {
                    routes[port] = nil
                    served[port] = nil
                }
            }

            func serve(_ request: URLRequest, port: Int) -> Route? {
                lock.withLock {
                    served[port, default: []].append(request)
                    return routes[port]
                }
            }

            func requests(port: Int) -> [URLRequest] {
                lock.withLock { served[port] ?? [] }
            }
        }

        private static let registry = Registry()

        static func install(port: UInt16, route: @escaping Route) {
            registry.install(route, port: Int(port))
        }

        static func uninstall(port: UInt16) {
            registry.uninstall(port: Int(port))
        }

        static func requests(port: UInt16) -> [URLRequest] {
            registry.requests(port: Int(port))
        }

        /// The production configuration with this protocol in front of every request.
        static func makeClient() -> URLSessionHostedMCPStdioHTTPClient {
            let configuration = URLSessionHostedMCPStdioHTTPClient.makeSessionConfiguration()
            configuration.protocolClasses = [ScriptedLoopbackProtocol.self]
            return URLSessionHostedMCPStdioHTTPClient(session: URLSession(configuration: configuration))
        }

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let port = request.url?.port ?? -1
            guard let route = Self.registry.serve(request, port: port), let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let reply = route(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: reply.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.contentType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in reply.chunks {
                client?.urlProtocol(self, didLoad: Data(chunk.utf8))
            }
            switch reply.ending {
            case .finish:
                client?.urlProtocolDidFinishLoading(self)
            case .hold:
                break
            }
        }

        override func stopLoading() {}
    }

    /// `postMCP` with the socket replaced by a scripted byte stream: the event-stream body goes
    /// through the production `relayEventStream`, and its failure through `mapError`, as
    /// `URLSessionHostedMCPStdioHTTPClient.postMCP` sends them. Unlike a `URLProtocol`, it can fail
    /// the body after every byte was read. `/identify` is answered from the agent store.
    private struct ScriptedEventStreamClient: HostedMCPStdioHTTPClient {
        let agentStore: HostedMCPAgentStore
        let replyBody: String
        let failure: URLError.Code?

        func getIdentify(port: UInt16, shortID: String, nonceHex: String) async throws -> (statusCode: Int, body: Data) {
            guard case .success(let payload) = agentStore.identify(shortID: shortID, nonceHex: nonceHex) else {
                return (404, Data())
            }
            return (200, try JSONEncoder().encode(payload))
        }

        func postMCP(
            port: UInt16,
            headers: [(String, String)],
            body: Data,
            onSSEFrame: @escaping @Sendable (Data) async -> Void
        ) async throws -> HostedMCPStdioHTTPResponse {
            let (bytes, continuation) = AsyncThrowingStream.makeStream(of: UInt8.self)
            for byte in replyBody.utf8 {
                continuation.yield(byte)
            }
            continuation.finish(throwing: failure.map { URLError($0) })
            do {
                try await URLSessionHostedMCPStdioHTTPClient.relayEventStream(bytes, onSSEFrame: onSSEFrame)
            } catch {
                throw URLSessionHostedMCPStdioHTTPClient.mapError(error)
            }
            return HostedMCPStdioHTTPResponse(
                statusCode: 200, headers: ["content-type": "text/event-stream"], body: Data(), wasStreamedSSE: true)
        }
    }

    /// Runs one modern `tools/call` with `id` through a relay whose POST reply is `replyBody`,
    /// ending in `failure` after every byte was read.
    private func relayOverScriptedEventStream(id: Int, replyBody: String, failure: URLError.Code) async throws -> OutputCollector {
        let (agentStore, token, _) = try makeAgentStore(label: "Scripted Stream Agent \(id)")
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: 48_440, rawToken: token),
            httpClient: ScriptedEventStreamClient(agentStore: agentStore, replyBody: replyBody, failure: failure),
            appOpener: SpyAppOpener(),
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        let call = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":40},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"progressToken":"p-\#(id)"}}}"#
        await relay.run(stdinChunks: stdinStream([call]))
        return collector
    }

    /// Answers `/identify` the way the listener does — from the agent store, so the proof is real
    /// and the relay goes on to send the Bearer token — and hands every other request to `mcp`.
    private func identifyingRoute(
        _ agentStore: HostedMCPAgentStore,
        mcp: @escaping ScriptedLoopbackProtocol.Route
    ) -> ScriptedLoopbackProtocol.Route {
        { request in
            guard request.url?.path == HostedMCPConstants.identifyPath else {
                return mcp(request)
            }
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            let shortID = items.first { $0.name == "agent" }?.value ?? ""
            let nonce = items.first { $0.name == "nonce" }?.value ?? ""
            guard case .success(let payload) = agentStore.identify(shortID: shortID, nonceHex: nonce),
                  let body = try? JSONEncoder().encode(payload)
            else {
                return .init(statusCode: 404, contentType: "application/json", chunks: [], ending: .finish)
            }
            return .init(statusCode: 200, contentType: "application/json", chunks: [String(decoding: body, as: UTF8.self)])
        }
    }

    /// Runs one modern `tools/call` with `id` through a relay whose HTTP client is the production
    /// `URLSessionHostedMCPStdioHTTPClient`, served `reply` for its POST.
    private func relayOverScriptedSession(
        port: UInt16,
        id: Int,
        reply: ScriptedLoopbackProtocol.Reply
    ) async throws -> OutputCollector {
        let (agentStore, token, _) = try makeAgentStore(label: "Scripted SSE Agent \(id)")
        ScriptedLoopbackProtocol.install(port: port, route: identifyingRoute(agentStore) { _ in reply })
        defer { ScriptedLoopbackProtocol.uninstall(port: port) }

        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: port, rawToken: token),
            httpClient: ScriptedLoopbackProtocol.makeClient(),
            appOpener: SpyAppOpener(),
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        let call = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":40},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"progressToken":"p-\#(id)"}}}"#
        await relay.run(stdinChunks: stdinStream([call]))
        return collector
    }

    private static func progressFrame(_ id: Int) -> String {
        #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"p-\#(id)","progress":1}}"#
    }

    private static func resultFrame(_ id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"done"}],"isError":false}}"#
    }

    // MARK: - 1. Launch Decision & JSONRPCLineFramer (§7.4, Ш23)

    @MainActor
    func testLaunchDecisionFunctionResolvesAppVsMCPStdioAndPortPriority() async {
        // 1. Normal app launch (no --mcp-stdio) -> .app
        let normalMode = NanoTeamsLauncher.resolveLaunchMode(
            arguments: ["/Applications/NanoTeams.app/Contents/MacOS/NanoTeams"],
            environment: ["NANOTEAMS_TOKEN": "ntm_abcd1234_secret"],
            configuredPort: 48000
        )
        XCTAssertEqual(normalMode, .app)

        // 2. XCTest host launch (-XCTest ...) -> .app
        let xctestMode = NanoTeamsLauncher.resolveLaunchMode(
            arguments: ["/Applications/NanoTeams.app/Contents/MacOS/NanoTeams", "-NSTreatUnknownArgumentsAsOpen", "NO"],
            environment: [:],
            configuredPort: nil
        )
        XCTAssertEqual(xctestMode, .app)

        // 3. --mcp-stdio with default port
        let defaultStdio = NanoTeamsLauncher.resolveLaunchMode(
            arguments: ["/Applications/NanoTeams.app/Contents/MacOS/NanoTeams", "--mcp-stdio"],
            environment: ["NANOTEAMS_TOKEN": "ntm_abcd1234_secret"],
            configuredPort: nil
        )
        XCTAssertEqual(
            defaultStdio,
            .mcpStdio(port: HostedMCPConstants.defaultPort, token: nil),
            "NANOTEAMS_TOKEN is never read: the token comes from --token-file only (#375)"
        )

        // 4. Configured port -> overridden by NANOTEAMS_MCP_PORT -> overridden by --port <N> and --port=<N>
        let configuredStdio = NanoTeamsLauncher.resolveLaunchMode(
            arguments: ["NanoTeams", "--mcp-stdio"],
            environment: [:],
            configuredPort: 49111
        )
        XCTAssertEqual(configuredStdio, .mcpStdio(port: 49111, token: nil))

        let envStdio = NanoTeamsLauncher.resolveLaunchMode(
            arguments: ["NanoTeams", "--mcp-stdio"],
            environment: ["NANOTEAMS_MCP_PORT": "50222"],
            configuredPort: 49111
        )
        XCTAssertEqual(envStdio, .mcpStdio(port: 50222, token: nil))

        let cliFlagStdio = NanoTeamsLauncher.resolveLaunchMode(
            arguments: ["NanoTeams", "--mcp-stdio", "--port", "51333"],
            environment: ["NANOTEAMS_MCP_PORT": "50222"],
            configuredPort: 49111
        )
        XCTAssertEqual(cliFlagStdio, .mcpStdio(port: 51333, token: nil))

        let cliEqualsStdio = NanoTeamsLauncher.resolveLaunchMode(
            arguments: ["NanoTeams", "--mcp-stdio", "--port=52444"],
            environment: ["NANOTEAMS_MCP_PORT": "50222"],
            configuredPort: 49111
        )
        XCTAssertEqual(cliEqualsStdio, .mcpStdio(port: 52444, token: nil))

        // 5. dispatch() routes .app to runApp alone, and .mcpStdio to the scrub, the relay and the exit
        var effects: [String] = []
        let dispatchedApp = NanoTeamsLauncher.dispatch(
            arguments: ["NanoTeams"],
            environment: [:],
            configuredPort: 47321,
            defaults: InMemoryConfigurationStorage(),
            scrubEnvironmentVariable: { effects.append("scrub \($0)") },
            noteInheritedToken: {},
            runApp: { effects.append("app") },
            runStdioRelay: { _, _, _ in
                effects.append("relay")
                return 0
            },
            exitProcess: { effects.append("exit \($0)") }
        )
        XCTAssertEqual(dispatchedApp, .app)
        XCTAssertEqual(effects, ["scrub NANOTEAMS_TOKEN", "app"], "the app scrubs too: it is every role's parent")

        effects = []
        let dispatchedStdio = NanoTeamsLauncher.dispatch(
            arguments: ["NanoTeams", "--mcp-stdio", "--port", "53555"],
            environment: [HostedMCPConstants.tokenEnvironmentVariable: "ntm_temp_env_token"],
            configuredPort: 47321,
            defaults: InMemoryConfigurationStorage(),
            scrubEnvironmentVariable: { effects.append("scrub \($0)") },
            noteInheritedToken: {},
            runApp: { effects.append("app") },
            runStdioRelay: { port, token, _ in
                effects.append("relay \(port) \(token ?? "nil")")
                return 7
            },
            exitProcess: { effects.append("exit \($0)") }
        )
        XCTAssertEqual(dispatchedStdio, .mcpStdio(port: 53555, token: nil))
        XCTAssertEqual(
            effects,
            ["scrub NANOTEAMS_TOKEN", "relay 53555 nil", "exit 7"],
            "the variable leaves the process environment BEFORE the relay runs, is never relayed, and the process exits with the relay's code"
        )
    }

    @MainActor
    func testStdioDispatchFallsBackToTheStoredExternalAgentsPort_readFromTheInjectedDefaults() async {
        func dispatchedPort(
            arguments: [String] = ["NanoTeams", "--mcp-stdio"],
            environment: [String: String] = [:],
            configuredPort: Int? = nil,
            stored: Int?
        ) -> UInt16? {
            let defaults = InMemoryConfigurationStorage()
            if let stored {
                defaults.set(stored, forKey: UserDefaultsKeys.externalAgentsPort)
            }
            var relayPort: UInt16?
            NanoTeamsLauncher.dispatch(
                arguments: arguments,
                environment: environment,
                configuredPort: configuredPort,
                defaults: defaults,
                scrubEnvironmentVariable: { _ in },
                noteInheritedToken: {},
                runApp: {},
                runStdioRelay: { port, _, _ in
                    relayPort = port
                    return 0
                },
                exitProcess: { _ in }
            )
            return relayPort
        }

        XCTAssertEqual(dispatchedPort(stored: 49111), 49111, "the port Settings stored is the fallback")
        XCTAssertEqual(dispatchedPort(stored: nil), HostedMCPConstants.defaultPort)
        XCTAssertEqual(dispatchedPort(stored: 0), HostedMCPConstants.defaultPort, "a stored 0 is no port")
        XCTAssertEqual(
            dispatchedPort(environment: [HostedMCPConstants.portEnvironmentVariable: "50222"], stored: 49111), 50222)
        XCTAssertEqual(dispatchedPort(arguments: ["NanoTeams", "--mcp-stdio", "--port", "51333"], stored: 49111), 51333)
        XCTAssertEqual(dispatchedPort(configuredPort: 48000, stored: 49111), 48000, "an explicit port wins over the stored one")
    }

    func testJSONRPCLineFramerHandlesPartialChunksCRLFOversizedLinesAndEOF() {
        var framer = JSONRPCLineFramer(maxLineBytes: 32)

        // Partial chunk followed by completion + CRLF + blank line
        XCTAssertEqual(framer.append(Data(#"{"id":1,"#.utf8)), [])
        let events1 = framer.append(Data("\"ok\":true}\r\n  \r\n{\"id\":2}\n".utf8))
        XCTAssertEqual(
            events1,
            [
                .line(Data(#"{"id":1,"ok":true}"#.utf8)),
                .line(Data(#"{"id":2}"#.utf8)),
            ]
        )

        // Oversized line emits .lineTooLong once and recovers on the next line
        let oversized = String(repeating: "x", count: 40) + "\n{\"id\":3}"
        let events2 = framer.append(Data(oversized.utf8))
        XCTAssertEqual(events2, [.lineTooLong])

        // Trailing line without newline flushed on finish()
        let events3 = framer.finish()
        XCTAssertEqual(events3, [.line(Data(#"{"id":3}"#.utf8))])

        // formatLine strips embedded CR/LF and appends a single \n
        let formatted = JSONRPCLineFramer.formatLine(Data("{\"a\":1}\r\n".utf8))
        XCTAssertEqual(String(decoding: formatted, as: UTF8.self), "{\"a\":1}\n")
    }

    // MARK: - 2. Line Framing, SSE Promotion -> Stdout Lines & Legacy Header Propagation (§7.4)

    func testLegacySessionHeaderPropagationAndSSEStreamingToStdoutLines() async throws {
        let secretStorage = InMemorySecureTokenStorage()
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage,
            appVersion: "2.0.0",
            processIdentifier: 4242
        )
        let issued = try agentStore.createAgent(label: "Claude Desktop")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                if name == ExternalAutovisorToolNames.waitForEvents {
                    try? await Task.sleep(for: .milliseconds(80))
                }
                return ToolExecutionResult(
                    toolName: name,
                    argumentsJSON: "{}",
                    outputJSON: #"{"ok":true,"data":{"tool":"\#(name)"}}"#,
                    isError: false
                )
            },
            agentTextVersion: "v-test",
            keepAliveInterval: 0.03
        )

        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: dispatcher)
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: 47321, rawToken: issued.token),
            httpClient: httpClient,
            appOpener: SpyAppOpener(),
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        // Send initialize (legacy 2025-06-18), notifications/initialized, tools/list, and SSE-promoted tools/call (with progressToken)
        let inputLines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude","version":"1.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":10},"_meta":{"progressToken":"prog-1"}}}"#,
        ]
        // Feed in small fragmented chunks to exercise JSONRPCLineFramer across chunk boundaries
        let joined = inputLines.joined(separator: "\n") + "\n"
        let bytes = Array(joined.utf8)
        for start in stride(from: 0, to: bytes.count, by: 29) {
            let end = min(bytes.count, start + 29)
            continuation.yield(Data(bytes[start..<end]))
        }
        continuation.finish()

        await relay.run(stdinChunks: stream)

        // Verify /identify ran once before the first POST
        XCTAssertEqual(httpClient.identifyCallCount, 1)
        XCTAssertEqual(httpClient.recordedPosts.count, 4)

        // Verify subsequent legacy requests carried negotiated MCP-Protocol-Version (2025-06-18) and Mcp-Session-Id
        let initializedHeaders = httpClient.recordedPosts[1].headers
        let toolsListHeaders = httpClient.recordedPosts[2].headers
        let toolsCallHeaders = httpClient.recordedPosts[3].headers

        let sessionID = try XCTUnwrap(toolsListHeaders["mcp-session-id"])
        XCTAssertFalse(sessionID.isEmpty)
        XCTAssertEqual(initializedHeaders["mcp-session-id"], sessionID)
        XCTAssertEqual(toolsCallHeaders["mcp-session-id"], sessionID)
        XCTAssertEqual(initializedHeaders["mcp-protocol-version"], "2025-06-18")
        XCTAssertEqual(toolsListHeaders["mcp-protocol-version"], "2025-06-18")
        XCTAssertEqual(toolsCallHeaders["mcp-protocol-version"], "2025-06-18")

        // Verify stdout lines: initialize (id:1), tools/list (id:2), SSE progress notification(s), and SSE final result (id:3)
        let outLines = collector.stdoutLines()
        XCTAssertGreaterThanOrEqual(outLines.count, 4, "Expected at least 4 stdout lines, got: \(outLines)")
        XCTAssertTrue(outLines.contains { $0.contains(#""id":1"#) && $0.contains(#""protocolVersion":"2025-06-18""#) })
        XCTAssertTrue(outLines.contains { $0.contains(#""id":2"#) && $0.contains(#""folder_status""#) })
        XCTAssertTrue(outLines.contains { $0.contains(#""notifications/progress""#) && $0.contains(#""prog-1""#) })
        XCTAssertTrue(outLines.contains { $0.contains(#""id":3"#) && $0.contains("wait_for_events") })
        XCTAssertEqual(collector.stderrContents(), "")
    }

    // MARK: - 3. Cancellation in Legacy Era (`notifications/cancelled` POST) and Modern Era (Stream Close) (§7.4, E3, E4)

    func testLegacyCancellationForwardsNotificationsCancelledPostAndCancelsInFlightWait() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let issued = try agentStore.createAgent(label: "Legacy Cancel Agent")
        let waitEntered = expectation(description: "legacy wait_for_events entered")

        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, isCancelled in
                if name == ExternalAutovisorToolNames.waitForEvents {
                    waitEntered.fulfill()
                    while !isCancelled() {
                        try? await Task.sleep(for: .milliseconds(15))
                    }
                    return ToolExecutionResult(
                        toolName: name,
                        argumentsJSON: "{}",
                        outputJSON: #"{"ok":false,"error":{"code":"cancelled","message":"Wait cancelled"}}"#,
                        isError: true
                    )
                }
                return ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )

        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: dispatcher)
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: 47321, rawToken: issued.token),
            httpClient: httpClient,
            appOpener: SpyAppOpener(),
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let runTask = Task {
            await relay.run(stdinChunks: stream)
        }

        continuation.yield(Data((
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"# + "\n" +
            #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":30}}}"# + "\n"
        ).utf8))

        await fulfillment(of: [waitEntered], timeout: 2.0)

        // Send legacy notifications/cancelled -> must be forwarded as POST /mcp with Mcp-Session-Id
        continuation.yield(Data((
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42,"reason":"user_cancelled"}}"# + "\n"
        ).utf8))
        continuation.finish()

        await runTask.value

        XCTAssertEqual(httpClient.recordedPosts.count, 3)
        let cancelPost = httpClient.recordedPosts[2]
        let cancelPostText = String(decoding: cancelPost.body, as: UTF8.self)
        XCTAssertTrue(cancelPostText.contains("notifications/cancelled"))
        XCTAssertNotNil(cancelPost.headers["mcp-session-id"])
        XCTAssertEqual(httpClient.cancelledStreamPostCount, 0)

        let outLines = collector.stdoutLines()
        XCTAssertTrue(outLines.contains { $0.contains(#""id":42"#) && $0.contains("cancelled") })
    }

    func testModernCancellationClosesInFlightHTTPStreamAndDerivesModernHeaders() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let issued = try agentStore.createAgent(label: "Modern Cancel Agent")
        let waitEntered = expectation(description: "modern wait_for_events entered")
        let waitCancelled = expectation(description: "modern wait_for_events observed stream cancellation")

        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, isCancelled in
                if name == ExternalAutovisorToolNames.waitForEvents {
                    waitEntered.fulfill()
                    while !isCancelled() {
                        try? await Task.sleep(for: .milliseconds(15))
                    }
                    waitCancelled.fulfill()
                }
                return ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )

        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: dispatcher)
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: 47321, rawToken: issued.token),
            httpClient: httpClient,
            appOpener: SpyAppOpener(),
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let runTask = Task {
            await relay.run(stdinChunks: stream)
        }

        // Send modern tools/call (id: 77)
        let modernCall = #"{"jsonrpc":"2.0","id":77,"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":30},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        continuation.yield(Data((modernCall + "\n").utf8))

        await fulfillment(of: [waitEntered], timeout: 2.0)

        // Verify modern headers were derived from the JSON-RPC body
        XCTAssertEqual(httpClient.recordedPosts.count, 1)
        let callHeaders = httpClient.recordedPosts[0].headers
        XCTAssertEqual(callHeaders["mcp-protocol-version"], "2026-07-28")
        XCTAssertEqual(callHeaders["mcp-method"], "tools/call")
        XCTAssertEqual(callHeaders["mcp-name"], "wait_for_events")

        // Send notifications/cancelled for id: 77 -> must close the in-flight HTTP stream (NOT send a second POST)
        continuation.yield(Data((
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":77}}"# + "\n"
        ).utf8))
        continuation.finish()

        await fulfillment(of: [waitCancelled], timeout: 2.0)
        await runTask.value

        XCTAssertEqual(httpClient.recordedPosts.count, 1, "Modern cancellation must close the stream without forwarding a second POST")
        XCTAssertEqual(httpClient.cancelledStreamPostCount, 1)
    }

    // MARK: - 4. Unreachable Server Triggers Auto-Open (`activates == false`) & Timeout Handling (§7.4, E6)

    func testUnreachableServerTriggersAutoOpenWithActivatesFalseAndSucceedsOnceServerStarts() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let issued = try agentStore.createAgent(label: "AutoOpen Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )

        // Start unreachable; when SpyAppOpener is called, bring the server online
        let httpClient = InProcessStdioHTTPClient(
            agentStore: agentStore,
            dispatcher: dispatcher,
            isServerReachable: false
        )
        let opener = SpyAppOpener {
            httpClient.isServerReachable = true
        }
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(
                port: 47321,
                rawToken: issued.token,
                launchTimeout: .seconds(2),
                pollInterval: .milliseconds(10)
            ),
            httpClient: httpClient,
            appOpener: opener,
            sleep: { _ in },
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )

        // Also verify NSWorkspaceHostedMCPAppOpener configures activates = false
        let workspaceConfig = NSWorkspaceHostedMCPAppOpener.makeOpenConfiguration(activates: false)
        XCTAssertFalse(workspaceConfig.activates)

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        continuation.yield(Data((#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n").utf8))
        continuation.finish()

        await relay.run(stdinChunks: stream)

        XCTAssertEqual(opener.openCallCount, 1)
        XCTAssertEqual(opener.recordedActivatesFlags, [false])
        XCTAssertEqual(httpClient.recordedPosts.count, 1)

        let outLines = collector.stdoutLines()
        XCTAssertEqual(outLines.count, 1)
        XCTAssertTrue(outLines[0].contains(#""id":1"#) && outLines[0].contains(#""result":{}"#))
    }

    func testUnreachableServerEmitsHonestJSONRPCErrorWhenAutoOpenPollTimesOut() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let issued = try agentStore.createAgent(label: "Timeout Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )

        let httpClient = InProcessStdioHTTPClient(
            agentStore: agentStore,
            dispatcher: dispatcher,
            isServerReachable: false
        )
        let opener = SpyAppOpener()
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(
                port: 47321,
                rawToken: issued.token,
                launchTimeout: .milliseconds(60),
                pollInterval: .milliseconds(20)
            ),
            httpClient: httpClient,
            appOpener: opener,
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        continuation.yield(Data((#"{"jsonrpc":"2.0","id":9,"method":"ping"}"# + "\n").utf8))
        continuation.finish()

        await relay.run(stdinChunks: stream)

        XCTAssertEqual(opener.openCallCount, 1)
        XCTAssertEqual(opener.recordedActivatesFlags, [false])
        XCTAssertEqual(httpClient.recordedPosts.count, 0)

        let outLines = collector.stdoutLines()
        XCTAssertEqual(outLines.count, 1)
        XCTAssertTrue(outLines[0].contains(#""id":9"#))
        XCTAssertTrue(outLines[0].contains(#""error""#))
        XCTAssertTrue(outLines[0].contains("did not become reachable"))
        XCTAssertTrue(collector.stderrContents().contains("did not become reachable"))
    }

    func testConcurrentRequestsWhenUnreachableCoalesceIdentifyAndLaunchAppOnlyOnce() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let issued = try agentStore.createAgent(label: "Coalesce Launch Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )
        let httpClient = InProcessStdioHTTPClient(
            agentStore: agentStore,
            dispatcher: dispatcher,
            isServerReachable: false
        )
        let opener = SpyAppOpener {
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                httpClient.isServerReachable = true
            }
        }
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(
                port: 47321,
                rawToken: issued.token,
                launchTimeout: .seconds(2),
                pollInterval: .milliseconds(10)
            ),
            httpClient: httpClient,
            appOpener: opener,
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let req1 = #"{"jsonrpc":"2.0","id":101,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        let req2 = #"{"jsonrpc":"2.0","id":102,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        continuation.yield(Data((req1 + "\n" + req2 + "\n").utf8))
        continuation.finish()

        await relay.run(stdinChunks: stream)

        XCTAssertEqual(opener.openCallCount, 1, "Concurrent requests when unreachable must coalesce auto-open to a single call")
        XCTAssertEqual(opener.recordedActivatesFlags, [false])
        let outLines = collector.stdoutLines()
        XCTAssertEqual(outLines.count, 2)
        XCTAssertTrue(outLines.contains { $0.contains(#""id":101"#) && $0.contains(#""tools""#) })
        XCTAssertTrue(outLines.contains { $0.contains(#""id":102"#) && $0.contains(#""tools""#) })
    }

    func testMidRequestTransportFailureDoesNotRelaunchAppOrRetryPost() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let issued = try agentStore.createAgent(label: "Mid-Request Drop Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: dispatcher)
        httpClient.postOverride = { _, _, _, _ in
            throw HostedMCPStdioHTTPError.transportFailure("connection_lost")
        }

        let opener = SpyAppOpener()
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: 47321, rawToken: issued.token),
            httpClient: httpClient,
            appOpener: opener,
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let callReq = #"{"jsonrpc":"2.0","id":201,"method":"tools/call","params":{"name":"create_managed_task","arguments":{"title":"t","brief":"b"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        continuation.yield(Data((callReq + "\n").utf8))
        continuation.finish()

        await relay.run(stdinChunks: stream)

        XCTAssertEqual(opener.openCallCount, 0, "Mid-request connection drop must not trigger appOpener")
        XCTAssertEqual(httpClient.recordedPosts.count, 1, "Mid-request connection drop must not retry a mutating POST")
        let outLines = collector.stdoutLines()
        XCTAssertEqual(outLines.count, 1)
        XCTAssertTrue(outLines[0].contains(#""id":201"#))
        XCTAssertTrue(outLines[0].contains("connection_lost"))

        XCTAssertTrue(URLSessionHostedMCPStdioHTTPClient.isJSONRPCResponsePayload(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)))
        XCTAssertTrue(URLSessionHostedMCPStdioHTTPClient.isJSONRPCResponsePayload(Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"err"}}"#.utf8)))
        XCTAssertFalse(URLSessionHostedMCPStdioHTTPClient.isJSONRPCResponsePayload(Data(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{}}"#.utf8)))
    }

    // MARK: - 5. Token Strictly From Environment & Port-Hijack Refusal (§7.4, §10.1)

    func testTokenReadStrictlyFromEnvironmentNeverKeychainAndPortHijackBadProofNeverSendsBearerToken() async throws {
        let secretStorage = InMemorySecureTokenStorage()
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: secretStorage
        )
        let issued = try agentStore.createAgent(label: "Hijack Check Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: dispatcher)

        // Part A: no token (no --token-file, no NANOTEAMS_TOKEN) fails even though secretStorage holds the agent's verifier
        let missingTokenCollector = OutputCollector()
        let missingTokenRelay = HostedMCPStdioRelay(
            configuration: .init(port: 47321, rawToken: nil),
            httpClient: httpClient,
            appOpener: SpyAppOpener(),
            writeStdout: { missingTokenCollector.appendStdout($0) },
            writeStderr: { missingTokenCollector.appendStderr($0) }
        )
        let (stream1, cont1) = AsyncStream.makeStream(of: Data.self)
        cont1.yield(Data((#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n").utf8))
        cont1.finish()
        await missingTokenRelay.run(stdinChunks: stream1)

        XCTAssertEqual(httpClient.identifyCallCount, 0)
        XCTAssertEqual(httpClient.recordedPosts.count, 0)
        let missingLines = missingTokenCollector.stdoutLines()
        XCTAssertEqual(missingLines.count, 1)
        XCTAssertTrue(missingLines[0].contains("--token-file"), "the reply names the way to give the bridge its token")

        // Part B: Port hijacker returns 200 OK on /identify with a forged HMAC proof -> relay NEVER sends POST /mcp!
        httpClient.identifyOverride = { _, _, _ in
            let forged = HostedMCPIdentifyPayload(
                app: "NanoTeams",
                version: "2.0.0",
                pid: 9999,
                proof: String(repeating: "a", count: 64)
            )
            let body = try JSONEncoder().encode(forged)
            return (200, body)
        }

        let hijackCollector = OutputCollector()
        let hijackRelay = HostedMCPStdioRelay(
            configuration: .init(port: 47321, rawToken: issued.token),
            httpClient: httpClient,
            appOpener: SpyAppOpener(),
            writeStdout: { hijackCollector.appendStdout($0) },
            writeStderr: { hijackCollector.appendStderr($0) }
        )
        let (stream2, cont2) = AsyncStream.makeStream(of: Data.self)
        cont2.yield(Data((#"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n").utf8))
        cont2.finish()
        await hijackRelay.run(stdinChunks: stream2)

        XCTAssertEqual(httpClient.identifyCallCount, 1)
        XCTAssertEqual(
            httpClient.recordedPosts.count,
            0,
            "Bearer token must NEVER be sent when /identify returns an invalid proof"
        )
        let hijackLines = hijackCollector.stdoutLines()
        XCTAssertEqual(hijackLines.count, 1)
        XCTAssertTrue(hijackLines[0].contains(#""id":2"#))
        XCTAssertTrue(hijackLines[0].contains("proof verification"))
        XCTAssertFalse(hijackCollector.stderrContents().contains(issued.token))
    }

    // MARK: - 6. Loopback E2E Against Real `HostedMCPListener` When Socket Bind Is Permitted (§7.4)

    func testLoopbackEndToEndStdioRelayAgainstHostedMCPListener() async throws {
        let agentStore = HostedMCPAgentStore(
            directoryURL: tempDir,
            secretStorage: InMemorySecureTokenStorage()
        )
        let issued = try agentStore.createAgent(label: "Loopback Stdio Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(
                    toolName: name,
                    argumentsJSON: "{}",
                    outputJSON: #"{"ok":true,"data":{"tool":"\#(name)"}}"#,
                    isError: false
                )
            },
            agentTextVersion: "v-loopback"
        )
        let listener = HostedMCPListener(agentStore: agentStore, dispatcher: dispatcher)
        defer {
            Task { await listener.stop() }
        }

        let port = try await listener.start(port: 0)
        let urlClient = URLSessionHostedMCPStdioHTTPClient()
        do {
            _ = try await urlClient.getIdentify(
                port: port,
                shortID: "00000000",
                nonceHex: "0123456789abcdef"
            )
        } catch {
            throw XCTSkip("Outbound loopback TCP connect to 127.0.0.1:\(port) is blocked by the current sandbox environment")
        }

        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: port, rawToken: issued.token),
            httpClient: urlClient,
            appOpener: SpyAppOpener(),
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let discoverReq = #"{"jsonrpc":"2.0","id":10,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        let callReq = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"folder_status","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"progressToken":"p1"}}}"#
        continuation.yield(Data((discoverReq + "\n" + callReq + "\n").utf8))
        continuation.finish()

        await relay.run(stdinChunks: stream)
        await listener.stop()

        let outLines = collector.stdoutLines()
        XCTAssertGreaterThanOrEqual(outLines.count, 2, "Expected discover and tools/call responses on stdout, got: \(outLines)")
        XCTAssertTrue(outLines.contains { $0.contains(#""id":10"#) && $0.contains(#""nanoteams""#) })
        XCTAssertTrue(outLines.contains { $0.contains(#""id":11"#) && $0.contains("folder_status") })
    }

    // MARK: - 7. Ш24: Startup Work-Folder Restoration Idempotence & Non-Activating Window Auto-Open (§11)

    @MainActor
    func testStartupBootstrapDefaultStorageIfNeededIsIdempotentAcrossOrchestratorStartupAndMainLayoutView() async throws {
        let projectDir = tempDir.appendingPathComponent("restored-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStorage = InMemoryConfigurationStorage()
        let config = StoreConfiguration(storage: configStorage)
        config.lastOpenedWorkFolderPath = projectDir.path

        let baseRepo = NTMSRepository()
        let countingRepo = SelectivelyFailingRepository(wrapping: baseRepo)
        let orchestrator = TestOrchestrator.make(
            repository: countingRepo,
            configuration: config
        )

        // Trigger startup bootstrap AND an immediate second call (as MainLayoutView .task does)
        orchestrator.startStartupBootstrapIfNeeded()
        await orchestrator.bootstrapDefaultStorageIfNeeded()
        // Calling a third time after completion must also be a no-op
        await orchestrator.bootstrapDefaultStorageIfNeeded()

        XCTAssertEqual(orchestrator.workFolderURL?.standardizedFileURL, projectDir.standardizedFileURL)
        XCTAssertEqual(
            countingRepo.openStarts.count,
            1,
            "openOrCreateWorkFolder must be called exactly once across startup and MainLayoutView .task"
        )
    }

    // MARK: - 8. Process I/O, App Opener & Error Mapping (§7.4)

    func testRunWithFileDescriptors_answersEveryRequestReadFromTheDescriptor_andReturnsAtEOF() throws {
        let input = Pipe()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":"two","method":"tools/list"}"#,
        ]
        // No newline after the last line: EOF itself must end it.
        input.fileHandleForWriting.write(Data(lines.joined(separator: "\n").utf8))
        try input.fileHandleForWriting.close()

        let (agentStore, _, _) = try makeAgentStore(label: "Descriptor Agent")
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: makeEchoDispatcher())
        let opener = SpyAppOpener()
        let collector = OutputCollector()
        _ = HostedMCPStdioRelay.runWithFileDescriptors(
            port: 48_401,
            rawToken: nil,
            stdinFD: input.fileHandleForReading.fileDescriptor,
            httpClient: httpClient,
            appOpener: opener,
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )

        XCTAssertEqual(httpClient.identifyCallCount, 0, "with no token nothing leaves the process")
        XCTAssertTrue(httpClient.recordedPosts.isEmpty)
        XCTAssertEqual(opener.openCallCount, 0)
        let stdout = collector.stdoutLines()
        let answers = stdout.compactMap(errorLine)
        XCTAssertEqual(answers.count, stdout.count, "stdout carries JSON-RPC replies only: \(stdout)")
        XCTAssertEqual(
            Set(answers.compactMap(\.id)), Set([JSONRPCID.number(1), .string("two")]),
            "one reply per request and none for the notification: \(stdout)")
        XCTAssertEqual(answers.count, 2, "\(stdout)")
        XCTAssertTrue(answers.allSatisfy { $0.code == -32000 && $0.message == Self.missingTokenMessage }, "\(answers)")
        XCTAssertEqual(
            collector.stderrContents().components(separatedBy: Self.missingTokenMessage).count - 1, 3,
            "every line is diagnosed on stderr, the notification's included")
    }

    /// A `--token-file` that was named and refused is what every request is answered with — not
    /// the generic "missing token", which would send the person looking for a variable.
    func testRunWithFileDescriptors_aRefusedTokenFileAnswersWithItsReason() throws {
        let input = Pipe()
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        try input.fileHandleForWriting.close()

        let (agentStore, _, _) = try makeAgentStore(label: "Token File Agent")
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: makeEchoDispatcher())
        let collector = OutputCollector()
        let reason = "The token file /x/a4c36525.token can be read by other users. Make it private to you (chmod 600)."
        _ = HostedMCPStdioRelay.runWithFileDescriptors(
            port: 48_402, rawToken: nil, tokenProblem: reason,
            stdinFD: input.fileHandleForReading.fileDescriptor,
            httpClient: httpClient, appOpener: SpyAppOpener(),
            writeStdout: { collector.appendStdout($0) }, writeStderr: { collector.appendStderr($0) })

        XCTAssertEqual(httpClient.identifyCallCount, 0, "with no token nothing leaves the process")
        let answers = collector.stdoutLines().compactMap(errorLine)
        XCTAssertEqual(answers.map(\.message), [reason])
        XCTAssertTrue(collector.stderrContents().contains(reason))
    }

    func testWriteToFileDescriptor_writesEveryByte() throws {
        let pipe = Pipe()
        HostedMCPStdioRelay.writeToFileDescriptor(pipe.fileHandleForWriting.fileDescriptor, data: Data("hello".utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try pipe.fileHandleForReading.readToEnd(), Data("hello".utf8))
    }

    func testAppOpener_resolvesTheAppBundle_andOpensItWithoutActivating() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/NanoTeams.app")
        let executableURL = URL(fileURLWithPath: "/Applications/NanoTeams.app/Contents/MacOS/NanoTeams")
        let toolURL = URL(fileURLWithPath: "/usr/bin/env")
        XCTAssertEqual(NSWorkspaceHostedMCPAppOpener.resolveDefaultAppBundleURL(bundleURL: appURL, executableURL: nil), appURL)
        XCTAssertEqual(
            NSWorkspaceHostedMCPAppOpener.resolveDefaultAppBundleURL(bundleURL: toolURL, executableURL: executableURL), appURL)
        XCTAssertNil(NSWorkspaceHostedMCPAppOpener.resolveDefaultAppBundleURL(bundleURL: toolURL, executableURL: toolURL))

        do {
            try await NSWorkspaceHostedMCPAppOpener(appBundleURL: nil).openApplication(activates: false)
            XCTFail("an opener that found no app bundle must refuse")
        } catch let error as HostedMCPStdioHTTPError {
            XCTAssertEqual(error, .transportFailure("app_bundle_not_found"))
        }

        let opened = LockedLog()
        let opener = NSWorkspaceHostedMCPAppOpener(
            appBundleURL: appURL,
            runningInstance: { nil },
            openWorkspaceApp: { url, configuration in
                opened.append("\(url.path) activates=\(configuration.activates) recents=\(configuration.addsToRecentItems) "
                    + "new=\(configuration.createsNewApplicationInstance)")
            }
        )
        try await opener.openApplication(activates: false)
        XCTAssertEqual(opened.all, ["/Applications/NanoTeams.app activates=false recents=false new=false"])
    }

    /// The relay starts no second NanoTeams (F6 C1, 2026-11-12): with one already running — its
    /// server simply not answering — opening would put a second process on the folder it opens.
    func testAppOpener_withANanoTeamsAlreadyRunning_opensNothing() async throws {
        let opened = LockedLog()
        let opener = NSWorkspaceHostedMCPAppOpener(
            appBundleURL: URL(fileURLWithPath: "/Applications/NanoTeams.app"),
            runningInstance: { HostedMCPRunningApp(launchedAt: Date(timeIntervalSince1970: 1_762_560_400)) },
            openWorkspaceApp: { url, _ in opened.append(url.path) }
        )
        do {
            try await opener.openApplication(activates: false)
            XCTFail("an opener that sees NanoTeams running must not open another")
        } catch let error as HostedMCPAppOpenerError {
            XCTAssertEqual(error, .alreadyRunning(HostedMCPRunningApp(
                launchedAt: Date(timeIntervalSince1970: 1_762_560_400))))
        }
        XCTAssertEqual(opened.all, [])
    }

    /// Which running copy the relay counts (F6 C1): every one but itself that has not terminated,
    /// launched at the latest of their moments — and at an unknown one when any of them does not
    /// say, so the relay gives an app it cannot date the whole launch window.
    func testOtherRunningApp_excludesItselfAndTheTerminated_andDatesByTheLatest() {
        let me: pid_t = 100
        let early = Date(timeIntervalSince1970: 1_762_560_400)
        let late = early.addingTimeInterval(45)
        func app(_ pid: pid_t, terminated: Bool = false, _ date: Date?) -> HostedMCPListedApp {
            HostedMCPListedApp(processID: pid, isTerminated: terminated, launchDate: date)
        }
        let choose = NSWorkspaceHostedMCPAppOpener.otherRunningApp

        XCTAssertNil(choose([], me))
        XCTAssertNil(choose([app(me, late)], me), "the relay's own process is not another NanoTeams")
        XCTAssertNil(choose([app(me, late), app(7, terminated: true, early)], me), "a terminated copy is not running")
        XCTAssertEqual(choose([app(7, early)], me), HostedMCPRunningApp(launchedAt: early))
        XCTAssertEqual(choose([app(7, early), app(8, late), app(me, late.addingTimeInterval(60))], me),
                       HostedMCPRunningApp(launchedAt: late), "the latest of the others, never its own")
        XCTAssertEqual(choose([app(7, early), app(8, nil)], me), HostedMCPRunningApp(launchedAt: nil),
                       "one copy that does not say makes the moment unknown")
        XCTAssertEqual(choose([app(7, early), app(8, terminated: true, nil)], me),
                       HostedMCPRunningApp(launchedAt: early), "an undated terminated copy does not count")
    }

    /// What is left of a running app's launch window (D-M18 R5): all of it when its launch time is
    /// unknown, the rest of it while it may still be starting, nothing once it is over.
    func testRemainingStartupWindow_isWhatIsLeftOfTheLaunchWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(HostedMCPStdioRelay.remainingStartupWindow(
            of: HostedMCPRunningApp(launchedAt: nil), launchTimeout: .seconds(30), now: now), .seconds(30))
        XCTAssertEqual(HostedMCPStdioRelay.remainingStartupWindow(
            of: HostedMCPRunningApp(launchedAt: now.addingTimeInterval(-10)), launchTimeout: .seconds(30), now: now),
            .seconds(20))
        XCTAssertEqual(HostedMCPStdioRelay.remainingStartupWindow(
            of: HostedMCPRunningApp(launchedAt: now.addingTimeInterval(-30)), launchTimeout: .seconds(30), now: now),
            .zero)
        XCTAssertEqual(HostedMCPStdioRelay.remainingStartupWindow(
            of: HostedMCPRunningApp(launchedAt: now.addingTimeInterval(-3600)), launchTimeout: .seconds(30), now: now),
            .zero)
        XCTAssertEqual(HostedMCPStdioRelay.remainingStartupWindow(
            of: HostedMCPRunningApp(launchedAt: now.addingTimeInterval(60)), launchTimeout: .seconds(30), now: now),
            .seconds(30), "a clock that moved back counts as just launched")
    }

    /// A NanoTeams launched a moment ago — by a login item, or by another relay — is listed before
    /// its server listens: the relay launches nothing and waits for it, instead of failing the
    /// agent's first call (D-M18 R5).
    func testRelay_whenNanoTeamsIsStillStarting_waitsForItsServer() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Starting Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: dispatcher, isServerReachable: false)
        let opener = SpyAppOpener { throw HostedMCPAppOpenerError.alreadyRunning(HostedMCPRunningApp(launchedAt: Date())) }
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: 47333, rawToken: issued.token,
                                 launchTimeout: .seconds(30), pollInterval: .milliseconds(10)),
            httpClient: httpClient,
            appOpener: opener,
            // The server comes up during the first wait.
            sleep: { _ in httpClient.isServerReachable = true },
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        continuation.yield(Data((#"{"jsonrpc":"2.0","id":5,"method":"ping"}"# + "\n").utf8))
        continuation.finish()

        await relay.run(stdinChunks: stream)

        XCTAssertEqual(opener.openCallCount, 1)
        XCTAssertEqual(httpClient.recordedPosts.count, 1, "the call reached the server once it answered")
        XCTAssertFalse(collector.stderrContents().contains("not answering"), collector.stderrContents())
    }

    /// Still starting, and its server never comes up within the window: the agent hears that it
    /// runs and does not answer — not that it could not be launched (D-M18 R5).
    func testRelay_whenNanoTeamsStartsButItsServerNeverAnswers_saysSoAfterTheWindow() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Never Answers Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: dispatcher, isServerReachable: false)
        let opener = SpyAppOpener { throw HostedMCPAppOpenerError.alreadyRunning(HostedMCPRunningApp(launchedAt: Date())) }
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: 47334, rawToken: issued.token,
                                 launchTimeout: .milliseconds(200), pollInterval: .milliseconds(10)),
            httpClient: httpClient,
            appOpener: opener,
            sleep: { try await Task.sleep(for: $0) },
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        continuation.yield(Data((#"{"jsonrpc":"2.0","id":6,"method":"ping"}"# + "\n").utf8))
        continuation.finish()

        await relay.run(stdinChunks: stream)

        XCTAssertGreaterThan(httpClient.identifyCallCount, 2, "it waited for the server")
        XCTAssertEqual(httpClient.recordedPosts.count, 0)
        XCTAssertTrue(collector.stderrContents().contains(HostedMCPStdioRelay.serverNotAnsweringMessage(port: 47334)),
                      collector.stderrContents())
    }

    /// The agent's call is told why, with the port — not "NanoTeams is not running".
    func testRelay_whenNanoTeamsRunsButDoesNotAnswer_saysSoAndStartsNothing() async throws {
        let agentStore = HostedMCPAgentStore(directoryURL: tempDir, secretStorage: InMemorySecureTokenStorage())
        let issued = try agentStore.createAgent(label: "Running Elsewhere Agent")
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: ClosureHostedMCPToolExecutor { name, _, _, _, _ in
                ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: "{}", isError: false)
            },
            agentTextVersion: "v-test"
        )
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: dispatcher, isServerReachable: false)
        // Launched long before its launch window: its server is off, not late — no wait.
        let opener = SpyAppOpener {
            throw HostedMCPAppOpenerError.alreadyRunning(HostedMCPRunningApp(launchedAt: .distantPast))
        }
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: 47333, rawToken: issued.token,
                                 launchTimeout: .seconds(2), pollInterval: .milliseconds(10)),
            httpClient: httpClient,
            appOpener: opener,
            sleep: { _ in },
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        continuation.yield(Data((#"{"jsonrpc":"2.0","id":4,"method":"ping"}"# + "\n").utf8))
        continuation.finish()

        await relay.run(stdinChunks: stream)

        XCTAssertEqual(opener.openCallCount, 1)
        XCTAssertEqual(httpClient.recordedPosts.count, 0)
        XCTAssertEqual(httpClient.identifyCallCount, 1, "no poll for a server that is off")
        let expected = HostedMCPStdioRelay.serverNotAnsweringMessage(port: 47333)
        XCTAssertTrue(expected.contains("127.0.0.1:47333"))
        let outLines = collector.stdoutLines()
        XCTAssertEqual(outLines.count, 1)
        XCTAssertTrue(outLines[0].contains(#""id":4"#) && outLines[0].contains("External Agents server is not answering"),
                      outLines[0])
        XCTAssertTrue(collector.stderrContents().contains(expected))
    }

    func testMapError_namesEveryTransportFailure() {
        XCTAssertEqual(URLSessionHostedMCPStdioHTTPClient.mapError(CancellationError()), .cancelled)
        XCTAssertEqual(URLSessionHostedMCPStdioHTTPClient.mapError(HostedMCPStdioHTTPError.connectionRefused), .connectionRefused)
        XCTAssertEqual(URLSessionHostedMCPStdioHTTPClient.mapError(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(URLSessionHostedMCPStdioHTTPClient.mapError(URLError(.cannotConnectToHost)), .connectionRefused)
        XCTAssertEqual(
            URLSessionHostedMCPStdioHTTPClient.mapError(URLError(.networkConnectionLost)), .transportFailure("connection_lost"))
        XCTAssertEqual(URLSessionHostedMCPStdioHTTPClient.mapError(URLError(.timedOut)), .transportFailure("timed_out"))
        XCTAssertEqual(
            URLSessionHostedMCPStdioHTTPClient.mapError(URLError(.badServerResponse)),
            .transportFailure("url_error_\(URLError.badServerResponse.rawValue)"))
        XCTAssertEqual(URLSessionHostedMCPStdioHTTPClient.mapError(NSError(domain: "t", code: 1)), .transportFailure("io_error"))
        XCTAssertFalse(URLSessionHostedMCPStdioHTTPClient.isJSONRPCResponsePayload(Data("not-json".utf8)))
        XCTAssertNil(HostedMCPStdioRelay.parsePort("999999"))
        XCTAssertEqual(HostedMCPStdioRelay.parseCLIPort(arguments: ["--port", "bad", "--port", "47321"]), 47321)
        XCTAssertNil(HostedMCPStdioRelay.parseBearerToken("ntm_zzzzzzzz_secret"))
        // One hex rule with the server (`HostedMCPHex`): a fullwidth digit is not a hex digit,
        // and the short id is eight BYTES. `Character.isHexDigit` took both.
        XCTAssertNil(HostedMCPStdioRelay.parseBearerToken("ntm_\u{FF10}1234567_secret"))
        XCTAssertNil(HostedMCPStdioRelay.parseBearerToken("ntm_\u{FF10}\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}\u{FF17}_secret"))
        XCTAssertEqual(HostedMCPStdioRelay.parseBearerToken("ntm_0a1B2c3D_secret")?.shortID, "0a1B2c3D")
    }

    // MARK: - 9. The Production URLSession Client, Served From a Script (§7.4)

    func testURLSessionClient_sendsWellFormedRequests_passesRepliesThrough_andMapsARefusedConnection() async throws {
        let port: UInt16 = 48_402
        ScriptedLoopbackProtocol.install(port: port) { request in
            if request.url?.path == HostedMCPConstants.identifyPath {
                return .init(statusCode: 200, contentType: "application/json", chunks: [#"{"app":"NanoTeams"}"#])
            }
            return .init(statusCode: 200, contentType: "application/json", chunks: [#"{"jsonrpc":"2.0","id":1,"result":{}}"#])
        }
        defer { ScriptedLoopbackProtocol.uninstall(port: port) }
        let client = ScriptedLoopbackProtocol.makeClient()

        let identify = try await client.getIdentify(port: port, shortID: "abcd1234", nonceHex: "00ff00ff00ff00ff")
        XCTAssertEqual(identify.statusCode, 200)
        XCTAssertEqual(identify.body, Data(#"{"app":"NanoTeams"}"#.utf8))

        let post = try await client.postMCP(
            port: port,
            headers: [("Authorization", "Bearer ntm_abcd1234_secret")],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8),
            onSSEFrame: { _ in XCTFail("a JSON reply is not an event stream") }
        )
        XCTAssertEqual(post.statusCode, 200)
        XCTAssertFalse(post.wasStreamedSSE)
        XCTAssertEqual(post.headers["content-type"], "application/json")
        XCTAssertEqual(post.body, Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))

        let served = ScriptedLoopbackProtocol.requests(port: port)
        XCTAssertEqual(served.map(\.httpMethod), ["GET", "POST"])
        let identifyURL = try XCTUnwrap(served.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(identifyURL.path, HostedMCPConstants.identifyPath)
        XCTAssertEqual(
            identifyURL.queryItems,
            [URLQueryItem(name: "agent", value: "abcd1234"), URLQueryItem(name: "nonce", value: "00ff00ff00ff00ff")])
        XCTAssertEqual(served.last?.url?.path, HostedMCPConstants.mcpPath)
        XCTAssertEqual(served.last?.value(forHTTPHeaderField: "Authorization"), "Bearer ntm_abcd1234_secret")
        XCTAssertEqual(served.last?.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")

        // A port nothing answers on is a refused connection — the one failure that auto-opens the app.
        do {
            _ = try await client.getIdentify(port: 48_403, shortID: "abcd1234", nonceHex: "00ff00ff00ff00ff")
            XCTFail("expected a refused connection")
        } catch let error as HostedMCPStdioHTTPError {
            XCTAssertEqual(error, .connectionRefused)
        }
    }

    func testAnSSEReplyWhoseBlankLineNeverArrives_stillReachesStdout() async throws {
        let collector = try await relayOverScriptedSession(port: 48_411, id: 7, reply: .init(chunks: [
            ": connected\n\n",
            "event: message\ndata: \(Self.progressFrame(7))\n\n",
            "event: message\ndata: \(Self.resultFrame(7))\n",
        ]))
        XCTAssertEqual(collector.stdoutLines(), [Self.progressFrame(7), Self.resultFrame(7)])
        XCTAssertEqual(collector.stderrContents(), "")
    }

    func testAnSSEReplyWhoseLastLineHasNoNewline_stillReachesStdout() async throws {
        let collector = try await relayOverScriptedSession(port: 48_412, id: 8, reply: .init(chunks: [
            "event: message\n",
            "data: \(Self.resultFrame(8))",
        ]))
        XCTAssertEqual(collector.stdoutLines(), [Self.resultFrame(8)])
        XCTAssertEqual(collector.stderrContents(), "")
    }

    func testAStreamErrorAfterACompleteReplyLine_deliversTheResult_notATransportError() async throws {
        let collector = try await relayOverScriptedEventStream(
            id: 9,
            replyBody: "event: message\ndata: \(Self.progressFrame(9))\n\nevent: message\ndata: \(Self.resultFrame(9))\n",
            failure: .networkConnectionLost
        )
        XCTAssertEqual(collector.stdoutLines(), [Self.progressFrame(9), Self.resultFrame(9)])
        XCTAssertEqual(collector.stderrContents(), "", "a request whose reply arrived did not fail")
    }

    func testAStreamCutMidLine_neverWritesHalfADocument_andAnswersWithTheTransportFailure() async throws {
        let collector = try await relayOverScriptedEventStream(
            id: 10,
            replyBody: "event: message\ndata: \(Self.progressFrame(10))\n\n" + #"event: message\#ndata: {"jsonrpc":"2.0","id":10,"res"#,
            failure: .networkConnectionLost
        )
        let lines = collector.stdoutLines()
        XCTAssertEqual(lines.first, Self.progressFrame(10))
        XCTAssertEqual(
            lines.dropFirst().map(errorLine),
            [ErrorLine(id: .number(10), code: -32000, message: "Hosted MCP transport failure (connection_lost).")],
            "\(lines)")
    }

    func testRelayEventStream_aCancelledRequestRelaysNothingMore() async {
        let (bytes, continuation) = AsyncThrowingStream.makeStream(of: UInt8.self)
        // A complete reply line whose blank line has not come yet; the body never ends by itself.
        for byte in "event: message\ndata: \(Self.resultFrame(14))\n".utf8 {
            continuation.yield(byte)
        }
        let relayed = LockedLog()
        let reading = Task {
            try await URLSessionHostedMCPStdioHTTPClient.relayEventStream(bytes) { frame in
                relayed.append(String(decoding: frame, as: UTF8.self))
            }
        }
        reading.cancel()
        let outcome = await reading.result

        XCTAssertThrowsError(try outcome.get(), "a cancelled read is not a delivered reply") { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(relayed.all, [], "the pending reply belongs to a request the client cancelled")
        continuation.finish()
    }

    func testAStreamThatEndsCleanlyWithoutAReply_answersTheRequestInsteadOfLeavingItOpen() async throws {
        let collector = try await relayOverScriptedSession(port: 48_415, id: 11, reply: .init(chunks: [
            ": connected\n\n",
            "event: message\ndata: \(Self.progressFrame(11))\n\n",
        ]))
        let lines = collector.stdoutLines()
        XCTAssertEqual(lines.first, Self.progressFrame(11))
        XCTAssertEqual(
            lines.dropFirst().map(errorLine),
            [ErrorLine(id: .number(11), code: -32000, message: "Hosted MCP transport failure (stream_ended_without_reply).")],
            "\(lines)")
    }

    func testAReplyCutMidLineByACleanClose_isNotWritten_andTheRequestIsStillAnswered() async throws {
        let collector = try await relayOverScriptedSession(port: 48_416, id: 12, reply: .init(chunks: [
            #"event: message\#ndata: {"jsonrpc":"2.0","id":12,"res"#,
        ]))
        let lines = collector.stdoutLines()
        XCTAssertEqual(
            lines.map(errorLine),
            [ErrorLine(id: .number(12), code: -32000, message: "Hosted MCP transport failure (stream_ended_without_reply).")],
            "\(lines)")
    }

    func testAModernCancellation_closesTheURLSessionStream_andWritesNothingForTheRequest() async throws {
        let port: UInt16 = 48_417
        let (agentStore, token, _) = try makeAgentStore(label: "Scripted Cancel Agent")
        ScriptedLoopbackProtocol.install(port: port, route: identifyingRoute(agentStore) { _ in
            .init(chunks: [": connected\n\n", "event: message\ndata: \(Self.resultFrame(13))\n"], ending: .hold)
        })
        defer { ScriptedLoopbackProtocol.uninstall(port: port) }

        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: port, rawToken: token),
            httpClient: ScriptedLoopbackProtocol.makeClient(),
            appOpener: SpyAppOpener(),
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let finished = LockedFlag()
        let runTask = Task {
            await relay.run(stdinChunks: stream)
            finished.set()
        }
        let call = #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":40},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        continuation.yield(Data((call + "\n").utf8))
        await waitUntil("the call's POST reaches the server") {
            ScriptedLoopbackProtocol.requests(port: port).contains { $0.httpMethod == "POST" }
        }
        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":13,"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        continuation.yield(Data((cancel + "\n").utf8))
        continuation.finish()

        // The held body never ends on its own, so only the cancellation lets the relay return.
        await waitUntil("the relay returns once the cancelled stream is closed") { finished.value }
        guard finished.value else { return }
        await runTask.value

        XCTAssertEqual(collector.stdoutLines(), [], "a cancelled request is answered by nothing, not even a reply already read")
        XCTAssertEqual(
            ScriptedLoopbackProtocol.requests(port: port).filter { $0.httpMethod == "POST" }.count, 1,
            "the modern era cancels by closing the stream, never by a second POST")
    }

    private func feed(_ text: String, into reader: inout HostedMCPStdioSSEReader) throws -> [String] {
        var messages: [String] = []
        for byte in text.utf8 {
            if let message = try reader.consume(byte) {
                messages.append(String(decoding: message, as: UTF8.self))
            }
        }
        return messages
    }

    func testSSEReader_handsOutWholeJSONRPCMessagesOnly_andOnlyAReplyAnswersTheRequest() throws {
        var reader = HostedMCPStdioSSEReader()
        let comments = try feed(": connected\n\n: keep-alive\n\n", into: &reader)
        XCTAssertEqual(comments, [], "comments dispatch nothing")

        let notification = try feed("event: message\ndata: \(Self.progressFrame(3))\n\n", into: &reader)
        XCTAssertEqual(notification, [Self.progressFrame(3)])
        XCTAssertFalse(reader.deliveredReply, "a notification is relayed, but it answers nothing")

        let notJSONRPC = try feed(
            "data: hello\n\ndata: [1,2]\n\ndata: {\"jsonrpc\":\"1.0\",\"id\":3,\"result\":{}}\n\n", into: &reader)
        XCTAssertEqual(notJSONRPC, [], "an event that is not a JSON-RPC 2.0 object never reaches stdout")
        XCTAssertFalse(reader.deliveredReply)

        let split = try feed("data: {\"jsonrpc\":\"2.0\",\r\ndata: \"id\":3,\"result\":{}}\r\n\r\n", into: &reader)
        XCTAssertEqual(
            split, ["{\"jsonrpc\":\"2.0\",\n\"id\":3,\"result\":{}}"],
            "one event split over two CRLF-terminated data lines is one message")
        XCTAssertTrue(reader.deliveredReply)
        let nothingPending = reader.finish()
        XCTAssertEqual(nothingPending, [], "nothing is pending after a dispatched event")
    }

    func testSSEReader_finish_drainsAnUnterminatedReply_butNeverHalfADocument() throws {
        var unterminatedLine = HostedMCPStdioSSEReader()
        let beforeEOF = try feed("event: message\ndata: \(Self.resultFrame(4))", into: &unterminatedLine)
        XCTAssertEqual(beforeEOF, [])
        let drainedLine = unterminatedLine.finish().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(drainedLine, [Self.resultFrame(4)])
        XCTAssertTrue(unterminatedLine.deliveredReply)

        var undispatchedEvent = HostedMCPStdioSSEReader()
        let beforeBlankLine = try feed("data: \(Self.resultFrame(5))\n", into: &undispatchedEvent)
        XCTAssertEqual(beforeBlankLine, [])
        let drainedEvent = undispatchedEvent.finish().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(drainedEvent, [Self.resultFrame(5)])
        XCTAssertTrue(undispatchedEvent.deliveredReply)

        var truncated = HostedMCPStdioSSEReader()
        let cutMidLine = try feed(#"data: {"jsonrpc":"2.0","id":6,"res"#, into: &truncated)
        XCTAssertEqual(cutMidLine, [])
        let drainedHalf = truncated.finish()
        XCTAssertEqual(drainedHalf, [], "half a document is never handed out")
        XCTAssertFalse(truncated.deliveredReply)

        var empty = HostedMCPStdioSSEReader()
        let drainedNothing = empty.finish()
        XCTAssertEqual(drainedNothing, [])
        XCTAssertFalse(empty.deliveredReply)
    }

    // MARK: - 10. Timeouts Belong to the Stdio Client (§7.3, §7.4)

    func testThePOSTOutlastsTheLongestCallTheServerAdvertises_whileIdentifyStaysShort() throws {
        let waitTool = try XCTUnwrap(HostedMCPCatalog.allTools.first { $0.name == ExternalAutovisorToolNames.waitForEvents })
        let longestWait = TimeInterval(try XCTUnwrap(waitTool.inputSchema.properties?["timeout_seconds"]?.maximum))
        let configuration = URLSessionHostedMCPStdioHTTPClient.makeSessionConfiguration()
        let post = URLSessionHostedMCPStdioHTTPClient.mcpRequest(port: 48_421, headers: [], body: Data())
        let identify = URLSessionHostedMCPStdioHTTPClient.identifyRequest(
            port: 48_421, shortID: "abcd1234", nonceHex: "00ff00ff00ff00ff")

        // The server holds a POST for as long as the call runs — a wait answered as plain JSON is
        // silent until it returns — and the stdio client owns the request's timeout (it cancels).
        // So no ceiling of the relay's may end a call the server can legitimately hold.
        XCTAssertGreaterThan(post.timeoutInterval, longestWait, "a POST's idle ceiling")
        XCTAssertGreaterThan(configuration.timeoutIntervalForRequest, longestWait, "the session's fallback idle ceiling")
        XCTAssertGreaterThan(configuration.timeoutIntervalForResource, longestWait, "the whole-call ceiling")
        // `/identify` is answered from memory: a peer that accepts the connection and then says
        // nothing is not NanoTeams, and must not hold the relay.
        XCTAssertLessThanOrEqual(identify.timeoutInterval, 5)
    }

    // MARK: - 11. No Bearer Token Leaves the Relay Unless `/identify` Proved the Server (§7.4, §10.1)

    func testIdentifyRefusals_neverSendTheBearerToken_andAnswerWithTheirReason() async throws {
        let port: UInt16 = 48_431
        let (agentStore, token, shortID) = try makeAgentStore(label: "Refused Identify Agent")
        let refusals: [(status: Int, reason: String)] = [
            (404, "Agent '\(shortID)' is not registered or has been revoked in NanoTeams."),
            (503, "NanoTeams Keychain storage is temporarily unavailable (HTTP 503)."),
            (500, "Port \(port) failed NanoTeams /identify proof verification (port hijacker or token mismatch). Refusing to send Bearer token."),
        ]
        for (index, refusal) in refusals.enumerated() {
            let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: makeEchoDispatcher())
            let status = refusal.status
            httpClient.identifyOverride = { _, _, _ in (status, Data()) }
            let opener = SpyAppOpener()
            let collector = OutputCollector()
            let relay = HostedMCPStdioRelay(
                configuration: .init(port: port, rawToken: token),
                httpClient: httpClient,
                appOpener: opener,
                writeStdout: { collector.appendStdout($0) },
                writeStderr: { collector.appendStderr($0) }
            )
            await relay.run(stdinChunks: stdinStream([#"{"jsonrpc":"2.0","id":\#(index + 1),"method":"ping"}"#]))

            XCTAssertTrue(httpClient.recordedPosts.isEmpty, "HTTP \(status): the Bearer token must not leave the relay")
            XCTAssertEqual(httpClient.identifyCallCount, 1, "HTTP \(status)")
            XCTAssertEqual(opener.openCallCount, 0, "HTTP \(status): a server that answered needs no launch")
            XCTAssertEqual(
                collector.stdoutLines().map(errorLine),
                [ErrorLine(id: .number(index + 1), code: -32000, message: refusal.reason)],
                "HTTP \(status)")
            XCTAssertTrue(collector.stderrContents().contains(refusal.reason), "HTTP \(status)")
            XCTAssertFalse(collector.stderrContents().contains(token), "HTTP \(status)")
        }
    }

    func testIdentifyTransportFailures_neverSendTheBearerToken_andAnswerWithTheirReason() async throws {
        let port: UInt16 = 48_432
        let (agentStore, token, _) = try makeAgentStore(label: "Failing Identify Agent")
        let failures: [(error: HostedMCPStdioHTTPError, reason: String)] = [
            (.cancelled, "Cancelled while verifying NanoTeams server identity."),
            (.transportFailure("io"), "Failed to verify NanoTeams server identity on 127.0.0.1:\(port)."),
        ]
        for (index, failure) in failures.enumerated() {
            let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: makeEchoDispatcher())
            let error = failure.error
            httpClient.identifyOverride = { _, _, _ in throw error }
            let opener = SpyAppOpener()
            let collector = OutputCollector()
            let relay = HostedMCPStdioRelay(
                configuration: .init(port: port, rawToken: token),
                httpClient: httpClient,
                appOpener: opener,
                writeStdout: { collector.appendStdout($0) },
                writeStderr: { collector.appendStderr($0) }
            )
            await relay.run(stdinChunks: stdinStream([#"{"jsonrpc":"2.0","id":\#(index + 1),"method":"ping"}"#]))

            XCTAssertTrue(httpClient.recordedPosts.isEmpty, "\(error): the Bearer token must not leave the relay")
            XCTAssertEqual(httpClient.identifyCallCount, 1, "\(error)")
            XCTAssertEqual(opener.openCallCount, 0, "\(error): only a refused connection launches the app")
            XCTAssertEqual(
                collector.stdoutLines().map(errorLine),
                [ErrorLine(id: .number(index + 1), code: -32000, message: failure.reason)],
                "\(error)")
        }
    }

    func testPollingAfterAutoOpen_stopsAtARefusalOrACancellation_withoutSendingTheBearerToken() async throws {
        let port: UInt16 = 48_433
        let (agentStore, token, shortID) = try makeAgentStore(label: "Polling Identify Agent")
        for (index, poll) in IdentifyPoll.allCases.enumerated() {
            let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: makeEchoDispatcher())
            let attempts = LockedCounter()
            httpClient.identifyOverride = { _, _, _ in
                // The first attempt finds nothing listening, which is what launches the app.
                guard attempts.increment() > 1 else { throw HostedMCPStdioHTTPError.connectionRefused }
                switch poll {
                case .agentNotRegistered: return (404, Data())
                case .cancelled: throw HostedMCPStdioHTTPError.cancelled
                case .keychainUnavailableThenSleepCancelled: return (503, Data())
                }
            }
            let opener = SpyAppOpener()
            let collector = OutputCollector()
            let relay = HostedMCPStdioRelay(
                configuration: .init(port: port, rawToken: token, launchTimeout: .seconds(2), pollInterval: .milliseconds(10)),
                httpClient: httpClient,
                appOpener: opener,
                sleep: { _ in
                    if poll == .keychainUnavailableThenSleepCancelled { throw CancellationError() }
                },
                writeStdout: { collector.appendStdout($0) },
                writeStderr: { collector.appendStderr($0) }
            )
            await relay.run(stdinChunks: stdinStream([#"{"jsonrpc":"2.0","id":\#(index + 1),"method":"ping"}"#]))

            let reason = poll == .agentNotRegistered
                ? "Agent '\(shortID)' is not registered or has been revoked in NanoTeams."
                : "Cancelled while waiting for NanoTeams to start."
            XCTAssertTrue(httpClient.recordedPosts.isEmpty, "\(poll): the Bearer token must not leave the relay")
            XCTAssertEqual(opener.recordedActivatesFlags, [false], "\(poll)")
            XCTAssertEqual(
                httpClient.identifyCallCount, 2,
                "\(poll): one refused attempt and one poll, then a stop — not polling on to the deadline")
            XCTAssertEqual(
                collector.stdoutLines().map(errorLine),
                [ErrorLine(id: .number(index + 1), code: -32000, message: reason)],
                "\(poll)")
        }
    }

    // MARK: - 12. Framing Edges, Mid-Session Refusals & Early Cancellation (§7.4, E3, E4, E6)

    func testEveryLine_oversizedMalformedOrUnterminated_getsExactlyOneAnswer() async throws {
        let port: UInt16 = 48_434
        let (agentStore, token, _) = try makeAgentStore(label: "Edge Lines Agent")
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: makeEchoDispatcher())
        httpClient.postOverride = { _, _, _, _ in
            HostedMCPStdioHTTPResponse(statusCode: 500, headers: [:], body: Data("plain error".utf8), wasStreamedSSE: false)
        }
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: port, rawToken: token),
            httpClient: httpClient,
            appOpener: SpyAppOpener(),
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        let oversized = String(repeating: "x", count: HostedMCPConstants.maxBodyBytes + 10)
        let cancelWithNothingInFlight = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":999,"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        let ping = #"{"jsonrpc":"2.0","id":60,"method":"ping"}"#
        await relay.run(stdinChunks: stdinStream(
            [oversized, cancelWithNothingInFlight, "not-json", ping], trailingNewline: false))

        let stdout = collector.stdoutLines()
        let answers = stdout.map(errorLine)
        let httpFailure = "NanoTeams Hosted MCP server returned HTTP 500."
        let oversizedRefusal = ErrorLine(id: nil, code: MCPErrorCode.invalidRequest, message: "JSON-RPC frame exceeds maximum size")
        XCTAssertEqual(answers.count, 3, "\(stdout)")
        XCTAssertEqual(
            answers.filter { $0 == oversizedRefusal }.count, 1,
            "the oversized line is refused by the relay itself: \(stdout)")
        XCTAssertEqual(
            answers.filter { $0 == ErrorLine(id: nil, code: -32000, message: httpFailure) }.count, 1,
            "the malformed line is forwarded for the server to judge: \(stdout)")
        XCTAssertEqual(
            answers.filter { $0 == ErrorLine(id: .number(60), code: -32000, message: httpFailure) }.count, 1,
            "the unterminated last line is flushed at EOF: \(stdout)")
        XCTAssertEqual(
            httpClient.recordedPosts.map { String(decoding: $0.body, as: UTF8.self) }.sorted(), ["not-json", ping].sorted(),
            "a modern cancellation with nothing in flight is not forwarded")
    }

    func testARefusedPOST_relaunchesTheAppOnce_provesTheServerAgain_andRetries() async throws {
        let port: UInt16 = 48_435
        let (agentStore, token, _) = try makeAgentStore(label: "Retry Post Agent")
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: makeEchoDispatcher())
        httpClient.postOverride = { [weak httpClient] _, _, _, _ in
            httpClient?.postOverride = nil
            throw HostedMCPStdioHTTPError.connectionRefused
        }
        let opener = SpyAppOpener()
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: port, rawToken: token, launchTimeout: .seconds(2), pollInterval: .milliseconds(10)),
            httpClient: httpClient,
            appOpener: opener,
            sleep: { _ in },
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        await relay.run(stdinChunks: stdinStream([#"{"jsonrpc":"2.0","id":55,"method":"ping"}"#]))

        XCTAssertEqual(opener.recordedActivatesFlags, [false])
        XCTAssertEqual(httpClient.identifyCallCount, 2, "the relaunched server is proven again before the token is resent")
        XCTAssertEqual(httpClient.recordedPosts.count, 2)
        let stdout = collector.stdoutLines()
        XCTAssertEqual(stdout.count, 1, "\(stdout)")
        XCTAssertTrue(stdout.first?.contains(#""id":55"#) == true && stdout.first?.contains(#""result":{}"#) == true, "\(stdout)")
    }

    func testARefusedPOST_whenTheAppCannotBeLaunched_answersUnreachable_withoutRetrying() async throws {
        let port: UInt16 = 48_436
        let (agentStore, token, _) = try makeAgentStore(label: "Unlaunchable Agent")
        let httpClient = InProcessStdioHTTPClient(agentStore: agentStore, dispatcher: makeEchoDispatcher())
        httpClient.postOverride = { _, _, _, _ in throw HostedMCPStdioHTTPError.connectionRefused }
        let opener = SpyAppOpener { throw HostedMCPStdioHTTPError.transportFailure("launch_failed") }
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: port, rawToken: token),
            httpClient: httpClient,
            appOpener: opener,
            sleep: { _ in },
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        await relay.run(stdinChunks: stdinStream([#"{"jsonrpc":"2.0","id":61,"method":"ping"}"#]))

        XCTAssertEqual(opener.recordedActivatesFlags, [false])
        XCTAssertEqual(httpClient.recordedPosts.count, 1, "a server that could not be relaunched is not posted to again")
        XCTAssertEqual(
            collector.stdoutLines().map(errorLine),
            [ErrorLine(id: .number(61), code: -32000, message: "NanoTeams Hosted MCP server on 127.0.0.1:\(port) is unreachable.")])
    }

    func testAModernCancellationThatArrivesDuringIdentify_isHeldUntilTheRequestStarts_thenClosesItsStream() async throws {
        let port: UInt16 = 48_437
        let (agentStore, token, _) = try makeAgentStore(label: "Early Cancel Agent")
        let httpClient = InProcessStdioHTTPClient(
            agentStore: agentStore,
            dispatcher: makeEchoDispatcher(),
            isServerReachable: false
        )
        let sawCancellation = LockedFlag()
        httpClient.postOverride = { _, _, _, _ in
            let deadline = ContinuousClock.now + .seconds(10)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard Task.isCancelled else {
                return HostedMCPStdioHTTPResponse(
                    statusCode: 200, headers: [:], body: Data(#"{"jsonrpc":"2.0","id":77,"result":{}}"#.utf8), wasStreamedSSE: false)
            }
            sawCancellation.set()
            throw HostedMCPStdioHTTPError.cancelled
        }
        // The app comes up only after the cancellation has been read, so it arrives before the
        // request has started and must be held until it does.
        let opener = SpyAppOpener { [weak httpClient] in
            try? await Task.sleep(for: .milliseconds(30))
            httpClient?.isServerReachable = true
        }
        let collector = OutputCollector()
        let relay = HostedMCPStdioRelay(
            configuration: .init(port: port, rawToken: token, launchTimeout: .seconds(5), pollInterval: .milliseconds(10)),
            httpClient: httpClient,
            appOpener: opener,
            writeStdout: { collector.appendStdout($0) },
            writeStderr: { collector.appendStderr($0) }
        )
        let call = #"{"jsonrpc":"2.0","id":77,"method":"tools/call","params":{"name":"folder_status","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":77,"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        await relay.run(stdinChunks: stdinStream([call, cancel]))

        XCTAssertTrue(sawCancellation.value, "the held cancellation must close the request's stream once it has started")
        XCTAssertEqual(httpClient.recordedPosts.count, 1, "the modern era never forwards notifications/cancelled as a POST")
        XCTAssertEqual(collector.stdoutLines(), [], "a cancelled request is answered by nothing")
        XCTAssertEqual(opener.recordedActivatesFlags, [false])
    }
}

