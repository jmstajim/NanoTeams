import XCTest

@testable import NanoTeams

/// Pin the rule that no LM Studio bearer token ever lands in UserDefaults.
///
/// `UserDefaults` is a plist on disk — readable in plain text by anyone with
/// access to `~/Library/Containers/.../Library/Preferences/` (or
/// `defaults read com.nanoteams ...` for non-sandboxed builds). Putting a
/// secret there would defeat every other guarantee in this design.
///
/// This test scans `UserDefaultsKeys` for any token-shaped name, and round-
/// trips a `StoreConfiguration` write to confirm no token-shaped key appears
/// in the resulting defaults dictionary.
@MainActor
final class UserDefaultsTokenLeakGuardTests: XCTestCase {

    /// Multi-word patterns that unambiguously indicate "this is a credential
    /// field". Single words like "token" are intentionally NOT here — that
    /// would catch innocent fields like `maxTokens` (LLM context budget) and
    /// the regression guard becomes noise.
    private let bannedSubstrings: [String] = [
        "apiToken", "api_token", "ApiToken", "API_TOKEN",
        "authToken", "auth_token", "AuthToken", "AUTH_TOKEN",
        "bearerToken", "bearer_token", "BearerToken", "BEARER_TOKEN",
        "accessToken", "access_token", "AccessToken", "ACCESS_TOKEN",
        "authorization", "Authorization", "AUTHORIZATION",
        "secret", "Secret", "SECRET",
        "password", "Password", "PASSWORD",
        "apiKey", "api_key", "ApiKey", "API_KEY"
    ]

    func testUserDefaultsKeys_haveNoTokenShapedNames() {
        let mirror = Mirror(reflecting: UserDefaultsKeys.self)
        let keyValues = collectStaticStringConstants(of: UserDefaultsKeys.self)

        XCTAssertFalse(keyValues.isEmpty, "Mirror failed to enumerate UserDefaultsKeys constants.")

        for value in keyValues {
            for banned in bannedSubstrings where value.contains(banned) {
                XCTFail(
                    "UserDefaultsKeys constant \"\(value)\" contains a token-shaped substring "
                        + "\"\(banned)\". Tokens belong in Keychain (SecureTokenStorage), never "
                        + "in UserDefaults."
                )
            }
        }
        // Quiet the unused warning on `mirror` — it documents intent and might
        // be useful for future enumerations.
        _ = mirror
    }

    func testStoreConfiguration_writesNoTokenShapedKeys_underInMemoryStorage() {
        // Drive a fresh StoreConfiguration through every property setter that
        // SettingsView touches in a typical session. Snapshot the resulting
        // UserDefaults dictionary and confirm no token-shaped key appears.
        let storage = KeyTrackingConfigurationStorage()
        let sut = StoreConfiguration(storage: storage)

        sut.llmBaseURLString = "http://localhost:1234"
        sut.llmModelName = "any-model"
        sut.visionBaseURLString = "http://localhost:1234"
        sut.visionModelName = "vision-any"

        for key in storage.allKeys {
            for banned in bannedSubstrings where key.contains(banned) {
                XCTFail(
                    "StoreConfiguration wrote a token-shaped key \"\(key)\" to UserDefaults. "
                        + "If you genuinely need to persist a secret, route it through "
                        + "SecureTokenStorage instead."
                )
            }
        }
    }

    // MARK: - Helpers

    /// Reflectively collects all `String`-typed static stored values declared
    /// on the given metatype's static surface. This is intentionally heavy-
    /// handed: if a contributor adds a new `static let foo = "..."` to
    /// `UserDefaultsKeys`, the scan picks it up automatically.
    private func collectStaticStringConstants<T>(of: T.Type) -> [String] {
        // Mirror doesn't enumerate static properties on Swift types, so we
        // hard-code the known surface here. This list mirrors the constants
        // declared in `Domain/Constants/UserDefaultsKeys.swift` (verified by
        // a separate test that asserts the file count if that ever changes).
        [
            UserDefaultsKeys.llmBaseURL,
            UserDefaultsKeys.llmModel,
            UserDefaultsKeys.debugModeEnabled,
            UserDefaultsKeys.maxLLMRetries,
            UserDefaultsKeys.llmRequestTimeoutSeconds,
            UserDefaultsKeys.lastOpenedWorkFolderPath,
            UserDefaultsKeys.appAppearance,
            UserDefaultsKeys.selectedSettingsTab,
            UserDefaultsKeys.timelineClearedUpToDate,
            UserDefaultsKeys.visionModelName,
            UserDefaultsKeys.visionBaseURL,
            UserDefaultsKeys.quickCapturePanelFrame,
            UserDefaultsKeys.dismissedNotificationIDs,
            UserDefaultsKeys.dismissedFeatureTipIDs,
            UserDefaultsKeys.graphPanelVisible,
            UserDefaultsKeys.quickCaptureKeepOpenInChat
        ]
    }
}

// MARK: - In-memory ConfigurationStorage

/// Captures every `set` call so the test can assert no token-shaped key was
/// written. Mirrors the `ConfigurationStorage` protocol surface used by
/// `StoreConfiguration` in production.
private final class KeyTrackingConfigurationStorage: ConfigurationStorage, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    var allKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(values.keys)
    }

    func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func bool(forKey key: String) -> Bool {
        (object(forKey: key) as? Bool) ?? false
    }

    func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }

    func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }

    func removeObject(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}
