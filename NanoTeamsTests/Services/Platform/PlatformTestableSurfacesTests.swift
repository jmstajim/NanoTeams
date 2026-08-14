import AppKit
import Security
import XCTest

@testable import NanoTeams

// MARK: - Shared private doubles / helpers
//
// Everything at file scope is `private`; the only non-private declarations are
// the test classes themselves, each prefixed `Platform…` so the names stay
// unique across the whole test target.

/// In-memory `ConfigurationStorage` for `FolderAccessManager`. Deliberately NOT
/// `UserDefaults.standard`: the manager persists a security-scoped bookmark
/// under a fixed key, and a test writing that key would (a) leak between test
/// classes and (b) overwrite the developer's real "last opened folder".
private final class PlatformFakeConfigurationStorage: ConfigurationStorage, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    /// Counts `removeObject` calls so the failure arm of
    /// `restoreLastFolderIfPossible` can be asserted on the ACTION, not just on
    /// the resulting absence (absence is also the never-written state).
    private(set) var removedKeys: [String] = []

    func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func bool(forKey key: String) -> Bool { (object(forKey: key) as? Bool) ?? false }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }

    func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }

    func removeObject(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        removedKeys.append(key)
        values.removeValue(forKey: key)
    }
}

/// Statuses that mean "this runner has no usable Keychain" rather than "the
/// production code is wrong". File-scope so it can be used from a `catch … where`
/// clause without any question of capturing `self`.
private func platformIsKeychainUnavailable(_ status: OSStatus) -> Bool {
    status == errSecMissingEntitlement
        || status == errSecInteractionNotAllowed
        || status == errSecAuthFailed
        || status == errSecNotAvailable
}

/// Resolves bookmark data the same way `FolderAccessManager` does, so a test can
/// assert "the stored bookmark now points at X" without depending on the exact
/// bytes (bookmark blobs are not byte-stable for the same path).
private func platformResolvePath(fromBookmark data: Data) -> String? {
    var stale = false
    guard let url = try? URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
    ) else { return nil }
    return url.standardizedFileURL.path
}

// MARK: - SecureTokenStorage

/// Covers the parts of `SecureTokenStorage.swift` that the existing suites leave
/// open: the `normalize(baseURL:)` SSOT beyond its three happy cases, and the
/// REAL `KeychainSecureTokenStorage` read/delete paths.
///
/// Write-path tests stay behind `skipUnlessRealKeychainOptedIn()` — the house
/// rule from `SecureTokenStorageTests`: an unsigned local dev build gets a
/// modal Keychain-authorization prompt on the first `SecItemAdd`, which blocks
/// the runner indefinitely. Reads and deletes of entries that do NOT exist have
/// no ACL to evaluate, so they cannot prompt and run unconditionally — those
/// are what exercise `loadToken`'s query construction, its `errSecItemNotFound`
/// arm, and `setToken`'s empty→`delete` arm against the real Keychain.
final class PlatformSecureTokenStorageSurfaceTests: XCTestCase {

    /// A service id no other process (or test) uses, so nothing here can read,
    /// write, or delete the production `com.nanoteams.lmstudio.bearer.v1` items.
    private func uniqueTestService(_ label: String = "surface") -> String {
        "com.nanoteams.tests.\(label).\(UUID().uuidString)"
    }

    // MARK: normalize(baseURL:) — the security-bearing account key

