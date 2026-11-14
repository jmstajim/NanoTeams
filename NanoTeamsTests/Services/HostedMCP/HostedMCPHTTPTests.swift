import Foundation
import XCTest

@testable import NanoTeams

final class HostedMCPHTTPTests: XCTestCase {

    private let testPort: UInt16 = 47321
    private let validAgent = AgentIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        label: "Claude Code"
    )

    // MARK: - Parser Matrix (§7.2)

    func testParserIncrementalSingleByteFeedAndQueryStringTarget() throws {
        var parser = HostedMCPHTTPRequestParser()
        let raw =
            "POST /mcp?client=claude HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Authorization: Bearer ntm_test_secret\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: 17\r\n" +
            "\r\n" +
            #"{"jsonrpc":"2.0"}"#
        let bytes = Data(raw.utf8)

        var completed: HostedMCPHTTPRequest?
        for index in bytes.indices {
            let step = parser.feed(bytes[index...index])
            if index < bytes.count - 1 {
                if case .complete = step {
                    XCTFail("completed before final byte at \(index)")
                }
            } else {
                guard case .complete(let request) = step else {
                    return XCTFail("expected complete request on final byte, got \(step)")
                }
                completed = request
            }
        }

        let request = try XCTUnwrap(completed)
        XCTAssertEqual(request.head.method, "POST")
        XCTAssertEqual(request.head.rawTarget, "/mcp?client=claude")
        XCTAssertEqual(request.head.path, HostedMCPConstants.mcpPath)
        XCTAssertEqual(request.head.query, "client=claude")
        XCTAssertEqual(request.head.header("HOST"), "127.0.0.1:47321")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), #"{"jsonrpc":"2.0"}"#)
    }

    func testParserRejectsBadRequestLines() {
        let badLines = [
            "POST\r\n\r\n",
            "POST /mcp\r\n\r\n",
            "POST /mcp HTTP/1.0\r\nHost: 127.0.0.1:47321\r\n\r\n",
            "POST mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\n\r\n",
            "POST /mcp HTTP/1.1\nHost: 127.0.0.1:47321\r\n\r\n",
            "POST /mcp\u{0007} HTTP/1.1\r\nHost: 127.0.0.1:47321\r\n\r\n",
        ]

        for raw in badLines {
            var parser = HostedMCPHTTPRequestParser()
            let state = parser.feed(Data(raw.utf8))
            guard case .failed(let error) = state else {
                XCTFail("expected failure for \(raw.debugDescription), got \(state)")
                continue
            }
            XCTAssertEqual(error.statusCode, 400, "unexpected status for \(raw.debugDescription)")
        }
    }

    func testParserRejectsLineOver8KiBAndHeadersOver16KiB() {
        // Single header line > 8 KiB
        let longValue = String(repeating: "a", count: HostedMCPConstants.maxHeaderLineBytes + 10)
        let lineOverflow = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nX-Long: \(longValue)\r\n\r\n"
        var lineParser = HostedMCPHTTPRequestParser()
        if case .failed(let error) = lineParser.feed(Data(lineOverflow.utf8)) {
            XCTAssertEqual(error, .lineTooLong)
            XCTAssertEqual(error.statusCode, 400)
        } else {
            XCTFail("expected .lineTooLong")
        }

        // Total header block > 16 KiB with each line < 8 KiB and <= 64 headers
        var bigHeaders = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\n"
        let chunk = String(repeating: "b", count: 1000)
        for idx in 0..<20 {
            bigHeaders += "X-Pad-\(idx): \(chunk)\r\n"
        }
        bigHeaders += "\r\n"
        var headParser = HostedMCPHTTPRequestParser()
        if case .failed(let error) = headParser.feed(Data(bigHeaders.utf8)) {
            XCTAssertEqual(error, .headersTooLarge)
            XCTAssertEqual(error.statusCode, 431)
        } else {
            XCTFail("expected .headersTooLarge")
        }
    }

    func testParserAccepts64HeadersAndRejects65Headers() {
        func makeRequest(headerCount: Int) -> String {
            var raw = "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\n"
            for idx in 1..<headerCount {
                raw += "X-Header-\(idx): v\(idx)\r\n"
            }
            raw += "\r\n"
            return raw
        }

        var parser64 = HostedMCPHTTPRequestParser()
        if case .complete(let req) = parser64.feed(Data(makeRequest(headerCount: 64).utf8)) {
            XCTAssertEqual(req.head.headers.count, 64)
        } else {
            XCTFail("64 headers must be accepted")
        }

        var parser65 = HostedMCPHTTPRequestParser()
        if case .failed(let error) = parser65.feed(Data(makeRequest(headerCount: 65).utf8)) {
            XCTAssertEqual(error, .tooManyHeaders)
            XCTAssertEqual(error.statusCode, 400)
        } else {
            XCTFail("65 headers must be rejected")
        }
    }

    func testParserRejectsObsFoldAndDuplicateSingleValueHeaders() {
        let obsFold =
            "POST /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            " folded-value\r\n" +
            "Content-Length: 0\r\n\r\n"
        var obsParser = HostedMCPHTTPRequestParser()
        if case .failed(let error) = obsParser.feed(Data(obsFold.utf8)) {
            XCTAssertEqual(error, .obsFoldNotAllowed)
            XCTAssertEqual(error.statusCode, 400)
        } else {
            XCTFail("obs-fold must be rejected")
        }

        let duplicateHost =
            "GET /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Host: localhost:47321\r\n\r\n"
        var dupParser = HostedMCPHTTPRequestParser()
        if case .failed(let error) = dupParser.feed(Data(duplicateHost.utf8)) {
            XCTAssertEqual(error, .duplicateHeader("host"))
            XCTAssertEqual(error.statusCode, 400)
        } else {
            XCTFail("duplicate Host header must be rejected")
        }
    }

    func testParserRejectsCLPlusTEAndInvalidContentLengthAndUnsupportedTE() {
        let clPlusTE =
            "POST /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Content-Length: 4\r\n" +
            "Transfer-Encoding: chunked\r\n\r\n"
        var clTeParser = HostedMCPHTTPRequestParser()
        if case .failed(let error) = clTeParser.feed(Data(clPlusTE.utf8)) {
            XCTAssertEqual(error, .conflictingLengthHeaders)
            XCTAssertEqual(error.statusCode, 400)
        } else {
            XCTFail("CL+TE must be rejected with 400")
        }

        for invalidCL in ["-1", "12abc", "+5", ""] {
            let raw =
                "POST /mcp HTTP/1.1\r\n" +
                "Host: 127.0.0.1:47321\r\n" +
                "Content-Length: \(invalidCL)\r\n\r\n"
            var parser = HostedMCPHTTPRequestParser()
            if case .failed(let error) = parser.feed(Data(raw.utf8)) {
                XCTAssertEqual(error, .invalidContentLength)
                XCTAssertEqual(error.statusCode, 400)
            } else {
                XCTFail("invalid Content-Length \(invalidCL) must be rejected")
            }
        }

        let unsupportedTE =
            "POST /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Transfer-Encoding: gzip\r\n\r\n"
        var teParser = HostedMCPHTTPRequestParser()
        if case .failed(let error) = teParser.feed(Data(unsupportedTE.utf8)) {
            XCTAssertEqual(error, .unsupportedTransferEncoding)
            XCTAssertEqual(error.statusCode, 501)
        } else {
            XCTFail("Transfer-Encoding: gzip must fail with 501")
        }
    }

    func testParserEnforces411LengthRequiredAnd413PayloadTooLarge() {
        let missingLength =
            "POST /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Content-Type: application/json\r\n\r\n"
        var parser411 = HostedMCPHTTPRequestParser()
        if case .failed(let error) = parser411.feed(Data(missingLength.utf8)) {
            XCTAssertEqual(error, .lengthRequired)
            XCTAssertEqual(error.statusCode, 411)
        } else {
            XCTFail("POST without Content-Length or Transfer-Encoding must fail with 411")
        }

        let tooLarge =
            "POST /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Content-Length: \(HostedMCPConstants.maxBodyBytes + 1)\r\n\r\n"
        var parser413 = HostedMCPHTTPRequestParser()
        if case .failed(let error) = parser413.feed(Data(tooLarge.utf8)) {
            XCTAssertEqual(error, .payloadTooLarge)
            XCTAssertEqual(error.statusCode, 413)
        } else {
            XCTFail("Content-Length past 4 MiB must fail with 413")
        }
    }

    func testParserChunkedSizesExtensionsTrailersAndOverflow() throws {
        let chunked =
            "POST /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "7;ext=1\r\n" +
            "{\"jsonr\r\n" +
            "A;foo=bar\r\n" +
            "pc\":\"2.0\"}\r\n" +
            "0\r\n" +
            "X-Trailer: done\r\n" +
            "\r\n"

        var parser = HostedMCPHTTPRequestParser()
        let bytes = Data(chunked.utf8)
        var result: HostedMCPHTTPParserStep = .needsMoreData
        for byte in bytes {
            result = parser.feed(Data([byte]))
        }
        guard case .complete(let request) = result else {
            return XCTFail("expected complete chunked request, got \(result)")
        }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), #"{"jsonrpc":"2.0"}"#)

        // Chunked overflow > maxBodyBytes
        let smallLimitConfig = HostedMCPHTTPRequestParser.Configuration(maxBodyBytes: 10)
        var overflowParser = HostedMCPHTTPRequestParser(configuration: smallLimitConfig)
        let overflowChunked =
            "POST /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Transfer-Encoding: chunked\r\n\r\n" +
            "B\r\n0123456789A\r\n0\r\n\r\n"
        if case .failed(let error) = overflowParser.feed(Data(overflowChunked.utf8)) {
            XCTAssertEqual(error, .payloadTooLarge)
            XCTAssertEqual(error.statusCode, 413)
        } else {
            XCTFail("chunked overflow must fail with 413")
        }
    }

    /// The parser drops the consumed prefix of its buffer only once that prefix is at least
    /// 4 KiB and no shorter than the tail the drop moves. Compacting after EVERY chunk moved the
    /// whole unconsumed tail once per chunk: one 64 KiB receive of `1\r\nX\r\n` chunks (about
    /// 10.9 K of them) moved ~358 MB on the listener's one serial queue.
    func testChunkedBodyOfTinyChunksCompactsAmortizedNotPerChunk() throws {
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nTransfer-Encoding: chunked\r\n\r\n"
        let chunk = "1\r\nX\r\n"
        let chunksPerReceive = 65_536 / chunk.utf8.count

        var oneReceive = Data(head.utf8)
        oneReceive.append(Data(String(repeating: chunk, count: chunksPerReceive).utf8))
        oneReceive.append(Data("0\r\n\r\n".utf8))
        var single = HostedMCPHTTPRequestParser()
        guard case .complete(let singleRequest) = single.feed(oneReceive) else {
            return XCTFail("expected the chunked request to complete in one feed")
        }
        XCTAssertEqual(singleRequest.body, Data(repeating: UInt8(ascii: "X"), count: chunksPerReceive))
        XCTAssertGreaterThan(single._testCompactionCount, 0, "anti-vacuum: 64 KiB of framing must be compacted away at least once")
        XCTAssertLessThanOrEqual(
            single._testCompactionCount, oneReceive.count / 4096,
            "one compaction per chunk is the quadratic shape; got \(single._testCompactionCount)")
        XCTAssertLessThanOrEqual(
            single._testCompactionMovedByteCount, oneReceive.count,
            "compaction may move each received byte at most once; moved \(single._testCompactionMovedByteCount)")

        // Four 64 KiB receives, each slice cutting a chunk in the middle.
        var stream = Data(head.utf8)
        stream.append(Data(String(repeating: chunk, count: chunksPerReceive * 4).utf8))
        stream.append(Data("0\r\n\r\n".utf8))
        var multi = HostedMCPHTTPRequestParser()
        var step: HostedMCPHTTPParserStep = .needsMoreData
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 65_536, stream.count)
            step = multi.feed(stream.subdata(in: offset..<end))
            offset = end
        }
        guard case .complete(let multiRequest) = step else {
            return XCTFail("expected the chunked request to complete across receives, got \(step)")
        }
        XCTAssertEqual(multiRequest.body, Data(repeating: UInt8(ascii: "X"), count: chunksPerReceive * 4))
        XCTAssertGreaterThan(multi._testCompactionCount, 0)
        XCTAssertLessThanOrEqual(multi._testCompactionCount, stream.count / 4096)
        XCTAssertLessThanOrEqual(multi._testCompactionMovedByteCount, stream.count)
    }

    /// A parser that has produced `.complete` or `.failed` is terminal: later bytes (a trailing
    /// CRLF, a pipelined copy of the request) are neither buffered nor parsed, and the same step
    /// comes back. Without that, every receive after completion grew the buffer for the life of
    /// the connection — an hour for a `wait_for_events` stream.
    func testParserIsTerminalOnceCompleteOrFailedAndBuffersNothingAfterwards() {
        let fixed = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nContent-Length: 2\r\n\r\n{}"
        var parser = HostedMCPHTTPRequestParser()
        guard case .complete(let request) = parser.feed(Data((fixed + "\r\n").utf8)) else {
            return XCTFail("expected a complete fixed-length request")
        }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{}")
        XCTAssertEqual(parser._testBufferedByteCount, 0, "a completed parser releases its buffers")
        for _ in 0..<3 {
            XCTAssertEqual(parser.feed(Data((fixed + "\r\n").utf8)), .complete(request))
        }
        XCTAssertEqual(parser._testBufferedByteCount, 0, "bytes after completion must not be buffered")

        let chunkedRaw =
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "2\r\n{}\r\n0\r\n\r\n"
        var chunked = HostedMCPHTTPRequestParser()
        guard case .complete(let chunkedRequest) = chunked.feed(Data(chunkedRaw.utf8)) else {
            return XCTFail("expected a complete chunked request")
        }
        XCTAssertEqual(chunked._testBufferedByteCount, 0)
        XCTAssertEqual(chunked.feed(Data(chunkedRaw.utf8)), .complete(chunkedRequest))
        XCTAssertEqual(chunked._testBufferedByteCount, 0)

        var bodiless = HostedMCPHTTPRequestParser()
        guard case .complete = bodiless.feed(Data("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\n\r\nGET /".utf8)) else {
            return XCTFail("expected a complete bodiless request")
        }
        XCTAssertEqual(bodiless._testBufferedByteCount, 0)

        var failed = HostedMCPHTTPRequestParser()
        XCTAssertEqual(failed.feed(Data("BAD\r\n\r\n".utf8)), .failed(.malformedRequestLine))
        XCTAssertEqual(failed._testBufferedByteCount, 0)
        XCTAssertEqual(failed.feed(Data(fixed.utf8)), .failed(.malformedRequestLine))
        XCTAssertEqual(failed._testBufferedByteCount, 0)
    }

    func testParserSupportsExpect100ContinueAndRejectsUnknownExpect() {
        let headOnly =
            "POST /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Expect: 100-continue\r\n" +
            "Content-Length: 2\r\n\r\n"
        var parser = HostedMCPHTTPRequestParser()
        let step1 = parser.feed(Data(headOnly.utf8))
        XCTAssertEqual(step1, .needsMoreData)
        XCTAssertNotNil(parser.parsedHead)
        XCTAssertTrue(parser.take100ContinueRequired())
        XCTAssertFalse(parser.take100ContinueRequired())

        let step2 = parser.feed(Data("{}".utf8))
        guard case .complete(let request) = step2 else {
            return XCTFail("expected complete request after body")
        }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{}")

        let badExpect =
            "POST /mcp HTTP/1.1\r\n" +
            "Host: 127.0.0.1:47321\r\n" +
            "Expect: 200-ok\r\n" +
            "Content-Length: 2\r\n\r\n{}"
        var badParser = HostedMCPHTTPRequestParser()
        if case .failed(let error) = badParser.feed(Data(badExpect.utf8)) {
            XCTAssertEqual(error, .expectationFailed)
            XCTAssertEqual(error.statusCode, 417)
        } else {
            XCTFail("unknown Expect must fail with 417")
        }
    }

    // MARK: - Guard Matrix (§7.2 ordered checks 1..6)

    func testGuardRejectsWrongPathWith404BeforeHostAndToken() {
        var tokenReads = 0
        let head = HostedMCPHTTPRequestHead(
            method: "POST",
            rawTarget: "/wrong",
            version: "HTTP/1.1",
            headers: [
                "host": "evil.example.com",
                "authorization": "Bearer ntm_token",
                "content-type": "application/json",
            ]
        )
        let decision = HostedMCPRequestGuard.evaluate(head: head, serverPort: testPort) { _ in
            tokenReads += 1
            return .authenticated(validAgent)
        }
        guard case .rejected(let rejection) = decision else {
            return XCTFail("expected 404 rejection")
        }
        XCTAssertEqual(rejection.response.statusCode, 404)
        XCTAssertEqual(tokenReads, 0, "wrong path must not read token")
    }

    func testGuardRejectsInvalidHostWith421BeforeReadingToken() {
        let acceptedHosts = [
            "127.0.0.1:47321",
            "localhost:47321",
            "LOCALHOST:47321",
            "[::1]:47321",
        ]
        for host in acceptedHosts {
            var tokenReads = 0
            let head = HostedMCPHTTPRequestHead(
                method: "POST",
                rawTarget: "/mcp",
                version: "HTTP/1.1",
                headers: [
                    "host": host,
                    "authorization": "Bearer ntm_token",
                    "content-type": "application/json",
                ]
            )
            let decision = HostedMCPRequestGuard.evaluate(head: head, serverPort: testPort) { _ in
                tokenReads += 1
                return .authenticated(validAgent)
            }
            guard case .accepted = decision else {
                XCTFail("expected host \(host) to be accepted, got \(decision)")
                continue
            }
            XCTAssertEqual(tokenReads, 1)
        }

        let rejectedHosts: [String?] = [
            nil,
            "",
            "127.0.0.1",
            "localhost",
            "[::1]",
            "127.0.0.1:9999",
            "evil.example.com:47321",
            "0.0.0.0:47321",
        ]
        for badHost in rejectedHosts {
            var tokenReads = 0
            var headers: [String: String] = [
                "authorization": "Bearer ntm_token",
                "content-type": "application/json",
            ]
            if let badHost { headers["host"] = badHost }
            let head = HostedMCPHTTPRequestHead(
                method: "POST",
                rawTarget: "/mcp",
                version: "HTTP/1.1",
                headers: headers
            )
            let decision = HostedMCPRequestGuard.evaluate(head: head, serverPort: testPort) { _ in
                tokenReads += 1
                return .authenticated(validAgent)
            }
            guard case .rejected(let rejection) = decision else {
                XCTFail("expected 421 for host \(String(describing: badHost))")
                continue
            }
            XCTAssertEqual(rejection.response.statusCode, 421)
            XCTAssertEqual(tokenReads, 0, "invalid Host \(String(describing: badHost)) must NEVER reach token verification")
        }
    }

    func testGuardChecksOriginAndRecordsVerbatimRejectedOriginBeforeReadingToken() {
        let allowedOrigins = [
            "http://127.0.0.1:3000",
            "https://localhost:8443",
            "http://[::1]:5173",
            "HTTP://LOCALHOST",
        ]
        for origin in allowedOrigins {
            let head = HostedMCPHTTPRequestHead(
                method: "POST",
                rawTarget: "/mcp",
                version: "HTTP/1.1",
                headers: [
                    "host": "127.0.0.1:47321",
                    "origin": origin,
                    "authorization": "Bearer ntm_token",
                    "content-type": "application/json",
                ]
            )
            let decision = HostedMCPRequestGuard.evaluate(head: head, serverPort: testPort) { _ in
                .authenticated(validAgent)
            }
            guard case .accepted = decision else {
                XCTFail("expected Origin \(origin) to be accepted")
                continue
            }
        }

        let forbiddenOrigins = [
            "null",
            "http://evil.example.com",
            "https://192.168.1.10:8080",
            "vscode-file://vscode-app",
        ]
        for origin in forbiddenOrigins {
            var tokenReads = 0
            let head = HostedMCPHTTPRequestHead(
                method: "POST",
                rawTarget: "/mcp",
                version: "HTTP/1.1",
                headers: [
                    "host": "127.0.0.1:47321",
                    "origin": origin,
                    "authorization": "Bearer ntm_token",
                    "content-type": "application/json",
                ]
            )
            let decision = HostedMCPRequestGuard.evaluate(head: head, serverPort: testPort) { _ in
                tokenReads += 1
                return .authenticated(validAgent)
            }
            guard case .rejected(let rejection) = decision else {
                XCTFail("expected 403 for Origin \(origin)")
                continue
            }
            XCTAssertEqual(rejection.response.statusCode, 403)
            XCTAssertEqual(rejection.rejectedOrigin, origin)
            XCTAssertEqual(tokenReads, 0, "rejected Origin must not reach token verification")
        }
    }

    func testGuardBearerAuthentication401WithoutResourceMetadataAnd503OnStorageFailure() {
        // Case-insensitive Bearer and trimmed whitespace succeed
        var capturedToken: String?
        let okHead = HostedMCPHTTPRequestHead(
            method: "POST",
            rawTarget: "/mcp",
            version: "HTTP/1.1",
            headers: [
                "host": "127.0.0.1:47321",
                "authorization": "  bEaReR   ntm_abc_123  ",
                "content-type": "application/json",
            ]
        )
        let okDecision = HostedMCPRequestGuard.evaluate(head: okHead, serverPort: testPort) { token in
            capturedToken = token
            return .authenticated(validAgent)
        }
        guard case .accepted(.mcp(let authedAgent)) = okDecision else {
            return XCTFail("expected accepted mcp route")
        }
        XCTAssertEqual(capturedToken, "ntm_abc_123")
        XCTAssertEqual(authedAgent, validAgent)

        // Missing or invalid token -> 401 with WWW-Authenticate: Bearer realm="nanoteams" (no resource_metadata)
        let badAuthHeaders: [String?] = [nil, "", "Basic dXNlcjpwYXNz", "Bearer   ", "Bearer wrong"]
        for auth in badAuthHeaders {
            var headers: [String: String] = [
                "host": "127.0.0.1:47321",
                "content-type": "application/json",
            ]
            if let auth { headers["authorization"] = auth }
            let head = HostedMCPHTTPRequestHead(
                method: "POST",
                rawTarget: "/mcp",
                version: "HTTP/1.1",
                headers: headers
            )
            let decision = HostedMCPRequestGuard.evaluate(head: head, serverPort: testPort) { _ in
                .invalidToken
            }
            guard case .rejected(let rejection) = decision else {
                XCTFail("expected 401 for auth \(String(describing: auth))")
                continue
            }
            XCTAssertEqual(rejection.response.statusCode, 401)
            let wwwAuth = rejection.response.header("WWW-Authenticate")
            XCTAssertEqual(wwwAuth, #"Bearer realm="nanoteams""#)
            XCTAssertFalse(wwwAuth?.contains("resource_metadata") ?? true)
        }

        // Keychain failure -> 503 Service Unavailable (never 401)
        let keychainHead = HostedMCPHTTPRequestHead(
            method: "POST",
            rawTarget: "/mcp",
            version: "HTTP/1.1",
            headers: [
                "host": "127.0.0.1:47321",
                "authorization": "Bearer ntm_valid_looking",
                "content-type": "application/json",
            ]
        )
        let storageDecision = HostedMCPRequestGuard.evaluate(head: keychainHead, serverPort: testPort) { _ in
            .storageFailure("errSecInteractionNotAllowed")
        }
        guard case .rejected(let storageRejection) = storageDecision else {
            return XCTFail("expected 503 on Keychain failure")
        }
        XCTAssertEqual(storageRejection.response.statusCode, 503)
        XCTAssertNil(storageRejection.response.header("WWW-Authenticate"))
    }

    func testGuardMethod405WithAllowPostAndContentType415() {
        for method in ["GET", "OPTIONS", "HEAD", "DELETE"] {
            let head = HostedMCPHTTPRequestHead(
                method: method,
                rawTarget: "/mcp",
                version: "HTTP/1.1",
                headers: [
                    "host": "127.0.0.1:47321",
                    "authorization": "Bearer ntm_ok",
                ]
            )
            let decision = HostedMCPRequestGuard.evaluate(head: head, serverPort: testPort) { _ in
                .authenticated(validAgent)
            }
            guard case .rejected(let rejection) = decision else {
                XCTFail("expected 405 for \(method)")
                continue
            }
            XCTAssertEqual(rejection.response.statusCode, 405)
            XCTAssertEqual(rejection.response.header("Allow"), "POST")
        }

        for contentType in [nil, "text/plain", "application/xml", "multipart/form-data"] {
            var headers: [String: String] = [
                "host": "127.0.0.1:47321",
                "authorization": "Bearer ntm_ok",
            ]
            if let contentType { headers["content-type"] = contentType }
            let head = HostedMCPHTTPRequestHead(
                method: "POST",
                rawTarget: "/mcp",
                version: "HTTP/1.1",
                headers: headers
            )
            let decision = HostedMCPRequestGuard.evaluate(head: head, serverPort: testPort) { _ in
                .authenticated(validAgent)
            }
            guard case .rejected(let rejection) = decision else {
                XCTFail("expected 415 for Content-Type \(String(describing: contentType))")
                continue
            }
            XCTAssertEqual(rejection.response.statusCode, 415)
        }

        for validContentType in [
            "application/json",
            "application/json; charset=utf-8",
            "APPLICATION/JSON; charset=ISO-8859-1",
        ] {
            let head = HostedMCPHTTPRequestHead(
                method: "POST",
                rawTarget: "/mcp",
                version: "HTTP/1.1",
                headers: [
                    "host": "127.0.0.1:47321",
                    "authorization": "Bearer ntm_ok",
                    "content-type": validContentType,
                ]
            )
            let decision = HostedMCPRequestGuard.evaluate(head: head, serverPort: testPort) { _ in
                .authenticated(validAgent)
            }
            guard case .accepted = decision else {
                XCTFail("expected \(validContentType) to be accepted")
                continue
            }
        }
    }

    /// The `/identify` nonce is ASCII hex. `Character.isHexDigit` also accepts the fullwidth
    /// digits and letters (`U+FF10…FF19`, `U+FF21…FF26`, `U+FF41…FF46`), so a fullwidth nonce
    /// passed this unauthenticated route's guard and was hashed into a proof.
    func testIdentifyGuardAcceptsOnlyASCIIHexNoncesOfEvenLengthWithinBounds() {
        func decide(_ nonce: String) -> HostedMCPGuardDecision {
            let encoded = nonce.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? nonce
            return HostedMCPRequestGuard.evaluate(
                head: HostedMCPHTTPRequestHead(
                    method: "GET",
                    rawTarget: "/identify?agent=a1b2c3d4&nonce=\(encoded)",
                    headers: ["host": "127.0.0.1:47321"]
                ),
                serverPort: testPort,
                verifyToken: { _ in .invalidToken }
            )
        }

        let refused = [
            String(repeating: "\u{FF10}\u{FF19}", count: 8),
            String(repeating: "\u{FF21}\u{FF46}", count: 8),
            "0123456789abcde\u{FF46}",
            "0123456789abcdef0",
            String(repeating: "a", count: HostedMCPConstants.minIdentifyNonceHexCharacters - 2),
            String(repeating: "a", count: HostedMCPConstants.maxIdentifyNonceHexCharacters + 2),
            "0123456789abcdeg",
        ]
        for nonce in refused {
            guard case .rejected(let rejection) = decide(nonce) else {
                XCTFail("nonce \(nonce.debugDescription) must be refused")
                continue
            }
            XCTAssertEqual(rejection.response.statusCode, 400, nonce.debugDescription)
            XCTAssertEqual(rejection.reason, "identify_invalid_parameters", nonce.debugDescription)
        }

        let accepted = [
            "0123456789ABCDEF",
            "0123456789abcdef",
            String(repeating: "f", count: HostedMCPConstants.maxIdentifyNonceHexCharacters),
        ]
        for nonce in accepted {
            guard case .accepted(.identify(let agentID, let acceptedNonce)) = decide(nonce) else {
                XCTFail("ASCII hex nonce \(nonce) must be accepted")
                continue
            }
            XCTAssertEqual(agentID, "a1b2c3d4")
            XCTAssertEqual(acceptedNonce, nonce)
        }
    }

    // MARK: - SSE Writer Round-Trip Through SSEFrameParser (§7.2, §7.3)

    func testSSEWriterRoundTripsThroughSSEFrameParser() throws {
        let headerBytes = HostedMCPSSEWriter.responseHeaderData(
            additionalHeaders: [("Mcp-Session-Id", "sess-42")]
        )
        let headerText = String(decoding: headerBytes, as: UTF8.self)
        XCTAssertTrue(headerText.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(headerText.contains("Content-Type: text/event-stream\r\n"))
        XCTAssertTrue(headerText.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(headerText.contains("Connection: close\r\n"))
        XCTAssertTrue(headerText.contains("X-Accel-Buffering: no\r\n"))
        XCTAssertTrue(headerText.contains("Mcp-Session-Id: sess-42\r\n"))

        let progressNotification = JSONRPCNotification(
            method: "notifications/progress",
            params: .object([
                "progressToken": .string("tok-1"),
                "progress": .int(1),
            ])
        )
        let finalResponse = JSONRPCResponse(
            id: .number(7),
            outcome: .result(.object(["ok": .bool(true), "multiline": .string("line1\nline2")]))
        )

        var stream = Data()
        stream.append(HostedMCPSSEWriter.primingCommentData())
        stream.append(HostedMCPSSEWriter.keepAliveCommentData())
        stream.append(HostedMCPSSEWriter.messageFrameData(JSONRPCCodec.encode(progressNotification)))
        stream.append(HostedMCPSSEWriter.keepAliveCommentData())
        stream.append(HostedMCPSSEWriter.messageFrameData(JSONRPCCodec.encode(finalResponse)))

        let streamText = String(decoding: stream, as: UTF8.self)
        XCTAssertFalse(streamText.contains("\nid:"), "SSE frames must not carry event IDs")

        var sseParser = SSEFrameParser()
        var parsedFrames: [SSEFrameParser.Frame] = []
        let lines = streamText.components(separatedBy: "\n")
        for line in lines {
            if let frame = try sseParser.consume(line: line) {
                parsedFrames.append(frame)
            }
        }
        if let trailing = sseParser.finish() {
            parsedFrames.append(trailing)
        }

        XCTAssertEqual(parsedFrames.count, 2)
        XCTAssertEqual(parsedFrames[0].event, "message")
        XCTAssertNil(parsedFrames[0].lastEventID)
        XCTAssertEqual(
            try JSONRPCCodec.decode(Data(parsedFrames[0].data.utf8)),
            .notification(progressNotification)
        )

        XCTAssertEqual(parsedFrames[1].event, "message")
        XCTAssertNil(parsedFrames[1].lastEventID)
        XCTAssertEqual(
            try JSONRPCCodec.decode(Data(parsedFrames[1].data.utf8)),
            .response(finalResponse)
        )
    }

    // MARK: - Background Queue Connection Driver (D8)

    func testConnectionDriverRunsOnBackgroundQueueAndEnforcesGuardAndDeadlines() {
        final class DriverStateBox: @unchecked Sendable {
            var sentChunks: [Data] = []
            var closedCount = 0
            var tokenReads = 0
            var timeoutData = Data()
        }

        let queue = DispatchQueue(label: "com.nanoteams.tests.hostedmcp.http.driver")
        let expectedAgent = validAgent
        let box = DriverStateBox()

        // 1. Valid request with Expect: 100-continue on background queue
        let completedExpectation = expectation(description: "driver completes valid request")

        let driver = HostedMCPHTTPConnectionDriver(
            queue: queue,
            serverPort: testPort,
            configuration: .init(
                headDeadline: .milliseconds(500),
                bodyDeadline: .milliseconds(500)
            ),
            verifyToken: { token in
                dispatchPrecondition(condition: .onQueue(queue))
                box.tokenReads += 1
                return token == "ntm_secret" ? .authenticated(expectedAgent) : .invalidToken
            },
            sendBytes: { data in
                dispatchPrecondition(condition: .onQueue(queue))
                box.sentChunks.append(data)
            },
            closeConnection: {
                dispatchPrecondition(condition: .onQueue(queue))
                box.closedCount += 1
                completedExpectation.fulfill()
            },
            onRequest: { route, request, respond in
                dispatchPrecondition(condition: .onQueue(queue))
                XCTAssertEqual(route, .mcp(agent: expectedAgent))
                XCTAssertEqual(String(decoding: request.body, as: UTF8.self), #"{"jsonrpc":"2.0"}"#)
                respond(HostedMCPHTTPResponse.json(statusCode: 200, body: Data(#"{"ok":true}"#.utf8)))
            }
        )

        queue.async {
            driver.start()
            let head =
                "POST /mcp HTTP/1.1\r\n" +
                "Host: 127.0.0.1:47321\r\n" +
                "Authorization: Bearer ntm_secret\r\n" +
                "Content-Type: application/json\r\n" +
                "Expect: 100-continue\r\n" +
                "Content-Length: 17\r\n\r\n"
            driver.receive(Data(head.utf8))
            driver.receive(Data(#"{"jsonrpc":"2.0"}"#.utf8))
        }

        wait(for: [completedExpectation], timeout: 3.0)
        XCTAssertEqual(box.tokenReads, 1)
        XCTAssertEqual(box.closedCount, 1)
        XCTAssertEqual(box.sentChunks.count, 2)
        XCTAssertEqual(String(decoding: box.sentChunks[0], as: UTF8.self), "HTTP/1.1 100 Continue\r\n\r\n")
        let finalReply = String(decoding: box.sentChunks[1], as: UTF8.self)
        XCTAssertTrue(finalReply.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(finalReply.contains("Connection: close\r\n"))
        XCTAssertTrue(finalReply.contains("Cache-Control: no-store\r\n"))

        // 2. Head deadline timeout on slow client
        let timeoutExpectation = expectation(description: "driver times out on slow head")
        let timeoutDriver = HostedMCPHTTPConnectionDriver(
            queue: queue,
            serverPort: testPort,
            configuration: .init(
                headDeadline: .milliseconds(80),
                bodyDeadline: .milliseconds(500)
            ),
            verifyToken: { _ in .invalidToken },
            sendBytes: { data in
                box.timeoutData.append(data)
            },
            closeConnection: {
                timeoutExpectation.fulfill()
            },
            onRequest: { _, _, _ in
                XCTFail("onRequest must not be called on timeout")
            }
        )

        queue.async {
            timeoutDriver.start()
            timeoutDriver.receive(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\n".utf8))
        }

        wait(for: [timeoutExpectation], timeout: 2.0)
        let timeoutText = String(decoding: box.timeoutData, as: UTF8.self)
        XCTAssertTrue(timeoutText.hasPrefix("HTTP/1.1 408 Request Timeout\r\n"))
    }

    func testResponseEqualityMultiValueHeadersAndIdentifyRouteShape() {
        let r1 = HostedMCPHTTPResponse.empty(statusCode: 202, headers: [("X-A", "1")])
        let r2 = HostedMCPHTTPResponse.empty(statusCode: 202, headers: [("X-A", "1")])
        let r3 = HostedMCPHTTPResponse(statusCode: 999, reasonPhrase: HostedMCPHTTPResponse.defaultReasonPhrase(for: 999))
        let r4 = HostedMCPHTTPResponse.empty(statusCode: 202, headers: [("X-A", "2")])
        XCTAssertEqual(r1, r2)
        XCTAssertNotEqual(r1, r3)
        XCTAssertNotEqual(r1, r4, "equality compares header values, not just names")
        XCTAssertEqual(r3.reasonPhrase, "Status 999")

        var multiParser = HostedMCPHTTPRequestParser()
        let multiRaw = "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nAccept: application/json\r\nAccept: text/event-stream\r\n\r\n"
        guard case .complete(let multiRequest) = multiParser.feed(Data(multiRaw.utf8)) else {
            return XCTFail("expected the multi-value Accept header to parse")
        }
        XCTAssertEqual(multiRequest.head.header("accept"), "application/json, text/event-stream")

        let okIdentify = HostedMCPHTTPRequestHead(
            method: "GET",
            rawTarget: "/identify?agent=a1b2c3d4&nonce=0123456789abcdef0123456789abcdef",
            version: "HTTP/1.1",
            headers: ["host": "127.0.0.1:47321"]
        )
        guard case .accepted(.identify(let shortID, let nonce)) = HostedMCPRequestGuard.evaluate(
            head: okIdentify,
            serverPort: testPort,
            verifyToken: { _ in .invalidToken }
        ) else {
            return XCTFail("expected /identify to be accepted")
        }
        XCTAssertEqual(shortID, "a1b2c3d4")
        XCTAssertEqual(nonce, "0123456789abcdef0123456789abcdef")

        let postIdentify = HostedMCPHTTPRequestHead(
            method: "POST",
            rawTarget: "/identify?agent=a1b2c3d4&nonce=0123456789abcdef0123456789abcdef",
            version: "HTTP/1.1",
            headers: ["host": "127.0.0.1:47321"]
        )
        guard case .rejected(let postRejection) = HostedMCPRequestGuard.evaluate(
            head: postIdentify,
            serverPort: testPort,
            verifyToken: { _ in .invalidToken }
        ) else {
            return XCTFail("expected 405 for POST /identify")
        }
        XCTAssertEqual(postRejection.response.statusCode, 405)
        XCTAssertEqual(postRejection.response.header("Allow"), "GET")
        XCTAssertEqual(postRejection.reason, "identify_method_not_allowed")

        let badTargets: [(target: String, reason: String)] = [
            ("/identify", "identify_missing_query"),
            ("/identify?agent=bad&nonce=short", "identify_invalid_parameters"),
            ("/identify?nonce=0123456789abcdef", "identify_invalid_parameters"),
            ("/identify?agent=a1b2c3d4", "identify_invalid_parameters"),
        ]
        for (target, reason) in badTargets {
            let head = HostedMCPHTTPRequestHead(
                method: "GET",
                rawTarget: target,
                version: "HTTP/1.1",
                headers: ["host": "127.0.0.1:47321"]
            )
            guard case .rejected(let rejection) = HostedMCPRequestGuard.evaluate(
                head: head,
                serverPort: testPort,
                verifyToken: { _ in .invalidToken }
            ) else {
                XCTFail("expected 400 for \(target)")
                continue
            }
            XCTAssertEqual(rejection.response.statusCode, 400, target)
            XCTAssertEqual(rejection.reason, reason, target)
        }
    }

    func testMalformedHeaderAndChunkedPayloadsFailWithTheirExactError() {
        let chunkedHead = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nTransfer-Encoding: chunked\r\n\r\n"
        let cases: [(payload: String, error: HostedMCPHTTPError)] = [
            ("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nNoColonHeader\r\n\r\n", .malformedHeader),
            ("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nBad Name: val\r\n\r\n", .malformedHeader),
            ("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\n: no-name\r\n\r\n", .malformedHeader),
            ("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nX-Ctrl: a\u{0007}b\r\n\r\n", .malformedHeader),
            ("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\nX-A: b\r\n\r\n", .malformedHeader),
            (chunkedHead + "ZZ\r\n\r\n", .malformedChunkedBody),
            (chunkedHead + ";ext\r\n\r\n", .malformedChunkedBody),
            (chunkedHead + "1\r\naXX", .malformedChunkedBody),
            (chunkedHead + "1\na\r\n0\r\n\r\n", .malformedChunkedBody),
            (chunkedHead + "0\r\nBadTrailerLine\r\n\r\n", .malformedChunkedBody),
            (chunkedHead + "0\r\n folded: trailer\r\n\r\n", .malformedChunkedBody),
            (chunkedHead + "\u{FF11}\r\na\r\n0\r\n\r\n", .malformedChunkedBody),
        ]
        for (payload, expected) in cases {
            var parser = HostedMCPHTTPRequestParser()
            XCTAssertEqual(parser.feed(Data(payload.utf8)), .failed(expected), payload.debugDescription)
        }

        let smallLineCfg = HostedMCPHTTPRequestParser.Configuration(maxLineBytes: 32, maxHeaderCount: 5, maxBodyBytes: 1024)
        var pChunkLineLong = HostedMCPHTTPRequestParser(configuration: smallLineCfg)
        XCTAssertEqual(
            pChunkLineLong.feed(Data(("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n" + String(repeating: "0", count: 40) + "\r\n").utf8)),
            .failed(.lineTooLong)
        )

        var pTrailerLineLong = HostedMCPHTTPRequestParser(configuration: smallLineCfg)
        XCTAssertEqual(
            pTrailerLineLong.feed(Data(("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n" + String(repeating: "X", count: 40) + "\r\n").utf8)),
            .failed(.lineTooLong)
        )

        var pTrailerNoCR = HostedMCPHTTPRequestParser()
        XCTAssertEqual(
            pTrailerNoCR.feed(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Trailer: 1\n\r\n".utf8)),
            .failed(.malformedChunkedBody)
        )

        let capTrailerCfg = HostedMCPHTTPRequestParser.Configuration(maxLineBytes: 256, maxHeaderCount: 2, maxBodyBytes: 1024)
        var pTrailerTooMany = HostedMCPHTTPRequestParser(configuration: capTrailerCfg)
        XCTAssertEqual(
            pTrailerTooMany.feed(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nT1: 1\r\nT2: 2\r\nT3: 3\r\n\r\n".utf8)),
            .failed(.tooManyHeaders)
        )

        var pChunkCtrl = HostedMCPHTTPRequestParser()
        XCTAssertEqual(
            pChunkCtrl.feed(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n1\u{01}\r\na\r\n0\r\n\r\n".utf8)),
            .failed(.malformedChunkedBody)
        )
    }

    // MARK: - Connection Driver Replies (D8)

    func testDriverAnswersAParseErrorWith400AndReportsIt() {
        let queue = DispatchQueue(label: "com.nanoteams.tests.hostedmcp.http.driver.parse")
        let box = DriverReplyBox()
        let closed = expectation(description: "connection closed after the 400")
        let driver = HostedMCPHTTPConnectionDriver(
            queue: queue,
            serverPort: testPort,
            verifyToken: { _ in .invalidToken },
            sendBytes: { box.sent.append($0) },
            closeConnection: { box.closeCount += 1; closed.fulfill() },
            onParseError: { box.parseErrors.append($0) },
            onRequest: { _, _, _ in box.dispatchCount += 1 }
        )
        queue.async {
            driver.start()
            driver.receive(Data("BAD\r\n\r\n".utf8))
        }
        wait(for: [closed], timeout: 2.0)
        queue.sync {}
        XCTAssertEqual(box.parseErrors, [.malformedRequestLine])
        XCTAssertEqual(box.sentTexts.count, 1)
        XCTAssertTrue(box.sentTexts.first?.hasPrefix("HTTP/1.1 400 Bad Request\r\n") == true, box.sentTexts.joined())
        XCTAssertEqual(box.dispatchCount, 0)
        XCTAssertEqual(box.closeCount, 1)
    }

    /// A request whose head and body arrive in one buffer still gets `100 Continue` first, and
    /// then exactly one final response.
    func testDriverSends100ContinueBeforeTheFinalResponseForASingleBufferRequest() {
        let queue = DispatchQueue(label: "com.nanoteams.tests.hostedmcp.http.driver.continue")
        let box = DriverReplyBox()
        let agent = validAgent
        let closed = expectation(description: "connection closed after the response")
        let driver = HostedMCPHTTPConnectionDriver(
            queue: queue,
            serverPort: testPort,
            verifyToken: { _ in .authenticated(agent) },
            sendBytes: { box.sent.append($0) },
            closeConnection: { box.closeCount += 1; closed.fulfill() },
            onRequest: { _, request, respond in
                box.dispatchCount += 1
                box.bodies.append(request.body)
                respond(.json(statusCode: 200, body: Data(#"{"ok":true}"#.utf8)))
            }
        )
        queue.async {
            driver.start()
            let fullWithExpect =
                "POST /mcp HTTP/1.1\r\n" +
                "Host: 127.0.0.1:47321\r\n" +
                "Authorization: Bearer ntm_secret\r\n" +
                "Content-Type: application/json\r\n" +
                "Expect: 100-continue\r\n" +
                "Content-Length: 2\r\n\r\n{}"
            driver.receive(Data(fullWithExpect.utf8))
        }
        wait(for: [closed], timeout: 2.0)
        queue.sync {}
        XCTAssertEqual(box.dispatchCount, 1)
        XCTAssertEqual(box.bodies, [Data("{}".utf8)])
        XCTAssertEqual(box.sentTexts.count, 2, box.sentTexts.joined())
        XCTAssertEqual(box.sentTexts.first, "HTTP/1.1 100 Continue\r\n\r\n")
        XCTAssertTrue(box.sentTexts.last?.hasPrefix("HTTP/1.1 200 OK\r\n") == true, box.sentTexts.joined())
        XCTAssertTrue(box.sentTexts.last?.hasSuffix(#"{"ok":true}"#) == true)
        XCTAssertEqual(box.closeCount, 1)
    }

    func testDriverAnswers408WhenTheBodyDeadlineElapses() {
        let queue = DispatchQueue(label: "com.nanoteams.tests.hostedmcp.http.driver.body")
        let box = DriverReplyBox()
        let agent = validAgent
        let closed = expectation(description: "connection closed after the 408")
        let driver = HostedMCPHTTPConnectionDriver(
            queue: queue,
            serverPort: testPort,
            configuration: .init(headDeadline: .milliseconds(500), bodyDeadline: .milliseconds(60)),
            verifyToken: { _ in .authenticated(agent) },
            sendBytes: { box.sent.append($0) },
            closeConnection: { box.closeCount += 1; closed.fulfill() },
            onParseError: { box.parseErrors.append($0) },
            onRequest: { _, _, _ in box.dispatchCount += 1 }
        )
        queue.async {
            driver.start()
            let partial =
                "POST /mcp HTTP/1.1\r\n" +
                "Host: 127.0.0.1:47321\r\n" +
                "Authorization: Bearer ntm_secret\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: 20\r\n\r\n{"
            driver.receive(Data(partial.utf8))
            box.authenticatedAgentID = driver.authenticatedAgentID
        }
        wait(for: [closed], timeout: 2.0)
        queue.sync {}
        XCTAssertEqual(box.authenticatedAgentID, agent.id)
        XCTAssertEqual(box.parseErrors, [.requestTimeout])
        XCTAssertEqual(box.sentTexts.count, 1, box.sentTexts.joined())
        XCTAssertTrue(box.sentTexts.first?.hasPrefix("HTTP/1.1 408 Request Timeout\r\n") == true, box.sentTexts.joined())
        XCTAssertEqual(box.dispatchCount, 0)
        XCTAssertEqual(box.closeCount, 1)
    }

    /// The driver hands a request to `onRequest` exactly once. Bytes that arrive while the
    /// response is pending — a trailing CRLF, a pipelined copy — re-dispatched the same
    /// `tools/call` on every later receive, each time taking another `wait_for_events` slot and
    /// orphaning the earlier dispatch task from eviction.
    func testDriverDispatchesACompletedRequestOnceAndIgnoresBytesThatFollowIt() {
        let queue = DispatchQueue(label: "com.nanoteams.tests.hostedmcp.http.driver.once")
        let box = DriverReplyBox()
        let agent = validAgent
        let closed = expectation(description: "connection closed after the one response")
        let driver = HostedMCPHTTPConnectionDriver(
            queue: queue,
            serverPort: testPort,
            verifyToken: { _ in .authenticated(agent) },
            sendBytes: { box.sent.append($0) },
            closeConnection: { box.closeCount += 1; closed.fulfill() },
            onRequest: { _, _, respond in
                box.dispatchCount += 1
                box.pendingResponders.append(respond)
            }
        )
        let request =
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nAuthorization: Bearer ntm_secret\r\n" +
            "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        queue.async {
            driver.start()
            driver.receive(Data(request.utf8))
            driver.receive(Data("\r\n".utf8))
            driver.receive(Data(request.utf8))
            box.dispatchCountBeforeResponse = box.dispatchCount
            box.pendingResponders.first?(.json(statusCode: 200, body: Data("{}".utf8)))
        }
        wait(for: [closed], timeout: 2.0)
        queue.sync {}
        XCTAssertEqual(box.dispatchCountBeforeResponse, 1, "later bytes must not dispatch the request again")
        XCTAssertEqual(box.dispatchCount, 1)
        XCTAssertEqual(box.sentTexts.count, 1, box.sentTexts.joined())
        XCTAssertTrue(box.sentTexts.first?.hasPrefix("HTTP/1.1 200 OK\r\n") == true)
        XCTAssertEqual(box.closeCount, 1)
    }
}

/// What a `HostedMCPHTTPConnectionDriver` under test did, written only on the driver's queue
/// and read after `queue.sync {}`.
private final class DriverReplyBox: @unchecked Sendable {
    var sent: [Data] = []
    var closeCount = 0
    var dispatchCount = 0
    var dispatchCountBeforeResponse = 0
    var parseErrors: [HostedMCPHTTPError] = []
    var bodies: [Data] = []
    var authenticatedAgentID: UUID?
    var pendingResponders: [@Sendable (HostedMCPHTTPResponse) -> Void] = []

    var sentTexts: [String] { sent.map { String(decoding: $0, as: UTF8.self) } }
}
