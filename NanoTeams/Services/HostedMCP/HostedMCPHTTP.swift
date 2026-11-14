import Foundation

// MARK: - HTTP Errors (§7.2)

nonisolated enum HostedMCPHTTPError: Error, Sendable, Equatable {
    case malformedRequestLine
    case unsupportedHTTPVersion
    case lineTooLong
    case headersTooLarge
    case tooManyHeaders
    case obsFoldNotAllowed
    case malformedHeader
    case duplicateHeader(String)
    case conflictingLengthHeaders
    case invalidContentLength
    case unsupportedTransferEncoding
    case lengthRequired
    case payloadTooLarge
    case expectationFailed
    case malformedChunkedBody
    case requestTimeout

    var statusCode: Int {
        switch self {
        case .malformedRequestLine,
             .unsupportedHTTPVersion,
             .lineTooLong,
             .tooManyHeaders,
             .obsFoldNotAllowed,
             .malformedHeader,
             .duplicateHeader,
             .conflictingLengthHeaders,
             .invalidContentLength,
             .malformedChunkedBody:
            return 400
        case .requestTimeout:
            return 408
        case .lengthRequired:
            return 411
        case .payloadTooLarge:
            return 413
        case .expectationFailed:
            return 417
        case .headersTooLarge:
            return 431
        case .unsupportedTransferEncoding:
            return 501
        }
    }

    func toResponse() -> HostedMCPHTTPResponse {
        HostedMCPHTTPResponse.empty(statusCode: statusCode)
    }
}

// MARK: - Request & Response Value Types

nonisolated struct HostedMCPHTTPRequestHead: Sendable, Equatable {
    let method: String
    let rawTarget: String
    let path: String
    let query: String?
    let version: String
    let headers: [String: String]

    init(
        method: String,
        rawTarget: String,
        version: String = "HTTP/1.1",
        headers: [String: String]
    ) {
        self.method = method
        self.rawTarget = rawTarget
        if let qIndex = rawTarget.firstIndex(of: "?") {
            self.path = String(rawTarget[..<qIndex])
            let afterQ = rawTarget.index(after: qIndex)
            self.query = String(rawTarget[afterQ...])
        } else {
            self.path = rawTarget
            self.query = nil
        }
        self.version = version
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(headers.count)
        for (key, value) in headers {
            normalized[key.lowercased()] = value
        }
        self.headers = normalized
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

nonisolated struct HostedMCPHTTPRequest: Sendable, Equatable {
    let head: HostedMCPHTTPRequestHead
    let body: Data
}

nonisolated struct HostedMCPHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [(String, String)]
    let body: Data

    init(
        statusCode: Int,
        reasonPhrase: String? = nil,
        headers: [(String, String)] = [],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase ?? Self.defaultReasonPhrase(for: statusCode)
        self.headers = headers
        self.body = body
    }

    static func == (lhs: HostedMCPHTTPResponse, rhs: HostedMCPHTTPResponse) -> Bool {
        lhs.statusCode == rhs.statusCode &&
            lhs.reasonPhrase == rhs.reasonPhrase &&
            lhs.body == rhs.body &&
            lhs.headers.elementsEqual(rhs.headers, by: ==)
    }

    func header(_ name: String) -> String? {
        let target = name.lowercased()
        for (key, value) in headers where key.lowercased() == target {
            return value
        }
        return nil
    }

    static func empty(
        statusCode: Int,
        headers: [(String, String)] = []
    ) -> HostedMCPHTTPResponse {
        HostedMCPHTTPResponse(statusCode: statusCode, headers: headers, body: Data())
    }

    static func json(
        statusCode: Int,
        headers: [(String, String)] = [],
        body: Data
    ) -> HostedMCPHTTPResponse {
        var merged = headers
        if !merged.contains(where: { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            merged.insert(("Content-Type", "application/json"), at: 0)
        }
        return HostedMCPHTTPResponse(statusCode: statusCode, headers: merged, body: body)
    }

    func serialized() -> Data {
        var headerBlock = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        var hasConnection = false
        var hasCacheControl = false
        var hasContentLength = false
        for (name, value) in headers {
            let lower = name.lowercased()
            if lower == "connection" { hasConnection = true }
            if lower == "cache-control" { hasCacheControl = true }
            if lower == "content-length" { hasContentLength = true }
            headerBlock += "\(name): \(value)\r\n"
        }
        if !hasCacheControl {
            headerBlock += "Cache-Control: no-store\r\n"
        }
        if !hasConnection {
            headerBlock += "Connection: close\r\n"
        }
        if !hasContentLength {
            headerBlock += "Content-Length: \(body.count)\r\n"
        }
        headerBlock += "\r\n"
        var out = Data(headerBlock.utf8)
        out.append(body)
        return out
    }

    static func defaultReasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 417: return "Expectation Failed"
        case 421: return "Misdirected Request"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status \(statusCode)"
        }
    }
}