    func testNormalize_lowercasesSchemeAsWellAsHost() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "HTTP://LocalHost:1234"),
            "http://localhost:1234"
        )
    }

    func testNormalize_collapsesEveryTrailingSlash_butKeepsInteriorOnes() {
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://host:1234/api/v1/////"),
            "http://host:1234/api/v1",
            "Only TRAILING slashes collapse — an interior path separator is part of the identity."
        )
    }

    func testNormalize_trimsNewlinesAndTabs_notJustSpaces() {
        // A pasted URL routinely carries a trailing newline. If that survived,
        // the write key and the read key would differ and every token would
        // read back as absent.
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "\t http://localhost:1234 \n"),
            "http://localhost:1234"
        )
    }

    func testNormalize_isIdempotent() {
        let once = KeychainSecureTokenStorage.normalize(baseURL: "  HTTP://Localhost:1234//  ")
        let twice = KeychainSecureTokenStorage.normalize(baseURL: once)
        XCTAssertEqual(once, twice, "Re-normalizing a key must be a no-op, or a second pass would strand the token.")
    }

    func testNormalize_emptyAndWhitespaceOnly_bothCollapseToEmpty() {
        XCTAssertEqual(KeychainSecureTokenStorage.normalize(baseURL: ""), "")
        XCTAssertEqual(KeychainSecureTokenStorage.normalize(baseURL: "   \n\t "), "")
    }

    func testNormalize_slashesOnly_collapseToEmpty() {
        XCTAssertEqual(KeychainSecureTokenStorage.normalize(baseURL: "///"), "")
    }

    func testNormalize_trailingSlashDoesNotMergeDistinctPaths() {
        // `http://h:1/v1/` and `http://h:1/v1` are the same server. `…/v1` and
        // `…/v2` are not — the trailing-slash collapse must not blur them.
        XCTAssertEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://h:1/v1/"),
            KeychainSecureTokenStorage.normalize(baseURL: "http://h:1/v1")
        )
        XCTAssertNotEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://h:1/v1"),
            KeychainSecureTokenStorage.normalize(baseURL: "http://h:1/v2")
        )
    }

    func testNormalize_httpAndHttpsStayDistinct() {
        XCTAssertNotEqual(
            KeychainSecureTokenStorage.normalize(baseURL: "http://host:1234"),
            KeychainSecureTokenStorage.normalize(baseURL: "https://host:1234"),
            "A bearer token minted for a TLS endpoint must not be replayed over plaintext."
        )
    }

    func testNormalize_matchesTheSharedStringNormalizer() {
        // The doc comment states the Keychain account key delegates to
        // `String.normalizedBaseURL` precisely so it cannot drift from the
        // model-catalog / census / reference-guard keys. Pin the delegation.
        for raw in [
            "  HTTP://LocalHost:1234//",
            "http://127.0.0.1:1234",
            "",
            "///",
            "https://Example.COM/API/"
        ] {
            XCTAssertEqual(
                KeychainSecureTokenStorage.normalize(baseURL: raw),
                raw.normalizedBaseURL,
                "normalize(baseURL:) must stay a pass-through to String.normalizedBaseURL for \(raw.debugDescription)."
            )
        }
    }

    // MARK: defaults

    func testInit_defaultsToProductionService() {
        XCTAssertEqual(KeychainSecureTokenStorage().service, KeychainSecureTokenStorage.defaultService)
    }

    func testInit_customService_isHonoured() {
        let service = uniqueTestService("ctor")
        XCTAssertEqual(KeychainSecureTokenStorage(service: service).service, service)
    }

    // MARK: real Keychain — non-mutating / non-prompting paths

    /// `loadToken` for an account that was never written must return `nil`
    /// (legitimate absence), not throw. This is the branch the whole
    /// "distinguish absence from failure" contract rests on, and it exercises
    /// the real `SecItemCopyMatching` query construction — no `SecItemAdd`, so
    /// there is no ACL to authorize and no prompt.
    func testKeychain_loadToken_neverWrittenAccount_returnsNil() throws {
        let sut = KeychainSecureTokenStorage(service: uniqueTestService("read-miss"))
        do {
            let value = try sut.loadToken(forKey: "http://127.0.0.1:1234")
            XCTAssertNil(value, "An account that was never written is legitimate absence → nil, never a throw.")
        } catch KeychainError.unhandled(let status) where platformIsKeychainUnavailable(status) {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
    }

    /// The non-throwing shim must agree with the throwing API on the absence
    /// case (both `nil`) — it only differs on real failures.
    func testKeychain_tokenShim_neverWrittenAccount_returnsNil() {
        let sut = KeychainSecureTokenStorage(service: uniqueTestService("shim-miss"))
        XCTAssertNil(sut.token(forKey: "http://127.0.0.1:1234"))
    }

    /// Distinct accounts under the same service must not alias. Verified on the
    /// read side alone (both miss), which is enough to prove the query carries
    /// `kSecAttrAccount` — if it did not, a wildcard match could surface a
    /// foreign entry.
    func testKeychain_loadToken_distinctAccounts_bothMissIndependently() throws {
        let sut = KeychainSecureTokenStorage(service: uniqueTestService("two-accounts"))
        do {
            XCTAssertNil(try sut.loadToken(forKey: "http://localhost:1234"))
            XCTAssertNil(try sut.loadToken(forKey: "http://127.0.0.1:1234"))
        } catch KeychainError.unhandled(let status) where platformIsKeychainUnavailable(status) {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
    }

    /// `setToken(nil)` routes to the private `delete(key:)`, whose contract is
    /// that `errSecItemNotFound` counts as success. Deleting an entry that does
    /// not exist touches no ACL, so this runs unconditionally.
    func testKeychain_setTokenNil_onMissingEntry_doesNotThrow() throws {
        let sut = KeychainSecureTokenStorage(service: uniqueTestService("delete-miss"))
        do {
            try sut.setToken(nil, forKey: "http://127.0.0.1:1234")
        } catch KeychainError.unhandled(let status) where platformIsKeychainUnavailable(status) {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
    }

    /// Empty and whitespace-only tokens are DELETES, not writes — so they can
    /// never reach `SecItemAdd` and can be exercised against the real Keychain.
    /// Getting this wrong would store a blank `Authorization: Bearer` header.
    func testKeychain_setTokenEmptyOrWhitespace_takesTheDeleteBranch() throws {
        let sut = KeychainSecureTokenStorage(service: uniqueTestService("empty-write"))
        let key = "http://127.0.0.1:1234"
        do {
            try sut.setToken("", forKey: key)
            try sut.setToken("   \n\t ", forKey: key)
            XCTAssertNil(try sut.loadToken(forKey: key), "A blank token must leave nothing behind to send.")
        } catch KeychainError.unhandled(let status) where platformIsKeychainUnavailable(status) {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
    }

    // MARK: real Keychain — write paths (opt-in; may prompt on an unsigned build)

    /// The add → duplicate → `SecItemUpdate` path. Idempotence matters because
    /// `LLMTokenField` re-saves on every edit; a delete+add would churn the
    /// item's attributes, and a failure to update would silently keep the old
    /// token in use after the user pasted a new one.
    func testKeychain_repeatedWrites_useUpdatePath_andLastValueWins() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let service = uniqueTestService("update-path")
        let sut = KeychainSecureTokenStorage(service: service)
        let key = KeychainSecureTokenStorage.normalize(baseURL: "http://127.0.0.1:1234/")
        defer { try? sut.setToken(nil, forKey: key) }

        do {
            try sut.setToken("v1", forKey: key)
        } catch KeychainError.unhandled(let status) where platformIsKeychainUnavailable(status) {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
        try sut.setToken("v2", forKey: key)
        try sut.setToken("v3", forKey: key)
        XCTAssertEqual(try sut.loadToken(forKey: key), "v3")
    }

    /// A write trims the token before storing — a trailing newline from a paste
    /// would otherwise ride into the HTTP header and be rejected by the server.
    func testKeychain_write_trimsBeforeStoring() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let sut = KeychainSecureTokenStorage(service: uniqueTestService("trim-write"))
        let key = "http://127.0.0.1:1234"
        defer { try? sut.setToken(nil, forKey: key) }

        do {
            try sut.setToken("  pasted-token\n", forKey: key)
        } catch KeychainError.unhandled(let status) where platformIsKeychainUnavailable(status) {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
        XCTAssertEqual(try sut.loadToken(forKey: key), "pasted-token")
    }

    /// Two servers under one service must stay isolated — this is the property
    /// that makes the per-URL keying safe for multi-server setups.
    func testKeychain_twoAccounts_doNotOverwriteEachOther() throws {
        try SecureTokenStorageTests.skipUnlessRealKeychainOptedIn()
        let sut = KeychainSecureTokenStorage(service: uniqueTestService("isolation"))
        let a = "http://localhost:1234"
        let b = "http://127.0.0.1:1234"
        defer {
            try? sut.setToken(nil, forKey: a)
            try? sut.setToken(nil, forKey: b)
        }

        do {
            try sut.setToken("token-a", forKey: a)
        } catch KeychainError.unhandled(let status) where platformIsKeychainUnavailable(status) {
            throw XCTSkip("Keychain unavailable on this runner (status \(status)).")
        }
        try sut.setToken("token-b", forKey: b)

        XCTAssertEqual(try sut.loadToken(forKey: a), "token-a")
        XCTAssertEqual(try sut.loadToken(forKey: b), "token-b")

        // Deleting one must not disturb the other.
        try sut.setToken(nil, forKey: a)
        XCTAssertNil(try sut.loadToken(forKey: a))
        XCTAssertEqual(try sut.loadToken(forKey: b), "token-b")
    }
}

// MARK: - FolderAccessManager

/// Drives `restoreLastFolderIfPossible` through its private collaborators
/// (`setProjectFolder` / `persistBookmark` / `stopSecurityScopedAccessIfNeeded`)
/// — all three are `private`, and this async entry point is their only caller
/// besides `deinit`.
///
/// The success path needs real security-scoped bookmark data. The app ships
/// with `ENABLE_APP_SANDBOX = NO`, so `URL.bookmarkData(options:
/// .withSecurityScope)` succeeds here; a runner where it does not is skipped
/// rather than failed. A plain (non-security-scoped) bookmark is NOT usable —
/// resolving one with `.withSecurityScope` fails with NSCocoaError 259, so the
/// fixture must create the security-scoped variant.
@MainActor
final class PlatformFolderAccessManagerRestoreTests: XCTestCase {

    /// Mirrors the manager's `private static let bookmarkDefaultsKey`. Kept as a
    /// literal on purpose: if the production key is renamed without a migration
    /// every installed user silently loses their last-opened folder, and these
    /// tests should go red.
    private static let bookmarkKey = "NanoTeams.projectFolderBookmark.v1"

    private var storage: PlatformFakeConfigurationStorage!
    private var manager: FolderAccessManager!
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        storage = PlatformFakeConfigurationStorage()
        manager = FolderAccessManager(storage: storage)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlatformFolderAccess-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Release the manager BEFORE the directories go away: its `deinit` calls
        // `stopSecurityScopedAccessIfNeeded` on the URL it is still holding.
        manager = nil
        storage = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: helpers

    private func makeFolder(_ name: String) -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Security-scoped bookmark data, or `nil` when this runner refuses to mint
    /// one (caller skips rather than fails — the refusal is environmental).
    private func securityScopedBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func storedBookmark() -> Data? { storage.data(forKey: Self.bookmarkKey) }

    // MARK: guard arms

    func testRestore_withNoStoredBookmark_leavesEverythingUntouched() async {
        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(manager.workFolderURL)
        XCTAssertTrue(
            storage.removedKeys.isEmpty,
            "The absent-bookmark early return must not clear the key — there is nothing to clear, and clearing is the FAILURE signal."
        )
    }

    func testRestore_withUndecodableBookmark_clearsTheStoredKey() async {
        storage.set(Data("not a bookmark".utf8), forKey: Self.bookmarkKey)

        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(manager.workFolderURL)
        XCTAssertNil(storedBookmark())
        XCTAssertEqual(
            storage.removedKeys, [Self.bookmarkKey],
            "A bookmark that cannot resolve must be REMOVED, not merely overwritten — otherwise every launch retries the same dead blob."
        )
    }

    func testRestore_withEmptyData_clearsTheStoredKey() async {
        storage.set(Data(), forKey: Self.bookmarkKey)

        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(manager.workFolderURL)
        XCTAssertEqual(storage.removedKeys, [Self.bookmarkKey])
    }

    /// A truncated but otherwise well-formed bookmark — the shape a partially
    /// written / corrupted preference takes, distinct from arbitrary text.
    func testRestore_withTruncatedBookmark_clearsTheStoredKey() async throws {
        let folder = makeFolder("Truncated")
        guard let data = securityScopedBookmark(for: folder) else {
            throw XCTSkip("This runner refuses to create security-scoped bookmarks.")
        }
        storage.set(data.prefix(40), forKey: Self.bookmarkKey)

        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(manager.workFolderURL)
        XCTAssertEqual(storage.removedKeys, [Self.bookmarkKey])
    }

    /// A bookmark for a directory that no longer exists resolves with an error
    /// (NOT a stale flag), so it must take the same clear-the-key arm.
    func testRestore_bookmarkForDeletedFolder_clearsTheStoredKey() async throws {
        let folder = makeFolder("Deleted")
        guard let data = securityScopedBookmark(for: folder) else {
            throw XCTSkip("This runner refuses to create security-scoped bookmarks.")
        }
        try FileManager.default.removeItem(at: folder)
        storage.set(data, forKey: Self.bookmarkKey)

        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(manager.workFolderURL)
        XCTAssertEqual(storage.removedKeys, [Self.bookmarkKey])
    }

    // MARK: success path

    func testRestore_withValidBookmark_publishesFolderAndRewritesBookmark() async throws {
        let folder = makeFolder("Valid")
        guard let data = securityScopedBookmark(for: folder) else {
            throw XCTSkip("This runner refuses to create security-scoped bookmarks.")
        }
        storage.set(data, forKey: Self.bookmarkKey)

        await manager.restoreLastFolderIfPossible()

        XCTAssertEqual(
            manager.workFolderURL?.standardizedFileURL.path,
            folder.standardizedFileURL.path,
            "A resolvable bookmark must publish its folder — this is the whole point of the restore."
        )
        XCTAssertTrue(storage.removedKeys.isEmpty, "A successful restore must never take the clear-the-key failure arm.")
        let rewritten = try XCTUnwrap(storedBookmark(), "setProjectFolder re-persists the bookmark on every restore.")
        XCTAssertEqual(
            platformResolvePath(fromBookmark: rewritten),
            folder.standardizedFileURL.path,
            "The re-persisted bookmark must still point at the same folder."
        )
    }

    /// The `stale` branch: moving the folder makes the stored bookmark resolve
    /// to the NEW location with `bookmarkDataIsStale == true`, which is the only
    /// trigger for the refresh write inside `restoreLastFolderIfPossible`.
    func testRestore_staleBookmark_refreshesToTheNewLocation() async throws {
        let original = makeFolder("Original")
        guard let data = securityScopedBookmark(for: original) else {
            throw XCTSkip("This runner refuses to create security-scoped bookmarks.")
        }
        let moved = tempRoot.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        storage.set(data, forKey: Self.bookmarkKey)

        await manager.restoreLastFolderIfPossible()

        XCTAssertEqual(
            manager.workFolderURL?.standardizedFileURL.path,
            moved.standardizedFileURL.path,
            "A stale bookmark still resolves — it must follow the folder to its new path."
        )
        let refreshed = try XCTUnwrap(storedBookmark())
        XCTAssertEqual(
            platformResolvePath(fromBookmark: refreshed),
            moved.standardizedFileURL.path,
            "The stale branch must WRITE BACK a fresh bookmark, or the next launch pays the stale-resolve cost again forever."
        )
        XCTAssertTrue(storage.removedKeys.isEmpty)
    }

    /// Second restore against a different folder: `setProjectFolder` must run
    /// `stopSecurityScopedAccessIfNeeded` for the previous URL before adopting
    /// the new one. Observable contract: the manager ends up on the new folder
    /// and the persisted bookmark follows.
    func testRestore_twiceWithDifferentFolders_adoptsTheSecondAndRepersists() async throws {
        let first = makeFolder("First")
        let second = makeFolder("Second")
        guard let firstData = securityScopedBookmark(for: first),
              let secondData = securityScopedBookmark(for: second)
        else {
            throw XCTSkip("This runner refuses to create security-scoped bookmarks.")
        }

        storage.set(firstData, forKey: Self.bookmarkKey)
        await manager.restoreLastFolderIfPossible()
        XCTAssertEqual(manager.workFolderURL?.standardizedFileURL.path, first.standardizedFileURL.path)

        storage.set(secondData, forKey: Self.bookmarkKey)
        await manager.restoreLastFolderIfPossible()

        XCTAssertEqual(
            manager.workFolderURL?.standardizedFileURL.path,
            second.standardizedFileURL.path,
            "The second restore must replace the first folder, releasing its security scope on the way."
        )
        let stored = try XCTUnwrap(storedBookmark())
        XCTAssertEqual(platformResolvePath(fromBookmark: stored), second.standardizedFileURL.path)
        XCTAssertTrue(storage.removedKeys.isEmpty)
    }

    /// Restoring the SAME folder twice is the ordinary relaunch case and must be
    /// idempotent — the second pass stops and immediately re-starts the scope.
    func testRestore_twiceWithSameFolder_isIdempotent() async throws {
        let folder = makeFolder("Same")
        guard let data = securityScopedBookmark(for: folder) else {
            throw XCTSkip("This runner refuses to create security-scoped bookmarks.")
        }
        storage.set(data, forKey: Self.bookmarkKey)

        await manager.restoreLastFolderIfPossible()
        await manager.restoreLastFolderIfPossible()

        XCTAssertEqual(manager.workFolderURL?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertTrue(storage.removedKeys.isEmpty)
    }

    /// A failed restore after a SUCCESSFUL one must not silently keep serving the
    /// old folder as if it were freshly validated — but it also must not clear the
    /// live `workFolderURL`, since the process is still holding that scope.
    /// Characterizes the current shape so a future change to it is a decision.
    func testRestore_failureAfterSuccess_clearsKeyButKeepsLiveFolder() async throws {
        let folder = makeFolder("Live")
        guard let data = securityScopedBookmark(for: folder) else {
            throw XCTSkip("This runner refuses to create security-scoped bookmarks.")
        }
        storage.set(data, forKey: Self.bookmarkKey)
        await manager.restoreLastFolderIfPossible()
        XCTAssertNotNil(manager.workFolderURL)

        storage.set(Data("garbage".utf8), forKey: Self.bookmarkKey)
        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(storedBookmark(), "The unusable bookmark is cleared.")
        XCTAssertEqual(
            manager.workFolderURL?.standardizedFileURL.path,
            folder.standardizedFileURL.path,
            "The in-process folder stays published — its security scope is still held, so dropping the URL would strand it."
        )
    }

    func testInit_startsWithNoFolder() {
        XCTAssertNil(manager.workFolderURL)
    }
}

// MARK: - QuickCapturePanel geometry

/// Pins the WIRING between the panel's resize entry points and the pure
/// `ResizeDecision` (which `QuickCapturePanelResizeDecisionTests` already covers
/// in isolation). The wiring is where the `isUserResize` argument is chosen, and
/// choosing it wrong is exactly the bug the lock exists to prevent: SwiftUI
/// content pushing `intrinsicContentSize` up through `NSHostingView` and
/// resizing the user's window.
@MainActor
final class PlatformQuickCapturePanelGeometryTests: XCTestCase {

    private var sut: QuickCapturePanel!
    /// The panel's frame autosave writes into `UserDefaults.standard`; snapshot
    /// and restore so these tests neither depend on nor damage the developer's
    /// real saved panel position.
    private var savedAutosaveEntry: Any?
    private static let autosaveDefaultsKey = "NSWindow Frame " + UserDefaultsKeys.quickCapturePanelFrame

    private var floor: NSSize { QuickCapturePanel.panelMinSize }

    override func setUp() {
        super.setUp()
        savedAutosaveEntry = UserDefaults.standard.object(forKey: Self.autosaveDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.autosaveDefaultsKey)
        sut = QuickCapturePanel()
    }

    override func tearDown() {
        sut?.orderOut(nil)
        sut = nil
        if let savedAutosaveEntry {
            UserDefaults.standard.set(savedAutosaveEntry, forKey: Self.autosaveDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.autosaveDefaultsKey)
        }
        savedAutosaveEntry = nil
        super.tearDown()
    }

    private func notification(_ name: Notification.Name) -> Notification {
        Notification(name: name, object: sut, userInfo: nil)
    }

    // MARK: setFrame → decide(isUserResize: false)

    func testSetFrame_withNoUserLock_honoursTheRequest() {
        let requested = NSRect(x: 120, y: 140, width: floor.width + 180, height: floor.height + 220)
        sut.setFrame(requested, display: false)
        XCTAssertEqual(sut.frame.size, requested.size)
    }

    func testSetFrame_withNoUserLock_clampsSubFloorRequestToFloor() {
        sut.setFrame(NSRect(x: 10, y: 10, width: 12, height: 9), display: false)
        XCTAssertEqual(sut.frame.size, floor, "Below-floor programmatic frames must be raised, not accepted.")
    }

    func testSetFrame_preservesOrigin_whileClampingSize() {
        let origin = NSPoint(x: 210, y: 190)
        sut.setFrame(NSRect(origin: origin, size: NSSize(width: 5, height: 5)), display: false)
        XCTAssertEqual(sut.frame.origin, origin, "Clamping is a SIZE decision — it must never move the window.")
    }

    /// The content-auto-grow defense: once a lock exists, a programmatic
    /// `setFrame` (which is how NSHostingView's intrinsic size arrives) must be
    /// ignored entirely.
    func testSetFrame_withUserLock_ignoresRequestAndRestoresTheLock() {
        let locked = NSSize(width: floor.width + 60, height: floor.height + 90)
        sut._testCaptureUserLock(size: locked)

        sut.setFrame(NSRect(x: 0, y: 0, width: 900, height: 1100), display: false)

        XCTAssertEqual(sut.frame.size, locked, "A locked panel must not grow when SwiftUI content wants more room.")
    }

    func testSetFrame_withUserLock_alsoBlocksShrink() {
        let locked = NSSize(width: floor.width + 60, height: floor.height + 90)
        sut._testCaptureUserLock(size: locked)

        sut.setFrame(NSRect(x: 0, y: 0, width: floor.width, height: floor.height), display: false)

        XCTAssertEqual(sut.frame.size, locked, "Content shrinking must not pull the user's window down either.")
    }

    func testSetFrameAnimated_routesThroughTheSameDecision() {
        let locked = NSSize(width: floor.width + 40, height: floor.height + 40)
        sut._testCaptureUserLock(size: locked)

        sut.setFrame(NSRect(x: 0, y: 0, width: 950, height: 950), display: false, animate: false)

        XCTAssertEqual(
            sut.frame.size, locked,
            "The animate: overload is a separate AppKit entry point — if it skipped `decide`, the auto-grow defense would have a hole."
        )
    }

    // MARK: setContentSize

    func testSetContentSize_withNoLock_growsTheWindow() {
        let before = sut.frame.size
        sut.setContentSize(NSSize(width: floor.width + 300, height: floor.height + 300))
        XCTAssertGreaterThan(sut.frame.size.width, before.width)
        XCTAssertGreaterThanOrEqual(sut.frame.size.width, floor.width)
        XCTAssertGreaterThanOrEqual(sut.frame.size.height, floor.height)
    }

    func testSetContentSize_withUserLock_doesNotAdoptTheRequestedSize() {
        let locked = NSSize(width: floor.width + 30, height: floor.height + 30)
        sut._testCaptureUserLock(size: locked)

        sut.setContentSize(NSSize(width: 4000, height: 4000))

        // Asserted as an upper bound rather than an exact frame: AppKit converts
        // content → frame internally and the titlebar delta is not a value this
        // test should encode. The contract that matters is "the 4000pt request
        // did not take effect".
        XCTAssertLessThan(sut.frame.size.width, 4000, "A locked panel must reject content-driven size requests.")
        XCTAssertLessThan(sut.frame.size.height, 4000)
        XCTAssertGreaterThanOrEqual(sut.frame.size.width, floor.width)
        XCTAssertGreaterThanOrEqual(sut.frame.size.height, floor.height)
    }

    func testSetContentSize_belowFloor_isClampedUp() {
        sut.setContentSize(NSSize(width: 1, height: 1))
        XCTAssertGreaterThanOrEqual(sut.frame.size.width, floor.width)
        XCTAssertGreaterThanOrEqual(sut.frame.size.height, floor.height)
    }

    // MARK: windowWillResize → decide(isUserResize: true)

    func testWindowWillResize_honoursTheDragEvenWhenLocked() {
        let locked = NSSize(width: floor.width + 10, height: floor.height + 10)
        sut._testCaptureUserLock(size: locked)
        let dragged = NSSize(width: floor.width + 400, height: floor.height + 500)

        let result = sut.windowWillResize(sut, to: dragged)

        XCTAssertEqual(
            result, dragged,
            "Live drag is USER intent — it must win over the lock, or the panel would be unresizable after the first drag."
        )
    }

    func testWindowWillResize_clampsDragToFloor() {
        XCTAssertEqual(sut.windowWillResize(sut, to: NSSize(width: 4, height: 4)), floor)
    }

    func testWindowWillResize_atFloor_returnsFloorUnchanged() {
        XCTAssertEqual(sut.windowWillResize(sut, to: floor), floor)
    }

    // MARK: windowDidEndLiveResize → captureUserLock

    func testWindowDidEndLiveResize_capturesCurrentFrameAsTheLock() {
        let size = NSSize(width: floor.width + 77, height: floor.height + 88)
        sut.setFrame(NSRect(origin: .zero, size: size), display: false)
        XCTAssertNil(sut._testUserLockedSize, "Precondition: a fresh panel has no lock.")

        sut.windowDidEndLiveResize(notification(NSWindow.didEndLiveResizeNotification))

        XCTAssertEqual(sut._testUserLockedSize, sut.frame.size)
        XCTAssertEqual(sut._testUserLockedSize, size)
    }

    func testWindowDidEndLiveResize_thenSetFrame_isBlockedByTheNewLock() {
        let size = NSSize(width: floor.width + 120, height: floor.height + 130)
        sut.setFrame(NSRect(origin: .zero, size: size), display: false)
        sut.windowDidEndLiveResize(notification(NSWindow.didEndLiveResizeNotification))

        sut.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 1200), display: false)

        XCTAssertEqual(sut.frame.size, size, "Drag-end must arm the lock, not merely record it.")
    }

    // MARK: windowDidResize → snap back to lock

    func testWindowDidResize_notLive_snapsFrameBackToTheLock() {
        // Grow first (no lock yet, so the request is honoured), THEN install a
        // smaller lock. This is the only way to construct "frame ≠ lock" from a
        // test — every setFrame path already consults the lock.
        let big = NSSize(width: floor.width + 300, height: floor.height + 300)
        sut.setFrame(NSRect(origin: .zero, size: big), display: false)
        let locked = NSSize(width: floor.width + 40, height: floor.height + 40)
        sut._testCaptureUserLock(size: locked)
        XCTAssertEqual(sut.frame.size, big, "Precondition: frame and lock disagree.")

        sut.windowDidResize(notification(NSWindow.didResizeNotification))

        XCTAssertEqual(
            sut.frame.size, locked,
            "The post-fact snap-back is the last-resort guard for a resize route that bypassed the overrides."
        )
    }

    func testWindowDidResize_withNoLock_leavesTheFrameAlone() {
        let size = NSSize(width: floor.width + 210, height: floor.height + 160)
        sut.setFrame(NSRect(origin: .zero, size: size), display: false)

        sut.windowDidResize(notification(NSWindow.didResizeNotification))

        XCTAssertEqual(sut.frame.size, size, "Before the first drag there is nothing to snap back to.")
    }

    func testWindowDidResize_frameAlreadyMatchesLock_isANoop() {
        let size = NSSize(width: floor.width + 55, height: floor.height + 55)
        sut.setFrame(NSRect(x: 33, y: 44, width: size.width, height: size.height), display: false)
        sut._testCaptureUserLock(size: size)
        let origin = sut.frame.origin

        sut.windowDidResize(notification(NSWindow.didResizeNotification))

        XCTAssertEqual(sut.frame.size, size)
        XCTAssertEqual(sut.frame.origin, origin, "A no-delta resize notification must not move the window.")
    }

    // MARK: show / hide

    func testShow_recordsTheExpectsFocusableFieldArgument() async {
        sut.show(expectsFocusableField: false)
        XCTAssertEqual(sut._testLastShowExpectsFocusableField, false)

        sut.show(expectsFocusableField: true)
        XCTAssertEqual(
            sut._testLastShowExpectsFocusableField, true,
            "The flag must be captured per call — a mutable property would let a re-show race the in-flight retry."
        )
        sut.hide()
    }

    /// With no usable autosaved frame, `show` takes the `!restored` arm and
    /// centres on the mouse's screen. The user-visible contract is "the panel
    /// lands somewhere visible", which also covers the offscreen guard.
    func testShow_withNoAutosavedFrame_leavesThePanelOnAScreen() async throws {
        // Resolve the screen exactly as `centerOnMouseScreen` does. Its own guard
        // returns early when neither the mouse's screen nor `NSScreen.main`
        // resolves (possible in a runner with no key window), and the panel would
        // then legitimately stay where it was — so skip rather than fail there.
        let mouseScreen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        try XCTSkipIf(mouseScreen == nil, "No resolvable screen to centre on in this runner.")
        UserDefaults.standard.removeObject(forKey: Self.autosaveDefaultsKey)
        // Park it far away first so a no-op `show` could not accidentally pass.
        sut.setFrame(NSRect(x: -90_000, y: -90_000, width: floor.width, height: floor.height), display: false)

        sut.show(expectsFocusableField: false)

        XCTAssertTrue(
            NSScreen.screens.contains { $0.visibleFrame.intersects(sut.frame) },
            "show() must never leave the panel entirely off every display."
        )
        sut.hide()
    }

    func testShow_neverLandsBelowTheResizeFloor() async {
        sut.show(expectsFocusableField: false)

        XCTAssertGreaterThanOrEqual(sut.frame.size.width, floor.width)
        XCTAssertGreaterThanOrEqual(sut.frame.size.height, floor.height)
        sut.hide()
    }

    /// `show` re-captures the (restored, floor-clamped) frame as the lock, so the
    /// very first SwiftUI content push after a show is already blocked.
    func testShow_capturesTheResultingFrameAsTheUserLock() async {
        sut.show(expectsFocusableField: false)

        XCTAssertEqual(
            sut._testUserLockedSize, sut.frame.size,
            "Without this capture, the first NSHostingView intrinsic-size push after a show would resize the window."
        )
        sut.hide()
    }

    /// A lock left over from a previous show must be cleared FIRST, or the
    /// autosave restore inside `show` would be treated as a programmatic resize
    /// and silently ignored — the user's saved panel size would never come back.
    func testShow_clearsAnyPreviousLockBeforeRestoring() async {
        // No autosaved frame ⇒ `show` centres (origin only) and leaves the size
        // alone, so the size after `show` is a clean signal for which lock won.
        UserDefaults.standard.removeObject(forKey: Self.autosaveDefaultsKey)
        let actual = NSSize(width: floor.width + 70, height: floor.height + 90)
        sut.setFrame(NSRect(origin: NSPoint(x: 100, y: 100), size: actual), display: false)
        let staleLock = NSSize(width: floor.width + 500, height: floor.height + 500)
        sut._testCaptureUserLock(size: staleLock)

        sut.show(expectsFocusableField: false)

        XCTAssertEqual(
            sut._testUserLockedSize, actual,
            "show() must drop the old lock and re-capture from the frame it actually ended up with."
        )
        XCTAssertNotEqual(sut._testUserLockedSize, staleLock, "The stale lock must not survive a show.")
        sut.hide()
    }

    func testHide_ordersOutAndFiresOnPanelHidden() async {
        var hiddenCount = 0
        sut.onPanelHidden = { hiddenCount += 1 }
        sut.orderFront(nil)
        XCTAssertTrue(sut.isVisible, "Precondition: panel visible.")

        sut.hide()

        XCTAssertFalse(sut.isVisible)
        XCTAssertEqual(hiddenCount, 1, "`hide()` routes through the overridden `orderOut`, which is what notifies the controller.")
    }

    func testOrderOut_firesOnPanelHidden_evenWithoutHide() {
        var fired = false
        sut.onPanelHidden = { fired = true }
        sut.orderFront(nil)

        sut.orderOut(nil)

        XCTAssertTrue(fired, "AppKit can order the panel out directly (Escape fallback) — the controller must still learn about it.")
    }

    func testHide_doesNotClearTheUserLock() {
        let locked = NSSize(width: floor.width + 25, height: floor.height + 25)
        sut._testCaptureUserLock(size: locked)

        sut.hide()

        XCTAssertEqual(sut._testUserLockedSize, locked, "Hiding is not resizing — the user's size must survive an open/close cycle.")
    }

    // MARK: chrome invariants that the geometry logic depends on

    func testPanel_isConfiguredAsANonActivatingFloatingPanel() {
        XCTAssertTrue(sut.isFloatingPanel)
        XCTAssertEqual(sut.level, .floating)
        XCTAssertFalse(sut.hidesOnDeactivate, "The overlay must survive the user clicking into another app.")
        XCTAssertFalse(sut.isReleasedWhenClosed, "`hide()` is orderOut — releasing on close would dangle the controller's reference.")
    }

    func testPanel_canBecomeKeyButNotMain() {
        XCTAssertTrue(sut.canBecomeKey, "The composer needs key status to receive keystrokes.")
        XCTAssertFalse(sut.canBecomeMain, "Becoming main would activate NanoTeams and steal focus from the app the user captured from.")
    }
}

// MARK: - QuickCaptureController+TaskCreation — createTask

/// Drives the real `QuickCaptureController.createTask()` against a real
/// orchestrator. Uses `QuickCaptureController.shared` (a process-global several
/// suites bind) and resets it in both `setUp` and `tearDown`, per CLAUDE.md
/// 2026-07-07.
@MainActor
final class PlatformQuickCaptureTaskCreationTests: NTMSOrchestratorTestBase {

    private var controller: QuickCaptureController!
    /// `keepOpenInChat` persists through `UserDefaults.standard`; snapshot it so
    /// these tests do not rewrite the developer's preference.
    private var savedKeepOpenInChat: Bool!

    override func setUp() {
        super.setUp()
        controller = QuickCaptureController.shared
        controller._testReset()
        controller.store = sut
        savedKeepOpenInChat = controller.keepOpenInChat
        // Force the non-chat post-create branch (dismissPanel). The chat branch
        // rebuilds panel content, which needs a DictationService that CI cannot
        // safely construct (CLAUDE.md #47). Chat routing itself is asserted
        // separately below via `currentVisualMode`.
        controller.keepOpenInChat = false
        // Any run started by task creation must not reach a real LM Studio.
        // Port 1 on loopback refuses immediately and deterministically.
        sut.configuration.llmBaseURL = "http://127.0.0.1:1"
    }

    override func tearDown() {
        controller.keepOpenInChat = savedKeepOpenInChat
        savedKeepOpenInChat = nil
        controller._testReset()
        controller = nil
        super.tearDown()
    }

    private func writeFile(_ name: String, bytes: Data) -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: false)
        try? bytes.write(to: url)
        return url
    }

    // MARK: guard arms

    func testCreateTask_withNoStore_returnsWithoutTouchingTheDraft() async {
        controller.store = nil
        controller.formState.title = "Kept"
        controller.formState.supervisorTask = "Kept goal"

        await controller.createTask()

        XCTAssertEqual(controller.formState.title, "Kept")
        XCTAssertEqual(
            controller.formState.supervisorTask, "Kept goal",
            "The no-store guard must return BEFORE `clearTaskDraft` — otherwise a misconfigured launch silently eats the user's typing."
        )
    }

    func testCreateTask_withEmptyForm_doesNotCreateATaskAndKeepsTheDraft() async {
        await sut.openWorkFolder(tempDir)
        let before = sut.snapshot?.tasksIndex.tasks.count ?? 0
        controller.formState.title = ""
        controller.formState.supervisorTask = "   \n  "
        let draftID = controller.formState.draftID
        controller._testIsPanelVisible = true

        await controller.createTask()

        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count ?? 0, before, "An untitled, empty task must not be created.")
        XCTAssertEqual(controller.formState.draftID, draftID, "A failed submit must not rotate the draft id — the staged attachments still belong to it.")
        XCTAssertTrue(
            controller._testIsPanelVisible,
            "A failed submit must leave the panel open so the user can fix the input."
        )
    }

    // MARK: happy path

    func testCreateTask_success_clearsTheDraftAndDismissesThePanel() async {
        await sut.openWorkFolder(tempDir)
        controller.formState.title = ""
        controller.formState.supervisorTask = "Build a calculator"
        controller.formState.attachments = []
        controller.formState.clippedTexts = []
        let draftID = controller.formState.draftID
        controller._testIsPanelVisible = true
        controller._testForceNewTaskMode = true

        await controller.createTask()

        XCTAssertNotNil(sut.activeTask, "The happy path must actually create and select a task.")
        XCTAssertEqual(sut.activeTask?.supervisorTask, "Build a calculator")
        XCTAssertEqual(controller.formState.supervisorTask, "", "clearTaskDraft must run on success.")
        XCTAssertEqual(controller.formState.title, "")
        XCTAssertNotEqual(controller.formState.draftID, draftID, "A fresh draft id must be minted so the next task stages separately.")
        XCTAssertFalse(controller._testIsPanelVisible, "keepOpenInChat == false ⇒ dismiss.")
        XCTAssertFalse(controller._testForceNewTaskMode, "dismissPanel clears the force-new-task override.")
    }

    func testCreateTask_derivesTitleFromTheFirstLine_whenTitleIsBlank() async {
        await sut.openWorkFolder(tempDir)
        controller.formState.title = "   "
        controller.formState.supervisorTask = "Fix the parser\nthen ship it"

        await controller.createTask()

        XCTAssertEqual(sut.activeTask?.title, "Fix the parser")
    }

    // MARK: clips

    func testCreateTask_foldsClipsIntoTheBrief_andSendsNoSeparateClipList() async {
        await sut.openWorkFolder(tempDir)
        controller.formState.title = "With clip"
        controller.formState.supervisorTask = "Review this"
        controller.formState.clippedTexts = ["let answer = 42 // unique-clip-marker"]

        await controller.createTask()

        let task = sut.activeTask
        XCTAssertNotNil(task)
        XCTAssertTrue(
            task?.supervisorTask.contains("unique-clip-marker") ?? false,
            "Clips are ALWAYS embedded inline by AnswerTextBuilder — the brief is the only place they reach the model."
        )
        XCTAssertTrue(
            task?.clippedTexts.isEmpty ?? false,
            "Having embedded the clips in the text, createTask must not ALSO forward them as structured clips — that would duplicate them in the prompt."
        )
    }

    // MARK: embedded attachments

    /// The `!built.failedFiles.isEmpty` branch. Kept deterministic by leaving the
    /// form otherwise empty: submission then fails at the empty-title guard,
    /// BEFORE attachment finalization or `startRun`, so nothing downstream can
    /// overwrite the single `lastErrorMessage` slot.
    func testCreateTask_withUnreadableAttachment_andEmbedEnabled_surfacesTheEmbedFailure() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.embedFilesInPrompt = true
        // Invalid UTF-8 under an extension DocumentTextExtractor does not handle
        // → extraction returns nil, the UTF-8 fallback throws → `.failed`.
        let bad = writeFile("unreadable.dat", bytes: Data([0xFF, 0xFE, 0x00, 0x01, 0x80]))
        guard let staged = try? StagedAttachment(url: bad, stagedRelativePath: "staged/unreadable.dat") else {
            XCTFail("Could not build the staged attachment fixture"); return
        }
        controller.formState.title = ""
        controller.formState.supervisorTask = ""
        controller.formState.attachments = [staged]
        sut.lastErrorMessage = nil

        await controller.createTask()

        XCTAssertTrue(
            sut.lastErrorMessage?.contains("Could not embed") ?? false,
            "A file the user asked to embed but that cannot be read must be reported — silently dropping it makes the model answer about content it never saw. Got: \(String(describing: sut.lastErrorMessage))"
        )
        XCTAssertTrue(sut.lastErrorMessage?.contains("unreadable.dat") ?? false, "The message must name the offending file.")
    }

    func testCreateTask_withReadableAttachment_andEmbedEnabled_inlinesTheContent() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.embedFilesInPrompt = true
        let source = writeFile("notes.txt", bytes: Data("embedded-file-marker\n".utf8))
        guard let staged = sut.stageAttachment(url: source, draftID: controller.formState.draftID) else {
            XCTFail("Staging failed"); return
        }
        controller.formState.title = "Embed"
        controller.formState.supervisorTask = "Summarise the notes"
        controller.formState.attachments = [staged]

        await controller.createTask()

        XCTAssertTrue(
            sut.activeTask?.supervisorTask.contains("embedded-file-marker") ?? false,
            "With embedFilesInPrompt on, the file's text must ride inside the brief rather than being left as a path for read_file."
        )
    }

    func testCreateTask_withReadableAttachment_andEmbedDisabled_keepsItAsAPath() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.embedFilesInPrompt = false
        let source = writeFile("keep-as-path.txt", bytes: Data("not-inlined-marker\n".utf8))
        guard let staged = sut.stageAttachment(url: source, draftID: controller.formState.draftID) else {
            XCTFail("Staging failed"); return
        }
        controller.formState.title = "Path"
        controller.formState.supervisorTask = "Look at the file"
        controller.formState.attachments = [staged]

        await controller.createTask()

        let task = sut.activeTask
        XCTAssertFalse(
            task?.supervisorTask.contains("not-inlined-marker") ?? true,
            "Embedding is opt-in — with it off the content must stay on disk."
        )
        XCTAssertFalse(task?.attachmentPaths.isEmpty ?? true, "The attachment must still be recorded as a path.")
    }

    // MARK: chat-mode routing

    func testCreateTask_chatTeam_withKeepOpen_staysOpenInWorkingMode() async {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder { workFolder in
            let supervisor = TeamRoleDefinition(
                id: "supervisor", name: "Supervisor",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies(), systemRoleID: "supervisor"
            )
            let assistant = TeamRoleDefinition(
                id: "assistant", name: "Assistant",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            )
            let chatTeam = Team(
                id: "platform_chat_team", name: "Platform Chat Team",
                roles: [supervisor, assistant], artifacts: [],
                settings: TeamSettings(), graphLayout: TeamGraphLayout()
            )
            workFolder.teams.append(chatTeam)
        }
        controller.keepOpenInChat = true
        controller.formState.selectedTeamID = "platform_chat_team"
        controller.formState.title = "Chat"
        controller.formState.supervisorTask = "Hello"
        controller._testIsPanelVisible = true

        await controller.createTask()

        XCTAssertTrue(
            controller._testIsPanelVisible,
            "keepOpenInChat + a chat team means the overlay becomes the chat composer instead of dismissing."
        )
        XCTAssertFalse(controller._testForceNewTaskMode, "The keep-open branch clears forceNewTaskMode explicitly.")
        XCTAssertTrue(controller.isTaskSelected, "The keep-open branch marks the freshly created task as selected.")
    }
}

