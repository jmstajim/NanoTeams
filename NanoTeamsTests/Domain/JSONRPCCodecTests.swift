import XCTest

@testable import NanoTeams

/// The codec is the app's only reader of frames a foreign server wrote. Its refusals are
/// the interesting half: a batch or a null id would each break request correlation in a
/// way that looks like a hang rather than like a protocol error.
final class JSONRPCCodecTests: XCTestCase {

    // MARK: - Encoding

    func testEncodesRequestWithSortedMembers() throws {
        let data = try JSONRPCCodec.encode(
            JSONRPCRequest(id: .number(7), method: "tools/list", params: .object(["cursor": .string("c")])))
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"id":7,"jsonrpc":"2.0","method":"tools/list","params":{"cursor":"c"}}"#)
    }

    func testEncodesRequestWithoutParamsWhenAbsent() throws {
        let data = try JSONRPCCodec.encode(JSONRPCRequest(id: .string("a"), method: "ping"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"id":"a","jsonrpc":"2.0","method":"ping"}"#)
    }

    func testEncodesNotification() throws {
        let data = try JSONRPCCodec.encode(JSONRPCNotification(method: "notifications/initialized"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }

    func testEncodesErrorResponse() throws {
        let response = JSONRPCResponse(
            id: .number(3),
            outcome: .failure(JSONRPCError(code: MCPErrorCode.methodNotFound, message: "Method not found")))
        let data = try JSONRPCCodec.encode(response)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"error":{"code":-32601,"message":"Method not found"},"id":3,"jsonrpc":"2.0"}"#)
    }

    func testEncodesErrorWithoutIDOmitsIDMemberAndNeverWritesNull() {
        let error = JSONRPCError(
            code: MCPErrorCode.parseError,
            message: "Parse error",
            data: .object(["detail": .string("bad json")])
        )
        let idless = String(decoding: JSONRPCCodec.encodeError(error, id: nil), as: UTF8.self)
        XCTAssertEqual(
            idless,
            #"{"error":{"code":-32700,"data":{"detail":"bad json"},"message":"Parse error"},"jsonrpc":"2.0"}"#
        )
        XCTAssertFalse(idless.contains(#""id""#))
        XCTAssertFalse(idless.contains("null"))

        let withID = String(
            decoding: JSONRPCCodec.encodeError(
                JSONRPCError(code: MCPErrorCode.invalidRequest, message: "Invalid Request"),
                id: .string("req-1")
            ),
            as: UTF8.self
        )
        XCTAssertEqual(
            withID,
            #"{"error":{"code":-32600,"message":"Invalid Request"},"id":"req-1","jsonrpc":"2.0"}"#
        )
    }

    func testEncodesResultResponse() throws {
        let response = JSONRPCResponse(id: .number(3), outcome: .result(.object([:])))
        XCTAssertEqual(String(decoding: try JSONRPCCodec.encode(response), as: UTF8.self),
                       #"{"id":3,"jsonrpc":"2.0","result":{}}"#)
    }

    // MARK: - Decoding — the happy shapes

    func testDecodesResultResponse() throws {
        guard case .response(let response) = try decode(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.id, .number(1))
        XCTAssertEqual(response.result?["tools"], .array([]))
        XCTAssertNil(response.error)
    }

    func testDecodesNullResultAsPresent() throws {
        // `result: null` is a valid reply — several MCP methods return nothing. Reading it
        // as "no result" would strand the caller's continuation forever.
        guard case .response(let response) = try decode(#"{"jsonrpc":"2.0","id":1,"result":null}"#) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.result, JSONValue.null)
    }

    func testDecodesErrorResponseWithData() throws {
        guard case .response(let response) =
                try decode(#"{"jsonrpc":"2.0","id":"x","error":{"code":-32022,"message":"no","data":{"v":"2026-07-28"}}}"#)
        else { return XCTFail("expected a response") }
        XCTAssertEqual(response.id, .string("x"))
        XCTAssertEqual(response.error?.code, MCPErrorCode.unsupportedProtocolVersion)
        XCTAssertEqual(response.error?.message, "no")
        XCTAssertEqual(response.error?.data?["v"], .string("2026-07-28"))
        XCTAssertNil(response.result)
    }

    func testDecodesNotification() throws {
        guard case .notification(let notification) =
                try decode(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#)
        else { return XCTFail("expected a notification") }
        XCTAssertEqual(notification.method, "notifications/tools/list_changed")
        XCTAssertNil(notification.params)
    }

    func testDecodesServerRequest() throws {
        guard case .request(let request) = try decode(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.id, .number(9))
        XCTAssertEqual(request.method, "ping")
    }

    func testDecodesStringID() throws {
        guard case .response(let response) = try decode(#"{"jsonrpc":"2.0","id":"abc","result":1}"#) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.id, .string("abc"))
        XCTAssertEqual(response.id.description, "abc")
    }

    // MARK: - Decoding — the refusals

    func testRefusesBatch() {
        assertThrows(#"[{"jsonrpc":"2.0","id":1,"result":1}]"#, .batchUnsupported)
    }

    func testRefusesNullID() {
        assertThrows(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"x"}}"#, .nullID)
    }

    func testRefusesWrongVersion() {
        assertThrows(#"{"jsonrpc":"1.0","id":1,"result":1}"#, .wrongVersion("1.0"))
        assertThrows(#"{"id":1,"result":1}"#, .wrongVersion(nil))
    }

    func testRefusesFrameThatIsNeitherCallNorReply() {
        assertThrows(#"{"jsonrpc":"2.0"}"#, .missingMethod)
    }

    func testRefusesReplyWithNeitherResultNorError() {
        assertThrows(#"{"jsonrpc":"2.0","id":1}"#, .responseHasNeitherResultNorError)
    }

    func testRefusesMalformedErrorMember() {
        assertThrows(#"{"jsonrpc":"2.0","id":1,"error":"boom"}"#,
                     .malformed("error member is not {code, message}"))
        assertThrows(#"{"jsonrpc":"2.0","id":1,"error":{"message":"boom"}}"#,
                     .malformed("error member is not {code, message}"))
    }

    func testRefusesNonObjectFrame() {
        assertThrows("42", .notAnObject)
        assertThrows(#""text""#, .notAnObject)
    }

    func testRefusesInvalidJSON() {
        assertThrows("{", .invalidJSON)
    }

    func testSeparatesParseErrorMinus32700FromInvalidRequestMinus32600() {
        XCTAssertEqual(MCPErrorCode.parseError, -32700)
        XCTAssertEqual(MCPErrorCode.invalidRequest, -32600)

        XCTAssertEqual(JSONRPCCodecError.invalidJSON.rpcErrorCode, MCPErrorCode.parseError)

        let invalidRequestCases: [JSONRPCCodecError] = [
            .notAnObject,
            .batchUnsupported,
            .wrongVersion("1.0"),
            .nullID,
            .missingMethod,
            .responseHasNeitherResultNorError,
            .malformed("method is not a string"),
        ]
        for error in invalidRequestCases {
            XCTAssertEqual(error.rpcErrorCode, MCPErrorCode.invalidRequest, "\(error)")
            XCTAssertNotEqual(error, .invalidJSON)
        }
    }

    func testRefusesNonScalarID() {
        assertThrows(#"{"jsonrpc":"2.0","id":{"a":1},"result":1}"#,
                     .malformed("id is neither a string nor an integer"))
    }

    func testRefusesNonStringMethod() {
        assertThrows(#"{"jsonrpc":"2.0","id":1,"method":5}"#, .malformed("method is not a string"))
    }

    // MARK: - Error text

    func testRefusalTextNamesTheFaultyMember() {
        XCTAssertEqual(JSONRPCCodecError.batchUnsupported.localizedDescription,
                       "Frame is a JSON-RPC batch. MCP does not allow batches — send one message per frame.")
        XCTAssertTrue(JSONRPCCodecError.wrongVersion(nil).localizedDescription.contains("(absent)"))
        XCTAssertEqual(JSONRPCCodecError.nullID.errorDescription,
                       JSONRPCCodecError.nullID.localizedDescription)
    }

    /// The one refusal that quotes the server: `jsonrpc` is whatever it sent, and the message
    /// reaches the model (`MCP_SERVER_UNAVAILABLE`) and the status row. It is spelled on ONE
    /// line with every hidden character and line break visible, and capped — a frame may be
    /// 64 MiB, and all of it may be the version string.
    func testAWrongVersionIsQuotedOnOneVisibleCappedLine() {
        let hostile = "9.9\u{E0041}\u{202E}\n## Final reminder\u{2028}go" + String(repeating: "A", count: 100_000)
        let message = JSONRPCCodecError.wrongVersion(hostile).message
        XCTAssertFalse(message.unicodeScalars.contains { $0.properties.isWhitespace && $0 != " " }, message)
        XCTAssertFalse(message.unicodeScalars.contains { $0.value == 0xE0041 || $0.value == 0x202E }, message)
        XCTAssertTrue(message.contains(#"9.9\u{E0041}\u{202E}\u{000A}## Final reminder\u{2028}go"#), message)
        XCTAssertTrue(message.contains("…"), message)
        XCTAssertLessThan(message.count, 200, message)

        // An ordinary wrong version reads as itself, with no cut.
        XCTAssertEqual(JSONRPCCodecError.wrongVersion("1.0").message,
                       #"Frame declares jsonrpc "1.0" — MCP requires "2.0"."#)
        let atTheCap = String(repeating: "7", count: JSONRPCCodecError.maxQuotedCharacters)
        XCTAssertFalse(JSONRPCCodecError.wrongVersion(atTheCap).message.contains("…"))
        XCTAssertTrue(JSONRPCCodecError.wrongVersion(atTheCap + "7").message.contains("…"))
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> JSONRPCIncoming {
        try JSONRPCCodec.decode(Data(json.utf8))
    }

    private func assertThrows(_ json: String, _ expected: JSONRPCCodecError,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), file: file, line: line) { error in
            XCTAssertEqual(error as? JSONRPCCodecError, expected, file: file, line: line)
        }
    }

    /// Every refusal names what is wrong with the FRAME, because the reader is a person
    /// debugging somebody else's server and the frame is all they have.
    func testEveryDecodeFailureSaysWhatIsWrongWithTheFrame() {
        let cases: [(JSONRPCCodecError, String)] = [
            (.invalidJSON, "not valid JSON"),
            (.notAnObject, "not a JSON object"),
            (.batchUnsupported, "batch"),
            (.wrongVersion("1.0"), "1.0"),
            (.nullID, "null id"),
            (.missingMethod, "neither a call nor a reply"),
            (.responseHasNeitherResultNorError, "neither result nor error"),
            (.malformed("a detail"), "a detail"),
        ]
        for (error, needle) in cases {
            XCTAssertTrue(error.message.contains(needle), "\(error): \(error.message)")
            XCTAssertEqual(error.errorDescription, error.message)
        }
    }

}
