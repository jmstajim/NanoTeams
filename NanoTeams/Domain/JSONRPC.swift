import Foundation

/// JSON-RPC 2.0 frames, transport-neutral.
///
/// MCP narrows the base protocol in two ways this file enforces, because both are
/// correlation bugs waiting to happen rather than style preferences:
///
///  - **No batches.** A JSON array at the top level is refused outright. Accepting one
///    would mean a single HTTP body could carry several replies, and the in-flight table
///    (`MCPClient`) resolves exactly one continuation per frame.
///  - **No `"id": null`.** Base JSON-RPC allows it on an error reply to an unparseable
///    request; MCP forbids it. A null id correlates with nothing, so a frame carrying one
///    would either resolve an arbitrary request or leak a continuation forever.

// MARK: - Identity

/// A request id. MCP permits a string or a number; this client only ever ISSUES numbers
/// (monotonic, per connection), but a server's own request — legacy era only — may use
/// either, and its reply has to echo the spelling it arrived in.
///
/// Deliberately NOT `Codable`. Both directions already exist and are hand-written, because
/// both have to be: `JSONRPCCodec.decodeID` REFUSES an explicit `null` (a `Codable` decoder
/// cannot tell that from an absent member), and `idValue` writes a number as `.int` so the
/// canonical form does not print `1.0`. A synthesized conformance beside them would be a
/// second spelling that nothing calls and nothing checks.
nonisolated enum JSONRPCID: Sendable, Hashable {
    case number(Int)
    case string(String)

    /// Log-safe rendering. Never interpolate the enum itself into a log line — the
    /// `string` spelling is server-controlled text.
    var description: String {
        switch self {
        case .number(let value): return String(value)
        case .string(let value): return value
        }
    }
}

// MARK: - Frames