// MARK: - Incremental HTTP/1.1 Request Parser (§7.2)

nonisolated enum HostedMCPHTTPParserStep: Sendable, Equatable {
    case needsMoreData
    case complete(HostedMCPHTTPRequest)
    case failed(HostedMCPHTTPError)
}

/// Incremental HTTP/1.1 request parser with resumable scan offsets.
///
/// Every received byte is scanned once: `scanOffset` resumes where the previous `feed` stopped.
/// The consumed prefix of `buffer` is dropped only when it is at least `compactionFloorBytes`
/// long and no shorter than the unconsumed tail the drop moves, so each byte is also moved at
/// most once and parsing stays linear (`O(n)`) in the bytes received — whatever the chunking.
/// Once `.complete` or `.failed` the parser is terminal: its buffers are released and every
/// later byte is ignored, so a connection carries exactly one request (§7.2).
nonisolated struct HostedMCPHTTPRequestParser: Sendable {

    /// The smallest consumed prefix worth compacting away.
    static let compactionFloorBytes = 4096

    nonisolated struct Configuration: Sendable, Equatable {
        var maxHeaderBytes: Int
        var maxLineBytes: Int
        var maxHeaderCount: Int
        var maxBodyBytes: Int
        var headDeadline: Duration
        var bodyDeadline: Duration

        init(
            maxHeaderBytes: Int = HostedMCPConstants.maxHeaderBytes,
            maxLineBytes: Int = HostedMCPConstants.maxHeaderLineBytes,
            maxHeaderCount: Int = HostedMCPConstants.maxHeaderCount,
            maxBodyBytes: Int = HostedMCPConstants.maxBodyBytes,
            headDeadline: Duration = HostedMCPConstants.defaultHeadDeadline,
            bodyDeadline: Duration = HostedMCPConstants.defaultBodyDeadline
        ) {
            self.maxHeaderBytes = maxHeaderBytes
            self.maxLineBytes = maxLineBytes
            self.maxHeaderCount = maxHeaderCount
            self.maxBodyBytes = maxBodyBytes
            self.headDeadline = headDeadline
            self.bodyDeadline = bodyDeadline
        }
    }

    private enum Phase: Sendable, Equatable {
        case readingHead
        case readingFixedBody(expectedBytes: Int)
        case readingChunkSize
        case readingChunkData(remainingBytes: Int)
        case readingChunkTrailers
        case complete(HostedMCPHTTPRequest)
        case failed(HostedMCPHTTPError)
    }

    let configuration: Configuration

    private var buffer = Data()
    private var scanOffset = 0
    private var lineStartOffset = 0
    private var phase: Phase = .readingHead

    private var method: String?
    private var rawTarget: String?
    private var version: String?
    private var headers: [String: String] = [:]
    private var headerCount = 0
    private var trailerCount = 0
    private var bodyBuffer = Data()
    private var pending100Continue = false

    private(set) var parsedHead: HostedMCPHTTPRequestHead?

    #if DEBUG
    private(set) var _testCompactionCount = 0
    private(set) var _testCompactionMovedByteCount = 0
    var _testBufferedByteCount: Int { buffer.count + bodyBuffer.count }
    #endif

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func take100ContinueRequired() -> Bool {
        guard pending100Continue else { return false }
        pending100Continue = false
        return true
    }

    mutating func feed(_ chunk: Data) -> HostedMCPHTTPParserStep {
        switch phase {
        case .complete(let request):
            return .complete(request)
        case .failed(let error):
            return .failed(error)
        case .readingHead,
             .readingFixedBody,
             .readingChunkSize,
             .readingChunkData,
             .readingChunkTrailers:
            break
        }

        if !chunk.isEmpty {
            buffer.append(chunk)
        }

        while advance() {}

        switch phase {
        case .complete(let request):
            return .complete(request)
        case .failed(let error):
            return .failed(error)
        case .readingHead,
             .readingFixedBody,
             .readingChunkSize,
             .readingChunkData,
             .readingChunkTrailers:
            return .needsMoreData
        }
    }

    // MARK: - State Machine Step

    private mutating func advance() -> Bool {
        switch phase {
        case .readingHead:
            return advanceHead()
        case .readingFixedBody(let expectedBytes):
            return advanceFixedBody(expectedBytes: expectedBytes)
        case .readingChunkSize:
            return advanceChunkSize()
        case .readingChunkData(let remainingBytes):
            return advanceChunkData(remainingBytes: remainingBytes)
        case .readingChunkTrailers:
            return advanceChunkTrailers()
        case .complete, .failed:
            return false
        }
    }

    private mutating func fail(_ error: HostedMCPHTTPError) -> Bool {
        phase = .failed(error)
        releaseBuffers()
        return false
    }

    private mutating func complete(_ request: HostedMCPHTTPRequest) -> Bool {
        phase = .complete(request)
        releaseBuffers()
        return false
    }

    private mutating func releaseBuffers() {
        buffer = Data()
        bodyBuffer = Data()
        scanOffset = 0
        lineStartOffset = 0
    }

    /// Drops the consumed prefix of `buffer` — everything before the current line — once it is
    /// at least `compactionFloorBytes` long and no shorter than the tail the drop moves.
    private mutating func compactConsumedPrefixIfAmortized() {
        let consumed = lineStartOffset
        guard consumed >= Self.compactionFloorBytes, consumed >= buffer.count - consumed else { return }
        buffer.removeSubrange(0..<consumed)
        scanOffset -= consumed
        lineStartOffset = 0
        #if DEBUG
        _testCompactionCount += 1
        _testCompactionMovedByteCount += buffer.count
        #endif
    }

    private mutating func advanceHead() -> Bool {
        guard scanOffset < buffer.count else { return false }

        let byte = buffer[scanOffset]
        let currentLineLength = scanOffset - lineStartOffset

        if currentLineLength > configuration.maxLineBytes {
            return fail(.lineTooLong)
        }
        if scanOffset >= configuration.maxHeaderBytes {
            return fail(.headersTooLarge)
        }

        if byte != 0x0A {
            scanOffset += 1
            return scanOffset < buffer.count
        }

        // Found LF (0x0A); require preceding CR (0x0D).
        guard scanOffset > lineStartOffset, buffer[scanOffset - 1] == 0x0D else {
            return fail(method == nil ? .malformedRequestLine : .malformedHeader)
        }

        let lineEnd = scanOffset - 1
        let lineData = buffer.subdata(in: lineStartOffset..<lineEnd)
        scanOffset += 1
        lineStartOffset = scanOffset

        if lineData.isEmpty {
            return method == nil ? fail(.malformedRequestLine) : finalizeHead()
        }

        if method == nil {
            guard parseRequestLine(lineData) else { return false }
        } else {
            guard parseHeaderLine(lineData) else { return false }
        }
        return scanOffset < buffer.count
    }

    private mutating func parseRequestLine(_ lineData: Data) -> Bool {
        guard !lineData.contains(where: { $0 < 0x20 || $0 == 0x7F }),
              let line = String(data: lineData, encoding: .utf8),
              case let parts = line.split(separator: " ", omittingEmptySubsequences: false),
              parts.count == 3 else {
            return fail(.malformedRequestLine)
        }
        let parsedMethod = String(parts[0])
        let parsedTarget = String(parts[1])
        let parsedVersion = String(parts[2])

        guard !parsedMethod.isEmpty,
              Self.isValidToken(parsedMethod),
              parsedTarget.hasPrefix("/") else {
            return fail(.malformedRequestLine)
        }
        guard parsedVersion == "HTTP/1.1" else {
            return fail(.unsupportedHTTPVersion)
        }

        method = parsedMethod
        rawTarget = parsedTarget
        version = parsedVersion
        return true
    }

    private mutating func parseHeaderLine(_ lineData: Data) -> Bool {
        guard let firstByte = lineData.first else { return false }
        if firstByte == 0x20 || firstByte == 0x09 {
            return fail(.obsFoldNotAllowed)
        }
        guard headerCount < configuration.maxHeaderCount else {
            return fail(.tooManyHeaders)
        }
        headerCount += 1

        guard let colonIndex = lineData.firstIndex(of: 0x3A),
              colonIndex > lineData.startIndex,
              let rawName = String(data: lineData[lineData.startIndex..<colonIndex], encoding: .utf8),
              Self.isValidToken(rawName),
              case let valueData = lineData[lineData.index(after: colonIndex)..<lineData.endIndex],
              !valueData.contains(where: { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7F }),
              let rawValue = String(data: valueData, encoding: .utf8) else {
            return fail(.malformedHeader)
        }

        let lowerName = rawName.lowercased()
        let trimmedValue = Self.trimHTTPWhitespace(rawValue)

        if Self.isSingleValueHeader(lowerName) {
            if headers[lowerName] != nil {
                return fail(.duplicateHeader(lowerName))
            }
            headers[lowerName] = trimmedValue
        } else {
            headers[lowerName] = headers[lowerName].map { "\($0), \(trimmedValue)" } ?? trimmedValue
        }
        return true
    }

    private mutating func finalizeHead() -> Bool {
        let head = HostedMCPHTTPRequestHead(
            method: method ?? "",
            rawTarget: rawTarget ?? "",
            version: version ?? "HTTP/1.1",
            headers: headers
        )
        parsedHead = head
        compactConsumedPrefixIfAmortized()

        if let expectValue = headers["expect"] {
            if expectValue.caseInsensitiveCompare("100-continue") == .orderedSame {
                pending100Continue = true
            } else {
                return fail(.expectationFailed)
            }
        }

        let contentLengthValue = headers["content-length"]
        let transferEncodingValue = headers["transfer-encoding"]

        if contentLengthValue != nil && transferEncodingValue != nil {
            return fail(.conflictingLengthHeaders)
        }

        if let transferEncodingValue {
            guard transferEncodingValue.caseInsensitiveCompare("chunked") == .orderedSame else {
                return fail(.unsupportedTransferEncoding)
            }
            phase = .readingChunkSize
            return scanOffset < buffer.count
        }

        if let contentLengthValue {
            guard let length = Self.parseDecimalSize(contentLengthValue) else {
                return fail(.invalidContentLength)
            }
            guard length <= configuration.maxBodyBytes else {
                return fail(.payloadTooLarge)
            }
            if length == 0 {
                return complete(HostedMCPHTTPRequest(head: head, body: Data()))
            }
            phase = .readingFixedBody(expectedBytes: length)
            return scanOffset < buffer.count
        }

        if head.method == "POST" {
            return fail(.lengthRequired)
        }

        return complete(HostedMCPHTTPRequest(head: head, body: Data()))
    }

    private mutating func advanceFixedBody(expectedBytes: Int) -> Bool {
        guard let head = parsedHead, buffer.count - scanOffset >= expectedBytes else { return false }
        let body = buffer.subdata(in: scanOffset..<(scanOffset + expectedBytes))
        return complete(HostedMCPHTTPRequest(head: head, body: body))
    }

    private mutating func advanceChunkSize() -> Bool {
        guard scanOffset < buffer.count else { return false }
        let currentLineLength = scanOffset - lineStartOffset
        if currentLineLength > configuration.maxLineBytes {
            return fail(.lineTooLong)
        }

        if buffer[scanOffset] != 0x0A {
            scanOffset += 1
            return scanOffset < buffer.count
        }

        guard scanOffset > lineStartOffset, buffer[scanOffset - 1] == 0x0D,
              case let lineData = buffer.subdata(in: lineStartOffset..<(scanOffset - 1)),
              let chunkSize = Self.parseChunkSizeLine(lineData) else {
            return fail(.malformedChunkedBody)
        }
        scanOffset += 1
        lineStartOffset = scanOffset

        guard bodyBuffer.count + chunkSize <= configuration.maxBodyBytes else {
            return fail(.payloadTooLarge)
        }

        phase = chunkSize == 0 ? .readingChunkTrailers : .readingChunkData(remainingBytes: chunkSize)
        return scanOffset < buffer.count
    }

    private mutating func advanceChunkData(remainingBytes: Int) -> Bool {
        let available = buffer.count - scanOffset
        guard available >= remainingBytes + 2 else { return false }

        let crIndex = scanOffset + remainingBytes
        let lfIndex = crIndex + 1
        guard buffer[crIndex] == 0x0D, buffer[lfIndex] == 0x0A else {
            return fail(.malformedChunkedBody)
        }

        bodyBuffer.append(buffer[scanOffset..<crIndex])
        scanOffset = lfIndex + 1
        lineStartOffset = scanOffset
        compactConsumedPrefixIfAmortized()

        phase = .readingChunkSize
        return scanOffset < buffer.count
    }

    private mutating func advanceChunkTrailers() -> Bool {
        guard scanOffset < buffer.count else { return false }
        let currentLineLength = scanOffset - lineStartOffset
        if currentLineLength > configuration.maxLineBytes {
            return fail(.lineTooLong)
        }

        if buffer[scanOffset] != 0x0A {
            scanOffset += 1
            return scanOffset < buffer.count
        }

        guard scanOffset > lineStartOffset, buffer[scanOffset - 1] == 0x0D else {
            return fail(.malformedChunkedBody)
        }

        let lineData = buffer.subdata(in: lineStartOffset..<(scanOffset - 1))
        scanOffset += 1
        lineStartOffset = scanOffset

        if lineData.isEmpty {
            guard let head = parsedHead else { return false }
            return complete(HostedMCPHTTPRequest(head: head, body: bodyBuffer))
        }

        // Non-empty trailer line: validate basic header syntax and count cap.
        guard trailerCount < configuration.maxHeaderCount else {
            return fail(.tooManyHeaders)
        }
        trailerCount += 1
        guard let first = lineData.first, first != 0x20, first != 0x09,
              let colon = lineData.firstIndex(of: 0x3A), colon > lineData.startIndex else {
            return fail(.malformedChunkedBody)
        }
        return scanOffset < buffer.count
    }

    // MARK: - Lexical Helpers

    private static func isSingleValueHeader(_ lowerName: String) -> Bool {
        switch lowerName {
        case "host", "content-length", "transfer-encoding", "authorization", "origin", "content-type", "expect":
            return true
        default:
            return lowerName.hasPrefix("mcp-")
        }
    }

    private static func isValidToken(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { byte in
            byte == 0x21 || (byte >= 0x23 && byte <= 0x27) ||
                byte == 0x2A || byte == 0x2B || byte == 0x2D || byte == 0x2E ||
                byte == 0x5E || byte == 0x5F || byte == 0x60 || byte == 0x7C || byte == 0x7E ||
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        }
    }

    static func trimHTTPWhitespace(_ value: String) -> String {
        var scalars = value.unicodeScalars[...]
        while let first = scalars.first, first == " " || first == "\t" {
            scalars = scalars.dropFirst()
        }
        while let last = scalars.last, last == " " || last == "\t" {
            scalars = scalars.dropLast()
        }
        return String(scalars)
    }

    private static func parseDecimalSize(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        var result = 0
        for byte in text.utf8 {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            let digit = Int(byte - 0x30)
            let (multiplied, overflow1) = result.multipliedReportingOverflow(by: 10)
            let (added, overflow2) = multiplied.addingReportingOverflow(digit)
            if overflow1 || overflow2 { return nil }
            result = added
        }
        return result
    }

    private static func parseChunkSizeLine(_ lineData: Data) -> Int? {
        guard !lineData.isEmpty,
              !lineData.contains(where: { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7F }) else {
            return nil
        }
        let sizeSlice = lineData.firstIndex(of: 0x3B).map { lineData[lineData.startIndex..<$0] } ?? lineData[...]
        guard !sizeSlice.isEmpty else { return nil }
        var result = 0
        for byte in sizeSlice {
            guard let digit = HostedMCPHex.digitValue(byte) else { return nil }
            let (multiplied, overflow1) = result.multipliedReportingOverflow(by: 16)
            let (added, overflow2) = multiplied.addingReportingOverflow(digit)
            if overflow1 || overflow2 { return nil }
            result = added
        }
        return result
    }
}

