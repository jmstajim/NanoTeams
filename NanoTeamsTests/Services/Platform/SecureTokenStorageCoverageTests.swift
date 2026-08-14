import XCTest
import Security

@testable import NanoTeams

/// Closes the uncovered remainder of `SecureTokenStorage.swift`: the
/// `KeychainError` surfacing contract, the `normalize(baseURL:)` corners the
/// existing suite doesn't reach, the real-Keychain READ path (safe — a lookup
/// under a unique nonexistent service neither writes nor prompts), and the
/// `InMemorySecureTokenStorage` test-hook accessors.
///
/// Write-path coverage stays where it already lives: behind
/// `SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()`. Every Keychain
/// call here uses a `com.nanoteams.tests.*` + UUID service id, so the
/// production `com.nanoteams.lmstudio.bearer.v1` namespace is never touched.
final class SecureTokenStorageCoverageTests: XCTestCase {

    /// Unique per-call service id. UUID-suffixed so parallel workers can't
    /// collide, and prefixed so a stray entry is greppable in Keychain Access.
    private func testService(_ label: String) -> String {
        "com.nanoteams.tests.\(label).\(UUID().uuidString)"
    }

    // MARK: - KeychainError surfacing (DEFECT pin)

    /// **Regression pin for a shipped defect.**
    ///
    /// `KeychainError` declared a bare `var localizedDescription` without
    /// conforming to `LocalizedError`. That member is reached by *static*
    /// dispatch only. Every production consumer catches the error as
    /// `any Error` — `LLMTokenField.onLoadError` is typed `((Error) -> Void)?`,
    /// and six settings views spell
    /// `store.lastErrorMessage = "Could not read saved API token: \(error.localizedDescription)"`.
    /// Through the existential, Swift falls back to `NSError` bridging and
    /// produces `"The operation couldn't be completed. (NanoTeams.KeychainError error 0.)"`.
    ///
    /// Failure scenario: the user's login keychain is locked (or the app's ACL
    /// entry was revoked). Settings → LLM loads, `loadToken` throws
    /// `.unhandled(errSecInteractionNotAllowed)`, and the banner says
    /// "Could not read saved API token: The operation couldn't be completed."
    /// — neither the OSStatus (which the doc comment calls out as needed for
    /// diagnosis) nor the "Unlock Keychain Access" remedy survives. The user
    /// concludes the token was never saved, retypes it, and the write fails
    /// for the same reason.
    ///
    /// The pre-existing pin (`testKeychainError_localizedDescription_pointsUserAtKeychainAccess`)
    /// passes either way because it reads the CONCRETE type.
    func testKeychainError_throughExistential_stillCarriesActionableMessage() {
        let boxed: any Error = KeychainError.unhandled(-25308)
        let message = boxed.localizedDescription

        XCTAssertTrue(
            message.contains("Keychain"),
            "Through `any Error` the message must still name Keychain. Got: \(message)"
        )
        XCTAssertTrue(
            message.contains("-25308"),
            "Through `any Error` the OSStatus must still be present for diagnosis. Got: \(message)"
        )
        XCTAssertFalse(
            message.contains("couldn’t be completed") || message.contains("couldn't be completed"),
            "NSError bridging fallback leaked — KeychainError must conform to LocalizedError. Got: \(message)"
        )
    }

    func testKeychainError_invalidUTF8_throughExistential_carriesRecoveryStep() {
        let boxed: any Error = KeychainError.invalidUTF8
        XCTAssertTrue(
            boxed.localizedDescription.lowercased().contains("re-enter"),
            "Through `any Error` the corrupt-entry remedy must survive. Got: \(boxed.localizedDescription)"
        )
    }

    /// The two ways a caller can reach the message must agree, or a banner's
    /// wording depends on how the catch site happened to be typed.
    func testKeychainError_concreteAndExistentialDescriptions_agree() {
        for error in [KeychainError.unhandled(0), .unhandled(-25300), .invalidUTF8] {
            let boxed: any Error = error
            XCTAssertEqual(error.localizedDescription, boxed.localizedDescription)
        }
    }

    // MARK: - KeychainError value semantics

    func testKeychainError_equatable_discriminatesStatusAndCase() {
        XCTAssertEqual(KeychainError.unhandled(-25300), .unhandled(-25300))
        XCTAssertNotEqual(KeychainError.unhandled(-25300), .unhandled(-25308))
        XCTAssertNotEqual(KeychainError.unhandled(0), .invalidUTF8)
        XCTAssertEqual(KeychainError.invalidUTF8, .invalidUTF8)
    }

