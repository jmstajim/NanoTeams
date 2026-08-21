import Security
import XCTest

@testable import NanoTeams

/// Covers `KeychainQuery` and `KeychainStatus`, the security-bearing half of
/// `KeychainSecureTokenStorage`.
///
/// Every one of the four query dictionaries and all three status mappings was uncovered:
/// the real Keychain is off-limits from this suite (CI runners refuse access — that is why
/// `InMemorySecureTokenStorage` exists), so the only route to them was through
/// `SecItem*`. That left two classes of defect invisible:
///
/// 1. **Attribute drift.** `kSecAttrSynchronizable = false` and
///    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` are what keep a bearer token off
///    iCloud Keychain and out of a Time Machine restore. Drop either and the token still
///    stores, still reads back, and every behavioural test still passes — while syncing
///    the user's credential to every device on their Apple ID.
/// 2. **Status collapse.** `errSecItemNotFound` means "absent" on a read, "success" on a
///    delete, and "failure" nowhere. `LLMTokenField` depends on that split to tell a
///    locked Keychain from a token the user never saved; collapsed, a transient lookup
///    error sends the request unauthenticated and the user sees a 401 they configured a
///    token to prevent.
final class KeychainQueryCoverageTests: XCTestCase {

    private let service = "com.nanoteams.test.bearer"
    private let account = "http://127.0.0.1:1234"

    private func string(_ query: [String: Any], _ key: CFString) -> String? {
        query[key as String] as? String
    }

    // MARK: - Identity

