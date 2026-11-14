import XCTest

@testable import NanoTeams

/// What gets written down, and what must not. The patterns are narrow on purpose — a broad
/// "anything token-shaped" rule would mangle tool names and ids, and a log nobody can read is
/// a log nobody keeps.
final class MCPRedactionTests: XCTestCase {

    private let secret = "t.aBcD1234-eFgH5678_iJkL"

    // MARK: - Headers

    func testTheCredentialHeadersLoseTheirValuesAndKeepTheirNames() {
        let redacted = MCPRedaction.headers([
            "Authorization": "Bearer \(secret)",
            "Mcp-Session-Id": "3f9a",
            "Cookie": "sid=abc",
            "X-Api-Key": secret,
            "Content-Type": "application/json",
        ])
        XCTAssertEqual(redacted["Authorization"], MCPRedaction.placeholder)
        XCTAssertEqual(redacted["Mcp-Session-Id"], MCPRedaction.placeholder)
        XCTAssertEqual(redacted["Cookie"], MCPRedaction.placeholder)
        XCTAssertEqual(redacted["X-Api-Key"], MCPRedaction.placeholder)
        XCTAssertEqual(redacted["Content-Type"], "application/json", "the diagnostic value survives")
        XCTAssertEqual(Set(redacted.keys).count, 5, "every NAME is kept")
    }

    func testHeaderMatchingIgnoresCase() {
        XCTAssertEqual(MCPRedaction.headers(["authorization": "Bearer x"])["authorization"],
                       MCPRedaction.placeholder)
    }

    /// A header the user invented for their own credential is named in the config, so the
    /// caller passes it in rather than hoping the static list covers it.
    func testACallerCanNameItsOwnSecretHeaders() {
        let redacted = MCPRedaction.headers(["X-Tenant-Secret": secret],
                                            additionalSensitiveNames: ["x-tenant-secret"])
        XCTAssertEqual(redacted["X-Tenant-Secret"], MCPRedaction.placeholder)
    }

    /// A value that is not on the list still goes through the text scrubber — a server can
    /// echo a credential into any header it likes.
    func testAnUnlistedHeaderValueIsStillScrubbed() {
        let redacted = MCPRedaction.headers(["X-Echo": "Bearer \(secret)"])
        XCTAssertFalse(redacted["X-Echo"]?.contains(secret) ?? true)
    }

    // MARK: - Text

    func testScrubsCredentialSchemesWhereverTheyAppear() {
        for input in ["Authorization: Bearer \(secret)", "tried Bearer \(secret) and failed",
                      "Basic \(secret)", "token \(secret)"] {
            XCTAssertFalse(MCPRedaction.text(input).contains(secret), input)
            XCTAssertTrue(MCPRedaction.text(input).contains(MCPRedaction.placeholder), input)
        }
    }

    func testScrubsTheParameterSpellingsOfTheSameValue() {
        for input in ["access_token=\(secret)", "api_key: \(secret)", "\"apiKey\": \"\(secret)\"",
                      "refresh_token=\(secret)", "mcp-session-id=\(secret)"] {
            XCTAssertFalse(MCPRedaction.text(input).contains(secret), input)
        }
    }

    func testScrubsUserInfoOutOfAURLInProse() {
        let scrubbed = MCPRedaction.text("redirected to https://user:hunter2@evil.test/mcp")
        XCTAssertFalse(scrubbed.contains("hunter2"))
        XCTAssertTrue(scrubbed.contains("evil.test"))
    }

    /// The narrowness is the point: a log that mangled tool names and ids would stop being
    /// worth keeping.
    func testLeavesOrdinaryDiagnosticTextAlone() {
        for input in ["tools/list returned 12 tools", "get_design_context failed with -32602",
                      "request id 4711", "Получить портфель"] {
            XCTAssertEqual(MCPRedaction.text(input), input, input)
        }
    }

    // MARK: - Agent tokens only (full bodies, 2026-11-08)

    /// An issued token: `ntm_` + 8 lower-case hex + `_` + 43 base64url (`HostedMCPAgentStore`).
    private let agentToken = "ntm_0a1b2c3d_" + String(repeating: "Ab9-_", count: 8) + "xyz"

    /// The token goes wherever it stands — mid-sentence, after a JSON escape, after `Bearer`.
    func testAgentTokensTakesOutTheIssuedTokenWhereverItStands() {
        for input in ["token is \(agentToken).", #"{"text":"line\n\#(agentToken)"}"#,
                      "Authorization: Bearer \(agentToken)", agentToken] {
            let scrubbed = MCPRedaction.agentTokens(input)
            XCTAssertFalse(scrubbed.contains(agentToken), input)
            XCTAssertFalse(scrubbed.contains("Ab9-_Ab9-_"), input)
            XCTAssertTrue(scrubbed.contains(MCPRedaction.placeholder), input)
        }
    }

