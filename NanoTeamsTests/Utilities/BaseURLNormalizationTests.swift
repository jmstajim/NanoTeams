import XCTest

@testable import NanoTeams

/// Every place that canonicalizes an LM Studio server URL must fold exactly the
/// same things. Divergence is silent and expensive: the Keychain account key
/// would strand a stored bearer token, the model-list cache key would split one
/// server into two entries, and the load-coalescing key would let two "different"
/// spellings of the same server double-load a model.
///
/// They now all delegate to `String.normalizedBaseURL`; this pins that they
/// still agree, so re-inlining any of them fails here rather than in production.
final class BaseURLNormalizationTests: XCTestCase {

    /// One row per fold, plus the degenerate inputs where a naive
    /// `dropLast()`-style implementation walks off the end.
    private let corners: [(input: String, expected: String)] = [
        ("http://127.0.0.1:1234", "http://127.0.0.1:1234"),   // already canonical
        ("http://127.0.0.1:1234/", "http://127.0.0.1:1234"),  // one trailing slash
        ("http://127.0.0.1:1234///", "http://127.0.0.1:1234"), // several
        ("  http://127.0.0.1:1234  ", "http://127.0.0.1:1234"), // outer whitespace
        ("HTTP://127.0.0.1:1234", "http://127.0.0.1:1234"),   // case
        ("\thttp://X:1234/\n", "http://x:1234"),              // all three at once
        ("", ""),
        ("   ", ""),
        ("/", ""),
        ("///", ""),
    ]

    func testNormalizedBaseURL_cornerTable() {
        for (input, expected) in corners {
            XCTAssertEqual(
                input.normalizedBaseURL, expected,
                "normalizedBaseURL(\(input.debugDescription))")
        }
    }

    func testAllNormalizers_agreeOnEveryCorner() {
        for (input, expected) in corners {
            XCTAssertEqual(
                KeychainSecureTokenStorage.normalize(baseURL: input), expected,
                "Keychain account key diverged on \(input.debugDescription) — "
                    + "every previously stored token for this server becomes unreadable")
            XCTAssertEqual(
                ModelCatalog.normalize(input), expected,
                "Model-list cache key diverged on \(input.debugDescription)")
        }
    }

    /// Deliberately conservative: these pairs are DIFFERENT servers. Collapsing
    /// them would share one token / one cache entry across hosts that a firewall
    /// can route differently.
    func testNormalization_doesNotCollapseDistinctHostsOrPorts() {
        XCTAssertNotEqual(
            "http://localhost:1234".normalizedBaseURL,
            "http://127.0.0.1:1234".normalizedBaseURL,
            "localhost and 127.0.0.1 are distinct network identities")
        XCTAssertNotEqual(
            "http://example".normalizedBaseURL,
            "http://example:80".normalizedBaseURL,
            "Default ports are not collapsed")
        XCTAssertNotEqual(
            "http://x:1234".normalizedBaseURL,
            "https://x:1234".normalizedBaseURL,
            "Scheme is part of the identity")
    }

    /// Only TRAILING slashes collapse — a path segment is part of the identity.
    func testNormalization_preservesInteriorSlashes() {
        XCTAssertEqual("http://x:1234/v1/".normalizedBaseURL, "http://x:1234/v1")
    }
}
