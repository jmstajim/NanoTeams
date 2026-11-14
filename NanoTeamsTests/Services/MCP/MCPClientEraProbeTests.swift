import XCTest

@testable import NanoTeams

/// Which revision a server speaks, decided in one round trip.
///
/// The probe's whole design rests on one asymmetry: `server/discover` and the errors `-32020`,
/// `-32021` and `-32022` exist only in 2026-07-28, so ANSWERING with any of them identifies a
/// modern server, and anything else — `methodNotFound`, a timeout, garbage — identifies a legacy
/// one. What each answer then means is `MCPEraVerdict`'s, row by row in `MCPEraVerdictTests`;
/// these read it through the client.
final class MCPClientEraProbeTests: XCTestCase {

    private let fastTimeouts = MCPTimeouts(connect: 1, requestInactivity: 5, requestAbsolute: 5)

    private func makeClient(_ transport: ScriptedTransport) -> MCPClient {
        MCPClient(transport: transport, log: nil, timeouts: fastTimeouts, clientVersion: "1.0")
    }

    private func legacyInitializeResult(version: String = MCPConstants.legacyProtocolVersion) -> JSONValue {
        .object([
            "protocolVersion": .string(version),
            "capabilities": .object([:]),
            "serverInfo": .object(["name": .string("trade-room"), "version": .string("2.1")]),
        ])
    }

    // MARK: - Modern