    /// `errSecItemNotFound` is the one status the storage must NEVER wrap into
    /// `.unhandled` — it means legitimate absence and is handled by returning
    /// `nil`. If it ever showed up in a banner it would tell the user their
    /// keychain is broken when they simply have no token saved.
    func testKeychainError_unhandled_rendersAnyStatusIncludingPositive() {
        XCTAssertTrue(KeychainError.unhandled(1).localizedDescription.contains("1"))
        XCTAssertTrue(KeychainError.unhandled(errSecItemNotFound).localizedDescription
            .contains("\(errSecItemNotFound)"))
    }

    // MARK: - normalize(baseURL:) corners

    func testNormalize_emptyInput_staysEmpty() {
        XCTAssertEqual(KeychainSecureTokenStorage.normalize(baseURL: ""), "")
    }

    func testNormalize_whitespaceOnly_collapsesToEmpty() {
        XCTAssertEqual(KeychainSecureTokenStorage.normalize(baseURL: "   \n\t "), "")
    }

    /// Degenerate input: a URL that is nothing but separators strips down to
    /// the empty account key rather than looping or trapping.
    func testNormalize_onlySlashes_collapsesToEmpty() {
        XCTAssertEqual(KeychainSecureTokenStorage.normalize(baseURL: "/////"), "")
    }

    /// The key must be a fixed point — the same server normalized twice has to
    /// land on the same Keychain account, or a re-save orphans the first entry.
    func testNormalize_isIdempotent() {
        let inputs = [
            "  HTTP://LocalHost:1234///  ",
            "http://127.0.0.1:1234",
            "https://example.com/v1/",
            "",
            "/////"
        ]
        for raw in inputs {
            let once = KeychainSecureTokenStorage.normalize(baseURL: raw)
            XCTAssertEqual(KeychainSecureTokenStorage.normalize(baseURL: once), once,
                           "normalize is not a fixed point for \(raw.debugDescription)")
        }
    }

