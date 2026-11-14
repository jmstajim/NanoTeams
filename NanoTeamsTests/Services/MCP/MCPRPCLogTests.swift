import XCTest

@testable import NanoTeams

/// The per-server audit trail — and, more importantly, what it refuses to contain.
final class MCPRPCLogTests: XCTestCase {

    private var directory: URL!
    private var log: MCPRPCLog!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-rpc-log-\(UUID().uuidString)", isDirectory: true)
        log = MCPRPCLog(logURL: directory.appendingPathComponent("rpc_log.jsonl"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        log = nil
        super.tearDown()
    }

    private func records() throws -> [[String: Any]] {
        let url = directory.appendingPathComponent("rpc_log.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func rawText() -> String {
        (try? String(contentsOf: directory.appendingPathComponent("rpc_log.jsonl"), encoding: .utf8)) ?? ""
    }

    // MARK: - Frames

    func testARequestAndItsReplyEachGetALine() throws {
        log.noteOutgoing(.request(JSONRPCRequest(
            id: .number(1), method: "tools/call", params: .object(["name": .string("get_quote")]))))
        log.noteIncoming(.response(JSONRPCResponse(
            id: .number(1), outcome: .result(.object(["content": .array([])])))), durationMs: 12.5)

        let rows = try records()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["kind"] as? String, "request")
        XCTAssertEqual(rows[0]["direction"] as? String, "out")
        XCTAssertEqual(rows[0]["method"] as? String, "tools/call")
        XCTAssertEqual(rows[0]["requestID"] as? String, "1")
        XCTAssertEqual(rows[1]["kind"] as? String, "response")
        XCTAssertEqual(rows[1]["durationMs"] as? Double, 12.5)
    }

    func testAServersRefusalKeepsItsCodeAndMessage() throws {
        log.noteIncoming(.response(JSONRPCResponse(
            id: .number(2),
            outcome: .failure(JSONRPCError(code: -32602, message: "figi is required")))))
        let row = try XCTUnwrap(records().first)
        XCTAssertEqual(row["errorCode"] as? Int, -32602)
        XCTAssertEqual(row["errorMessage"] as? String, "figi is required")
    }

    func testAServerRequestIsRecordedAsSuchAndSoIsTheReply() throws {
        log.noteIncoming(.request(JSONRPCRequest(id: .string("p1"), method: "ping")))
        log.noteOutgoing(.response(JSONRPCResponse(id: .string("p1"), outcome: .result(.object([:])))))
        let rows = try records()
        XCTAssertEqual(rows[0]["kind"] as? String, "serverRequest")
        XCTAssertEqual(rows[0]["requestID"] as? String, "p1")
        XCTAssertEqual(rows[1]["direction"] as? String, "out")
    }

    // MARK: - What must never be in it

    /// `Authorization` and `Mcp-Session-Id` carry the two things that must never be written
    /// down, and no header carries any part of the audit question. Leaving the field out is
    /// stronger than redacting it: there is nothing for a future change to forget.
    func testNoRecordHasAHeaderFieldAtAll() throws {
        log.noteOutgoing(.request(JSONRPCRequest(id: .number(1), method: "tools/list")))
        log.noteConnect(url: try XCTUnwrap(URL(string: "https://u:p@example.com/mcp?token=SECRET-1234")))
        log.noteEra(.legacy, protocolVersion: "2025-11-25", how: "initialize answered")

        let keys = Set(try records().flatMap(\.keys).map { $0.lowercased() })
        for forbidden in ["headers", "header", "authorization", "cookie", "sessionid", "mcp-session-id"] {
            XCTAssertFalse(keys.contains(forbidden), "\(forbidden) must not be a field of this record")
        }
        XCTAssertFalse(rawText().contains("SECRET-1234"))
        XCTAssertFalse(rawText().contains("u:p@"))
    }

    /// A server can echo a credential into any payload it likes.
    func testCredentialsInsideAPayloadAreScrubbed() throws {
        log.noteOutgoing(.request(JSONRPCRequest(
            id: .number(1), method: "tools/call",
            params: .object(["arguments": .object(["auth": .string("Bearer t.SECRET-VALUE-9f3a1c")])]))))
        XCTAssertFalse(rawText().contains("t.SECRET-VALUE-9f3a1c"), rawText())
        XCTAssertTrue(rawText().contains(MCPRedaction.placeholder))
    }

    /// The literal secrets this server is sent, and the value after any of its secret header
    /// NAMES, are absent from every field this log writes — the refusal message, the payload
    /// excerpt, a failure's message — in whichever direction the frame went (F11). Until
    /// 2026-09-23 the header names were stored here and never read.
    func testAnEchoedSecretIsAbsentFromEveryRecord() throws {
        let secret = "wk_live_8f3a9c2d"
        let secretLog = MCPRPCLog(
            logURL: directory.appendingPathComponent("rpc_log.jsonl"),
            credentials: { MCPRedaction.Credentials(headerNames: ["X-Workspace-Key"], values: [secret]) })
        secretLog.noteIncoming(.response(JSONRPCResponse(
            id: .number(1), outcome: .failure(JSONRPCError(code: -32001, message: "bad key \(secret)")))))
        secretLog.noteIncoming(.response(JSONRPCResponse(
            id: .number(2), outcome: .result(.object(["echo": .string("X-Workspace-Key: other-9f8e7d")])))))
        secretLog.noteOutgoing(.request(JSONRPCRequest(
            id: .number(3), method: "tools/call", params: .object(["text": .string("mine is \(secret)")]))))
        secretLog.noteOutgoing(.response(JSONRPCResponse(
            id: .string("p"), outcome: .failure(JSONRPCError(code: -1, message: secret)))))
        secretLog.noteFailure(MCPClientError.rpc(code: -32001, message: "echo \(secret)", data: nil))
        secretLog.noteFailure(MCPTransportError.httpStatus(code: 400, body: "X-Workspace-Key=\(secret)"))

        let text = rawText()
        XCTAssertEqual(try records().count, 6)
        XCTAssertFalse(text.contains(secret), text)
        XCTAssertFalse(text.contains("other-9f8e7d"), text)
        XCTAssertTrue(text.contains(MCPRedaction.placeholder), text)
    }

    /// The credentials are read when a line is WRITTEN, not when the log is built: a token
    /// rotated in Settings is scrubbed from the next line on, with no reconnect.
    func testTheCredentialsAreReadPerLine() throws {
        final class Box: @unchecked Sendable { var value = "first-secret-1" }
        let box = Box()
        let rotating = MCPRPCLog(
            logURL: directory.appendingPathComponent("rpc_log.jsonl"),
            credentials: { MCPRedaction.Credentials(values: [box.value]) })
        rotating.noteFailure(MCPClientError.rpc(code: 1, message: "first-secret-1", data: nil))
        box.value = "second-secret-2"
        rotating.noteFailure(MCPClientError.rpc(code: 1, message: "second-secret-2", data: nil))
        XCTAssertFalse(rawText().contains("first-secret-1"), rawText())
        XCTAssertFalse(rawText().contains("second-secret-2"), rawText())
    }

    /// A `get_screenshot` reply is a megabyte of base64 and writing it here would cost more
    /// than the audit is worth — but the true size is kept, so nothing reads as complete when
    /// it is not.
    func testAHugePayloadIsCappedAndItsTrueSizeRecorded() throws {
        let blob = String(repeating: "A", count: 50_000)
        log.noteIncoming(.response(JSONRPCResponse(
            id: .number(1), outcome: .result(.object(["data": .string(blob)])))))
        let row = try XCTUnwrap(records().first)
        let body = try XCTUnwrap(row["body"] as? String)
        XCTAssertLessThanOrEqual(body.count, MCPRPCLog.maxBodyCharacters + 1)
        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertGreaterThan(try XCTUnwrap(row["bodyBytes"] as? Int), 50_000)
    }

    /// The same rule as one directory over: a foreign error's own localized string never
    /// reaches a file this app writes.
    func testAFailureRecordsAppAuthoredTextOnly() throws {
        log.noteFailure(MCPTransportError.timedOut, method: "tools/call", requestID: .number(3))
        let row = try XCTUnwrap(records().first)
        XCTAssertEqual(row["kind"] as? String, "failure")
        XCTAssertEqual(row["method"] as? String, "tools/call")
        XCTAssertTrue(try XCTUnwrap(row["errorMessage"] as? String).contains("did not answer in time"))
    }

    func testAnErrorWithNoDescriptionStillRecordsSomething() throws {
        struct Opaque: Error {}
        log.noteFailure(Opaque())
        let row = try XCTUnwrap(records().first)
        XCTAssertEqual(row["errorMessage"] as? String, "the operation failed")
    }

    // MARK: - Lifecycle events

    func testTheLifecycleEventsEachNameThemselves() throws {
        log.noteConnect(url: try XCTUnwrap(URL(string: "https://example.com/mcp")))
        log.noteEra(.modern, protocolVersion: MCPConstants.modernProtocolVersion, how: "server/discover answered")
        log.noteList(toolCount: 12, pages: 2)
        log.notePin(tool: "GetPortfolio", state: "changed")
        log.noteClose(reason: "the connection was closed")

        let rows = try records()
        XCTAssertEqual(rows.map { $0["kind"] as? String }, ["connect", "era", "list", "pin", "close"])
        XCTAssertEqual(rows[0]["detail"] as? String, "https://example.com/mcp")
        XCTAssertTrue(try XCTUnwrap(rows[2]["detail"] as? String).contains("12 tools"))
        XCTAssertTrue(try XCTUnwrap(rows[3]["detail"] as? String).contains("GetPortfolio"))
    }

    /// One JSON object per line, so a torn tail costs one row rather than the file.
    func testEveryRecordIsExactlyOneLine() throws {
        for index in 0..<5 {
            log.noteOutgoing(.notification(JSONRPCNotification(
                method: "n\(index)", params: .object(["text": .string("a\nb")]))))
        }
        let lines = rawText().split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 5)
    }

    func testTheDirectoryIsCreatedOnFirstWrite() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        log.noteClose(reason: "x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// A notification arriving FROM the server is a distinct row from one this client sent.
    func testAnIncomingNotificationIsRecordedWithItsDirection() throws {
        log.noteIncoming(.notification(JSONRPCNotification(
            method: "notifications/tools/list_changed", params: .object(["reason": .string("edit")]))))
        let row = try XCTUnwrap(records().first)
        XCTAssertEqual(row["kind"] as? String, "notification")
        XCTAssertEqual(row["direction"] as? String, "in")
        XCTAssertEqual(row["method"] as? String, "notifications/tools/list_changed")
    }

    /// A frame with no payload records no body rather than an empty one — `jq` can then tell
    /// "nothing was sent" from "an empty object was".
    func testAFrameWithNoPayloadRecordsNoBody() throws {
        log.noteOutgoing(.notification(JSONRPCNotification(method: "notifications/initialized")))
        let row = try XCTUnwrap(records().first)
        XCTAssertNil(row["body"])
        XCTAssertNil(row["bodyBytes"])
    }
}
