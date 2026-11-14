import AppKit
import CryptoKit
import Darwin
import Foundation

// MARK: - App Opener Seam (§7.4, E6)

/// Opens NanoTeams in the background without stealing focus when the stdio relay finds
/// the local Hosted MCP server unreachable.
nonisolated protocol HostedMCPAppOpening: Sendable {
    func openApplication(activates: Bool) async throws
}

/// A NanoTeams that is already running, as LaunchServices lists it.
nonisolated struct HostedMCPRunningApp: Equatable, Sendable {
    /// When it was launched — `nil` when LaunchServices does not say.
    let launchedAt: Date?
}

/// One copy of the app as LaunchServices lists it — what `NSWorkspaceHostedMCPAppOpener` reads
/// of an `NSRunningApplication`, so the choice among them is a function of values.
nonisolated struct HostedMCPListedApp: Equatable, Sendable {
    let processID: pid_t
    let isTerminated: Bool
    let launchDate: Date?
}

/// Why the opener did not open the app.
nonisolated enum HostedMCPAppOpenerError: Error, Equatable, Sendable {
    /// A NanoTeams is already running — its server not answering yet, or not at all. A second copy
    /// would be a second process on the folder it opens (`WorkFolderInstanceLock` refuses it, F6
    /// C1). The relay waits for the one running while it may still be starting (D-M18 R5).
    case alreadyRunning(HostedMCPRunningApp)
}

