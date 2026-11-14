import XCTest

@testable import NanoTeams

/// The one spelling of "the server an address reaches". Two rules read it: the redirect policy
/// (a hop may not leave the origin, or the `Authorization` header goes with it) and the
/// re-point check (a new origin loses every secret and approval the old one was given). Until
/// the second review of group D (2026-09-24) each had its own copy, and a normalization fixed in
/// one would not have reached the other.
final class URLOriginTests: XCTestCase {

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    func testTheDefaultPortIsSpelledOut() throws {
        XCTAssertEqual(URLOrigin(try url("https://example.com/mcp"))?.port, 443)
        XCTAssertEqual(URLOrigin(try url("http://example.com/mcp"))?.port, 80)
        XCTAssertEqual(URLOrigin(try url("https://example.com:443/mcp")), URLOrigin(try url("https://example.com/mcp")))
        XCTAssertNotEqual(URLOrigin(try url("https://example.com:8443/mcp")), URLOrigin(try url("https://example.com/mcp")))
    }

    func testTheSchemeAndTheHostAreCaseFolded() throws {
        let origin = try XCTUnwrap(URLOrigin(try url("HTTPS://Example.COM/mcp")))
        XCTAssertEqual(origin.scheme, "https")
        XCTAssertEqual(origin.host, "example.com")
    }

    /// An IPv6 literal compares without its brackets, as `LoopbackHost` reads it: `URL.host`
    /// drops them on macOS and `URLComponents.host` keeps them, so the two parsers spelled one
    /// host two ways.
    ///
    /// RED until the second review of group D (2026-09-24): the re-point check read
    /// `URLComponents.host` and got `[::1]`; the redirect policy got `::1`.
    func testAnIPv6LiteralIsReadWithoutItsBrackets() throws {
        XCTAssertEqual(URLOrigin(try url("http://[::1]:3845/mcp"))?.host, "::1")
        XCTAssertEqual(URLOrigin("http://[::1]:3845/mcp")?.host, "::1")
        XCTAssertEqual(URLOrigin("https://[FE80::1]/mcp")?.host, "fe80::1")
        XCTAssertEqual(URLOrigin.normalizedHost("[::1]"), "::1", "a hand-typed host loses its brackets too")
        XCTAssertEqual(URLOrigin.normalizedHost("LocalHost"), "localhost")
    }

    /// `LoopbackHost` normalizes a host through the same rule, so the loopback check and the
    /// origin cannot drift apart.
    func testLoopbackHostNormalizesThroughTheOriginsHostRule() {
        for host in ["[::1]", "LocalHost", "[FE80::1]", "127.0.0.1", ""] {
            XCTAssertEqual(LoopbackHost.normalize(host), URLOrigin.normalizedHost(host), host)
        }
    }

    func testAnAddressThatNamesNoServerHasNoOrigin() {
        for string in ["", "   ", "not a url", "a.test/mcp", "https://"] {
            XCTAssertNil(URLOrigin(string), string)
        }
    }

    /// The re-point check and the redirect policy answer every pair alike — a default port
    /// spelled out, a host's case, an IPv6 literal, a loopback spelling the normalizer folds,
    /// and each of scheme, host and port changed alone.
    func testTheRepointCheckAndTheRedirectPolicyAgree() throws {
        let pairs: [(String, String, Bool)] = [
            ("https://example.com/mcp", "https://example.com:443/v2", true),
            ("https://example.com/mcp", "https://EXAMPLE.com/mcp", true),
            ("http://[::1]:3845/mcp", "http://[::1]:3845/v2", true),
            ("http://[::1]:3845/mcp", "http://[::1]:3846/mcp", false),
            ("http://LOCALHOST:3845/mcp", "http://localhost:3845/v2", true),
            ("http://127.0.0.1:3845/mcp", "http://localhost:3845/mcp", false),
            ("https://example.com/mcp", "https://example.com:8443/mcp", false),
            ("https://example.com:8443/mcp", "http://example.com:8443/mcp", false),
            ("https://example.com/mcp", "https://evil.test/mcp", false),
        ]
        for (first, second, same) in pairs {
            XCTAssertEqual(MCPHTTPConfig.reachSameServer(first, second), same, "\(first) → \(second)")
            if (try? MCPEndpointPolicy.validate(second)) != nil {
                XCTAssertEqual(
                    MCPRedirectPolicy.allows(from: try url(first), to: try url(second)), same, "\(first) → \(second)")
            }
        }
    }


