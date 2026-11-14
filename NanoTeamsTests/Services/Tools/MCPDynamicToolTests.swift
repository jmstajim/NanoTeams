import XCTest

@testable import NanoTeams

/// One external tool from the runtime's side: arguments in, envelope out, and every failure
/// leaving as an envelope rather than as a throw.
final class MCPDynamicToolTests: XCTestCase {

    /// Records what reached the wire and answers with whatever the test set.
    private final class ScriptedInvoker: MCPToolInvoking, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [MCPToolCall] = []
        var answer: Result<MCPCallToolResult, Error> =
            .success(MCPCallToolResult(contentBlocks: []))

        var received: [MCPToolCall] { lock.withLock { calls } }

        func callTool(_ call: MCPToolCall) async throws -> MCPCallToolResult {
            lock.withLock { calls.append(call) }
            return try answer.get()
        }
    }

    private var invoker: ScriptedInvoker!
    private let fileManager = FileManager.default
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        invoker = ScriptedInvoker()
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? fileManager.removeItem(at: root) }
        root = nil
        invoker = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func tool(
        originalName: String = "get_screenshot",
        properties: [String: JSONSchemaProperty] = [:],
        headerParams: [MCPHeaderParam] = [],
        attachments: URL? = nil,
        era: MCPProtocolEra = .modern,
        through invoking: (any MCPToolInvoking)? = nil
    ) throws -> MCPDynamicTool {
        let slug = try XCTUnwrap(MCPServerSlug("folio"))
        let name = try XCTUnwrap(MCPToolNaming.modelFacingName(slug: "folio", toolName: originalName))
        let descriptor = MCPToolDescriptor(
            originalName: originalName,
            modelFacingName: name,
            displayDescription: "Takes a screenshot.",
            inputSchema: JSONSchema.object(properties: properties, required: ["node"]),
            outputSchema: nil,
            annotations: .specDefaults,
            headerParams: headerParams,
            callShapeDependsOnEra: !headerParams.isEmpty,
            pinHash: "hash",
            rawTool: .object([:]),
            strippedHiddenCharacters: false)
        let entry = MCPToolsSnapshot.Entry(
            serverID: Self.serverID,
            slug: slug,
            serverDisplayName: "Folio Desktop",
            approvalMode: .manual,
            serverTrusted: false,
            alwaysAllowed: false,
            runsUnattended: false,
            descriptor: descriptor, era: era)
        return MCPDynamicTool(
            entry: entry,
            invoker: invoking ?? invoker,
            attachmentsDirectory: attachments,
            workFolderRoot: root,
            makeCallID: { "call-1" })
    }

    private static let serverID = UUID()

    private var context: ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: root, taskID: 1, runID: 0, roleID: "engineer")
    }

    private func envelope(_ result: ToolExecutionResult) throws -> [String: Any] {
        try XCTUnwrap(JSONUtilities.parseJSONDictionary(result.outputJSON))
    }

    private func errorCode(_ result: ToolExecutionResult) throws -> String {
        let error = try XCTUnwrap(try envelope(result)["error"] as? [String: Any])
        return try XCTUnwrap(error["code"] as? String)
    }

    // MARK: - The call

    func testTheSchemaTheRuntimeSeesIsTheProjectionUnderTheModelFacingName() throws {
        let tool = try tool(properties: ["node": JSONSchema.string()])
        XCTAssertEqual(tool.schema.name, "mcp__folio__get_screenshot")
        XCTAssertEqual(tool.schema.description, "Takes a screenshot.")
        XCTAssertEqual(tool.schema.parameters.required, ["node"])
    }

    /// The fold is lossy by construction, so sending the model-facing name would name a tool
    /// the server may not have — or a different one whose name folds the same way.
    func testTheServersOwnNameGoesOnTheWire() async throws {
        let tool = try tool(originalName: "get-Design Context")
        _ = await tool.handle(args: ["node": "1:2"])
        XCTAssertEqual(invoker.received.first?.toolName, "get-Design Context")
        XCTAssertEqual(tool.name, "mcp__folio__get_design_context")
    }

    func testTheCallCarriesTheServerIDAndTheCoercedArguments() async throws {
        let tool = try tool(properties: ["limit": JSONSchema.integer()])
        _ = await tool.handle(args: ["limit": "10"])
        let call = try XCTUnwrap(invoker.received.first)
        XCTAssertEqual(call.serverID, Self.serverID)
        XCTAssertEqual(call.arguments, .object(["limit": .int(10)]))
    }

    /// A header parameter reaches the call in the body and, in the modern era, mirrored as its
    /// header; the call names the era it was split for, so a session in another era refuses it.
    /// In the legacy era it is a body argument alone.
    func testAHeaderParameterReachesTheCallInTheBodyAndMirroredAsAHeader() async throws {
        let param = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        _ = await (try tool(headerParams: [param], era: .modern)).handle(args: ["account": "X1", "node": "1:2"])
        let modern = try XCTUnwrap(invoker.received.last)
        XCTAssertEqual(modern.headerParameters, ["Mcp-Param-Account": "X1"])
        XCTAssertEqual(modern.arguments, .object(["account": .string("X1"), "node": .string("1:2")]))
        XCTAssertEqual(modern.era, .modern)

        _ = await (try tool(headerParams: [param], era: .legacy)).handle(args: ["account": "X1", "node": "1:2"])
        let legacy = try XCTUnwrap(invoker.received.last)
        XCTAssertEqual(legacy.headerParameters, [:])
        XCTAssertEqual(legacy.arguments, .object(["account": .string("X1"), "node": .string("1:2")]))
        XCTAssertEqual(legacy.era, .legacy)

        _ = await (try tool(era: .legacy)).handle(args: ["node": "1:2"])
        XCTAssertNil(try XCTUnwrap(invoker.received.last).era, "a tool with no header parameter depends on no era")
    }

    /// The coercion's own report has to survive into the result the model reads.
    func testAnAdoptedConversionIsReportedInTheResult() async throws {
        let tool = try tool(properties: ["limit": JSONSchema.integer()])
        let result = await tool.handle(args: ["limit": "10"])
        let meta = try XCTUnwrap(try envelope(result)["meta"] as? [String: Any])
        XCTAssertEqual(meta["warnings"] as? [String], ["`limit` was read as a number."])
    }

    // MARK: - What the card shows is what the server receives (2026-10-28)

    /// The server's side of one HTTP exchange, as the stub session saw it: the `tools/call`
    /// request the REAL transport built — `nil` when none was sent.
    private struct Received {
        /// `params.arguments` of the request's body.
        let arguments: JSONValue?
        /// Every `Mcp-Param-*` header of the request, its value decoded from the spec's Base64
        /// sentinel (`=?base64?…?=`) where the transport used it.
        let headerParameters: [String: String]
        /// The same headers exactly as they went out.
        let rawHeaderParameters: [String: String]
    }

    /// Decodes the 2026-07-28 sentinel form of a header value; a plain value is itself.
    private static func decodedHeaderValue(_ value: String) -> String {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?="), value.count >= 11 else { return value }
        let payload = String(value.dropFirst("=?base64?".count).dropLast(2))
        guard let data = Data(base64Encoded: payload), let text = String(data: data, encoding: .utf8) else {
            return value
        }
        return text
    }

    /// A client over the REAL Streamable HTTP transport, over a stub session that answers as a
    /// server of `era` would: `server/discover` for the modern era; for the legacy one a
    /// `-32601` to it, then `initialize` with a session, and no push channel. Conforming: a
    /// modern request is checked as a 2026-07-28 server checks it before it is answered
    /// (`ScriptedMCPHTTPSession.conforming`).
    private func connectedOverHTTP(
        era: MCPProtocolEra, _ session: ScriptedMCPHTTPSession
    ) async throws -> (client: MCPClient, era: MCPProtocolEra) {
        session.conforming = true
        switch era {
        case .modern:
            session.repliesByRPCMethod[MCPWire.discoverMethod] = .json(#"{"jsonrpc":"2.0","id":{{id}},"result":{}}"#)
        case .legacy:
            session.repliesByRPCMethod[MCPWire.discoverMethod] = .json(
                #"{"jsonrpc":"2.0","id":{{id}},"error":{"code":-32601,"message":"no"}}"#)
            session.repliesByRPCMethod[MCPWire.initializeMethod] = .json(
                #"{"jsonrpc":"2.0","id":{{id}},"result":{"protocolVersion":"2025-11-25"}}"#,
                headers: ["Mcp-Session-Id": "sess-1"])
            session.repliesByRPCMethod[MCPWire.initializedNotification] = .accepted
            session.getReplies = [.status(405)]
        }
        session.repliesByRPCMethod[MCPWire.toolsCallMethod] = .json(
            #"{"jsonrpc":"2.0","id":{{id}},"result":{"content":[]}}"#)
        let transport = StreamableHTTPTransport(
            config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
            authorizer: NoAuthorizer(), session: session)
        let client = MCPClient(
            transport: transport, log: nil,
            timeouts: MCPTimeouts(connect: 2, requestInactivity: 3, requestAbsolute: 5), clientVersion: "1.0")
        let connection = try await client.connect(cachedEra: nil)
        XCTAssertEqual(connection.era, era, "premise: the era under test")
        return (client, connection.era)
    }

    /// One arguments document, as the model wrote it, through everything between it and the
    /// server: the runtime that reads it, this tool that assembles the call, the registry that
    /// routes it, the client that frames `tools/call`, and the real HTTP transport that writes
    /// the request — read back off the request the stub session received. `preflight` is what
    /// the approval gate computes for the same document before any of that runs, against the
    /// entry the step registered, whose era is the session's.
    private func wire(
        _ document: String, era: MCPProtocolEra,
        properties: [String: JSONSchemaProperty] = [:], headerParams: [MCPHeaderParam] = []
    ) async throws -> (received: Received, result: ToolExecutionResult, preflight: MCPDynamicTool.Preflight) {
        let session = ScriptedMCPHTTPSession()
        let (client, negotiated) = try await connectedOverHTTP(era: era, session)
        defer { Task { await client.close(budget: 0) } }
        let registry = MCPClientRegistry()
        registry.publish(client, approvedHashes: ["get_screenshot": "hash"], era: negotiated, for: Self.serverID)
        let tool = try tool(properties: properties, headerParams: headerParams, era: negotiated, through: registry)
        if !headerParams.isEmpty {
            session.toolHeaderParameters[tool.entry.descriptor.originalName] = headerParams.map {
                ConformingMCPServerCheck.HeaderParameter(path: $0.argumentPath, header: $0.headerName)
            }
        }
        let preflight = MCPDynamicTool.preflight(argumentsJSON: document, toolName: tool.name, entry: tool.entry)
        let toolRegistry = ToolRegistry()
        toolRegistry.register(name: tool.name, schema: tool.schema) { _, args in
            await tool.handle(args: args)
        }
        let results = await ToolRuntime(registry: toolRegistry, logger: nil).executeAll(
            context: context, toolCalls: [StepToolCall(name: tool.name, argumentsJSON: document)])
        let calls = session.requests(rpcMethod: MCPWire.toolsCallMethod)
        XCTAssertLessThanOrEqual(calls.count, 1)
        var arguments: JSONValue?
        var raw: [String: String] = [:]
        if let request = calls.first {
            let body = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
            let params = try XCTUnwrap(body["params"] as? [String: Any])
            arguments = params["arguments"].flatMap { JSONValue.fromFoundation($0) }
            for (name, value) in request.allHTTPHeaderFields ?? [:]
                where name.lowercased().hasPrefix(MCPHeaderParam.prefix.lowercased()) {
                raw[name] = value
            }
        }
        return (Received(arguments: arguments, headerParameters: raw.mapValues(Self.decodedHeaderValue),
                         rawHeaderParameters: raw),
                try XCTUnwrap(results.first), preflight)
    }

    /// The model-facing name of the tool `wire(_:era:)` calls.
    private static let cardToolName = "mcp__folio__get_screenshot"

    /// The approval card the gate would publish for a call the preflight let through.
    private func card(_ outgoing: MCPDynamicTool.OutgoingCall) -> MCPApprovalRequest {
        MCPApprovalRequest(
            taskID: 1, stepID: "s", callKey: "k", toolName: Self.cardToolName, serverSlug: "folio",
            serverDisplayName: "Folio Desktop", toolTitle: "get_screenshot", toolDescription: "d",
            outgoing: outgoing, annotations: .specDefaults, serverTrusted: false, pinHash: "hash",
            offerAlways: false, createdAt: Date(timeIntervalSince1970: 0))
    }

    /// The card shows exactly what the server receives, in both eras — read off the HTTP request
    /// the REAL transport wrote, never off what the transport was handed: the preflight the gate
    /// builds the card from equals the request body's `params.arguments` and its `Mcp-Param-*`
    /// headers — for an envelope (shown as the arguments inside it), a key the runtime drops or
    /// trims, an argument the coercion converts, and a call with a header parameter alone, with a
    /// body argument alone, and with both. "No arguments" exactly when the server receives none:
    /// an absent document, a `null` one and an empty object all send `"arguments": {}`.
    ///
    /// A header parameter is MIRRORED in the modern era — the body keeps it and its header
    /// carries it too — and the legacy era, which has no header channel, sends it in the body
    /// alone.
    ///
    /// RED until 2026-10-28 for `null`: it reached the server as `{"__raw_input__":"null"}`.
    /// RED until 2026-10-28 for the envelope, the dropped and trimmed keys and the
    /// conversion, and for the header parameter: it compared against the
    /// hints a scripted transport was handed, and a legacy server received the value nowhere
    /// while the card showed it as a header; a modern one received it without its body value.
    func testTheCardShowsExactlyWhatTheServerReceives() async throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let properties: [String: JSONSchemaProperty] = ["limit": JSONSchema.integer(), "account": JSONSchema.string()]
        let nothing: [String] = ["", "  \n", "null", " null ", "{}", "{ }", #"{"":""}"#,
                                 #"{"name":"mcp__folio__get_screenshot","arguments":{}}"#]
        for era in [MCPProtocolEra.modern, .legacy] {
            let mirrored: (String) -> [String: String] = { era == .modern ? ["Mcp-Param-Account": $0] : [:] }
            let something: [(String, JSONValue, [String: String])] = [
                (#"{"node":"1:2"}"#, .object(["node": .string("1:2")]), [:]),
                (#"{"node":null}"#, .object(["node": .null]), [:]),
                (#"{"name":"mcp__folio__get_screenshot","arguments":{"node":"9"}}"#, .object(["node": .string("9")]), [:]),
                (#"{"":"x","node":"9"}"#, .object(["node": .string("9")]), [:]),
                (#"{" node ":"9"}"#, .object(["node": .string("9")]), [:]),
                (#"{"limit":"10"}"#, .object(["limit": .int(10)]), [:]),
                // A header parameter alone, beside a body argument, and beside a conversion.
                (#"{"account":"X1"}"#, .object(["account": .string("X1")]), mirrored("X1")),
                (#"{"account":"X1","node":"1"}"#, .object(["account": .string("X1"), "node": .string("1")]),
                 mirrored("X1")),
                (#"{"account":"X1","limit":"10"}"#, .object(["account": .string("X1"), "limit": .int(10)]),
                 mirrored("X1")),
            ]
            for document in nothing {
                let wired = try await wire(document, era: era, properties: properties, headerParams: [account])
                XCTAssertFalse(wired.result.isError, "\(era) \(document): \(wired.result.outputJSON)")
                XCTAssertEqual(wired.received.arguments, .object([:]), "\(era) \(document): the server receives no argument")
                XCTAssertEqual(wired.received.headerParameters, [:], "\(era) \(document)")
                guard case .sends(let outgoing) = wired.preflight else {
                    XCTFail("\(era) \(document): the gate's reading — a call that is sent"); continue
                }
                XCTAssertEqual(outgoing.arguments, wired.received.arguments, "\(era) \(document)")
                XCTAssertTrue(card(outgoing).hasNoArguments, "\(era) \(document)")
            }
            for (document, body, headers) in something {
                let wired = try await wire(document, era: era, properties: properties, headerParams: [account])
                XCTAssertFalse(wired.result.isError, "\(era) \(document): \(wired.result.outputJSON)")
                XCTAssertEqual(wired.received.arguments, body, "\(era) \(document): the request's body")
                XCTAssertEqual(wired.received.headerParameters, headers, "\(era) \(document): the request's headers")
                guard case .sends(let outgoing) = wired.preflight else {
                    XCTFail("\(era) \(document): the gate's reading — a call that is sent"); continue
                }
                XCTAssertEqual(outgoing.arguments, wired.received.arguments, "\(era) \(document): the card's body is the request's")
                XCTAssertEqual(outgoing.headerParameters, wired.received.headerParameters,
                               "\(era) \(document): and its headers are the request's")
                XCTAssertFalse(card(outgoing).hasNoArguments, "\(era) \(document)")
                XCTAssertEqual(
                    card(outgoing).argumentsDisplay.display,
                    MCPApprovalRequest.argumentsText(of: MCPDynamicTool.OutgoingCall(arguments: body, headerParameters: headers)),
                    "\(era) \(document): what the box shows")
                XCTAssertEqual(
                    card(outgoing).argumentsDisplay.display.contains(MCPApprovalRequest.headerParametersHeading),
                    !headers.isEmpty, "\(era) \(document): a headers section exactly when a header is sent")
            }
        }
    }

    /// A header value that is not a plain ASCII header value goes as the spec's Base64 sentinel —
    /// the body keeps the text itself — and one that is plain goes as itself. The card shows
    /// the value, which is what the server decodes and compares with the body.
    ///
    /// RED until 2026-10-28: the value was written into the header raw.
    func testAHeaderValueThatIsNotPlainASCIIGoesAsTheSpecsBase64Sentinel() async throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let properties: [String: JSONSchemaProperty] = ["account": JSONSchema.string()]
        for value in ["Zürich", " padded ", "=?base64?literal?="] {
            let document = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: ["account": value]), encoding: .utf8))
            let wired = try await wire(document, era: .modern, properties: properties, headerParams: [account])
            XCTAssertEqual(wired.received.arguments, .object(["account": .string(value)]), value)
            let raw = try XCTUnwrap(wired.received.rawHeaderParameters["Mcp-Param-Account"], value)
            XCTAssertEqual(raw, "=?base64?" + Data(value.utf8).base64EncodedString() + "?=", value)
            XCTAssertEqual(wired.received.headerParameters, ["Mcp-Param-Account": value], value)
            guard case .sends(let outgoing) = wired.preflight else { XCTFail(value); continue }
            XCTAssertEqual(outgoing.headerParameters, ["Mcp-Param-Account": value], "\(value): the card shows the value")
        }
        let plain = try await wire(#"{"account":"X-1 b"}"#, era: .modern, properties: properties, headerParams: [account])
        XCTAssertEqual(plain.received.rawHeaderParameters["Mcp-Param-Account"], "X-1 b", "a plain value goes as itself")
    }

    /// An empty string the model wrote for a header parameter is a value provided: from the
    /// document, through the coercion that decides the header and the real transport that writes
    /// it, the server receives the empty header beside the body's empty string — "Parameter value
    /// provided | Client MUST include the header" — and the card shows exactly that. The socket's
    /// half — that URLSession sends an empty header line at all — is
    /// `MCPClientOverHTTPTests.testAnEmptyHeaderParameterValueReachesTheSocketAsAnEmptyHeader`.
    func testAnEmptyHeaderParameterIsSentAsAnEmptyHeaderFromTheModelsDocument() async throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let wired = try await wire(
            #"{"account":""}"#, era: .modern, properties: ["account": JSONSchema.string()], headerParams: [account])
        XCTAssertEqual(wired.received.arguments, .object(["account": .string("")]))
        XCTAssertEqual(wired.received.rawHeaderParameters, ["Mcp-Param-Account": ""])
        guard case .sends(let outgoing) = wired.preflight else { return XCTFail("the preflight refused it") }
        XCTAssertEqual(outgoing.headerParameters, ["Mcp-Param-Account": ""], "the card shows the empty header")
    }

    /// A call the send path refuses never reaches the server as something the card did not show,
    /// and the preflight — what the gate reads before it holds a card — refuses it too, so no
    /// card is held for it: a document that is not a JSON object (the runtime hands such text to
    /// a built-in handler under its own recovery key; an external server never declared it), an
    /// argument the runtime's type gate refuses, and a header parameter no header can carry.
    ///
    /// RED until 2026-10-28: the server received `{"__raw_input__":"hello"}`, and for the
    /// type gate and the header the gate held a card for both.
    func testACallTheSendPathRefusesIsNeverSentAndGetsNoCard() async throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let properties: [String: JSONSchemaProperty] = ["limit": JSONSchema.integer(), "account": JSONSchema.string()]
        let notAnObject = ToolRuntimeError.argumentsNotObject.errorDescription ?? "∅"
        let everyEra: [(String, String)] = [
            ("hello", notAnObject), ("Null", notAnObject), ("{not json}", notAnObject), ("[]", notAnObject),
            ("5", notAnObject),
            (#"{"limit":"ten"}"#, "`limit` must be an integer; received a string."),
        ]
        // What only a HEADER cannot carry: refused in the modern era, which mirrors the value
        // into its header, and sent in the body by the legacy one, which has no header. A value
        // the spec Base64-encodes is not among them: it is sent
        // (`testEveryValueTheSpecEncodesGoesAsItsSentinelAndDecodesToTheBody`).
        let headerOnly: [(String, String)] = [
            (#"{"account":{"id":1}}"#, MCPArgumentCoercion.Failure.headerValueNotAScalar(argument: "account").message),
        ]
        for era in [MCPProtocolEra.modern, .legacy] {
            for (document, refusal) in everyEra + (era == .modern ? headerOnly : []) {
                let wired = try await wire(document, era: era, properties: properties, headerParams: [account])
                XCTAssertNil(wired.received.arguments, "\(era) \(document): nothing reaches the server")
                XCTAssertTrue(wired.result.isError, "\(era) \(document)")
                XCTAssertTrue(wired.result.outputJSON.contains(refusal), "\(era) \(document): \(wired.result.outputJSON)")
                XCTAssertEqual(wired.preflight, .refused, "\(era) \(document): nothing would be sent, so no card")
            }
        }
        for (document, _) in headerOnly {
            let wired = try await wire(document, era: .legacy, properties: properties, headerParams: [account])
            XCTAssertFalse(wired.result.isError, "legacy \(document): \(wired.result.outputJSON)")
            XCTAssertNotNil(wired.received.arguments?.objectValue?["account"], "legacy \(document): sent in the body")
            XCTAssertEqual(wired.received.headerParameters, [:], "legacy \(document)")
            guard case .sends(let outgoing) = wired.preflight else { XCTFail("legacy \(document)"); continue }
            XCTAssertEqual(outgoing.arguments, wired.received.arguments, "legacy \(document): the card shows it")
        }
    }

    /// The preflight checks a call against the schema the runtime registered the tool under —
    /// the frozen entry's projection (`registeredSchema(of:)`), the same value `schema` hands the
    /// registry — and a call that schema lets through is sent, so it is put to a person.
    func testThePreflightReadsTheSchemaTheToolIsRegisteredUnder() throws {
        let tool = try tool(properties: ["limit": JSONSchema.integer()])
        XCTAssertEqual(MCPDynamicTool.registeredSchema(of: tool.entry), tool.schema)
        XCTAssertEqual(
            MCPDynamicTool.preflight(argumentsJSON: #"{"limit":"ten"}"#, toolName: tool.name, entry: tool.entry),
            .refused)
        XCTAssertEqual(
            MCPDynamicTool.preflight(argumentsJSON: #"{"limit":"10"}"#, toolName: tool.name, entry: tool.entry),
            .sends(MCPDynamicTool.OutgoingCall(arguments: .object(["limit": .int(10)]), headerParameters: [:])))
    }

    // MARK: - The text the call was made against (F21)

    /// The invoker is told which text the model called: the step's frozen descriptor, so the
    /// last component before the wire can refuse a call whose tool has since been rewritten.
    func testTheCallCarriesTheTextItWasMadeAgainst() async throws {
        _ = await (try tool()).handle(args: [:])
        XCTAssertEqual(invoker.received.first?.expectedHash, "hash")
    }

    /// A call stopped at dispatch reads exactly like one the iteration withheld — same code,
    /// same text, same `tool` field — because it is the same fact caught later.
    func testARefusalAtDispatchIsTheRefusalTheIterationGivesTheSameFact() async throws {
        let cases: [(MCPDispatchRefusal, LLMExecutionService.ToolUnavailabilityReason)] = [
            (.toolChanged, .mcpToolChanged),
            (.serverNotConnected, .mcpServerNotConnected),
        ]
        for (refusal, reason) in cases {
            invoker.answer = .failure(refusal)
            let result = await (try tool()).handle(args: ["node": "1:2"])
            let expected = LLMExecutionService.makeUnavailableToolResult(
                call: StepToolCall(name: "mcp__folio__get_screenshot", argumentsJSON: "{}"),
                canonicalName: "mcp__folio__get_screenshot", scope: "for this role", reason: reason)
            XCTAssertTrue(result.isError, "\(refusal)")
            XCTAssertEqual(result.outputJSON, expected.outputJSON, "\(refusal)")
            XCTAssertEqual(result.toolName, "mcp__folio__get_screenshot")
            XCTAssertEqual(result.argumentsJSON, encodeArgsToJSON(["node": "1:2"]))
        }
    }

    /// A refusal is not a server failure: nothing was sent, and `MCP_SERVER_UNAVAILABLE`'s
    /// "Do not retry" would be false for a server between sessions.
    func testARefusalAtDispatchIsNotReportedAsTheServerBeingUnavailable() async throws {
        invoker.answer = .failure(MCPDispatchRefusal.serverNotConnected)
        let result = await (try tool()).handle(args: [:])
        XCTAssertFalse(result.outputJSON.contains(ToolErrorCode.mcpServerUnavailable.rawValue), result.outputJSON)
    }

    // MARK: - Failures leave as envelopes

    /// The contract this shares with a real `ToolHandler`: nothing throws out of `handle`.
    func testATransportFailureBecomesAnUnavailableEnvelope() async throws {
        invoker.answer = .failure(MCPClientError.transport(.timedOut))
        let result = await (try tool()).handle(args: [:])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(try errorCode(result), ToolErrorCode.mcpServerUnavailable.rawValue)
    }

    func testAServerRefusalOfTheArgumentsBecomesInvalidArgs() async throws {
        invoker.answer = .failure(MCPClientError.rpc(
            code: MCPErrorCode.invalidParams, message: "node is required", data: nil))
        let result = await (try tool()).handle(args: [:])
        XCTAssertEqual(try errorCode(result), ToolErrorCode.invalidArgs.rawValue)
    }

    func testAnyOtherServerRefusalIsAToolError() async throws {
        invoker.answer = .failure(MCPClientError.rpc(code: -32000, message: "rate limited", data: nil))
        let result = await (try tool()).handle(args: [:])
        XCTAssertEqual(try errorCode(result), ToolErrorCode.mcpToolError.rawValue)
    }

    func testATimeoutKeepsItsOwnCodeSoTheNoteCanOfferARetry() async throws {
        invoker.answer = .failure(MCPClientError.timedOut(method: "tools/call"))
        let result = await (try tool()).handle(args: [:])
        XCTAssertEqual(try errorCode(result), ToolErrorCode.mcpTimedOut.rawValue)
        XCTAssertTrue(ToolErrorCode.mcpTimedOut.rawValue.hasSuffix("_TIMED_OUT"))
    }

    /// An abandoned call is the same cancellation a paused `bash` produces, so downstream
    /// classifiers see one shape.
    func testACancelledCallUsesTheUnifiedCancellationEnvelope() async throws {
        invoker.answer = .failure(MCPClientError.cancelled)
        let result = await (try tool()).handle(args: [:])
        XCTAssertTrue(result.isCancellationEnvelope)
    }

    /// A header value the model wrote with a line break reaches the invoker whole — the value the
    /// server decodes — for the transport to carry in the spec's Base64 sentinel, where no line
    /// can be injected. Nothing is refused that the spec says to send.
    ///
    /// RED until 2026-10-28: the call was refused before the wire.
    func testAHeaderValueWithALineBreakReachesTheInvokerWhole() async throws {
        let param = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let tool = try tool(headerParams: [param])
        let value = "X\r\nAuthorization: Bearer x"
        let result = await tool.handle(args: ["account": value])
        XCTAssertFalse(result.isError, result.outputJSON)
        let call = try XCTUnwrap(invoker.received.first)
        XCTAssertEqual(call.headerParameters, ["Mcp-Param-Account": value])
        XCTAssertEqual(call.arguments, .object(["account": .string(value)]))
    }

    // MARK: - The spec's rules at the HTTP seam (2026-10-28)

    /// Every value the spec's Value Encoding sends through the sentinel — CR/LF, a line or
    /// paragraph separator, NEL, a ZWNJ in a Persian name, a control character — leaves the REAL
    /// transport as `=?base64?…?=`, and decodes to exactly the body's value; the card built from
    /// the same call shows that value. Nothing is refused.
    ///
    /// RED until 2026-10-28: each was refused before the wire.
    func testEveryValueTheSpecEncodesGoesAsItsSentinelAndDecodesToTheBody() async throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let properties: [String: JSONSchemaProperty] = ["account": JSONSchema.string()]
        for value in ["a\r\nX-Evil: 1", "alex\u{2028}Mcp-Param-Locale: en", "p\u{2029}q", "x\u{0085}y",
                      "نام\u{200C}خانوادگی", "bell\u{7}"] {
            let document = try XCTUnwrap(String(
                data: try JSONSerialization.data(withJSONObject: ["account": value]), encoding: .utf8))
            let wired = try await wire(document, era: .modern, properties: properties, headerParams: [account])
            XCTAssertFalse(wired.result.isError, "\(value.debugDescription): \(wired.result.outputJSON)")
            XCTAssertEqual(wired.received.arguments, .object(["account": .string(value)]), value.debugDescription)
            XCTAssertEqual(wired.received.rawHeaderParameters["Mcp-Param-Account"],
                           "=?base64?" + Data(value.utf8).base64EncodedString() + "?=", value.debugDescription)
            XCTAssertEqual(wired.received.headerParameters, ["Mcp-Param-Account": value], "decoded == body")
            guard case .sends(let outgoing) = wired.preflight else { XCTFail(value.debugDescription); continue }
            XCTAssertEqual(outgoing.headerParameters, wired.received.headerParameters, "the card's header is the request's")
        }
    }

    /// A NESTED header parameter is mirrored at its path by the real transport, beside the body
    /// that carries it, in the modern era; the legacy era sends the body alone. The card's call is
    /// the request's.
    ///
    /// RED until 2026-10-28: no nested header was ever sent.
    func testANestedHeaderParameterLeavesTheTransportFromItsPath() async throws {
        let region = try MCPHeaderParam.make(argumentPath: ["target", "region"], rawName: "Region")
        let properties: [String: JSONSchemaProperty] = ["target": JSONSchema.object("t")]
        let document = #"{"target":{"region":"eu-west","zone":"a"}}"#
        let body = JSONValue.object(["target": .object(["region": .string("eu-west"), "zone": .string("a")])])
        for (era, headers) in [(MCPProtocolEra.modern, ["Mcp-Param-Region": "eu-west"]), (.legacy, [:])] {
            let wired = try await wire(document, era: era, properties: properties, headerParams: [region])
            XCTAssertFalse(wired.result.isError, "\(era): \(wired.result.outputJSON)")
            XCTAssertEqual(wired.received.arguments, body, "\(era)")
            XCTAssertEqual(wired.received.headerParameters, headers, "\(era)")
            guard case .sends(let outgoing) = wired.preflight else { XCTFail("\(era)"); continue }
            XCTAssertEqual(outgoing, MCPDynamicTool.OutgoingCall(arguments: body, headerParameters: headers), "\(era)")
        }
    }

    /// An integer header value outside the spec's safe range never reaches the server, and no card
    /// is held for it; the refusal names the property. The legacy era sends it in the body.
    func testAnIntegerHeaderOutsideTheSafeRangeIsNeverSent() async throws {
        let n = try MCPHeaderParam.make(argumentPath: ["n"], rawName: "N")
        let properties: [String: JSONSchemaProperty] = ["n": JSONSchema.integer()]
        let refusal = MCPArgumentCoercion.Failure.headerValueOutsideSafeIntegerRange(argument: "n").message
        let modern = try await wire(#"{"n":9007199254740992}"#, era: .modern, properties: properties, headerParams: [n])
        XCTAssertNil(modern.received.arguments, "nothing reaches the server")
        XCTAssertTrue(modern.result.outputJSON.contains(refusal), modern.result.outputJSON)
        XCTAssertEqual(modern.preflight, .refused)
        let bound = try await wire(#"{"n":9007199254740991}"#, era: .modern, properties: properties, headerParams: [n])
        XCTAssertEqual(bound.received.headerParameters, ["Mcp-Param-N": "9007199254740991"], "the bound itself goes")
        let legacy = try await wire(#"{"n":9007199254740992}"#, era: .legacy, properties: properties, headerParams: [n])
        XCTAssertEqual(legacy.received.arguments, .object(["n": .int(9_007_199_254_740_992)]))
    }

    // MARK: - Attachments

    func testABinaryResultIsWrittenUnderTheServersOwnSlug() async throws {
        let attachments = root.appendingPathComponent(
            ".nanoteams/tasks/1/attachments/mcp/folio", isDirectory: true)
        invoker.answer = .success(MCPCallToolResult(contentBlocks: [
            .object([
                "type": .string("image"), "mimeType": .string("image/png"),
                "data": .string(Data([0x89, 0x50]).base64EncodedString()),
            ]),
        ]))
        let result = await (try tool(attachments: attachments))
            .handle(args: ["node": "1:2"])
        let data = try XCTUnwrap(try envelope(result)["data"] as? [String: Any])
        let files = try XCTUnwrap(data["files"] as? [[String: Any]])
        XCTAssertEqual(
            files[0]["path"] as? String,
            ".nanoteams/tasks/1/attachments/mcp/folio/call-1-0.png")
    }

    // MARK: - The server's own secret, echoed into a result

    /// End to end: a real client (its transport scripted) behind the registry, called by the
    /// tool the runtime runs. The token this app sent the server comes back in a text block and
    /// in `structuredContent`, on success and on the server's own failure, and reaches the
    /// envelope the model reads as the placeholder — in no field at all as itself.
    func testAnEchoedTokenNeverReachesTheEnvelope() async throws {
        let token = "tok_live_9f8e7d6c5b4a"
        for isError in [false, true] {
            let transport = ScriptedTransport()
            transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
            let client = MCPClient(
                transport: transport, log: nil,
                timeouts: MCPTimeouts(connect: 1, requestInactivity: 3, requestAbsolute: 5),
                clientVersion: "1.0",
                credentials: { MCPRedaction.Credentials(values: [token]) })
            _ = try await client.connect(cachedEra: nil)
            transport.script(MCPWire.toolsCallMethod, [.result(.object([
                "isError": .bool(isError),
                "content": .array([.object(["type": .string("text"), "text": .string("you are \(token)")])]),
                "structuredContent": .object(["token": .string(token)]),
            ]))])
            let registry = MCPClientRegistry()
            registry.publish(client, approvedHashes: ["get_screenshot": "hash"], era: .modern, for: Self.serverID)

            let result = await (try tool(through: registry)).handle(args: ["node": "1:2"])
            XCTAssertEqual(result.isError, isError)
            XCTAssertFalse(result.outputJSON.contains(token), result.outputJSON)
            XCTAssertTrue(result.outputJSON.contains(MCPRedaction.placeholder), result.outputJSON)
            await client.close(budget: 0)
        }
    }

    /// End to end, a secret split by a bidi override: the result mapper's data cleaning drops
    /// the override on the way to the model, so the scrub has to look after that cleaning —
    /// or the model reads the secret whole.
    func testASecretSplitByABidiOverrideNeverReachesTheEnvelope() async throws {
        let secret = "wk_live_8f3a9c2d"
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        let client = MCPClient(
            transport: transport, log: nil,
            timeouts: MCPTimeouts(connect: 1, requestInactivity: 3, requestAbsolute: 5),
            clientVersion: "1.0",
            credentials: { MCPRedaction.Credentials(values: [secret]) })
        _ = try await client.connect(cachedEra: nil)
        transport.script(MCPWire.toolsCallMethod, [.result(.object([
            "content": .array([.object(["type": .string("text"),
                                        "text": .string("you are wk_live\u{202E}_8f3a9c2d")])]),
            "structuredContent": .object(["key": .string("wk_live\u{2066}_8f3a9c2d")]),
        ]))])
        let registry = MCPClientRegistry()
        registry.publish(client, approvedHashes: ["get_screenshot": "hash"], era: .modern, for: Self.serverID)

        let result = await (try tool(through: registry)).handle(args: ["node": "1:2"])
        XCTAssertFalse(result.outputJSON.contains(secret), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains(MCPRedaction.placeholder), result.outputJSON)
        await client.close(budget: 0)
    }

    // MARK: - The classifier, arm by arm

    /// Every `MCPClientError` under the code its own recovery needs. Driven directly rather
    /// than through a call, because three of the arms are reachable only from the client's
    /// own lifecycle — and an arm that inherits the wrong code is exactly what this switch
    /// exists to prevent: `COMMAND_FAILED` for all of them was one code for three different
    /// recoveries.
    func testEveryClientErrorGetsTheCodeItsRecoveryNeeds() {
        let cases: [(MCPClientError, ToolErrorCode)] = [
            (.rpc(code: MCPErrorCode.invalidParams, message: "node is required", data: nil), .invalidArgs),
            (.rpc(code: -32000, message: "rate limited", data: nil), .mcpToolError),
            (.timedOut(method: "tools/call"), .mcpTimedOut),
            (.notConnected, .mcpServerUnavailable),
            (.transport(.timedOut), .mcpServerUnavailable),
            (.unsupportedProtocolVersion(offered: "2026-07-28", serverSupports: ["2024-11-05"]),
             .mcpServerUnavailable),
            // Raised only by the probe, never by a call — kept exhaustive all the same.
            (.handshakeRefused(code: -32021, message: "requires sampling"), .mcpServerUnavailable),
            // A result that is not a finished answer: input this client cannot give is the tool
            // refusing this call; a type it does not know is an answer it cannot read.
            (.inputRequired, .mcpToolError),
            (.unknownResultType("streaming"), .mcpServerUnavailable),
            // Reachable and answering, with something this client cannot read: the repair is
            // the server, so it shares the unavailable recovery rather than the tool one.
            (.malformedResult("the server repeated its page cursor"), .mcpServerUnavailable),
            (.pageLimitExceeded(100), .mcpServerUnavailable),
            // Never reached through `execute` — the cancellation envelope claims it one arm
            // earlier — but kept exhaustive so a new case cannot silently inherit a wrong code.
            (.cancelled, .cancelled),
        ]
        for (error, expected) in cases {
            let (code, message) = ToolErrorHandler.classify(mcpClientError: error)
            XCTAssertEqual(code, expected, "\(error)")
            XCTAssertEqual(message, error.message, "\(error)")
            XCTAssertFalse(message.isEmpty, "\(error)")
        }
    }

    /// An argument that violates the schema's `enum` or numeric `minimum`/`maximum` is refused as
    /// `INVALID_ARGS` both by `preflight` (before any approval card) and by `handle` (without
    /// touching the transport).
    func testAnEnumOrRangeViolationIsRefusedByPreflightAndNeverSent() async throws {
        let slug = try XCTUnwrap(MCPServerSlug("folio"))
        let outcome = try MCPToolDescriptorFactory.build(
            rawTools: [.object([
                "name": .string("get_screenshot"),
                "description": .string("Takes a screenshot."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "required": .array([.string("node")]),
                    "properties": .object([
                        "node": .object(["type": .string("string")]),
                        "format": .object([
                            "type": .string("string"),
                            "enum": .array([.string("png"), .string("jpg")]),
                        ]),
                        "scale": .object([
                            "type": .string("integer"),
                            "minimum": .int(1),
                            "maximum": .int(4),
                        ]),
                    ]),
                ]),
            ])],
            slug: slug, era: .modern)
        let descriptor = try XCTUnwrap(outcome.descriptors.first)
        let entry = MCPToolsSnapshot.Entry(
            serverID: Self.serverID, slug: slug, serverDisplayName: "Folio Desktop",
            approvalMode: .manual, serverTrusted: false, alwaysAllowed: false,
            runsUnattended: false, descriptor: descriptor, era: .modern)
        let dynamicTool = MCPDynamicTool(
            entry: entry, invoker: invoker, attachmentsDirectory: nil,
            workFolderRoot: root, makeCallID: { "call-1" })

        for (badJSON, badArgs, substring) in [
            (#"{"node":"1:2","format":"bmp"}"#, ["node": "1:2", "format": "bmp"] as [String: Any], "Allowed values: png, jpg"),
            (#"{"node":"1:2","scale":0}"#, ["node": "1:2", "scale": 0] as [String: Any], "between 1 and 4"),
        ] {
            XCTAssertEqual(
                MCPDynamicTool.preflight(argumentsJSON: badJSON, toolName: entry.modelFacingName, entry: entry),
                .refused,
                badJSON)

            let handleResult = await dynamicTool.handle(args: badArgs)
            XCTAssertTrue(handleResult.isError)
            XCTAssertEqual(try errorCode(handleResult), ToolErrorCode.invalidArgs.rawValue)
            XCTAssertTrue(handleResult.outputJSON.contains(substring), handleResult.outputJSON)
        }
        XCTAssertTrue(invoker.received.isEmpty, "invalid arguments must never reach the wire")
    }

    // MARK: - Synthesized resource & resource-template tools (D-M3)

    func testSynthesizedResourceAndTemplateToolsInvokeResourcesReadAndSaveBinaryBlobsAsAttachments() async throws {
        let slug = try XCTUnwrap(MCPServerSlug("folio"))
        let outcome = try MCPToolDescriptorFactory.build(
            rawTools: [],
            rawResources: [
                .object([
                    "uri": .string("file:///logo.png"),
                    "name": .string("logo"),
                    "description": .string("Company logo."),
                    "mimeType": .string("image/png"),
                ]),
            ],
            rawResourceTemplates: [
                .object([
                    "uriTemplate": .string("repo://notes/{topic}"),
                    "name": .string("topic_note"),
                    "description": .string("Topic note."),
                    "mimeType": .string("text/plain"),
                ]),
            ],
            slug: slug,
            era: .modern)

        let staticDesc = try XCTUnwrap(outcome.descriptors.first { $0.originalName == "resource:file:///logo.png" })
        let templateDesc = try XCTUnwrap(outcome.descriptors.first { $0.originalName == "resource_template:repo://notes/{topic}" })

        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        transport.script(MCPWire.resourcesReadMethod, [
            .result(.object([
                "contents": .array([
                    .object([
                        "uri": .string("file:///logo.png"),
                        "mimeType": .string("image/png"),
                        "blob": .string(pngBytes.base64EncodedString()),
                    ]),
                ]),
            ])),
            .result(.object([
                "contents": .array([
                    .object([
                        "uri": .string("repo://notes/security"),
                        "mimeType": .string("text/plain"),
                        "text": .string("Pin everything before use."),
                    ]),
                ]),
            ])),
        ])
        let client = MCPClient(
            transport: transport, log: nil,
            timeouts: MCPTimeouts(connect: 1, requestInactivity: 3, requestAbsolute: 5),
            clientVersion: "1.0")
        _ = try await client.connect(cachedEra: nil)
        let registry = MCPClientRegistry()
        registry.publish(
            client,
            approvedHashes: [
                staticDesc.originalName: staticDesc.pinHash,
                templateDesc.originalName: templateDesc.pinHash,
            ],
            era: .modern,
            for: Self.serverID)

        let attachments = root.appendingPathComponent(".nanoteams/tasks/1/attachments/mcp/folio", isDirectory: true)
        let staticTool = MCPDynamicTool(
            entry: MCPToolsSnapshot.Entry(
                serverID: Self.serverID, slug: slug, serverDisplayName: "Folio Desktop",
                approvalMode: .manual, serverTrusted: false, alwaysAllowed: false,
                runsUnattended: false, descriptor: staticDesc, era: .modern),
            invoker: registry, attachmentsDirectory: attachments, workFolderRoot: root, makeCallID: { "res-1" })

        let staticResult = await staticTool.handle(args: [:])
        XCTAssertFalse(staticResult.isError, staticResult.outputJSON)
        let staticData = try XCTUnwrap(try envelope(staticResult)["data"] as? [String: Any])
        let files = try XCTUnwrap(staticData["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["path"] as? String, ".nanoteams/tasks/1/attachments/mcp/folio/res-1-0.png")

        let templateTool = MCPDynamicTool(
            entry: MCPToolsSnapshot.Entry(
                serverID: Self.serverID, slug: slug, serverDisplayName: "Folio Desktop",
                approvalMode: .manual, serverTrusted: false, alwaysAllowed: false,
                runsUnattended: false, descriptor: templateDesc, era: .modern),
            invoker: registry, attachmentsDirectory: attachments, workFolderRoot: root, makeCallID: { "res-2" })

        let templateResult = await templateTool.handle(args: ["topic": "security"])
        XCTAssertFalse(templateResult.isError, templateResult.outputJSON)
        let templateData = try XCTUnwrap(try envelope(templateResult)["data"] as? [String: Any])
        let resources = try XCTUnwrap(templateData["resources"] as? [[String: Any]])
        XCTAssertEqual(resources.first?["uri"] as? String, "repo://notes/security")
        XCTAssertEqual(resources.first?["text"] as? String, "Pin everything before use.")
        await client.close(budget: 0)
    }

}