nonisolated struct NSWorkspaceHostedMCPAppOpener: HostedMCPAppOpening {
    let appBundleURL: URL?
    let runningInstance: @Sendable () -> HostedMCPRunningApp?
    let openWorkspaceApp: @Sendable (URL, NSWorkspace.OpenConfiguration) async throws -> Void

    init(
        appBundleURL: URL? = Self.resolveDefaultAppBundleURL(),
        runningInstance: @escaping @Sendable () -> HostedMCPRunningApp? = Self.anotherRunningNanoTeams,
        openWorkspaceApp: @escaping @Sendable (URL, NSWorkspace.OpenConfiguration) async throws -> Void = { url, config in
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    ) {
        self.appBundleURL = appBundleURL
        self.runningInstance = runningInstance
        self.openWorkspaceApp = openWorkspaceApp
    }

    /// The NanoTeams other than this process that is running, if any — read off LaunchServices by
    /// bundle identifier, so a copy at another path counts too (a Debug build beside an installed
    /// one: the 8 November pair). The relays themselves are command-line processes of the same
    /// binary and LaunchServices does not list them (measured 2026-11-12: seven `--mcp-stdio`
    /// relays alive, one application listed); this process is excluded by PID all the same. Of
    /// several, the latest launched — the one most likely still starting.
    static func anotherRunningNanoTeams() -> HostedMCPRunningApp? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let listed = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map {
            HostedMCPListedApp(processID: $0.processIdentifier, isTerminated: $0.isTerminated, launchDate: $0.launchDate)
        }
        return otherRunningApp(among: listed, excluding: ProcessInfo.processInfo.processIdentifier)
    }

    /// The choice `anotherRunningNanoTeams` makes of what LaunchServices listed: every copy but
    /// `me` that has not terminated; `nil` when none is left. Its launch moment is the latest of
    /// theirs — and unknown (`nil`) when any of them does not say, since the one that does not
    /// may be the one still starting.
    static func otherRunningApp(among listed: [HostedMCPListedApp], excluding me: pid_t) -> HostedMCPRunningApp? {
        let others = listed.filter { $0.processID != me && !$0.isTerminated }
        guard !others.isEmpty else { return nil }
        let dates = others.compactMap(\.launchDate)
        return HostedMCPRunningApp(launchedAt: dates.count == others.count ? dates.max() : nil)
    }

    static func resolveDefaultAppBundleURL(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL
    ) -> URL? {
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        var current = executableURL ?? bundleURL
        while current.path != "/" && !current.path.isEmpty {
            if current.pathExtension == "app" {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    static func makeOpenConfiguration(activates: Bool) -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates
        config.addsToRecentItems = false
        // Its default, spelled. Not the whole guard: whether LaunchServices counts a copy at another
        // path as the app already running is not measured, so `runningInstance` asks first.
        config.createsNewApplicationInstance = false
        return config
    }

    func openApplication(activates: Bool) async throws {
        guard let appBundleURL else {
            throw HostedMCPStdioHTTPError.transportFailure("app_bundle_not_found")
        }
        if let running = runningInstance() { throw HostedMCPAppOpenerError.alreadyRunning(running) }
        try await openWorkspaceApp(appBundleURL, Self.makeOpenConfiguration(activates: activates))
    }
}

// MARK: - HTTP Client Seam (§7.4)

nonisolated enum HostedMCPStdioHTTPError: Error, Equatable, Sendable {
    case connectionRefused
    case cancelled
    case transportFailure(String)
}

nonisolated struct HostedMCPStdioHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let wasStreamedSSE: Bool
}

nonisolated protocol HostedMCPStdioHTTPClient: Sendable {
    func getIdentify(
        port: UInt16,
        shortID: String,
        nonceHex: String
    ) async throws -> (statusCode: Int, body: Data)

    func postMCP(
        port: UInt16,
        headers: [(String, String)],
        body: Data,
        onSSEFrame: @escaping @Sendable (Data) async -> Void
    ) async throws -> HostedMCPStdioHTTPResponse
}

/// Production HTTP client backed by `URLSession` talking to `http://127.0.0.1:<port>`.
nonisolated final class URLSessionHostedMCPStdioHTTPClient: HostedMCPStdioHTTPClient {
    private let urlSession: URLSession

    /// `session` is the seam tests use to serve the client from a `URLProtocol` instead of a
    /// socket; production always builds it from `makeSessionConfiguration()`.
    init(
        session: URLSession = URLSession(configuration: URLSessionHostedMCPStdioHTTPClient.makeSessionConfiguration())
    ) {
        self.urlSession = session
    }

    /// `GET /identify` is answered from memory, so a short wait for it is safe: a peer that
    /// accepts the connection and then says nothing is not NanoTeams, and must not hold the relay.
    static let identifyTimeout: TimeInterval = 5

    /// Both ceilings of a `POST /mcp`: the wait for its next byte and its whole life. The server
    /// holds a call for as long as it runs — a `wait_for_events` answered as plain JSON is silent
    /// until it returns, one promoted to SSE is silent between keep-alives, and the longest lasts
    /// its whole `timeout_seconds`, `HostedMCPConstants.maxWaitSeconds` at most — while the stdio
    /// client owns that request's timeout and cancels it. So the relay must never be the one to end
    /// a call: both ceilings are the client call timeout every generated configuration also uses,
    /// a margin above the longest wait the server advertises. They were 5 s and 120 s until
    /// 2026-11-07, and every call that took more than 5 s to send its first byte came back to the
    /// stdio client as `transport failure (timed_out)`.
    static let mcpRequestTimeout = TimeInterval(HostedMCPConstants.clientCallTimeoutSeconds)

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = mcpRequestTimeout
        config.timeoutIntervalForResource = mcpRequestTimeout
        config.waitsForConnectivity = false
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return config
    }

    static func identifyRequest(port: UInt16, shortID: String, nonceHex: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = HostedMCPConstants.identifyPath
        components.queryItems = [
            URLQueryItem(name: "agent", value: shortID),
            URLQueryItem(name: "nonce", value: nonceHex),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        request.timeoutInterval = identifyTimeout
        return request
    }

    static func mcpRequest(port: UInt16, headers: [(String, String)], body: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(HostedMCPConstants.mcpPath)")!)
        request.timeoutInterval = mcpRequestTimeout
        request.httpMethod = "POST"
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        return request
    }

    func getIdentify(
        port: UInt16,
        shortID: String,
        nonceHex: String
    ) async throws -> (statusCode: Int, body: Data) {
        let request = Self.identifyRequest(port: port, shortID: shortID, nonceHex: nonceHex)
        do {
            let (data, response) = try await urlSession.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
            return (statusCode, data)
        } catch let error {
            throw Self.mapError(error)
        }
    }

    func postMCP(
        port: UInt16,
        headers: [(String, String)],
        body: Data,
        onSSEFrame: @escaping @Sendable (Data) async -> Void
    ) async throws -> HostedMCPStdioHTTPResponse {
        let request = Self.mcpRequest(port: port, headers: headers, body: body)
        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 500
            let normalizedHeaders = http.map { Self.normalizeHeaders($0.allHeaderFields) } ?? [:]
            let contentType = normalizedHeaders["content-type"]?.lowercased() ?? ""

            if contentType.hasPrefix("text/event-stream") {
                try await Self.relayEventStream(bytes, onSSEFrame: onSSEFrame)
                return HostedMCPStdioHTTPResponse(
                    statusCode: statusCode,
                    headers: normalizedHeaders,
                    body: Data(),
                    wasStreamedSSE: true
                )
            } else {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte)
                }
                return HostedMCPStdioHTTPResponse(
                    statusCode: statusCode,
                    headers: normalizedHeaders,
                    body: data,
                    wasStreamedSSE: false
                )
            }
        } catch let error {
            throw Self.mapError(error)
        }
    }

    /// Relays an SSE response body: every JSON-RPC message it carries goes to `onSSEFrame` in
    /// order, the one the body ended on without its blank line included.
    ///
    /// The request's reply decides how the body may end. Once the reply has been relayed, the
    /// request is answered however the body ends — cleanly or with an error. Before that, an end
    /// is a failure the caller must report, because nothing else will ever answer that request
    /// id: a clean end throws `stream_ended_without_reply`, an error is rethrown. A cancelled
    /// request relays nothing more and rethrows the cancellation.
    static func relayEventStream<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        onSSEFrame: @escaping @Sendable (Data) async -> Void
    ) async throws where Bytes.Element == UInt8 {
        var reader = HostedMCPStdioSSEReader()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                if let message = try reader.consume(byte) {
                    await onSSEFrame(message)
                }
            }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw error
            }
            for message in reader.finish() {
                await onSSEFrame(message)
            }
            guard reader.deliveredReply else { throw error }
            return
        }
        for message in reader.finish() {
            await onSSEFrame(message)
        }
        guard reader.deliveredReply else {
            throw HostedMCPStdioHTTPError.transportFailure("stream_ended_without_reply")
        }
    }

    static func isJSONRPCResponsePayload(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return object["result"] != nil || object["error"] != nil
    }

    private static func normalizeHeaders(_ raw: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in raw {
            if let k = key as? String, let v = value as? String {
                result[k.lowercased()] = v
            }
        }
        return result
    }

    static func mapError(_ error: Error) -> HostedMCPStdioHTTPError {
        if error is CancellationError || Task.isCancelled {
            return .cancelled
        }
        if let stdioError = error as? HostedMCPStdioHTTPError {
            return stdioError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .cannotConnectToHost:
                return .connectionRefused
            case .networkConnectionLost:
                return .transportFailure("connection_lost")
            case .timedOut:
                return .transportFailure("timed_out")
            default:
                return .transportFailure("url_error_\(urlError.errorCode)")
            }
        }
        return .transportFailure("io_error")
    }
}

// MARK: - SSE Body Reader (§7.4)

