import XCTest

@testable import NanoTeams

/// Drives the load / save lifecycle that all four LM Studio API-token
/// SecureField surfaces share. Each test corresponds to a real user gesture.
/// If any of these fail, the corresponding UX flow is broken (token not
/// loaded on open, lost on URL switch, persisted twice on every keystroke,
/// etc.).
final class LLMTokenFieldPersistenceTests: XCTestCase {

    // MARK: - Open the panel — load the token for the current URL

    func testLoadToken_emptyStorage_returnsEmpty() {
        let storage = InMemorySecureTokenStorage()
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://x:1", storage: storage),
            ""
        )
    }

    func testLoadToken_existingEntry_returnsValue() throws {
        let storage = InMemorySecureTokenStorage()
        try storage.setToken(
            "tok",
            forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://x:1")
        )
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://x:1", storage: storage),
            "tok"
        )
    }

    func testLoadToken_normalizesURLBeforeLookup() throws {
        let storage = InMemorySecureTokenStorage()
        try storage.setToken(
            "tok",
            forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://x:1")
        )
        // User typed a URL with trailing slash + uppercase; load must still hit.
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "HTTP://X:1/", storage: storage),
            "tok"
        )
    }

    // MARK: - Edit the field — save under the current URL

    func testSaveToken_writesNewValue() {
        let storage = InMemorySecureTokenStorage()
        let didWrite = LLMTokenFieldPersistence.saveTokenIfChanged(
            "tok-1", forBaseURL: "http://x:1", storage: storage
        )
        XCTAssertTrue(didWrite)
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://x:1", storage: storage),
            "tok-1"
        )
    }

    func testSaveToken_idempotent_returnsFalseOnSecondIdenticalSave() {
        let storage = InMemorySecureTokenStorage()
        XCTAssertTrue(
            LLMTokenFieldPersistence.saveTokenIfChanged(
                "tok", forBaseURL: "http://x:1", storage: storage)
        )
        // Calling save again with the same value (e.g. onAppear → reload →
        // onChange-token fires with the just-loaded value) must be a no-op.
        XCTAssertFalse(
            LLMTokenFieldPersistence.saveTokenIfChanged(
                "tok", forBaseURL: "http://x:1", storage: storage)
        )
    }

    func testSaveToken_treatsTrailingWhitespaceAsNoChange() {
        // `SecureTokenStorage.setToken` trims before persisting. The skip
        // logic must compare against the trimmed view; otherwise typing a
        // trailing space (then having SwiftUI trim it elsewhere) would loop.
        let storage = InMemorySecureTokenStorage()
        XCTAssertTrue(
            LLMTokenFieldPersistence.saveTokenIfChanged(
                "tok", forBaseURL: "http://x:1", storage: storage)
        )
        XCTAssertFalse(
            LLMTokenFieldPersistence.saveTokenIfChanged(
                "tok ", forBaseURL: "http://x:1", storage: storage)
        )
        XCTAssertFalse(
            LLMTokenFieldPersistence.saveTokenIfChanged(
                "  tok\n", forBaseURL: "http://x:1", storage: storage)
        )
    }

    func testSaveToken_emptyValue_deletesEntry() throws {
        let storage = InMemorySecureTokenStorage()
        try storage.setToken("tok", forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://x:1"))

        // User taps the Clear (×) button.
        let didWrite = LLMTokenFieldPersistence.saveTokenIfChanged(
            "", forBaseURL: "http://x:1", storage: storage
        )
        XCTAssertTrue(didWrite)
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://x:1", storage: storage),
            ""
        )
    }

    func testSaveToken_whitespaceOnlyValue_deletesEntry() throws {
        let storage = InMemorySecureTokenStorage()
        try storage.setToken("tok", forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://x:1"))

        XCTAssertTrue(
            LLMTokenFieldPersistence.saveTokenIfChanged(
                "   \n\t  ", forBaseURL: "http://x:1", storage: storage)
        )
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://x:1", storage: storage),
            ""
        )
    }

    // MARK: - Full UX flow simulations

    func testFlow_openPanel_typeToken_close_reopen_seesToken() {
        let storage = InMemorySecureTokenStorage()
        let url = "http://localhost:1234"

        // 1. User opens Settings → LLM. View calls reloadToken on appear.
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: url, storage: storage),
            "",
            "First open: no token yet."
        )
        // 2. User types "abc". onChange fires per character; final state = "abc".
        for partial in ["a", "ab", "abc"] {
            LLMTokenFieldPersistence.saveTokenIfChanged(
                partial, forBaseURL: url, storage: storage)
        }
        // 3. User dismisses settings. State discarded.
        // 4. User reopens settings. View calls reloadToken on appear.
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: url, storage: storage),
            "abc",
            "Reopened panel must show the persisted token."
        )
    }

    func testFlow_changeURL_loadsFreshTokenForNewURL_doesNotLeakOldToken() throws {
        let storage = InMemorySecureTokenStorage()
        try storage.setToken(
            "tok-A", forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://server-a:1"))
        try storage.setToken(
            "tok-B", forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://server-b:2"))

        // User has the LLM card open on server-a.
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://server-a:1", storage: storage),
            "tok-A"
        )

        // User edits the URL field to server-b. View's onChange(of: url) fires
        // → reloadToken runs against the new URL.
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://server-b:2", storage: storage),
            "tok-B"
        )

        // User edits URL to server-c (no token stored).
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://server-c:3", storage: storage),
            "",
            "Switching to a fresh URL must NOT inherit the previous URL's token."
        )

        // After switching back to server-a, the token is intact.
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://server-a:1", storage: storage),
            "tok-A",
            "Round-tripping URL changes must not lose any URL's stored token."
        )
    }

    func testFlow_clearViaClearButton_thenTypeAgain_persistsNewValue() {
        let storage = InMemorySecureTokenStorage()
        let url = "http://x:1"

        // User types initial token.
        LLMTokenFieldPersistence.saveTokenIfChanged("first", forBaseURL: url, storage: storage)
        // User taps × Clear.
        LLMTokenFieldPersistence.saveTokenIfChanged("", forBaseURL: url, storage: storage)
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: url, storage: storage), "")
        // User types a second token.
        LLMTokenFieldPersistence.saveTokenIfChanged("second", forBaseURL: url, storage: storage)
        XCTAssertEqual(
            LLMTokenFieldPersistence.loadToken(forBaseURL: url, storage: storage),
            "second"
        )
    }

    // MARK: - Read-failure surfacing (regression for C1/C2 review findings)

    /// When `errSecItemNotFound` returns `nil` the field should silently
    /// stay empty — that's a legitimate "no token saved" state, not an error
    /// the user needs to know about.
    func testLoadToken_throwingAPI_returnsEmptyForLegitimateAbsence() throws {
        let storage = InMemorySecureTokenStorage()
        let sut = LLMTokenFieldPersistence(storage: storage)
        let value = try sut.loadToken(forBaseURL: "http://no-entry:1")
        XCTAssertEqual(value, "")
    }

    /// When the storage layer throws (locked Keychain, ACL denied, corrupt
    /// entry) the throwing API must propagate the error so callers can
    /// banner it. Without this distinction every transient lookup looks
    /// like "no token" and the user 401-loops forever.
    func testLoadToken_throwingAPI_propagatesRealReadFailure() {
        let storage = InMemorySecureTokenStorage()
        storage.readError = .unhandled(-25308) // errSecInteractionNotAllowed
        let sut = LLMTokenFieldPersistence(storage: storage)

        XCTAssertThrowsError(try sut.loadToken(forBaseURL: "http://locked:1")) { error in
            guard let kc = error as? KeychainError else {
                XCTFail("Expected KeychainError, got \(error)"); return
            }
            XCTAssertEqual(kc, .unhandled(-25308))
        }
    }

    /// The non-throwing variant routes the error to `onReadError` and still
    /// returns `""` so the SecureField stays editable (user can re-enter
    /// the token to overwrite the stuck entry).
    func testLoadToken_onReadErrorVariant_invokesCallback_andReturnsEmpty() {
        let storage = InMemorySecureTokenStorage()
        storage.readError = .unhandled(-25300) // errSecItemNotFound (we still test path)
        // Use a real fault: locked Keychain
        storage.readError = .unhandled(-25308)
        let sut = LLMTokenFieldPersistence(storage: storage)

        var capturedError: Error?
        let value = sut.loadToken(forBaseURL: "http://locked:1") { capturedError = $0 }

        XCTAssertEqual(value, "", "Field must stay editable so user can overwrite the bad entry.")
        XCTAssertNotNil(capturedError, "Read failure must propagate to the callback.")
    }

    /// When the equality-check read for the no-op skip throws, save MUST
    /// fall through to a write attempt — otherwise a transient Keychain
    /// lock could mask a user-initiated clear (typing `""` over a stale
    /// `""` read), leaving the old token resident.
    func testSaveTokenIfChanged_readFailureForcesWrite_doesNotSilentlyShortCircuit() throws {
        let storage = InMemorySecureTokenStorage()
        let sut = LLMTokenFieldPersistence(storage: storage)
        // First save the real token.
        XCTAssertTrue(try sut.saveTokenIfChanged("real-token", forBaseURL: "http://x:1"))
        // Storage now has the token. Simulate transient read failure.
        storage.readError = .unhandled(-25308)
        // User types "" to clear. Without the fall-through fix, the stale
        // `existing == ""` from the failed read would equal the trimmed `""`
        // and the delete would be skipped.
        let didWrite = try sut.saveTokenIfChanged("", forBaseURL: "http://x:1")
        XCTAssertTrue(
            didWrite,
            "Read failure must force a write attempt — otherwise a locked-Keychain "
                + "hiccup masks the user's clear and leaves the old token resident."
        )
        // Recover the storage; the entry should be gone.
        storage.readError = nil
        XCTAssertEqual(try sut.loadToken(forBaseURL: "http://x:1"), "")
    }

    func testFlow_reloadOnAppear_isAlwaysNoOp_whenStorageIsUnchanged() {
        // Simulates: user opens settings, the view immediately fires onAppear
        // (reloadToken) which sets `apiToken = stored`, which in turn fires
        // onChange(of: apiToken) → saveToken(stored). That cycle MUST detect
        // the no-op and skip the write, otherwise we churn the Keychain on
        // every panel open.
        let storage = InMemorySecureTokenStorage()
        try? storage.setToken(
            "tok", forKey: KeychainSecureTokenStorage.normalize(baseURL: "http://x:1"))

        // First "appear" cycle.
        let loaded = LLMTokenFieldPersistence.loadToken(forBaseURL: "http://x:1", storage: storage)
        let didWrite = LLMTokenFieldPersistence.saveTokenIfChanged(
            loaded, forBaseURL: "http://x:1", storage: storage
        )
        XCTAssertFalse(didWrite, "onAppear-then-onChange must NOT write when nothing changed.")

        // Second cycle.
        let didWrite2 = LLMTokenFieldPersistence.saveTokenIfChanged(
            LLMTokenFieldPersistence.loadToken(forBaseURL: "http://x:1", storage: storage),
            forBaseURL: "http://x:1", storage: storage
        )
        XCTAssertFalse(didWrite2)
    }
}
