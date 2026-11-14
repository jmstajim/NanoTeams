import Foundation

/// What the two eras actually put on the wire, as pure functions.
///
/// Kept out of `MCPClient` because every one of these is a fact about the protocol, not about
/// a connection: the shape of `_meta`, where a server hides its tool page cursor, which member
/// carries the negotiated version. A pure enum can be exercised against a recorded frame
/// without an actor, a socket or a clock — and the frames are the half that a spec revision
/// changes.
nonisolated enum MCPWire {

    // MARK: - Method names

    /// 2026-07-28's replacement for the whole `initialize` handshake.
    static let discoverMethod = "server/discover"
    /// 2026-07-28 long-lived POST opening a server-to-client notification stream.
    static let subscriptionsListenMethod = "subscriptions/listen"
    static let initializeMethod = "initialize"
    static let initializedNotification = "notifications/initialized"
    static let toolsListMethod = "tools/list"
    static let toolsCallMethod = "tools/call"
    static let resourcesListMethod = "resources/list"
    static let resourceTemplatesListMethod = "resources/templates/list"
    static let resourcesReadMethod = "resources/read"
    static let promptsListMethod = "prompts/list"
    static let promptsGetMethod = "prompts/get"
    static let pingMethod = "ping"
    static let cancelledNotification = "notifications/cancelled"
    static let progressNotification = "notifications/progress"
    /// Both spellings of "my tool list moved" — the legacy nested one and the modern flat one.
    static let toolListChangedNotifications: Set<String> = [
        "notifications/tools/list_changed", "notifications/tools_list_changed",
    ]
    /// Both spellings of "my resource list moved" — the legacy nested one and the modern flat one.
    static let resourceListChangedNotifications: Set<String> = [
        "notifications/resources/list_changed", "notifications/resources_list_changed",
    ]
    /// Both spellings of "my prompt list moved" — the legacy nested one and the modern flat one.
    static let promptListChangedNotifications: Set<String> = [
        "notifications/prompts/list_changed", "notifications/prompts_list_changed",
    ]
    /// Every notification that means the server's reviewable catalogue moved.
    static let catalogueListChangedNotifications: Set<String> =
        toolListChangedNotifications
            .union(resourceListChangedNotifications)
            .union(promptListChangedNotifications)

    // MARK: - Client identity and capabilities

    static let clientName = "NanoTeams"

    /// `{}` — and the emptiness is the design.
    ///
    /// Declaring `sampling` would let a server ask this client to run a model prompt of the
    /// server's choosing; `elicitation` would let it ask the user questions; `roots` would
    /// tell it the filesystem layout. None is needed to call a tool, and each is a channel an
    /// untrusted server could drive. A capability that is never declared cannot be exercised,
    /// so the refusal is structural rather than a check somebody has to remember.
    static func clientCapabilities() -> JSONValue { .object([:]) }

    static func clientInfo(version: String) -> JSONValue {
        .object(["name": .string(clientName), "version": .string(version)])
    }

    // MARK: - The 2026-07-28 per-request fields

    /// The `_meta` keys a 2026-07-28 request carries (basic/index, "Per-request protocol
    /// fields"), under the prefix the revision reserves for itself — spelled here and nowhere
    /// else. `protocolVersion` and `clientCapabilities` are REQUIRED on every request: "A request
    /// missing any required field is malformed; the server MUST reject it with JSON-RPC error
    /// code -32602 (Invalid params). On HTTP, the response status MUST be 400 Bad Request."
    /// `clientInfo` SHOULD be there.
    ///
    /// Until 2026-10-28 they were the bare `protocolVersion`, `clientInfo` and `capabilities`:
    /// a conforming server refused every modern request, the probe fell back, and the app spoke
    /// the legacy era to every modern server it met. Tests spell the spec's literal, never these
    /// constants, so a wrong spelling here cannot pass with them.
    static let protocolVersionMetaKey = "io.modelcontextprotocol/protocolVersion"
    static let clientCapabilitiesMetaKey = "io.modelcontextprotocol/clientCapabilities"
    static let clientInfoMetaKey = "io.modelcontextprotocol/clientInfo"
    /// Where a 2026-07-28 result names its server (basic/index, "Per-response protocol fields"):
    /// self-reported, for display — "Implementations SHOULD NOT use them to change the behavior
    /// of the client" (`MCPServerInfo`).
    static let serverInfoMetaKey = "io.modelcontextprotocol/serverInfo"

    private static func modernMetaMembers(protocolVersion: String, clientVersion: String) -> [String: JSONValue] {
        [
            protocolVersionMetaKey: .string(protocolVersion),
            clientCapabilitiesMetaKey: clientCapabilities(),
            clientInfoMetaKey: clientInfo(version: clientVersion),
        ]
    }

    /// The modern era carries version and capabilities in `params._meta` of EVERY request,
    /// because there is no handshake to carry them once. Adds `_meta` to a params object,
    /// creating the object if the method has no other parameters. A non-object params value is
    /// left alone — the spec has none, and wrapping one would change what the server receives.
    /// Merged into a `_meta` the params already carry — a progress token — rather than replacing
    /// it.
    static func withModernMeta(_ params: JSONValue?, protocolVersion: String, clientVersion: String) -> JSONValue {
        withMeta(params, modernMetaMembers(protocolVersion: protocolVersion, clientVersion: clientVersion))
    }

    /// Names the request as its own progress token — `_meta.progressToken`, in both eras.
    /// A receiver may report progress only under a token the request supplied.
    static func withProgressToken(_ params: JSONValue?, _ id: JSONRPCID) -> JSONValue {
        withMeta(params, ["progressToken": id.jsonValue])
    }

    /// `members` set in the params' `_meta`, the object created where there was none. A
    /// non-object params value comes back unchanged.
    private static func withMeta(_ params: JSONValue?, _ members: [String: JSONValue]) -> JSONValue {
        guard case .object(var object)? = params else {
            if let params, !params.isObject { return params }
            return .object(["_meta": .object(members)])
        }
        var meta = object["_meta"]?.objectValue ?? [:]
        for (key, value) in members { meta[key] = value }
        object["_meta"] = .object(meta)
        return .object(object)
    }

    static func initializeParams(protocolVersion: String, clientVersion: String) -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": clientCapabilities(),
            "clientInfo": clientInfo(version: clientVersion),
        ])
    }

    // MARK: - Reading results

    /// A version string longer than this is cut: every revision name is a date, and the value
    /// is quoted into the Settings status row and the frame log.
    static let maxVersionCharacters = 64
    /// How many of a `-32022`'s versions are read. The refusal lists them in one sentence.
    static let maxListedVersions = 16

    /// The version the server agreed to. Legacy `initialize` names it in the result; a modern
    /// `server/discover` names the list it supports instead (`supportedVersions(fromDiscoverResult:)`),
    /// and is read for this only when it names none (`MCPEraVerdict`).
    ///
    /// Cleaned like every server-supplied version (`cleanedVersion`): the legacy era quotes it
    /// in its refusal, and the modern one sends it back in `MCP-Protocol-Version`.
    static func negotiatedProtocolVersion(from result: JSONValue) -> String? {
        result.objectValue?["protocolVersion"]?.stringValue.flatMap(cleanedVersion)
    }

    /// The versions a `-32022` says it does speak. Read from several spellings because this is
    /// the one error whose DATA decides whether to retry or to give up, and a server that
    /// spells it `versions` instead of `supported` would otherwise read as "speaks nothing".
    ///
    /// The list reaches the Settings status row joined into one sentence
    /// (`MCPClientError.unsupportedProtocolVersion`), so each entry is cleaned
    /// (`cleanedVersion`), an entry that cleans to nothing is dropped, and when
    /// `cappedForDisplay` is true at most `maxListedVersions` are returned (`MCPEraVerdict`
    /// checks membership against the full cleaned list before capping the refusal).
    static func supportedVersions(
        fromErrorData data: JSONValue?,
        cappedForDisplay: Bool = true
    ) -> [String] {
        guard let object = data?.objectValue else { return [] }
        for key in ["supported", "supportedVersions", "versions", "protocolVersions"] {
            if let array = object[key]?.arrayValue {
                let cleaned = array.lazy.compactMap(\.stringValue).compactMap(cleanedVersion)
                return cappedForDisplay ? Array(cleaned.prefix(maxListedVersions)) : Array(cleaned)
            }
            if let single = object[key]?.stringValue { return cleanedVersion(single).map { [$0] } ?? [] }
        }
        return []
    }

    /// The revisions a 2026-07-28 `DiscoverResult` names — "`supportedVersions`: Protocol versions
    /// the server supports. The client should choose one of these for subsequent requests"
    /// (server/discover) — cleaned and, when `cappedForDisplay` is true, bounded as a `-32022`'s
    /// list is; `nil` when the result names no list at all, which is not the same answer as an
    /// empty one (`MCPEraVerdict`).
    static func supportedVersions(
        fromDiscoverResult result: JSONValue,
        cappedForDisplay: Bool = true
    ) -> [String]? {
        guard let array = result.objectValue?["supportedVersions"]?.arrayValue else { return nil }
        let cleaned = array.lazy.compactMap(\.stringValue).compactMap(cleanedVersion)
        return cappedForDisplay ? Array(cleaned.prefix(maxListedVersions)) : Array(cleaned)
    }

    /// A server-supplied version as `MCPServerInfo` reads a server's name — one line, nothing
    /// hidden, `nil` when that leaves nothing — and capped at `maxVersionCharacters`.
    private static func cleanedVersion(_ raw: String) -> String? {
        let line = MCPTextSanitizer.singleLine(raw)
        return line.isEmpty ? nil : MCPTextSanitizer.capped(line, at: maxVersionCharacters)
    }

    /// What a 2026-07-28 result says it is (basic/index, "ResultType").
    nonisolated enum ResultType: Hashable, Sendable {
        /// The answer: `"complete"`, or no `resultType` at all — "clients MUST treat an absent
        /// `resultType` as `"complete"`".
        case complete
        /// `"input_required"`: the server needs input — an elicitation, a sampling, the roots —
        /// before it will finish, asked for in a multi round-trip request this client does not
        /// make: it declares no capability and retries no call.
        case inputRequired
        /// Any other value, as one capped visible line (a value that is not a string, in its
        /// JSON spelling): "A resultType of any value unrecognized by the client MUST be
        /// considered invalid."
        case unrecognized(String)
    }

    static let inputRequiredResultType = "input_required"

    /// Reads `resultType` from a 2026-07-28 result (basic/index, "ResultType"): absent,
    /// explicit `null`, and `"complete"` are all `.complete`; `"input_required"` is
    /// `.inputRequired`; anything else — an unknown string, a non-string — is `.unrecognized`,
    /// named as one capped visible line.
    static func resultType(of result: JSONValue) -> ResultType {
        guard let value = result.objectValue?["resultType"], value != .null else { return .complete }
        switch value.stringValue {
        case "complete": return .complete
        case inputRequiredResultType: return .inputRequired
        case let text?: return .unrecognized(cleanedVersion(text) ?? "(blank)")
        case nil: return .unrecognized(cleanedVersion(value.canonicalJSONString()) ?? "(blank)")
        }
    }

    /// How long the server says its catalogue stays valid. Floored by
    /// `MCPConstants.minimumCatalogueTTL` at the caller — a server naming 100 ms would
    /// otherwise re-list between every tool call.
    static func catalogueTTL(from result: JSONValue) -> TimeInterval? {
        guard let object = result.objectValue else { return nil }
        let container = object["_meta"]?.objectValue ?? object
        if let milliseconds = container["ttlMs"]?.intValue { return TimeInterval(milliseconds) / 1000 }
        if let milliseconds = container["ttlMs"]?.doubleValue { return milliseconds / 1000 }
        return nil
    }

    /// Whether a 2026-07-28 `DiscoverResult` advertises server-initiated notifications —
    /// either a `subscriptions` capability object or any capability table naming
    /// `"listChanged": true`.
    static func advertisesSubscriptions(inDiscoverResult result: JSONValue) -> Bool {
        guard let capabilities = result.objectValue?["capabilities"]?.objectValue else { return false }
        if capabilities["subscriptions"]?.isObject == true { return true }
        return capabilities.values.contains { $0.objectValue?["listChanged"]?.boolValue == true }
    }

    /// Whether a handshake result (`server/discover` or `initialize`) declares the `resources`
    /// capability object.
    static func advertisesResources(inHandshakeResult result: JSONValue) -> Bool {
        result.objectValue?["capabilities"]?.objectValue?["resources"]?.isObject == true
    }

    /// Whether a handshake result (`server/discover` or `initialize`) declares the `prompts`
    /// capability object.
    static func advertisesPrompts(inHandshakeResult result: JSONValue) -> Bool {
        result.objectValue?["capabilities"]?.objectValue?["prompts"]?.isObject == true
    }

    private static func listPage(
        from result: JSONValue,
        key: String
    ) -> (items: [JSONValue], nextCursor: String?) {
        let object = result.objectValue ?? [:]
        let items = object[key]?.arrayValue ?? []
        let cursor = object["nextCursor"]?.stringValue
        return (items, (cursor?.isEmpty ?? true) ? nil : cursor)
    }

    /// One page of `tools/list`, or of a `server/discover` that inlined its tools.
    static func toolsPage(from result: JSONValue) -> (tools: [JSONValue], nextCursor: String?) {
        let page = listPage(from: result, key: "tools")
        return (page.items, page.nextCursor)
    }

    /// One page of `resources/list`.
    static func resourcesPage(from result: JSONValue) -> (resources: [JSONValue], nextCursor: String?) {
        let page = listPage(from: result, key: "resources")
        return (page.items, page.nextCursor)
    }

    /// One page of `resources/templates/list`.
    static func resourceTemplatesPage(
        from result: JSONValue
    ) -> (resourceTemplates: [JSONValue], nextCursor: String?) {
        let page = listPage(from: result, key: "resourceTemplates")
        return (page.items, page.nextCursor)
    }

    /// One page of `prompts/list`.
    static func promptsPage(from result: JSONValue) -> (prompts: [JSONValue], nextCursor: String?) {
        let page = listPage(from: result, key: "prompts")
        return (page.items, page.nextCursor)
    }

    /// A `tools/call` reply. `isError` defaults to false, and a non-boolean value is read as
    /// false rather than as truthy — a server cannot turn a success into a failure, or the
    /// reverse, through a type confusion.
    static func callResult(from result: JSONValue) -> MCPCallToolResult {
        let object = result.objectValue ?? [:]
        return MCPCallToolResult(
            contentBlocks: object["content"]?.arrayValue ?? [],
            structuredContent: object["structuredContent"],
            isError: object["isError"]?.boolValue ?? false)
    }

    /// A `resources/read` reply mapped into the same `MCPCallToolResult` block shape
    /// (`{"type": "resource", "resource": item}`) that `MCPToolResultMapper` and
    /// `MCPClient.scrubbingOwnSecrets` already consume.
    static func resourceReadResult(from result: JSONValue) -> MCPCallToolResult {
        let contents = result.objectValue?["contents"]?.arrayValue ?? []
        let blocks: [JSONValue] = contents.map { item in
            .object(["type": .string("resource"), "resource": item])
        }
        return MCPCallToolResult(contentBlocks: blocks, structuredContent: nil, isError: false)
    }

    /// A `prompts/get` reply after secret scrubbing.
    static func promptGetResult(from result: JSONValue) -> MCPPromptGetResult {
        let object = result.objectValue ?? [:]
        let rawDescription = object["description"]?.stringValue.map(MCPTextSanitizer.sanitizeData)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let description = (rawDescription?.isEmpty == false) ? rawDescription : nil
        let rawMessages = object["messages"]?.arrayValue ?? []
        let messages: [MCPPromptGetResult.Message] = rawMessages.compactMap { entry in
            guard let msgObj = entry.objectValue else { return nil }
            let role = msgObj["role"]?.stringValue.map(MCPTextSanitizer.singleLine) ?? "user"
            let text = renderPromptContent(msgObj["content"])
            guard !text.isEmpty else { return nil }
            return MCPPromptGetResult.Message(role: role.isEmpty ? "user" : role, text: text)
        }
        return MCPPromptGetResult(description: description, messages: messages)
    }

    private static func renderPromptContent(_ content: JSONValue?) -> String {
        guard let obj = content?.objectValue else { return "" }
        if obj["type"]?.stringValue == "resource", let res = obj["resource"]?.objectValue {
            let uri = res["uri"]?.stringValue.map(MCPTextSanitizer.singleLine) ?? ""
            if let text = res["text"]?.stringValue {
                let cleaned = MCPTextSanitizer.sanitizeData(text)
                return uri.isEmpty ? cleaned : "[\(uri)]\n\(cleaned)"
            }
            return uri
        }
        return obj["text"]?.stringValue.map(MCPTextSanitizer.sanitizeData) ?? ""
    }

    static func toolsCallParams(name: String, arguments: JSONValue) -> JSONValue {
        .object(["name": .string(name), "arguments": arguments.isObject ? arguments : .object([:])])
    }

    static func resourcesReadParams(uri: String) -> JSONValue {
        .object(["uri": .string(uri)])
    }

    static func promptsGetParams(name: String, arguments: [String: String]) -> JSONValue {
        if arguments.isEmpty {
            return .object(["name": .string(name)])
        }
        return .object([
            "name": .string(name),
            "arguments": .object(arguments.mapValues { .string($0) }),
        ])
    }

    static func toolsListParams(cursor: String?) -> JSONValue? {
        cursor.map { .object(["cursor": .string($0)]) }
    }

    /// The `notifications` filter a 2026-07-28 `subscriptions/listen` request carries
    /// (SEP-2575): each notification kind is opt-in ("Each type is opt-in; the server MUST NOT
    /// send types not requested here"), and `notifications` is a required member of
    /// `SubscriptionsListenRequestParams` (the Python SDK `mcp==2.3.0` rejects a request
    /// missing it with `-32602` `Invalid request parameters`).
    static func subscriptionsListenParams() -> JSONValue {
        .object([
            "notifications": .object([
                "toolsListChanged": .bool(true),
                "resourcesListChanged": .bool(true),
                "promptsListChanged": .bool(true),
            ]),
        ])
    }

    static func cancelledParams(requestID: JSONRPCID, reason: String) -> JSONValue {
        .object([
            "requestId": requestID.jsonValue,
            "reason": .string(reason),
        ])
    }

    /// The id a `notifications/progress` belongs to, so the inactivity timer can be reset for
    /// the right request and only that one. A `requestId` is not one: that is what a
    /// cancellation names, and the server's cancellations name its own requests.
    static func progressToken(from params: JSONValue?) -> String? {
        guard let token = params?.objectValue?["progressToken"] else { return nil }
        return token.stringValue ?? token.intValue.map(String.init)
    }
}