    // MARK: - The account segment (third pass of group D's review, 2026-09-24)

    /// Addresses that vary each of scheme, host and port alone, spell one origin several ways
    /// (case, a default port written out, a path, an IDN host and its punycode, an IPv6 literal
    /// with and without its port), and carry a `:`, a `/`, a `%`, a `[` or a space inside the
    /// host — each of which a naive `scheme:host:port` join could let collide.
    private static let corpus = [
        "https://example.com/mcp", "https://EXAMPLE.com:443/v2", "http://example.com/mcp",
        "http://example.com:443/mcp", "https://example.com:8443/mcp", "https://example.com:80/mcp",
        "http://example.com:80/x", "https://evil.test/mcp", "https://example.com.evil.test/mcp",
        "http://[::1]:3845/mcp", "http://[::1]:3846/mcp", "http://[::1]/mcp", "https://[::1]/mcp",
        "HTTP://[FE80::1]/mcp", "http://[fe80::1]:80/v2", "http://[0:0:0:0:0:0:0:1]:3845/mcp",
        "http://[fe80::1%25en0]:8080/", "http://[fe80::1]:8080/",
        "http://127.0.0.1:3845/mcp", "http://localhost:3845/mcp", "http://LOCALHOST:3845/v2",
        "http://a%3A80/", "http://a:80/", "http://a%3A80:80/", "http://a%3Ab.test/", "http://a%3Ab.test:80/",
        "http://a%2Fb.test/", "http://a%252Fb.test/", "http://a%25b/", "http://a%5Bb.test/", "http://a%20b/",
        "https://пример.рф/", "https://xn--e1afmkfd.xn--p1ai/mcp",
        "ftp://files.test/", "ftp://files.test:21/",
    ]

    /// Every Keychain account a server reads is spelled under the segment of the origin it was
    /// entered for, so a value typed for one address is never read for another. Spelled for a
    /// person reading Keychain Access: scheme, host and port, the default port written out, an
    /// IPv6 literal in its brackets.
    func testTheAccountSegmentSpellsTheSchemeTheHostAndThePort() {
        XCTAssertEqual(URLOrigin("https://example.com/mcp")?.accountSegment, "https:example.com:443")
        XCTAssertEqual(URLOrigin("HTTPS://Example.COM:443/v2")?.accountSegment, "https:example.com:443")
        XCTAssertEqual(URLOrigin("http://127.0.0.1:3845/mcp")?.accountSegment, "http:127.0.0.1:3845")
        XCTAssertEqual(URLOrigin("http://[::1]:3845/mcp")?.accountSegment, "http:[::1]:3845")
        XCTAssertEqual(URLOrigin("HTTP://[FE80::1]/mcp")?.accountSegment, "http:[fe80::1]:80")
        XCTAssertEqual(URLOrigin("https://пример.рф/")?.accountSegment, "https:xn--e1afmkfd.xn--p1ai:443")
        XCTAssertEqual(URLOrigin("ftp://files.test/x")?.accountSegment, "ftp:files.test:",
                       "a scheme with no default port spells none")
    }

