import XCTest

@testable import NanoTeams

/// User-flow invariant: a single-server user (the common case — global LLM,
/// vision, embedding all pointed at `http://127.0.0.1:1234`) enters their
/// API token ONCE on the LLM card, and Vision / Embedding / per-role override
/// surfaces all pick it up automatically. Multi-server users (advanced) get
/// per-URL isolation.
///
/// The contract is purely "lookups normalize the URL the same way as writes",
/// so a write on the LLM card under one form (`http://localhost:1234`) is
/// visible to a Vision read under another form (`HTTP://LOCALHOST:1234/`).
final class MultiSurfaceTokenSharingTests: XCTestCase {

    func testTokenForOneURL_isVisibleToAllSurfacesWithSameURL() throws {
        let storage = InMemorySecureTokenStorage()
        let llmURL = "http://localhost:1234"
        let resolver = DefaultLLMTokenResolver(storage: storage)

        // Simulate the LLM card writing the token.
        try storage.setToken(
            "shared-token",
            forKey: KeychainSecureTokenStorage.normalize(baseURL: llmURL)
        )

        // Vision card looks up under its own URL field, which (when empty)
        // falls back to the LLM URL.
        XCTAssertEqual(resolver.token(forBaseURL: llmURL), "shared-token")

        // Embedding card looks up under the same URL too.
        XCTAssertEqual(
            resolver.token(forBaseURL: "HTTP://LOCALHOST:1234/"),
            "shared-token",
            "Lookup must normalize: a Vision card that stores its URL with "
                + "trailing slash must still see the LLM card's token."
        )

        // Per-role override on the same URL: same token.
        XCTAssertEqual(resolver.token(forBaseURL: "  http://localhost:1234  "), "shared-token")
    }

    func testTokenForOneURL_isInvisibleToOtherURLs() throws {
        let storage = InMemorySecureTokenStorage()
        let resolver = DefaultLLMTokenResolver(storage: storage)

        try storage.setToken(
            "secret-A",
            forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://server-a:1234")
        )

        XCTAssertNil(resolver.token(forBaseURL: "http://server-b:1234"))
        XCTAssertNil(resolver.token(forBaseURL: "https://server-a:1234"),
                     "Different scheme must NOT share the token.")
        XCTAssertNil(resolver.token(forBaseURL: "http://server-a:5678"),
                     "Different port must NOT share the token.")
    }

    func testWritingDifferentTokensForDifferentURLs_keepsBothIsolated() throws {
        let storage = InMemorySecureTokenStorage()
        let resolver = DefaultLLMTokenResolver(storage: storage)

        let urlA = "http://server-a:1"
        let urlB = "http://server-b:2"

        try storage.setToken("tok-A", forKey: KeychainSecureTokenStorage.normalize(baseURL: urlA))
        try storage.setToken("tok-B", forKey: KeychainSecureTokenStorage.normalize(baseURL: urlB))

        XCTAssertEqual(resolver.token(forBaseURL: urlA), "tok-A")
        XCTAssertEqual(resolver.token(forBaseURL: urlB), "tok-B")
    }

    func testClearingTokenForOneURL_doesNotAffectOthers() throws {
        let storage = InMemorySecureTokenStorage()
        let resolver = DefaultLLMTokenResolver(storage: storage)

        try storage.setToken("tok-A", forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://a:1"))
        try storage.setToken("tok-B", forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://b:2"))

        // User taps the Clear (×) button on the A card.
        try storage.setToken(nil, forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://a:1"))

        XCTAssertNil(resolver.token(forBaseURL: "http://a:1"))
        XCTAssertEqual(resolver.token(forBaseURL: "http://b:2"), "tok-B",
                       "Clearing one URL's token must not touch any other URL's entry.")
    }
}
