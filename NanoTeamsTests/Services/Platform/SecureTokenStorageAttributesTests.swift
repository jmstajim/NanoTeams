import XCTest
import Security

@testable import NanoTeams

/// Pins the load-bearing Keychain attribute set documented in CLAUDE.md
/// "LM Studio Authentication". Behavioral round-trip tests pass even if a
/// future refactor silently drops `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// (Keychain default `WhenUnlocked` would silently break background readability)
/// or flips `kSecAttrSynchronizable` to `true` (token starts iCloud-syncing —
/// off-device leak vector).
///
/// macOS Keychain's `SecItemCopyMatching(... kSecReturnAttributes: true)` does
/// NOT echo `kSecAttrAccessible` (`pdmn`) in the returned dict — only the
/// basic attributes (`acct`, `cdat`, `class`, `labl`, `mdat`, `svce`). So the
/// tests here use the attribute as a **search filter** instead of a read-back:
/// if the stored entry's `kSecAttrAccessible` is anything other than
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, the filtered query
/// returns `errSecItemNotFound`, which fails the test. Same idea for
/// `kSecAttrSynchronizable=false`: the production storage's read query already
/// filters on it, so a regression to `synchronizable=true` would make
/// `KeychainSecureTokenStorage.token(forKey:)` silently return nil — that's
/// behaviorally pinned by `SecureTokenStorageTests.testKeychain_roundTrip_underUniqueService`.
final class SecureTokenStorageAttributesTests: XCTestCase {

    // MARK: - Service constant pin

    /// `kSecAttrService` is the global namespace under which all NanoTeams LM
    /// Studio tokens live. A rename without migration would orphan every
    /// installed user's token. Pin the literal so the rename is visible.
    func testDefaultService_literalIsPinned() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.defaultService,
            "com.nanoteams.lmstudio.bearer.v1",
            "kSecAttrService rename without migration would orphan every "
                + "installed user's saved token. If you intentionally bumped to "
                + ".v2, also add a migration that re-keys existing items."
        )
    }

    // MARK: - kSecAttrAccessible search-filter assertions

    /// After a fresh `SecItemAdd`, the entry must carry
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Verified by
    /// querying with that attribute as a search filter — if the stored
    /// attribute is anything else, the query returns `errSecItemNotFound`.
    func testAdd_isFindableByAccessibleAfterFirstUnlockThisDeviceOnly() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let service = "com.nanoteams.tests.attrs.\(UUID().uuidString)"
        let sut = KeychainSecureTokenStorage(service: service)
        let key = "http://127.0.0.1:1234"
        defer { try? sut.setToken(nil, forKey: key) }

        do {
            try sut.setToken("attr-test-token", forKey: key)
        } catch KeychainError.unhandled(let status)
            where status == errSecMissingEntitlement
                || status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
        {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }

        try assertEntryIsFindableWithAccessibleFilter(
            service: service, account: key,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    // MARK: - Idempotent overwrite preserves the attribute

    /// `errSecDuplicateItem` → `SecItemUpdate` path must keep the same
    /// `kSecAttrAccessible`. A regression to delete-then-add could lose
    /// attribute continuity (e.g. write a v2 with default Accessible).
    func testOverwrite_preservesAccessibleAttribute() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let service = "com.nanoteams.tests.attrs.\(UUID().uuidString)"
        let sut = KeychainSecureTokenStorage(service: service)
        let key = "http://127.0.0.1:1234"
        defer { try? sut.setToken(nil, forKey: key) }

        do {
            try sut.setToken("v1", forKey: key)
        } catch KeychainError.unhandled(let status)
            where status == errSecMissingEntitlement
                || status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
        {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
        try sut.setToken("v2", forKey: key)
        XCTAssertEqual(sut.token(forKey: key), "v2")

        // After update, the attribute must still match the production filter.
        try assertEntryIsFindableWithAccessibleFilter(
            service: service, account: key,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    // MARK: - Helpers

    private func assertEntryIsFindableWithAccessibleFilter(
        service: String,
        account: String,
        accessible: CFString,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String: accessible,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecMissingEntitlement
            || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
        {
            throw XCTSkip("Keychain filter query refused (status \(status)).")
        }
        XCTAssertEqual(
            status, errSecSuccess,
            "Entry must be findable by kSecAttrAccessible filter \(accessible). "
                + "Status \(status) means the stored attribute is something else — regression.",
            file: file, line: line
        )
        XCTAssertNotNil(item, file: file, line: line)
    }

}
