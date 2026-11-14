import XCTest

@testable import NanoTeams

/// The only two things this client asks a server to do.
final class MCPClientToolsTests: XCTestCase {

    private let fastTimeouts = MCPTimeouts(connect: 1, requestInactivity: 3, requestAbsolute: 5)

    private func connected(_ transport: ScriptedTransport) async throws -> MCPClient {
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        let client = MCPClient(transport: transport, log: nil, timeouts: fastTimeouts, clientVersion: "1.0")
        _ = try await client.connect(cachedEra: nil)
        return client
    }

    private func tool(_ name: String) -> JSONValue {
        .object(["name": .string(name), "inputSchema": .object(["type": .string("object")])])
    }

    private func page(_ names: [String], next: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["tools": .array(names.map(tool))]
        if let next { object["nextCursor"] = .string(next) }
        return .object(object)
    }

    // MARK: - Listing

    func testASinglePageListing() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsListMethod, [.result(page(["a", "b"]))])
        let tools = try await client.listAllTools()
        XCTAssertEqual(tools.compactMap { $0.objectValue?["name"]?.stringValue }, ["a", "b"])
    }

    func testEveryPageIsFollowedInOrder() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsListMethod, [
            .result(page(["a"], next: "p2")),
            .result(page(["b"], next: "p3")),
            .result(page(["c"])),
        ])
        let tools = try await client.listAllTools()
        XCTAssertEqual(tools.compactMap { $0.objectValue?["name"]?.stringValue }, ["a", "b", "c"])

        let cursors = transport.sent.compactMap { frame -> String? in
            guard case .request(let request) = frame, request.method == MCPWire.toolsListMethod else { return nil }
            return request.params?.objectValue?["cursor"]?.stringValue ?? "(none)"
        }
        XCTAssertEqual(cursors, ["(none)", "p2", "p3"])
    }

    func testAnEmptyCursorEndsTheListingRatherThanAskingAgain() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsListMethod, [
            .result(.object(["tools": .array([tool("a")]), "nextCursor": .string("")])),
        ])
        let tools = try await client.listAllTools()
        XCTAssertEqual(tools.count, 1)
    }

    /// A cursor that repeats itself is a loop wearing a different hat, and the page cap alone
    /// would spend a hundred round trips discovering it.
    func testARepeatedCursorIsRefusedImmediately() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsListMethod, [
            .result(page(["a"], next: "same")),
            .result(page(["b"], next: "same")),
        ])
        do {
            _ = try await client.listAllTools()
            XCTFail("a repeated cursor is a loop")
        } catch MCPClientError.malformedResult(let detail) {
            XCTAssertTrue(detail.contains("cursor"), detail)
        }
        let requests = transport.sent.filter {
            if case .request(let request) = $0 { return request.method == MCPWire.toolsListMethod }
            return false
        }
        XCTAssertEqual(requests.count, 2, "the loop is caught on the second page, not on the hundredth")
    }

    /// A server that keeps handing back a fresh cursor would hold the connect path open
    /// forever — and the connect path is what a role's first step waits on.
    func testAnEndlessPagerIsStoppedAtTheCap() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsListMethod, [.frames([])])
        // A fresh cursor every time: scripted as a closure would be neater, but a long list of
        // distinct pages is what a real endless pager looks like.
        transport.script(MCPWire.toolsListMethod,
                         (0...MCPConstants.maxToolsListPages).map { .result(page(["t\($0)"], next: "c\($0)")) })
        do {
            _ = try await client.listAllTools()
            XCTFail("an endless pager must be stopped")
        } catch MCPClientError.pageLimitExceeded(let limit) {
            XCTAssertEqual(limit, MCPConstants.maxToolsListPages)
        }
    }

    func testAListingWithNoToolsIsAnAnswerNotAFailure() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsListMethod, [.result(.object([:]))])
        let tools = try await client.listAllTools()
        XCTAssertTrue(tools.isEmpty)
    }

    // MARK: - Calling

    /// The server's OWN name goes on the wire. The fold is lossy, so sending the model-facing
    /// name could send a name the server does not have — or a different tool whose name folds
    /// to the same thing.
    func testACallCarriesTheServersOwnNameNotTheFoldedOne() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsCallMethod, [.result(.object([
            "content": .array([.object([
                "type": .string("text"),
                "text": .string("ok"),
                "annotations": .object(["audience": .array([.string("user")])]),
            ])]),
        ]))])
        let result = try await client.callTool(
            originalName: "GetPortfolio", arguments: .object(["accountId": .string("1")]))

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.contentBlocks.count, 1)
        XCTAssertEqual(result.contentBlocks.first?.objectValue?["annotations"],
                       .object(["audience": .array([.string("user")])]))
        guard case .request(let request)? = transport.sent.last else {
            return XCTFail("the call must be a request")
        }
        XCTAssertEqual(request.params?.objectValue?["name"], .string("GetPortfolio"))
        XCTAssertEqual(request.params?.objectValue?["arguments"]?.objectValue?["accountId"], .string("1"))
    }

    func testHeaderParametersRideTheHintsRatherThanTheBody() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsCallMethod, [.result(.object([:]))])
        _ = try await client.callTool(
            originalName: "x", arguments: .object([:]), headerParameters: ["Mcp-Param-Tenant": "acme"])

        let hints = transport.hints
        XCTAssertEqual(hints.last?.name, "x")
        XCTAssertEqual(hints.last?.headerParameters, ["Mcp-Param-Tenant": "acme"])
        guard case .request(let request)? = transport.sent.last else { return XCTFail("expected a request") }
        XCTAssertNil(request.params?.objectValue?["arguments"]?.objectValue?["Mcp-Param-Tenant"])
    }

    /// The server's own "this call failed" flag is not a protocol error: the two are different
    /// things, and collapsing them would tell a role its arguments were wrong when the server
    /// was simply down.
    func testAToolThatReportsItsOwnFailureStillReturnsAResult() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsCallMethod, [.result(.object([
            "isError": .bool(true),
            "content": .array([.object(["type": .string("text"), "text": .string("no such account")])]),
        ]))])
        let result = try await client.callTool(originalName: "x", arguments: .object([:]))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.contentBlocks.count, 1)
    }

    /// A server cannot flip a success into a failure through a type confusion.
    func testANonBooleanIsErrorReadsAsSuccess() {
        XCTAssertFalse(MCPWire.callResult(from: .object(["isError": .string("true")])).isError)
        XCTAssertFalse(MCPWire.callResult(from: .object(["isError": .int(1)])).isError)
        XCTAssertTrue(MCPWire.callResult(from: .object(["isError": .bool(true)])).isError)
    }

    func testStructuredContentIsCarriedThrough() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsCallMethod, [.result(.object([
            "structuredContent": .object(["total": .int(42)]),
        ]))])
        let result = try await client.callTool(originalName: "x", arguments: .object([:]))
        XCTAssertEqual(result.structuredContent?.objectValue?["total"], .int(42))
    }

    // MARK: - A result that is not a finished answer

    private func ok(_ text: String) -> JSONValue {
        .array([.object(["type": .string("text"), "text": .string(text)])])
    }

    /// A 2026-07-28 result says what it is (basic/index, "ResultType"). Absent or `"complete"` is
    /// the answer — "clients MUST treat an absent resultType as complete" — and is read as it
    /// always was. `"input_required"` is a server asking, before it will finish, for input this
    /// client never offers: it declares no capability, and it retries no call (multi round-trip
    /// requests, MRTR) — so a `requestState` alone is no answer either. And "A resultType of any
    /// value unrecognized by the client MUST be considered invalid". Neither is read as the tool's
    /// answer: the call fails, closed, and says which. Spelled as the spec spells them.
    ///
    /// RED until 2026-10-28: `resultType` was never read, and an `input_required` result
    /// reached the role as an empty, successful tool result.
    func testAModernResultThatIsNotFinishedFailsTheCallClosed() async throws {
        let refused: [(String, JSONValue, MCPClientError, String)] = [
            ("input required", .object([
                "resultType": .string("input_required"),
                "inputRequests": .object(["login": .object([
                    "method": .string("elicitation/create"),
                    "params": .object(["mode": .string("form"), "message": .string("Your login?")]),
                ])]),
            ]), .inputRequired, "input_required"),
            ("input required, state alone", .object([
                "resultType": .string("input_required"), "requestState": .string("opaque"),
            ]), .inputRequired, "input_required"),
            ("a type it does not know", .object([
                "resultType": .string("streaming"), "content": ok("looks like an answer"),
            ]), .unknownResultType("streaming"), "streaming"),
            ("a type that is not a string", .object(["resultType": .int(5), "content": ok("x")]),
             .unknownResultType("5"), "(5)"),
        ]
        for (label, answer, expected, named) in refused {
            let transport = ScriptedTransport()
            let client = try await connected(transport)
            transport.script(MCPWire.toolsCallMethod, [.result(answer)])
            do {
                let result = try await client.callTool(originalName: "x", arguments: .object([:]))
                XCTFail("\(label): read as the tool's answer — \(result)")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, expected, label)
                XCTAssertTrue(error.message.contains(named), "\(label): \(error.message)")
            }
            await client.close(budget: 0)
        }

        for (label, answer) in [
            ("complete", JSONValue.object(["resultType": .string("complete"), "content": ok("done")])),
            ("no resultType", .object(["content": ok("done")])),
        ] {
            let transport = ScriptedTransport()
            let client = try await connected(transport)
            transport.script(MCPWire.toolsCallMethod, [.result(answer)])
            let result = try await client.callTool(originalName: "x", arguments: .object([:]))
            XCTAssertEqual(result.contentBlocks, ok("done").arrayValue, label)
            await client.close(budget: 0)
        }
    }

    /// The rule is the revision's: a page of `tools/list` that is not a finished answer is no
    /// catalogue — the reference server may never send one there (MRTR: "Servers MUST NOT send
    /// InputRequiredResult responses on any other client requests"). A legacy session's result
    /// carries no `resultType` in its revision, and a member of that name is read past, as any
    /// unknown member is.
    func testTheResultTypeIsAModernRuleForEveryResult() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.script(MCPWire.toolsListMethod, [.result(.object([
            "resultType": .string("input_required"), "tools": .array([tool("a")]),
        ]))])
        do {
            let tools = try await client.listAllTools()
            XCTFail("an unfinished page was read as the catalogue: \(tools)")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .inputRequired)
        }
        await client.close(budget: 0)

        let legacy = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(code: MCPErrorCode.methodNotFound, message: "unknown")],
            MCPWire.initializeMethod: [.result(.object(["protocolVersion": .string("2025-11-25")]))],
            MCPWire.toolsCallMethod: [.result(.object([
                "resultType": .string("input_required"), "content": ok("legacy"),
            ]))],
        ])
        let legacyClient = MCPClient(transport: legacy, log: nil, timeouts: fastTimeouts, clientVersion: "1.0")
        let connection = try await legacyClient.connect(cachedEra: nil)
        XCTAssertEqual(connection.era, .legacy, "premise")
        let result = try await legacyClient.callTool(originalName: "x", arguments: .object([:]))
        XCTAssertEqual(result.contentBlocks, ok("legacy").arrayValue)
        await legacyClient.close(budget: 0)
    }

    // MARK: - The server's own secrets in a RESULT

    private static let bearer = "tok_live_9f8e7d6c5b4a"
    private static let headerValue = "wk_live_8f3a9c2d"

    /// Counts how often the client asked for its credentials — a Keychain read in production.
    private final class CredentialReads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var reads: Int { lock.withLock { count } }
        func note() { lock.withLock { count += 1 } }
    }

    private func connected(
        _ transport: ScriptedTransport,
        credentials: MCPRedaction.Credentials,
        reads: CredentialReads? = nil
    ) async throws -> MCPClient {
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        let client = MCPClient(
            transport: transport, log: nil, timeouts: fastTimeouts, clientVersion: "1.0",
            credentials: { reads?.note(); return credentials })
        _ = try await client.connect(cachedEra: nil)
        return client
    }

    private var ours: MCPRedaction.Credentials {
        MCPRedaction.Credentials(headerNames: ["X-Workspace-Key"], values: [Self.bearer, Self.headerValue])
    }

    private func call(_ client: MCPClient, _ transport: ScriptedTransport, answering result: JSONValue)
        async throws -> MCPCallToolResult {
        transport.script(MCPWire.toolsCallMethod, [.result(result)])
        return try await client.callTool(originalName: "x", arguments: .object([:]))
    }

    private func textBlock(_ text: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    /// A server that echoes the token it was sent hands it to the model, which can carry it to
    /// another server or into an artifact. The error paths were scrubbed (F11); a RESULT was not.
    func testAnEchoedBearerInATextBlockIsReplaced() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        let result = try await call(client, transport, answering: .object([
            "content": .array([textBlock("debug: you sent Bearer \(Self.bearer), welcome")]),
        ]))
        XCTAssertEqual(
            result.contentBlocks.first?.objectValue?["text"],
            .string("debug: you sent Bearer \(MCPRedaction.placeholder), welcome"))
    }

    /// A leaf and a KEY: a server that keys a map by the credential it was called with puts
    /// the credential in the key. Every other key and value comes through as sent.
    func testAnEchoedHeaderValueInStructuredContentIsReplacedInALeafAndAKey() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        let result = try await call(client, transport, answering: .object([
            "structuredContent": .object([
                "caller": .object(["key": .string(Self.headerValue), "plan": .string("pro")]),
                Self.headerValue: .array([.string("session for \(Self.headerValue)"), .int(3)]),
                "total": .int(42),
            ]),
        ]))
        XCTAssertEqual(result.structuredContent, .object([
            "caller": .object(["key": .string(MCPRedaction.placeholder), "plan": .string("pro")]),
            MCPRedaction.placeholder: .array([.string("session for \(MCPRedaction.placeholder)"), .int(3)]),
            "total": .int(42),
        ]))
    }

    /// Two keys that scrub to the same name keep both values: the one scrubbing left alone
    /// keeps its name, the rest take numbered suffixes — in scalar order, not dictionary order.
    /// No visible spelling: that is the one thing this scrub exists to hide.
    func testKeysThatCollideAfterScrubbingKeepEveryValue() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        let placeholder = MCPRedaction.placeholder
        let result = try await call(client, transport, answering: .object([
            "structuredContent": .object([
                placeholder: .string("already named so"),
                Self.headerValue: .string("header"),
                Self.bearer: .string("bearer"),
            ]),
        ]))
        XCTAssertEqual(result.structuredContent, .object([
            placeholder: .string("already named so"),
            "\(placeholder) (2)": .string("bearer"),
            "\(placeholder) (3)": .string("header"),
        ]))
    }

    /// A value with a quote in it reads `\"` once a server has JSON-encoded it into its text.
    func testTheJSONSpellingOfASecretIsReplacedToo() async throws {
        let quoted = #"pa"ss\word"#
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: MCPRedaction.Credentials(values: [quoted]))
        let result = try await call(client, transport, answering: .object([
            "content": .array([textBlock(#"{"echo":"pa\"ss\\word"} and raw pa"ss\word"#)]),
        ]))
        XCTAssertEqual(
            result.contentBlocks.first?.objectValue?["text"],
            .string(#"{"echo":"<redacted>"} and raw <redacted>"#))
    }

    /// Below the literal floor a value is not a credential worth the name, and cutting it out
    /// of every word it spells would leave a result nobody can read.
    func testAValueShorterThanTheLiteralFloorIsLeftAlone() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: MCPRedaction.Credentials(values: ["abc"]))
        let result = try await call(client, transport, answering: .object([
            "content": .array([textBlock("abc abcdef")]),
            "structuredContent": .object(["abc": .string("abc")]),
        ]))
        XCTAssertEqual(result.contentBlocks.first?.objectValue?["text"], .string("abc abcdef"))
        XCTAssertEqual(result.structuredContent, .object(["abc": .string("abc")]))
    }

    /// Only THIS server's own values go. A tool that lists the user's API keys, or documents
    /// the `Authorization:` header, returns text shaped like a credential — and that text is
    /// the answer, so the generic shape patterns and the header-name patterns stay off DATA.
    func testTextThatMerelyLooksLikeACredentialIsLeftUntouched() async throws {
        let lookalike = """
        Authorization: Bearer sk-proj-4f8a9b2c7d1e6f3a
        X-Workspace-Key: wk_test_0000aaaa
        api_key=AKIAIOSFODNN7EXAMPLE https://user:pass@example.com/
        """
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        let result = try await call(client, transport, answering: .object([
            "content": .array([textBlock(lookalike)]),
            "structuredContent": .object(["token": .string("sk-proj-4f8a9b2c7d1e6f3a")]),
        ]))
        XCTAssertEqual(result.contentBlocks.first?.objectValue?["text"], .string(lookalike))
        XCTAssertEqual(result.structuredContent, .object(["token": .string("sk-proj-4f8a9b2c7d1e6f3a")]))
    }

    /// A failure's text is read by the model exactly as a success's is.
    func testAnErrorResultIsScrubbedToo() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        let result = try await call(client, transport, answering: .object([
            "isError": .bool(true),
            "content": .array([textBlock("key \(Self.headerValue) is over quota")]),
            "structuredContent": .object(["rejected": .string(Self.bearer)]),
        ]))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(
            result.contentBlocks.first?.objectValue?["text"],
            .string("key \(MCPRedaction.placeholder) is over quota"))
        XCTAssertEqual(result.structuredContent, .object(["rejected": .string(MCPRedaction.placeholder)]))
    }

    /// Embedded resource TEXT is a file's contents and is scrubbed; its uri too, and a
    /// resource_link's words. Base64 is not text: a short value turns up in a megabyte of
    /// it by chance, and "scrubbing" it would corrupt the image rather than hide anything.
    func testResourceTextIsScrubbedAndBinaryDataIsLeftAlone() async throws {
        let secret = "QUJDREVG" // base64 of "ABCDEF" — and also an eight-byte credential
        let image = "iVBORw0KGgo\(secret)AAAA"
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: MCPRedaction.Credentials(values: [secret]))
        let result = try await call(client, transport, answering: .object([
            "content": .array([
                .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(image)]),
                .object(["type": .string("audio"), "mimeType": .string("audio/wav"), "data": .string(image)]),
                .object(["type": .string("resource"), "resource": .object([
                    "uri": .string("file:///env?k=\(secret)"), "text": .string("KEY=\(secret)"),
                ])]),
                .object(["type": .string("resource"), "resource": .object([
                    "uri": .string("file:///logo.png"), "blob": .string(image),
                ])]),
                .object(["type": .string("resource_link"), "uri": .string("https://x/\(secret)"),
                         "name": .string(secret), "description": .string("for \(secret)")]),
            ]),
        ]))
        let blocks = result.contentBlocks.compactMap(\.objectValue)
        let placeholder = MCPRedaction.placeholder
        XCTAssertEqual(blocks[0]["data"], .string(image))
        XCTAssertEqual(blocks[1]["data"], .string(image))
        XCTAssertEqual(blocks[2]["resource"], .object([
            "uri": .string("file:///env?k=\(placeholder)"), "text": .string("KEY=\(placeholder)"),
        ]))
        XCTAssertEqual(blocks[3]["resource"]?.objectValue?["blob"], .string(image))
        XCTAssertEqual(blocks[4]["uri"], .string("https://x/\(placeholder)"))
        XCTAssertEqual(blocks[4]["name"], .string(placeholder))
        XCTAssertEqual(blocks[4]["description"], .string("for \(placeholder)"))
    }

    /// A base64 or JWT-style secret carries `/`: a server's JSON encoder writes it `\/`, and a
    /// query or form echo percent-encodes it. Both reach the model as the placeholder.
    func testTheSlashEscapedAndPercentEncodedSpellingsOfASecretAreReplaced() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(
            transport, credentials: MCPRedaction.Credentials(values: ["ab/cd+ef=="]))
        let result = try await call(client, transport, answering: .object([
            "content": .array([textBlock(#"{"echo":"ab\/cd+ef=="} and ?k=ab%2Fcd%2Bef%3D%3D"#)]),
            "structuredContent": .object(["k": .string("ab%2Fcd%2Bef%3D%3D")]),
        ]))
        XCTAssertEqual(
            result.contentBlocks.first?.objectValue?["text"],
            .string(#"{"echo":"<redacted>"} and ?k=<redacted>"#))
        XCTAssertEqual(result.structuredContent, .object(["k": .string(MCPRedaction.placeholder)]))
    }

    /// A secret SPLIT by a character the data sanitizer drops — a bidi override, a tag, a C0
    /// control — is whole again by the time the model reads it. So the scrub looks at the text
    /// AFTER that cleaning, as `route` does for an error; until then it looked before, and the
    /// mapper joined the halves on the way out.
    func testASecretSplitByAStrippedCharacterIsStillReplaced() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        let split = "wk_live\u{202E}_8f3a9c2d"
        let result = try await call(client, transport, answering: .object([
            "content": .array([textBlock("you are \(split) / wk_live\u{E0041}_8f3a9c2d / wk_live\u{07}_8f3a9c2d"),
                               .object(["type": .string("resource"), "resource": .object([
                                   "uri": .string("file:///k"), "text": .string("KEY=\(split)")])])]),
            "structuredContent": .object([split: .string(split), "n": .int(1)]),
        ]))
        let placeholder = MCPRedaction.placeholder
        XCTAssertEqual(
            result.contentBlocks.first?.objectValue?["text"],
            .string("you are \(placeholder) / \(placeholder) / \(placeholder)"))
        XCTAssertEqual(result.contentBlocks.last?.objectValue?["resource"]?.objectValue?["text"],
                       .string("KEY=\(placeholder)"))
        XCTAssertEqual(result.structuredContent, .object([placeholder: .string(placeholder), "n": .int(1)]))
    }

    /// A field the mapper lays out as a LINE or as prose — a link's uri, name, description and
    /// mime type, an embedded resource's uri and mime type, an unknown block's type — loses
    /// characters the data pass keeps (a zero-width space, a joiner), so a secret split by one
    /// is whole again in what the model reads unless the scrub looks at the field in THAT form.
    func testASecretSplitByACharacterOnlyTheLinePassDropsNeverReachesTheModel() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        let split = "wk_live\u{200B}_8f3a9c2d"
        let result = try await call(client, transport, answering: .object([
            "content": .array([
                .object(["type": .string("resource_link"), "uri": .string("https://h/cb?token=\(split)"),
                         "name": .string("n \(split)"), "description": .string("d\n\n\(split)"),
                         "mimeType": .string("text/\(split)")]),
                .object(["type": .string("resource"), "resource": .object([
                    "uri": .string("file:///\(split)"), "mimeType": .string("m/\(split)"), "text": .string("t")])]),
                .object(["type": .string("kind-\(split)")]),
            ]),
        ]))
        let mapped = MCPToolResultMapper.map(
            result: result, toolName: "mcp__x__y", args: [:], callID: "c", destination: nil)
        XCTAssertFalse(mapped.outputJSON.contains(Self.headerValue), mapped.outputJSON)
        XCTAssertTrue(mapped.outputJSON.contains(MCPRedaction.placeholder), mapped.outputJSON)
    }

    /// An `ESC [` right before a secret takes its first letter as the sequence's final byte,
    /// so the cleaned text holds the secret less one character — which no literal matches. The
    /// raw text still holds it whole, so the scrub looks there too.
    func testASecretRightAfterAnUnterminatedCSIIsStillReplaced() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        let result = try await call(client, transport, answering: .object([
            "content": .array([textBlock("x \u{1B}[\(Self.headerValue) y")]),
            "structuredContent": .object(["k": .string("\u{1B}[\(Self.headerValue)")]),
        ]))
        let tail = String(Self.headerValue.dropFirst())
        let text = try XCTUnwrap(result.contentBlocks.first?.objectValue?["text"]?.stringValue)
        XCTAssertFalse(text.contains(tail), text)
        XCTAssertFalse(result.structuredContent?.objectValue?["k"]?.stringValue?.contains(tail) ?? true)
    }

    /// Error text and data have different literal floors: a five-byte value goes from the
    /// server's refusal but stays in its answer; an eight-byte one goes from both.
    func testAResultKeepsAShortValueTheRefusalScrubs() async throws {
        for (value, scrubbedFromData) in [("prodx", false), ("prod-key", true)] {
            let transport = ScriptedTransport()
            let client = try await connected(transport, credentials: MCPRedaction.Credentials(values: [value]))
            let result = try await call(client, transport, answering: .object([
                "content": .array([textBlock("env \(value)")]),
            ]))
            XCTAssertEqual(
                result.contentBlocks.first?.objectValue?["text"],
                .string("env \(scrubbedFromData ? MCPRedaction.placeholder : value)"), value)

            transport.script(MCPWire.toolsCallMethod, [.error(code: -32000, message: "bad env \(value)")])
            do {
                _ = try await client.callTool(originalName: "x", arguments: .object([:]))
                XCTFail("a refusal is not a result")
            } catch MCPClientError.rpc(_, let message, _) {
                XCTAssertEqual(message, "bad env \(MCPRedaction.placeholder)", value)
            }
        }
    }

    /// A value containing another is replaced whole, not left with its tail.
    func testTheLongerOfTwoOverlappingValuesIsReplacedWhole() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(
            transport, credentials: MCPRedaction.Credentials(values: ["wk_live_8f3a", "wk_live_8f3a9c2d"]))
        let result = try await call(client, transport, answering: .object([
            "content": .array([textBlock("wk_live_8f3a9c2d / wk_live_8f3a")]),
        ]))
        XCTAssertEqual(
            result.contentBlocks.first?.objectValue?["text"],
            .string("\(MCPRedaction.placeholder) / \(MCPRedaction.placeholder)"))
    }

    /// A server this app sends nothing to gets its result back exactly as the wire carried it.
    func testAServerWithNoCredentialsChangesNothing() async throws {
        let raw: JSONValue = .object([
            "content": .array([textBlock("Bearer \(Self.bearer)"),
                               .object(["type": .string("image"), "data": .string("QUJD")])]),
            "structuredContent": .object([Self.headerValue: .string(Self.bearer)]),
        ])
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: .none)
        let result = try await call(client, transport, answering: raw)
        XCTAssertEqual(result, MCPWire.callResult(from: raw))
    }

    /// One read per RESULT, however many blocks it has: in production each read is a Keychain
    /// lookup per secret.
    func testTheCredentialsAreReadOncePerResult() async throws {
        let reads = CredentialReads()
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours, reads: reads)
        let before = reads.reads
        _ = try await call(client, transport, answering: .object([
            "content": .array([textBlock("a"), textBlock("b"), textBlock("c")]),
            "structuredContent": .object(["x": .string("y"), "z": .array([.string("w")])]),
        ]))
        XCTAssertEqual(reads.reads - before, 1)
    }

    /// A tool with no parameters must still send an object — a server that decodes
    /// `arguments` into a struct chokes on a string or a null.
    func testArgumentsThatAreNotAnObjectAreSentAsAnEmptyObject() {
        XCTAssertEqual(MCPWire.toolsCallParams(name: "x", arguments: .string("oops")),
                       .object(["name": .string("x"), "arguments": .object([:])]))
        XCTAssertEqual(MCPWire.toolsCallParams(name: "x", arguments: .null),
                       .object(["name": .string("x"), "arguments": .object([:])]))
    }

    // MARK: - Connection state a reader can ask for

    func testTheClientReportsItsEraVersionAndHowManyCallsAreWaiting() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        let era = await client.currentEra
        let version = await client.negotiatedProtocolVersion
        XCTAssertEqual(era, .modern)
        XCTAssertEqual(version, MCPConstants.modernProtocolVersion)
        let idle = await client.inFlightCount
        XCTAssertEqual(idle, 0, "the probe has already been answered")

        transport.script("slow", [.silence])
        let pending = Task { try await client.call(method: "slow") }
        try await Task.sleep(nanoseconds: 100_000_000)
        let waiting = await client.inFlightCount
        XCTAssertEqual(waiting, 1)
        pending.cancel()
        _ = try? await pending.value
    }

    /// A notification is fire-and-forget, but a transport that could not carry it is still a
    /// failure the caller has to see — silently dropping `notifications/initialized` would
    /// leave a legacy server waiting for a handshake that never completes.
    func testANotificationThatCouldNotBeSentIsReported() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        transport.setConnectError(nil)
        transport.script("notifications/x", [.transportFailure(.network("the connection was lost"))])
        do {
            // A notification carries no id, so the scripted transport answers by METHOD; the
            // failure arm throws from `send` itself.
            try await client.notify(method: "notifications/x")
        } catch MCPClientError.transport {
            return
        }
        // The scripted transport answers notifications with `.accepted` before it consults the
        // script, so reaching here is the ordinary path and not a defect.
        let sent = transport.sent.compactMap(\.method)
        XCTAssertTrue(sent.contains("notifications/x"))
    }

    func testAClosedClientRefusesToNotify() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport)
        await client.close(budget: 0)
        do {
            try await client.notify(method: "x")
            XCTFail("a closed client carries nothing")
        } catch MCPClientError.notConnected {
            // expected
        }
    }

    // MARK: - Resources, resource templates, and prompts (D-M3)

    func testResourcesAndTemplatesAndPromptsAreListedAcrossPagesAndTemplatesGracefullyHandleMethodNotFound() async throws {
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.result(.object([
            "capabilities": .object([
                "resources": .object(["listChanged": .bool(true)]),
                "prompts": .object(["listChanged": .bool(true)]),
            ]),
        ]))])
        let client = MCPClient(transport: transport, log: nil, timeouts: fastTimeouts, clientVersion: "1.0")
        let connection = try await client.connect(cachedEra: nil)
        XCTAssertTrue(connection.advertisesResources)
        XCTAssertTrue(connection.advertisesPrompts)
        let advertisesResources = await client.advertisesResources
        let advertisesPrompts = await client.advertisesPrompts
        XCTAssertTrue(advertisesResources)
        XCTAssertTrue(advertisesPrompts)

        transport.script(MCPWire.resourcesListMethod, [
            .result(.object([
                "resources": .array([.object(["uri": .string("file:///a.txt"), "name": .string("a")])]),
                "nextCursor": .string("r2"),
            ])),
            .result(.object([
                "resources": .array([.object(["uri": .string("file:///b.txt"), "name": .string("b")])]),
            ])),
        ])
        let resources = try await client.listAllResources()
        XCTAssertEqual(resources.compactMap { $0.objectValue?["name"]?.stringValue }, ["a", "b"])

        transport.script(MCPWire.resourceTemplatesListMethod, [
            .result(.object([
                "resourceTemplates": .array([.object(["uriTemplate": .string("file:///{path}"), "name": .string("tpl")])]),
            ])),
        ])
        let templates = try await client.listAllResourceTemplates()
        XCTAssertEqual(templates.compactMap { $0.objectValue?["name"]?.stringValue }, ["tpl"])

        // When a server advertises `resources` but does not implement `resources/templates/list`,
        // `-32601` (`methodNotFound`) reads as an empty template list rather than failing the catalogue.
        transport.script(MCPWire.resourceTemplatesListMethod, [
            .error(code: MCPErrorCode.methodNotFound, message: "Method not found"),
        ])
        let emptyTemplates = try await client.listAllResourceTemplates()
        XCTAssertTrue(emptyTemplates.isEmpty)

        transport.script(MCPWire.promptsListMethod, [
            .result(.object([
                "prompts": .array([.object(["name": .string("review")])]),
                "nextCursor": .string("pr2"),
            ])),
            .result(.object([
                "prompts": .array([.object(["name": .string("summarize")])]),
            ])),
        ])
        let prompts = try await client.listAllPrompts()
        XCTAssertEqual(prompts.compactMap { $0.objectValue?["name"]?.stringValue }, ["review", "summarize"])
        await client.close(budget: 0)
    }

    func testReadingAResourceMapsContentsIntoResourceBlocksAndScrubsOwnSecrets() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        let imageBlob = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        transport.script(MCPWire.resourcesReadMethod, [.result(.object([
            "contents": .array([
                .object([
                    "uri": .string("file:///env?k=\(Self.bearer)"),
                    "mimeType": .string("text/plain"),
                    "text": .string("TOKEN=\(Self.bearer) KEY=\(Self.headerValue)"),
                ]),
                .object([
                    "uri": .string("file:///logo.png"),
                    "mimeType": .string("image/png"),
                    "blob": .string(imageBlob),
                ]),
            ]),
        ]))])

        let result = try await client.readResource(uri: "file:///env")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(transport.hints.last?.name, "file:///env")
        guard case .request(let request)? = transport.sent.last else { return XCTFail("expected request") }
        XCTAssertEqual(request.method, MCPWire.resourcesReadMethod)
        XCTAssertEqual(request.params?.objectValue?["uri"], .string("file:///env"))
        XCTAssertEqual(MCPWire.resourcesReadParams(uri: "file:///env"), .object(["uri": .string("file:///env")]))

        let placeholder = MCPRedaction.placeholder
        let blocks = result.contentBlocks.compactMap(\.objectValue)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"], .string("resource"))
        XCTAssertEqual(blocks[0]["resource"], .object([
            "uri": .string("file:///env?k=\(placeholder)"),
            "mimeType": .string("text/plain"),
            "text": .string("TOKEN=\(placeholder) KEY=\(placeholder)"),
        ]))
        XCTAssertEqual(blocks[1]["type"], .string("resource"))
        XCTAssertEqual(blocks[1]["resource"]?.objectValue?["blob"], .string(imageBlob))
        await client.close(budget: 0)
    }

    func testGettingAPromptSendsNameAndArgumentsAndScrubsOwnSecrets() async throws {
        let transport = ScriptedTransport()
        let client = try await connected(transport, credentials: ours)
        transport.script(MCPWire.promptsGetMethod, [.result(.object([
            "description": .string("Review for \(Self.bearer)"),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("Inspect repo with key \(Self.headerValue) on branch main."),
                    ]),
                ]),
                .object([
                    "role": .string("assistant"),
                    "content": .object([
                        "type": .string("resource"),
                        "resource": .object([
                            "uri": .string("file:///cfg"),
                            "text": .string("secret=\(Self.bearer)"),
                        ]),
                    ]),
                ]),
            ]),
        ]))])

        let prompt = try await client.getPrompt(name: "code_review", arguments: ["branch": "main"])
        XCTAssertEqual(transport.hints.last?.name, "code_review")
        guard case .request(let request)? = transport.sent.last else { return XCTFail("expected request") }
        XCTAssertEqual(request.method, MCPWire.promptsGetMethod)
        XCTAssertEqual(request.params?.objectValue?["name"], .string("code_review"))
        XCTAssertEqual(request.params?.objectValue?["arguments"], .object(["branch": .string("main")]))
        XCTAssertEqual(
            MCPWire.promptsGetParams(name: "code_review", arguments: ["branch": "main"]),
            .object(["name": .string("code_review"), "arguments": .object(["branch": .string("main")])]))

        let placeholder = MCPRedaction.placeholder
        XCTAssertEqual(prompt.description, "Review for \(placeholder)")
        XCTAssertEqual(prompt.messages.count, 2)
        XCTAssertEqual(prompt.messages[0].role, "user")
        XCTAssertEqual(prompt.messages[0].text, "Inspect repo with key \(placeholder) on branch main.")
        XCTAssertEqual(prompt.messages[1].role, "assistant")
        XCTAssertTrue(prompt.messages[1].text.contains("secret=\(placeholder)"), prompt.messages[1].text)
        XCTAssertFalse(prompt.renderedText.contains(Self.bearer), prompt.renderedText)
        XCTAssertFalse(prompt.renderedText.contains(Self.headerValue), prompt.renderedText)

        XCTAssertTrue(MCPWire.resourceReadResult(from: .null).contentBlocks.isEmpty)
        let emptyPrompt = MCPWire.promptGetResult(from: .null)
        XCTAssertNil(emptyPrompt.description)
        XCTAssertEqual(emptyPrompt.renderedText, "")
        let descOnlyPrompt = MCPWire.promptGetResult(from: .object([
            "description": .string("Fallback description"),
            "messages": .array([
                .string("not-an-object"),
                .object(["content": .string("not-an-object")]),
                .object(["content": .object([:])]),
                .object(["content": .object(["type": .string("resource"), "resource": .object(["uri": .string("file:///only-uri")])])]),
                .object(["role": .string(""), "content": .object(["type": .string("resource"), "resource": .object(["text": .string("body-only")])])]),
            ]),
        ]))
        XCTAssertEqual(descOnlyPrompt.messages.map(\.role), ["user", "user"])
        XCTAssertEqual(descOnlyPrompt.messages.map(\.text), ["file:///only-uri", "body-only"])
        XCTAssertEqual(
            MCPPromptGetResult(description: "Fallback", messages: []).renderedText,
            "Fallback")
        await client.close(budget: 0)
    }
}
