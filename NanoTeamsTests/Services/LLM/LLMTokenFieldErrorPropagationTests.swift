import XCTest

@testable import NanoTeams

/// User scenario: the user types an API token. The Keychain write fails (e.g.
/// device locked, sandbox surprise). The user must see "Could not save API
/// token: <reason>" in the error banner — not silently lose the token they
/// just typed and discover next session that everything 401s.
///
/// The error-banner wiring lives in each settings card's parent
/// (`LLMSettingsSheetView`, `VisionSettingsView`, `ExploratorySearchSettingsView`,
/// `RoleEditorSheet`, and — after the security review fix —
/// `GenerateTeamSettingsView`). Each parent passes
/// `onTokenSaveError: { store.lastErrorMessage = "Could not save API token: ..." }`
/// down to the relevant card, which forwards to `LLMTokenField.onSaveError`.
/// The field's `save()` catches the throw and invokes the callback.
///
/// This test pins the contract every layer in that chain depends on: the
/// persistence helper's *instance* `saveTokenIfChanged` MUST propagate
/// storage errors up so the field can route them to `onSaveError`. (The
/// static back-compat shim deliberately swallows errors with a debug print —
/// only used by older tests, no production callers.)
final class LLMTokenFieldErrorPropagationTests: XCTestCase {

    /// Test double that simulates a Keychain write failure (e.g.
    /// `errSecAuthFailed` or `errSecInteractionNotAllowed` when the user's
    /// keychain is locked).
    private final class FailingSecureTokenStorage: SecureTokenStorage, @unchecked Sendable {
        let writeError: Error
        var existingToken: String?
        var setTokenInvocations: Int = 0

        init(writeError: Error, existingToken: String? = nil) {
            self.writeError = writeError
            self.existingToken = existingToken
        }

        func setToken(_ token: String?, forKey key: String) throws {
            setTokenInvocations += 1
            throw writeError
        }

        func loadToken(forKey key: String) throws -> String? {
            existingToken
        }
    }

    // MARK: - Instance method propagates the error

    func testSaveTokenIfChanged_instance_propagatesStorageError() {
        let storage = FailingSecureTokenStorage(
            writeError: KeychainError.unhandled(errSecAuthFailed)
        )
        let sut = LLMTokenFieldPersistence(storage: storage)

        XCTAssertThrowsError(
            try sut.saveTokenIfChanged("typed-token", forBaseURL: "http://x:1")
        ) { error in
            // The error must surface as the same KeychainError the storage
            // threw — otherwise the error-banner message would be a generic
            // wrapped wrapper that hides the failure shape.
            guard case KeychainError.unhandled(let status) = error else {
                XCTFail("Expected KeychainError.unhandled, got \(error)"); return
            }
            XCTAssertEqual(status, errSecAuthFailed)
        }

        XCTAssertEqual(
            storage.setTokenInvocations, 1,
            "Storage must be called exactly once before throwing — no silent retry."
        )
    }

    /// Skip-write fast path: when the new value matches the stored value,
    /// the helper returns `false` WITHOUT calling `setToken`. Even with a
    /// failing storage, this path must not throw — otherwise reload's echo
    /// would surface phantom errors to the user.
    func testSaveTokenIfChanged_noOpWhenUnchanged_doesNotThrow() throws {
        let storage = FailingSecureTokenStorage(
            writeError: KeychainError.unhandled(errSecAuthFailed),
            existingToken: "tok"
        )
        let sut = LLMTokenFieldPersistence(storage: storage)

        let didWrite = try sut.saveTokenIfChanged("tok", forBaseURL: "http://x:1")
        XCTAssertFalse(didWrite)
        XCTAssertEqual(
            storage.setTokenInvocations, 0,
            "No-op path must NOT touch storage — that's the whole point of the skip."
        )
    }

    // MARK: - Callback invocation contract for LLMTokenField

    /// The field's `save()` body is `do { try persistence.saveTokenIfChanged(...) }
    /// catch { onSaveError?(error) }`. This test pins the callback shape: when
    /// the persistence throws, the captured callback is invoked with the same
    /// error. If a future refactor changes this to `try?` or wraps the error,
    /// the user banner stops showing.
    func testFieldStyleCatchPattern_invokesOnSaveErrorWithSameError() {
        // Reproduce the field's catch pattern locally so the contract is
        // pinned independently of SwiftUI mounting.
        let storage = FailingSecureTokenStorage(
            writeError: KeychainError.unhandled(errSecInteractionNotAllowed)
        )
        let persistence = LLMTokenFieldPersistence(storage: storage)

        var receivedError: Error?
        do {
            try persistence.saveTokenIfChanged("typed-token", forBaseURL: "http://x:1")
        } catch {
            receivedError = error
        }

        XCTAssertNotNil(
            receivedError,
            "Catch must observe the storage error — otherwise onSaveError fires with no signal."
        )
        if case KeychainError.unhandled(let status) = receivedError ?? KeychainError.invalidUTF8 {
            XCTAssertEqual(status, errSecInteractionNotAllowed)
        } else {
            XCTFail("Wrong error shape: \(String(describing: receivedError))")
        }
    }
}