    /// And nothing else: the generic scrub reads `basic implementation` as a credential, which a
    /// full body kept for a person to read cannot afford.
    func testAgentTokensLeavesEverythingElseWhole() {
        for input in ["a basic implementation of token streaming", "Bearer \(secret)",
                      "api_key: \(secret)", "ntm_ is the prefix", "ntm_abcd_short", "",
                      "Получить портфель 🧮\u{2028}"] {
            XCTAssertEqual(MCPRedaction.agentTokens(input), input, input)
        }
        XCTAssertNotEqual(MCPRedaction.text("a basic implementation"), "a basic implementation",
                          "the reason agentTokens exists: text cuts this prose")
    }

    /// One spelling of the token, at the issuer; `text` still takes it out exactly as before.
    func testTextStillScrubsTheAgentTokenThroughTheSharedPattern() {
        XCTAssertEqual(MCPRedaction.text("x \(agentToken) y"), "x \(MCPRedaction.placeholder) y")
        XCTAssertTrue(HostedMCPConstants.agentTokenPattern.hasPrefix(HostedMCPConstants.tokenPrefix))
    }

    // MARK: - URLs

    func testAURLIsWrittenDownWithoutItsCredentialsOrQuery() throws {
        let url = try XCTUnwrap(URL(string: "https://user:pass@example.com:8443/mcp?token=\(secret)#frag"))
        let written = MCPRedaction.url(url)
        XCTAssertFalse(written.contains("pass"))
        XCTAssertFalse(written.contains(secret))
        XCTAssertFalse(written.contains("frag"))
        XCTAssertTrue(written.contains("example.com:8443/mcp"))
    }

