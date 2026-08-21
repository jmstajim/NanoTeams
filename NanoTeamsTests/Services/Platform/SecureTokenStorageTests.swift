import XCTest

@testable import NanoTeams

final class SecureTokenStorageTests: XCTestCase {

    /// Real-Keychain tests prompt for authorization on the first write by an
    /// unsigned app on local dev machines and block indefinitely waiting for
    /// the user to click Allow. Default to skipping; set
    /// `NANOTEAMS_TEST_REAL_KEYCHAIN=1` in the test scheme's environment to
    /// run them. CI uses a signed runner where the prompt doesn't fire.
    static func skipUnlessRealKeychainOptedIn() throws {
        guard ProcessInfo.processInfo.environment["NANOTEAMS_TEST_REAL_KEYCHAIN"] == "1" else {
            throw XCTSkip("Real Keychain test disabled by default. "
                + "Set NANOTEAMS_TEST_REAL_KEYCHAIN=1 in the scheme env to enable.")
        }
    }

    // MARK: - InMemory impl

    func testInMemory_setThenGet_returnsToken() throws {
        let sut = InMemorySecureTokenStorage()
        try sut.setToken("abc123", forKey: "k")
        XCTAssertEqual(sut.token(forKey: "k"), "abc123")
    }

    func testInMemory_setNil_deletes() throws {
        let sut = InMemorySecureTokenStorage(initial: ["k": "abc"])
        try sut.setToken(nil, forKey: "k")
        XCTAssertNil(sut.token(forKey: "k"))
    }

    func testInMemory_setEmpty_deletes() throws {
        let sut = InMemorySecureTokenStorage(initial: ["k": "abc"])
        try sut.setToken("", forKey: "k")
        XCTAssertNil(sut.token(forKey: "k"))
    }

    func testInMemory_setWhitespaceOnly_deletes() throws {
        let sut = InMemorySecureTokenStorage(initial: ["k": "abc"])
        try sut.setToken("   \n\t  ", forKey: "k")
        XCTAssertNil(sut.token(forKey: "k"))
    }

    func testInMemory_setTrimsWhitespace() throws {
        let sut = InMemorySecureTokenStorage()
        try sut.setToken("  token-value  ", forKey: "k")
        XCTAssertEqual(sut.token(forKey: "k"), "token-value")
    }

    func testInMemory_overwrite_keepsLatestValue() throws {
        let sut = InMemorySecureTokenStorage()
        try sut.setToken("v1", forKey: "k")
        try sut.setToken("v2", forKey: "k")
        XCTAssertEqual(sut.token(forKey: "k"), "v2")
    }

    func testInMemory_keyIsolated() throws {
        let sut = InMemorySecureTokenStorage()
        try sut.setToken("a", forKey: "k1")
        try sut.setToken("b", forKey: "k2")
        XCTAssertEqual(sut.token(forKey: "k1"), "a")
        XCTAssertEqual(sut.token(forKey: "k2"), "b")
    }

    // MARK: - URL normalization (security-critical)