nonisolated struct JSONRPCRequest: Sendable, Hashable {
    let id: JSONRPCID
    let method: String
    let params: JSONValue?

    init(id: JSONRPCID, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

nonisolated struct JSONRPCNotification: Sendable, Hashable {
    let method: String
    let params: JSONValue?

    init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

nonisolated struct JSONRPCError: Sendable, Hashable, Error {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A reply. `result` and `error` are mutually exclusive in JSON-RPC, so they are one
/// enum here rather than two optionals — the "both present" and "neither present"
/// quadrants do not exist and cannot be mishandled downstream.
nonisolated struct JSONRPCResponse: Sendable, Hashable {
    let id: JSONRPCID
    let outcome: Outcome

    nonisolated enum Outcome: Sendable, Hashable {
        case result(JSONValue)
        case failure(JSONRPCError)
    }

    var result: JSONValue? {
        if case .result(let value) = outcome { return value }
        return nil
    }

    var error: JSONRPCError? {
        if case .failure(let error) = outcome { return error }
        return nil
    }
}

/// Anything that can arrive from a server on either era.
nonisolated enum JSONRPCIncoming: Sendable, Hashable {
    case response(JSONRPCResponse)
    /// Server → client request. Legacy era only; the 2026-07-28 revision removed the
    /// direction entirely. The client answers `ping` and refuses everything else with
    /// `methodNotFound`, because it advertises no capabilities.
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
}

// MARK: - Error codes

/// Base JSON-RPC 2.0 codes plus the three MCP added in 2026-07-28.
nonisolated enum MCPErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603

    /// `HeaderMismatch` (2026-07-28, Streamable HTTP, "Server Validation"): "The HTTP headers do
    /// not match the corresponding values in the request body, or required headers are
    /// missing/malformed." Until 2026-10-28 this constant was named `requestRefused` and
    /// described as a policy refusal; nothing read it.
    static let headerMismatch = -32020
    /// `MissingRequiredClientCapability` (2026-07-28, basic/index, "Per-request protocol
    /// fields"): "If processing a request requires a capability the client did not include in
    /// `io.modelcontextprotocol/clientCapabilities`, the server MUST return a
    /// MissingRequiredClientCapabilityError (-32021) whose `data.requiredCapabilities` lists the
    /// missing capabilities. On HTTP, the response status MUST be 400 Bad Request." This client
    /// declares none on purpose (`MCPWire.clientCapabilities`), so on the probe it is a
    /// refusal nothing here can answer (`MCPEraVerdict`).
    static let missingRequiredClientCapability = -32021
    /// Protocol-version mismatch. The 2026-07-28 revision answers `server/discover` with
    /// this code when it does not speak the version the client named — which is what makes
    /// it the era probe's "modern server" signal just as much as a successful discover:
    /// only a modern server knows the code at all.
    static let unsupportedProtocolVersion = -32022
}

// MARK: - Codec

nonisolated enum JSONRPCCodecError: Error, Equatable, LocalizedError {
    case invalidJSON
    case notAnObject
    case batchUnsupported
    case wrongVersion(String?)
    case nullID
    case missingMethod
    case responseHasNeitherResultNorError
    case malformed(String)

    /// The JSON-RPC 2.0 error code a server returns when an incoming frame fails with this
    /// error: `-32700` (`Parse error`) when the bytes are not valid JSON, and `-32600`
    /// (`Invalid Request`) when the parsed JSON value is not a valid JSON-RPC 2.0 frame.
    var rpcErrorCode: Int {
        switch self {
        case .invalidJSON:
            return MCPErrorCode.parseError
        case .notAnObject,
             .batchUnsupported,
             .wrongVersion,
             .nullID,
             .missingMethod,
             .responseHasNeitherResultNorError,
             .malformed:
            return MCPErrorCode.invalidRequest
        }
    }

    /// Reader-facing text for the RPC log, the server-status row and — through
    /// `MCPTransportError.malformedFrame` — the tool result the model reads. Says which frame
    /// property was wrong so a server author can fix it; never quotes the frame body, which
    /// may carry a secret the server echoed back.
    var errorDescription: String? { message }

    /// How much of the server's `jsonrpc` value a refusal quotes. The one member this text
    /// quotes is the server's to fill, and a frame is allowed 64 MiB: a version string is a
    /// few characters, and anything past these is not one.
    static let maxQuotedCharacters = 64

    /// Non-optional: `LocalizedError` types it `String?`, so every caller wrote
    /// `errorDescription ?? "something went wrong"` — a fallback no arm of this switch
    /// can reach.
    var message: String {
        switch self {
        case .invalidJSON:
            return "Frame could not be read: not valid JSON"
        case .notAnObject:
            return "Frame is not a JSON object."
        case .batchUnsupported:
            return "Frame is a JSON-RPC batch. MCP does not allow batches — send one message per frame."
        case .wrongVersion(let found):
            return "Frame declares jsonrpc \"\(found.map(Self.quoted) ?? "(absent)")\" — MCP requires \"2.0\"."
        case .nullID:
            return "Frame carries a null id. MCP requires a string or a number."
        case .missingMethod:
            return "Frame has neither a method nor an id — it is neither a call nor a reply."
        case .responseHasNeitherResultNorError:
            return "Reply carries neither result nor error."
        case .malformed(let detail):
            return "Frame could not be read: \(detail)"
        }
    }

    /// The server's value on one line with every hidden character and line break spelled out,
    /// and capped. Cut BEFORE it is spelled, so a 64 MiB value costs no more than a short one.
    private static func quoted(_ found: String) -> String {
        let head = String(found.prefix(maxQuotedCharacters + 1))
        return MCPTextSanitizer.capped(MCPTextSanitizer.visibleLine(head), at: maxQuotedCharacters)
    }
}

/// Encodes outgoing frames and reads incoming ones.
///
/// Decoding is hand-rolled over `JSONSerialization` rather than `Codable` for one reason:
/// `result: null` is a VALID reply (several MCP methods return nothing), and a `Codable`
/// container cannot tell "the key is absent" from "the key holds null" without the same
/// `contains` dance — while `JSONSerialization` also gives the top-level array check for free.
nonisolated enum JSONRPCCodec {

    static let version = "2.0"

    // MARK: Encoding

    static func encode(_ request: JSONRPCRequest) -> Data {
        var frame: [String: JSONValue] = [
            "jsonrpc": .string(version),
            "id": idValue(request.id),
            "method": .string(request.method),
        ]
        if let params = request.params { frame["params"] = params }
        return encodeFrame(frame)
    }

    static func encode(_ notification: JSONRPCNotification) -> Data {
        var frame: [String: JSONValue] = [
            "jsonrpc": .string(version),
            "method": .string(notification.method),
        ]
        if let params = notification.params { frame["params"] = params }
        return encodeFrame(frame)
    }

    static func encode(_ response: JSONRPCResponse) -> Data {
        switch response.outcome {
        case .result(let value):
            let frame: [String: JSONValue] = [
                "jsonrpc": .string(version),
                "id": idValue(response.id),
                "result": value,
            ]
            return encodeFrame(frame)
        case .failure(let error):
            return encodeError(error, id: response.id)
        }
    }

    /// Encodes a JSON-RPC error reply. When `id` is `nil` (a parse error or an invalid
    /// request whose `"id"` could not be read), `"id"` is omitted — MCP forbids `"id": null`.
    static func encodeError(_ error: JSONRPCError, id: JSONRPCID? = nil) -> Data {
        var payload: [String: JSONValue] = [
            "code": .int(error.code),
            "message": .string(error.message),
        ]
        if let data = error.data { payload["data"] = data }
        var frame: [String: JSONValue] = [
            "jsonrpc": .string(version),
            "error": .object(payload),
        ]
        if let id { frame["id"] = idValue(id) }
        return encodeFrame(frame)
    }

    /// `Data(_:utf8)` rather than `data(using:)`: the optional spelling has no failing case
    /// for a Swift String, and handling one made three callers carry a `try` for a branch that
    /// could not be taken.
    private static func encodeFrame(_ frame: [String: JSONValue]) -> Data {
        Data(JSONValue.object(frame).canonicalJSONString().utf8)
    }

    private static func idValue(_ id: JSONRPCID) -> JSONValue {
        switch id {
        case .number(let value): return .int(value)
        case .string(let value): return .string(value)
        }
    }

    // MARK: Decoding

    static func decode(
        _ data: Data,
        errorFallbackID: JSONRPCID? = nil
    ) throws(JSONRPCCodecError) -> JSONRPCIncoming {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONRPCCodecError.invalidJSON
        }
        if any is [Any] { throw JSONRPCCodecError.batchUnsupported }
        guard let value = JSONValue.fromFoundation(any), case .object(let frame) = value else {
            throw JSONRPCCodecError.notAnObject
        }
        return try decode(frame: frame, errorFallbackID: errorFallbackID)
    }

    static func decode(
        frame: [String: JSONValue],
        errorFallbackID: JSONRPCID? = nil
    ) throws(JSONRPCCodecError) -> JSONRPCIncoming {
        guard frame["jsonrpc"]?.stringValue == version else {
            throw JSONRPCCodecError.wrongVersion(frame["jsonrpc"]?.stringValue)
        }
        let isErrorReply = frame["method"] == nil && frame["error"] != nil
        let id = try decodeID(frame["id"], fallback: isErrorReply ? errorFallbackID : nil)

        if let method = frame["method"]?.stringValue {
            let params = frame["params"]
            if let id {
                return .request(JSONRPCRequest(id: id, method: method, params: params))
            }
            return .notification(JSONRPCNotification(method: method, params: params))
        }
        guard frame["method"] == nil else { throw JSONRPCCodecError.malformed("method is not a string") }
        guard let id else { throw JSONRPCCodecError.missingMethod }

        if let errorValue = frame["error"] {
            guard case .object(let payload) = errorValue,
                  let code = payload["code"]?.intValue,
                  let message = payload["message"]?.stringValue else {
                throw JSONRPCCodecError.malformed("error member is not {code, message}")
            }
            return .response(JSONRPCResponse(
                id: id,
                outcome: .failure(JSONRPCError(code: code, message: message, data: payload["data"]))))
        }
        guard let result = frame["result"] else {
            throw JSONRPCCodecError.responseHasNeitherResultNorError
        }
        return .response(JSONRPCResponse(id: id, outcome: .result(result)))
    }

    /// `nil` means the member is absent (a notification), unless a request-carrying POST supplies
    /// `fallback` for an error response whose `id` is omitted or `null`.
    private static func decodeID(
        _ value: JSONValue?,
        fallback: JSONRPCID? = nil
    ) throws(JSONRPCCodecError) -> JSONRPCID? {
        guard let value else { return fallback }
        switch value {
        case .null:
            if let fallback { return fallback }
            throw JSONRPCCodecError.nullID
        case .int(let number): return .number(number)
        case .string(let string): return .string(string)
        default: throw JSONRPCCodecError.malformed("id is neither a string nor an integer")
        }
    }
}
