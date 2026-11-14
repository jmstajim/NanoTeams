import Foundation

/// What a conforming 2026-07-28 server refuses BEFORE it reads a request — the checks the HTTP
/// fakes run in their conforming mode (`FakeMCPHTTPServer` in every mode that answers
/// `server/discover`, `ScriptedMCPHTTPSession.conforming`), so a malformed modern request can no
/// longer pass a fake that accepts any `_meta`. One home for both fakes: two copies of a rule
/// drift apart.
///
/// **Spelled from the spec, never from the app.** Every key and code here is the revision's own
/// literal (modelcontextprotocol.io/specification/2026-07-28, basic/index "Per-request protocol
/// fields", basic/transports/streamable-http "Server Validation"). A fixture that read
/// `MCPWire`'s spelling would move with it, and a wrong spelling would pass its own check — the
/// shape that kept the app's bare `protocolVersion` / `capabilities` keys green against every
/// fake, while a conforming server refused every modern request and the app ran legacy.
///
/// The order is the reference server's (python-sdk `classify_inbound_request`): the required
/// envelope keys first — "A request missing any required field is malformed; the server MUST
/// reject it with JSON-RPC error code -32602 (Invalid params). On HTTP, the response status MUST
/// be 400 Bad Request." — then the headers against the body: `MCP-Protocol-Version` against
/// `io.modelcontextprotocol/protocolVersion`, `Mcp-Method` against `method`, and for `tools/call`
/// `Mcp-Name` against `params.name` and every `Mcp-Param-*` header declared by the tool's
/// `x-mcp-header` against `params.arguments` after the Base64 sentinel is decoded — "servers MUST
/// return HTTP status 400 Bad Request and MUST include a JSON-RPC error response" with `-32020`
/// (`HeaderMismatch`).
///
/// Every request carrying `MCP-Protocol-Version: 2026-07-28` OR carrying a modern `_meta`
/// envelope (`io.modelcontextprotocol/protocolVersion` or
/// `io.modelcontextprotocol/clientCapabilities`) is checked — including `initialize`. That is
/// deliberately STRICTER than a dual-era server (by the spec, receiving `initialize` selects
/// legacy semantics regardless of headers): this check holds our client to never sending modern
/// headers on a legacy `initialize` (`D-M8`), and to never sending a modern envelope without its
/// matching `MCP-Protocol-Version` header (`D-M9` pt. 1). The legacy opening `initialize` carries
/// no `MCP-Protocol-Version` header at all, and everything after a legacy handshake carries the
/// negotiated legacy header; "header requirements for notification POSTs are not defined by this
/// revision".
enum ConformingMCPServerCheck {

    /// One `x-mcp-header` parameter declared on a tool's `inputSchema`: `path` is the chain of
    /// `properties` keys to the annotated property, and `header` is the `Mcp-Param-<token>` header
    /// name a conforming client mirrors its value into.
    struct HeaderParameter: Equatable, Sendable {
        let path: [String]
        let header: String

        init(_ key: String, header: String) {
            self.path = [key]
            self.header = header
        }

        init(path: [String], header: String) {
            self.path = path
            self.header = header
        }
    }

    /// One refusal, as the server's HTTP status and its JSON-RPC error.
    struct Refusal: Equatable {
        let status: Int
        let code: Int
        let message: String

        /// The HTTP body a conforming server sends: the JSON-RPC error answering the request.
        func body(answering id: Any?) -> String {
            let message = message.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"jsonrpc":"2.0","id":"# + Self.idLiteral(id)
                + #","error":{"code":"# + String(code) + #","message":""# + message + #""}}"#
        }

        private static func idLiteral(_ id: Any?) -> String {
            switch id {
            case let number as Int: return String(number)
            case let text as String: return "\"\(text)\""
            default: return "null"
            }
        }
    }

    /// The revision this fixture serves, spelled as the spec spells it.
    static let modernRevision = "2026-07-28"

    static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let clientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"