    /// The segment is ONE path segment of an account (`<uuid>/<segment>/bearer`), and a reader
    /// splits it at its first `:` and its last. So a host's `%`, `/`, `[` and `]` are
    /// percent-escaped — the `%` too, so an escape can never be read back as a character the
    /// host really had — and a host with a `:` in it is written inside brackets, the only place
    /// a host's `:` can appear.
    func testAHostIsSpelledSoTheSegmentHasNoSlashAndNoBareColon() {
        XCTAssertEqual(URLOrigin("http://a%2Fb.test/mcp")?.accountSegment, "http:a%2Fb.test:80")
        XCTAssertEqual(URLOrigin("http://a%252Fb.test/mcp")?.accountSegment, "http:a%252fb.test:80",
                       "a host that SPELLS an escape — case-folded like any host — is not the host the escape stands for")
        XCTAssertEqual(URLOrigin("http://a%3Ab.test/mcp")?.accountSegment, "http:[a:b.test]:80")
        XCTAssertEqual(URLOrigin("http://a%3A80/")?.accountSegment, "http:[a:80]:80")
        XCTAssertEqual(URLOrigin("http://a%5Bb.test/")?.accountSegment, "http:a%5Bb.test:80")
        XCTAssertEqual(URLOrigin("http://[fe80::1%25en0]:8080/mcp")?.accountSegment, "http:[fe80::1%25en0]:8080")
        for address in Self.corpus {
            guard let segment = URLOrigin(address)?.accountSegment else { continue }
            XCTAssertFalse(segment.contains("/"), "\(address) → \(segment)")
            let first = segment.firstIndex(of: ":"), last = segment.lastIndex(of: ":")
            let host = first.flatMap { f in last.map { l in segment[segment.index(after: f)..<l] } }.map(String.init) ?? ""
            XCTAssertTrue(!host.contains(":") || (host.hasPrefix("[") && host.hasSuffix("]")), "\(address) → \(segment)")
        }
    }

    /// Injective over the origin: two addresses share a segment exactly when they reach the
    /// same origin — every pair of the corpus, both ways.
    func testTwoAddressesShareASegmentExactlyWhenTheyShareAnOrigin() throws {
        let origins = try Self.corpus.map { try XCTUnwrap(URLOrigin($0), $0) }
        XCTAssertEqual(Set(origins).count, Set(origins.map(\.accountSegment)).count, "premise: as many segments as origins")
        for (a, first) in zip(Self.corpus, origins) {
            for (b, second) in zip(Self.corpus, origins) {
                XCTAssertEqual(first == second, first.accountSegment == second.accountSegment, "\(a) | \(b)")
            }
        }
    }

    /// An address that names no server gets a segment too — its own spelling, escaped the same
    /// way and with its `:` escaped as well, so it holds no `:` and can never be an origin's,
    /// which always holds two. And the re-point check IS the comparison of segments: two
    /// addresses reach the same server exactly when every account of one is an account of the
    /// other.
    func testTheRepointCheckIsTheComparisonOfAccountSegments() {
        XCTAssertEqual(MCPHTTPConfig.secretAccountSegment(for: "  not a url  "), "not a url")
        XCTAssertEqual(MCPHTTPConfig.secretAccountSegment(for: "a.test/mcp"), "a.test%2Fmcp")
        XCTAssertEqual(MCPHTTPConfig.secretAccountSegment(for: "x:y%z"), "x%3Ay%25z")
        XCTAssertEqual(MCPHTTPConfig.secretAccountSegment(for: "https://example.com/mcp"), "https:example.com:443")
        let unparsed = ["not a url", "  not a url  ", "a.test/mcp", "a.test%2Fmcp", "x:y%z", "https://", ""]
        for address in unparsed {
            XCTAssertNil(URLOrigin(address), "premise: \(address)")
            XCTAssertFalse(MCPHTTPConfig.secretAccountSegment(for: address).contains(":"), address)
            XCTAssertFalse(MCPHTTPConfig.secretAccountSegment(for: address).contains("/"), address)
        }
        let all = Self.corpus + unparsed
        for a in all {
            for b in all {
                XCTAssertEqual(
                    MCPHTTPConfig.reachSameServer(a, b),
                    MCPHTTPConfig.secretAccountSegment(for: a) == MCPHTTPConfig.secretAccountSegment(for: b),
                    "\(a) | \(b)")
            }
        }
        XCTAssertFalse(MCPHTTPConfig.reachSameServer("a.test/mcp", "a.test%2Fmcp"), "an escape is not what it stands for")
    }
}