// MARK: - ASCII Hex (§6, §7.2)

/// The one hex alphabet of the hosted server — ASCII `0-9`, `A-F`, `a-f` — for chunk sizes,
/// `/identify` nonces and token short ids alike.
///
/// `Character.isHexDigit` and `hexDigitValue` also accept the fullwidth digits and letters
/// (`U+FF10…FF19`, `U+FF21…FF26`, `U+FF41…FF46`). Spelled through them, a fullwidth nonce
/// passed the unauthenticated `/identify` guard and was hashed into a proof.
nonisolated enum HostedMCPHex {

    /// The value of one ASCII hex digit, or `nil` for any other byte.
    static func digitValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x46: return Int(byte - 0x41) + 10
        case 0x61...0x66: return Int(byte - 0x61) + 10
        default: return nil
        }
    }

    /// `true` when `text` is non-empty and every byte of it is an ASCII hex digit.
    static func isDigits(_ text: some StringProtocol) -> Bool {
        !text.utf8.isEmpty && text.utf8.allSatisfy { digitValue($0) != nil }
    }

    /// The `GET /identify` nonce — what the request guard routes and `HostedMCPAgentStore.identify`
    /// answers: an even number of ASCII hex digits within the configured length bounds.
    static func isIdentifyNonce(_ text: String) -> Bool {
        let length = text.utf8.count
        return length >= HostedMCPConstants.minIdentifyNonceHexCharacters
            && length <= HostedMCPConstants.maxIdentifyNonceHexCharacters
            && length.isMultiple(of: 2)
            && isDigits(text)
    }
}