    func testNormalize_trimsTrailingSlash() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://localhost:1234/"),
            "http://localhost:1234"
        )
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://localhost:1234///"),
            "http://localhost:1234"
        )
    }

    func testNormalize_lowercasesHost() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://LOCALHOST:1234"),
            "http://localhost:1234"
        )
    }

    func testNormalize_doesNotCollapseLocalhostAnd127() {
        // 127.0.0.1 and localhost must stay distinct — they can route differently
        // through host-based firewall rules, and a token leak across them would
        // be a real security issue.
        let a = KeychainSecureTokenStorage.normalize(baseURL: "http://localhost:1234")
        let b = KeychainSecureTokenStorage.normalize(baseURL: "http://127.0.0.1:1234")
        XCTAssertNotEqual(a, b)
    }

    func testNormalize_doesNotCollapseDifferentPorts() {
        XCTAssertNotEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://localhost:1234"),
            KeychainSecureTokenStorage.normalize(baseURL: "http://localhost:5678")
        )
    }

    func testNormalize_trimsLeadingTrailingWhitespace() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "  http://localhost:1234  "),
            "http://localhost:1234"
        )
    }

    // MARK: - Production Keychain integration (skipped on CI when unavailable)

    /// Smoke test for the real Keychain code path. Uses a unique service id so
    /// it never touches the user's real LM Studio token entry. Skipped on
    /// runners where the default keychain refuses access (e.g. headless CI),
    /// AND skipped by default on local dev machines because macOS prompts
    /// for keychain authorization on the first write by an unsigned app —
    /// that prompt blocks the test runner indefinitely. Opt in via env var
    /// `NANOTEAMS_TEST_REAL_KEYCHAIN=1` when running locally.
    func testKeychain_roundTrip_underUniqueService() throws {
        try Self.skipUnlessRealKeychainOptedIn()
        let service = "com.nanoteams.tests.\(UUID().uuidString)"
        let sut = KeychainSecureTokenStorage(service: service)
        defer { try? sut.setToken(nil, forKey: "k") }

        do {
            try sut.setToken("integration-test-token", forKey: "k")
        } catch KeychainError.unhandled(let status)
            where status == errSecMissingEntitlement
            || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
        {
            throw XCTSkip("Keychain is unavailable on this runner (status \(status)).")
        }

        XCTAssertEqual(sut.token(forKey: "k"), "integration-test-token")

        // Idempotent overwrite via SecItemUpdate path
        try sut.setToken("integration-test-token-v2", forKey: "k")
        XCTAssertEqual(sut.token(forKey: "k"), "integration-test-token-v2")

        // Delete via setToken(nil)
        try sut.setToken(nil, forKey: "k")
        XCTAssertNil(sut.token(forKey: "k"))
    }

    // MARK: - Throwing read API (regression for C1 review finding)

    /// `loadToken(forKey:)` MUST distinguish "no entry" from "lookup
    /// failed" — without that distinction every transient Keychain error
    /// silently sends requests unauthenticated and the user can't tell
    /// whether to add a token or unlock Keychain.
    func testInMemory_loadToken_legitimateAbsence_returnsNilNoThrow() throws {
        let sut = InMemorySecureTokenStorage()
        XCTAssertNil(try sut.loadToken(forKey: "absent"))
    }

    func testInMemory_loadToken_existingEntry_returnsValue() throws {
        let sut = InMemorySecureTokenStorage(initial: ["k": "abc"])
        XCTAssertEqual(try sut.loadToken(forKey: "k"), "abc")
    }

    func testInMemory_loadToken_throwsWhenReadErrorInjected() {
        let sut = InMemorySecureTokenStorage(initial: ["k": "abc"])
        sut.readError = .unhandled(-25308) // errSecInteractionNotAllowed
        XCTAssertThrowsError(try sut.loadToken(forKey: "k")) { error in
            guard let kc = error as? KeychainError else {
                XCTFail("Expected KeychainError, got \(error)"); return
            }
            XCTAssertEqual(kc, .unhandled(-25308))
        }
    }

    /// The non-throwing convenience extension MUST swallow real failures
    /// (returning `nil`) so hot-path resolvers don't have to wrap every
    /// call in try?. Settings UI surfaces use the throwing variant
    /// directly to surface the failure.
    func testInMemory_token_nonThrowingShim_returnsNilOnReadError() {
        let sut = InMemorySecureTokenStorage(initial: ["k": "abc"])
        sut.readError = .unhandled(-25308)
        XCTAssertNil(sut.token(forKey: "k"))
    }

    func testKeychainError_localizedDescription_pointsUserAtKeychainAccess() {
        let err = KeychainError.unhandled(-25308)
        XCTAssertTrue(err.localizedDescription.contains("Keychain"),
                      "User-facing message must mention Keychain.")
        XCTAssertTrue(err.localizedDescription.contains("-25308"),
                      "Status code must be in the message for diagnosis.")
    }

    func testKeychainError_invalidUTF8_pointsUserAtRecoveryStep() {
        let err = KeychainError.invalidUTF8
        XCTAssertTrue(err.localizedDescription.lowercased().contains("re-enter")
            || err.localizedDescription.lowercased().contains("re enter"))
    }
}