// MARK: - QuickCaptureController+TaskCreation — submitAnswer / cancelDraft

@MainActor
final class PlatformQuickCaptureAnswerSubmissionTests: NTMSOrchestratorTestBase {

    private var controller: QuickCaptureController!
    private var savedKeepOpenInChat: Bool!

    override func setUp() {
        super.setUp()
        controller = QuickCaptureController.shared
        controller._testReset()
        controller.store = sut
        savedKeepOpenInChat = controller.keepOpenInChat
        controller.keepOpenInChat = false
        sut.configuration.llmBaseURL = "http://127.0.0.1:1"
    }

    override func tearDown() {
        controller.keepOpenInChat = savedKeepOpenInChat
        savedKeepOpenInChat = nil
        controller._testReset()
        controller = nil
        super.tearDown()
    }

    // MARK: fixtures

    /// A task whose latest run holds one step parked on `ask_supervisor`. Mirrors
    /// the private helper in `QuickCaptureControllerTests` so both suites drive
    /// the same shape.
    private func makeParkedTask() async -> (taskID: Int, stepID: String)? {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return nil
        }
        await sut.switchTask(to: taskID)

        let stepID = "platform_answer_step"
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: task.runs.first?.teamID ?? "test_team")
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: "eng", name: "Engineer",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            ))
            step.id = stepID
            step.needsSupervisorInput = true
            step.supervisorQuestion = "Which approach?"
            step.status = .needsSupervisorInput
            run.steps.append(step)
            task.runs.append(run)
        }
        return (taskID, stepID)
    }

    private func payload(taskID: Int, stepID: String, isChatMode: Bool = false) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: stepID,
            taskID: taskID,
            role: .softwareEngineer,
            roleDefinition: nil,
            question: "Which approach?",
            messageContent: nil,
            thinking: nil,
            isChatMode: isChatMode
        )
    }

    private func storedAnswer(taskID: Int, stepID: String) -> String? {
        sut.loadedTask(taskID)?.runs.last?.steps.first { $0.id == stepID }?.supervisorAnswer
    }

    // MARK: guard arms

    func testSubmitAnswer_withNoPendingAnswer_isANoop() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller.formState.answerText = "an answer nobody asked for"
        XCTAssertFalse(controller._testIsInAnswerMode, "Precondition: not in answer mode.")

        await controller.submitAnswer()

        XCTAssertNil(
            storedAnswer(taskID: taskID, stepID: stepID),
            "Without a pending question there is no step to answer — writing anyway would resume a run the Supervisor never unblocked."
        )
    }

    func testSubmitAnswer_withNoStore_isANoop() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))
        controller.formState.answerText = "text"
        controller.store = nil

        await controller.submitAnswer()

        XCTAssertNil(storedAnswer(taskID: taskID, stepID: stepID))
        controller.store = sut
    }

    func testSubmitAnswer_withEmptyTextAndNothingAttached_doesNotSubmit() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))
        controller.formState.answerText = "    \n  "
        controller.formState.answerAttachments = []
        controller.formState.answerClippedTexts = []

        await controller.submitAnswer()

        XCTAssertNil(storedAnswer(taskID: taskID, stepID: stepID), "An empty answer must not unblock the step.")
        XCTAssertTrue(controller._testIsInAnswerMode, "A rejected submit must leave the user in answer mode.")
    }

    /// Whitespace-only TEXT is still submittable when a clip is attached — the
    /// clip is the payload. Pins the three-way `||` in the emptiness guard.
    func testSubmitAnswer_emptyTextButAClip_stillSubmits() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))
        controller.formState.answerText = ""
        controller.formState.answerClippedTexts = ["clip-only-marker"]

        await controller.submitAnswer()

        let answer = storedAnswer(taskID: taskID, stepID: stepID)
        XCTAssertNotNil(answer, "A clip alone is a valid answer.")
        XCTAssertTrue(answer?.contains("clip-only-marker") ?? false)
    }

    // MARK: happy path

    func testSubmitAnswer_success_writesTheAnswerAndClearsAnswerState() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))
        controller.formState.answerText = "  Use the second approach  "
        controller._testIsPanelVisible = true

        await controller.submitAnswer()

        XCTAssertEqual(
            storedAnswer(taskID: taskID, stepID: stepID), "Use the second approach",
            "The answer is trimmed before it reaches the step."
        )
        XCTAssertFalse(controller._testIsInAnswerMode, "A successful submit exits answer mode in both branches.")
        XCTAssertEqual(controller.formState.answerText, "", "The composer must not keep the just-sent text.")
        XCTAssertTrue(controller.formState.answerClippedTexts.isEmpty)
        XCTAssertTrue(controller.formState.answerAttachments.isEmpty)
        XCTAssertFalse(controller._testIsPanelVisible, "keepOpenInChat == false ⇒ dismiss after answering.")
    }

    func testSubmitAnswer_success_foldsClipsIntoTheAnswerText() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))
        controller.formState.answerText = "See below"
        controller.formState.answerClippedTexts = ["func f() { } // answer-clip-marker"]

        await controller.submitAnswer()

        let answer = storedAnswer(taskID: taskID, stepID: stepID)
        XCTAssertTrue(answer?.contains("See below") ?? false)
        XCTAssertTrue(
            answer?.contains("answer-clip-marker") ?? false,
            "Answer clips are inlined by AnswerTextBuilder — the step's answer is the only channel to the model."
        )
    }

    func testSubmitAnswer_success_discardsThePerTaskAnswerDraft() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))
        controller.formState.answerText = "answered"

        await controller.submitAnswer()

        // Re-entering answer mode for the same task must start clean; a surviving
        // draft would resurrect the already-sent text in the composer.
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))
        XCTAssertEqual(
            controller.formState.answerText, "",
            "The draft for an answered task must be discarded, or the sent text reappears on the next question."
        )
    }

    func testSubmitAnswer_chatTeamWithKeepOpen_staysOpenInWorkingMode() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller.keepOpenInChat = true
        controller._testEnterAnswerMode(
            .supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID, isChatMode: true))
        )
        controller.formState.answerText = "keep chatting"
        controller._testIsPanelVisible = true

        await controller.submitAnswer()

        XCTAssertEqual(storedAnswer(taskID: taskID, stepID: stepID), "keep chatting")
        XCTAssertTrue(
            controller._testIsPanelVisible,
            "In a chat team with keep-open the overlay must stay up so the conversation continues."
        )
        XCTAssertFalse(controller._testIsInAnswerMode, "Both post-submit branches exit answer mode.")
    }

    /// The step disappeared between rendering the answer field and submitting
    /// (restart / rebuild). `answerSupervisorQuestion` returns false, and
    /// `submitAnswer` must bail BEFORE clearing the user's typing.
    func testSubmitAnswer_whenTheStepIsGone_keepsTheDraftAndStaysInAnswerMode() async {
        guard let (taskID, _) = await makeParkedTask() else { return }
        controller._testEnterAnswerMode(
            .supervisorAnswer(payload: payload(taskID: taskID, stepID: "no_such_step"))
        )
        controller.formState.answerText = "typed but undeliverable"
        controller._testIsPanelVisible = true
        sut.lastErrorMessage = nil

        await controller.submitAnswer()

        XCTAssertEqual(
            controller.formState.answerText, "typed but undeliverable",
            "A failed delivery must NOT eat the answer — the user has to be able to retry without retyping."
        )
        XCTAssertTrue(controller._testIsInAnswerMode)
        XCTAssertTrue(controller._testIsPanelVisible)
        XCTAssertTrue(
            sut.lastErrorMessage?.contains("no longer active") ?? false,
            "The Supervisor must be told the question went stale, not just that 'submission failed'. Got: \(String(describing: sut.lastErrorMessage))"
        )
    }

    // MARK: cancelDraft

    func testCancelDraft_inTaskMode_clearsTheDraftAndDismisses() async {
        controller.formState.title = "Half typed"
        controller.formState.supervisorTask = "Half typed goal"
        controller.formState.clippedTexts = ["clip"]
        let draftID = controller.formState.draftID
        controller._testIsPanelVisible = true
        controller._testForceNewTaskMode = true

        controller.cancelDraft()

        XCTAssertEqual(controller.formState.title, "")
        XCTAssertEqual(controller.formState.supervisorTask, "")
        XCTAssertTrue(controller.formState.clippedTexts.isEmpty)
        XCTAssertNotEqual(controller.formState.draftID, draftID, "Cancel mints a fresh draft id so the discarded staging dir is never reused.")
        XCTAssertFalse(controller._testIsPanelVisible)
        XCTAssertFalse(controller._testForceNewTaskMode)
    }

    func testCancelDraft_inAnswerMode_discardsTheAnswerButKeepsTheTaskDraft() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller.formState.title = "Task title survives"
        controller.formState.supervisorTask = "Task draft survives"
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))
        controller.formState.answerText = "answer being typed"
        controller.formState.answerClippedTexts = ["answer clip"]
        controller._testIsPanelVisible = true

        controller.cancelDraft()

        XCTAssertFalse(controller._testIsInAnswerMode)
        XCTAssertEqual(
            controller.formState.supervisorTask, "Task draft survives",
            "Cancelling an ANSWER must restore the stashed task draft, not wipe it — they are different pieces of user work."
        )
        XCTAssertEqual(controller.formState.title, "Task title survives")
        XCTAssertTrue(controller.formState.answerClippedTexts.isEmpty)
        XCTAssertFalse(controller._testIsPanelVisible)
        XCTAssertNil(storedAnswer(taskID: taskID, stepID: stepID), "Cancel must never deliver the answer.")
    }

    func testCancelDraft_inAnswerMode_discardsThePerTaskDraftSoReentryIsClean() async {
        guard let (taskID, stepID) = await makeParkedTask() else { return }
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))
        controller.formState.answerText = "abandoned answer"

        controller.cancelDraft()
        controller._testEnterAnswerMode(.supervisorAnswer(payload: payload(taskID: taskID, stepID: stepID)))

        XCTAssertEqual(
            controller.formState.answerText, "",
            "An explicitly cancelled answer must not come back on re-entry — cancel is the user saying 'discard this'."
        )
    }
}