    func testAServerThatAnswersDiscoverIsModern() async throws {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.result(.object([
                "protocolVersion": .string(MCPConstants.modernProtocolVersion),
                "serverInfo": .object(["name": .string("folio"), "title": .string("Folio Desktop")]),
            ]))],
        ])
        let connection = try await makeClient(transport).connect(cachedEra: nil)
        XCTAssertEqual(connection.era, .modern)
        XCTAssertEqual(connection.protocolVersion, MCPConstants.modernProtocolVersion)
        XCTAssertEqual(connection.serverInfo.title, "Folio Desktop")
        let adopted = transport.adoptedEra
        XCTAssertEqual(adopted, .modern)
    }

    /// The modern era carries version and capabilities in `_meta` of every request, because
    /// there is no handshake to carry them once — under the keys the 2026-07-28 revision
    /// reserves, spelled HERE as the spec spells them (basic/index, "Per-request protocol
    /// fields"), never through the app's own constant: `io.modelcontextprotocol/protocolVersion`
    /// and `io.modelcontextprotocol/clientCapabilities` are required on every request, and
    /// `io.modelcontextprotocol/clientInfo` should be there. "A request missing any required
    /// field is malformed; the server MUST reject it with JSON-RPC error code -32602" — so the
    /// bare spellings are asserted ABSENT too: under them a conforming server refused the probe,
    /// the probe fell back, and the app ran the legacy era against every modern server.
    ///
    /// RED until 2026-10-28: the keys were the bare `protocolVersion`, `capabilities` and
    /// `clientInfo`.
    func testTheProbeCarriesTheVersionAndTheEmptyCapabilitiesInMeta() async throws {
        let transport = ScriptedTransport(answers: [MCPWire.discoverMethod: [.result(.object([:]))]])
        _ = try await makeClient(transport).connect(cachedEra: nil)

        guard case .request(let request)? = transport.sent.first else {
            return XCTFail("the probe must be a request")
        }
        XCTAssertEqual(request.method, MCPWire.discoverMethod)
        let meta = try XCTUnwrap(request.params?.objectValue?["_meta"]?.objectValue)
        XCTAssertEqual(meta["io.modelcontextprotocol/protocolVersion"], .string("2026-07-28"))
        XCTAssertEqual(meta["io.modelcontextprotocol/clientCapabilities"], .object([:]),
                       "declaring sampling, elicitation or roots would open a channel a server could drive")
        XCTAssertEqual(meta["io.modelcontextprotocol/clientInfo"],
                       .object(["name": .string("NanoTeams"), "version": .string("1.0")]))
        for bare in ["protocolVersion", "capabilities", "clientCapabilities", "clientInfo"] {
            XCTAssertNil(meta[bare], "`\(bare)` is not a key the revision reads: \(meta.keys.sorted())")
        }
        XCTAssertEqual(meta.count, 3, "nothing else rides the envelope: \(meta.keys.sorted())")
    }

    func testAServerThatNamesNoVersionKeepsTheOneItWasOffered() async throws {
        let transport = ScriptedTransport(answers: [MCPWire.discoverMethod: [.result(.object([:]))]])
        let connection = try await makeClient(transport).connect(cachedEra: nil)
        XCTAssertEqual(connection.protocolVersion, MCPConstants.modernProtocolVersion)
    }

    /// A server that refuses a version it lists as supported is contradicting itself — which
    /// happens while it starts up or rolls a config. Retried ONCE, and never by falling back.
    func testMinusThirtyTwoOhTwoTwoNamingOurVersionRetriesOnceAndStaysModern() async throws {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [
                .error(code: MCPErrorCode.unsupportedProtocolVersion, message: "not yet",
                       data: .object(["supported": .array([.string(MCPConstants.modernProtocolVersion)])])),
                .result(.object(["protocolVersion": .string(MCPConstants.modernProtocolVersion)])),
            ],
        ])
        let connection = try await makeClient(transport).connect(cachedEra: nil)
        XCTAssertEqual(connection.era, .modern)
        let methods = transport.sent.compactMap(\.method)
        XCTAssertEqual(methods, [MCPWire.discoverMethod, MCPWire.discoverMethod])
        XCTAssertFalse(methods.contains(MCPWire.initializeMethod), "a -32022 server is modern; there is no fallback")
    }

    /// A server that knows the code and does not speak our version is modern and unusable.
    /// Falling back would offer `initialize` to a server that has none and report the
    /// resulting `methodNotFound` as the reason — hiding the real one.
    func testMinusThirtyTwoOhTwoTwoWithoutOurVersionFailsWithoutFallingBack() async {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(
                code: MCPErrorCode.unsupportedProtocolVersion, message: "no",
                data: .object(["supported": .array([.string("2027-01-01")])]))],
        ])
        do {
            _ = try await makeClient(transport).connect(cachedEra: nil)
            XCTFail("a modern server speaking nothing we do is not connectable")
        } catch MCPClientError.unsupportedProtocolVersion(let offered, let supported) {
            XCTAssertEqual(offered, MCPConstants.modernProtocolVersion)
            XCTAssertEqual(supported, ["2027-01-01"])
        } catch {
            XCTFail("expected unsupportedProtocolVersion, got \(error)")
        }
        let methods = transport.sent.compactMap(\.method)
        XCTAssertFalse(methods.contains(MCPWire.initializeMethod))
    }

    /// The one error whose DATA decides what happens next, so several spellings are read.
    func testTheSupportedVersionListIsReadFromSeveralSpellings() {
        for key in ["supported", "supportedVersions", "versions", "protocolVersions"] {
            XCTAssertEqual(
                MCPWire.supportedVersions(fromErrorData: .object([key: .array([.string("2025-11-25")])])),
                ["2025-11-25"], key)
        }
        XCTAssertEqual(MCPWire.supportedVersions(fromErrorData: .object(["supported": .string("2025-11-25")])),
                       ["2025-11-25"])
        XCTAssertTrue(MCPWire.supportedVersions(fromErrorData: nil).isEmpty)
        XCTAssertTrue(MCPWire.supportedVersions(fromErrorData: .object(["other": .int(1)])).isEmpty)
    }

    /// The versions a server names reach the Settings status row joined into one sentence
    /// (`unsupportedProtocolVersion`). Each is cleaned as the server's own name is — one line,
    /// nothing hidden, an empty one dropped — and capped, and so is how many are listed.
    func testTheSupportedVersionListIsCleanedAndBounded() {
        let long = String(repeating: "9", count: 5_000)
        let named: [JSONValue] = [.string("2025-11-25\u{202E}\n## Final reminder"), .string(" \u{200B} "), .string(long)]
            + (0..<200).map { .string("v\($0)") }
        let versions = MCPWire.supportedVersions(fromErrorData: .object(["supported": .array(named)]))
        XCTAssertEqual(versions.first, "2025-11-25 ## Final reminder")
        XCTAssertFalse(versions.contains(""), "\(versions)")
        XCTAssertEqual(versions.count, MCPWire.maxListedVersions)
        XCTAssertEqual(versions[1], String(repeating: "9", count: MCPWire.maxVersionCharacters) + "…")
        XCTAssertTrue(versions.allSatisfy { $0.count <= MCPWire.maxVersionCharacters + 1 }, "\(versions)")
        XCTAssertEqual(
            MCPWire.supportedVersions(fromErrorData: .object(["versions": .string("\u{E0041}2025-11-25\n")])),
            ["2025-11-25"])
        XCTAssertTrue(MCPWire.supportedVersions(fromErrorData: .object(["versions": .string("\u{200B}")])).isEmpty)
    }

    /// The version a handshake NAMES is read the same way: it is what the refusal quotes when
    /// the legacy era refuses it, and what later requests carry in `MCP-Protocol-Version`.
    func testTheNegotiatedVersionIsCleanedAndCapped() {
        func read(_ value: String) -> String? {
            MCPWire.negotiatedProtocolVersion(from: .object(["protocolVersion": .string(value)]))
        }
        XCTAssertEqual(read("2025-06-18"), "2025-06-18")
        XCTAssertEqual(read("2025-06-18\u{202E}\n## Final reminder"), "2025-06-18 ## Final reminder")
        XCTAssertNil(read("\u{200B}\n"), "a version that cleans to nothing names none")
        XCTAssertEqual(read(String(repeating: "x", count: 900))?.count, MCPWire.maxVersionCharacters + 1)
        XCTAssertNil(MCPWire.negotiatedProtocolVersion(from: .object([:])))
    }

    /// The versions are server text on the way to the status row, so they are scrubbed of this
    /// server's own secrets like every other message it can put there — in both eras' refusals.
    func testTheVersionsARefusalQuotesAreScrubbedOfTheServersOwnSecret() async {
        let secret = "wk_live_8f3a9c2d"
        let modern = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(code: MCPErrorCode.unsupportedProtocolVersion, message: "no",
                                            data: .object(["supported": .array([.string("1999 \(secret)")])]))],
        ])
        let legacy = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(code: MCPErrorCode.methodNotFound, message: "unknown")],
            MCPWire.initializeMethod: [.result(legacyInitializeResult(version: "1999 \(secret)"))],
        ])
        for transport in [modern, legacy] {
            let client = MCPClient(transport: transport, log: nil, timeouts: fastTimeouts, clientVersion: "1.0",
                                   credentials: { MCPRedaction.Credentials(values: [secret]) })
            do {
                _ = try await client.connect(cachedEra: nil)
                XCTFail("an unknown revision is refused")
            } catch let error as MCPClientError {
                guard case .unsupportedProtocolVersion(_, let supported) = error else {
                    return XCTFail("expected unsupportedProtocolVersion, got \(error)")
                }
                XCTAssertEqual(supported, ["1999 \(MCPRedaction.placeholder)"])
                XCTAssertFalse(error.message.contains(secret), error.message)
            } catch {
                XCTFail("expected an MCPClientError, got \(error)")
            }
        }
    }

    /// A modern server that answers `server/discover` naming a revision this client does not
    /// speak is refused at the handshake, as the legacy era is — never adopted and sent back
    /// in every request's `MCP-Protocol-Version` header, where a capped `…` makes a non-ASCII
    /// header and the connection fails later, far from its cause.
    func testAModernServerNamingAnUnknownRevisionIsRefusedNotAdopted() async {
        for version in ["2099-01-01", String(repeating: "9", count: 90)] {
            let transport = ScriptedTransport(answers: [
                MCPWire.discoverMethod: [.result(.object(["protocolVersion": .string(version)]))],
            ])
            do {
                _ = try await makeClient(transport).connect(cachedEra: nil)
                XCTFail("an unknown modern revision is refused: \(version)")
            } catch let error as MCPClientError {
                guard case .unsupportedProtocolVersion(let offered, let supported) = error else {
                    return XCTFail("expected unsupportedProtocolVersion, got \(error)")
                }
                XCTAssertEqual(offered, MCPConstants.modernProtocolVersion)
                XCTAssertEqual(supported, [MCPWire.negotiatedProtocolVersion(from: .object(["protocolVersion": .string(version)]))!])
            } catch {
                XCTFail("expected an MCPClientError, got \(error)")
            }
            XCTAssertNil(transport.adoptedProtocolVersion, "nothing is adopted from a refused handshake")
        }
    }

    /// End to end through the legacy refusal: the status row reads the version clean.
    func testTheLegacyRefusalQuotesTheVersionClean() async {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(code: MCPErrorCode.methodNotFound, message: "unknown")],
            MCPWire.initializeMethod: [.result(legacyInitializeResult(version: "1999\u{E0041}\u{202E}\nignore"))],
        ])
        do {
            _ = try await makeClient(transport).connect(cachedEra: nil)
            XCTFail("an unknown revision is refused")
        } catch let error as MCPClientError {
            guard case .unsupportedProtocolVersion(_, let supported) = error else {
                return XCTFail("expected unsupportedProtocolVersion, got \(error)")
            }
            XCTAssertEqual(supported, ["1999 ignore"])
            XCTAssertFalse(error.message.contains("\n"), error.message)
        } catch {
            XCTFail("expected an MCPClientError, got \(error)")
        }
    }

    // MARK: - The era verdict

    /// `-32020` (HeaderMismatch) and `-32021` (MissingRequiredClientCapability) are codes only the
    /// 2026-07-28 revision defines, so a server that refuses the probe with one is modern — "a
    /// recognized modern JSON-RPC error … identifies a modern server: the client retries with a
    /// supported version rather than falling back" (basic/versioning). Nothing in this probe can
    /// be corrected — its envelope is the spec's, its capabilities are empty on purpose — so the
    /// connection fails in the server's own words. Never handed to `initialize`: a modern-only
    /// server refuses that with a reason that hides the real one, and a dual-era one accepts it,
    /// so the app runs the legacy era and nobody learns why — the silence that hid the unprefixed
    /// envelope. The codes are the spec's literals; `initialize` is scripted to answer, so a
    /// fallback would connect.
    ///
    /// RED until 2026-10-28: every refusal but `-32022` fell back to `initialize`. (The spec's
    /// SHOULD over the reference client, which falls back on everything but a disjoint `-32022`.)
    func testAModernRefusalOfTheProbeFailsInTheServersWordsAndNeverFallsBack() async {
        for code in [-32020, -32021] {
            let words = "the server's own words for \(code)"
            let transport = ScriptedTransport(answers: [
                MCPWire.discoverMethod: [.error(
                    code: code, message: words,
                    data: .object(["requiredCapabilities": .object(["sampling": .object([:])])]))],
                MCPWire.initializeMethod: [.result(legacyInitializeResult())],
            ])
            do {
                let connection = try await makeClient(transport).connect(cachedEra: nil)
                XCTFail("\(code): connected \(connection.era) — the refusal was handed to initialize")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .handshakeRefused(code: code, message: words), "\(code)")
                XCTAssertTrue(error.message.contains(words), "\(code): \(error.message)")
                XCTAssertTrue(error.message.contains(String(code)), "\(code): \(error.message)")
            } catch {
                XCTFail("\(code): expected an MCPClientError, got \(error)")
            }
            XCTAssertEqual(transport.sent.compactMap(\.method), [MCPWire.discoverMethod], "\(code): no fallback")
            XCTAssertNil(transport.adoptedEra, "\(code): nothing is adopted from a refused probe")
        }
    }

    /// The same refusal the way a 2026-07-28 server sends it over HTTP — `400 Bad Request`
    /// carrying the JSON-RPC error, `-32021` with `data.requiredCapabilities` (basic/index: "On
    /// HTTP, the response status MUST be 400 Bad Request") — through the real transport, including
    /// when the server omits `id` or writes `"id": null` on the POST's refusal (D-M9 pt. 2).
    func testAModernRefusalOfTheProbeOverHTTPNeverReachesInitialize() async throws {
        let cases: [(String, String, Int, String)] = [
            ("echoed id -32020", #""id":{{id}},"#, -32020, "Header mismatch: Mcp-Method"),
            ("echoed id -32021", #""id":{{id}},"#, -32021, "Missing required client capability"),
            ("omitted id -32020", "", -32020, "Header mismatch without id"),
            ("null id -32021", #""id":null,"#, -32021, "Missing capability with null id"),
        ]
        for (label, idMember, code, words) in cases {
            let session = ScriptedMCPHTTPSession()
            session.conforming = true
            session.repliesByRPCMethod[MCPWire.discoverMethod] = .json(
                #"{"jsonrpc":"2.0","# + idMember + #""error":{"code":"# + String(code) + #","message":""# + words
                    + #"","data":{"requiredCapabilities":{"sampling":{}}}}}"#,
                status: 400)
            session.repliesByRPCMethod[MCPWire.initializeMethod] = .json(
                #"{"jsonrpc":"2.0","id":{{id}},"result":{"protocolVersion":"2025-11-25"}}"#,
                headers: ["Mcp-Session-Id": "sess-1"])
            session.repliesByRPCMethod[MCPWire.initializedNotification] = .accepted
            session.getReplies = [.status(405)]
            let client = MCPClient(
                transport: StreamableHTTPTransport(
                    config: MCPHTTPConfig(urlString: "https://example.com/mcp"),
                    authorizer: NoAuthorizer(), session: session, timeouts: fastTimeouts),
                log: nil, timeouts: fastTimeouts, clientVersion: "1.0")
            do {
                let connection = try await client.connect(cachedEra: nil)
                XCTFail("\(label): connected \(connection.era)")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .handshakeRefused(code: code, message: words), label)
            }
            XCTAssertTrue(session.requests(rpcMethod: MCPWire.initializeMethod).isEmpty, "\(label): no fallback")
            await client.close(budget: 0)
        }
    }

    /// Every other refusal of the probe falls back to `initialize`, as it always did: a legacy
    /// server's `-32601` for a method it has never heard of, `-32602`, `-32603`, an
    /// implementation's own `-32000`, and `-32042`, which 2025-11-25 alone defined — inside the
    /// range the 2026-07-28 revision reserves without being one of its codes (basic/index, "Error
    /// Codes": the set is exactly -32020, -32021, -32022). Literal codes, scripted fallback.
    func testEveryOtherRefusalOfTheProbeFallsBackToTheLegacyHandshake() async throws {
        for code in [-32601, -32602, -32603, -32000, -32042] {
            let transport = ScriptedTransport(answers: [
                MCPWire.discoverMethod: [.error(code: code, message: "no")],
                MCPWire.initializeMethod: [.result(legacyInitializeResult())],
            ])
            let connection = try await makeClient(transport).connect(cachedEra: nil)
            XCTAssertEqual(connection.era, .legacy, "\(code)")
            XCTAssertEqual(transport.sent.compactMap(\.method).first(where: { $0 != MCPWire.discoverMethod }),
                           MCPWire.initializeMethod, "\(code)")
        }
    }

    /// A `-32022` whose supported list shares no MODERN revision with this client but names a
    /// handshake-era one it accepts is a dual-era server saying which revision to speak: "The
    /// client SHOULD select a mutually supported version from the `supported` list and retry the
    /// request" (basic/versioning), and a mutual handshake-era revision is reached through
    /// `initialize`. A list sharing nothing at all — a handshake revision this client does not
    /// accept included — still fails, naming it, with no `initialize` tried.
    ///
    /// RED until 2026-10-28: any `-32022` without this client's modern revision failed the
    /// connection, a dual-era server's too.
    func testAVersionRefusalNamingOnlyAHandshakeRevisionTakesTheLegacyHandshake() async throws {
        for supported in [["2025-11-25"], ["2027-01-01", "2025-06-18"]] {
            let transport = ScriptedTransport(answers: [
                MCPWire.discoverMethod: [.error(
                    code: -32022, message: "Unsupported protocol version",
                    data: .object(["supported": .array(supported.map { .string($0) }),
                                   "requested": .string("2026-07-28")]))],
                MCPWire.initializeMethod: [.result(legacyInitializeResult())],
            ])
            let connection = try await makeClient(transport).connect(cachedEra: nil)
            XCTAssertEqual(connection.era, .legacy, "\(supported)")
            XCTAssertEqual(
                transport.sent.compactMap(\.method),
                [MCPWire.discoverMethod, MCPWire.initializeMethod, MCPWire.initializedNotification], "\(supported)")
        }

        let disjoint = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(
                code: -32022, message: "no", data: .object(["supported": .array([.string("2024-11-05")])]))],
            MCPWire.initializeMethod: [.result(legacyInitializeResult())],
        ])
        do {
            _ = try await makeClient(disjoint).connect(cachedEra: nil)
            XCTFail("a list sharing nothing with this client is not connectable")
        } catch MCPClientError.unsupportedProtocolVersion(let offered, let supported) {
            XCTAssertEqual(offered, "2026-07-28")
            XCTAssertEqual(supported, ["2024-11-05"])
        } catch {
            XCTFail("expected unsupportedProtocolVersion, got \(error)")
        }
        XCTAssertFalse(disjoint.sent.compactMap(\.method).contains(MCPWire.initializeMethod))
    }

    /// A `DiscoverResult` names the revisions its server speaks — "`supportedVersions`: Protocol
    /// versions the server supports. The client should choose one of these for subsequent
    /// requests" (server/discover) — and is adopted BY that list, not merely for answering: this
    /// client's modern revision among them → modern; only a handshake revision it accepts in
    /// common → the legacy handshake (a legacy advertisement, as the reference client reads it,
    /// not an incompatibility); nothing in common, an empty list included → refused, naming the
    /// list, with no `initialize` tried. A result naming no list stays as it was: the revision the
    /// probe asked for, unless the server names another (`protocolVersion`).
    ///
    /// RED until 2026-10-28: any answer was adopted as modern, read only for `protocolVersion`
    /// — an `initialize` field the revision's `DiscoverResult` does not have.
    func testADiscoverResultIsAdoptedByItsSupportedVersions() async throws {
        func probe(_ supported: [String]) -> ScriptedTransport {
            ScriptedTransport(answers: [
                MCPWire.discoverMethod: [.result(.object([
                    "resultType": .string("complete"),
                    "supportedVersions": .array(supported.map { .string($0) }),
                    "capabilities": .object(["tools": .object([:])]),
                ]))],
                MCPWire.initializeMethod: [.result(legacyInitializeResult())],
            ])
        }
        let modern = probe(["2026-07-28", "2025-11-25"])
        let both = try await makeClient(modern).connect(cachedEra: nil)
        XCTAssertEqual(both.era, .modern)
        XCTAssertEqual(both.protocolVersion, "2026-07-28")
        XCTAssertEqual(modern.sent.compactMap(\.method), [MCPWire.discoverMethod])

        let legacy = probe(["2025-11-25"])
        let handshake = try await makeClient(legacy).connect(cachedEra: nil)
        XCTAssertEqual(handshake.era, .legacy)
        XCTAssertEqual(legacy.sent.compactMap(\.method).dropFirst().first, MCPWire.initializeMethod)

        for disjoint in [["2027-01-01"], []] {
            let transport = probe(disjoint)
            do {
                _ = try await makeClient(transport).connect(cachedEra: nil)
                XCTFail("\(disjoint): a list sharing nothing with this client is not connectable")
            } catch MCPClientError.unsupportedProtocolVersion(let offered, let supported) {
                XCTAssertEqual(offered, "2026-07-28", "\(disjoint)")
                XCTAssertEqual(supported, disjoint)
            } catch {
                XCTFail("\(disjoint): expected unsupportedProtocolVersion, got \(error)")
            }
            XCTAssertEqual(transport.sent.compactMap(\.method), [MCPWire.discoverMethod], "\(disjoint)")
            XCTAssertNil(transport.adoptedEra, "\(disjoint)")
        }
    }

    /// A probe answered with a result that is not a finished one — `input_required`, which the
    /// revision allows only on `prompts/get`, `resources/read` and `tools/call` (MRTR, "Supported
    /// Requests"), or a `resultType` this client does not know, which "MUST be considered
    /// invalid" — identifies a modern server (a legacy server answers `server/discover` with
    /// method-not-found, not a result) and fails as incompatible with the resultType message
    /// rather than falling back to `initialize`.
    func testAProbeAnsweredWithAnUnfinishedResultIsNotReadAsADiscoverResult() async throws {
        let rows: [(String, MCPClientError)] = [
            ("input_required", .inputRequired),
            ("streaming", .unknownResultType("streaming")),
        ]
        for (type, expectedError) in rows {
            let transport = ScriptedTransport(answers: [
                MCPWire.discoverMethod: [.result(.object([
                    "resultType": .string(type), "supportedVersions": .array([.string("2026-07-28")]),
                ]))],
                MCPWire.initializeMethod: [.result(legacyInitializeResult())],
            ])
            do {
                _ = try await makeClient(transport).connect(cachedEra: nil)
                XCTFail("\(type): expected \(expectedError)")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, expectedError, type)
            }
            XCTAssertEqual(transport.sent.compactMap(\.method), [MCPWire.discoverMethod], type)
            XCTAssertNil(transport.adoptedEra, type)
        }
    }

    // MARK: - Legacy

    func testAServerThatHasNeverHeardOfDiscoverIsLegacy() async throws {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(code: MCPErrorCode.methodNotFound, message: "unknown")],
            MCPWire.initializeMethod: [.result(legacyInitializeResult())],
        ])
        let connection = try await makeClient(transport).connect(cachedEra: nil)
        XCTAssertEqual(connection.era, .legacy)
        XCTAssertEqual(connection.protocolVersion, MCPConstants.legacyProtocolVersion)
        XCTAssertEqual(connection.serverInfo.name, "trade-room")
        let adopted = transport.adoptedEra
        XCTAssertEqual(adopted, .legacy)
    }

    /// On a `ManualMCPClock` (since 2026-10-28; it waited one real second): the probe's watchdog
    /// is armed at the connect budget, and once the clock passes it the handshake goes on as
    /// legacy. Bounded both ways, like its correlation twins: a watchdog armed past the clock fails
    /// at the arming, a connect that never ends at `boundedValue` — never a hung run.
    func testAProbeThatTimesOutFallsBackToLegacy() async throws {
        let clock = ManualMCPClock()
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.silence],
            MCPWire.initializeMethod: [.result(legacyInitializeResult())],
        ])
        let client = MCPClient(
            transport: transport, log: nil,
            timeouts: MCPTimeouts(connect: 1, requestInactivity: 1, requestAbsolute: 1),
            clientVersion: "1.0", clock: clock)
        let connecting = Task { try await client.connect(cachedEra: nil) }
        let armed = await clock.waitForSleeper(dueIn: 1)
        XCTAssertTrue(armed, "the probe was not given the one-second connect budget")
        XCTAssertFalse(transport.sent.contains { $0.method == MCPWire.initializeMethod },
                       "the handshake fell back before the probe's budget ran out")
        guard armed else { return connecting.cancel() }
        clock.advance(by: 1)
        let connection = try await boundedValue(of: connecting, "the connect")
        XCTAssertEqual(connection.era, .legacy)
    }

    func testAMalformedProbeReplyFallsBackToLegacy() async throws {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(code: MCPErrorCode.internalError, message: "boom")],
            MCPWire.initializeMethod: [.result(legacyInitializeResult())],
        ])
        let connection = try await makeClient(transport).connect(cachedEra: nil)
        XCTAssertEqual(connection.era, .legacy)
    }

    /// The handshake ends with the notification, and only then is the connection usable.
    func testTheLegacyHandshakeSendsInitializedAndCarriesNoMetaOnIt() async throws {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(code: MCPErrorCode.methodNotFound, message: "unknown")],
            MCPWire.initializeMethod: [.result(legacyInitializeResult())],
        ])
        _ = try await makeClient(transport).connect(cachedEra: nil)

        let sent = transport.sent
        XCTAssertEqual( sent.compactMap(\.method).last, MCPWire.initializedNotification)
        XCTAssertEqual(
            transport.hints.map(\.protocolVersion),
            [MCPConstants.modernProtocolVersion, nil, MCPConstants.legacyProtocolVersion],
            "discover carries the modern revision, initialize carries none, and initialized carries the negotiated one")
        guard case .request(let initialize) = sent[1] else { return XCTFail("initialize must be a request") }
        XCTAssertNil(initialize.params?.objectValue?["_meta"],
                     "the legacy era carries capabilities once, in initialize's own members")
        XCTAssertEqual(initialize.params?.objectValue?["capabilities"], .object([:]))
        XCTAssertEqual(initialize.params?.objectValue?["protocolVersion"],
                       .string(MCPConstants.legacyProtocolVersion))
    }

    /// 2024-11-05 is a DIFFERENT TRANSPORT (HTTP+SSE), not a dialect. Speaking to it over
    /// Streamable HTTP would fail later in a way nothing points at.
    func testAServerAnsweringAnUnacceptedRevisionIsRefused() async {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(code: MCPErrorCode.methodNotFound, message: "unknown")],
            MCPWire.initializeMethod: [.result(legacyInitializeResult(version: "2024-11-05"))],
        ])
        do {
            _ = try await makeClient(transport).connect(cachedEra: nil)
            XCTFail("2024-11-05 is a different transport")
        } catch MCPClientError.unsupportedProtocolVersion(_, let supported) {
            XCTAssertEqual(supported, ["2024-11-05"])
        } catch {
            XCTFail("expected unsupportedProtocolVersion, got \(error)")
        }
    }

    func testEveryAcceptedLegacyRevisionConnects() async throws {
        for version in MCPConstants.acceptedLegacyProtocolVersions.sorted() {
            let transport = ScriptedTransport(answers: [
                MCPWire.discoverMethod: [.error(code: MCPErrorCode.methodNotFound, message: "unknown")],
                MCPWire.initializeMethod: [.result(legacyInitializeResult(version: version))],
            ])
            let connection = try await makeClient(transport).connect(cachedEra: nil)
            XCTAssertEqual(connection.protocolVersion, version)
            let adopted = transport.adoptedProtocolVersion
            XCTAssertEqual(adopted, version)
        }
    }

    // MARK: - The cached era

    /// A hint, never a belief: the cache saves a round trip on the common path.
    func testACachedLegacyEraSkipsTheProbeEntirely() async throws {
        let transport = ScriptedTransport(answers: [
            MCPWire.initializeMethod: [.result(legacyInitializeResult())],
        ])
        let connection = try await makeClient(transport).connect(cachedEra: .legacy)
        XCTAssertEqual(connection.era, .legacy)
        let methods = transport.sent.compactMap(\.method)
        XCTAssertFalse(methods.contains(MCPWire.discoverMethod))
    }

    /// A server can be upgraded under the app, so a cached era that fails re-probes ONCE
    /// rather than reporting a failure.
    func testACachedEraThatNoLongerHoldsFallsThroughToTheProbe() async throws {
        let transport = ScriptedTransport(answers: [
            MCPWire.initializeMethod: [.error(code: MCPErrorCode.methodNotFound, message: "gone")],
            MCPWire.discoverMethod: [.result(.object([
                "protocolVersion": .string(MCPConstants.modernProtocolVersion)]))],
        ])
        let connection = try await makeClient(transport).connect(cachedEra: .legacy)
        XCTAssertEqual(connection.era, .modern)
    }

    /// A catalogue lifetime of 100 ms would re-list between every tool call.
    func testTheServersCatalogueLifetimeIsFloored() async throws {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.result(.object(["_meta": .object(["ttlMs": .int(100)])]))],
        ])
        let connection = try await makeClient(transport).connect(cachedEra: nil)
        XCTAssertEqual(connection.catalogueTTL, MCPConstants.minimumCatalogueTTL)
    }

    func testAServerThatNamesNoLifetimeGetsNone() async throws {
        let transport = ScriptedTransport(answers: [MCPWire.discoverMethod: [.result(.object([:]))]])
        let connection = try await makeClient(transport).connect(cachedEra: nil)
        XCTAssertNil(connection.catalogueTTL)
    }

    func testAnEndpointTheTransportRefusesNeverReachesTheProbe() async {
        let transport = ScriptedTransport()
        transport.setConnectError(.endpointRefused("plain HTTP off loopback"))
        do {
            _ = try await makeClient(transport).connect(cachedEra: nil)
            XCTFail("a refused endpoint is not connectable")
        } catch MCPClientError.transport(.endpointRefused) {
            let sent = transport.sent
            XCTAssertTrue(sent.isEmpty)
        } catch {
            XCTFail("expected a transport refusal, got \(error)")
        }
    }

    /// A server that keeps refusing a version it keeps listing is refusing it, and one retry
    /// is all the contradiction is worth.
    func testAServerThatContradictsItselfTwiceIsGivenUpOn() async {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.error(
                code: MCPErrorCode.unsupportedProtocolVersion, message: "not yet",
                data: .object(["supported": .array([.string(MCPConstants.modernProtocolVersion)])]))],
        ])
        do {
            _ = try await makeClient(transport).connect(cachedEra: nil)
            XCTFail("two refusals in a row are a refusal")
        } catch MCPClientError.unsupportedProtocolVersion(let offered, let supported) {
            XCTAssertEqual(offered, MCPConstants.modernProtocolVersion)
            XCTAssertEqual(supported, [MCPConstants.modernProtocolVersion])
        } catch {
            XCTFail("expected unsupportedProtocolVersion, got \(error)")
        }
        let methods = transport.sent.compactMap(\.method)
        XCTAssertEqual(methods, [MCPWire.discoverMethod, MCPWire.discoverMethod],
                       "exactly one retry, and no legacy fallback")
    }

    /// A transport that cannot carry the probe is a transport failure, not a legacy server:
    /// falling back would send `initialize` down the same broken pipe and report its failure
    /// instead of the real one.
    func testATransportThatCannotCarryTheProbeIsReportedAsItself() async {
        let transport = ScriptedTransport(answers: [
            MCPWire.discoverMethod: [.transportFailure(.network("the connection was refused"))],
            MCPWire.initializeMethod: [.transportFailure(.network("the connection was refused"))],
        ])
        do {
            _ = try await makeClient(transport).connect(cachedEra: nil)
            XCTFail("a dead connection is not a handshake")
        } catch MCPClientError.transport(.network(let reason)) {
            XCTAssertEqual(reason, "the connection was refused")
        } catch {
            XCTFail("expected a transport failure, got \(error)")
        }
    }

    // MARK: - The wire's own readers

    /// `_meta` is added to whatever params a method already had, and created when it had none.
    func testModernMetaIsAddedWithoutDisturbingTheMethodsOwnParameters() {
        let withParams = MCPWire.withModernMeta(
            .object(["name": .string("x")]), protocolVersion: "v", clientVersion: "1.0")
        XCTAssertEqual(withParams.objectValue?["name"], .string("x"))
        XCTAssertNotNil(withParams.objectValue?["_meta"])

        let withNone = MCPWire.withModernMeta(nil, protocolVersion: "v", clientVersion: "1.0")
        XCTAssertEqual(withNone.objectValue.map { Set($0.keys) }, ["_meta"])
    }

    /// The spec has no method whose params are not an object, and wrapping one would change
    /// what the server receives — so a non-object is left exactly as it arrived.
    func testANonObjectParamsValueIsLeftAlone() {
        XCTAssertEqual(MCPWire.withModernMeta(.string("raw"), protocolVersion: "v", clientVersion: "1"),
                       .string("raw"))
        XCTAssertEqual(MCPWire.withModernMeta(.array([.int(1)]), protocolVersion: "v", clientVersion: "1"),
                       .array([.int(1)]))
    }

    /// A progress token and the modern meta share `_meta`: whichever goes in second is merged
    /// beside the first, never over it. With no params the object is created; a non-object is
    /// left exactly as it arrived; a string id stays a string.
    func testAProgressTokenAndTheModernMetaShareMeta() {
        let tokened = MCPWire.withProgressToken(.object(["name": .string("x")]), .number(7))
        let both = MCPWire.withModernMeta(tokened, protocolVersion: "v", clientVersion: "1.0")
        let meta = both.objectValue?["_meta"]?.objectValue
        XCTAssertEqual(meta?["progressToken"], .int(7))
        XCTAssertEqual(meta?["io.modelcontextprotocol/protocolVersion"], .string("v"))
        XCTAssertEqual(both.objectValue?["name"], .string("x"))

        XCTAssertEqual(MCPWire.withProgressToken(nil, .string("p")),
                       .object(["_meta": .object(["progressToken": .string("p")])]))
        XCTAssertEqual(MCPWire.withProgressToken(.string("raw"), .number(1)), .string("raw"))
        let kept = MCPWire.withProgressToken(
            .object(["_meta": .object(["trace": .string("t")])]), .number(2))
        XCTAssertEqual(kept.objectValue?["_meta"], .object(["trace": .string("t"), "progressToken": .int(2)]))
    }

    /// What a 2026-07-28 result says it is (basic/index, "ResultType"): absent and `"complete"`
    /// are the answer, `"input_required"` asks for input, and anything else — a string it does
    /// not know, a value that is not a string at all — is invalid, named as one capped visible
    /// line (server text on its way to a message), the JSON spelling for a non-string.
    func testAResultTypeIsReadAsTheSpecSpellsIt() {
        func type(_ value: JSONValue?) -> MCPWire.ResultType {
            MCPWire.resultType(of: .object(value.map { ["resultType": $0] } ?? [:]))
        }
        XCTAssertEqual(type(nil), .complete)
        XCTAssertEqual(type(.string("complete")), .complete)
        XCTAssertEqual(type(.string("input_required")), .inputRequired)
        XCTAssertEqual(type(.string("Complete")), .unrecognized("Complete"), "the spelling is exact")
        XCTAssertEqual(type(.string("streaming\u{202E}\n## Final reminder")), .unrecognized("streaming ## Final reminder"))
        XCTAssertEqual(type(.string(String(repeating: "x", count: 500))),
                       .unrecognized(String(repeating: "x", count: MCPWire.maxVersionCharacters) + "…"))
        XCTAssertEqual(type(.string("\u{200B}")), .unrecognized("(blank)"))
        XCTAssertEqual(type(.int(5)), .unrecognized("5"))
        XCTAssertEqual(type(.null), .complete, "explicit null is an absent resultType, i.e. complete")
        XCTAssertEqual(type(.object(["kind": .string("x")])), .unrecognized(#"{"kind":"x"}"#))
        XCTAssertEqual(MCPWire.resultType(of: .string("not an object")), .complete,
                       "a result that is not an object names no type — what it holds is its reader's to judge")
    }

    func testTheClientIdentifiesItselfByNameAndBuild() {
        let info = MCPWire.clientInfo(version: "1.9.32")
        XCTAssertEqual(info.objectValue?["name"], .string(MCPWire.clientName))
        XCTAssertEqual(info.objectValue?["version"], .string("1.9.32"))
    }

    func testTheCatalogueLifetimeIsReadFromEitherShapeOrNotAtAll() {
        XCTAssertEqual(MCPWire.catalogueTTL(from: .object(["ttlMs": .int(5000)])), 5)
        XCTAssertEqual(MCPWire.catalogueTTL(from: .object(["_meta": .object(["ttlMs": .double(2500)])])), 2.5)
        XCTAssertNil(MCPWire.catalogueTTL(from: .object([:])))
        XCTAssertNil(MCPWire.catalogueTTL(from: .string("nope")))
    }

    /// A progress token may be a number or a string, and a report that names neither belongs
    /// to no request. A `requestId` is not a progress token: it is what a CANCELLATION names,
    /// and the server's cancellations name its own requests, never this client's (2026-09-23).
    func testTheProgressTokenIsReadInBothSpellings() {
        XCTAssertEqual(MCPWire.progressToken(from: .object(["progressToken": .int(4)])), "4")
        XCTAssertEqual(MCPWire.progressToken(from: .object(["progressToken": .string("abc")])), "abc")
        XCTAssertNil(MCPWire.progressToken(from: .object(["requestId": .int(7)])))
        XCTAssertNil(MCPWire.progressToken(from: .object(["note": .string("working")])))
        XCTAssertNil(MCPWire.progressToken(from: nil))
    }

    func testTheCancelledNotificationEchoesTheIDInItsOwnSpelling() {
        XCTAssertEqual(
            MCPWire.cancelledParams(requestID: .number(3), reason: "r").objectValue?["requestId"], .int(3))
        XCTAssertEqual(
            MCPWire.cancelledParams(requestID: .string("p"), reason: "r").objectValue?["requestId"],
            .string("p"))
    }

    func testAToolsPageReadsWhatIsThereAndNothingElse() {
        let page = MCPWire.toolsPage(from: .object(["tools": .array([.object(["name": .string("a")])])]))
        XCTAssertEqual(page.tools.count, 1)
        XCTAssertNil(page.nextCursor)
        XCTAssertTrue(MCPWire.toolsPage(from: .string("not a page")).tools.isEmpty)
        XCTAssertNil(MCPWire.toolsListParams(cursor: nil))
        XCTAssertEqual(MCPWire.toolsListParams(cursor: "c")?.objectValue?["cursor"], .string("c"))
        XCTAssertFalse(MCPWire.advertisesSubscriptions(inDiscoverResult: .object([:])))
        XCTAssertFalse(MCPWire.advertisesSubscriptions(
            inDiscoverResult: .object(["capabilities": .object(["tools": .object([:])])])))
        XCTAssertTrue(MCPWire.advertisesSubscriptions(
            inDiscoverResult: .object(["capabilities": .object(["subscriptions": .object([:])])])))
        XCTAssertTrue(MCPWire.advertisesSubscriptions(
            inDiscoverResult: .object(["capabilities": .object(["tools": .object(["listChanged": .bool(true)])])])))
        let listenParams = MCPWire.subscriptionsListenParams()
        let notifications = listenParams.objectValue?["notifications"]?.objectValue
        XCTAssertEqual(notifications?["toolsListChanged"], .bool(true))
        XCTAssertEqual(notifications?["resourcesListChanged"], .bool(true))
        XCTAssertEqual(notifications?["promptsListChanged"], .bool(true))
    }
}