nonisolated extension JSONRPCID {
    /// The id as it goes back on the wire — a number stays a number.
    var jsonValue: JSONValue {
        switch self {
        case .number(let value): return .int(value)
        case .string(let value): return .string(value)
        }
    }
}

/// What a server says about itself.
///
/// **`instructions` is deliberately not here.** The legacy `initialize` result carries a free
/// text field whose only purpose is to be pasted into a model's prompt — which is tool
/// poisoning with the tool step removed. This client does not read it, so there is no path
/// from that field to a prompt, and no check anybody has to remember to keep.
///
/// Everything here is SELF-REPORTED and is labelled that way wherever it is shown. A name is
/// not an identity; the trust record is keyed by the server's id and its tools' hashes.
nonisolated struct MCPServerInfo: Hashable, Sendable {
    let name: String?
    let title: String?
    let version: String?

    static let unknown = MCPServerInfo(name: nil, title: nil, version: nil)

    /// A field longer than this is cut: each is quoted into the server-detail header as a
    /// label, never read as a document.
    static let maxFieldCharacters = 120

    /// Reads the server's identity off either era's handshake result — the legacy `initialize`
    /// result's `serverInfo`, or where a 2026-07-28 result carries it, `_meta` under
    /// `MCPWire.serverInfoMetaKey` — sanitizing each field: these strings reach a Settings row,
    /// and a zero-width payload in a server name is a name that reads differently in two places.
    /// Each is capped at `maxFieldCharacters`.
    init(result: JSONValue) {
        let object = result.objectValue
        let info = object?["serverInfo"]?.objectValue
            ?? object?["_meta"]?.objectValue?[MCPWire.serverInfoMetaKey]?.objectValue
            ?? object?["server"]?.objectValue ?? [:]
        self.init(
            name: Self.clean(info["name"]),
            title: Self.clean(info["title"]),
            version: Self.clean(info["version"]))
    }

    init(name: String?, title: String?, version: String?) {
        self.name = name
        self.title = title
        self.version = version
    }

    private static func clean(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue else { return nil }
        let cleaned = MCPTextSanitizer.singleLine(text)
        return cleaned.isEmpty ? nil : MCPTextSanitizer.capped(cleaned, at: maxFieldCharacters)
    }

    /// What the server-detail header shows beside "self-reported".
    var displayLabel: String? {
        let label = [title ?? name, version].compactMap { $0 }.joined(separator: " ")
        return label.isEmpty ? nil : label
    }
}

/// What `prompts/get` returns after secret scrubbing and text cleaning.
nonisolated struct MCPPromptGetResult: Hashable, Sendable {
    nonisolated struct Message: Hashable, Sendable {
        let role: String
        let text: String
    }

    let description: String?
    let messages: [Message]

    /// Renders the prompt messages into the body text staged into a `SkillClip`.
    var renderedText: String {
        let body = messages.map(\.text).joined(separator: "\n\n")
        return body.isEmpty ? (description ?? "") : body
    }
}