    /// The query goes wholesale rather than being filtered, because a server is free to name
    /// its token parameter anything.
    func testTheWholeQueryGoesNotJustTheKnownNames() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/mcp?wibble=\(secret)"))
        XCTAssertFalse(MCPRedaction.url(url).contains(secret))
    }

    // MARK: - Excerpts

    func testAnExcerptIsScrubbedBeforeItIsCut() {
        let body = String(repeating: "x", count: 40) + " Bearer \(secret) " + String(repeating: "y", count: 2000)
        let excerpt = MCPRedaction.excerpt(body)
        XCTAssertFalse(excerpt.contains(secret))
        XCTAssertLessThanOrEqual(excerpt.count, 501)
        XCTAssertTrue(excerpt.hasSuffix("…"))
    }

    func testAShortBodyIsNotCutAtAll() {
        XCTAssertEqual(MCPRedaction.excerpt("  server is starting up  "), "server is starting up")
        XCTAssertEqual(MCPRedaction.excerpt(""), "")
    }

    // MARK: - One server's own credentials (F11)

    private let key = "wk_live_8f3a9c2d"

    /// The value the authorizer SENT is scrubbed wherever it appears — no pattern needs to
    /// recognise its shape, because the redaction knows the value itself.
    func testCredentialsRedactEveryLiteralValue() {
        let credentials = MCPRedaction.Credentials(values: [key])
        for input in ["rejected \(key)", "\(key)", "a\(key)b and \(key) again", "path/\(key).json"] {
            let scrubbed = credentials.text(input)
            XCTAssertFalse(scrubbed.contains(key), input)
            XCTAssertTrue(scrubbed.contains(MCPRedaction.placeholder), input)
        }
        XCTAssertEqual(credentials.text("a\(key)b"), "a\(MCPRedaction.placeholder)b")
    }

    /// The same value inside a JSON document — which is how the frame log writes a payload —
    /// is spelled with its quotes and backslashes escaped, and is scrubbed in that spelling too.
    func testALiteralValueIsScrubbedInItsJSONSpellingToo() {
        let quoted = #"se"cret\8f3a"#
        let credentials = MCPRedaction.Credentials(values: [quoted])
        let document = JSONValue.object(["echo": .string("got \(quoted)")]).canonicalJSONString()
        XCTAssertFalse(credentials.text(document).contains(#"se\"cret\\8f3a"#), credentials.text(document))
        XCTAssertFalse(credentials.text("got \(quoted)").contains(quoted))
    }

    /// The value after a secret header's NAME goes whatever it is, in the spellings a server
    /// actually writes: a header line, a form field, a JSON member — and in any case.
    func testCredentialsRedactTheValueOfEveryNamedHeader() {
        let credentials = MCPRedaction.Credentials(headerNames: ["X-Workspace-Key"])
        for input in ["Invalid X-Workspace-Key: abc-123-zzz", "x-workspace-key=abc-123-zzz",
                      #"{"X-WORKSPACE-KEY": "abc-123-zzz"}"#, "X-Workspace-Key:abc-123-zzz;next"] {
            let scrubbed = credentials.text(input)
            XCTAssertFalse(scrubbed.contains("abc-123-zzz"), "\(input) → \(scrubbed)")
            XCTAssertTrue(scrubbed.lowercased().contains("x-workspace-key"), "the NAME stays: \(scrubbed)")
        }
        // The name alone, or as part of a longer word, is not a credential.
        XCTAssertEqual(credentials.text("X-Workspace-Key header missing"), "X-Workspace-Key header missing")
        XCTAssertEqual(credentials.text("My-X-Workspace-Keyring: 1"), "My-X-Workspace-Keyring: 1")
    }

    /// A header name is escaped before it becomes a pattern: a name with regex metacharacters
    /// matches itself and nothing wider.
    func testAHeaderNameIsMatchedLiterally() {
        let credentials = MCPRedaction.Credentials(headerNames: ["X.Key+"])
        XCTAssertFalse(credentials.text("X.Key+: s3cret-value").contains("s3cret-value"))
        XCTAssertEqual(credentials.text("XaKeyy: s3cret-value"), "XaKeyy: s3cret-value")
    }

    /// A value shorter than four bytes is not a credential worth the name, and scrubbing it
    /// literally would cut it out of every word it happens to spell. An empty header name
    /// names nothing.
    func testAShortValueIsNotScrubbedAsALiteral() {
        let credentials = MCPRedaction.Credentials(headerNames: [""], values: ["abc", ""])
        XCTAssertEqual(credentials.text("abcdef abc: value-1234"), "abcdef abc: value-1234")
        XCTAssertEqual(MCPRedaction.Credentials(values: ["abcd"]).text("xabcdx"), "x\(MCPRedaction.placeholder)x")
        XCTAssertEqual(MCPRedaction.Credentials.minimumLiteralBytes, 4)
    }

    /// A longer secret that contains a shorter one is replaced whole, not with a tail left over.
    func testALongerValueIsReplacedBeforeAShorterOneInsideIt() {
        let credentials = MCPRedaction.Credentials(values: ["abcd", "abcdefgh"])
        XCTAssertEqual(credentials.text("[abcdefgh]"), "[\(MCPRedaction.placeholder)]")
    }

    // MARK: - Literals alone, for a tool's DATA

    /// The literal half and nothing else: the header-name patterns and the credential shapes
    /// stay off a tool's answer, which may legitimately be a list of keys.
    func testLiteralsReplaceOnlyTheServersOwnValues() {
        let literals = MCPRedaction.Credentials(headerNames: ["X-Workspace-Key"], values: [key]).literals
        XCTAssertEqual(literals.scrub("X-Workspace-Key: other-9f8e7d"), "X-Workspace-Key: other-9f8e7d")
        XCTAssertEqual(literals.scrub("Bearer \(secret)"), "Bearer \(secret)")
        XCTAssertEqual(literals.scrub("sent \(key)"), "sent \(MCPRedaction.placeholder)")
    }

    /// The same spellings `text` uses — JSON spelling, longest first — over a HIGHER floor.
    func testLiteralsShareTheJSONSpellingAndTheOrderOverTheirOwnFloor() {
        let quoted = #"se"cret\8f3a"#
        let literals = MCPRedaction.Credentials(values: ["abc", "abcd", "abcdefgh", quoted]).literals
        XCTAssertEqual(literals.scrub("abc abcd [abcdefgh]"), "abc abcd [\(MCPRedaction.placeholder)]")
        XCTAssertEqual(literals.scrub(#"se\"cret\\8f3a"#), MCPRedaction.placeholder)
        XCTAssertTrue(MCPRedaction.Credentials(values: ["abc", "abcdefg", ""]).literals.isEmpty)
        XCTAssertTrue(MCPRedaction.Credentials.none.literals.isEmpty)
    }

    /// Two floors, because the two scrubs cut different things. An error message is about the
    /// call and a cut costs a word of it; a RESULT is the answer, and a user who marks
    /// `X-Env: prod` secret would otherwise read `<redacted>uction` in every file the tool
    /// returns. Under eight bytes a value is not a credential worth corrupting data for.
    func testAResultKeepsAValueTheErrorTextStillScrubs() {
        XCTAssertEqual(MCPRedaction.Credentials.minimumLiteralBytes, 4)
        XCTAssertEqual(MCPRedaction.Credentials.Literals.minimumBytes, 8)
        let five = MCPRedaction.Credentials(values: ["prodx"])
        XCTAssertEqual(five.text("bad env prodx"), "bad env \(MCPRedaction.placeholder)")
        XCTAssertEqual(five.literals.scrub("prodx production"), "prodx production")
        let eight = MCPRedaction.Credentials(values: ["prod-key"])
        XCTAssertEqual(eight.text("bad prod-key"), "bad \(MCPRedaction.placeholder)")
        XCTAssertEqual(eight.literals.scrub("got prod-key"), "got \(MCPRedaction.placeholder)")
    }

    // MARK: - The spellings a value takes on its way back

    private static let slashy = "wk/live+8f3a9c2d=="

    /// A base64 or JWT-style secret carries `/`, which a JSON encoder is free to write `\/`
    /// (JSONSerialization does), and a form or query echo percent-encodes. Both spellings go,
    /// in error text and in data alike.
    func testTheSlashEscapedAndPercentEncodedSpellingsAreScrubbed() {
        let credentials = MCPRedaction.Credentials(values: [Self.slashy])
        let placeholder = MCPRedaction.placeholder
        let escaped = #"{"key":"wk\/live+8f3a9c2d=="}"#
        let percent = "key=wk%2Flive%2B8f3a9c2d%3D%3D&x=1"
        XCTAssertEqual(credentials.text(escaped), #"{"key":"\#(placeholder)"}"#)
        XCTAssertEqual(credentials.literals.scrub(escaped), #"{"key":"\#(placeholder)"}"#)
        XCTAssertEqual(credentials.literals.scrub(percent), "key=\(placeholder)&x=1")
        XCTAssertFalse(credentials.text(percent).contains("8f3a9c2d"), credentials.text(percent))
        XCTAssertEqual(credentials.literals.scrub("raw \(Self.slashy)"), "raw \(placeholder)")
    }

    /// A value whose percent-encoding is itself adds nothing, and one without a `/` has no
    /// slash-escaped spelling: an unreserved value is scrubbed exactly as before.
    func testAnUnreservedValueHasOneSpelling() {
        let literals = MCPRedaction.Credentials(values: ["wk_live-8f3a.9c~2d"]).literals
        XCTAssertEqual(literals.spellings, ["wk_live-8f3a.9c~2d"])
    }

    /// Every string and key of a document; numbers, booleans and null untouched; keys that
    /// fold together keep every value.
    func testLiteralsWalkADocument() {
        let literals = MCPRedaction.Credentials(values: [key]).literals
        let placeholder = MCPRedaction.placeholder
        let scrubbed = literals.scrub(JSONValue.object([
            "a": .array([.string(key), .int(1), .bool(true), .null, .double(1.5)]),
            key: .object(["\(key)!": .string("x")]),
            "k-\(key)": .string("y"),
            "\(key)-k": .string("z"),
        ]))
        XCTAssertEqual(scrubbed, .object([
            "a": .array([.string(placeholder), .int(1), .bool(true), .null, .double(1.5)]),
            placeholder: .object(["\(placeholder)!": .string("x")]),
            "k-\(placeholder)": .string("y"),
            "\(placeholder)-k": .string("z"),
        ]))
    }

    /// No credentials is exactly the generic scrub — the redaction only ever adds.
    func testNoCredentialsIsTheGenericScrub() {
        let input = "Bearer \(secret) and \(key)"
        XCTAssertEqual(MCPRedaction.Credentials.none.text(input), MCPRedaction.text(input))
        XCTAssertEqual(MCPRedaction.Credentials.none.excerpt("  x  "), MCPRedaction.excerpt("  x  "))
    }

    /// The excerpt scrubs BEFORE it cuts, so a secret straddling the cap cannot leave its first
    /// half behind.
    func testTheExcerptScrubsBeforeItCuts() {
        let credentials = MCPRedaction.Credentials(values: ["SECRET-straddle"])
        let excerpt = credentials.excerpt(String(repeating: "x", count: 8) + "SECRET-straddle", limit: 12)
        XCTAssertEqual(excerpt, String(repeating: "x", count: 8) + String(MCPRedaction.placeholder.prefix(4)) + "…")
    }
}