    /// Extracts `x-mcp-header` declarations by tool name from a `tools/list` JSON-RPC response body.
    static func headerParameters(inToolsListBody body: Data?) -> [String: [HeaderParameter]] {
        guard let body,
              let frame = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let result = frame["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]]
        else { return [:] }
        var byTool: [String: [HeaderParameter]] = [:]
        for tool in tools {
            guard let name = tool["name"] as? String,
                  let schema = tool["inputSchema"] as? [String: Any]
            else { continue }
            let params = extractHeaderParameters(fromSchema: schema, prefix: [])
            if !params.isEmpty { byTool[name] = params }
        }
        return byTool
    }

    private static func extractHeaderParameters(
        fromSchema schema: [String: Any], prefix: [String]
    ) -> [HeaderParameter] {
        guard let properties = schema["properties"] as? [String: [String: Any]] else { return [] }
        var found: [HeaderParameter] = []
        for key in properties.keys.sorted() {
            guard let property = properties[key] else { continue }
            let path = prefix + [key]
            if let token = property["x-mcp-header"] as? String, !token.isEmpty {
                found.append(HeaderParameter(path: path, header: "Mcp-Param-" + token))
            }
            found.append(contentsOf: extractHeaderParameters(fromSchema: property, prefix: path))
        }
        return found
    }

    /// The refusal a conforming server gives `body` sent with these headers, or `nil` when it
    /// would read the request. `header` looks a field up by name, case-insensitively.
    static func refusal(
        header: (String) -> String?,
        body: Data?,
        toolHeaderParameters: [String: [HeaderParameter]] = [:]
    ) -> Refusal? {
        guard let body,
              let frame = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = frame["method"] as? String,
              frame["id"] != nil
        else { return nil }

        let params = frame["params"] as? [String: Any]
        let meta = params?["_meta"] as? [String: Any]
        let carriesModernHeader = header("MCP-Protocol-Version") == modernRevision
        let carriesModernEnvelope = meta?[protocolVersionKey] != nil || meta?[clientCapabilitiesKey] != nil
        guard carriesModernHeader || carriesModernEnvelope else { return nil }

        var missing: [String] = []
        if !(meta?[protocolVersionKey] is String) { missing.append(protocolVersionKey) }
        if !(meta?[clientCapabilitiesKey] is [String: Any]) { missing.append(clientCapabilitiesKey) }
        if !missing.isEmpty {
            return Refusal(
                status: 400, code: -32602,
                message: "Invalid params: params._meta is missing the required envelope key(s): "
                    + missing.joined(separator: ", "))
        }

        let enveloped = meta?[protocolVersionKey] as? String
        if header("MCP-Protocol-Version") != enveloped {
            return headerMismatch("MCP-Protocol-Version does not match \(protocolVersionKey)")
        }
        if header("Mcp-Method") != method {
            return headerMismatch("Mcp-Method does not match the body's method")
        }
        if method == "tools/call" {
            let toolName = params?["name"] as? String
            if header("Mcp-Name").map(decodedSentinel) != toolName {
                return headerMismatch("Mcp-Name does not match params.name")
            }
            if let toolName, let declarations = toolHeaderParameters[toolName] {
                let arguments = params?["arguments"] as? [String: Any]
                for param in declarations {
                    let pathLabel = param.path.joined(separator: ".")
                    let bodyValue = instanceValue(at: param.path, in: arguments)
                    if bodyValue == nil || bodyValue is NSNull {
                        if header(param.header) != nil {
                            return headerMismatch(
                                "\(param.header) is present when params.arguments.\(pathLabel) is omitted or null")
                        }
                    } else {
                        guard let actual = header(param.header).map(decodedSentinel) else {
                            return headerMismatch(
                                "\(param.header) is missing for params.arguments.\(pathLabel)")
                        }
                        guard let expected = bodyValue.flatMap(scalarText), actual == expected else {
                            return headerMismatch(
                                "\(param.header) does not match params.arguments.\(pathLabel)")
                        }
                    }
                }
            }
        }
        if method == "resources/read" {
            let uri = params?["uri"] as? String
            if header("Mcp-Name").map(decodedSentinel) != uri {
                return headerMismatch("Mcp-Name does not match params.uri")
            }
        }
        if method == "prompts/get" {
            let promptName = params?["name"] as? String
            if header("Mcp-Name").map(decodedSentinel) != promptName {
                return headerMismatch("Mcp-Name does not match params.name")
            }
        }
        return nil
    }

    private static func instanceValue(at path: [String], in arguments: [String: Any]?) -> Any? {
        guard let arguments, !path.isEmpty else { return nil }
        var current: Any = arguments
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    private static func scalarText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return nil
    }

    private static func headerMismatch(_ detail: String) -> Refusal {
        Refusal(status: 400, code: -32020, message: "Header mismatch: \(detail)")
    }

    /// `=?base64?…?=` decoded, as the spec has a server do "before comparing it to the
    /// corresponding request body value"; a plain value is itself.
    private static func decodedSentinel(_ value: String) -> String {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?="), value.count >= 11,
              let data = Data(base64Encoded: String(value.dropFirst(9).dropLast(2))),
              let text = String(data: data, encoding: .utf8)
        else { return value }
        return text
    }
}