// MARK: - Ordered Request Guard (§7.2)

nonisolated enum HostedMCPTokenVerificationResult: Sendable, Equatable {
    case authenticated(AgentIdentity)
    case invalidToken
    case storageFailure(String)
}

nonisolated enum HostedMCPRoute: Sendable, Equatable {
    case mcp(agent: AgentIdentity)
    case identify(agentID: String, nonceHex: String)
}

nonisolated struct HostedMCPGuardRejection: Sendable, Equatable {
    let response: HostedMCPHTTPResponse
    let reason: String
    let rejectedOrigin: String?

    init(
        response: HostedMCPHTTPResponse,
        reason: String,
        rejectedOrigin: String? = nil
    ) {
        self.response = response
        self.reason = reason
        self.rejectedOrigin = rejectedOrigin
    }
}

nonisolated enum HostedMCPGuardDecision: Sendable, Equatable {
    case accepted(HostedMCPRoute)
    case rejected(HostedMCPGuardRejection)
}

/// Enforces the strict §7.2 check sequence:
/// 1. Path (`/mcp` or `/identify`) → else `404`
/// 2. `Host` ∈ {`127.0.0.1:P`, `localhost:P`, `[::1]:P`} → else `421` (never touches token)
/// 3. `Origin` absent or loopback `http`/`https` → else `403` with verbatim rejected Origin
/// 4. `Authorization: Bearer <token>` → `401` (`WWW-Authenticate: Bearer realm="nanoteams"`) or `503` on Keychain failure
/// 5. Method `POST` → else `405` (`Allow: POST`)
/// 6. `Content-Type: application/json` (any `charset`) → else `415`
nonisolated enum HostedMCPRequestGuard {

    private static func reject(
        _ statusCode: Int,
        reason: String,
        headers: [(String, String)] = [],
        rejectedOrigin: String? = nil
    ) -> HostedMCPGuardDecision {
        .rejected(
            HostedMCPGuardRejection(
                response: .empty(statusCode: statusCode, headers: headers),
                reason: reason,
                rejectedOrigin: rejectedOrigin
            )
        )
    }

    static func evaluate(
        head: HostedMCPHTTPRequestHead,
        serverPort: UInt16,
        verifyToken: (String) -> HostedMCPTokenVerificationResult
    ) -> HostedMCPGuardDecision {
        // 1. Path check
        let isMCPRoute = head.path == HostedMCPConstants.mcpPath
        let isIdentifyRoute = head.path == HostedMCPConstants.identifyPath
        guard isMCPRoute || isIdentifyRoute else {
            return reject(404, reason: "unknown_path")
        }

        // 2. Host header check (421 Misdirected Request — before Origin and before token!)
        guard let rawHost = head.header("host"),
              isAllowedLoopbackHostHeader(rawHost, serverPort: serverPort) else {
            return reject(421, reason: "invalid_host")
        }

        // 3. Origin header check (403 Forbidden — before token!)
        if let rawOrigin = head.header("origin") {
            guard isAllowedOriginHeader(rawOrigin) else {
                return reject(403, reason: "forbidden_origin", rejectedOrigin: rawOrigin)
            }
        }

        if isIdentifyRoute {
            return evaluateIdentifyRoute(head: head)
        }

        // 4. Authorization: Bearer <token>
        guard let rawAuth = head.header("authorization"),
              let bearerToken = extractBearerToken(from: rawAuth) else {
            return reject(
                401,
                reason: "missing_or_malformed_bearer",
                headers: [("WWW-Authenticate", HostedMCPConstants.wwwAuthenticateBearerRealm)]
            )
        }

        let agent: AgentIdentity
        switch verifyToken(bearerToken) {
        case .authenticated(let verifiedAgent):
            agent = verifiedAgent
        case .invalidToken:
            return reject(
                401,
                reason: "invalid_token",
                headers: [("WWW-Authenticate", HostedMCPConstants.wwwAuthenticateBearerRealm)]
            )
        case .storageFailure(let detail):
            return reject(503, reason: "keychain_unavailable:\(detail)")
        }

        // 5. Method check (POST only; GET/OPTIONS/HEAD/DELETE -> 405 Allow: POST)
        guard head.method == "POST" else {
            return reject(405, reason: "method_not_allowed:\(head.method)", headers: [("Allow", "POST")])
        }

        // 6. Content-Type: application/json (with any charset parameter)
        guard let rawContentType = head.header("content-type"),
              isJSONContentType(rawContentType) else {
            return reject(415, reason: "unsupported_media_type")
        }

        return .accepted(.mcp(agent: agent))
    }

    // MARK: - Guard Helpers

    private static func isAllowedLoopbackHostHeader(_ rawHost: String, serverPort: UInt16) -> Bool {
        let trimmed = HostedMCPHTTPRequestParser.trimHTTPWhitespace(rawHost).lowercased()
        let portSuffix = ":\(serverPort)"
        return trimmed == "127.0.0.1\(portSuffix)"
            || trimmed == "localhost\(portSuffix)"
            || trimmed == "[::1]\(portSuffix)"
    }

    private static func isAllowedOriginHeader(_ rawOrigin: String) -> Bool {
        let trimmed = HostedMCPHTTPRequestParser.trimHTTPWhitespace(rawOrigin)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("null") != .orderedSame,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host else {
            return false
        }
        return LoopbackHost.isLoopback(host)
    }

    private static func extractBearerToken(from rawAuth: String) -> String? {
        let trimmed = HostedMCPHTTPRequestParser.trimHTTPWhitespace(rawAuth)
        guard let spaceIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }
        let scheme = String(trimmed[..<spaceIndex])
        guard scheme.caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        let remainder = String(trimmed[trimmed.index(after: spaceIndex)...])
        let token = HostedMCPHTTPRequestParser.trimHTTPWhitespace(remainder)
        return token.isEmpty ? nil : token
    }

    private static func isJSONContentType(_ rawContentType: String) -> Bool {
        let mediaPart = rawContentType.firstIndex(of: ";").map { String(rawContentType[..<$0]) } ?? rawContentType
        let normalized = HostedMCPHTTPRequestParser.trimHTTPWhitespace(mediaPart).lowercased()
        return normalized == "application/json"
    }

    private static func evaluateIdentifyRoute(head: HostedMCPHTTPRequestHead) -> HostedMCPGuardDecision {
        guard head.method == "GET" else {
            return reject(405, reason: "identify_method_not_allowed", headers: [("Allow", "GET")])
        }
        guard let components = URLComponents(string: head.rawTarget),
              let queryItems = components.queryItems else {
            return reject(400, reason: "identify_missing_query")
        }
        var agentID: String?
        var nonceHex: String?
        for item in queryItems {
            if item.name == "agent", let value = item.value, !value.isEmpty {
                agentID = value
            } else if item.name == "nonce", let value = item.value, !value.isEmpty {
                nonceHex = value
            }
        }
        guard let agentID,
              let nonceHex,
              HostedMCPHex.isIdentifyNonce(nonceHex) else {
            return reject(400, reason: "identify_invalid_parameters")
        }
        return .accepted(.identify(agentID: agentID, nonceHex: nonceHex))
    }
}

