import XCTest

@testable import NanoTeams

/// Pin URL canonicalization to keep tokens **isolated** between distinct LM
/// Studio servers. Any normalization rule that collapses two genuinely
/// distinct identities (different host, port, scheme, or path) into one key
/// would let the token for server A leak to server B.
///
/// These tests are paranoid on purpose: changing them requires a security
/// review.
final class URLNormalizationSecurityTests: XCTestCase {

    private func key(_ urlString: String) -> String {
        KeychainSecureTokenStorage.normalize(baseURL: urlString)
    }

    // MARK: - Identity equivalence (same server, written differently)

    func testTrailingSlash_collapsesToSameKey() {
        XCTAssertEqual(key("http://localhost:1234"), key("http://localhost:1234/"))
        XCTAssertEqual(key("http://localhost:1234"), key("http://localhost:1234///"))
    }

    func testCaseDifferences_collapseToSameKey() {
        XCTAssertEqual(key("HTTP://LOCALHOST:1234"), key("http://localhost:1234"))
        XCTAssertEqual(key("Http://Localhost:1234"), key("http://localhost:1234"))
    }

    func testLeadingTrailingWhitespace_doesNotChangeIdentity() {
        XCTAssertEqual(key("  http://localhost:1234  "), key("http://localhost:1234"))
        XCTAssertEqual(key("\thttp://localhost:1234\n"), key("http://localhost:1234"))
    }

    // MARK: - Distinct servers must NOT collide (security-critical)

    func testLocalhost_vs_127_areDistinct() {
        // Different network identities; firewalls + hosts files can route
        // differently. Tokens must NOT cross.
        XCTAssertNotEqual(key("http://localhost:1234"), key("http://127.0.0.1:1234"))
    }

    func testHttp_vs_https_areDistinct() {
        XCTAssertNotEqual(key("http://localhost:1234"), key("https://localhost:1234"))
    }

    func testDifferentPorts_areDistinct() {
        XCTAssertNotEqual(key("http://localhost:1234"), key("http://localhost:5678"))
        // Default ports are NOT collapsed (LM Studio uses :1234, the rule
        // would buy us nothing and would invite ":80 = no-port" mistakes).
        XCTAssertNotEqual(key("http://example.com:80"), key("http://example.com"))
    }

    func testDifferentHosts_areDistinct() {
        XCTAssertNotEqual(key("http://server-a:1234"), key("http://server-b:1234"))
    }

    func testDifferentPaths_areDistinct() {
        // LM Studio's own URL has no path, but if a user puts the server
        // behind a reverse-proxy prefix, the prefix is part of the identity.
        XCTAssertNotEqual(key("http://gateway:1234/lm-a"), key("http://gateway:1234/lm-b"))
        XCTAssertNotEqual(key("http://gateway:1234"), key("http://gateway:1234/lm"))
    }

    func testIPv6Brackets_preserved() {
        // IPv6 hosts use bracket notation. Lowercasing is fine; brackets must
        // be preserved exactly so [::1] and 127.0.0.1 stay distinct.
        let ipv6 = key("http://[::1]:1234")
        XCTAssertNotEqual(ipv6, key("http://localhost:1234"))
        XCTAssertNotEqual(ipv6, key("http://127.0.0.1:1234"))
        // Same IPv6 host, trailing slash → collapse
        XCTAssertEqual(ipv6, key("http://[::1]:1234/"))
    }

    func testEmptyString_isStableKey() {
        // No crash; idempotent.
        XCTAssertEqual(key(""), "")
        XCTAssertEqual(key("   "), "")
    }
}