/// The stdio relay's reading of one SSE response body: one JSON-RPC message per event, framed by
/// `SSEFrameParser`.
///
/// Only a whole JSON-RPC message is ever handed out — the same test the relay applies to a plain
/// JSON body before writing it. A body cut mid-line leaves half a document in the parser, and on
/// stdout that would be a line the stdio client cannot parse, so it is dropped and the request is
/// answered by the relay's own error instead.
nonisolated struct HostedMCPStdioSSEReader {
    private var parser = SSEFrameParser()
    private var pendingLine = Data()

    /// Whether a reply — a JSON-RPC `result` or `error` — has been handed out.
    private(set) var deliveredReply = false

    /// Feeds one byte of the body; returns the message the byte completed, if any.
    mutating func consume(_ byte: UInt8) throws -> Data? {
        guard byte == 0x0A else {
            pendingLine.append(byte)
            return nil
        }
        let line = String(decoding: pendingLine, as: UTF8.self)
        pendingLine.removeAll(keepingCapacity: true)
        return message(in: try parser.consume(line: line))
    }

    /// Drains what the body ended without terminating: its last line, when no newline followed
    /// it, then the event no blank line dispatched. A server ends a stream that way on a clean
    /// close, and dropping that event loses the reply the request was waiting for
    /// (`SSEFrameParser.finish`).
    mutating func finish() -> [Data] {
        var messages: [Data] = []
        if !pendingLine.isEmpty {
            let line = String(decoding: pendingLine, as: UTF8.self)
            pendingLine.removeAll()
            if let message = message(in: try? parser.consume(line: line)) {
                messages.append(message)
            }
        }
        if let message = message(in: parser.finish()) {
            messages.append(message)
        }
        return messages
    }

    private mutating func message(in frame: SSEFrameParser.Frame?) -> Data? {
        guard let frame else { return nil }
        let payload = Data(frame.data.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard HostedMCPStdioRelay.isJSONRPCEnvelope(payload) else { return nil }
        if URLSessionHostedMCPStdioHTTPClient.isJSONRPCResponsePayload(payload) {
            deliveredReply = true
        }
        return payload
    }
}

// MARK: - Stdio Relay (§7.4)

/// Native `--mcp-stdio` bridge that translates line-delimited JSON-RPC on `stdin`/`stdout`
/// into Streamable HTTP requests against NanoTeams's local Hosted MCP server (`127.0.0.1:<port>`).
///
/// Security invariants:
/// - Reads the agent token from the file `--token-file` names — the one NanoTeams wrote for the
///   agent (`HostedMCPClientTokenFile`), private to the user and refused otherwise — and from
///   nowhere else: not the Keychain (running the binary grants nothing without a secret the
///   caller can already read), not `NANOTEAMS_TOKEN` (any process of the user, a role's
///   sandboxed `bash` included, reads another's environment — #375; the launcher scrubs a stray
///   one in place, `NanoTeamsLauncher.scrubEnvironmentVariable`). No released build ever handed
///   out a configuration that passes it.
/// - Verifies `GET /identify` (`HMAC-SHA256` proof over the SHA-256 token verifier) **before**
///   sending the Bearer token over the wire; refuses to send the token on any proof mismatch.
/// - Writes only JSON-RPC lines to `stdout`; all diagnostic messages go to `stderr`.
nonisolated final class HostedMCPStdioRelay: @unchecked Sendable {

    struct Configuration: Sendable {
        var port: UInt16
        var rawToken: String?
        /// Why `rawToken` is missing, when a token file was named and refused — the answer to
        /// every request instead of the generic `missingTokenMessage`.
        var tokenProblem: String?
        var launchTimeout: Duration
        var pollInterval: Duration

        init(
            port: UInt16 = HostedMCPConstants.defaultPort,
            rawToken: String? = nil,
            tokenProblem: String? = nil,
            launchTimeout: Duration = .seconds(30),
            pollInterval: Duration = .milliseconds(250)
        ) {
            self.port = port
            self.rawToken = rawToken
            self.tokenProblem = tokenProblem
            self.launchTimeout = launchTimeout
            self.pollInterval = pollInterval
        }
    }

    /// What every request is answered with when the bridge has no token and no file said why.
    static let missingTokenMessage =
        "Missing agent token. Give the bridge --token-file with the file NanoTeams wrote for this agent."

    private let configuration: Configuration
    private let httpClient: HostedMCPStdioHTTPClient
    private let appOpener: HostedMCPAppOpening
    private let sleep: @Sendable (Duration) async throws -> Void
    private let writeStdout: @Sendable (Data) -> Void
    private let writeStderr: @Sendable (String) -> Void

    private let stateLock = NSLock()
    private var isServerIdentified = false
    private var inFlightIdentifyTask: Task<IdentifyOutcome, Never>?
    private var rememberedSessionID: String?
    private var rememberedLegacyVersion: String?
    private var inFlightByRequestID: [JSONRPCID: InFlightRequest] = [:]
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    private final class InFlightRequest: @unchecked Sendable {
        let requestID: JSONRPCID
        let isModern: Bool
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var started = false
        private var startedContinuations: [CheckedContinuation<Void, Never>] = []
        private var cancelledByClient = false

        init(requestID: JSONRPCID, isModern: Bool) {
            self.requestID = requestID
            self.isModern = isModern
        }

        var isCancelledByClient: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelledByClient
        }

        func setTask(_ task: Task<Void, Never>) {
            var shouldCancel = false
            lock.lock()
            self.task = task
            shouldCancel = self.cancelledByClient
            lock.unlock()
            if shouldCancel {
                task.cancel()
            }
        }

        func markStarted() {
            let waiters: [CheckedContinuation<Void, Never>]
            lock.lock()
            started = true
            waiters = startedContinuations
            startedContinuations.removeAll()
            lock.unlock()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func waitUntilStarted() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if started {
                    lock.unlock()
                    continuation.resume()
                } else {
                    startedContinuations.append(continuation)
                    lock.unlock()
                }
            }
        }

        func cancelFromClient() {
            let currentTask: Task<Void, Never>?
            lock.lock()
            cancelledByClient = true
            currentTask = task
            lock.unlock()
            currentTask?.cancel()
        }
    }

    init(
        configuration: Configuration,
        httpClient: HostedMCPStdioHTTPClient = URLSessionHostedMCPStdioHTTPClient(),
        appOpener: HostedMCPAppOpening = NSWorkspaceHostedMCPAppOpener(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        writeStdout: @escaping @Sendable (Data) -> Void = HostedMCPStdioRelay.defaultWriteStdout,
        writeStderr: @escaping @Sendable (String) -> Void = HostedMCPStdioRelay.defaultWriteStderr
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.appOpener = appOpener
        self.sleep = sleep
        self.writeStdout = writeStdout
        self.writeStderr = writeStderr
    }

    // MARK: - CLI Argument & Environment Resolution (§7.4)

    private static let methodHeaderName = "Mcp-Method"
    private static let nameHeaderName = "Mcp-Name"
    private static let sessionIDHeaderName = "Mcp-Session-Id"

    /// Resolves the target port from `--port <N>` CLI flag, `NANOTEAMS_MCP_PORT`, or configured `UserDefaults` port.
    static func resolvePort(
        arguments: [String],
        environment: [String: String],
        configuredPort: Int? = nil
    ) -> UInt16 {
        if let cliPort = parseCLIPort(arguments: arguments) {
            return cliPort
        }
        return HostedMCPEnvironment.resolveServerPort(
            environment: environment,
            configuredPort: configuredPort ?? Int(HostedMCPConstants.defaultPort)
        )
    }

    static func parsePort(_ rawValue: String) -> UInt16? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed),
              parsed >= HostedMCPConstants.minValidPort,
              parsed <= HostedMCPConstants.maxValidPort
        else {
            return nil
        }
        return UInt16(parsed)
    }

    static func parseCLIPort(arguments: [String]) -> UInt16? {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--port", index + 1 < arguments.count {
                if let parsed = parsePort(arguments[index + 1]) {
                    return parsed
                }
                index += 2
                continue
            }
            if arg.hasPrefix("--port=") {
                let value = String(arg.dropFirst("--port=".count))
                if let parsed = parsePort(value) {
                    return parsed
                }
            }
            index += 1
        }
        return nil
    }

    /// Parses a raw `ntm_<shortID>_<secret>` bearer token into its short ID and secret components.
    static func parseBearerToken(_ rawToken: String) -> (shortID: String, secret: String)? {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(HostedMCPConstants.tokenPrefix) else { return nil }
        let remainder = trimmed.dropFirst(HostedMCPConstants.tokenPrefix.count)
        guard let underscoreIndex = remainder.firstIndex(of: "_") else { return nil }
        let shortID = String(remainder[..<underscoreIndex])
        let secret = String(remainder[remainder.index(after: underscoreIndex)...])
        // The server's hex rule (`HostedMCPHex`): ASCII only, counted in bytes.
        guard shortID.utf8.count == HostedMCPConstants.shortIDCharacterCount,
              HostedMCPHex.isDigits(shortID),
              !secret.isEmpty
        else {
            return nil
        }
        return (shortID, secret)
    }

    static let tokenFileFlag = "--token-file"

    /// The path after `--token-file` (or in `--token-file=<path>`), if the arguments name one.
    static func tokenFilePath(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == tokenFileFlag, index + 1 < arguments.count {
                return arguments[index + 1]
            }
            // ASCII flag: its UTF-8 length is its length in characters.
            let spelledWithValue = tokenFileFlag + "="
            if argument.hasPrefix(spelledWithValue) {
                return String(argument.dropFirst(spelledWithValue.utf8.count))
            }
        }
        return nil
    }

    /// The token from `--token-file`, or why there is none. Without the flag there is no token
    /// and no particular reason (`missingTokenMessage` answers). `NANOTEAMS_TOKEN` is never read:
    /// until 2026-11-08 it was the fallback, and a token in an environment is one a role's
    /// sandboxed `bash` reads (#375).
    static func resolveToken(arguments: [String]) -> (value: String?, problem: String?) {
        guard let path = tokenFilePath(in: arguments) else { return (nil, nil) }
        return readTokenFile(atPath: path)
    }

    /// Largest token file read: a token is ~60 bytes, so anything near this is not one.
    static let maxTokenFileBytes = 4096

    /// Reads the token file NanoTeams wrote. Refused unless it is a regular file (not a link),
    /// owned by this user and closed to everyone else — the mode NanoTeams writes it with; a
    /// looser file is one another account or a copy elsewhere may have read.
    static func readTokenFile(atPath path: String) -> (value: String?, problem: String?) {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                // Revoking an agent removes its file: the commonest way here, and then there is
                // nothing to reissue (review 2026-11-08).
                return (nil, "The token file \(path) does not exist: its agent was revoked in NanoTeams, or its token was never written there. Add the agent again in NanoTeams, or reissue its token.")
            }
            return (nil, "The token file \(path) cannot be opened.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return (nil, "The token file \(path) is not a regular file.")
        }
        guard info.st_uid == getuid() else {
            return (nil, "The token file \(path) belongs to another user.")
        }
        guard info.st_mode & 0o077 == 0 else {
            return (nil, "The token file \(path) can be read by other users. Make it private to you (chmod 600).")
        }
        guard info.st_size <= maxTokenFileBytes else {
            return (nil, "The token file \(path) is too large to hold a token.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            offset += count
        }
        let token = String(decoding: bytes[..<offset], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return (nil, "The token file \(path) is empty. Reissue the agent's token in NanoTeams.")
        }
        // A file that holds something else — Claude Code's headers file, an edited one — gets
        // its own answer, not "give the bridge --token-file" when it was given one.
        guard parseBearerToken(token) != nil else {
            return (nil, "The token file \(path) does not hold an agent token. Point --token-file at the file NanoTeams wrote for this agent, or reissue its token.")
        }
        return (token, nil)
    }

    // MARK: - Cryptographic `/identify` Proof Verification (§7.1, §7.4)

    static func expectedIdentifyProof(secret: String, nonceHex: String) -> String {
        let verifierDigest = SHA256.hash(data: Data(secret.utf8))
        let key = SymmetricKey(data: Data(verifierDigest))
        let message = Data((HostedMCPConstants.identifyDomainSeparator + nonceHex.lowercased()).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    static func verifyIdentifyResponse(
        statusCode: Int,
        body: Data,
        secret: String,
        nonceHex: String
    ) -> Bool {
        guard statusCode == 200,
              let payload = try? JSONDecoder().decode(HostedMCPIdentifyPayload.self, from: body),
              payload.app == HostedMCPConstants.serverTitle
        else {
            return false
        }
        let expected = expectedIdentifyProof(secret: secret, nonceHex: nonceHex)
        let candidate = payload.proof.lowercased()
        guard candidate.utf8.count == expected.utf8.count else { return false }
        var diff: UInt8 = 0
        for (lhs, rhs) in zip(candidate.utf8, expected.utf8) {
            diff |= lhs ^ rhs
        }
        return diff == 0
    }

    // MARK: - Run Loop

    /// Runs the relay over an `AsyncStream<Data>` of stdin chunks until EOF.
    func run(stdinChunks: AsyncStream<Data>) async {
        var framer = JSONRPCLineFramer()
        for await chunk in stdinChunks {
            if Task.isCancelled { break }
            let events = framer.append(chunk)
            for event in events {
                await handleFramerEvent(event)
            }
        }
        for event in framer.finish() {
            await handleFramerEvent(event)
        }
        await waitForActiveTasks()
    }

    /// Blocking entry point used when launched with `--mcp-stdio`: reads `stdinFD` until EOF and
    /// returns once every request it carried has been answered. The launcher passes the real
    /// standard input and the production client and opener; tests pass a pipe and doubles, so a
    /// test can never reach a listening server or launch the app it runs inside.
    static func runWithFileDescriptors(
        port: UInt16,
        rawToken: String?,
        tokenProblem: String? = nil,
        stdinFD: Int32,
        httpClient: HostedMCPStdioHTTPClient = URLSessionHostedMCPStdioHTTPClient(),
        appOpener: HostedMCPAppOpening = NSWorkspaceHostedMCPAppOpener(),
        writeStdout: @escaping @Sendable (Data) -> Void = HostedMCPStdioRelay.defaultWriteStdout,
        writeStderr: @escaping @Sendable (String) -> Void = HostedMCPStdioRelay.defaultWriteStderr
    ) -> Int32 {
        let relay = HostedMCPStdioRelay(
            configuration: Configuration(port: port, rawToken: rawToken, tokenProblem: tokenProblem),
            httpClient: httpClient,
            appOpener: appOpener,
            writeStdout: writeStdout,
            writeStderr: writeStderr
        )

        let stdinStream = AsyncStream<Data> { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = Darwin.read(stdinFD, &buffer, buffer.count)
                    if count > 0 {
                        continuation.yield(Data(buffer[0..<count]))
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        continuation.finish()
                        break
                    }
                }
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await relay.run(stdinChunks: stdinStream)
            semaphore.signal()
        }
        semaphore.wait()
        return 0
    }

    // MARK: - Frame Handling

    private func handleFramerEvent(_ event: JSONRPCLineFramer.Event) async {
        switch event {
        case .lineTooLong:
            logStderr("Refusing oversized stdin line exceeding \(HostedMCPConstants.maxBodyBytes) bytes.")
            emitSynthesizedError(
                id: nil,
                code: MCPErrorCode.invalidRequest,
                message: "JSON-RPC frame exceeds maximum size"
            )
        case .line(let lineData):
            await handleIncomingLine(lineData)
        }
    }

    private func registerInFlightRequest(for parsed: InspectedFrame) -> InFlightRequest? {
        guard let reqID = parsed.id else { return nil }
        let entry = InFlightRequest(requestID: reqID, isModern: parsed.isModern)
        stateLock.withLock {
            inFlightByRequestID[reqID] = entry
        }
        return entry
    }

    private func registerActiveTask(_ task: Task<Void, Never>, id: UUID) {
        stateLock.withLock {
            activeTasks[id] = task
        }
    }

    private func unregisterActiveTask(id: UUID, requestID: JSONRPCID?) {
        stateLock.withLock {
            if let requestID {
                inFlightByRequestID.removeValue(forKey: requestID)
            }
            activeTasks.removeValue(forKey: id)
        }
    }

    private func lookupInFlightRequest(id: JSONRPCID?) -> InFlightRequest? {
        guard let id else { return nil }
        return stateLock.withLock {
            inFlightByRequestID[id]
        }
    }

    private func isCurrentlyIdentified() -> Bool {
        stateLock.withLock { isServerIdentified }
    }

    private func handleIncomingLine(_ lineData: Data) async {
        let parsed = Self.inspectFrame(lineData)

        // Handle client-side `notifications/cancelled` (E3, E4).
        if parsed.method == MCPWire.cancelledNotification, parsed.id == nil {
            await handleClientCancellation(lineData: lineData, parsed: parsed)
            return
        }

        // Handshake and discovery frames (`initialize`, `notifications/initialized`, `server/discover`)
        // are awaited inline so `/identify` verification and negotiated session/protocol state complete
        // before subsequent requests are dispatched concurrently.
        if parsed.method == MCPWire.initializeMethod
            || parsed.method == MCPWire.initializedNotification
            || parsed.method == MCPWire.discoverMethod
        {
            await dispatchLineToServer(lineData: lineData, parsed: parsed, inFlight: nil)
            return
        }

        let taskID = UUID()
        let registeredInFlight = registerInFlightRequest(for: parsed)

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.unregisterActiveTask(id: taskID, requestID: parsed.id)
            }
            await self.dispatchLineToServer(
                lineData: lineData,
                parsed: parsed,
                inFlight: registeredInFlight
            )
        }
        registerActiveTask(task, id: taskID)
        registeredInFlight?.setTask(task)
    }

    private func handleClientCancellation(lineData: Data, parsed: InspectedFrame) async {
        let targetEntry = lookupInFlightRequest(id: parsed.cancelledRequestID)

        if let targetEntry {
            await targetEntry.waitUntilStarted()
            if targetEntry.isModern || parsed.isModern {
                // Modern era (2026-07-28): cancel by closing the in-flight HTTP stream (E3, E4).
                targetEntry.cancelFromClient()
                return
            }
        } else if parsed.isModern {
            return
        }

        // Legacy era: forward `notifications/cancelled` via POST /mcp (202 Accepted).
        await dispatchLineToServer(lineData: lineData, parsed: parsed, inFlight: nil)
    }

    private func dispatchLineToServer(
        lineData: Data,
        parsed: InspectedFrame,
        inFlight: InFlightRequest?
    ) async {
        guard let rawToken = configuration.rawToken,
              let parsedToken = Self.parseBearerToken(rawToken)
        else {
            inFlight?.markStarted()
            let message = configuration.tokenProblem ?? Self.missingTokenMessage
            logStderr(message)
            if parsed.expectsResponse {
                emitSynthesizedError(id: parsed.id, code: -32000, message: message)
            }
            return
        }

        switch await ensureServerIdentified(parsedToken: parsedToken) {
        case .identified:
            break
        case .failed(let reason):
            inFlight?.markStarted()
            logStderr(reason)
            if parsed.expectsResponse {
                emitSynthesizedError(id: parsed.id, code: -32000, message: reason)
            }
            return
        }

        let headers = buildOutboundHeaders(for: parsed, bearerToken: rawToken)
        inFlight?.markStarted()

        do {
            let response = try await performPostWithAutoOpenRetry(
                headers: headers,
                body: lineData,
                parsedToken: parsedToken
            ) { [weak self] ssePayload in
                self?.emitRawJSONRPCLine(ssePayload)
            }

            if parsed.method == MCPWire.initializeMethod {
                captureLegacySessionFromInitialize(response: response)
            }

            guard !response.wasStreamedSSE else { return }
            if !response.body.isEmpty, Self.isJSONRPCEnvelope(response.body) {
                emitRawJSONRPCLine(response.body)
            } else if response.statusCode != 202,
                      response.statusCode >= 400 || !response.body.isEmpty,
                      parsed.expectsResponse
            {
                emitSynthesizedError(
                    id: parsed.id,
                    code: -32000,
                    message: "NanoTeams Hosted MCP server returned HTTP \(response.statusCode)."
                )
            }
        } catch {
            switch URLSessionHostedMCPStdioHTTPClient.mapError(error) {
            case .cancelled:
                // Stream closed intentionally for modern cancellation — emit nothing.
                return
            case .connectionRefused:
                let msg = "NanoTeams Hosted MCP server on 127.0.0.1:\(configuration.port) is unreachable."
                logStderr(msg)
                if parsed.expectsResponse, inFlight?.isCancelledByClient != true {
                    emitSynthesizedError(id: parsed.id, code: -32000, message: msg)
                }
            case .transportFailure(let code):
                let msg = "Hosted MCP transport failure (\(code))."
                logStderr(msg)
                if parsed.expectsResponse, inFlight?.isCancelledByClient != true {
                    emitSynthesizedError(id: parsed.id, code: -32000, message: msg)
                }
            }
        }
    }

    private func performPostWithAutoOpenRetry(
        headers: [(String, String)],
        body: Data,
        parsedToken: (shortID: String, secret: String),
        onSSEFrame: @escaping @Sendable (Data) async -> Void
    ) async throws -> HostedMCPStdioHTTPResponse {
        do {
            return try await httpClient.postMCP(
                port: configuration.port,
                headers: headers,
                body: body,
                onSSEFrame: onSSEFrame
            )
        } catch HostedMCPStdioHTTPError.connectionRefused {
            guard case .identified = await ensureServerIdentified(parsedToken: parsedToken, forceReopen: true) else {
                throw HostedMCPStdioHTTPError.connectionRefused
            }
            return try await httpClient.postMCP(
                port: configuration.port,
                headers: headers,
                body: body,
                onSSEFrame: onSSEFrame
            )
        }
    }

    // MARK: - `/identify` Pre-Check & Auto-Open Polling (§7.4, E6)

    private enum IdentifyOutcome: Sendable {
        case identified
        case failed(String)
    }

    private func clearInFlightIdentifyTask() {
        stateLock.withLock {
            inFlightIdentifyTask = nil
        }
    }

    private func ensureServerIdentified(
        parsedToken: (shortID: String, secret: String),
        forceReopen: Bool = false
    ) async -> IdentifyOutcome {
        let taskToAwait: Task<IdentifyOutcome, Never> = stateLock.withLock {
            if !forceReopen, isServerIdentified {
                return Task { .identified }
            }
            if forceReopen {
                isServerIdentified = false
            }
            if let existing = inFlightIdentifyTask {
                return existing
            }
            let task = Task { [weak self] () -> IdentifyOutcome in
                guard let self else {
                    return .failed("Relay deallocated while verifying NanoTeams server identity.")
                }
                defer {
                    self.clearInFlightIdentifyTask()
                }
                if forceReopen {
                    return await self.openAppAndPollIdentify(parsedToken: parsedToken)
                }
                return await self.performSingleIdentifyOrAutoOpen(parsedToken: parsedToken)
            }
            inFlightIdentifyTask = task
            return task
        }
        return await taskToAwait.value
    }

    private func performSingleIdentifyOrAutoOpen(
        parsedToken: (shortID: String, secret: String)
    ) async -> IdentifyOutcome {
        if isCurrentlyIdentified() {
            return .identified
        }

        let nonce = Self.generateNonceHex()
        do {
            let (status, body) = try await httpClient.getIdentify(
                port: configuration.port,
                shortID: parsedToken.shortID,
                nonceHex: nonce
            )
            return evaluateIdentifyResult(
                statusCode: status,
                body: body,
                parsedToken: parsedToken,
                nonceHex: nonce
            )
        } catch HostedMCPStdioHTTPError.connectionRefused {
            return await openAppAndPollIdentify(parsedToken: parsedToken)
        } catch HostedMCPStdioHTTPError.cancelled {
            return .failed("Cancelled while verifying NanoTeams server identity.")
        } catch {
            return .failed("Failed to verify NanoTeams server identity on 127.0.0.1:\(configuration.port).")
        }
    }

    /// runtime-prompt
    ///
    /// What the agent's call is told when NanoTeams runs but its server does not answer: the relay
    /// starts no second NanoTeams (`HostedMCPAppOpenerError.alreadyRunning`), and the person is the
    /// one who can turn the server on.
    nonisolated static func serverNotAnsweringMessage(port: UInt16) -> String {
        "NanoTeams is running, but its External Agents server is not answering on 127.0.0.1:\(port), "
            + "so no second NanoTeams was started. Ask the person to turn on External Agents in the "
            + "NanoTeams that is running, on port \(port)."
    }

    /// How long a NanoTeams that is already running may still be starting: what is left of the
    /// launch window it was launched with. Zero once that window is over — its server is off, not
    /// late — and the whole window when its launch time is unknown.
    nonisolated static func remainingStartupWindow(
        of running: HostedMCPRunningApp, launchTimeout: Duration, now: Date = Date()
    ) -> Duration {
        guard let launchedAt = running.launchedAt else { return launchTimeout }
        let elapsed = Duration.milliseconds(Int64(max(0, now.timeIntervalSince(launchedAt)) * 1000))
        return elapsed >= launchTimeout ? .zero : launchTimeout - elapsed
    }

    private func openAppAndPollIdentify(
        parsedToken: (shortID: String, secret: String)
    ) async -> IdentifyOutcome {
        var window = configuration.launchTimeout
        var timeoutMessage =
            "NanoTeams Hosted MCP server on 127.0.0.1:\(configuration.port) did not become reachable within timeout."
        do {
            try await appOpener.openApplication(activates: false)
        } catch HostedMCPAppOpenerError.alreadyRunning(let running) {
            // Nothing is launched. LaunchServices lists an app from the moment it launches, before
            // its server listens — a login-item launch, another relay's a moment ago — so the
            // relay waits out what is left of that app's launch window. Until 2026-11-12 it
            // failed at once, and an agent starting beside another always did (D-M18 R5).
            window = Self.remainingStartupWindow(of: running, launchTimeout: configuration.launchTimeout)
            timeoutMessage = Self.serverNotAnsweringMessage(port: configuration.port)
            guard window > .zero else { return .failed(timeoutMessage) }
        } catch {
            return .failed("NanoTeams is not running and could not be launched automatically.")
        }

        let clock = ContinuousClock()
        let deadline = clock.now + window

        while clock.now < deadline {
            if Task.isCancelled {
                return .failed("Cancelled while waiting for NanoTeams to start.")
            }
            let nonce = Self.generateNonceHex()
            do {
                let (status, body) = try await httpClient.getIdentify(
                    port: configuration.port,
                    shortID: parsedToken.shortID,
                    nonceHex: nonce
                )
                let outcome = evaluateIdentifyResult(
                    statusCode: status,
                    body: body,
                    parsedToken: parsedToken,
                    nonceHex: nonce
                )
                switch outcome {
                case .identified:
                    return .identified
                case .failed(let reason):
                    // Immediate abort on proof mismatch / unknown agent — never send Bearer token!
                    if status != 503 {
                        return .failed(reason)
                    }
                }
            } catch HostedMCPStdioHTTPError.cancelled {
                return .failed("Cancelled while waiting for NanoTeams to start.")
            } catch {
                // Server not listening yet or transient startup error; continue polling until deadline.
            }

            do {
                try await sleep(configuration.pollInterval)
            } catch {
                return .failed("Cancelled while waiting for NanoTeams to start.")
            }
        }

        return .failed(timeoutMessage)
    }

    private func evaluateIdentifyResult(
        statusCode: Int,
        body: Data,
        parsedToken: (shortID: String, secret: String),
        nonceHex: String
    ) -> IdentifyOutcome {
        if statusCode == 404 {
            return .failed("Agent '\(parsedToken.shortID)' is not registered or has been revoked in NanoTeams.")
        }
        if statusCode == 503 {
            return .failed("NanoTeams Keychain storage is temporarily unavailable (HTTP 503).")
        }
        guard Self.verifyIdentifyResponse(
            statusCode: statusCode,
            body: body,
            secret: parsedToken.secret,
            nonceHex: nonceHex
        ) else {
            return .failed(
                "Port \(configuration.port) failed NanoTeams /identify proof verification (port hijacker or token mismatch). Refusing to send Bearer token."
            )
        }
        stateLock.withLock {
            isServerIdentified = true
        }
        return .identified
    }

    // MARK: - Header Construction & Session State (§7.3, §7.4)

    private func buildOutboundHeaders(
        for parsed: InspectedFrame,
        bearerToken: String
    ) -> [(String, String)] {
        var headers: [(String, String)] = [
            ("Authorization", "Bearer \(bearerToken)"),
        ]

        if parsed.isModern, let modernVersion = parsed.modernProtocolVersion {
            headers.append((MCPConstants.protocolVersionHeader, modernVersion))
            if parsed.id != nil, let method = parsed.method, !method.isEmpty {
                headers.append((Self.methodHeaderName, method))
                if method == MCPWire.toolsCallMethod, let toolName = parsed.toolName, !toolName.isEmpty {
                    headers.append((Self.nameHeaderName, StreamableHTTPTransport.headerValue(toolName)))
                }
            }
            return headers
        }

        if parsed.method == MCPWire.initializeMethod {
            return headers
        }

        let (sessionID, legacyVersion): (String?, String) = stateLock.withLock {
            (
                rememberedSessionID,
                rememberedLegacyVersion ?? MCPConstants.legacyProtocolVersion
            )
        }

        headers.append((MCPConstants.protocolVersionHeader, legacyVersion))
        if let sessionID, !sessionID.isEmpty {
            headers.append((Self.sessionIDHeaderName, sessionID))
        }
        return headers
    }

    private func captureLegacySessionFromInitialize(response: HostedMCPStdioHTTPResponse) {
        let headerSession = response.headers[Self.sessionIDHeaderName.lowercased()]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headerVersion = response.headers[MCPConstants.protocolVersionHeader.lowercased()]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var bodyVersion: String?
        if let json = try? JSONDecoder().decode(JSONValue.self, from: response.body),
           case .object(let root) = json,
           case .object(let resultObj) = root["result"],
           case .string(let ver) = resultObj["protocolVersion"]
        {
            bodyVersion = ver.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        stateLock.withLock {
            if let headerSession, !headerSession.isEmpty {
                rememberedSessionID = headerSession
            }
            if let ver = headerVersion ?? bodyVersion, !ver.isEmpty {
                rememberedLegacyVersion = ver
            }
        }
    }

    private func snapshotActiveTasks() -> [Task<Void, Never>] {
        stateLock.withLock {
            Array(activeTasks.values)
        }
    }

    private func waitForActiveTasks() async {
        while true {
            let tasks = snapshotActiveTasks()
            guard !tasks.isEmpty else { break }
            for task in tasks {
                await task.value
            }
        }
    }

    // MARK: - Frame Inspection & Output Helpers

    private struct InspectedFrame: Sendable {
        var id: JSONRPCID?
        var method: String?
        var toolName: String?
        var modernProtocolVersion: String?
        var cancelledRequestID: JSONRPCID?
        var isMalformedOrInvalid: Bool

        var isModern: Bool {
            modernProtocolVersion != nil
        }

        var expectsResponse: Bool {
            id != nil || isMalformedOrInvalid
        }
    }

    private static func parseJSONRPCID(_ raw: JSONValue?) -> JSONRPCID? {
        switch raw {
        case .string(let s): return .string(s)
        case .int(let n): return .number(n)
        default: return nil
        }
    }

    private static func inspectFrame(_ data: Data) -> InspectedFrame {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = value
        else {
            return InspectedFrame(isMalformedOrInvalid: true)
        }

        let id = parseJSONRPCID(obj["id"])
        let method = obj["method"]?.stringValue
        let paramsObj = obj["params"]?.objectValue
        let metaObj = paramsObj?["_meta"]?.objectValue
        let modernVersion = metaObj?[MCPWire.protocolVersionMetaKey]?.stringValue
        let toolName = paramsObj?["name"]?.stringValue
        let cancelledID = method == MCPWire.cancelledNotification ? parseJSONRPCID(paramsObj?["requestId"]) : nil

        let hasValidVersion = obj["jsonrpc"]?.stringValue == "2.0"
        return InspectedFrame(
            id: id,
            method: method,
            toolName: toolName,
            modernProtocolVersion: modernVersion,
            cancelledRequestID: cancelledID,
            isMalformedOrInvalid: !hasValidVersion || (method?.isEmpty != false)
        )
    }

    /// What may be written to stdout: a JSON object carrying `"jsonrpc": "2.0"`. One test for a
    /// plain JSON reply and for every SSE event (`HostedMCPStdioSSEReader`).
    fileprivate static func isJSONRPCEnvelope(_ data: Data) -> Bool {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = value
        else {
            return false
        }
        return obj["jsonrpc"]?.stringValue == "2.0"
    }

    private static func generateNonceHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func emitRawJSONRPCLine(_ payload: Data) {
        writeStdout(JSONRPCLineFramer.formatLine(payload))
    }

    private func emitSynthesizedError(id: JSONRPCID?, code: Int, message: String) {
        let error = JSONRPCError(code: code, message: message)
        let data = JSONRPCCodec.encodeError(error, id: id)
        emitRawJSONRPCLine(data)
    }

    private func logStderr(_ message: String) {
        var sanitized = message
        if let rawToken = configuration.rawToken, !rawToken.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: rawToken, with: "<redacted>")
            if let parsed = Self.parseBearerToken(rawToken) {
                sanitized = sanitized.replacingOccurrences(of: parsed.secret, with: "<redacted>")
            }
        }
        writeStderr("[NanoTeams --mcp-stdio] \(sanitized)\n")
    }

    private static let ioLock = NSLock()

    static func writeToFileDescriptor(_ fd: Int32, data: Data) {
        ioLock.lock()
        defer { ioLock.unlock() }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let rc = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                if rc > 0 {
                    written += rc
                } else if rc < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    static let defaultWriteStdout: @Sendable (Data) -> Void = { data in
        writeToFileDescriptor(STDOUT_FILENO, data: data)
        Darwin.fflush(Darwin.stdout)
    }

    static let defaultWriteStderr: @Sendable (String) -> Void = { text in
        writeToFileDescriptor(STDERR_FILENO, data: Data(text.utf8))
        Darwin.fflush(Darwin.stderr)
    }
}