// MARK: - SSE Writer (§7.2, §7.3)

nonisolated enum HostedMCPSSEWriter {

    static func responseHeaderData(
        statusCode: Int = 200,
        additionalHeaders: [(String, String)] = []
    ) -> Data {
        let phrase = HostedMCPHTTPResponse.defaultReasonPhrase(for: statusCode)
        var text = "HTTP/1.1 \(statusCode) \(phrase)\r\n"
        text += "Content-Type: text/event-stream\r\n"
        text += "Cache-Control: no-store\r\n"
        text += "Connection: close\r\n"
        text += "X-Accel-Buffering: no\r\n"
        for (name, value) in additionalHeaders {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    static func primingCommentData() -> Data {
        Data(": connected\n\n".utf8)
    }

    static func keepAliveCommentData() -> Data {
        Data(": keep-alive\n\n".utf8)
    }

    /// Formats a JSON-RPC frame as an SSE `message` event without an `id:` field (§7.3).
    static func messageFrameData(_ jsonData: Data) -> Data {
        let payload = String(decoding: jsonData, as: UTF8.self)
        var text = "event: message\n"
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            text += "data: \(line)\n"
        }
        text += "\n"
        return Data(text.utf8)
    }
}

// MARK: - Background Queue Connection Driver (D8)

/// Drives one HTTP/1.1 request-response lifecycle on a dedicated background `DispatchQueue`.
///
/// Evaluates `HostedMCPRequestGuard` as soon as the header block completes so an invalid
/// `Host` (`421`) or `Origin` (`403`) or `Authorization` (`401`/`503`) fails immediately
/// before sending `100 Continue` or waiting for the request body. A completed request is handed
/// to `onRequest` exactly once; bytes the peer sends while it is answered are ignored.
nonisolated final class HostedMCPHTTPConnectionDriver: @unchecked Sendable {

    private let queue: DispatchQueue
    private let serverPort: UInt16
    private var parser: HostedMCPHTTPRequestParser
    private let verifyToken: @Sendable (String) -> HostedMCPTokenVerificationResult
    private let sendBytes: @Sendable (Data) -> Void
    private let closeConnection: @Sendable () -> Void
    private let onRejection: (@Sendable (HostedMCPGuardRejection) -> Void)?
    private let onParseError: (@Sendable (HostedMCPHTTPError) -> Void)?
    private let onRequest: @Sendable (
        HostedMCPRoute,
        HostedMCPHTTPRequest,
        @escaping @Sendable (HostedMCPHTTPResponse) -> Void
    ) -> Void

    private var headTimer: DispatchSourceTimer?
    private var bodyTimer: DispatchSourceTimer?
    private var acceptedRoute: HostedMCPRoute?
    private var hasDispatched = false
    private var isFinished = false

    /// Whether this connection is still waiting for the end of the HTTP header block (`\r\n\r\n`).
    var isReadingHead: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return parser.parsedHead == nil && !isFinished
    }

    /// Authenticated agent ID once the request head has passed `HostedMCPRequestGuard`.
    var authenticatedAgentID: UUID? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard case .mcp(let agent) = acceptedRoute else { return nil }
        return agent.id
    }

    init(
        queue: DispatchQueue,
        serverPort: UInt16,
        configuration: HostedMCPHTTPRequestParser.Configuration = .init(),
        verifyToken: @escaping @Sendable (String) -> HostedMCPTokenVerificationResult,
        sendBytes: @escaping @Sendable (Data) -> Void,
        closeConnection: @escaping @Sendable () -> Void,
        onRejection: (@Sendable (HostedMCPGuardRejection) -> Void)? = nil,
        onParseError: (@Sendable (HostedMCPHTTPError) -> Void)? = nil,
        onRequest: @escaping @Sendable (
            HostedMCPRoute,
            HostedMCPHTTPRequest,
            @escaping @Sendable (HostedMCPHTTPResponse) -> Void
        ) -> Void
    ) {
        self.queue = queue
        self.serverPort = serverPort
        self.parser = HostedMCPHTTPRequestParser(configuration: configuration)
        self.verifyToken = verifyToken
        self.sendBytes = sendBytes
        self.closeConnection = closeConnection
        self.onRejection = onRejection
        self.onParseError = onParseError
        self.onRequest = onRequest
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished else { return }
        scheduleHeadDeadline()
    }

    func receive(_ chunk: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished, !hasDispatched else { return }

        let step = parser.feed(chunk)

        // As soon as the request head is available, run the ordered guard before
        // sending 100 Continue or reporting body-framing errors like 411/413.
        if acceptedRoute == nil, let head = parser.parsedHead {
            cancelHeadTimer()
            let decision = HostedMCPRequestGuard.evaluate(
                head: head,
                serverPort: serverPort,
                verifyToken: verifyToken
            )
            switch decision {
            case .accepted(let route):
                acceptedRoute = route
            case .rejected(let rejection):
                onRejection?(rejection)
                finishWithResponse(rejection.response)
                return
            }
        }

        switch step {
        case .needsMoreData:
            if acceptedRoute != nil {
                if parser.take100ContinueRequired() {
                    sendBytes(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                }
                if bodyTimer == nil {
                    scheduleBodyDeadline()
                }
            }
        case .complete(let request):
            cancelHeadTimer()
            cancelBodyTimer()
            guard let route = acceptedRoute else { return }
            if parser.take100ContinueRequired() {
                sendBytes(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }
            hasDispatched = true
            onRequest(route, request) { [weak self] response in
                guard let self else { return }
                self.queue.async {
                    self.finishWithResponse(response)
                }
            }
        case .failed(let error):
            cancelHeadTimer()
            cancelBodyTimer()
            onParseError?(error)
            finishWithResponse(error.toResponse())
        }
    }

    /// Sends a raw SSE chunk on `queue` while the stream is active.
    func sendStreamChunk(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished else { return }
        sendBytes(data)
    }

    /// Completes an SSE stream on `queue` and closes the connection without sending a second HTTP header.
    func finishStream() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished else { return }
        isFinished = true
        cancelHeadTimer()
        cancelBodyTimer()
        closeConnection()
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished else { return }
        isFinished = true
        cancelHeadTimer()
        cancelBodyTimer()
        closeConnection()
    }

    // MARK: - Timers & Completion

    private func scheduleHeadDeadline() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let nanos = Self.nanoseconds(for: parser.configuration.headDeadline)
        timer.schedule(deadline: .now() + .nanoseconds(nanos))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isFinished else { return }
            self.onParseError?(.requestTimeout)
            self.finishWithResponse(HostedMCPHTTPError.requestTimeout.toResponse())
        }
        headTimer = timer
        timer.resume()
    }

    private func scheduleBodyDeadline() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let nanos = Self.nanoseconds(for: parser.configuration.bodyDeadline)
        timer.schedule(deadline: .now() + .nanoseconds(nanos))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isFinished else { return }
            self.onParseError?(.requestTimeout)
            self.finishWithResponse(HostedMCPHTTPError.requestTimeout.toResponse())
        }
        bodyTimer = timer
        timer.resume()
    }

    private func cancelHeadTimer() {
        headTimer?.cancel()
        headTimer = nil
    }

    private func cancelBodyTimer() {
        bodyTimer?.cancel()
        bodyTimer = nil
    }

    private func finishWithResponse(_ response: HostedMCPHTTPResponse) {
        guard !isFinished else { return }
        isFinished = true
        cancelHeadTimer()
        cancelBodyTimer()
        sendBytes(response.serialized())
        closeConnection()
    }

    private static func nanoseconds(for duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        let secNanos = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let attoNanos = attoseconds / 1_000_000_000
        if secNanos.overflow { return Int.max }
        let total = secNanos.partialValue.addingReportingOverflow(attoNanos)
        if total.overflow || total.partialValue <= 0 { return 1_000_000 }
        return Int(clamping: total.partialValue)
    }
}
