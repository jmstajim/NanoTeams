import Foundation
import Security

// MARK: - Keychain Query Construction

/// The `SecItem*` query dictionaries and status mapping behind
/// `KeychainSecureTokenStorage`, split out because they are the security-bearing half
/// and the only half that can be verified.
///
/// The attribute choices carry real guarantees and nothing pinned them:
/// `kSecAttrSynchronizable = false` plus
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` are what keep a bearer token off
/// iCloud Keychain and out of a Time Machine restore. Dropping either compiles, stores
/// the token, reads it back, and passes every behavioural test — while syncing the
/// user's credential to every device on their Apple ID. A dictionary literal is exactly
/// the shape where that goes unnoticed.
///
/// Deliberately NOT an attempt to seam the Keychain itself: `SecItemAdd` and friends are
/// left in `KeychainSecureTokenStorage`, which stays uncovered, because a fake that
/// returned the statuses `KeychainStatus` already classifies would assert a tautology.
/// CI runners can refuse Keychain access (`InMemorySecureTokenStorage` exists for that
/// reason), so driving the real API from tests is not an option either.
nonisolated enum KeychainQuery {

    /// Identity of one stored token: class, service scope, account, and the
    /// no-sync assertion. Shared by add, update-match, load, and delete so the four
    /// cannot disagree about which item they address — a divergence here would strand
    /// every previously stored token behind a key nothing looks up.
    static func identity(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    /// Insert query: identity plus the payload and the accessibility class.
    static func add(service: String, account: String, data: Data) -> [String: Any] {
        var query = identity(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    /// Attributes for the `errSecDuplicateItem` update path. Only the payload and the
    /// accessibility class — update preserves everything it is not given, which is why
    /// add-or-update is idempotent rather than delete-then-add.
    static func updateAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    /// Read query: identity plus "return the bytes, exactly one match".
    ///
    /// `kSecMatchLimitOne` is what makes the `item as? Data` cast in the caller sound —
    /// with `kSecMatchLimitAll` the result is a `CFArray` and the cast fails, which the
    /// caller reports as a Keychain failure rather than the programming error it is.
    static func load(service: String, account: String) -> [String: Any] {
        var query = identity(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// Delete query — identity alone.
    static func delete(service: String, account: String) -> [String: Any] {
        identity(service: service, account: account)
    }
}

// MARK: - Status Classification

/// What an `OSStatus` from a `SecItem*` call means for the caller.
///
/// The three call sites read the same status space differently, and the differences are
/// load-bearing rather than incidental:
/// - `errSecDuplicateItem` on an insert is not a failure, it is the update path.
/// - `errSecItemNotFound` on a read is legitimate absence, and on a delete it is
///   success. Everywhere else it would be a failure.
///
/// That absence-versus-failure split is the whole reason `loadToken` returns
/// `String?` AND throws: `LLMTokenField` surfaces a throw as a banner so a locked
/// Keychain is distinguishable from a token the user never saved. Collapse the two and
/// a transient lookup error sends the request unauthenticated and the user sees a 401
/// they cannot explain.
nonisolated enum KeychainStatus {

    /// Outcome of an insert.
    enum WriteOutcome: Equatable {
        case stored
        /// The item exists — retry as an update.
        case needsUpdate
        case failed(OSStatus)
    }

    /// Outcome of a read.
    enum ReadOutcome: Equatable {
        case found
        /// No entry for this key. NOT an error.
        case absent
        case failed(OSStatus)
    }

    /// Outcome of a delete. `alreadyAbsent` is a success: `setToken(nil)` deleting a key
    /// that was never stored is the ordinary "user cleared an empty field" case.
    enum DeleteOutcome: Equatable {
        case removed
        case alreadyAbsent
        case failed(OSStatus)
    }

    static func write(_ status: OSStatus) -> WriteOutcome {
        switch status {
        case errSecSuccess: return .stored
        case errSecDuplicateItem: return .needsUpdate
        default: return .failed(status)
        }
    }

    static func read(_ status: OSStatus) -> ReadOutcome {
        switch status {
        case errSecSuccess: return .found
        case errSecItemNotFound: return .absent
        default: return .failed(status)
        }
    }

    static func delete(_ status: OSStatus) -> DeleteOutcome {
        switch status {
        case errSecSuccess: return .removed
        case errSecItemNotFound: return .alreadyAbsent
        default: return .failed(status)
        }
    }

    /// Two-state outcome for a call that has no legitimate non-success status.
    enum PlainOutcome: Equatable {
        case ok
        case failed(OSStatus)
    }

    /// The update leg of add-or-update: no `needsUpdate` to fall back to and no absence
    /// to tolerate (we only get here because the item exists), so anything other than
    /// success is a failure. Named rather than inlined so the asymmetry with `write` is
    /// visible — an update that treated `errSecDuplicateItem` as success would silently
    /// keep the OLD token after the user typed a new one.
    static func update(_ status: OSStatus) -> PlainOutcome {
        status == errSecSuccess ? .ok : .failed(status)
    }
}
