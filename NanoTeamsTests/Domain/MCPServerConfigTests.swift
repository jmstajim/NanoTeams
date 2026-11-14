import XCTest

@testable import NanoTeams

/// The configuration a user types and the app stores. Three properties are load-bearing and
/// each is pinned here: a slug can never be a path, a secret can never be a stored value, and
/// a stored timeout can never disable a guard.
final class MCPServerConfigTests: XCTestCase {

    // MARK: - Slug

    func testAcceptsAWellFormedSlug() throws {
        let slug = try XCTUnwrap(MCPServerSlug("trade_room"))
        XCTAssertEqual(slug.rawValue, "trade_room")
        XCTAssertEqual(slug.description, "trade_room")
    }

    /// The slug is a path component (`internal/mcp/<slug>/rpc_log.jsonl`). Everything that
    /// could walk out of that directory has to be unconstructible, not merely unusual.
    func testRefusesAnythingThatCouldEscapeADirectory() {
        for hostile in ["..", "../../etc", "a/b", "a\\b", ".", "", " ", "Folio", "fol-io", "trade__room"] {
            XCTAssertNil(MCPServerSlug(hostile), hostile)
        }
    }

    func testSlugRoundTripsThroughJSON() throws {
        let slug = try XCTUnwrap(MCPServerSlug("folio"))
        let data = try JSONEncoder().encode(slug)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"folio\"")
        XCTAssertEqual(try JSONDecoder().decode(MCPServerSlug.self, from: data), slug)
    }

    /// Healing a bad slug would silently re-namespace every tool already approved under the
    /// old one, and the pins are keyed by the old name — so the row is refused instead.
    func testDecodingRefusesAnInvalidSlugRatherThanHealingIt() {
        let data = Data("\"../secrets\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MCPServerSlug.self, from: data))
    }

    func testSlugsSortByTheirText() throws {
        let a = try XCTUnwrap(MCPServerSlug("a"))
        let b = try XCTUnwrap(MCPServerSlug("b"))
        XCTAssertTrue(a < b)
        XCTAssertEqual([b, a].sorted(), [a, b])
    }

    // MARK: - Approval mode

    /// Where a standing grant may be offered and written is ONE rule: only a mode that does not
    /// hold every call for a person allows one. The gate's button, the server page's switch and
    /// the write read it.
    func testOnlyAModeThatDoesNotHoldEveryCallAllowsAStandingGrant() {
        XCTAssertFalse(MCPApprovalMode.manual.allowsStandingGrants)
        XCTAssertTrue(MCPApprovalMode.semiAutomatic.allowsStandingGrants)
        XCTAssertTrue(MCPApprovalMode.auto.allowsStandingGrants)
        XCTAssertEqual(MCPApprovalMode.allCases.count, 3, "a fourth mode must be classified, not defaulted")
    }

    func testEveryModeAndAuthorizationNamesItself() {
        for mode in MCPApprovalMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.settingDescription.isEmpty, mode.rawValue)
        }
        for strictness in MCPJudgeStrictness.allCases {
            XCTAssertFalse(strictness.displayName.isEmpty, strictness.rawValue)
            XCTAssertFalse(strictness.settingDescription.isEmpty, strictness.rawValue)
            XCTAssertFalse(strictness.judgeGuidance.isEmpty, strictness.rawValue)
        }
        for mode in MCPAuthorizationMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, mode.rawValue)
        }
    }

    /// The default is the strict one. A server added and enabled without anybody touching the
    /// picker must not start clearing its own calls.
    func testANewlyAddedServerIsOffUntrustedAndManual() throws {
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("s")),
            displayName: "S",
            transport: .http(MCPHTTPConfig(urlString: "https://example.com/mcp")))
        XCTAssertFalse(config.isEnabled)
        XCTAssertFalse(config.isTrusted)
        XCTAssertEqual(config.approvalMode, .manual)
        XCTAssertEqual(config.judgeStrictness, .standard)
    }

    // MARK: - Timeouts

    func testTimeoutsAreClampedIntoTheirRanges() {
        let tiny = MCPTimeouts(connect: 0, requestInactivity: 0, requestAbsolute: 0)
        XCTAssertEqual(tiny.connect, MCPTimeouts.connectRange.lowerBound)
        XCTAssertEqual(tiny.requestInactivity, MCPTimeouts.inactivityRange.lowerBound)

        let huge = MCPTimeouts(connect: 99_999, requestInactivity: 99_999, requestAbsolute: 99_999)
        XCTAssertEqual(huge.connect, MCPTimeouts.connectRange.upperBound)
        XCTAssertEqual(huge.requestInactivity, MCPTimeouts.inactivityRange.upperBound)
        XCTAssertEqual(huge.requestAbsolute, MCPTimeouts.absoluteRange.upperBound)
    }

    /// An absolute ceiling below the inactivity budget would fire first and make every
    /// progress notification meaningless.
    func testTheAbsoluteCeilingNeverSitsBelowTheInactivityBudget() {
        let inverted = MCPTimeouts(connect: 10, requestInactivity: 600, requestAbsolute: 30)
        XCTAssertGreaterThanOrEqual(inverted.requestAbsolute, inverted.requestInactivity)
    }

    /// The budgets the app runs on are the named constants, on every path that builds them
    /// without a stored value: `.standard`, a new server's default and a server stored with no
    /// timeouts. The tests that run the budgets fast inject their own (`init(unclampedConnect:…)`,
    /// a `ManualMCPClock`), so this is where the constants themselves are held.
    ///
    /// RED: give `.standard`, or the config's default, any other value → the matching line here.
    func testTheAppsTimeoutsAreTheNamedConstants() throws {
        XCTAssertEqual(MCPTimeouts.standard.connect, MCPConstants.connectTimeout)
        XCTAssertEqual(MCPTimeouts.standard.requestInactivity, MCPConstants.requestInactivityTimeout)
        XCTAssertEqual(MCPTimeouts.standard.requestAbsolute, MCPConstants.requestAbsoluteTimeout)
        let added = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("s")), displayName: "S",
            transport: .http(MCPHTTPConfig(urlString: "https://example.com/mcp")))
        XCTAssertEqual(added.timeouts, .standard, "a new server's default")
    }

    /// The test-only initializer keeps what it is given — below every floor — while the public
    /// one, the only one a stored value reaches, still clamps the same numbers.
    func testOnlyTheTestInitializerTakesBudgetsBelowTheFloors() {
        let unclamped = MCPTimeouts(unclampedConnect: 0.1, requestInactivity: 0.5, requestAbsolute: 1)
        XCTAssertEqual(unclamped.connect, 0.1)
        XCTAssertEqual(unclamped.requestInactivity, 0.5)
        XCTAssertEqual(unclamped.requestAbsolute, 1)
        let clamped = MCPTimeouts(connect: 0.1, requestInactivity: 0.5, requestAbsolute: 1)
        XCTAssertEqual(clamped.connect, MCPTimeouts.connectRange.lowerBound)
        XCTAssertEqual(clamped.requestInactivity, MCPTimeouts.inactivityRange.lowerBound)
        XCTAssertEqual(clamped.requestAbsolute, MCPTimeouts.absoluteRange.lowerBound)
    }

    func testTimeoutsDecodeFieldByFieldWithConstantDefaults() throws {
        let decoded = try JSONDecoder().decode(MCPTimeouts.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, MCPTimeouts.standard)
        let partial = try JSONDecoder().decode(MCPTimeouts.self, from: Data(#"{"connect": 7}"#.utf8))
        XCTAssertEqual(partial.connect, 7)
        XCTAssertEqual(partial.requestInactivity, MCPConstants.requestInactivityTimeout)
    }

    // MARK: - HTTP config

    /// A header the transport owns would either be overwritten silently or would put a
    /// credential into a plaintext JSON file.
    func testReservedHeadersAreStrippedOnTheWayIn() {
        let config = MCPHTTPConfig(
            urlString: "https://example.com/mcp",
            headers: ["Authorization": "Bearer leaked", "Accept": "text/plain", "X-Tenant": "acme"])
        XCTAssertNil(config.headers["Authorization"])
        XCTAssertNil(config.headers["Accept"])
        XCTAssertEqual(config.headers["X-Tenant"], "acme")
    }

    func testReservedHeaderMatchingIgnoresCase() {
        let config = MCPHTTPConfig(urlString: "https://x/mcp", headers: ["authorization": "Bearer leaked"])
        XCTAssertTrue(config.headers.isEmpty)
    }

    /// The two lists must be disjoint, or the same header name would mean both "here is the
    /// value" and "look the value up".
    func testAHeaderNamedAsSecretCannotAlsoCarryAStoredValue() {
        let config = MCPHTTPConfig(
            urlString: "https://x/mcp",
            headers: ["X-Api-Key": "plaintext"],
            secretHeaderNames: ["X-Api-Key"])
        XCTAssertTrue(config.headers.isEmpty)
        XCTAssertEqual(config.secretHeaderNames, ["X-Api-Key"])
    }

    /// Two configs differing only in the order the user typed the names are the same config;
    /// otherwise a save would look like an edit and the connection would be torn down.
    func testSecretHeaderNamesAreNormalisedAndOrderInsensitive() {
        let a = MCPHTTPConfig(urlString: "https://x/mcp", secretHeaderNames: ["B", "a", " a ", ""])
        let b = MCPHTTPConfig(urlString: "https://x/mcp", secretHeaderNames: ["a", "B"])
        XCTAssertEqual(a.secretHeaderNames, ["B", "a"])
        XCTAssertEqual(a, b)
    }

    func testURLIsParsedFromTheStoredText() {
        XCTAssertEqual(MCPHTTPConfig(urlString: "  https://x/mcp  ").url?.absoluteString, "https://x/mcp")
    }

    // MARK: - Transport

    func testTransportRoundTripsAndRefusesAnythingButHTTP() throws {
        let transport = MCPTransportConfig.http(MCPHTTPConfig(urlString: "https://x/mcp"))
        let data = try JSONEncoder().encode(transport)
        XCTAssertEqual(try JSONDecoder().decode(MCPTransportConfig.self, from: data), transport)
        XCTAssertEqual(transport.http.urlString, "https://x/mcp")

        // A future file naming a transport this build does not implement decodes tolerantly and
        // round-trips its raw payload rather than quarantining the whole servers.json, while its
        // HTTP projection is empty so it is never connected as HTTP.
        let stdio = Data(#"{"kind":"stdio","command":"npx","args":["-y","srv"]}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPTransportConfig.self, from: stdio)
        XCTAssertEqual(decoded.http.urlString, "")
        let reencoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(try JSONDecoder().decode(MCPTransportConfig.self, from: reencoded), decoded)

        let unknownAuth = Data(#"{"urlString":"https://x/mcp","authorization":"oauth"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MCPHTTPConfig.self, from: unknownAuth).authorization, .none)
    }

    /// A file written before a field existed still has to open.
    func testServerConfigDecodesTolerantlyButNeedsAnIDAndASlug() throws {
        let minimal = Data(#"""
        {"id":"7F1B9C1E-0000-0000-0000-000000000001","slug":"folio",
         "transport":{"kind":"http","http":{"urlString":"http://127.0.0.1:3845/mcp"}}}
        """#.utf8)
        let config = try JSONDecoder().decode(MCPServerConfig.self, from: minimal)
        XCTAssertEqual(config.slug.rawValue, "folio")
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.approvalMode, .manual)
        XCTAssertEqual(config.timeouts, .standard)
        XCTAssertEqual(config.effectiveDisplayName, "folio", "a blank name reads as a rendering bug")

        let noSlug = Data(#"{"id":"7F1B9C1E-0000-0000-0000-000000000001"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MCPServerConfig.self, from: noSlug))
    }

    func testServerConfigRoundTrips() throws {
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            displayName: "Trade-Room",
            transport: .http(MCPHTTPConfig(urlString: "https://x/mcp", authorization: .staticBearer)),
            isEnabled: true,
            isTrusted: true,
            approvalMode: .semiAutomatic)
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(MCPServerConfig.self, from: data), config)
    }

    // MARK: - What a connection is built from

    private func baseline() throws -> MCPServerConfig {
        MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            displayName: "Trade-Room",
            transport: .http(MCPHTTPConfig(urlString: "https://x/mcp")),
            isEnabled: true, isTrusted: false, approvalMode: .manual, timeouts: .standard)
    }

    /// The fields a live session is built from — changing any of them is a new connection.
    private static let termFields: Set<String> = ["slug", "transport", "timeouts"]
    /// The fields read per call — a kept connection takes them in place.
    private static let policyFields: Set<String> = [
        "displayName", "isEnabled", "isTrusted", "approvalMode", "judgeStrictness",
    ]
    /// The row's identity: never edited, and what `adopt(_:)` refuses another of.
    private static let identityFields: Set<String> = ["id"]

    /// A field added to `MCPServerConfig` must be filed as a connection term or as policy. Left
    /// unfiled it would be policy by default, and a new transport-shaped field (a proxy, a
    /// client certificate) would then be edited under a live session built without it.
    func testEveryFieldIsFiledAsATermOrAsPolicy() throws {
        let labels = Set(Mirror(reflecting: try baseline()).children.compactMap(\.label))
        XCTAssertEqual(
            labels, Self.termFields.union(Self.policyFields).union(Self.identityFields),
            "file the new field: a connection term (`MCPServerConfig.ConnectionTerms`) or policy")
        XCTAssertTrue(Self.termFields.isDisjoint(with: Self.policyFields))
        XCTAssertEqual(
            Set(Mirror(reflecting: try baseline().connectionTerms).children.compactMap(\.label)),
            Self.termFields, "the terms type carries exactly the term fields")
    }

    /// Each policy field, changed alone, leaves the terms equal.
    func testAPolicyEditLeavesTheConnectionTermsAlone() throws {
        let base = try baseline()
        var edits: [(String, MCPServerConfig)] = []
        var mode = base; mode.approvalMode = .semiAutomatic; edits.append(("approvalMode", mode))
        var strictness = base; strictness.judgeStrictness = .strict; edits.append(("judgeStrictness", strictness))
        var trusted = base; trusted.isTrusted = true; edits.append(("isTrusted", trusted))
        var named = base; named.displayName = "Trade Room (live)"; edits.append(("displayName", named))
        var off = base; off.isEnabled = false; edits.append(("isEnabled", off))
        XCTAssertEqual(Set(edits.map(\.0)), Self.policyFields, "every policy field is exercised")
        for (field, edited) in edits {
            XCTAssertNotEqual(edited, base, field)
            XCTAssertEqual(edited.connectionTerms, base.connectionTerms, field)
        }
    }

    /// Each term, changed alone, moves the terms.
    func testATransportEditMovesTheConnectionTerms() throws {
        let base = try baseline()
        var edits: [(String, MCPServerConfig)] = []
        var slug = base; slug.slug = try XCTUnwrap(MCPServerSlug("trading")); edits.append(("slug", slug))
        var url = base; url.transport = .http(MCPHTTPConfig(urlString: "https://y/mcp")); edits.append(("transport", url))
        var timeouts = base
        timeouts.timeouts = MCPTimeouts(connect: 5, requestInactivity: 50, requestAbsolute: 500)
        edits.append(("timeouts", timeouts))
        XCTAssertEqual(Set(edits.map(\.0)), Self.termFields, "every term is exercised")
        for (field, edited) in edits {
            XCTAssertNotEqual(edited.connectionTerms, base.connectionTerms, field)
        }
        // The credential SHAPE is part of the transport: a bearer the transport was not built
        // with cannot be added under a live session.
        var bearer = base
        bearer.transport = .http(MCPHTTPConfig(urlString: "https://x/mcp", authorization: .staticBearer))
        XCTAssertNotEqual(bearer.connectionTerms, base.connectionTerms)
        var header = base
        header.transport = .http(MCPHTTPConfig(urlString: "https://x/mcp", headers: ["X-Team": "a"]))
        XCTAssertNotEqual(header.connectionTerms, base.connectionTerms)
    }

    // MARK: - Secret keys

    /// Keyed by the server's UUID and the ORIGIN the secret was entered for — never by the slug:
    /// renaming the server keeps the secret, and so does a new path on the same origin.
    ///
    /// The spelling itself, written out: this is the one test that states it, so everything else
    /// reads it through the config.
    func testSecretKeysAreScopedToTheServerIdentityAndItsOrigin() throws {
        let id = UUID()
        var config = MCPServerConfig(
            id: id,
            slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            displayName: "Trade-Room",
            transport: .http(MCPHTTPConfig(
                urlString: "https://x/mcp", secretHeaderNames: ["X-Api-Key"], authorization: .staticBearer)))
        XCTAssertEqual(config.originAccountPrefix, "\(id.uuidString)/https:x:443/")
        XCTAssertEqual(config.bearerSecretKey, "\(id.uuidString)/https:x:443/bearer")
        XCTAssertEqual(config.secretKey(forHeader: "X-Api-Key"), "\(id.uuidString)/https:x:443/header/X-Api-Key")
        XCTAssertEqual(config.allSecretKeys,
                       ["\(id.uuidString)/https:x:443/bearer", "\(id.uuidString)/https:x:443/header/X-Api-Key"].sorted())

        config.slug = try XCTUnwrap(MCPServerSlug("traderoom"))
        XCTAssertEqual(config.bearerSecretKey, "\(id.uuidString)/https:x:443/bearer", "a rename must not strand the secret")
        config.transport = .http(MCPHTTPConfig(
            urlString: "HTTPS://X:443/v2/mcp", secretHeaderNames: ["X-Api-Key"], authorization: .staticBearer))
        XCTAssertEqual(config.bearerSecretKey, "\(id.uuidString)/https:x:443/bearer", "a new path is the same server")
    }

    /// A secret is bound to the address it was entered for BY ITS ACCOUNT NAME: an edit that
    /// points the server at another scheme, host or port gives every account a new name, and
    /// one that does not changes none. So a connection — which reads only the accounts its own
    /// config names — never reads a value typed for another address, whatever order a save, a
    /// failure and a reload happen in.
    ///
    /// RED until the third pass of group D's review (2026-09-24): both addresses read
    /// `<uuid>/bearer`, and only the ORDER of a save's steps kept the new host's token off the
    /// old one.
    func testARepointRenamesEveryAccountAndNothingElseRenamesAny() throws {
        let id = UUID()
        let addresses = ["https://a.test/mcp", "https://A.test:443/v2", "http://a.test/mcp", "https://a.test:8443/mcp",
                         "https://b.test/mcp", "http://[::1]:3845/mcp", "http://[::1]:3846/mcp", "not a url"]
        func config(_ url: String) throws -> MCPServerConfig {
            MCPServerConfig(
                id: id, slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "Folio",
                transport: .http(MCPHTTPConfig(
                    urlString: url, secretHeaderNames: ["X-A", "X-B"], authorization: .staticBearer)))
        }
        for first in addresses {
            for second in addresses {
                let stored = try config(first), saved = try config(second)
                let before = Set(stored.allSecretKeys), after = Set(saved.allSecretKeys)
                if saved.isRepointed(from: stored) {
                    XCTAssertTrue(before.isDisjoint(with: after), "\(first) → \(second): an account survived a re-point")
                } else {
                    XCTAssertEqual(before, after, "\(first) → \(second): an account moved without a re-point")
                }
                XCTAssertEqual(stored.secretAccountPrefix, saved.secretAccountPrefix, "one purge prefix per server")
            }
        }
    }

    /// The server an account belongs to, read back from its name: a server id exactly as the
    /// config spells it, then `/`. Anything else is not a server's account — an LM Studio-shaped
    /// base URL, a lowercase or partial id, an id with no `/` after it, a lookalike — and the
    /// orphaned-secret sweep never touches it.
    func testAnAccountNamesItsServerOnlyWhenSpelledUnderAServerID() throws {
        let id = UUID()
        let config = MCPServerConfig(
            id: id, slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "Folio",
            transport: .http(MCPHTTPConfig(urlString: "https://x/mcp", secretHeaderNames: ["X-A"])))
        XCTAssertEqual(MCPServerConfig.serverID(ofAccount: config.secretKey(forHeader: "X-A")), id)
        XCTAssertEqual(MCPServerConfig.serverID(ofAccount: config.bearerSecretKey), id)
        XCTAssertEqual(MCPServerConfig.serverID(ofAccount: "\(id.uuidString)/bearer"), id, "an older spelling is still this server's")
        for other in ["http://localhost:1234", "http://127.0.0.1:1234/v1", "https://\(id.uuidString)/bearer",
                      "\(id.uuidString.lowercased())/bearer", "\(id.uuidString)", "\(id.uuidString)-copy/bearer",
                      String(id.uuidString.dropLast()) + "/bearer", "/\(id.uuidString)/bearer", "", "/"] {
            XCTAssertNil(MCPServerConfig.serverID(ofAccount: other), other)
        }
    }

    /// A server with no authorization reads no secret, so nothing asks the Keychain about it —
    /// a bearer saved while it used one is never sent, and goes with the rest of its prefix when
    /// the server is removed or re-pointed.
    func testAServerWithoutAuthorizationReadsNoSecret() throws {
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")),
            displayName: "Folio",
            transport: .http(MCPHTTPConfig(urlString: "http://127.0.0.1:3845/mcp")))
        XCTAssertTrue(config.allSecretKeys.isEmpty)
        XCTAssertTrue(config.hasRequiredSecrets(among: []))
    }

    /// Every account a server can hold — the headers', the bearer's in every mode — lies under
    /// its prefix, and the prefix is the id and a `/`: one listing finds them all, and no other
    /// server's.
    func testEveryAccountAServerNamesLiesUnderItsPrefix() throws {
        let id = UUID()
        for authorization in MCPAuthorizationMode.allCases {
            let config = MCPServerConfig(
                id: id, slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "Folio",
                transport: .http(MCPHTTPConfig(
                    urlString: "https://x/mcp", secretHeaderNames: ["X-A", "X-B"], authorization: authorization)))
            XCTAssertEqual(config.secretAccountPrefix, "\(id.uuidString)/")
            for key in config.allSecretKeys + [config.bearerSecretKey] {
                XCTAssertTrue(key.hasPrefix(config.secretAccountPrefix), key)
            }
        }
    }

    // MARK: - The trust mark

    /// Only the modes that read the trust mark are named under it, from the modes themselves.
    func testTheTrustCaptionNamesTheModesThatReadTheMark() {
        XCTAssertFalse(MCPApprovalMode.manual.readsTrustMark)
        XCTAssertTrue(MCPApprovalMode.semiAutomatic.readsTrustMark)
        XCTAssertTrue(MCPApprovalMode.auto.readsTrustMark)
        let readers = MCPApprovalMode.allCases.filter(\.readsTrustMark)
        XCTAssertFalse(readers.isEmpty)
        let caption = MCPApprovalMode.trustMarkCaption
        XCTAssertTrue(caption.hasPrefix("Counts under "), caption)
        XCTAssertTrue(caption.hasSuffix(" only."), caption)
        for mode in MCPApprovalMode.allCases {
            XCTAssertEqual(caption.contains(mode.displayName), mode.readsTrustMark, "\(mode): \(caption)")
        }
    }

    func testServerGrantNameMatchesTheNamingRule() throws {
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")),
            displayName: "Folio",
            transport: .http(MCPHTTPConfig(urlString: "http://127.0.0.1:3845/mcp")))
        XCTAssertEqual(config.serverGrantName, "mcp__folio")
        XCTAssertTrue(MCPToolNaming.isServerGrant(config.serverGrantName))
    }

    // MARK: - A catalogue file written by a different build

    /// The decode is tolerant by design: a stored server that lost a field is repaired to
    /// something inert rather than dropped, because dropping it would take the user's whole
    /// list with it on one malformed row.
    func testAStoredServerWithNoURLDecodesToAnUnusableAddressRatherThanFailing() throws {
        let json = """
        {"id":"\(UUID().uuidString)","slug":"folio","displayName":"Folio",
         "transport":{"kind":"http","http":{}},"isEnabled":true}
        """
        let config = try JSONCoderFactory.makeDateDecoder()
            .decode(MCPServerConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.transport.http.urlString, "")
        XCTAssertEqual(config.slug.rawValue, "folio")
    }

    /// A transport row with no `kind` reads as HTTP — the only transport this build has, and
    /// the one every stored row was written under.
    func testATransportWithNoKindReadsAsHTTP() throws {
        let json = """
        {"id":"\(UUID().uuidString)","slug":"folio","displayName":"Folio",
         "transport":{"http":{"urlString":"https://folio.test/mcp"}},"isEnabled":false}
        """
        let config = try JSONCoderFactory.makeDateDecoder()
            .decode(MCPServerConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.transport.http.urlString, "https://folio.test/mcp")
    }

    /// Unknown `approvalMode` raw values fall back to `.manual`; a missing `judgeStrictness`
    /// key defaults to `.standard`, while a present unknown `judgeStrictness` raw value falls
    /// back to `.strict` (fail-closed toward the strictest tier).
    func testTolerantDecodingOfApprovalModeAndJudgeStrictness() throws {
        let missingStrictness = """
        {"id":"\(UUID().uuidString)","slug":"folio","displayName":"Folio",
         "transport":{"kind":"http","http":{"urlString":"https://folio.test/mcp"}},
         "isEnabled":true,"approvalMode":"auto"}
        """
        let decodedMissing = try JSONCoderFactory.makeDateDecoder()
            .decode(MCPServerConfig.self, from: Data(missingStrictness.utf8))
        XCTAssertEqual(decodedMissing.approvalMode, .auto)
        XCTAssertEqual(decodedMissing.judgeStrictness, .standard)

        let unknownBoth = """
        {"id":"\(UUID().uuidString)","slug":"folio","displayName":"Folio",
         "transport":{"kind":"http","http":{"urlString":"https://folio.test/mcp"}},
         "isEnabled":true,"approvalMode":"future_mode","judgeStrictness":"future_strictness"}
        """
        let decodedUnknown = try JSONCoderFactory.makeDateDecoder()
            .decode(MCPServerConfig.self, from: Data(unknownBoth.utf8))
        XCTAssertEqual(decodedUnknown.approvalMode, .manual)
        XCTAssertEqual(decodedUnknown.judgeStrictness, .strict)
    }

}
