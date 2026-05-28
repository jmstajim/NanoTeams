import Foundation

/// Shared lifecycle helper for the four LM Studio API-token SecureField
/// surfaces (`LLMSettingsView`, `VisionSettingsView`,
/// `ExploratorySearchEmbeddingsCard`, `RoleEditorLLMTab`). Each surface owns
/// its own `@State var apiToken: String`; this helper centralizes the
/// "load on appear / URL change" and "save on edit, skipping no-op writes"
/// semantics so all four surfaces behave identically — and so the lifecycle
/// is unit-testable without mounting SwiftUI.
///
/// Implemented as a struct that owns its `SecureTokenStorage` so call sites
/// don't have to thread the storage parameter into every helper invocation.
/// Tests substitute `InMemorySecureTokenStorage` for hermetic runs.
nonisolated struct LLMTokenFieldPersistence {

    let storage: any SecureTokenStorage

    init(storage: any SecureTokenStorage = KeychainSecureTokenStorage()) {
        self.storage = storage
    }

    /// Reads the stored token. Returns `""` for "no entry" (legitimate
    /// absence). Throws `KeychainError` on real read failures — locked
    /// Keychain (`errSecInteractionNotAllowed`), ACL denied, corrupt UTF-8 —
    /// so the UI can banner the failure instead of leaving the user
    /// wondering why every request 401s.
    func loadToken(forBaseURL baseURL: String) throws -> String {
        let key = KeychainSecureTokenStorage.normalize(baseURL: baseURL)
        return try storage.loadToken(forKey: key) ?? ""
    }

    /// Best-effort variant for SwiftUI bindings that have nowhere to
    /// surface a thrown error directly. Real read failures are reported
    /// via the `onReadError` callback so the parent can route to a
    /// banner; the function still returns `""` so the SecureField stays
    /// editable (otherwise the user can't overwrite the bad entry).
    func loadToken(
        forBaseURL baseURL: String,
        onReadError: ((Error) -> Void)?
    ) -> String {
        do {
            return try loadToken(forBaseURL: baseURL)
        } catch {
            onReadError?(error)
            return ""
        }
    }

    /// Writes `newValue` for `baseURL`. Returns `true` when storage was
    /// actually touched, `false` when the call was a no-op (existing value
    /// matched). The no-op skip keeps `onAppear` reloads from churning the
    /// Keychain on every panel open.
    ///
    /// Empty / whitespace-only `newValue` deletes the entry — the storage
    /// implementation does the trimming + delete in one place.
    ///
    /// Throws on Keychain write failure (e.g. locked / corrupted) so the UI
    /// can surface the error instead of silently losing the user's typed
    /// token. **Crucially also forces a write attempt when the read for
    /// the no-op-skip equality check itself fails** — without this, a
    /// transient read failure could mask a user-initiated clear (`""` typed
    /// over a stale `""` read) and leave the old token resident.
    @discardableResult
    func saveTokenIfChanged(
        _ newValue: String,
        forBaseURL baseURL: String
    ) throws -> Bool {
        let key = KeychainSecureTokenStorage.normalize(baseURL: baseURL)
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Best-effort read for the equality short-circuit. If the read
        // throws, we treat it as "unknown" and fall through to a write
        // attempt — that way a locked-Keychain hiccup can never silently
        // suppress a user-initiated clear or update.
        let existing: String?
        do {
            existing = try storage.loadToken(forKey: key)
        } catch {
            existing = nil
        }
        if let existing, existing == trimmed { return false }
        try storage.setToken(newValue, forKey: key)
        return true
    }

    // MARK: - Static back-compat shims (used by older test files)

    /// Back-compat: existing tests call `LLMTokenFieldPersistence.loadToken(forBaseURL:storage:)`
    /// as a static method. Forwards to an instance and swallows real
    /// read failures into `""` (back-compat tests never check for them).
    static func loadToken(
        forBaseURL baseURL: String,
        storage: any SecureTokenStorage
    ) -> String {
        Self(storage: storage).loadToken(forBaseURL: baseURL, onReadError: nil)
    }

    /// Back-compat: throwing variant. Returns `false` instead of throwing if
    /// the caller doesn't want the error (older `try?` call sites).
    @discardableResult
    static func saveTokenIfChanged(
        _ newValue: String,
        forBaseURL baseURL: String,
        storage: any SecureTokenStorage
    ) -> Bool {
        do {
            return try Self(storage: storage).saveTokenIfChanged(newValue, forBaseURL: baseURL)
        } catch {
            #if DEBUG
            print("[LLMTokenFieldPersistence] write failed: \(error)")
            #endif
            return false
        }
    }
}