    /// Trim happens BEFORE the trailing-slash strip, so a URL padded with both
    /// still resolves to the bare form. Order matters: strip-then-trim would
    /// leave `"http://x/"` for `"http://x/ "`.
    func testNormalize_trimsBeforeStrippingSlashes() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "  http://localhost:1234/  "),
            "http://localhost:1234"
        )
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "\thttp://localhost:1234///\n"),
            "http://localhost:1234"
        )
    }

    /// A non-root path is part of the server identity and must survive; only
    /// the trailing separator is cosmetic.
    func testNormalize_preservesPathButDropsTrailingSlash() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "https://example.com/api/v1/"),
            "https://example.com/api/v1"
        )
    }

    func testNormalize_lowercasesScheme() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "HTTPS://Example.COM"),
            "https://example.com"
        )
    }

    /// Characterization, not endorsement: the shared normalizer lowercases the
    /// WHOLE string, so two paths differing only in case share one Keychain
    /// account. Harmless for base URLs (host + port + optional `/v1`), but it
    /// is the reason this must never be reused as a general path key.
    func testNormalize_foldsPathCaseToo_characterization() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://h:1/API"),
            KeychainSecureTokenStorage.normalize(baseURL: "http://h:1/api")
        )
    }

    /// Different schemes on the same host:port are different servers — an
    /// http↔https collapse would send a token over the wrong transport.
    func testNormalize_doesNotCollapseSchemes() {
        XCTAssertNotEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://example.com:443"),
            KeychainSecureTokenStorage.normalize(baseURL: "https://example.com:443")
        )
    }

    /// Explicit default port is a distinct string from the implicit one.
    /// Deliberate: collapsing them would need URL parsing, and a
    /// parse-failure fallback would silently re-key existing tokens.
    func testNormalize_doesNotCollapseImplicitAndExplicitDefaultPort() {
        XCTAssertNotEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://example.com"),
            KeychainSecureTokenStorage.normalize(baseURL: "http://example.com:80")
        )
    }

    // MARK: - Real Keychain READ path (no write, no prompt)

    /// Exercises `KeychainSecureTokenStorage.loadToken` against the real
    /// Security framework. A `SecItemCopyMatching` for an account under a
    /// freshly-minted service id returns `errSecItemNotFound` immediately: no
    /// item is created, no ACL is evaluated, so no authorization prompt can
    /// fire. That makes the read path safe to cover without the write opt-in.
    func testKeychain_loadToken_absentEntry_returnsNilWithoutThrowing() throws {
        let sut = KeychainSecureTokenStorage(service: testService("read"))
        do {
            XCTAssertNil(try sut.loadToken(forKey: "http://127.0.0.1:1234"))
        } catch KeychainError.unhandled(let status) {
            throw XCTSkip("Keychain lookup refused on this runner (status \(status)).")
        }
    }

    /// The non-throwing shim over the same absent-entry read.
    func testKeychain_tokenShim_absentEntry_returnsNil() {
        let sut = KeychainSecureTokenStorage(service: testService("read-shim"))
        XCTAssertNil(sut.token(forKey: "http://127.0.0.1:1234"))
    }

    /// The empty account key is representable (`normalize("")` yields it), so
    /// the lookup must be a clean miss rather than a malformed-query error.
    func testKeychain_loadToken_emptyKey_returnsNilWithoutThrowing() throws {
        let sut = KeychainSecureTokenStorage(service: testService("read-emptykey"))
        do {
            XCTAssertNil(try sut.loadToken(forKey: ""))
        } catch KeychainError.unhandled(let status) {
            throw XCTSkip("Keychain lookup refused on this runner (status \(status)).")
        }
    }

    /// Two storages with different service ids must not see each other's
    /// namespace — this is what keeps the test services from ever reading the
    /// production `com.nanoteams.lmstudio.bearer.v1` entry.
    func testKeychain_serviceScoping_isolatesNamespaces() {
        let a = KeychainSecureTokenStorage(service: testService("iso-a"))
        let b = KeychainSecureTokenStorage(service: testService("iso-b"))
        XCTAssertNotEqual(a.service, b.service)
        XCTAssertNil(a.token(forKey: "k"))
        XCTAssertNil(b.token(forKey: "k"))
    }

    func testKeychain_defaultInit_usesProductionService() {
        XCTAssertEqual(
            KeychainSecureTokenStorage().service,
            KeychainSecureTokenStorage.defaultService
        )
    }

    // MARK: - Real Keychain WRITE path (opt-in only)

    /// `setToken(nil,)` on an absent key goes through `delete(key:)`, whose
    /// `errSecItemNotFound` arm must be treated as success — a clear-token
    /// click on a server that never had one must not banner an error.
    /// Gated behind the write opt-in even though it deletes nothing.
    func testKeychain_deleteAbsentEntry_isNotAnError() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let sut = KeychainSecureTokenStorage(service: testService("del-absent"))
        do {
            try sut.setToken(nil, forKey: "http://127.0.0.1:1234")
        } catch KeychainError.unhandled(let status)
            where status == errSecMissingEntitlement
                || status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
        {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
    }

    /// Whitespace-only input is a clear, not a store — otherwise a stray space
    /// in the SecureField would persist an unusable `Authorization: Bearer`
    /// header value.
    func testKeychain_setWhitespaceOnly_clearsRatherThanStores() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let sut = KeychainSecureTokenStorage(service: testService("ws-clear"))
        let key = "http://127.0.0.1:1234"
        defer { try? sut.setToken(nil, forKey: key) }

        do {
            try sut.setToken("real-token", forKey: key)
        } catch KeychainError.unhandled(let status)
            where status == errSecMissingEntitlement
                || status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
        {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
        XCTAssertEqual(sut.token(forKey: key), "real-token")

        try sut.setToken("   \n ", forKey: key)
        XCTAssertNil(sut.token(forKey: key))
    }

    /// The stored value must be the TRIMMED token — a trailing newline pasted
    /// from a terminal would otherwise ride into the HTTP header.
    func testKeychain_setTrimsSurroundingWhitespaceBeforeStoring() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let sut = KeychainSecureTokenStorage(service: testService("trim"))
        let key = "http://127.0.0.1:1234"
        defer { try? sut.setToken(nil, forKey: key) }

        do {
            try sut.setToken("  padded-token\n", forKey: key)
        } catch KeychainError.unhandled(let status)
            where status == errSecMissingEntitlement
                || status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
        {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
        XCTAssertEqual(sut.token(forKey: key), "padded-token")
    }

    /// Non-ASCII round-trips through the UTF-8 encode/decode pair intact.
    func testKeychain_roundTripsNonASCIIToken() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let sut = KeychainSecureTokenStorage(service: testService("utf8"))
        let key = "http://127.0.0.1:1234"
        let token = "tökén-Ключ-🔑"
        defer { try? sut.setToken(nil, forKey: key) }

        do {
            try sut.setToken(token, forKey: key)
        } catch KeychainError.unhandled(let status)
            where status == errSecMissingEntitlement
                || status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
        {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
        XCTAssertEqual(sut.token(forKey: key), token)
    }

    /// Two normalized keys under one service are separate accounts — a shared
    /// entry would send server A's token to server B.
    func testKeychain_distinctKeysUnderOneService_doNotBleed() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let sut = KeychainSecureTokenStorage(service: testService("multikey"))
        let k1 = KeychainSecureTokenStorage.normalize(baseURL: "http://localhost:1234/")
        let k2 = KeychainSecureTokenStorage.normalize(baseURL: "http://127.0.0.1:1234/")
        defer {
            try? sut.setToken(nil, forKey: k1)
            try? sut.setToken(nil, forKey: k2)
        }

        do {
            try sut.setToken("token-localhost", forKey: k1)
        } catch KeychainError.unhandled(let status)
            where status == errSecMissingEntitlement
                || status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
        {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
        try sut.setToken("token-loopback", forKey: k2)

        XCTAssertEqual(sut.token(forKey: k1), "token-localhost")
        XCTAssertEqual(sut.token(forKey: k2), "token-loopback")
    }

    // MARK: - InMemorySecureTokenStorage test hooks

    /// The `readError` GETTER takes the lock in its own right; `loadToken`
    /// deliberately reads `_readError` directly to avoid recursing on the
    /// non-reentrant `NSLock`. Exercise both so a future refactor that routes
    /// `loadToken` through the property deadlocks a test instead of the app.
    func testInMemory_readError_roundTripsThroughAccessor() {
        let sut = InMemorySecureTokenStorage()
        XCTAssertNil(sut.readError)
        sut.readError = .invalidUTF8
        XCTAssertEqual(sut.readError, .invalidUTF8)
        XCTAssertThrowsError(try sut.loadToken(forKey: "k"))
        sut.readError = nil
        XCTAssertNil(sut.readError)
        XCTAssertNoThrow(try sut.loadToken(forKey: "k"))
    }

    /// An injected read failure must not block writes — otherwise the
    /// "Keychain locked, then unlocked, then save" path would be untestable.
    func testInMemory_writesStillSucceedWhileReadErrorIsInjected() throws {
        let sut = InMemorySecureTokenStorage()
        sut.readError = .unhandled(-25308)
        XCTAssertNoThrow(try sut.setToken("v", forKey: "k"))
        sut.readError = nil
        XCTAssertEqual(try sut.loadToken(forKey: "k"), "v")
    }

    /// Deleting an absent key is a no-op, mirroring the Keychain impl's
    /// `errSecItemNotFound`-is-success rule.
    func testInMemory_deleteAbsentKey_isNoOp() {
        let sut = InMemorySecureTokenStorage()
        XCTAssertNoThrow(try sut.setToken(nil, forKey: "never-there"))
        XCTAssertNil(sut.token(forKey: "never-there"))
    }

    func testInMemory_initialSeed_isReadable() throws {
        let sut = InMemorySecureTokenStorage(initial: ["a": "1", "b": "2"])
        XCTAssertEqual(try sut.loadToken(forKey: "a"), "1")
        XCTAssertEqual(try sut.loadToken(forKey: "b"), "2")
        XCTAssertNil(try sut.loadToken(forKey: "c"))
    }

    /// The `token(forKey:)` protocol-extension shim is the hot-path resolver.
    /// It must swallow a thrown failure into `nil` — a throw there would
    /// propagate out of `URLRequest` construction.
    func testTokenShim_swallowsThrownFailureIntoNil() {
        let sut = InMemorySecureTokenStorage(initial: ["k": "v"])
        XCTAssertEqual(sut.token(forKey: "k"), "v")
        sut.readError = .unhandled(-25308)
        XCTAssertNil(sut.token(forKey: "k"))
    }

    /// The shim is reached through the existential too — `DefaultLLMTokenResolver`
    /// holds `any SecureTokenStorage`, so protocol-extension dispatch has to work
    /// there or every request would go out unauthenticated.
    func testTokenShim_worksThroughExistential() {
        let concrete = InMemorySecureTokenStorage(initial: ["k": "v"])
        let sut: any SecureTokenStorage = concrete
        XCTAssertEqual(sut.token(forKey: "k"), "v")
        concrete.readError = .invalidUTF8
        XCTAssertNil(sut.token(forKey: "k"))
    }
}