    /// RED: drop the `kSecAttrSynchronizable` entry → the no-sync assertion fails. This is
    /// the single most consequential line in the file and nothing pinned it.
    func testIdentity_pinsClassServiceAccountAndNoSync() {
        let query = KeychainQuery.identity(service: service, account: account)

        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String,
                       "a bearer token is an opaque blob, not a credential pair")
        XCTAssertEqual(string(query, kSecAttrService), service)
        XCTAssertEqual(string(query, kSecAttrAccount), account)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false,
                       "synchronizable must be FALSE — true puts the token on iCloud "
                           + "Keychain and onto every device on the Apple ID")
    }

    /// All four queries must address the SAME item. A divergence would strand every
    /// previously stored token behind a key nothing looks up — and it would be silent,
    /// because a lookup miss is a legitimate "no token saved".
    ///
    /// RED: change any one builder's `kSecAttrService`/`kSecAttrAccount`/class → the
    /// matching subset assertion fails.
    func testEveryQueryAddressesTheSameItem() {
        let identity = KeychainQuery.identity(service: service, account: account)
        let queries: [(String, [String: Any])] = [
            ("add", KeychainQuery.add(service: service, account: account, data: Data("t".utf8))),
            ("load", KeychainQuery.load(service: service, account: account)),
            ("delete", KeychainQuery.delete(service: service, account: account))
        ]

        for (name, query) in queries {
            for (key, value) in identity {
                if let expected = value as? String {
                    XCTAssertEqual(query[key] as? String, expected,
                                   "\(name) disagrees with identity on \(key)")
                } else if let expected = value as? Bool {
                    XCTAssertEqual(query[key] as? Bool, expected,
                                   "\(name) disagrees with identity on \(key)")
                }
            }
        }
    }

    // MARK: - Add / update

    /// RED: drop `kSecAttrAccessible` from `add` → the accessibility assertion fails, and
    /// the item defaults to `WhenUnlocked`, which a background request cannot read.
    func testAdd_carriesThePayloadAndTheDeviceBoundAccessibility() {
        let data = Data("tok-1".utf8)
        let query = KeychainQuery.add(service: service, account: account, data: data)

        XCTAssertEqual(query[kSecValueData as String] as? Data, data)
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                       "AfterFirstUnlock so background requests can read it; "
                           + "ThisDeviceOnly so it does not migrate via a restore")
        XCTAssertNil(query[kSecReturnData as String],
                     "an insert must not ask for data back")
    }

    /// The update leg must carry ONLY the payload and the accessibility class: it is what
    /// makes add-or-update preserve everything else, which is the stated reason the code
    /// does not delete-then-add.
    ///
    /// RED: add `kSecAttrService` to `updateAttributes` → the key-set assertion fails.
    /// Passing an identity attribute as an attribute-to-CHANGE rewrites what the item is,
    /// not what it holds.
    func testUpdateAttributes_carriesOnlyWhatChanges() {
        let data = Data("tok-2".utf8)
        let attrs = KeychainQuery.updateAttributes(data: data)

        XCTAssertEqual(Set(attrs.keys),
                       Set([kSecValueData as String, kSecAttrAccessible as String]),
                       "update must not restate identity: \(attrs.keys.sorted())")
        XCTAssertEqual(attrs[kSecValueData as String] as? Data, data)
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                       "the accessibility class must be re-asserted on update too, or an "
                           + "item created by an older build keeps its weaker class forever")
    }

    // MARK: - Load

    /// `kSecMatchLimitOne` is what makes the caller's `item as? Data` cast sound. With
    /// `kSecMatchLimitAll` the result is a CFArray, the cast fails, and the caller reports
    /// a Keychain failure — a 401 banner for a programming error.
    ///
    /// RED: change to `kSecMatchLimitAll`, or drop `kSecReturnData` → the matching
    /// assertion fails.
    func testLoad_asksForExactlyOneItemsBytes() {
        let query = KeychainQuery.load(service: service, account: account)

        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true,
                       "without kSecReturnData the match returns attributes, not the token")
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String,
                       "MatchLimitAll returns a CFArray and breaks the caller's Data cast")
        XCTAssertNil(query[kSecValueData as String], "a read must not carry a payload")
        XCTAssertNil(query[kSecAttrAccessible as String],
                     "a read must not restate the accessibility class")
    }

    // MARK: - Status classification

    /// RED: make `write` return `.failed` for `errSecDuplicateItem` → the update path is
    /// never taken and re-entering a token throws instead of replacing it.
    func testWriteStatus_duplicateIsTheUpdatePathNotAFailure() {
        XCTAssertEqual(KeychainStatus.write(errSecSuccess), .stored)
        XCTAssertEqual(KeychainStatus.write(errSecDuplicateItem), .needsUpdate,
                       "a duplicate is how add-or-update stays idempotent")
        XCTAssertEqual(KeychainStatus.write(errSecAuthFailed), .failed(errSecAuthFailed))
        XCTAssertEqual(KeychainStatus.write(errSecItemNotFound), .failed(errSecItemNotFound),
                       "not-found on an INSERT is nonsense and must surface, not be "
                           + "quietly treated as success")
    }

    /// The absence-versus-failure split, which is the whole reason `loadToken` both returns
    /// an optional AND throws.
    ///
    /// RED: map `errSecInteractionNotAllowed` (a locked Keychain) to `.absent` → the last
    /// assertion fails, and a locked Keychain becomes indistinguishable from "no token
    /// saved": the request goes out unauthenticated and the user gets a 401 with nothing
    /// to act on.
    func testReadStatus_separatesAbsenceFromFailure() {
        XCTAssertEqual(KeychainStatus.read(errSecSuccess), .found)
        XCTAssertEqual(KeychainStatus.read(errSecItemNotFound), .absent,
                       "no entry is the ordinary case, not an error")
        XCTAssertEqual(KeychainStatus.read(errSecInteractionNotAllowed),
                       .failed(errSecInteractionNotAllowed),
                       "a locked Keychain must be reported so the banner can say so")
    }

    /// Deleting a key that was never stored is `setToken(nil)` on an empty field — the
    /// ordinary "user cleared nothing" case.
    ///
    /// RED: map `errSecItemNotFound` to `.failed` → clearing an empty token field throws a
    /// Keychain error banner at the user.
    func testDeleteStatus_absenceIsSuccess() {
        XCTAssertEqual(KeychainStatus.delete(errSecSuccess), .removed)
        XCTAssertEqual(KeychainStatus.delete(errSecItemNotFound), .alreadyAbsent,
                       "clearing a field that held nothing is not a failure")
        XCTAssertEqual(KeychainStatus.delete(errSecAuthFailed), .failed(errSecAuthFailed))
    }

    /// The update leg is asymmetric with `write` on purpose: it is only reached because the
    /// item exists, so there is no duplicate to tolerate and no absence to accept.
    ///
    /// RED: make `update` accept `errSecDuplicateItem` as `.ok` → this fails, and a failed
    /// update reports success while the OLD token stays stored: the user retypes their
    /// token, sees no error, and keeps getting 401s.
    func testUpdateStatus_onlySuccessIsSuccess() {
        XCTAssertEqual(KeychainStatus.update(errSecSuccess), .ok)
        XCTAssertEqual(KeychainStatus.update(errSecDuplicateItem), .failed(errSecDuplicateItem))
        XCTAssertEqual(KeychainStatus.update(errSecItemNotFound), .failed(errSecItemNotFound))
    }

    // MARK: - Payload decoding

    /// Both failure arms of `decodeToken` map to DIFFERENT errors, and only one of them
    /// tells the user something actionable.
    ///
    /// RED: collapse the non-Data arm into `.invalidUTF8` → the user is told to re-enter a
    /// token that is stored perfectly well, and the real cause (a `kSecMatchLimit`
    /// regression) is hidden.
    func testDecodeToken_distinguishesWrongShapeFromBadBytes() throws {
        XCTAssertEqual(try KeychainSecureTokenStorage.decodeToken(
            Data("tok".utf8) as CFTypeRef, status: errSecSuccess), "tok")

        // A CFArray is what `kSecMatchLimitAll` would hand back.
        XCTAssertThrowsError(try KeychainSecureTokenStorage.decodeToken(
            [Data("tok".utf8)] as CFTypeRef, status: errSecSuccess)) { error in
                XCTAssertEqual(error as? KeychainError, .unhandled(errSecSuccess),
                               "a non-Data payload is a lookup problem, not a corrupt token")
            }

        // Lone continuation byte: valid Data, invalid UTF-8.
        XCTAssertThrowsError(try KeychainSecureTokenStorage.decodeToken(
            Data([0x80]) as CFTypeRef, status: errSecSuccess)) { error in
                XCTAssertEqual(error as? KeychainError, .invalidUTF8,
                               "bad bytes are the one case where re-entering the token helps")
            }

        XCTAssertThrowsError(try KeychainSecureTokenStorage.decodeToken(
            nil, status: errSecSuccess))
    }

    // MARK: - Normalization

    /// The account key is a normalized base URL, and it MUST route through the shared
    /// normalizer: a second implementation that diverged on whitespace or a trailing slash
    /// strands every token already stored (CLAUDE.md records exactly that divergence for
    /// the vision-model resolver).
    func testNormalize_delegatesToTheSharedBaseURLNormalizer() {
        for raw in ["http://127.0.0.1:1234/", "HTTP://127.0.0.1:1234", " http://127.0.0.1:1234 "] {
            XCTAssertEqual(KeychainSecureTokenStorage.normalize(baseURL: raw),
                           raw.normalizedBaseURL, "diverged on \(raw.debugDescription)")
        }
        XCTAssertNotEqual(KeychainSecureTokenStorage.normalize(baseURL: "http://localhost:1234"),
                          KeychainSecureTokenStorage.normalize(baseURL: "http://127.0.0.1:1234"),
                          "localhost and 127.0.0.1 are deliberately NOT collapsed — "
                              + "firewalls can route them differently")
    }
}
