import Foundation
import Security

/// Stores opaque secrets (LM Studio bearer tokens) so they never enter UserDefaults,
/// JSON files, or any Codable surface. The protocol is the DIP seam: production
/// uses `KeychainSecureTokenStorage`; tests substitute `InMemorySecureTokenStorage`
/// because GitHub Actions macOS runners can refuse Keychain access.
///
/// Keying contract: `key` is a normalized base URL (lowercase, trailing slash
/// trimmed) — see `KeychainSecureTokenStorage.normalize(baseURL:)`. One server →
/// one entry, regardless of which app surface (chat / vision / embedding /
/// per-role override) reads it.
protocol SecureTokenStorage: Sendable {
    nonisolated func setToken(_ token: String?, forKey key: String) throws

    /// Reads the stored token. Returns `nil` ONLY for legitimate absence
    /// (`errSecItemNotFound`). Throws on real Keychain failures (locked,
    /// ACL denied, corrupt UTF-8) so the caller can distinguish "no token"
    /// from "lookup unavailable" — without that distinction, every
    /// transient lookup error silently sends the request unauthenticated
    /// and the user sees a 401 banner even though they configured a token.
    nonisolated func loadToken(forKey key: String) throws -> String?
}

nonisolated extension SecureTokenStorage {
    /// Best-effort lookup that swallows real failures into `nil`. Use only
    /// on hot paths that have nowhere to surface the error (e.g. HTTP
    /// request build). Settings UI surfaces must use `loadToken(forKey:)`
    /// directly so they can banner Keychain failures.
    func token(forKey key: String) -> String? {
        (try? loadToken(forKey: key)) ?? nil
    }
}

enum KeychainError: Error, Equatable {
    case unhandled(OSStatus)
    case invalidUTF8

    /// User-facing description for banner surfacing. Stable wording so tests
    /// can pin it.
    var localizedDescription: String {
        switch self {
        case .unhandled(let status):
            return "Keychain unavailable — couldn't read your saved token (OSStatus \(status)). Unlock Keychain Access or restart the app."
        case .invalidUTF8:
            return "Saved token is corrupt (invalid UTF-8). Re-enter the token to overwrite the bad entry."
        }
    }
}

/// Keychain Services-backed `SecureTokenStorage`.
///
/// Attribute choices (Apple guidance for an opaque background-readable token):
/// - `kSecClassGenericPassword` — opaque blob, not a credential pair.
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable by background
///   tasks (no user-presence prompt), device-bound (does not migrate via Time
///   Machine / iCloud restore), excluded from sync.
/// - `kSecAttrSynchronizable = false` — defense-in-depth alongside
///   `*ThisDeviceOnly` to keep the token off iCloud Keychain.
///
/// Add-or-update is idempotent via `errSecDuplicateItem` → `SecItemUpdate`
/// (preserves attributes; cleaner than delete+add).
nonisolated struct KeychainSecureTokenStorage: SecureTokenStorage {

    /// Service identifier scoping all NanoTeams LM Studio bearer tokens. The `.v1`
    /// suffix is here so a future schema break (e.g. salting the key) can ship
    /// without colliding with existing entries.
    static let defaultService = "com.nanoteams.lmstudio.bearer.v1"

    let service: String

    init(service: String = defaultService) {
        self.service = service
    }

    /// The Keychain account key for a server. Delegates to the shared
    /// `String.normalizedBaseURL` (which carries the "don't collapse
    /// `localhost`/`127.0.0.1`, don't collapse default ports" rationale) so
    /// this security-bearing key can never drift from the other normalizers —
    /// a divergence would strand every previously stored token.
    static func normalize(baseURL: String) -> String {
        baseURL.normalizedBaseURL
    }

    func setToken(_ token: String?, forKey key: String) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try delete(key: key)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.invalidUTF8
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandled(updateStatus)
            }
        default:
            throw KeychainError.unhandled(addStatus)
        }
    }

    func loadToken(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unhandled(status)
            }
            guard let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidUTF8
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    private func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}

#if DEBUG
/// Test impl. CI macOS runners may refuse Keychain access, so unit tests
/// inject this instead of touching the real Keychain.
nonisolated final class InMemorySecureTokenStorage: SecureTokenStorage, @unchecked Sendable {
    private var tokens: [String: String] = [:]
    private let lock = NSLock()

    init(initial: [String: String] = [:]) {
        self.tokens = initial
    }

    func setToken(_ token: String?, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            tokens.removeValue(forKey: key)
        } else {
            tokens[key] = trimmed
        }
    }

    func loadToken(forKey key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        // Read `_readError` directly — going through the public `readError`
        // property here would re-acquire `lock` and deadlock (NSLock is
        // not reentrant).
        if let injectedError = _readError {
            throw injectedError
        }
        return tokens[key]
    }

    /// Test hook: when non-nil, every `loadToken` call throws this. Lets
    /// concurrency / lifecycle tests simulate a locked Keychain without
    /// needing a real Keychain handle. Setter takes the lock once; reads
    /// inside `loadToken` use `_readError` directly to avoid recursive
    /// locking.
    var readError: KeychainError? {
        get { lock.lock(); defer { lock.unlock() }; return _readError }
        set { lock.lock(); defer { lock.unlock() }; _readError = newValue }
    }
    private var _readError: KeychainError?
}
#endif
