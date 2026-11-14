import Foundation
import Security

/// Stores opaque secrets (LM Studio bearer tokens, MCP server secrets) so they never enter
/// UserDefaults, JSON files, or any Codable surface. The protocol is the DIP seam: production
/// uses `KeychainSecureTokenStorage`; tests substitute `InMemorySecureTokenStorage`
/// because GitHub Actions macOS runners can refuse Keychain access.
///
/// Keying contract, per service: LM Studio's `key` is a normalized base URL (lowercase,
/// trailing slash trimmed) — see `KeychainSecureTokenStorage.normalize(baseURL:)`. One server →
/// one entry, regardless of which app surface (chat / vision / embedding / per-role override)
/// reads it. The MCP service keys every account by its server's id and then the origin the
/// value was entered for (`<id>/<origin>/…`, `MCPServerConfig.originAccountPrefix`): the id
/// alone (`secretAccountPrefix`) makes `accountNames(withPrefix:)` a server's whole list, and
/// the empty prefix the whole service's — what the MCP launch sweep reads. The two services
/// never list each other's accounts: a listing is scoped to its own service.
protocol SecureTokenStorage: Sendable {
    nonisolated func setToken(_ token: String?, forKey key: String) throws

    /// Reads the stored token. Returns `nil` ONLY for legitimate absence
    /// (`errSecItemNotFound`). Throws on real Keychain failures (locked,
    /// ACL denied, corrupt UTF-8) so the caller can distinguish "no token"
    /// from "lookup unavailable" — without that distinction, every
    /// transient lookup error silently sends the request unauthenticated
    /// and the user sees a 401 banner even though they configured a token.
    nonisolated func loadToken(forKey key: String) throws -> String?

    /// The account names stored under `prefix`, sorted — NAMES only: no value is read, so an
    /// entry whose bytes cannot be decoded is listed like any other. `[]` when there are none;
    /// throws on a real Keychain failure, as `loadToken` does.
    ///
    /// No default: a conformer that forgot it would list nothing, and whatever reads the list
    /// to clear a server's accounts would silently leave them behind.
    nonisolated func accountNames(withPrefix prefix: String) throws -> [String]
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

enum KeychainError: Error, LocalizedError, Equatable {
    case unhandled(OSStatus)
    case invalidUTF8

    /// `LocalizedError` conformance is load-bearing, not decoration. A bare
    /// `var localizedDescription` on an `Error` type is reached by STATIC
    /// dispatch only; every consumer here catches the error as `any Error`
    /// (`LLMTokenField.onLoadError` is typed `((Error) -> Void)?`, and six
    /// settings views spell `"…: \(error.localizedDescription)"`). Through
    /// the existential Swift falls back to `NSError` bridging and renders
    /// "The operation couldn't be completed. (NanoTeams.KeychainError error 0.)"
    /// — losing both the OSStatus and the remedy. Routing through
    /// `errorDescription` is what makes the message survive the box.
    var errorDescription: String? { localizedDescription }

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

        let addQuery = KeychainQuery.add(service: service, account: key, data: data)
        switch KeychainStatus.write(SecItemAdd(addQuery as CFDictionary, nil)) {
        case .stored:
            return
        case .needsUpdate:
            let match = KeychainQuery.identity(service: service, account: key)
            let attrs = KeychainQuery.updateAttributes(data: data)
            let status = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
            if case .failed(let code) = KeychainStatus.update(status) {
                throw KeychainError.unhandled(code)
            }
        case .failed(let code):
            throw KeychainError.unhandled(code)
        }
    }

    /// Every account of this service, by attribute — no value is read — cut to `prefix` (the
    /// empty one keeps them all). The Keychain cannot match an account by prefix, so the
    /// service's accounts are listed and filtered here; each service holds one kind of secret,
    /// so the list is that kind's — the MCP sweep never sees an LM Studio token.
    func accountNames(withPrefix prefix: String) throws -> [String] {
        let query = KeychainQuery.list(service: service)
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch KeychainStatus.read(status) {
        case .found:
            return try Self.accountNames(in: items, status: status, withPrefix: prefix)
        case .absent:
            return []
        case .failed(let code):
            throw KeychainError.unhandled(code)
        }
    }

    func loadToken(forKey key: String) throws -> String? {
        let query = KeychainQuery.load(service: service, account: key)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch KeychainStatus.read(status) {
        case .found:
            return try Self.decodeToken(item, status: status)
        case .absent:
            return nil
        case .failed(let code):
            throw KeychainError.unhandled(code)
        }
    }

    /// Turns a successful `SecItemCopyMatching` payload into the token.
    ///
    /// Split out and `static` so both failure arms are reachable without a Keychain: a
    /// non-`Data` payload (a `kSecMatchLimitOne` regression would hand back a CFArray)
    /// and bytes that are not UTF-8 map to DIFFERENT errors, and only the second tells
    /// the user the actionable thing — re-enter the token to overwrite the bad entry.
    static func decodeToken(_ item: CFTypeRef?, status: OSStatus) throws -> String {
        guard let data = item as? Data else {
            throw KeychainError.unhandled(status)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidUTF8
        }
        return string
    }

    /// Turns a successful listing into the account names under `prefix`, sorted. Split out and
    /// `static` for the reason `decodeToken` is: anything but an array of attribute dictionaries
    /// is a lookup problem (`.unhandled`), not "no accounts", and that arm is reachable only
    /// without a Keychain.
    static func accountNames(in items: CFTypeRef?, status: OSStatus, withPrefix prefix: String) throws -> [String] {
        guard let rows = items as? [[String: Any]] else {
            throw KeychainError.unhandled(status)
        }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    private func delete(key: String) throws {
        let query = KeychainQuery.delete(service: service, account: key)
        let outcome = KeychainStatus.delete(SecItemDelete(query as CFDictionary))
        if case .failed(let code) = outcome {
            throw KeychainError.unhandled(code)
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
        if let injectedError = _writeFailure?(key, token) {
            throw injectedError
        }
        corrupt.remove(key)
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
        if corrupt.contains(key) { throw KeychainError.invalidUTF8 }
        return tokens[key]
    }

    func accountNames(withPrefix prefix: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let injectedError = _readError {
            throw injectedError
        }
        return Set(tokens.keys).union(corrupt).filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// Test hook: stores an entry under `key` whose bytes are not UTF-8, as a real Keychain can
    /// hold one — `loadToken` throws `.invalidUTF8` for it, `accountNames` lists it, and a write
    /// or a delete replaces it.
    func storeCorruptEntry(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        tokens.removeValue(forKey: key)
        corrupt.insert(key)
    }
    private var corrupt: Set<String> = []

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

    /// Test hook: asked before every `setToken` — a write when `token` is non-nil, a delete when
    /// it is nil — and the error it returns is thrown instead of the write. Per key and per
    /// kind, because what a save does after ONE refused write (an ACL on one account, a
    /// Keychain locked between two writes) is the thing worth testing, and a hook that failed
    /// every write could not show it.
    var writeFailure: (@Sendable (_ key: String, _ token: String?) -> KeychainError?)? {
        get { lock.lock(); defer { lock.unlock() }; return _writeFailure }
        set { lock.lock(); defer { lock.unlock() }; _writeFailure = newValue }
    }
    private var _writeFailure: (@Sendable (_ key: String, _ token: String?) -> KeychainError?)?
}
#endif
